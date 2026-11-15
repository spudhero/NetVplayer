#import "NVDolbyVisionSource.h"
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <libavutil/frame.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/ambient_viewing_environment.h>
#include <math.h>

static const AVFrameSideData *side(const AVFrame *frame, enum AVFrameSideDataType type) {
    for (int i = 0; i < frame->nb_side_data; i++)
        if (frame->side_data[i]->type == type) return frame->side_data[i];
    return NULL;
}
static void attach(CVPixelBufferRef pixel, CFStringRef key, const void *bytes, size_t count) {
    CFDataRef data = CFDataCreate(NULL, bytes, count);
    CVBufferSetAttachment(pixel, key, data, kCVAttachmentMode_ShouldPropagate);
    CFRelease(data);
}
static BOOL scaled(AVRational value, double scale, uint32_t limit, uint32_t *out) {
    if (value.den <= 0 || value.num < 0) return NO;
    double v = round((double)value.num / value.den * scale);
    if (!isfinite(v) || v > limit) return NO;
    *out = (uint32_t)v; return YES;
}
static void be16(uint8_t *p, uint32_t v) { p[0] = v >> 8; p[1] = v; }
static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

// CoreVideo's public attachment payloads are the big-endian SEI payloads,
// not native FFmpeg structs. Never keep static HDR data from another frame.
static BOOL colorMetadata(CVPixelBufferRef pixel, const AVFrame *frame) {
    const AVFrameSideData *sd = side(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    uint8_t bytes[24]; uint32_t v;
    if (sd) {
        if (sd->size < sizeof(AVMasteringDisplayMetadata)) return NO;
        const AVMasteringDisplayMetadata *m = (const void *)sd->data;
        if (m->has_primaries && m->has_luminance) {
            // SEI order is G, B, R; FFmpeg uses R, G, B.
            const int order[] = {1, 2, 0};
            for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++) {
                if (!scaled(m->display_primaries[order[i]][j], 50000, 50000, &v)) return NO;
                be16(bytes + i*4 + j*2, v);
            }
            for (int j = 0; j < 2; j++) {
                if (!scaled(m->white_point[j], 50000, 50000, &v)) return NO;
                be16(bytes + 12 + j*2, v);
            }
            if (!scaled(m->max_luminance, 10000, UINT32_MAX, &v)) return NO;
            be32(bytes + 16, v);
            if (!scaled(m->min_luminance, 10000, UINT32_MAX, &v)) return NO;
            be32(bytes + 20, v);
            attach(pixel, kCVImageBufferMasteringDisplayColorVolumeKey, bytes, 24);
        }
    }
    sd = side(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    if (sd) {
        if (sd->size < sizeof(AVContentLightMetadata)) return NO;
        const AVContentLightMetadata *m = (const void *)sd->data;
        if (m->MaxCLL > UINT16_MAX || m->MaxFALL > UINT16_MAX) return NO;
        be16(bytes, m->MaxCLL); be16(bytes+2, m->MaxFALL);
        attach(pixel, kCVImageBufferContentLightLevelInfoKey, bytes, 4);
    }
    sd = side(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT);
    if (sd) {
        if (sd->size < sizeof(AVAmbientViewingEnvironment)) return NO;
        const AVAmbientViewingEnvironment *m = (const void *)sd->data;
        if (!scaled(m->ambient_illuminance, 10000, UINT32_MAX, &v)) return NO;
        be32(bytes, v);
        if (!scaled(m->ambient_light_x, 50000, 50000, &v)) return NO;
        be16(bytes+4, v);
        if (!scaled(m->ambient_light_y, 50000, 50000, &v)) return NO;
        be16(bytes+6, v);
        attach(pixel, kCVImageBufferAmbientViewingEnvironmentKey, bytes, 8);
    }
    return YES;
}

@implementation NVDolbyVisionSource {
    CVPixelBufferPoolRef _pool;
    CVPixelBufferRef _pixel;
    int _width, _height, _compatibility, _residual;
    double _pts, _copyMS;
    uint64_t _generation;
    NSString *_reason;
    NSUInteger _bytes, _captures, _rejections;
}
@synthesize pixel = _pixel, pts = _pts, generation = _generation;
- (void)beginFrame {
    if (_pixel) CFRelease(_pixel);
    _pixel = NULL; _bytes = 0; _residual = -1; _compatibility = 0;
    _pts = NAN; _generation = 0; _copyMS = 0; _reason = @"not-captured";
}
- (BOOL)reject:(NSString *)reason {
    if (_pixel) CFRelease(_pixel);
    _pixel = NULL; _bytes = 0; _reason = reason; _rejections++; return NO;
}
- (BOOL)captureFrame:(const void *)opaque pts:(double)pts generation:(uint64_t)generation compatibility:(int)compatibility {
    [self beginFrame];
    const AVFrame *f = opaque;
    if (!f) return [self reject:@"composition-or-transform"];
    if (!isfinite(pts) || !generation) return [self reject:@"frame-identity"];
    const AVFrameSideData *rpu = side(f, AV_FRAME_DATA_DOVI_RPU_BUFFER);
    const AVFrameSideData *md = side(f, AV_FRAME_DATA_DOVI_METADATA);
    if (!rpu || !rpu->data || !rpu->size || rpu->size > 65536 || !md || md->size < sizeof(AVDOVIMetadata))
        return [self reject:@"missing-or-invalid-rpu"];
    const AVDOVIMetadata *m = (const void *)md->data;
    if (m->header_offset < sizeof(*m) || m->header_offset > md->size ||
        sizeof(AVDOVIRpuDataHeader) > md->size - m->header_offset)
        return [self reject:@"invalid-rpu-header"];
    AVDOVIRpuDataHeader h;
    memcpy(&h, md->data + m->header_offset, sizeof(h));
    _residual = h.disable_residual_flag;
    if (_residual != 1) return [self reject:@"residual-required"];
    // Initial experiment deliberately admits only verified P8.1/P8.4 streams.
    // P5 and P7 MEL/FEL stay on the existing reconstruction path.
    if ((compatibility != 1 && compatibility != 4) || h.vdr_rpu_profile != 1 ||
        h.bl_video_full_range_flag || h.bl_bit_depth != 10 || h.rpu_type != 2)
        return [self reject:@"profile-not-supported"];
    if (f->color_primaries != AVCOL_PRI_BT2020 || f->colorspace != AVCOL_SPC_BT2020_NCL ||
        f->color_range != AVCOL_RANGE_MPEG ||
        f->color_trc != (compatibility == 4 ? AVCOL_TRC_ARIB_STD_B67 : AVCOL_TRC_SMPTE2084))
        return [self reject:@"source-color-mismatch"];
    if (f->format != AV_PIX_FMT_YUV420P10LE && f->format != AV_PIX_FMT_P010LE)
        return [self reject:@"pixel-format-not-supported"];
    int w = f->width, height = f->height;
    if (w <= 0 || height <= 0 || w > 4096 || height > 2160 || (w | height) & 1 ||
        f->crop_left || f->crop_right || f->crop_top || f->crop_bottom ||
        (f->flags & AV_FRAME_FLAG_INTERLACED)) return [self reject:@"dimensions-or-crop"];
    int planes = f->format == AV_PIX_FMT_YUV420P10LE ? 3 : 2;
    for (int p = 0; p < planes; p++) {
        int row = p && planes == 3 ? w : w*2;
        if (!f->data[p] || f->linesize[p] < row) return [self reject:@"plane-layout"];
    }
    double start = CACurrentMediaTime();
    if (!_pool || w != _width || height != _height) {
        if (_pool) CFRelease(_pool);
        _pool = NULL;
        CVReturn code = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)@{
            (__bridge id)kCVPixelBufferWidthKey:@(w), (__bridge id)kCVPixelBufferHeightKey:@(height),
            (__bridge id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            (__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &_pool);
        if (code || !_pool) return [self reject:@"pool-create"];
        _width = w; _height = height;
    }
    CVReturn code = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool,
        (__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferPoolAllocationThresholdKey:@3}, &_pixel);
    if (code || !_pixel) return [self reject:code == kCVReturnWouldExceedAllocationThreshold ? @"pool-busy" : @"pixel-allocation-failed"];
    // Also bound actual padded allocations, not just logical dimensions.
    if (CVPixelBufferGetDataSize(_pixel) > 32*1024*1024) return [self reject:@"pixel-budget"];
    if (CVPixelBufferLockBaseAddress(_pixel, 0)) return [self reject:@"pixel-lock"];
    for (int p = 0; p < 2; p++) {
        for (int y = 0; y < (p ? height/2 : height); y++) {
            uint16_t *dst = (void *)((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(_pixel, p) + y*CVPixelBufferGetBytesPerRowOfPlane(_pixel, p));
            const uint16_t *src = (const void *)(f->data[p] + y*f->linesize[p]);
            if (f->format == AV_PIX_FMT_P010LE) memcpy(dst, src, w*2);
            else if (!p) for (int x = 0; x < w; x++) dst[x] = src[x] << 6;
            else {
                const uint16_t *v = (const void *)(f->data[2] + y*f->linesize[2]);
                for (int x = 0; x < w/2; x++) { dst[2*x] = src[x] << 6; dst[2*x+1] = v[x] << 6; }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(_pixel, 0);
    CVBufferRemoveAllAttachments(_pixel);
    IOSurfaceRemoveAllValues(CVPixelBufferGetIOSurface(_pixel));
    CVBufferSetAttachment(_pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(_pixel, kCVImageBufferTransferFunctionKey,
        compatibility == 4 ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(_pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
    if (f->chroma_location == AVCHROMA_LOC_LEFT || f->chroma_location == AVCHROMA_LOC_TOPLEFT) {
        CVBufferSetAttachment(_pixel, kCVImageBufferChromaLocationTopFieldKey,
            f->chroma_location == AVCHROMA_LOC_LEFT ? kCVImageBufferChromaLocation_Left : kCVImageBufferChromaLocation_TopLeft,
            kCVAttachmentMode_ShouldPropagate);
    } else if (f->chroma_location != AVCHROMA_LOC_UNSPECIFIED) return [self reject:@"chroma-location"];
    if (!colorMetadata(_pixel, f)) return [self reject:@"invalid-color-metadata"];
    attach(_pixel, CFSTR("DolbyVisionRPUData"), rpu->data, rpu->size);
    CFTypeRef data = CVBufferCopyAttachment(_pixel, CFSTR("DolbyVisionRPUData"), NULL);
    IOSurfaceSetValue(CVPixelBufferGetIOSurface(_pixel), CFSTR("DolbyVisionRPUData"), data);
    CFRelease(data);
    _bytes = rpu->size; _pts = pts; _generation = generation; _compatibility = compatibility;
    _copyMS = (CACurrentMediaTime()-start)*1000; _captures++; _reason = @"captured";
    return YES;
}
- (NSDictionary *)facts {
    return @{@"sourceCaptureReason":_reason ?: @"not-captured", @"sourceCaptures":@(_captures),
        @"sourceRejections":@(_rejections), @"sourceCopyMS":@(_copyMS), @"sourceRPUBytes":@(_bytes),
        @"sourceDisableResidual":@(_residual), @"sourceCompatibilityID":@(_compatibility),
        @"sourceWidth":@(_width), @"sourceHeight":@(_height), @"sourceMaximumBuffers":@3,
        @"sourceMaximumBufferBytes":@(32*1024*1024)};
}
- (void)reset { [self beginFrame]; if (_pool) CFRelease(_pool); _pool = NULL; _width = _height = 0; }
- (void)dealloc { if (_pixel) CFRelease(_pixel); if (_pool) CFRelease(_pool); }
@end
