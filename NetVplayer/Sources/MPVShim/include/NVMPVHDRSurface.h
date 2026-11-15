#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Requires the owning mpv CGL context current for allocation/render/release.
/// Product mode uses two bounded slots; AV-03 retains synchronous reference mode.
@interface NVMPVHDRSurface : NSView
/// Metal allocation can fail; keep this separate from NSView's nonnull initializer.
- (nullable instancetype)initWithHDRFrame:(NSRect)frame NS_SWIFT_NAME(init(hdrFrame:));
@property(nonatomic, readonly) int framebuffer;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *facts;
@property(nonatomic) BOOL asynchronousPresentation;
@property(nonatomic) double maximumLinearComponent;
@property(nonatomic, readonly) BOOL temporarilyUnavailable;
- (BOOL)prepareWidth:(int)width height:(int)height;
- (BOOL)present;
/// Test-only explicit Metal readback after presentation; not on playback path.
- (nullable NSData *)copyPresentedHalfFloats;
- (void)releaseSurface NS_SWIFT_NAME(releaseSurface());
@end
NS_ASSUME_NONNULL_END
