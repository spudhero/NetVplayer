/* NetVplayer HDMI transport matching. Original implementation; no reference
 * player code is included. See Docs/hdmi_earc_comparison_20261018.md.
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef NETVPLAYER_COREAUDIO_HDMI_H
#define NETVPLAYER_COREAUDIO_HDMI_H

#include <CoreAudio/CoreAudio.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>

enum nv_ca_hdmi_codec {
    NV_CA_HDMI_LEGACY,
    NV_CA_HDMI_EAC3,
    NV_CA_HDMI_TRUEHD,
    NV_CA_HDMI_DTSHD_MA,
};

/* Keep private driver IDs local to a codec-specific transport. In particular,
 * do not normalize cc+3/cd+3/mtc+/mtct to AC3 or infer payload compatibility
 * from equal byte rates. cec3 was observed with the same EAC3/JOC fixture on
 * this HDMI endpoint. Independent receiver tests qualified mtct for both
 * TrueHD/MAT and full DTS-HD MA type IV at the exact geometry below. Each
 * codec still requires its own explicit AO opt-in; other endpoints and HRA's
 * two-word logical transport remain unqualified. This does not encode PCM or
 * objects into MAT, and DTS-HD MA receiver evidence does not verify DTS:X. */
static inline int nv_ca_hdmi_rank(enum nv_ca_hdmi_codec codec, int rate,
                                 int channels, int stride,
                                 const AudioStreamBasicDescription *f)
{
    if (rate <= 0 || channels <= 0 || stride != channels * 2 ||
        f->mBitsPerChannel != 16 ||
        (f->mFormatFlags & (kAudioFormatFlagIsFloat |
                           kAudioFormatFlagIsBigEndian |
                           kAudioFormatFlagIsNonInterleaved)))
        return 0;

    if (f->mFormatID == 'cec3') {
        return codec == NV_CA_HDMI_EAC3 && rate == 192000 && channels == 2 &&
               f->mSampleRate == 192000 && f->mChannelsPerFrame == 2 &&
               f->mBytesPerFrame == 4 && f->mFramesPerPacket == 6144 &&
               f->mBytesPerPacket == 24576 &&
               (f->mFormatFlags & (kAudioFormatFlagIsSignedInteger |
                                  kAudioFormatFlagIsPacked)) ==
                   (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
               ? 2 : 0;
    }

    if (f->mFormatID == 'mtct') {
        // The ASBD packet size describes the driver, not the input codec's
        // burst size. MAT uses 61440-byte bursts; the verified DTS IV fixture
        // uses 32768-byte bursts. Both are continuous 3072000-byte/s transport
        // streams. Preserve the decoder's stride and do not repacketize them.
        return (codec == NV_CA_HDMI_TRUEHD || codec == NV_CA_HDMI_DTSHD_MA) &&
               rate == 192000 && channels == 8 &&
               f->mSampleRate == 768000 && f->mChannelsPerFrame == 2 &&
               f->mFormatFlags == 76 && f->mBytesPerFrame == 4 &&
               f->mFramesPerPacket == 15360 && f->mBytesPerPacket == 61440
               ? 2 : 0;
    }

    // Equal byte rates do not qualify another private ID or a legacy sink.
    if (codec == NV_CA_HDMI_TRUEHD || codec == NV_CA_HDMI_DTSHD_MA)
        return 0;

    switch (f->mFormatID) {
    case 'IAC3': case 'iac3': case kAudioFormat60958AC3: case kAudioFormatAC3:
        return f->mSampleRate == rate && f->mChannelsPerFrame == (UInt32)channels &&
               f->mBytesPerFrame == (UInt32)stride ? 1 : 0;
    default:
        return 0;
    }
}

/* FFmpeg can keep DTS type IV framing while silently stripping HD extensions
 * when a packet exceeds the selected carrier capacity. An encoded-output label
 * is therefore insufficient. Compare every original packet, including any HD
 * and object metadata, against the word-swapped IEC payload before release.
 * This helper does not decode, reinterpret or mutate the compressed stream. */
static inline bool nv_ca_hdmi_dtshd_payload_matches(
    const uint8_t *wire, int bytes, const uint8_t *packet, int packet_bytes)
{
    if (!wire || !packet || bytes < 20 || packet_bytes <= 0 ||
        packet_bytes > UINT16_MAX || wire[0] != 0x72 || wire[1] != 0xf8 ||
        wire[2] != 0x1f || wire[3] != 0x4e || wire[4] != 0x11 || wire[5] > 5)
        return false;
    unsigned burst_bytes = (512U << wire[5]) * 4;
    unsigned declared = wire[6] | ((unsigned)wire[7] << 8);
    unsigned payload_bytes = wire[18] | ((unsigned)wire[19] << 8);
    if ((unsigned)bytes != burst_bytes || payload_bytes != (unsigned)packet_bytes ||
        declared < payload_bytes + 12 || declared > burst_bytes - 8 ||
        20U + ((payload_bytes + 1) & ~1U) > burst_bytes)
        return false;
    const uint8_t header[10] = {0, 1, 0, 0, 0, 0, 0, 0, 0xfe, 0xfe};
    for (unsigned i = 0; i < sizeof(header); i++)
        if (wire[8 + i] != header[i])
            return false;
    for (unsigned i = 0; i < payload_bytes; i++)
        if (wire[20 + (i ^ 1U)] != packet[i])
            return false;
    return true;
}

/* HAL requests bytes, while ao_read_data counts mpv logical transport frames.
 * In particular, using the mtct HAL stride (4) instead of the HBR logical
 * stride (16) would consume four times the data and advance the clock 4x. */
static inline int nv_ca_hdmi_logical_frames(int stride, uint32_t bytes)
{
    if (stride <= 0 || bytes % stride || bytes / stride > INT_MAX)
        return -1;
    return bytes / stride;
}

/* Device/stream latency properties count carrier frames, not mpv's logical
 * frames. Use the verified virtual/physical rate without changing the AO. */
static inline int64_t nv_ca_hdmi_carrier_frames_to_ns(
    uint64_t frames, const AudioStreamBasicDescription *carrier)
{
    if (!carrier || !(carrier->mSampleRate > 0) ||
        carrier->mSampleRate > 768000)
        return -1;
    long double duration = frames * 1000000000.0L / carrier->mSampleRate;
    if (duration >= (long double)INT64_MAX)
        return -1;
    return duration;
}

/* Physical AND virtual readback must describe the selected encoded carrier.
 * Matching only rate/channels can accidentally accept an ordinary LPCM sink. */
static inline bool nv_ca_hdmi_asbd_equal(const AudioStreamBasicDescription *a,
                                       const AudioStreamBasicDescription *b)
{
    return a->mFormatID == b->mFormatID && a->mSampleRate == b->mSampleRate &&
           a->mFormatFlags == b->mFormatFlags &&
           a->mChannelsPerFrame == b->mChannelsPerFrame &&
           a->mBitsPerChannel == b->mBitsPerChannel &&
           a->mBytesPerFrame == b->mBytesPerFrame &&
           a->mBytesPerPacket == b->mBytesPerPacket &&
           a->mFramesPerPacket == b->mFramesPerPacket;
}
#endif
