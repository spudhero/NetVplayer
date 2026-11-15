/* TrueHD object decode on mpv's selected demux stream and clock.
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#include <math.h>
#include <string.h>
#include <libavutil/error.h>
#include "audio/aframe.h"
#include "audio/chmap.h"
#include "audio/format.h"
#include "common/codecs.h"
#include "common/common.h"
#include "common/msg.h"
#include "demux/packet.h"
#include "demux/stheader.h"
#include "filters/f_decoder_wrapper.h"
#include "filters/filter_internal.h"
#include "ad_truehd_objects.h"
#include "atmos_render.h"
#include "atmos_binaural.h"

struct priv {
    struct mp_decoder public;
    struct lavc_state state;
    TrueHDAtmosDecoder *decoder;
    struct nv_atmos_renderer renderer;
    void *binaural;
    int mode, binaural_rate;
    bool eof, warned_fallback;
    struct nv_object_audio_status status;
    struct mp_aframe_pool *pool;
    float samples[NV_ATMOS_BUSES][TRUEHD_ATMOS_MAX_BLOCK_FRAMES];
};

static void reset(struct mp_filter *f)
{
    struct priv *p = f->priv;
    truehd_atmos_decoder_reset(p->decoder);
    nv_atmos_reset(&p->renderer);
    nv_binaural_reset(p->binaural);
    p->eof = p->warned_fallback = false;
    p->state = (struct lavc_state){0};
    p->status = (struct nv_object_audio_status){.mode = p->mode, .pose_age = -1};
}

static void destroy(struct mp_filter *f)
{
    struct priv *p = f->priv;
    nv_binaural_destroy(p->binaural);
    truehd_atmos_decoder_destroy(p->decoder);
}

static int control(struct mp_filter *f, enum dec_ctrl cmd, void *arg)
{
    struct priv *p = f->priv;
    if (cmd != ADCTRL_GET_OBJECT_AUDIO_STATUS) return CONTROL_UNKNOWN;
    struct nv_binaural_status h;
    nv_binaural_get_status(p->binaural, &h);
    p->status.tracking_requested = p->mode == 3;
    p->status.tracking_active = h.tracking_active;
    p->status.poses = h.poses;
    p->status.pose_age = h.pose_age;
    p->status.binaural_frames = h.frames;
    *(struct nv_object_audio_status *)arg = p->status;
    return CONTROL_OK;
}

static int send_packet(struct mp_filter *f, struct demux_packet *packet)
{
    struct priv *p = f->priv;
    if (!packet) { p->eof = true; return 0; }
    int64_t pts = TRUEHD_ATMOS_NO_PTS;
    if (packet->pts != MP_NOPTS_VALUE && isfinite(packet->pts) && fabs(packet->pts) < 9e9)
        pts = llround(packet->pts * 1e9);
    int s = truehd_atmos_decoder_push(p->decoder, packet->buffer, packet->len, pts);
    if (s == TRUEHD_ATMOS_OK) return 0;
    MP_ERR(f, "Object decoder push failed (%d): %s\n", s, truehd_atmos_decoder_last_error(p->decoder));
    return AVERROR_INVALIDDATA;
}

static int receive_frame(struct mp_filter *f, struct mp_frame *result)
{
    struct priv *p = f->priv;
    TrueHDAtmosBlock b;
    int s = truehd_atmos_decoder_pull(p->decoder, &b);
    if (s == TRUEHD_ATMOS_NEED_MORE_DATA) return p->eof ? AVERROR_EOF : AVERROR(EAGAIN);
    if (s != TRUEHD_ATMOS_OK || !b.frame_count || !b.sample_rate) return AVERROR_INVALIDDATA;
    float *planes[NV_ATMOS_BUSES];
    for (int c = 0; c < NV_ATMOS_BUSES; c++) planes[c] = p->samples[c];
    int rendered = nv_atmos_render(&p->renderer, &b, planes);
    if (rendered < 0) {
        MP_ERR(f, "Unsupported object metadata/layout; refusing an incorrect Atmos render.\n");
        return AVERROR_INVALIDDATA;
    }
    if (rendered > 0) {
        p->status.fallback_blocks++;
        if (!p->warned_fallback) {
            MP_WARN(f, "ISF position unavailable; using the aligned channel-based presentation.\n");
            p->warned_fallback = true;
        }
    }
    TrueHDAtmosStreamInfo info;
    if (truehd_atmos_decoder_get_stream_info(p->decoder, &info) == TRUEHD_ATMOS_OK) {
        p->status.has_objects = info.has_objects;
        p->status.metadata_seen = info.oamd_seen;
    }
    TrueHDAtmosStats stats;
    if (truehd_atmos_decoder_get_stats(p->decoder, &stats) == TRUEHD_ATMOS_OK) {
        p->status.metadata_updates = stats.metadata_updates;
        p->status.decode_errors = stats.decode_errors;
        p->status.sync_errors = stats.sync_errors;
        p->status.metadata_errors = stats.oamd_errors;
    }
    struct mp_aframe *out = mp_aframe_create();
    struct mp_chmap map;
    mp_chmap_from_str(&map, bstr0(p->mode == 1
        ? "fl-fr-fc-lfe-bl-br-sl-sr-tfl-tfr-tbl-tbr" : "stereo"));
    mp_aframe_set_format(out, AF_FORMAT_FLOATP);
    mp_aframe_set_chmap(out, &map);
    mp_aframe_set_rate(out, b.sample_rate);
    if (mp_aframe_pool_allocate(p->pool, out, b.frame_count) < 0) goto fail;
    float **dst = (float **)mp_aframe_get_data_rw(out);
    if (!dst) goto fail;
    if (p->mode == 1) {
        for (int c = 0; c < NV_ATMOS_CHANNELS; c++)
            for (unsigned n = 0; n < b.frame_count; n++) dst[c][n] = planes[c][n] + planes[c+NV_ATMOS_CHANNELS][n];
    } else {
        if (p->binaural_rate != b.sample_rate) {
            nv_binaural_destroy(p->binaural);
            p->binaural = nv_binaural_create(b.sample_rate, p->mode == 3);
            p->binaural_rate = b.sample_rate;
        }
        if (b.flags & TRUEHD_ATMOS_BLOCK_DISCONTINUITY) nv_binaural_reset(p->binaural);
        if (!nv_binaural_render(p->binaural, planes, b.frame_count, dst[0], dst[1])) {
            MP_ERR(f, "HRTF DSP failed; refusing mislabeled binaural output.\n");
            goto fail;
        }
    }
    // Summing object signals and HRTF responses can exceed full scale even
    // when every decoded plane is valid. Reserve a fixed 12 dB of mix headroom
    // before the user's gain/DSP. Do not clip float PCM or ride per-block gain.
    for (int c = 0; c < (p->mode == 1 ? NV_ATMOS_CHANNELS : 2); c++)
        for (unsigned n = 0; n < b.frame_count; n++) dst[c][n] *= .25f;
    // Use each access unit's own packet timestamp, including units skipped
    // before major sync after seek. No independently advancing audio clock.
    double pts = b.pts == TRUEHD_ATMOS_NO_PTS ? MP_NOPTS_VALUE
        : b.pts/1e9 + (double)b.pts_au_index*b.access_unit_frames/b.sample_rate;
    mp_aframe_set_pts(out, pts);
    p->status.rate = b.sample_rate;
    p->status.presentation = b.presentation;
    p->status.elements = b.channel_count;
    p->status.frames += b.frame_count;
    if (!rendered && p->status.has_objects && b.metadata) p->status.object_blocks++;
    *result = MAKE_FRAME(MP_FRAME_AUDIO, out);
    return 0;
fail:
    talloc_free(out);
    return AVERROR_INVALIDDATA;
}

static void process(struct mp_filter *f)
{
    struct priv *p = f->priv;
    lavc_process(f, &p->state, send_packet, receive_frame);
}

static const struct mp_filter_info filter = {
    .name = "ad_truehd_objects", .priv_size = sizeof(struct priv),
    .process = process, .reset = reset, .destroy = destroy,
};

static struct mp_decoder *create(struct mp_filter *parent, struct mp_codec_params *codec, const char *name)
{
    if (!codec->codec || strcmp(codec->codec, "truehd") || truehd_atmos_api_version() != TRUEHD_ATMOS_API_VERSION) return NULL;
    int mode = strcmp(name, "truehd_objects_714") == 0 ? 1
        : strcmp(name, "truehd_objects_binaural") == 0 ? 2
        : strcmp(name, "truehd_objects_tracked") == 0 ? 3 : 0;
    if (!mode) return NULL;
    struct mp_filter *f = mp_filter_create(parent, &filter);
    if (!f) return NULL;
    mp_filter_add_pin(f, MP_PIN_IN, "in"); mp_filter_add_pin(f, MP_PIN_OUT, "out");
    struct priv *p = f->priv;
    p->mode = mode;
    p->public.f = f; p->public.control = control;
    p->pool = mp_aframe_pool_create(p);
    p->decoder = truehd_atmos_decoder_create(TRUEHD_ATMOS_PRESENTATION_HIGHEST);
    if (!p->decoder || truehd_atmos_decoder_set_bed_companion(p->decoder, true) != TRUEHD_ATMOS_OK) {
        talloc_free(f); return NULL;
    }
    reset(f);
    MP_INFO(f, "TrueHD object renderer: %s; exact matrix interpolation, single demux/timeline.\n", name);
    return &p->public;
}

const struct mp_decoder_fns ad_truehd_objects = {.create = create};
