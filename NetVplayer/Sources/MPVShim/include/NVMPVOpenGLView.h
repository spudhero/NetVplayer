#ifndef NETVPLAYER_MPV_OPENGL_VIEW_H
#define NETVPLAYER_MPV_OPENGL_VIEW_H

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NVMPVOpenGLView : NSView

@property(nonatomic, readonly, getter=isOpenGLAvailable) BOOL openGLAvailable;
@property(nonatomic, readonly) NSInteger openGLSurfaceOrder;
+ (NSInteger)requiredOpenGLSurfaceOrder;
@property(nonatomic, copy, nullable) void (^prepareHandler)(void);
@property(nonatomic, copy, nullable) void (^drawHandler)(void);

- (instancetype)initWithFrame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (void)makeOpenGLContextCurrent;
- (void)updateOpenGLContext;
- (void)flushOpenGLBuffer;
- (void)requestOpenGLDisplay;
- (void)displayOpenGL;

@end

NS_ASSUME_NONNULL_END

#endif
