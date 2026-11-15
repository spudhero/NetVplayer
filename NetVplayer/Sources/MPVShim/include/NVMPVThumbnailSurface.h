#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A bounded, offscreen surface owned by one thumbnail worker thread.
@interface NVMPVThumbnailSurface : NSObject
- (nullable instancetype)initWithWidth:(int)width height:(int)height;
@property(nonatomic, readonly) int framebuffer;
- (void)makeCurrent;
- (nullable NSData *)pngData;
- (void)close;
@end

NS_ASSUME_NONNULL_END
