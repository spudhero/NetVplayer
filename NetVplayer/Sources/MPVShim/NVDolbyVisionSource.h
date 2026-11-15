#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

/// Owns a bounded copy of one untouched decoded frame. No decoder or clock.
@interface NVDolbyVisionSource : NSObject
@property(nonatomic, readonly) CVPixelBufferRef pixel;
@property(nonatomic, readonly) double pts;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) NSDictionary *facts;
- (void)beginFrame;
- (BOOL)captureFrame:(const void *)frame pts:(double)pts generation:(uint64_t)generation compatibility:(int)compatibility;
- (void)reset;
@end
