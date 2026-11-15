#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Narrow dynamic boundary. No private framework is linked at load time.
NS_SWIFT_UI_ACTOR
@interface NVPictureInPicture : NSObject
@property(class, nonatomic, readonly) BOOL available;
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *event);
- (BOOL)present:(NSViewController *)content window:(NSWindow *)window rect:(NSRect)rect aspect:(NSSize)aspect playing:(BOOL)playing;
- (BOOL)dismiss;
- (void)setPlaying:(BOOL)playing;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
