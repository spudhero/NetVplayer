// Real decoded fixture data plus adversarial frame/attachment lifetime cases.
// No audio device, system display mode change or receiver proof.
#import "NVDolbyVisionSource.h"
#import <IOSurface/IOSurface.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/ambient_viewing_environment.h>
#include <assert.h>
#include <math.h>

static AVFrame *decode(const char *path) {
    AVFormatContext *format = NULL;
    assert(avformat_open_input(&format, path, NULL, NULL) == 0);
    assert(avformat_find_stream_info(format, NULL) >= 0);
    int index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    assert(index >= 0);
    AVCodecContext *codec = avcodec_alloc_context3(avcodec_find_decoder(format->streams[index]->codecpar->codec_id));
    assert(codec && avcodec_parameters_to_context(codec, format->streams[index]->codecpar) >= 0);
    codec->thread_count = 1;
    assert(avcodec_open2(codec, codec->codec, NULL) >= 0);
    AVPacket *packet = av_packet_alloc(); AVFrame *frame = av_frame_alloc();
    int received = -1;
    for (int i = 0; i < 128 && received < 0; i++) {
        int read = av_read_frame(format, packet);
        if (read < 0) avcodec_send_packet(codec, NULL);
        else if (packet->stream_index == index) assert(avcodec_send_packet(codec, packet) >= 0);
        av_packet_unref(packet);
        received = avcodec_receive_frame(codec, frame);
    }
    assert(received == 0);
    av_packet_free(&packet); avcodec_free_context(&codec); avformat_close_input(&format);
    return frame;
}
static NSData *attachment(CVPixelBufferRef pixel, CFStringRef key) {
    return CFBridgingRelease(CVBufferCopyAttachment(pixel, key, NULL));
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    NSString *folder = @(argv[1]);
    AVFrame *frame = decode([[folder stringByAppendingPathComponent:@"p81-a.mp4"] fileSystemRepresentation]);
    NVDolbyVisionSource *source = [NVDolbyVisionSource new];
    BOOL captured = [source captureFrame:frame pts:1 generation:1 compatibility:1];
    if (!captured) NSLog(@"capture rejected: %@ color=%d/%d/%d/%d", source.facts,
        frame->color_primaries, frame->color_trc, frame->colorspace, frame->color_range);
    assert(captured);
    AVFrameSideData *rpu = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER);
    assert([attachment(source.pixel, CFSTR("DolbyVisionRPUData")) isEqualToData:[NSData dataWithBytes:rpu->data length:rpu->size]]);
    CFTypeRef iosRPU = IOSurfaceCopyValue(CVPixelBufferGetIOSurface(source.pixel), CFSTR("DolbyVisionRPUData"));
    assert(iosRPU && CFEqual(iosRPU, (__bridge CFDataRef)attachment(source.pixel, CFSTR("DolbyVisionRPUData"))));
    CFRelease(iosRPU);
    NSData *mastering = attachment(source.pixel, kCVImageBufferMasteringDisplayColorVolumeKey);
    const uint8_t expectedMastering[] = {0x21,0x34,0x9b,0xaa,0x19,0x96,0x08,0xfc,0x8a,0x48,0x39,0x08,0x3d,0x13,0x40,0x42,0,0x98,0x96,0x80,0,0,0,1};
    assert([mastering isEqualToData:[NSData dataWithBytes:expectedMastering length:24]]);
    const uint8_t expectedLight[] = {3,232,1,144};
    assert([attachment(source.pixel, kCVImageBufferContentLightLevelInfoKey) isEqualToData:[NSData dataWithBytes:expectedLight length:4]]);

    AVAmbientViewingEnvironment *ambient = av_ambient_viewing_environment_create_side_data(frame);
    ambient->ambient_illuminance = (AVRational){25,1};
    ambient->ambient_light_x = (AVRational){3127,10000};
    ambient->ambient_light_y = (AVRational){329,1000};
    assert([source captureFrame:frame pts:1 generation:1 compatibility:1]);
    const uint8_t expectedAmbient[] = {0,3,208,144,0x3d,0x13,0x40,0x42};
    assert([attachment(source.pixel, kCVImageBufferAmbientViewingEnvironmentKey) isEqualToData:[NSData dataWithBytes:expectedAmbient length:8]]);

    // Every Y/U/V sample is preserved; only 10-bit packing changes.
    assert(CVPixelBufferLockBaseAddress(source.pixel, kCVPixelBufferLock_ReadOnly) == 0);
    for (int p = 0; p < 3; p++) {
        int w = p ? frame->width/2 : frame->width, h = p ? frame->height/2 : frame->height;
        for (int y = 0; y < h; y++) {
            const uint16_t *original = (const void *)(frame->data[p]+y*frame->linesize[p]);
            const uint16_t *copied = (const void *)((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source.pixel, p ? 1 : 0)+y*CVPixelBufferGetBytesPerRowOfPlane(source.pixel, p ? 1 : 0));
            for (int x = 0; x < w; x++) assert((copied[p ? 2*x+(p-1) : x] >> 6) == original[x]);
        }
    }
    CVPixelBufferUnlockBaseAddress(source.pixel, kCVPixelBufferLock_ReadOnly);
    // Held compositor buffers cannot be overwritten or cause unbounded growth.
    CVPixelBufferRef held[3];
    for (int i = 0; i < 3; i++) {
        assert([source captureFrame:frame pts:i generation:1 compatibility:1]);
        held[i] = CVPixelBufferRetain(source.pixel);
    }
    assert(![source captureFrame:frame pts:4 generation:1 compatibility:1]);
    assert([source.facts[@"sourceCaptureReason"] isEqual:@"pool-busy"]);
    for (int i = 0; i < 3; i++) CFRelease(held[i]);

    // Missing static metadata does not reuse another frame's metadata.
    av_frame_remove_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT);
    for (int i = 0; i < 8; i++) {
        assert([source captureFrame:frame pts:1 generation:2 compatibility:1]);
        assert(!attachment(source.pixel, kCVImageBufferMasteringDisplayColorVolumeKey));
        assert(!attachment(source.pixel, kCVImageBufferContentLightLevelInfoKey));
        assert(!attachment(source.pixel, kCVImageBufferAmbientViewingEnvironmentKey));
    }
    AVFrameSideData *md = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
    AVDOVIMetadata *metadata = (void *)md->data;
    AVDOVIRpuDataHeader *header = (void *)(md->data + metadata->header_offset);
    // Controlled residual-required header, not a claimed P7 FEL media decode.
    header->disable_residual_flag = 0;
    assert(![source captureFrame:frame pts:1 generation:2 compatibility:1]);
    assert([source.facts[@"sourceCaptureReason"] isEqual:@"residual-required"]);
    header->disable_residual_flag = 1;
    assert(![source captureFrame:frame pts:1 generation:2 compatibility:0]); // unverified / P7 MEL config
    size_t offset = metadata->header_offset, size = md->size;
    for (size_t n = 0; n < offset+sizeof(*header); n++) {
        md->size = n;
        assert(![source captureFrame:frame pts:1 generation:2 compatibility:1]);
    }
    md->size = size;
    metadata->header_offset = SIZE_MAX;
    assert(![source captureFrame:frame pts:1 generation:2 compatibility:1]);
    metadata->header_offset = offset;
    assert(![source captureFrame:frame pts:NAN generation:2 compatibility:1]);
    assert(![source captureFrame:frame pts:1 generation:0 compatibility:1]);
    assert(![source captureFrame:NULL pts:1 generation:2 compatibility:1]);
    assert([source captureFrame:frame pts:1 generation:2 compatibility:1]);
    [source reset]; assert(!source.pixel && source.generation == 0);
    av_frame_free(&frame);
    frame = decode([[folder stringByAppendingPathComponent:@"p5.mp4"] fileSystemRepresentation]);
    assert(![source captureFrame:frame pts:1 generation:3 compatibility:1]);
    assert([source.facts[@"sourceCaptureReason"] isEqual:@"profile-not-supported"]);
    av_frame_free(&frame);
    frame = decode([[folder stringByAppendingPathComponent:@"p84.mp4"] fileSystemRepresentation]);
    assert([source captureFrame:frame pts:1 generation:4 compatibility:4]);
    assert(CFEqual(CVBufferGetAttachment(source.pixel, kCVImageBufferTransferFunctionKey, NULL), kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    assert(![source captureFrame:frame pts:1 generation:4 compatibility:1]);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER);
    assert(![source captureFrame:frame pts:1 generation:4 compatibility:4]);
    av_frame_free(&frame);
    puts("PASS: decoded source RPU/pixels, SEI packing, static removal, pool pressure, profile/residual/PTS/header gates and release");
    return 0;
} }
