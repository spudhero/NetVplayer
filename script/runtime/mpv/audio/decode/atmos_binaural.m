/* NetVplayer offline HRTF bridge. SPDX-License-Identifier: LGPL-2.1-or-later
 * AVAudioEngine is a DSP graph only: no device, media URL, playback clock or
 * independent audio sink. mpv owns all input, timestamps and output. */
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#include <math.h>
#include <string.h>
#include "atmos_binaural.h"

@interface NVAtmosBinaural : NSObject {
@public
    AVAudioEngine *engine;
    AVAudioEnvironmentNode *environment, *headLocked;
    NSMutableArray<AVAudioSourceNode *> *sources;
    AVAudioPCMBuffer *buffer;
    CMHeadphoneMotionManager *motion;
    CMAttitude *reference;
    float *input[NV_ATMOS_BUSES];
    int inputFrames, consumed[NV_ATMOS_BUSES];
    bool underflow, testOrientation;
    AVAudio3DAngularOrientation orientation;
    struct nv_binaural_status status;
    double lastPose;
}
- (bool)configure:(int)rate tracking:(bool)tracking;
- (void)updatePose;
@end

/* Physical virtual-speaker angles, x right/y up/z behind the listener. LFE
 * has no position; both LFE buses go directly to the main stereo mixer. */
static AVAudio3DPoint position(int channel)
{
    const float azimuth[] = {-30,30,0,0,-150,150,-90,90,-45,45,-135,135};
    float a = azimuth[channel]*M_PI/180;
    float elevation = channel >= 8 ? M_PI/4 : 0;
    return AVAudioMake3DPoint(sinf(a)*cosf(elevation), sinf(elevation), -cosf(a)*cosf(elevation));
}

@implementation NVAtmosBinaural
- (bool)configure:(int)rate tracking:(bool)tracking
{
    engine = [[AVAudioEngine alloc] init];
    environment = [[AVAudioEnvironmentNode alloc] init];
    headLocked = [[AVAudioEnvironmentNode alloc] init];
    sources = [[NSMutableArray alloc] init];
    AVAudioFormat *mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
    AVAudioFormat *stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    for (AVAudioEnvironmentNode *node in @[environment, headLocked]) {
        [engine attachNode:node];
        node.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        node.reverbParameters.enable = NO;
        node.distanceAttenuationParameters.rolloffFactor = 0;
        // Only our explicitly requested motion source controls this DSP graph.
        if (@available(macOS 15.0, *)) node.listenerHeadTrackingEnabled = NO;
        [engine connect:node to:engine.mainMixerNode format:stereo];
    }
    if (![environment.applicableRenderingAlgorithms containsObject:@(AVAudio3DMixingRenderingAlgorithmHRTFHQ)]) {
        [mono release]; [stereo release]; return false;
    }
    for (int c = 0; c < NV_ATMOS_BUSES; c++) {
        // Source blocks do not retain the owner; destroy stops the engine
        // before releasing nodes. Buffers live through this synchronous call.
        void *ownerPointer = self;
        AVAudioSourceNode *node = [[AVAudioSourceNode alloc] initWithFormat:mono renderBlock:
            ^OSStatus(BOOL *silent, const AudioTimeStamp *time, AVAudioFrameCount count, AudioBufferList *list) {
                NVAtmosBinaural *owner = ownerPointer;
                int offset = owner->consumed[c];
                if (offset + count > owner->inputFrames) owner->underflow = true;
                for (unsigned b = 0; b < list->mNumberBuffers; b++) {
                    float *dst = list->mBuffers[b].mData;
                    for (unsigned f = 0; f < count; f++)
                        dst[f] = offset + f < owner->inputFrames ? owner->input[c][offset+f] : 0;
                }
                owner->consumed[c] += count;
                *silent = NO;
                return noErr;
            }];
        [engine attachNode:node];
        if (c % NV_ATMOS_CHANNELS == 3) {
            [engine connect:node to:engine.mainMixerNode format:mono];
        } else {
            // OAMD can mark individual elements as head-locked. A separate
            // fixed listener preserves that rule without counter-rotation or
            // dependence on Apple's internal orientation smoothing.
            [engine connect:node to:c < NV_ATMOS_CHANNELS ? environment : headLocked format:mono];
            node.sourceMode = AVAudio3DMixingSourceModeSpatializeIfMono;
            node.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTFHQ;
            node.reverbBlend = 0;
            node.position = position(c % NV_ATMOS_CHANNELS);
        }
        [sources addObject:node];
        [node release];
    }
    NSError *error = nil;
    bool ok = [engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                  format:stereo maximumFrameCount:TRUEHD_ATMOS_MAX_BLOCK_FRAMES error:&error];
    buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:TRUEHD_ATMOS_MAX_BLOCK_FRAMES];
    [mono release]; [stereo release];
    if (!ok || !buffer || ![engine startAndReturnError:&error]) return false;
    status.tracking_requested = tracking;
    status.pose_age = -1;
    if (tracking && [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMotionUsageDescription"]) {
        motion = [[CMHeadphoneMotionManager alloc] init];
    }
    return true;
}
- (void)updatePose
{
    status.tracking_active = false;
    status.pose_age = -1;
    if (!testOrientation) orientation = AVAudioMake3DAngularOrientation(0,0,0);
    if (motion) {
        // Poll availability again after reconnect; requesting the mode without
        // suitable headphones never counts as active tracking.
        if (motion.deviceMotionAvailable && !motion.deviceMotionActive &&
            [CMHeadphoneMotionManager authorizationStatus] != CMAuthorizationStatusDenied &&
            [CMHeadphoneMotionManager authorizationStatus] != CMAuthorizationStatusRestricted)
            [motion startDeviceMotionUpdates];
        CMDeviceMotion *sample = motion.deviceMotion;
        double age = sample ? NSProcessInfo.processInfo.systemUptime - sample.timestamp : -1;
        if (sample && age >= 0 && age < .5) {
            if (!reference) reference = [sample.attitude copy];
            CMAttitude *relative = [sample.attitude copy];
            [relative multiplyByInverseOfAttitude:reference];
            orientation = AVAudioMake3DAngularOrientation(-relative.yaw*180/M_PI,
                relative.pitch*180/M_PI, -relative.roll*180/M_PI);
            [relative release];
            status.tracking_active = true;
            status.pose_age = age;
            if (sample.timestamp != lastPose) { status.poses++; lastPose = sample.timestamp; }
        } else {
            [reference release]; reference = nil;
        }
    }
    environment.listenerAngularOrientation = orientation;
}
- (void)dealloc
{
    [motion stopDeviceMotionUpdates];
    [engine stop];
    [engine disableManualRenderingMode];
    // Detach source nodes so their copied blocks release captured references
    // before destroying the owner (the blocks deliberately capture a C ptr).
    for (AVAudioSourceNode *node in sources) [engine detachNode:node];
    [sources release]; [buffer release]; [reference release]; [motion release];
    [environment release]; [headLocked release]; [engine release];
    [super dealloc];
}
@end

void *nv_binaural_create(int rate, bool tracking)
{
    @autoreleasepool {
        NVAtmosBinaural *p = nil;
        @try {
            p = [[NVAtmosBinaural alloc] init];
            if ([p configure:rate tracking:tracking]) return p;
        } @catch (NSException *exception) { /* unavailable system AU: fail closed */ }
        [p release];
        return NULL;
    }
}

void nv_binaural_destroy(void *handle) { [(NVAtmosBinaural *)handle release]; }

void nv_binaural_reset(void *handle)
{
    NVAtmosBinaural *p = handle;
    if (!p) return;
    @autoreleasepool {
        [p->engine reset];
        [p->reference release]; p->reference = nil;
        p->status.frames = p->status.poses = 0;
        p->status.tracking_active = false; p->status.pose_age = -1;
        p->lastPose = 0;
    }
}

bool nv_binaural_render(void *handle, float *const planes[NV_ATMOS_BUSES],
                        int frames, float *left, float *right)
{
    NVAtmosBinaural *p = handle;
    if (!p || frames <= 0 || frames > TRUEHD_ATMOS_MAX_BLOCK_FRAMES || !left || !right) return false;
    @autoreleasepool { @try {
        for (int c = 0; c < NV_ATMOS_BUSES; c++) {
            if (!planes[c]) return false;
            p->input[c] = planes[c]; p->consumed[c] = 0;
        }
        p->inputFrames = frames; p->underflow = false;
        [p updatePose];
        NSError *error = nil;
        AVAudioEngineManualRenderingStatus s = [p->engine renderOffline:frames toBuffer:p->buffer error:&error];
        if (s != AVAudioEngineManualRenderingStatusSuccess || p->underflow || p->buffer.frameLength != frames) return false;
        for (int c = 0; c < NV_ATMOS_BUSES; c++) if (p->consumed[c] != frames) return false;
        memcpy(left, p->buffer.floatChannelData[0], frames*sizeof(float));
        memcpy(right, p->buffer.floatChannelData[1], frames*sizeof(float));
        p->status.frames += frames;
        return true;
    } @catch (NSException *exception) { return false; } }
}

void nv_binaural_get_status(void *handle, struct nv_binaural_status *out)
{
    if (out) *out = handle ? ((NVAtmosBinaural *)handle)->status : (struct nv_binaural_status){.pose_age = -1};
    if (handle && out && out->tracking_active) {
        out->pose_age = NSProcessInfo.processInfo.systemUptime - ((NVAtmosBinaural *)handle)->lastPose;
        out->tracking_active = out->pose_age >= 0 && out->pose_age < .5;
    }
}

bool nv_binaural_set_test_orientation(void *handle, float yaw, float pitch, float roll)
{
    NVAtmosBinaural *p = handle;
    if (!p || p->motion || !isfinite(yaw) || !isfinite(pitch) || !isfinite(roll)) return false;
    p->testOrientation = true;
    p->orientation = AVAudioMake3DAngularOrientation(yaw,pitch,roll);
    return true;
}
