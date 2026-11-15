#import "NVMPVThumbnailSurface.h"
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <ImageIO/ImageIO.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@implementation NVMPVThumbnailSurface {
    CGLContextObj _context;
    CGLContextObj _previous;
    GLuint _framebuffer, _texture;
    int _width, _height;
}

- (nullable instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    if (!self || width <= 0 || height <= 0 || width > 512 || height > 512) return nil;
    _width = width; _height = height;
    _previous = CGLGetCurrentContext();
    if (_previous) CGLRetainContext(_previous);
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    CGLError error = CGLChoosePixelFormat(attributes, &format, &count);
    if (error == kCGLNoError && format) error = CGLCreateContext(format, NULL, &_context);
    if (format) CGLReleasePixelFormat(format);
    if (error != kCGLNoError || !_context) return nil;
    [self makeCurrent];
    glGenTextures(1, &_texture);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return nil;
    return self;
}

- (int)framebuffer { return (int)_framebuffer; }
- (void)makeCurrent { if (_context) CGLSetCurrentContext(_context); }

- (nullable NSData *)pngData {
    if (!_context || !_framebuffer) return nil;
    [self makeCurrent];
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)_width * _height * 4];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, _width, _height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.mutableBytes);
    if (glGetError() != GL_NO_ERROR) return nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(_width, _height, 8, 32, _width * 4, space,
        kCGBitmapByteOrder32Big | kCGImageAlphaLast, provider, NULL, false, kCGRenderingIntentDefault);
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef destination = image ? CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL) : NULL;
    bool complete = false;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        complete = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    if (image) CGImageRelease(image);
    if (space) CGColorSpaceRelease(space);
    if (provider) CGDataProviderRelease(provider);
    return complete ? png : nil;
}

- (void)close {
    if (_context) {
        [self makeCurrent];
        if (_framebuffer) glDeleteFramebuffers(1, &_framebuffer);
        if (_texture) glDeleteTextures(1, &_texture);
        CGLSetCurrentContext(_previous);
        CGLReleaseContext(_context);
        _context = NULL; _framebuffer = 0; _texture = 0;
    }
    if (_previous) { CGLReleaseContext(_previous); _previous = NULL; }
}
- (void)dealloc { [self close]; }
@end

#pragma clang diagnostic pop
