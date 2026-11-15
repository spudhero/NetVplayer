#import "NVDolbyVisionSurface.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLIOSurface.h>
#import <Metal/Metal.h>
#import "NVDolbyVisionMetadata.h"
#import "NVDolbyVisionSource.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface NVDolbyVisionSlot : NSObject {
@public
    IOSurfaceRef surface;
    GLuint fbo, texture;
}
@end
@implementation NVDolbyVisionSlot
- (void)dealloc { if (surface) CFRelease(surface); }
@end

@implementation NVDolbyVisionSurface {
    AVSampleBufferDisplayLayer *_displayLayer;
    CVPixelBufferPoolRef _pool;
    CVPixelBufferRef _activePixel, _presentedPixel;
    NSMutableSet<NSNumber *> *_poolSurfaceIDs;
    NVDolbyVisionSlot *_active;
    VTHDRPerFrameMetadataGenerationSessionRef _metadataSession API_AVAILABLE(macos(15.0));
    int _width, _height;
    BOOL _temporarilyUnavailable, _hasPTS, _currentMetadataSubmitted;
    double _lastPTS, _metadataMS, _glWaitMS;
    uint64_t _generation;
    NSUInteger _submittedFrames, _metadataFrames, _metadataBytes, _busyFrames, _resets;
    OSStatus _lastError;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _statisticsPipeline;
    id<MTLBuffer> _statisticsBuffer;
    uint16_t _minimumPQ, _maximumPQ, _averagePQ;
    double _statisticsMS;
    double _backpressureSince;
    NVDolbyVisionSource *_source;
    BOOL _presentedSource;
    NSString *_outputProfile;
    uint64_t _minimumGeneration;
}
@synthesize framesPerSecond = _framesPerSecond;
@synthesize sourceMetadataEnabled = _sourceMetadataEnabled, sourceCompatibility = _sourceCompatibility;

+ (BOOL)available { if (@available(macOS 15.0, *)) return YES; return NO; }
+ (instancetype)surfaceWithFrame:(NSRect)frame { return [[self alloc] initWithFrame:frame]; }
- (instancetype)initWithFrame:(NSRect)frame {
    if (![NVDolbyVisionSurface available]) return nil;
    if (!(self = [super initWithFrame:frame])) return nil;
    _framesPerSecond = 24;
    _source = [NVDolbyVisionSource new];
    _poolSurfaceIDs = [NSMutableSet new];
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    // Independent display-referred HLG statistics, including the BT.2100 OOTF
    // (1000-nit reference display, system gamma 1.2). Analyze every rendered
    // pixel on the GPU; read back tile reductions, never the video image.
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "float inverseHLG(float x) { return x<=0.5f ? x*x/3.0f : (exp((x-0.55991073f)/0.17883277f)+0.28466892f)/12.0f; }\n"
        "float pq(float x) { float p=pow(clamp(x/10000.0f,0.0f,1.0f),2610.0f/16384.0f); return pow((3424.0f/4096.0f+2413.0f/128.0f*p)/(1.0f+2392.0f/128.0f*p),2523.0f/32.0f); }\n"
        "kernel void hlgStats(texture2d<half,access::read> image [[texture(0)]], device float4 *stats [[buffer(0)]], uint2 tile [[thread_position_in_grid]]) {\n"
        "uint width=image.get_width(), height=image.get_height(), columns=(width+15)/16; float lo=1,hi=0,sum=0,count=0;\n"
        "for(uint y=tile.y*16;y<min(height,(tile.y+1)*16);y++) for(uint x=tile.x*16;x<min(width,(tile.x+1)*16);x++) {\n"
        "float3 c=float3(image.read(uint2(x,y)).rgb); if(!all(isfinite(c))) { stats[tile.y*columns+tile.x]=float4(-1); return; }\n"
        "c=clamp(c,0.0f,1.0f); float3 scene=float3(inverseHLG(c.r),inverseHLG(c.g),inverseHLG(c.b));\n"
        "float luminance=dot(scene,float3(0.2627f,0.6780f,0.0593f)); float3 display=1000.0f*scene*pow(luminance,0.2f);\n"
        "float maximum=pq(max(display.r,max(display.g,display.b))); float minimum=pq(min(display.r,min(display.g,display.b)));\n"
        "lo=min(lo,minimum); hi=max(hi,maximum); sum+=maximum; count++; }\n"
        "stats[tile.y*columns+tile.x]=float4(lo,hi,sum,count); }";
    id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:nil];
    id<MTLFunction> function = [library newFunctionWithName:@"hlgStats"];
    if (function) _statisticsPipeline = [_device newComputePipelineStateWithFunction:function error:nil];
    if (!_queue || !_statisticsPipeline) return nil;
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    // The FBO already includes the video crop, letterboxing, OSD and subtitles.
    _displayLayer.videoGravity = AVLayerVideoGravityResize;
    _displayLayer.opaque = YES;
    self.wantsLayer = YES;
    self.layer = _displayLayer;
    return self;
}
- (int)framebuffer { return _active ? (int)_active->fbo : 0; }
- (BOOL)temporarilyUnavailable { return _temporarilyUnavailable; }
- (void)setSourceMetadataEnabled:(BOOL)enabled {
    if (_sourceMetadataEnabled == enabled) return;
    _sourceMetadataEnabled = enabled;
    [_source reset];
    [self resetMetadata];
}
- (void)setSourceCompatibility:(int)compatibility {
    if (_sourceCompatibility == compatibility) return;
    _sourceCompatibility = compatibility;
    [_source reset];
    [self resetMetadata];
}
- (void)captureSourceFrame:(const void *)frame pts:(double)pts generation:(uint64_t)generation {
    [_source captureFrame:frame pts:pts generation:generation compatibility:_sourceCompatibility];
}
void nv_mpv_capture_dolby_source(void *opaque, const void *frame, double pts, uint64_t generation) {
    [(__bridge NVDolbyVisionSurface *)opaque captureSourceFrame:frame pts:pts generation:generation];
}
- (void)discardActivePixel {
    // CGL's IOSurface texture binding keeps the surface in use. Releasing only
    // the CVPixelBuffer starves the pool after three frames. GL has completed
    // before submission, so retire the binding before releasing the pixel.
    if (_active) {
        if (_active->fbo) glDeleteFramebuffers(1, &_active->fbo);
        if (_active->texture) glDeleteTextures(1, &_active->texture);
        _active->fbo = _active->texture = 0;
    }
    if (_activePixel) CFRelease(_activePixel);
    _activePixel = NULL; _active = nil;
}
- (void)resetMetadata {
    if (@available(macOS 15.0, *)) {
        if (_metadataSession) CFRelease(_metadataSession);
        _metadataSession = NULL;
    }
    [_displayLayer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
    if (_presentedPixel) CFRelease(_presentedPixel);
    _presentedPixel = NULL;
    _hasPTS = NO; _currentMetadataSubmitted = NO; _metadataBytes = 0;
    _presentedSource = NO; _outputProfile = nil;
    _resets++;
}
- (void)invalidateBeforeGeneration:(uint64_t)generation {
    _minimumGeneration = generation;
    [_source reset];
    [self resetMetadata];
}
- (BOOL)prepareWidth:(int)width height:(int)height {
    [_source beginFrame];
    _currentMetadataSubmitted = NO;
    _temporarilyUnavailable = NO;
    [self discardActivePixel];
    if (!CGLGetCurrentContext() || ![NVDolbyVisionSurface available]) return NO;
    if (_displayLayer.sampleBufferRenderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        _lastError = (OSStatus)_displayLayer.sampleBufferRenderer.error.code;
        _currentMetadataSubmitted = NO;
        return NO;
    }
    if (width != _width || height != _height || !_pool) {
        uint64_t minimumGeneration = _minimumGeneration;
        [self releaseSurface];
        _minimumGeneration = minimumGeneration;
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return NO;
        size_t stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 8);
        // Three buffers cover the compositor's current image, the next image and
        // the GL writer. Never overwrite a buffer retained by AVFoundation.
        if ((uint64_t)stride * height * 3 > 192 * 1024 * 1024) return NO;
        CVReturn result = CVPixelBufferPoolCreate(NULL,
            (__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferPoolMinimumBufferCountKey:@3},
            (__bridge CFDictionaryRef)@{
                (__bridge id)kCVPixelBufferWidthKey:@(width),
                (__bridge id)kCVPixelBufferHeightKey:@(height),
                (__bridge id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_64RGBAHalf),
                (__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &_pool);
        if (result != kCVReturnSuccess || !_pool) { _lastError = result; return NO; }
        _width = width; _height = height;
    }
    if (!_displayLayer.sampleBufferRenderer.readyForMoreMediaData) {
        return [self waitForBackpressure];
    }
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool,
        (__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferPoolAllocationThresholdKey:@3}, &_activePixel);
    if (result == kCVReturnWouldExceedAllocationThreshold) {
        return [self waitForBackpressure];
    }
    if (result != kCVReturnSuccess || !_activePixel) { _lastError = result; return NO; }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(_activePixel);
    if (!surface) { [self discardActivePixel]; return NO; }
    _backpressureSince = 0;
    [_poolSurfaceIDs addObject:@(IOSurfaceGetID(surface))];
    {
        NVDolbyVisionSlot *slot = [NVDolbyVisionSlot new];
        slot->surface = (IOSurfaceRef)CFRetain(surface);
        _active = slot;
        glGenTextures(1, &slot->texture);
        glBindTexture(GL_TEXTURE_RECTANGLE, slot->texture);
        CGLError error = CGLTexImageIOSurface2D(CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE,
            GL_RGBA16F, width, height, GL_RGBA, GL_HALF_FLOAT, surface, 0);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glBindTexture(GL_TEXTURE_RECTANGLE, 0);
        glGenFramebuffers(1, &slot->fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, slot->fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, slot->texture, 0);
        BOOL complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        if (error != kCGLNoError || !complete) { _lastError = error ?: -1; return NO; }
    }
    return YES;
}
- (BOOL)waitForBackpressure {
    double now = CACurrentMediaTime();
    if (!_backpressureSince) _backpressureSince = now;
    if (now - _backpressureSince > 1) {
        _lastError = -20001; // Host deadline, not a VideoToolbox status.
        _currentMetadataSubmitted = NO;
        return NO;
    }
    _temporarilyUnavailable = YES; _busyFrames++;
    return NO;
}
- (BOOL)presentPTS:(double)pts generation:(uint64_t)generation {
    if (!isfinite(pts) || !_activePixel || !_active) {
        _currentMetadataSubmitted = NO; _metadataBytes = 0;
        _lastError = kVTParameterErr;
        return NO;
    }
    if (@available(macOS 15.0, *)) {
        if (generation < _minimumGeneration) {
            // A seek can leave the outgoing frame available for redraw until
            // the core publishes its reset. Consume it without displaying it.
            glFinish(); [self discardActivePixel]; [_source beginFrame];
            [self resetMetadata]; return YES;
        }
        if (_hasPTS && (generation != _generation || pts < _lastPTS || pts > _lastPTS + 1))
            [self resetMetadata];
        // A paused-frame redraw can change subtitles/OSD at the same media PTS.
        // Always submit the newly rendered pixels and matching metadata.
        _currentMetadataSubmitted = NO;
        _metadataBytes = 0;
        // Capture ran inside render(); presentation happens only after mpv's
        // target-time wait has completed. Match both timeline and frame PTS.
        if (_sourceMetadataEnabled && _source.pixel && _source.generation == generation &&
            fabs(_source.pts - pts) < 0.000001) {
            _metadataBytes = [_source.facts[@"sourceRPUBytes"] unsignedIntegerValue];
            _metadataFrames++;
            _metadataMS = 0; _statisticsMS = 0; _glWaitMS = 0;
            double waitStart = CACurrentMediaTime(); glFinish();
            _glWaitMS = (CACurrentMediaTime()-waitStart)*1000;
            _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
            _outputProfile = _sourceCompatibility == 4 ? @"8.4" : @"8.1";
            return [self enqueuePixel:_source.pixel pts:pts generation:generation source:YES];
        }
        _displayLayer.videoGravity = AVLayerVideoGravityResize;
        _outputProfile = @"8.4";
        // GL has no public fence interoperable with this system analysis API.
        double start = CACurrentMediaTime(); glFinish();
        _glWaitMS = (CACurrentMediaTime()-start)*1000;
        if (![self measureLuminance]) { _lastError = kVTInsufficientSourceColorDataErr; return NO; }
        if (!_metadataSession) {
            float fps = isfinite(_framesPerSecond) && _framesPerSecond >= 1 && _framesPerSecond <= 240
                ? (float)_framesPerSecond : 24;
            _lastError = VTHDRPerFrameMetadataGenerationSessionCreate(NULL, fps,
                (__bridge CFDictionaryRef)@{(__bridge id)kVTHDRPerFrameMetadataGenerationOptionsKey_HDRFormats:
                    @[(__bridge id)kVTHDRPerFrameMetadataGenerationHDRFormatType_DolbyVision]}, &_metadataSession);
            if (_lastError || !_metadataSession) return NO;
        }
        // These are HLG BT.2020 pixels, not the EDR route's linear BT.709 pixels.
        // The renderer converts/reconstructs first; source RPU cannot be attached
        // to modified pixels. Apple generates NEW matching Profile 8.4 metadata.
        CVBufferRemoveAllAttachments(_activePixel);
        CVBufferSetAttachment(_activePixel, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(_activePixel, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(_activePixel, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
        // CoreVideo pool reuse must not retain a previous frame's opaque RPU.
        // The public API has no exported constant for this observed attachment;
        // fail closed if a future OS changes the system's attachment contract.
        IOSurfaceRemoveValue(CVPixelBufferGetIOSurface(_activePixel), CFSTR("DolbyVisionRPUData"));
        start = CACurrentMediaTime();
        _lastError = VTHDRPerFrameMetadataGenerationSessionAttachMetadata(_metadataSession, _activePixel, true);
        _metadataMS = (CACurrentMediaTime()-start)*1000;
        CFTypeRef payload = CVBufferCopyAttachment(_activePixel, CFSTR("DolbyVisionRPUData"), NULL);
        BOOL hasPayload = payload && CFGetTypeID(payload) == CFDataGetTypeID() && CFDataGetLength(payload) > 0;
        if (!_lastError && hasPayload) {
            uint8_t corrected[1024]; size_t count = 0;
            hasPayload = nv_dovi_system_rpu_set_l1(CFDataGetBytePtr(payload), (size_t)CFDataGetLength(payload),
                _minimumPQ, _maximumPQ, _averagePQ, corrected, sizeof(corrected), &count);
            CFRelease(payload); payload = NULL;
            if (hasPayload) {
                payload = CFDataCreate(NULL, corrected, (CFIndex)count);
                if (payload) {
                    CVBufferSetAttachment(_activePixel, CFSTR("DolbyVisionRPUData"), payload, kCVAttachmentMode_ShouldPropagate);
                    IOSurfaceSetValue(CVPixelBufferGetIOSurface(_activePixel), CFSTR("DolbyVisionRPUData"), payload);
                } else { hasPayload = NO; }
            }
        }
        _metadataBytes = hasPayload ? (NSUInteger)CFDataGetLength(payload) : 0;
        if (payload) CFRelease(payload);
        _currentMetadataSubmitted = NO;
        if (_lastError || !hasPayload) { if (!_lastError) _lastError = kVTInsufficientSourceColorDataErr; return NO; }
        _metadataFrames++;
        return [self enqueuePixel:_activePixel pts:pts generation:generation source:NO];
    }
    return NO;
}
- (BOOL)enqueuePixel:(CVPixelBufferRef)pixel pts:(double)pts generation:(uint64_t)generation source:(BOOL)source {
    if (_hasPTS && _presentedSource != source) [self resetMetadata];
    _outputProfile = source && _sourceCompatibility == 1 ? @"8.1" : @"8.4";
    CFTypeRef payload = CVBufferCopyAttachment(pixel, CFSTR("DolbyVisionRPUData"), NULL);
    _metadataBytes = payload && CFGetTypeID(payload) == CFDataGetTypeID() ? CFDataGetLength(payload) : 0;
    if (payload) CFRelease(payload);
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    _lastError = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel, &format);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(pts, 1000000), kCMTimeInvalid};
    if (!_lastError) _lastError = CMSampleBufferCreateReadyWithImageBuffer(NULL, pixel, format, &timing, &sample);
    if (format) CFRelease(format);
    if (_lastError || !sample) return NO;
    // mpv has already waited for this frame's audio/video deadline. No second
    // timebase, decoder, player or audio output is introduced here.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                         kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    [_displayLayer.sampleBufferRenderer enqueueSampleBuffer:sample];
    CFRelease(sample);
    if (_displayLayer.sampleBufferRenderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        _lastError = (OSStatus)_displayLayer.sampleBufferRenderer.error.code;
        return NO;
    }
    if (_presentedPixel) CFRelease(_presentedPixel);
    _presentedPixel = (CVPixelBufferRef)CFRetain(pixel);
    _lastPTS = pts; _generation = generation; _hasPTS = YES;
    _submittedFrames++; _currentMetadataSubmitted = YES; _presentedSource = source;
    [self discardActivePixel];
    return YES;
}
- (BOOL)measureLuminance {
    @autoreleasepool {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
        width:_width height:_height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> image = [_device newTextureWithDescriptor:desc iosurface:CVPixelBufferGetIOSurface(_activePixel) plane:0];
    NSUInteger columns = (_width+15)/16, rows = (_height+15)/16, bytes = columns*rows*4*sizeof(float);
    if (!_statisticsBuffer || _statisticsBuffer.length != bytes)
        _statisticsBuffer = [_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!image || !_statisticsBuffer || !command || !encoder) return NO;
    [encoder setComputePipelineState:_statisticsPipeline];
    [encoder setTexture:image atIndex:0]; [encoder setBuffer:_statisticsBuffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(columns, rows, 1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder endEncoding];
    double start = CACurrentMediaTime(); [command commit]; [command waitUntilCompleted];
    _statisticsMS = (CACurrentMediaTime()-start)*1000;
    if (command.status != MTLCommandBufferStatusCompleted) return NO;
    const float *stats = _statisticsBuffer.contents;
    double minimum = 1, maximum = 0, sum = 0, count = 0;
    for (NSUInteger i = 0; i < columns*rows; i++, stats += 4) {
        if (stats[3] < 0 || !isfinite(stats[2])) return NO;
        minimum = fmin(minimum, stats[0]); maximum = fmax(maximum, stats[1]);
        sum += stats[2]; count += stats[3];
    }
    if (count != (double)_width*_height) return NO;
    // CMv2.9 L1 legal display-adaptation bounds, on a 12-bit PQ scale.
    _minimumPQ = (uint16_t)fmin(12, fmax(0, round(minimum*4095)));
    _maximumPQ = (uint16_t)fmin(3079, fmax(2081, round(maximum*4095)));
    _averagePQ = (uint16_t)fmin(_maximumPQ-1, fmax(819, round(sum/count*4095)));
    return YES;
    }
}
- (NSDictionary *)facts {
    BOOL ready = NO;
    if (@available(macOS 14.4, *)) ready = _displayLayer.readyForDisplay;
    NSMutableDictionary *facts = [@{@"width":@(_width), @"height":@(_height), @"surfaceCount":@(_poolSurfaceIDs.count),
        @"maximumSurfaceCount":@3, @"busyFrames":@(_busyFrames), @"resets":@(_resets),
        @"metadataFrames":@(_metadataFrames), @"submittedFrames":@(_submittedFrames),
        @"metadataBytes":@(_metadataBytes), @"currentMetadataSubmitted":@(_currentMetadataSubmitted),
        @"lastPTS":@(_hasPTS ? _lastPTS : 0), @"generation":@(_generation), @"lastError":@(_lastError),
        @"metadataMS":@(_metadataMS), @"glFinishMS":@(_glWaitMS),
        @"statisticsMS":@(_statisticsMS), @"l1MinimumPQ":_presentedSource ? NSNull.null : @(_minimumPQ),
        @"l1MaximumPQ":_presentedSource ? NSNull.null : @(_maximumPQ),
        @"l1AveragePQ":_presentedSource ? NSNull.null : @(_averagePQ),
        @"rendererStatus":@(_displayLayer.sampleBufferRenderer.status),
        @"readyForDisplay":@(ready),
        @"outputProfile":_outputProfile ?: @"none",
        @"colorSpace":_presentedSource && _sourceCompatibility == 1 ? @"BT.2020 / PQ" : @"BT.2020 / HLG",
        @"metadataOrigin":_presentedSource ? @"source-rpu-unmodified" : @"system-regenerated+gpu-l1",
        @"sourceMetadataRequested":@(_sourceMetadataEnabled),
        @"sourceRPUBytesPreserved":@(_presentedSource && _currentMetadataSubmitted),
        @"sourceRPUPassthrough":@NO, @"receiverDolbyVisionVerified":@NO} mutableCopy];
    [facts addEntriesFromDictionary:_source.facts];
    return facts;
}
- (NSData *)copyPresentedHalfFloats {
    if (_presentedSource || !_presentedPixel || CVPixelBufferLockBaseAddress(_presentedPixel, kCVPixelBufferLock_ReadOnly)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)_width * _height * 8];
    for (int y = 0; y < _height; y++)
        memcpy((char *)data.mutableBytes + (size_t)y*_width*8,
               (char *)CVPixelBufferGetBaseAddress(_presentedPixel) + y*CVPixelBufferGetBytesPerRow(_presentedPixel), (size_t)_width*8);
    CVPixelBufferUnlockBaseAddress(_presentedPixel, kCVPixelBufferLock_ReadOnly);
    return data;
}
- (NSData *)copyPresentedRPU {
    if (!_presentedPixel) return nil;
    CFTypeRef data = CVBufferCopyAttachment(_presentedPixel, CFSTR("DolbyVisionRPUData"), NULL);
    if (!data) return nil;
    if (CFGetTypeID(data) != CFDataGetTypeID()) { CFRelease(data); return nil; }
    return CFBridgingRelease(data);
}
- (NSData *)copyPresentedSourcePlanes {
    if (!_presentedSource || !_presentedPixel || CVPixelBufferLockBaseAddress(_presentedPixel, kCVPixelBufferLock_ReadOnly)) return nil;
    NSMutableData *data = [NSMutableData new];
    for (size_t p = 0; p < 2; p++)
        for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(_presentedPixel, p); y++)
            [data appendBytes:(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(_presentedPixel, p) + y*CVPixelBufferGetBytesPerRowOfPlane(_presentedPixel, p)
                       length:CVPixelBufferGetWidth(_presentedPixel)*2];
    CVPixelBufferUnlockBaseAddress(_presentedPixel, kCVPixelBufferLock_ReadOnly);
    return data;
}
- (NSDictionary *)copyPresentedColorAttachments {
    if (!_presentedPixel) return @{};
    return CFBridgingRelease(CVBufferCopyAttachments(_presentedPixel, kCVAttachmentMode_ShouldPropagate)) ?: @{};
}
- (void)releaseSurface {
    [_source reset];
    _minimumGeneration = 0;
    [self discardActivePixel]; [self resetMetadata];
    [_poolSurfaceIDs removeAllObjects];
    if (_pool) CFRelease(_pool);
    _pool = NULL; _width = _height = 0;
    _statisticsBuffer = nil;
    _backpressureSince = 0;
}
- (void)dealloc {
    // GL names must have been retired with the owning context by releaseSurface.
    if (_activePixel) CFRelease(_activePixel);
    if (_presentedPixel) CFRelease(_presentedPixel);
    if (_pool) CFRelease(_pool);
    if (@available(macOS 15.0, *)) { if (_metadataSession) CFRelease(_metadataSession); }
}
@end
#pragma clang diagnostic pop
