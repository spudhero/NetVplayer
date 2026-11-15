#!/usr/bin/env python3
"""Exercise pinned shared-CoreAudio lifecycle functions with a fake HAL.

The function bodies are read from the selected mpv checkout, not copied into
this test. No CoreAudio framework is linked and no physical device is queried.
"""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile


def function(source: str, name: str) -> str:
    for match in re.finditer(rf"(?m)^(?:static )?(?:bool|void|int|OSStatus)\s+{re.escape(name)}\(", source):
        brace = source.find("{", match.end())
        semicolon = source.find(";", match.end())
        if brace < 0 or (semicolon >= 0 and semicolon < brace):
            continue
        end = source.index("\n}\n", brace) + 3
        return source[match.start():end]
    raise ValueError(f"function not found: {name}")


PREFIX = r'''
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define MP_NUM_CHANNELS 64
#define MP_ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define MPCLAMP(x,l,h) ((x)<(l)?(l):((x)>(h)?(h):(x)))
#define AO_INIT_EXCLUSIVE 1
#define CONTROL_OK 1
#define CONTROL_ERROR -1
#define DISPATCH_QUEUE_SERIAL 0
#define noErr 0
#define kAudioFormatLinearPCM UINT32_C(0x6c70636d)
#define kAudioDevicePropertyStreams 10
#define kAudioStreamPropertyAvailablePhysicalFormats 11
#define kAudioStreamPropertyDirection 12
#define kAudioStreamPropertyPhysicalFormat 13
#define kAudioHardwarePropertyDevices 14
#define kAudioHardwarePropertyDefaultOutputDevice 15
#define kAudioObjectSystemObject 1
#define kAudioObjectPropertyScopeGlobal 0
#define kAudioObjectPropertyElementMain 0
#define CHECK_CA_WARN(message) (err == noErr)
#define CHECK_CA_ERROR(message) do { if (err != noErr) goto coreaudio_error; } while(0)
typedef int OSStatus;
typedef int OSErr;
typedef uint32_t AudioDeviceID;
typedef uint32_t AudioStreamID;
typedef struct {
    double mSampleRate;
    uint32_t mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket;
    uint32_t mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel, mReserved;
} AudioStreamBasicDescription;
typedef struct { double mMinimum, mMaximum; } AudioValueRange;
typedef struct {
    AudioStreamBasicDescription mFormat;
    AudioValueRange mSampleRateRange;
} AudioStreamRangedDescription;
typedef struct { uint32_t mSelector, mScope, mElement; } AudioObjectPropertyAddress;
typedef int AudioChannelLayout;
struct priv {
    AudioDeviceID device;
    AudioStreamBasicDescription original_asbd;
    AudioStreamID original_asbd_stream;
    bool change_physical_format;
    int hotplug_cb_registration_times;
    uint64_t hw_latency_ns;
    void *queue;
};
struct ao {
    struct priv *priv;
    int format, init_flags, samplerate, device_buffer;
    struct { int num; } channels;
    const char *redirect;
};
static struct {
    AudioStreamID streams[2];
    size_t stream_count;
    AudioStreamRangedDescription formats[4];
    size_t format_count;
    AudioStreamBasicDescription physical;
    bool fail_snapshot, chmap_ok, audiounit_ok;
    int failed_changes, changes, snapshot_reads;
    int adds, removes, fail_add, active_listeners;
} hal;
static int failures;
static void log_message(const char *format, ...) { (void)format; }
#define MP_WARN(ao,...) log_message(__VA_ARGS__)
#define MP_ERR(ao,...) log_message(__VA_ARGS__)
#define MP_VERBOSE(ao,...) log_message(__VA_ARGS__)
static char *mp_tag_str(uint32_t tag) { (void)tag; return "test"; }
static void *talloc_new(void *unused) { (void)unused; return &hal; }
static void talloc_free(void *unused) { (void)unused; }
static void talloc_steal(void *parent, void *child) { (void)parent; (void)child; }
static OSStatus fake_array(uint32_t object, uint32_t selector, void *data, size_t *count)
{
    (void)object;
    if (selector == kAudioDevicePropertyStreams) {
        *(AudioStreamID **)data=hal.streams; *count=hal.stream_count;
    } else if (selector == kAudioStreamPropertyAvailablePhysicalFormats) {
        *(AudioStreamRangedDescription **)data=hal.formats; *count=hal.format_count;
    } else return -50;
    return noErr;
}
#define CA_GET_ARY_O(id,sel,data,count) fake_array(id,sel,data,count)
#define CA_GET_ARY(id,sel,data,count) fake_array(id,sel,data,count)
static OSStatus fake_get(uint32_t object, uint32_t selector, void *data)
{
    (void)object;
    if (selector == kAudioStreamPropertyDirection) *(uint32_t *)data=0;
    else if (selector == kAudioStreamPropertyPhysicalFormat) {
        hal.snapshot_reads++;
        if (hal.fail_snapshot) return -50;
        *(AudioStreamBasicDescription *)data=hal.physical;
    } else return -50;
    return noErr;
}
#define CA_GET(id,sel,data) fake_get(id,sel,data)
static void ca_fill_asbd(struct ao *ao, AudioStreamBasicDescription *asbd)
{
    *asbd=(AudioStreamBasicDescription){.mSampleRate=ao->samplerate,
        .mFormatID=kAudioFormatLinearPCM,.mChannelsPerFrame=ao->channels.num,
        .mBitsPerChannel=32,.mBytesPerFrame=4*ao->channels.num,
        .mBytesPerPacket=4*ao->channels.num,.mFramesPerPacket=1};
}
static bool ca_asbd_equals(const AudioStreamBasicDescription *a,
                            const AudioStreamBasicDescription *b)
{
    return a->mSampleRate==b->mSampleRate && a->mFormatID==b->mFormatID &&
           a->mChannelsPerFrame==b->mChannelsPerFrame &&
           a->mBitsPerChannel==b->mBitsPerChannel &&
           a->mBytesPerFrame==b->mBytesPerFrame;
}
static void ca_print_asbd(struct ao *ao, const char *description,
                         const AudioStreamBasicDescription *format)
{ (void)ao; (void)description; (void)format; }
static bool ca_change_physical_format_sync(struct ao *ao, AudioStreamID stream,
                                           AudioStreamBasicDescription desired)
{
    (void)ao; (void)stream;
    hal.changes++;
    hal.physical=desired;
    if (hal.failed_changes) {
        hal.failed_changes--;
        // An error can still leave a partially changed device.
        hal.physical.mSampleRate+=1;
        return false;
    }
    return true;
}
static OSStatus hotplug_cb(uint32_t object, uint32_t count,
                           const AudioObjectPropertyAddress addresses[], void *ctx)
{ (void)object; (void)count; (void)addresses; (void)ctx; return noErr; }
static OSStatus AudioObjectAddPropertyListener(uint32_t object,
        const AudioObjectPropertyAddress *address, void *callback, void *ctx)
{
    (void)object; (void)address; (void)callback; (void)ctx;
    hal.adds++;
    if (hal.adds==hal.fail_add) return -50;
    hal.active_listeners++;
    return noErr;
}
static OSStatus AudioObjectRemovePropertyListener(uint32_t object,
        const AudioObjectPropertyAddress *address, void *callback, void *ctx)
{
    (void)object; (void)address; (void)callback; (void)ctx;
    hal.removes++; hal.active_listeners--;
    return noErr;
}
static bool af_fmt_is_pcm(int format) { return format==1; }
static bool reinit_device(struct ao *ao) { ao->priv->device=1; return true; }
static bool ca_init_chmap(struct ao *ao, uint32_t device)
{ (void)ao; (void)device; return hal.chmap_ok; }
static AudioChannelLayout *ca_get_acl(struct ao *ao, size_t *size)
{ (void)ao; *size=sizeof(AudioChannelLayout); return (void *)&hal; }
static bool init_audiounit(struct ao *ao, AudioStreamBasicDescription asbd,
                           AudioChannelLayout *layout, size_t size)
{ (void)ao; (void)asbd; (void)layout; (void)size; return hal.audiounit_ok; }
static void reinit_latency(struct ao *ao) { ao->priv->hw_latency_ns=0; }
static int64_t av_rescale(int64_t value, int64_t scale, int64_t divisor)
{ return value*scale/divisor; }
static void *dispatch_queue_create(const char *name, int type)
{ (void)name; (void)type; return (void *)&hal; }
static void init_physical_format(struct ao *ao);
static void unregister_hotplug_cb(struct ao *ao);
'''

SUFFIX = r'''
static struct ao reset(struct priv *p)
{
    memset(&hal,0,sizeof(hal));
    *p=(struct priv){.device=1,.change_physical_format=true};
    struct ao ao={.priv=p,.format=1,.samplerate=44100,.channels={8}};
    hal.streams[0]=11; hal.stream_count=1; hal.format_count=1;
    ca_fill_asbd(&ao,&hal.physical); hal.physical.mSampleRate=48000;
    hal.formats[0]=(AudioStreamRangedDescription){.mFormat=hal.physical,
        .mSampleRateRange={8000,192000}};
    hal.chmap_ok=true; hal.audiounit_ok=true;
    return ao;
}
static void expect(const char *name, bool passed)
{
    printf("{\"case\":\"%s\",\"passed\":%s}\n",name,passed?"true":"false");
    if (!passed) failures++;
}
int main(void)
{
    struct priv p; struct ao ao=reset(&p);
    AudioStreamBasicDescription requested, candidate;
    ca_fill_asbd(&ao,&requested);
    expect("continuous-range-selects-source-rate",
        pcm_physical_candidate(&requested,&hal.formats[0],&candidate) && candidate.mSampleRate==44100);
    hal.formats[0].mSampleRateRange=(AudioValueRange){48000,48000};
    expect("fixed-range-keeps-supported-fallback",
        pcm_physical_candidate(&requested,&hal.formats[0],&candidate) && candidate.mSampleRate==48000);
    hal.formats[0].mFormat.mSampleRate=0;
    hal.formats[0].mSampleRateRange=(AudioValueRange){8000,192000};
    expect("zero-format-rate-uses-valid-continuous-range",
        pcm_physical_candidate(&requested,&hal.formats[0],&candidate) && candidate.mSampleRate==44100);
    hal.formats[0].mFormat.mFormatID=UINT32_C(0x63656333);
    expect("compressed-carrier-excluded-from-pcm-selection",
        !pcm_physical_candidate(&requested,&hal.formats[0],&candidate));
    ao=reset(&p); hal.fail_snapshot=true;
    init_physical_format(&ao);
    expect("snapshot-read-failure-never-writes",hal.snapshot_reads==1 && hal.changes==0 && !p.original_asbd.mFormatID);
    ao=reset(&p); hal.physical.mFormatID=0;
    init_physical_format(&ao);
    expect("invalid-original-never-writes",hal.changes==0 && !p.original_asbd.mFormatID);
    ao=reset(&p); ao.samplerate=48000;
    init_physical_format(&ao);
    expect("already-correct-format-never-writes",hal.changes==0 && !p.original_asbd.mFormatID);
    ao=reset(&p);
    init_physical_format(&ao);
    bool switched=hal.physical.mSampleRate==44100 && p.original_asbd.mSampleRate==48000;
    restore_physical_format(&ao);
    expect("normal-release-restores-original",switched && hal.physical.mSampleRate==48000 && hal.changes==2 && !p.original_asbd.mFormatID);
    ao=reset(&p); hal.failed_changes=1;
    init_physical_format(&ao);
    expect("partially-failed-switch-rolls-back",hal.changes==2 && hal.physical.mSampleRate==48000 && !p.original_asbd.mFormatID);
    ao=reset(&p); hal.failed_changes=2;
    init_physical_format(&ao);
    bool retained=p.original_asbd.mFormatID && p.original_asbd.mSampleRate==48000 && p.original_asbd_stream==11;
    restore_physical_format(&ao);
    expect("failed-rollback-retains-snapshot-for-retry",retained && hal.changes==3 && hal.physical.mSampleRate==48000 && !p.original_asbd.mFormatID);
    ao=reset(&p); hal.chmap_ok=false;
    int result=init(&ao);
    expect("channel-map-init-failure-restores-and-unregisters",result<0 && hal.changes==2 && hal.physical.mSampleRate==48000 && !p.original_asbd.mFormatID && !hal.active_listeners && !p.hotplug_cb_registration_times);
    ao=reset(&p); hal.audiounit_ok=false;
    result=init(&ao);
    expect("audiounit-init-failure-restores-and-unregisters",result<0 && hal.changes==2 && hal.physical.mSampleRate==48000 && !p.original_asbd.mFormatID && !hal.active_listeners);
    ao=reset(&p); hal.fail_add=2;
    result=init(&ao);
    expect("partially-failed-listener-registration-unwinds",result<0 && hal.adds==2 && hal.removes==1 && !hal.active_listeners && !p.hotplug_cb_registration_times && !hal.changes);
    ao=reset(&p);
    bool first=register_hotplug_cb(&ao), second=register_hotplug_cb(&ao);
    unregister_hotplug_cb(&ao);
    bool retained_listeners=hal.active_listeners==2 && p.hotplug_cb_registration_times==1;
    unregister_hotplug_cb(&ao); unregister_hotplug_cb(&ao);
    expect("listener-reference-count-remains-balanced",first && second && retained_listeners && hal.adds==2 && hal.removes==2 && !hal.active_listeners && !p.hotplug_cb_registration_times);
    ao=reset(&p); ao.format=2;
    result=init(&ao);
    expect("compressed-input-redirects-without-physical-pcm-write",result<0 && ao.redirect && !strcmp(ao.redirect,"coreaudio_exclusive") && !hal.changes && !hal.adds);
    ao=reset(&p); ao.init_flags=AO_INIT_EXCLUSIVE;
    result=init(&ao);
    expect("exclusive-input-stays-outside-shared-pcm-path",result<0 && ao.redirect && !hal.changes && !hal.adds);
    ao=reset(&p); p.change_physical_format=false; hal.audiounit_ok=false;
    result=init(&ao);
    expect("device-clock-mode-never-writes",result<0 && !hal.changes && !hal.active_listeners);
    return failures?1:0;
}
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpv_source", type=Path)
    args = parser.parse_args()
    coreaudio = (args.mpv_source / "audio/out/ao_coreaudio.c").read_text()
    utils = (args.mpv_source / "audio/out/ao_coreaudio_utils.c").read_text()
    properties = re.search(r"(?ms)^static uint32_t hotplug_properties\[\] = \{.*?^\};", coreaudio)
    if not properties:
        raise ValueError("hotplug property list not found")
    functions = [function(utils, name) for name in ["value_is_better", "ca_asbd_is_better"]]
    functions += [properties.group(0)]
    functions += [function(coreaudio, name) for name in [
        "register_hotplug_cb", "unregister_hotplug_cb", "restore_physical_format",
        "cleanup_init_failure", "pcm_physical_candidate", "init_physical_format", "init",
    ]]
    print('{"sourceSHA256":"' + hashlib.sha256(coreaudio.encode()).hexdigest() + '","scope":"actual lifecycle function bodies with fake HAL; no device or CoreAudio framework"}', flush=True)
    with tempfile.TemporaryDirectory(prefix="netvplayer-ca-pcm-test-") as directory:
        source = Path(directory) / "test.c"
        executable = Path(directory) / "test"
        source.write_text(PREFIX + "\n" + "\n".join(functions) + SUFFIX)
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-sign-compare",
                        str(source), "-o", str(executable)], check=True)
        return subprocess.run([str(executable)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
