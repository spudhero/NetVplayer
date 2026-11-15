/* NetVplayer render telemetry extension. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef MPV_RENDER_NETVPLAYER_H
#define MPV_RENDER_NETVPLAYER_H
#include <stdint.h>
#include "client.h"
MPV_EXPORT uint64_t mpv_netvplayer_runtime_capabilities(void);
#define MPV_RENDER_PARAM_NETVPLAYER_STATUS 10001
#define MPV_NETVPLAYER_STATUS_VERSION 1
#define MPV_NETVPLAYER_CAP_DOVI 1ULL
#define MPV_NETVPLAYER_CAP_ENHANCEMENT 2ULL
#define MPV_NETVPLAYER_CAP_ICC 4ULL
#define MPV_NETVPLAYER_CAP_FLOAT_TARGET 8ULL
#define MPV_NETVPLAYER_CAP_HDR_VIVID 16ULL
#define MPV_NETVPLAYER_CAP_SOURCE_FRAME 32ULL
#define MPV_RENDER_PARAM_NETVPLAYER_SOURCE_FRAME 10002
/* Optional synchronous observation of the source of a successfully rendered
 * frame. AVFrame is borrowed, in the indicated libavutil major ABI. Copy before
 * returning; never enqueue for display here: render() has not waited for the
 * mpv presentation deadline yet. NULL means compositing/transform is required.
 * The existing reconstruction, subtitles, audio and clock always continue. */
typedef struct mpv_netvplayer_source_frame {
    uint32_t size, version, avutil_major;
    void *opaque;
    void (*capture)(void *opaque, const void *avframe, double pts, uint64_t generation);
} mpv_netvplayer_source_frame;
#define MPV_NETVPLAYER_FRAME_DOVI 1ULL
#define MPV_NETVPLAYER_FRAME_ENHANCEMENT 2ULL
#define MPV_NETVPLAYER_FRAME_FEL 4ULL
#define MPV_NETVPLAYER_FRAME_FAILED 8ULL
#define MPV_NETVPLAYER_FRAME_HDR_VIVID 16ULL
#define MPV_NETVPLAYER_FRAME_VIVID_MAPPED 32ULL
#define MPV_NETVPLAYER_FRAME_VIVID_FALLBACK 64ULL
/* Callers initialize size and version. All other fields are outputs. Counters
 * belong to generation (reset/reconfigure), never to a previously loaded item.
 * DOVI/FEL counters advance only after the GPU render submission succeeds.
 * These describe reconstruction/color processing, not HDMI Dolby signaling. */
typedef struct mpv_netvplayer_render_status {
    uint32_t size, version;
    uint64_t capabilities, generation;
    uint64_t rendered_frames, dovi_frames, enhancement_frames, fel_frames;
    uint64_t failures, frame_flags;
    double pts;
} mpv_netvplayer_render_status;
#endif
