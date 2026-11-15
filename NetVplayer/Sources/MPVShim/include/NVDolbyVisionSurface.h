#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
void nv_mpv_capture_dolby_source(void * _Nullable opaque, const void * _Nullable frame, double pts, uint64_t generation);
/// Experimental system presentation of regenerated P8.4 or eligible source RPU.
/// All methods require the owning main thread and CGL context. mpv remains the
/// sole media clock; this view accepts only frames already scheduled by mpv.
@interface NVDolbyVisionSurface : NSView
@property(class, nonatomic, readonly) BOOL available;
@property(nonatomic) double framesPerSecond;
/// Independent opt-in. Zero compatibility rejects unverified/P5/P7 input.
@property(nonatomic) BOOL sourceMetadataEnabled;
@property(nonatomic) int sourceCompatibility;
@property(nonatomic, readonly) int framebuffer;
@property(nonatomic, readonly) BOOL temporarilyUnavailable;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *facts;
+ (nullable instancetype)surfaceWithFrame:(NSRect)frame NS_SWIFT_NAME(make(frame:));
- (BOOL)prepareWidth:(int)width height:(int)height;
- (BOOL)presentPTS:(double)pts generation:(uint64_t)generation;
- (void)invalidateBeforeGeneration:(uint64_t)generation NS_SWIFT_NAME(invalidate(beforeGeneration:));
- (void)releaseSurface NS_SWIFT_NAME(releaseSurface());
/// Development readback only. Returns the HLG RGB half floats actually submitted.
- (nullable NSData *)copyPresentedHalfFloats;
- (nullable NSData *)copyPresentedRPU;
/// Canonical packed P010 source planes, for development verification only.
- (nullable NSData *)copyPresentedSourcePlanes;
- (NSDictionary *)copyPresentedColorAttachments;
@end
NS_ASSUME_NONNULL_END
