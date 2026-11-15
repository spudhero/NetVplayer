/* NetVplayer E-AC-3 transport. SPDX-License-Identifier: LGPL-2.1-or-later
 * Preserve complete independent/dependent syncframes (including JOC data).
 * Only IEC 61937 framing and word byte order are removed; no PCM conversion.
 */
#include <libavformat/avformat.h>
#include <libavcodec/ac3_parser.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/channel_layout.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreMedia/CoreMedia.h>

#define NV_EAC3_BURST_BYTES 24576
#define NV_EAC3_BURST_FRAMES (NV_EAC3_BURST_BYTES / 4)

struct nv_eac3_packet {
    uint8_t data[NV_EAC3_BURST_BYTES];
    size_t size;
    int rate, channels, frames;
};

static bool nv_eac3_unpack(const uint8_t *burst, size_t length,
                           struct nv_eac3_packet *out)
{
    if (length != NV_EAC3_BURST_BYTES)
        return false;
    bool little;
    if (AV_RL16(burst) == 0xf872 && AV_RL16(burst + 2) == 0x4e1f)
        little = true;
    else if (AV_RB16(burst) == 0xf872 && AV_RB16(burst + 2) == 0x4e1f)
        little = false;
    else
        return false;
    uint16_t type = little ? AV_RL16(burst + 4) : AV_RB16(burst + 4);
    size_t bytes = little ? AV_RL16(burst + 6) : AV_RB16(burst + 6);
    if ((type & 0x1f) != 0x15 || (type & 0x80) || bytes < 6 ||
        bytes > length - 8 || bytes % 2)
        return false;
    *out = (struct nv_eac3_packet){.size = bytes};
    for (size_t i = 0; i < bytes; i++)
        out->data[i] = burst[8 + (little ? i ^ 1 : i)];
    static const int rates[] = {48000, 44100, 32000};
    static const int blocks[] = {1, 2, 3, 6};
    static const int channels[] = {2, 1, 2, 3, 3, 4, 4, 5};
    bool independent = false;
    for (size_t pos = 0; pos < bytes;) {
        if (bytes - pos < 6 || AV_RB16(out->data + pos) != 0x0b77)
            return false;
        const uint8_t *h = out->data + pos;
        uint8_t bsid = 0;
        uint16_t size = 0;
        if (av_ac3_parse_header(h, bytes - pos, &bsid, &size) < 0 ||
            size < 7 || size > bytes - pos || bsid > 16)
            return false;
        int rate, count, stream_type = 0, substream = 0, acmod, lfe;
        if (bsid <= 10) {
            // Blu-ray DD+ may carry an AC-3 independent substream followed by
            // E-AC-3 dependent substreams. Preserve both, as one access unit.
            int fscod = h[4] >> 6;
            if (fscod == 3)
                return false;
            rate = rates[fscod] >> (bsid > 8 ? bsid - 8 : 0);
            count = 6;
            acmod = h[6] >> 5;
            int shift = 5;
            if ((acmod & 1) && acmod != 1) shift -= 2;
            if (acmod & 4) shift -= 2;
            if (acmod == 2) shift -= 2;
            lfe = (h[6] >> (shift - 1)) & 1;
        } else {
            stream_type = h[2] >> 6;
            substream = (h[2] >> 3) & 7;
            int fscod = h[4] >> 6;
            int fscod2 = (h[4] >> 4) & 3;
            if (stream_type == 3 || (fscod == 3 && fscod2 == 3))
                return false;
            rate = fscod == 3 ? rates[fscod2] / 2 : rates[fscod];
            count = fscod == 3 ? 6 : blocks[fscod2];
            acmod = (h[4] >> 1) & 7;
            lfe = h[4] & 1;
        }
        if (out->rate && out->rate != rate)
            return false;
        out->rate = rate;
        if (stream_type != 1) {
            // An IEC burst carries one selected program, with any dependent
            // substreams. Never merge separately timed independent programs.
            if (substream != 0)
                return false;
            independent = true;
            out->frames += count * 256;
            out->channels = channels[acmod] + lfe;
        } else if (!independent) {
            return false;
        }
        pos += size;
    }
    return independent && out->frames == 1536;
}

// Locate dec3 through bounded ISO BMFF boxes, never by scanning payload bytes.
static const uint8_t *nv_eac3_cookie_box(const uint8_t *data, size_t size,
                                        size_t *cookie_size, int depth)
{
    if (depth > 9)
        return NULL;
    for (size_t pos = 0; size - pos >= 8;) {
        uint32_t len = AV_RB32(data + pos);
        const uint8_t *box = data + pos;
        if (len < 8 || len > size - pos)
            return NULL;
        if (!memcmp(box + 4, "dec3", 4) && len >= 13 && len <= 256) {
            *cookie_size = len;
            return box;
        }
        size_t skip = 0;
        if (!memcmp(box + 4, "moov", 4) || !memcmp(box + 4, "trak", 4) ||
            !memcmp(box + 4, "mdia", 4) || !memcmp(box + 4, "minf", 4) ||
            !memcmp(box + 4, "stbl", 4))
            skip = 8;
        else if (!memcmp(box + 4, "stsd", 4))
            skip = 16;
        else if (!memcmp(box + 4, "ec-3", 4))
            skip = 36;
        if (skip && len > skip) {
            const uint8_t *found = nv_eac3_cookie_box(box + skip, len - skip,
                                                    cookie_size, depth + 1);
            if (found)
                return found;
        }
        pos += len;
    }
    return NULL;
}

static CMAudioFormatDescriptionRef nv_eac3_format(const struct nv_eac3_packet *p, bool *joc)
{
    if (joc) *joc = false;
    AVFormatContext *mux = NULL;
    AVPacket *packet = NULL;
    uint8_t *mp4 = NULL;
    CMAudioFormatDescriptionRef desc = NULL;
    if (avformat_alloc_output_context2(&mux, NULL, "mp4", NULL) < 0 || !mux)
        goto done;
    AVStream *st = avformat_new_stream(mux, NULL);
    if (!st || avio_open_dyn_buf(&mux->pb) < 0)
        goto done;
    st->time_base = (AVRational){1, p->rate};
    st->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    st->codecpar->codec_id = AV_CODEC_ID_EAC3;
    st->codecpar->sample_rate = p->rate;
    st->codecpar->frame_size = p->frames;
    st->codecpar->bit_rate = (int64_t)p->size * 8 * p->rate / p->frames;
    av_channel_layout_default(&st->codecpar->ch_layout, p->channels);
    mux->flags |= AVFMT_FLAG_BITEXACT;
    if (avformat_write_header(mux, NULL) < 0)
        goto done;
    packet = av_packet_alloc();
    if (!packet || av_new_packet(packet, p->size) < 0)
        goto done;
    memcpy(packet->data, p->data, p->size);
    packet->pts = packet->dts = 0;
    packet->duration = p->frames;
    packet->stream_index = st->index;
    if (av_write_frame(mux, packet) < 0 || av_write_trailer(mux) < 0)
        goto done;
    int size = avio_close_dyn_buf(mux->pb, &mp4);
    mux->pb = NULL;
    if (size < 0 || size > 131072)
        goto done;
    size_t cookie_size = 0;
    const uint8_t *cookie = nv_eac3_cookie_box(mp4, size, &cookie_size, 0);
    if (!cookie)
        goto done;
    // ETSI TS 102 366 dec3: each independent substream occupies 24 or
    // 32 bits; the optional type-A extension carries the JOC complexity index.
    const uint8_t *config = cookie + 8;
    size_t config_bytes = cookie_size - 8, cursor = 2;
    int independent_substreams = (config[1] & 7) + 1;
    for (int i = 0; i < independent_substreams; i++) {
        if (cursor + 3 > config_bytes) { cursor = config_bytes; break; }
        int dependents = (config[cursor + 2] >> 1) & 15;
        cursor += dependents ? 4 : 3;
    }
    if (joc && cursor + 2 <= config_bytes)
        *joc = (config[cursor] & 1) != 0;
    AudioStreamBasicDescription asbd = {
        .mFormatID = kAudioFormatEnhancedAC3,
        .mSampleRate = p->rate,
        .mFramesPerPacket = p->frames,
        .mChannelsPerFrame = p->channels,
    };
    UInt32 asbd_size = sizeof(asbd);
    // CoreAudio derives dependent substream/channel information from the exact
    // dec3 cookie produced by FFmpeg's E-AC-3 parser, including JOC extensions.
    AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, cookie_size, cookie,
                           &asbd_size, &asbd);
    if (CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, cookie_size,
                                      cookie, NULL, &desc) != noErr)
        desc = NULL;
done:
    av_packet_free(&packet);
    if (mux && mux->pb) {
        uint8_t *buffer = NULL;
        avio_close_dyn_buf(mux->pb, &buffer);
        av_free(buffer);
        mux->pb = NULL;
    }
    avformat_free_context(mux);
    av_free(mp4);
    return desc;
}
