// Pure transport-policy regression; does not open or change an audio device.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "coreaudio_hdmi.h"

static void test_dts_core(void)
{
    // AF_FORMAT_S_DTS uses NV_CA_HDMI_LEGACY in the strict AO. This is an
    // offline carrier fixture, not a claim that a receiver accepted DTS.
    AudioStreamBasicDescription core = {
        .mFormatID = kAudioFormat60958AC3, .mSampleRate = 48000,
        .mFormatFlags = 76, .mChannelsPerFrame = 2, .mBitsPerChannel = 16,
        .mBytesPerFrame = 4, .mFramesPerPacket = 1536, .mBytesPerPacket = 6144,
    };
    assert(core.mFormatID == 'cac3');
    assert(nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &core) == 1);
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 44100, 2, 4, &core));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 8, 16, &core));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 8, &core));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 2, 4, &core));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 8, 16, &core));

    AudioStreamBasicDescription changed = core;
    changed.mSampleRate = 44100;
    assert(nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 44100, 2, 4, &changed) == 1);
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    // mpv's DTS core transport chooses 44.1k or 48k, not the 32k cac3 mode.
    changed.mSampleRate = 32000;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 44100, 2, 4, &changed));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    changed = core; changed.mChannelsPerFrame = 8;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    changed = core; changed.mBytesPerFrame = 16;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    changed = core; changed.mBitsPerChannel = 24;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    const unsigned bad_flags[] = {kAudioFormatFlagIsFloat,
        kAudioFormatFlagIsBigEndian, kAudioFormatFlagIsNonInterleaved};
    for (unsigned i = 0; i < sizeof(bad_flags) / sizeof(*bad_flags); i++) {
        changed = core; changed.mFormatFlags |= bad_flags[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    }

    const AudioFormatID private_ids[] = {
        'cec3', 'cc+3', 'cd+3', 'mtct', 'mtc+', 'lpcm',
    };
    for (unsigned i = 0; i < sizeof(private_ids) / sizeof(*private_ids); i++) {
        changed = core; changed.mFormatID = private_ids[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 48000, 2, 4, &changed));
    }

    // A carrier's advertised packet geometry is preserved and compared in
    // full during physical/virtual readback. It is not rewritten to match
    // each DTS I/II/III burst's 512/1024/2048 decoded-sample period.
    changed = core; changed.mFramesPerPacket = 1024;
    assert(!nv_ca_hdmi_asbd_equal(&core, &changed));
    changed = core; changed.mBytesPerPacket = 4096;
    assert(!nv_ca_hdmi_asbd_equal(&core, &changed));
    const unsigned periods[] = {512, 1024, 2048};
    for (unsigned i = 0; i < sizeof(periods) / sizeof(*periods); i++) {
        unsigned bytes = periods[i] * 4;
        assert(nv_ca_hdmi_logical_frames(4, bytes) == (int)periods[i]);
    }
    assert(core.mSampleRate * core.mBytesPerFrame == 192000);

    // The legacy path cannot opt a DTS-HD transport into high-rate private
    // carriers. Full MA requires its separate, explicitly enabled HBR path.
    changed = core; changed.mFormatID = 'cec3'; changed.mSampleRate = 192000;
    changed.mFramesPerPacket = 6144; changed.mBytesPerPacket = 24576;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 2, 4, &changed));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 8, 16, &changed));
    changed = core; changed.mFormatID = 'mtct'; changed.mSampleRate = 768000;
    changed.mFramesPerPacket = 15360; changed.mBytesPerPacket = 61440;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 2, 4, &changed));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 8, 16, &changed));
}

static void test_dtshd_ma(void)
{
    AudioStreamBasicDescription carrier = {
        .mFormatID = 'mtct', .mSampleRate = 768000,
        .mFormatFlags = 76, .mChannelsPerFrame = 2, .mBitsPerChannel = 16,
        .mBytesPerFrame = 4, .mFramesPerPacket = 15360, .mBytesPerPacket = 61440,
    };
    assert(nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &carrier) == 2);
    // HRA / a low-capacity two-word route has not been qualified by this test.
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 2, 4, &carrier));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 768000, 2, 4, &carrier));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 176400, 8, 16, &carrier));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 4, &carrier));
    const AudioFormatID rejected[] = {
        'mtc+', 'cec3', 'cc+3', 'cd+3', 'lpcm', 'IAC3', 'iac3',
        kAudioFormat60958AC3, kAudioFormatAC3,
    };
    for (unsigned i = 0; i < sizeof(rejected) / sizeof(*rejected); i++) {
        AudioStreamBasicDescription changed = carrier;
        changed.mFormatID = rejected[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    }
    AudioStreamBasicDescription changed = carrier;
    changed.mSampleRate = 192000;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    changed = carrier; changed.mChannelsPerFrame = 8;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    changed = carrier; changed.mBitsPerChannel = 24;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    changed = carrier; changed.mBytesPerFrame = 16;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    changed = carrier; changed.mFramesPerPacket = 8192;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    changed = carrier; changed.mBytesPerPacket = 32768;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    const unsigned rejected_flags[] = {
        12, 76 | kAudioFormatFlagIsFloat, 76 | kAudioFormatFlagIsBigEndian,
        76 | kAudioFormatFlagIsNonInterleaved,
    };
    for (unsigned i = 0; i < sizeof(rejected_flags) / sizeof(*rejected_flags); i++) {
        changed = carrier; changed.mFormatFlags = rejected_flags[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_DTSHD_MA, 192000, 8, 16, &changed));
    }
    assert(192000 * 16 == carrier.mSampleRate * carrier.mBytesPerFrame);
    // DTS IV burst and the HAL's packet/callback sizes are independent. Both
    // retain the decoder's 16-byte logical stride with no packet conversion.
    const unsigned reads[] = {4096, 32768, 61440, 122880};
    for (unsigned i = 0; i < sizeof(reads) / sizeof(*reads); i++)
        assert(nv_ca_hdmi_logical_frames(16, reads[i]) == (int)(reads[i] / 16));
    assert(nv_ca_hdmi_carrier_frames_to_ns(8192, &carrier) == 10666666);
}

static void test_dtshd_payload_integrity(void)
{
    uint8_t packet[1025], wire[32768] = {0};
    for (unsigned i = 0; i < sizeof(packet); i++)
        packet[i] = (uint8_t)(i * 53);
    const uint8_t preamble[] = {0x72, 0xf8, 0x1f, 0x4e, 0x11, 4};
    memcpy(wire, preamble, sizeof(preamble));
    const uint8_t header[] = {0, 1, 0, 0, 0, 0, 0, 0, 0xfe, 0xfe};
    memcpy(wire + 8, header, sizeof(header));
    unsigned pd = ((sizeof(packet) + 12 + 8 + 15) & ~15U) - 8;
    wire[6] = pd; wire[7] = pd >> 8;
    wire[18] = sizeof(packet) & 255; wire[19] = sizeof(packet) >> 8;
    for (unsigned i = 0; i < sizeof(packet); i++)
        wire[20 + (i ^ 1U)] = packet[i];
    assert(nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), packet, sizeof(packet)));
    // The odd final byte must be checked, not silently dropped in word swaps.
    wire[20 + ((sizeof(packet) - 1) ^ 1U)] ^= 1;
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), packet, sizeof(packet)));
    wire[20 + ((sizeof(packet) - 1) ^ 1U)] ^= 1;
    // Same DTS-HD type-IV label, but only a shorter core payload: reject.
    wire[18] = 0; wire[19] = 2;
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), packet, sizeof(packet)));
    wire[18] = sizeof(packet) & 255; wire[19] = sizeof(packet) >> 8;
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire) - 16, packet, sizeof(packet)));
    wire[5] = 3;
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), packet, sizeof(packet)));
    wire[5] = 4; wire[16] ^= 1;
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), packet, sizeof(packet)));
    wire[16] ^= 1; wire[6] = 0; wire[7] = 0;
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), packet, sizeof(packet)));
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, 19, packet, sizeof(packet)));
    assert(!nv_ca_hdmi_dtshd_payload_matches(NULL, sizeof(wire), packet, sizeof(packet)));
    assert(!nv_ca_hdmi_dtshd_payload_matches(wire, sizeof(wire), NULL, sizeof(packet)));
}

int main(void)
{
    test_dts_core();
    test_dtshd_ma();
    test_dtshd_payload_integrity();
    AudioStreamBasicDescription f = {
        .mFormatID = 'cec3', .mSampleRate = 192000,
        .mFormatFlags = 76, .mChannelsPerFrame = 2, .mBitsPerChannel = 16,
        .mBytesPerFrame = 4, .mFramesPerPacket = 6144, .mBytesPerPacket = 24576,
    };
    assert(nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &f) == 2);
    // A TrueHD or DTS payload must never be sent into the EAC3 carrier.
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 2, 4, &f));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 8, 16, &f));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 48000, 2, 4, &f));
    const AudioFormatID rejected[] = {'lpcm', 'cc+3', 'cd+3', 'mtc+', 'mtct'};
    for (unsigned i = 0; i < sizeof(rejected) / sizeof(*rejected); i++) {
        AudioStreamBasicDescription other = f;
        other.mFormatID = rejected[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &other));
        assert(!nv_ca_hdmi_asbd_equal(&f, &other));
    }
    AudioStreamBasicDescription changed = f;
    changed.mBytesPerPacket /= 2;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &changed));
    assert(!nv_ca_hdmi_asbd_equal(&f, &changed));
    changed = f; changed.mFramesPerPacket /= 2;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &changed));
    const unsigned bad_flags[] = {kAudioFormatFlagIsFloat,
        kAudioFormatFlagIsBigEndian, kAudioFormatFlagIsNonInterleaved};
    for (unsigned i = 0; i < sizeof(bad_flags) / sizeof(*bad_flags); i++) {
        changed = f; changed.mFormatFlags |= bad_flags[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &changed));
    }
    assert(nv_ca_hdmi_asbd_equal(&f, &f));
    // Preserve the legacy path only with its original exact byte geometry.
    changed = f; changed.mFormatID = kAudioFormat60958AC3;
    assert(nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &changed) == 1);
    changed.mSampleRate = 48000;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 2, 4, &changed));

    AudioStreamBasicDescription mat = {
        .mFormatID = 'mtct', .mSampleRate = 768000,
        .mFormatFlags = 76, .mChannelsPerFrame = 2, .mBitsPerChannel = 16,
        .mBytesPerFrame = 4, .mFramesPerPacket = 15360, .mBytesPerPacket = 61440,
    };
    assert(nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &mat) == 2);
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_EAC3, 192000, 8, 16, &mat));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_LEGACY, 192000, 8, 16, &mat));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 2, 4, &mat));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 768000, 2, 4, &mat));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 176400, 8, 16, &mat));
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 4, &mat));
    const AudioFormatID not_truehd[] = {
        'mtc+', 'cec3', 'cc+3', 'cd+3', 'lpcm', kAudioFormat60958AC3,
    };
    for (unsigned i = 0; i < sizeof(not_truehd) / sizeof(*not_truehd); i++) {
        changed = mat; changed.mFormatID = not_truehd[i];
        assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    }
    changed = mat; changed.mSampleRate = 192000;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    changed = mat; changed.mChannelsPerFrame = 8;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    changed = mat; changed.mFormatFlags = 12;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    changed = mat; changed.mBytesPerFrame = 16;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    changed = mat; changed.mFramesPerPacket = 3840;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    changed = mat; changed.mBytesPerPacket = 61424;
    assert(!nv_ca_hdmi_rank(NV_CA_HDMI_TRUEHD, 192000, 8, 16, &changed));
    assert(!nv_ca_hdmi_asbd_equal(&mat, &changed));

    // Reframing bytes must preserve both byte rate and duration.
    assert(nv_ca_hdmi_logical_frames(16, 61440) == 3840);
    assert(nv_ca_hdmi_logical_frames(4, 61440) == 15360);
    assert(nv_ca_hdmi_logical_frames(16, 0) == 0);
    assert(nv_ca_hdmi_logical_frames(16, 4) == -1);
    assert(nv_ca_hdmi_logical_frames(0, 61440) == -1);
    assert(nv_ca_hdmi_carrier_frames_to_ns(15360, &mat) == 20000000);
    assert(nv_ca_hdmi_carrier_frames_to_ns(768, &mat) == 1000000);
    assert(nv_ca_hdmi_carrier_frames_to_ns(6144, &f) == 32000000);
    changed = mat; changed.mSampleRate = 0;
    assert(nv_ca_hdmi_carrier_frames_to_ns(15360, &changed) == -1);
    assert(nv_ca_hdmi_carrier_frames_to_ns(UINT64_MAX, &mat) == -1);
    puts("CoreAudio HDMI transport policy passed");
}
