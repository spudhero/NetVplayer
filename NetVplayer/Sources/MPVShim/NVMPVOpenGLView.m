#import "NVMPVOpenGLView.h"

// libmpv's public macOS render API still requires a current CGL context. Keep
// the deprecated AppKit surface private to this compatibility translation unit.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@class NVMPVOpenGLView;

@interface NVMPVBackingOpenGLView : NSOpenGLView

@property(nonatomic, weak) NVMPVOpenGLView *owner;

@end

static void NVConfigureOpenGLContext(NSOpenGLContext *context) {
    if (!context) {
        return;
    }
    GLint surfaceOrder = (GLint)[NVMPVOpenGLView requiredOpenGLSurfaceOrder];
    [context setValues:&surfaceOrder forParameter:NSOpenGLContextParameterSurfaceOrder];
    GLint swapInterval = 1;
    [context setValues:&swapInterval forParameter:NSOpenGLContextParameterSwapInterval];
}


@implementation NVMPVOpenGLView {
    NVMPVBackingOpenGLView *_backingView;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize,
        24,
        NSOpenGLPFAAlphaSize,
        8,
        0
    };
    NSOpenGLPixelFormat *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    if (!pixelFormat) {
        return self;
    }

    _backingView = [[NVMPVBackingOpenGLView alloc] initWithFrame:self.bounds
                                                    pixelFormat:pixelFormat];
    if (!_backingView) {
        return self;
    }
    _backingView.owner = self;
    _backingView.wantsBestResolutionOpenGLSurface = YES;
    _backingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NVConfigureOpenGLContext(_backingView.openGLContext);
    [self addSubview:_backingView];
    return self;
}

- (BOOL)isOpenGLAvailable {
    return _backingView != nil;
}

- (NSInteger)openGLSurfaceOrder {
    GLint surfaceOrder = 0;
    [_backingView.openGLContext getValues:&surfaceOrder
                             forParameter:NSOpenGLContextParameterSurfaceOrder];
    return surfaceOrder;
}

+ (NSInteger)requiredOpenGLSurfaceOrder {
    return -1;
}

- (void)makeOpenGLContextCurrent {
    [_backingView.openGLContext makeCurrentContext];
}

- (void)updateOpenGLContext {
    [_backingView.openGLContext update];
}

- (void)flushOpenGLBuffer {
    [_backingView.openGLContext flushBuffer];
}

- (void)requestOpenGLDisplay {
    _backingView.needsDisplay = YES;
}

- (void)displayOpenGL {
    [_backingView display];
}

@end


@implementation NVMPVBackingOpenGLView

- (void)prepareOpenGL {
    [super prepareOpenGL];
    [self.openGLContext makeCurrentContext];
    NVConfigureOpenGLContext(self.openGLContext);
    if (self.owner.prepareHandler) {
        self.owner.prepareHandler();
    }
}

- (void)reshape {
    [super reshape];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (self.owner.drawHandler) {
        self.owner.drawHandler();
    }
}

@end

#pragma clang diagnostic pop
