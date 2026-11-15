#import "include/NVSystemHDRDisplay.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreAudio/CoreAudio.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

int32_t nv_system_hdr_has_own_hdmi_audio_hog(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr
        || size > 1024 * 1024 || size % sizeof(AudioDeviceID)) return -1;
    if (!size) return -1; // An empty/hidden hardware list cannot prove release.
    AudioDeviceID *devices = calloc(1, size);
    if (!devices) return -1;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) {
        free(devices);
        return -1;
    }
    BOOL unknown = NO;
    int32_t result = 0;
    for (UInt32 i = 0; i < size / sizeof(AudioDeviceID); i++) {
        UInt32 transport = 0, propertySize = sizeof(transport);
        address.mSelector = kAudioDevicePropertyTransportType;
        if (AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &propertySize, &transport) != noErr) {
            unknown = YES;
            continue;
        }
        if (transport != kAudioDeviceTransportTypeHDMI && transport != kAudioDeviceTransportTypeDisplayPort) continue;
        pid_t pid = -1;
        propertySize = sizeof(pid);
        address.mSelector = kAudioDevicePropertyHogMode;
        if (AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &propertySize, &pid) != noErr) {
            unknown = YES;
            continue;
        }
        if (pid == getpid()) { result = 1; break; }
    }
    free(devices);
    return result ? 1 : (unknown ? -1 : 0);
}

// Independent typed declarations; only standard Objective-C runtime discovery
// touches the private framework. Reject signature changes before sending a message.
@protocol NVHDRRuntimeDisplay <NSObject>
- (int)displayID;
- (NSUUID *)uuid;
- (BOOL)hasHDRModes;
- (BOOL)preferHDRModes;
- (void)setPreferHDRModes:(BOOL)enabled;
@end

@protocol NVHDRRuntimeManager <NSObject>
- (NSArray *)displays;
@end

@interface NVSystemHDRDisplayState ()
@property(nonatomic) uint32_t displayID;
@property(nonatomic, copy) NSUUID *displayUUID;
@property(nonatomic) BOOL supportsHDR;
@property(nonatomic) BOOL prefersHDR;
@property(nonatomic) BOOL isBuiltin;
@property(nonatomic, copy) NSString *configurationFingerprint;
@end
@implementation NVSystemHDRDisplayState
@end

static BOOL NVHDRFail(NSError **error, NSInteger code, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"NetVplayer.SystemHDR" code:code
                                      userInfo:@{NSLocalizedDescriptionKey:reason}];
    return NO;
}

static BOOL NVHDRMethodMatches(Class cls, SEL selector, const char *returnType,
                                unsigned int argumentCount, const char *lastArgument) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != argumentCount) return NO;
    char *result = method_copyReturnType(method);
    BOOL matches = result && strcmp(result, returnType) == 0;
    free(result);
    if (matches && lastArgument) {
        char *argument = method_copyArgumentType(method, argumentCount - 1);
        matches = argument && strcmp(argument, lastArgument) == 0;
        free(argument);
    }
    return matches;
}

static id<NVHDRRuntimeManager> NVHDRManager(NSError **error) {
#if defined(NETVPLAYER_APP_STORE)
    NVHDRFail(error, 1, @"System HDR control is unavailable in this distribution.");
    return nil;
#else
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
                           RTLD_LAZY | RTLD_LOCAL);
    });
    Class managerClass = framework ? NSClassFromString(@"MPDisplayMgr") : Nil;
    Class displayClass = framework ? NSClassFromString(@"MPDisplay") : Nil;
    BOOL compatible = managerClass && displayClass
        && NVHDRMethodMatches(managerClass, @selector(displays), @encode(id), 2, NULL)
        && NVHDRMethodMatches(displayClass, @selector(displayID), @encode(int), 2, NULL)
        && NVHDRMethodMatches(displayClass, @selector(uuid), @encode(id), 2, NULL)
        && NVHDRMethodMatches(displayClass, @selector(hasHDRModes), @encode(BOOL), 2, NULL)
        && NVHDRMethodMatches(displayClass, @selector(preferHDRModes), @encode(BOOL), 2, NULL)
        && NVHDRMethodMatches(displayClass, @selector(setPreferHDRModes:), @encode(void), 3, @encode(BOOL));
    if (!compatible) {
        NVHDRFail(error, 2, @"The system HDR interface is unavailable or incompatible.");
        return nil;
    }
    return [[managerClass alloc] init];
#endif
}

static NSString *NVHDRFingerprint(CGDirectDisplayID displayID) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    if (!mode) return nil;
    // HDR preference can legitimately change pixel encoding/mode number. Keep
    // geometry, scale, refresh and rotation to detect unrelated user changes.
    NSString *fingerprint = [NSString stringWithFormat:@"%zux%zu:%zux%zu:%.3f:%.1f",
        CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
        CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode),
        CGDisplayModeGetRefreshRate(mode), CGDisplayRotation(displayID)];
    CGDisplayModeRelease(mode);
    return fingerprint;
}

@implementation NVSystemHDRDisplay
+ (NSArray<NVSystemHDRDisplayState *> *)readDisplaysWithError:(NSError **)error {
    @try {
        id<NVHDRRuntimeManager> manager = NVHDRManager(error);
        if (!manager) return nil;
        NSArray *displays = [manager displays];
        if (![displays isKindOfClass:NSArray.class]) {
            NVHDRFail(error, 3, @"The system returned an invalid display list.");
            return nil;
        }
        NSMutableArray *result = [NSMutableArray array];
        Class displayClass = NSClassFromString(@"MPDisplay");
        for (id object in displays) {
            if (![object isKindOfClass:displayClass]) continue;
            id<NVHDRRuntimeDisplay> display = object;
            int displayID = [display displayID];
            NSUUID *uuid = [display uuid];
            if (displayID == 0 || ![uuid isKindOfClass:NSUUID.class]
                || !CGDisplayIsOnline((CGDirectDisplayID)displayID)) continue;
            NSString *fingerprint = NVHDRFingerprint((CGDirectDisplayID)displayID);
            if (!fingerprint) continue;
            NVSystemHDRDisplayState *state = [NVSystemHDRDisplayState new];
            state.displayID = (uint32_t)displayID;
            state.displayUUID = uuid;
            state.supportsHDR = [display hasHDRModes];
            state.prefersHDR = [display preferHDRModes];
            state.isBuiltin = CGDisplayIsBuiltin((CGDirectDisplayID)displayID);
            state.configurationFingerprint = fingerprint;
            [result addObject:state];
        }
        return result;
    } @catch (NSException *exception) {
        NVHDRFail(error, 4, @"The system HDR interface could not read the display configuration.");
        return nil;
    }
}

+ (BOOL)setPrefersHDR:(BOOL)enabled forDisplayUUID:(NSUUID *)displayUUID error:(NSError **)error {
    @try {
        id<NVHDRRuntimeManager> manager = NVHDRManager(error);
        if (!manager) return NO;
        for (id object in [manager displays]) {
            if (![object isKindOfClass:NSClassFromString(@"MPDisplay")]) continue;
            id<NVHDRRuntimeDisplay> display = object;
            NSUUID *uuid = [display uuid];
            int displayID = [display displayID];
            if (![uuid isKindOfClass:NSUUID.class] || ![uuid isEqual:displayUUID]
                || displayID == 0 || !CGDisplayIsOnline((CGDirectDisplayID)displayID)) continue;
            if (CGDisplayIsBuiltin((CGDirectDisplayID)displayID)) return NVHDRFail(error, 8, @"Built-in displays use the public EDR rendering path.");
            if (![display hasHDRModes]) return NVHDRFail(error, 5, @"This display mode does not support HDR control.");
            if ([display preferHDRModes] != enabled) [display setPreferHDRModes:enabled];
            // This is a submitted request. Swift verifies the actual preference
            // and EDR rendering separately after display reconfiguration.
            return YES;
        }
        return NVHDRFail(error, 6, @"The HDR display is no longer connected.");
    } @catch (NSException *exception) {
        return NVHDRFail(error, 7, @"The system HDR interface could not change the display preference.");
    }
}
@end
