/* NetVplayer object renderer. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef NV_ATMOS_RENDER_H
#define NV_ATMOS_RENDER_H
#include <stdbool.h>
#include <stdint.h>
#include <truehd_atmos.h>

/* mpv/FFmpeg order, deliberately independent of CoreAudio's Atmos tag order:
 * FL FR FC LFE BL BR SL SR TFL TFR TBL TBR. The second bank is head-locked. */
#define NV_ATMOS_CHANNELS 12
#define NV_ATMOS_BUSES 24
struct nv_atmos_renderer {
    uint32_t serial, channels;
    bool configured, known[TRUEHD_ATMOS_MAX_CHANNELS];
    float gain[TRUEHD_ATMOS_MAX_CHANNELS][NV_ATMOS_BUSES];
    float target[TRUEHD_ATMOS_MAX_CHANNELS][NV_ATMOS_BUSES];
    uint32_t remaining[TRUEHD_ATMOS_MAX_CHANNELS];
};
void nv_atmos_reset(struct nv_atmos_renderer *r);
/* 0: rendered presentation; 1: aligned channel-based companion used because
 * this presentation contains unsupported ISF; -1: invalid/unsupported data.
 * No clipping, resampling, bass management, or second copy of the 7.1 mix. */
int nv_atmos_render(struct nv_atmos_renderer *r, const TrueHDAtmosBlock *block,
                    float *const out[NV_ATMOS_BUSES]);
void nv_atmos_point_gains(float x, float y, float z, uint8_t zone, bool snap,
                          float out[NV_ATMOS_CHANNELS]);
#endif
