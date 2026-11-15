#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// -1: read failed/unknown; 0: no HDMI/DP hog owned by this process; 1: owned.
FOUNDATION_EXPORT int32_t nv_system_hdr_has_own_hdmi_audio_hog(void);

/// Runtime-only MonitorPanel bridge for directly distributed macOS builds.
/// No private framework is linked and no display mode/refresh rate is forced.
@interface NVSystemHDRDisplayState : NSObject
@property(nonatomic, readonly) uint32_t displayID;
@property(nonatomic, readonly, copy) NSUUID *displayUUID;
@property(nonatomic, readonly) BOOL supportsHDR;
@property(nonatomic, readonly) BOOL prefersHDR;
@property(nonatomic, readonly) BOOL isBuiltin;
@property(nonatomic, readonly, copy) NSString *configurationFingerprint;
@end

@interface NVSystemHDRDisplay : NSObject
+ (nullable NSArray<NVSystemHDRDisplayState *> *)readDisplaysWithError:(NSError **)error;
+ (BOOL)setPrefersHDR:(BOOL)enabled
      forDisplayUUID:(NSUUID *)displayUUID
               error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
