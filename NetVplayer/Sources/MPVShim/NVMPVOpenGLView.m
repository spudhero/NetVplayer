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

    [self restoreOpenGLSurface];
    return self;
}

- (void)dealloc {
    [self releaseOpenGLSurface];
}

- (BOOL)restoreOpenGLSurface {
    if (_backingView) {
        return YES;
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
        return NO;
    }

    NVMPVBackingOpenGLView *backingView = [[NVMPVBackingOpenGLView alloc] initWithFrame:self.bounds
                                                                            pixelFormat:pixelFormat];
    if (!backingView) {
        return NO;
    }
    backingView.owner = self;
    backingView.wantsBestResolutionOpenGLSurface = YES;
    backingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NVConfigureOpenGLContext(backingView.openGLContext);
    [self addSubview:backingView];
    _backingView = backingView;
    return YES;
}

- (void)releaseOpenGLSurface {
    NVMPVBackingOpenGLView *backingView = _backingView;
    if (!backingView) {
        return;
    }

    _backingView = nil;
    backingView.owner = nil;
    NSOpenGLContext *context = backingView.openGLContext;
    if ([NSOpenGLContext currentContext] == context) {
        [NSOpenGLContext clearCurrentContext];
    }
    [context clearDrawable];
    [backingView clearGLContext];
    [backingView removeFromSuperview];
}

- (BOOL)isOpenGLAvailable {
    return _backingView != nil && _backingView.openGLContext != nil;
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
