#import "NVMPVHDRSurface.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLIOSurface.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// All slot access is on the owning CGL/main thread. A pending command retains
// its textures; slots cannot be overwritten, resized or destroyed before it ends.
@interface NVMPVHDRSlot : NSObject {
@public
    IOSurfaceRef surface;
    GLuint fbo, glTexture;
    id<MTLTexture> texture;
    id<MTLCommandBuffer> command;
}
@end
@implementation NVMPVHDRSlot
- (void)dealloc { if (surface) CFRelease(surface); }
@end

@implementation NVMPVHDRSurface {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    NSArray<NVMPVHDRSlot *> *_slots;
    NVMPVHDRSlot *_active;
    id<MTLTexture> _presentedTexture;
    id<MTLCommandBuffer> _presentedCommand;
    CAMetalLayer *_metalLayer;
    int _width, _height, _redBits, _componentType;
    NSUInteger _frames, _busyFrames, _maximumInFlight;
    double _glWaitMS, _metalWaitMS, _drawableWaitMS, _presentMS, _gpuMS;
    BOOL _temporarilyUnavailable;
}
@synthesize asynchronousPresentation = _asynchronousPresentation;
@synthesize maximumLinearComponent = _maximumLinearComponent;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    if (!_queue) return nil;
    _maximumLinearComponent = 1;
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
    _metalLayer.framebufferOnly = NO;
    _metalLayer.maximumDrawableCount = 2;
    _metalLayer.wantsExtendedDynamicRangeContent = YES;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    _metalLayer.colorspace = space;
    CGColorSpaceRelease(space);
    self.wantsLayer = YES;
    self.layer = _metalLayer;
    return self;
}
- (void)setAsynchronousPresentation:(BOOL)value {
    if (_asynchronousPresentation == value) return;
    [self releaseSurface];
    _asynchronousPresentation = value;
    if (!value || _pipeline) return;
    // The shader caps only video-layer highlights, preserves negative wide-gamut
    // values and 1x subtitle white. The compositor converts the linear RGB tag.
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 hdrVertex(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment half4 hdrFragment(float4 p [[position]], texture2d<half,access::read> image [[texture(0)]], constant float &ceiling [[buffer(0)]]) { half4 c=image.read(uint2(p.xy)); return half4(min(c.rgb,half3(ceiling)),c.a); }";
    id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:nil];
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"hdrVertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"hdrFragment"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    if (desc.vertexFunction && desc.fragmentFunction) _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:nil];
}
- (int)framebuffer { return _active ? (int)_active->fbo : 0; }
- (BOOL)temporarilyUnavailable { return _temporarilyUnavailable; }
- (NSUInteger)inFlightCount {
    NSUInteger count = 0;
    for (NVMPVHDRSlot *slot in _slots) {
        if (slot->command && slot->command.status < MTLCommandBufferStatusCompleted) count++;
    }
    return count;
}
- (BOOL)prepareWidth:(int)width height:(int)height {
    _temporarilyUnavailable = NO;
    if (!CGLGetCurrentContext() || (_asynchronousPresentation && !_pipeline)) return NO;
    for (NVMPVHDRSlot *slot in _slots) {
        if (slot->command.status == MTLCommandBufferStatusError) return NO;
        if (slot->command.status == MTLCommandBufferStatusCompleted)
            _gpuMS = (slot->command.GPUEndTime-slot->command.GPUStartTime)*1000;
    }
    if (width != _width || height != _height || !_slots.count) {
        [self releaseSurface];
        NSUInteger count = _asynchronousPresentation ? 2 : 1;
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return NO;
        size_t stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 8);
        if ((uint64_t)stride * height * count > 128 * 1024 * 1024) return NO;
        NSMutableArray *slots = [NSMutableArray new];
        // Publish partial allocations so every failure is cleaned with this CGL.
        for (NSUInteger i=0; i<count; i++) {
            NVMPVHDRSlot *slot = [NVMPVHDRSlot new];
            [slots addObject:slot]; _slots = [slots copy];
            slot->surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
                (id)kIOSurfaceWidth:@(width), (id)kIOSurfaceHeight:@(height),
                (id)kIOSurfaceBytesPerElement:@8, (id)kIOSurfaceBytesPerRow:@(stride),
                (id)kIOSurfaceAllocSize:@(stride*height), (id)kIOSurfacePixelFormat:@((uint32_t)0x52476841)});
            if (!slot->surface) { [self releaseSurface]; return NO; }
            glGenTextures(1, &slot->glTexture);
            glBindTexture(GL_TEXTURE_RECTANGLE, slot->glTexture);
            CGLError code = CGLTexImageIOSurface2D(CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE,
                GL_RGBA16F, width, height, GL_RGBA, GL_HALF_FLOAT, slot->surface, 0);
            glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glBindTexture(GL_TEXTURE_RECTANGLE, 0);
            glGenFramebuffers(1, &slot->fbo);
            glBindFramebuffer(GL_FRAMEBUFFER, slot->fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, slot->glTexture, 0);
            glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE, &_redBits);
            glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE, &_componentType);
            BOOL complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:width height:height mipmapped:NO];
            desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
            slot->texture = [_device newTextureWithDescriptor:desc iosurface:slot->surface plane:0];
            if (code != kCGLNoError || !complete || _redBits != 16 || _componentType != GL_FLOAT || !slot->texture) {
                [self releaseSurface]; return NO;
            }
        }
        _width = width; _height = height;
        _metalLayer.drawableSize = CGSizeMake(width, height);
    }
    _active = nil;
    for (NVMPVHDRSlot *slot in _slots) {
        if (!slot->command || slot->command.status == MTLCommandBufferStatusCompleted) {
            slot->command = nil; _active = slot; break;
        }
    }
    if (!_active) { _temporarilyUnavailable = YES; _busyFrames++; return NO; }
    return YES;
}
- (BOOL)present {
    if (!_active || !_active->texture) return NO;
    double presentBegin = CACurrentMediaTime();
    double begin = presentBegin;
    // Public GL/Metal IOSurface APIs do not provide a shared cross-API fence.
    // Complete GL writes before Metal reads; do not remove this synchronization.
    glFinish();
    _glWaitMS = (CACurrentMediaTime()-begin)*1000;
    begin = CACurrentMediaTime();
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    _drawableWaitMS = (CACurrentMediaTime()-begin)*1000;
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    if (!drawable || !command) return NO;
    if (_asynchronousPresentation) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder) return NO;
        float ceiling = (float)fmax(1, fmin(10000.0/203, _maximumLinearComponent));
        [encoder setRenderPipelineState:_pipeline];
        [encoder setFragmentTexture:_active->texture atIndex:0];
        [encoder setFragmentBytes:&ceiling length:sizeof(ceiling) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    } else {
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!blit) return NO;
        [blit copyFromTexture:_active->texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(_width,_height,1) toTexture:drawable.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];
    }
    [command presentDrawable:drawable];
    begin = CACurrentMediaTime();
    _active->command = command;
    [command commit];
    _maximumInFlight = MAX(_maximumInFlight, [self inFlightCount]);
    if (!_asynchronousPresentation) [command waitUntilCompleted];
    _metalWaitMS = _asynchronousPresentation ? 0 : (CACurrentMediaTime()-begin)*1000;
    if (command.status == MTLCommandBufferStatusError) return NO;
    _presentedTexture = drawable.texture; _presentedCommand = command;
    _frames++;
    _presentMS = (CACurrentMediaTime()-presentBegin)*1000;
    return YES;
}
- (NSData *)copyPresentedHalfFloats {
    if (!_presentedTexture) return nil;
    [_presentedCommand waitUntilCompleted];
    if (_presentedCommand.status != MTLCommandBufferStatusCompleted) return nil;
    NSUInteger stride = _width * 8;
    id<MTLBuffer> buffer = [_device newBufferWithLength:stride*_height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!buffer || !command || !blit) return nil;
    [blit copyFromTexture:_presentedTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(_width,_height,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride*_height];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) return nil;
    return [NSData dataWithBytes:buffer.contents length:stride*_height];
}
- (NSDictionary *)facts {
    NSUInteger bytes=0;
    for (NVMPVHDRSlot *slot in _slots) if (slot->surface) bytes += IOSurfaceGetAllocSize(slot->surface);
    return @{@"width":@(_width), @"height":@(_height), @"glRedBits":@(_redBits),
        @"glComponentType":@(_componentType), @"metalPixelFormat":@(_active ? _active->texture.pixelFormat : 0),
        @"drawablePixelFormat":@(_presentedTexture.pixelFormat), @"surfaceBytes":@(bytes),
        @"presentedFrames":@(_frames), @"glFinishMS":@(_glWaitMS), @"metalWaitMS":@(_metalWaitMS),
        @"drawableWaitMS":@(_drawableWaitMS), @"hostPresentMS":@(_presentMS),
        @"metalPassGPUMS":@(_gpuMS), @"metalBlitGPUMS":@(_gpuMS),
        @"colorSpace":@"extendedLinearSRGB", @"edrRequested":@(_metalLayer.wantsExtendedDynamicRangeContent),
        @"layerAttached":@(_metalLayer.superlayer != nil), @"layerHidden":@(_metalLayer.hidden),
        @"windowVisible":@(self.window.isVisible), @"windowOccluded":@(!(self.window.occlusionState & NSWindowOcclusionStateVisible)),
        @"cpuPixelCopiesPerFrame":@0, @"gpuBlitsPerFrame":@(_asynchronousPresentation ? 0 : 1),
        @"gpuRenderPassesPerFrame":@(_asynchronousPresentation ? 1 : 0),
        @"inFlightFrames":@([self inFlightCount]), @"maximumObservedInFlightFrames":@(_maximumInFlight),
        @"surfaceCount":@(_slots.count), @"busyFrames":@(_busyFrames), @"maximumDrawableCount":@2,
        @"asynchronousPresentation":@(_asynchronousPresentation), @"hasPipeline":@(_pipeline != nil), @"maximumLinearComponent":@(_maximumLinearComponent)};
}
- (void)releaseSurface {
    // Used only on resize, fallback and teardown. Ordinary product frames never
    // wait for Metal on the CPU; a busy ring asks the render gate to try again.
    for (NVMPVHDRSlot *slot in _slots) [slot->command waitUntilCompleted];
    _presentedTexture = nil; _presentedCommand = nil; _active = nil;
    for (NVMPVHDRSlot *slot in _slots) {
        if (slot->fbo) glDeleteFramebuffers(1, &slot->fbo);
        if (slot->glTexture) glDeleteTextures(1, &slot->glTexture);
        slot->fbo = slot->glTexture = 0;
    }
    _slots = nil; _width = _height = 0;
}
@end
#pragma clang diagnostic pop
