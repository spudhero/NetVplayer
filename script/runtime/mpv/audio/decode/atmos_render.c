/* NetVplayer allocentric speaker renderer. SPDX-License-Identifier: LGPL-2.1-or-later
 * Uses the OAMD room coordinates and 7.1.4 reference speaker positions. This
 * is an application renderer, not the proprietary/certified Dolby renderer. */
#include "atmos_render.h"
#include <math.h>
#include <string.h>

static float clamp(float x, float low, float high)
{
    return fminf(high, fmaxf(low, x));
}

static const float locations[NV_ATMOS_CHANNELS][3] = {
    {0,0,0}, {1,0,0}, {.5,0,0}, {.5,.5,0},
    {0,1,0}, {1,1,0}, {0,.5,0}, {1,.5,0},
    {.25,.25,1}, {.75,.25,1}, {.25,.75,1}, {.75,.75,1},
};

static bool allowed(int c, uint8_t zone)
{
    if (c == 3) return false; // objects never feed LFE
    float y = locations[c][1];
    switch (zone) {
    case TRUEHD_ATMOS_ZONE_NO_BACK: return y < .75f;
    case TRUEHD_ATMOS_ZONE_NO_SIDES: return c != 6 && c != 7;
    case TRUEHD_ATMOS_ZONE_CENTER_BACK: return c == 2 || y >= .75f;
    case TRUEHD_ATMOS_ZONE_SCREEN_ONLY: return y <= .25f;
    case TRUEHD_ATMOS_ZONE_SURROUND_ONLY: return y > .25f;
    default: return true;
    }
}

void nv_atmos_point_gains(float x, float y, float z, uint8_t zone, bool snap,
                          float out[NV_ATMOS_CHANNELS])
{
    x = clamp(x, 0, 1); y = clamp(y, 0, 1); z = clamp(z, 0, 1);
    memset(out, 0, sizeof(float) * NV_ATMOS_CHANNELS);
    float best = INFINITY;
    int nearest = 0;
    for (int c = 0; c < NV_ATMOS_CHANNELS; c++) {
        if (!allowed(c, zone)) continue;
        // Deterministic snap weighting from TS 103 448, 5.1.4.3.
        float dx = x - locations[c][0], dy = y - locations[c][1];
        float dz = z - locations[c][2];
        float d = dx*dx/16 + 4*dy*dy + 32*dz*dz;
        if (d < best) { best = d; nearest = c; }
    }
    if (snap) { out[nearest] = 1; return; }
    // Constant-power interpolation between rows and elevation layers. The
    // ceiling reference rectangle is inset by 1/4 room width/depth.
    float front = 1 - clamp(y * 2, 0, 1);
    float rear = clamp(y * 2 - 1, 0, 1);
    float side = 1 - front - rear;
    float left = x < .5f ? 1 - 2*x : 0;
    float right = x > .5f ? 2*x - 1 : 0;
    out[0] = front * left * (1-z);
    out[1] = front * right * (1-z);
    out[2] = front * (1-left-right) * (1-z);
    out[4] = rear * (1-x) * (1-z); out[5] = rear * x * (1-z);
    out[6] = side * (1-x) * (1-z); out[7] = side * x * (1-z);
    float tx = clamp((x-.25f)*2, 0, 1), ty = clamp((y-.25f)*2, 0, 1);
    out[8] = (1-tx)*(1-ty)*z; out[9] = tx*(1-ty)*z;
    out[10] = (1-tx)*ty*z; out[11] = tx*ty*z;
    float total = 0;
    for (int c = 0; c < NV_ATMOS_CHANNELS; c++) {
        if (!allowed(c, zone)) out[c] = 0;
        total += out[c];
    }
    if (total < 1e-12f) { out[nearest] = 1; return; }
    for (int c = 0; c < NV_ATMOS_CHANNELS; c++) out[c] = sqrtf(out[c]/total);
}

static bool bed_gains(uint8_t speaker, float out[NV_ATMOS_CHANNELS])
{
    memset(out, 0, sizeof(float) * NV_ATMOS_CHANNELS);
    int direct = -1;
    switch (speaker) {
    case TRUEHD_ATMOS_SPEAKER_L: direct = 0; break;
    case TRUEHD_ATMOS_SPEAKER_R: direct = 1; break;
    case TRUEHD_ATMOS_SPEAKER_C: direct = 2; break;
    case TRUEHD_ATMOS_SPEAKER_LFE:
    case TRUEHD_ATMOS_SPEAKER_LFE2: direct = 3; break;
    case TRUEHD_ATMOS_SPEAKER_LB: direct = 4; break;
    case TRUEHD_ATMOS_SPEAKER_RB: direct = 5; break;
    case TRUEHD_ATMOS_SPEAKER_LS:
    case TRUEHD_ATMOS_SPEAKER_LSD: direct = 6; break;
    case TRUEHD_ATMOS_SPEAKER_RS:
    case TRUEHD_ATMOS_SPEAKER_RSD: direct = 7; break;
    case TRUEHD_ATMOS_SPEAKER_TFL: direct = 8; break;
    case TRUEHD_ATMOS_SPEAKER_TFR: direct = 9; break;
    case TRUEHD_ATMOS_SPEAKER_TBL: direct = 10; break;
    case TRUEHD_ATMOS_SPEAKER_TBR: direct = 11; break;
    case TRUEHD_ATMOS_SPEAKER_TSL: out[8] = out[10] = sqrtf(.5f); return true;
    case TRUEHD_ATMOS_SPEAKER_TSR: out[9] = out[11] = sqrtf(.5f); return true;
    case TRUEHD_ATMOS_SPEAKER_OBJECT: return true; // silence until OAMD
    case TRUEHD_ATMOS_SPEAKER_LSC: nv_atmos_point_gains(.25,0,0,0,false,out); return true;
    case TRUEHD_ATMOS_SPEAKER_RSC: nv_atmos_point_gains(.75,0,0,0,false,out); return true;
    case TRUEHD_ATMOS_SPEAKER_CB: nv_atmos_point_gains(.5,1,0,0,false,out); return true;
    case TRUEHD_ATMOS_SPEAKER_TC: nv_atmos_point_gains(.5,.5,1,0,false,out); return true;
    case TRUEHD_ATMOS_SPEAKER_LW: nv_atmos_point_gains(0,.25,0,0,false,out); return true;
    case TRUEHD_ATMOS_SPEAKER_RW: nv_atmos_point_gains(1,.25,0,0,false,out); return true;
    case TRUEHD_ATMOS_SPEAKER_TFC: nv_atmos_point_gains(.5,0,1,0,false,out); return true;
    default: return false;
    }
    out[direct] = 1;
    return true;
}

static bool element_gains(const TrueHDAtmosElement *e, float out[NV_ATMOS_BUSES])
{
    memset(out, 0, sizeof(float) * NV_ATMOS_BUSES);
    if (!isfinite(e->gain) || e->gain < 0 || e->gain > 8) return false;
    if (e->kind == TRUEHD_ATMOS_ELEMENT_BED || e->kind == TRUEHD_ATMOS_ELEMENT_LFE) {
        if (!bed_gains(e->speaker, out)) return false;
    } else if (e->kind == TRUEHD_ATMOS_ELEMENT_OBJECT) {
        if (!(e->flags & TRUEHD_ATMOS_ELEMENT_ACTIVE)) return true;
        for (int a = 0; a < 3; a++)
            if (!isfinite(e->position[a]) || !isfinite(e->size[a])) return false;
        if (e->zone > TRUEHD_ATMOS_ZONE_SURROUND_ONLY) return false;
        float z = e->flags & TRUEHD_ATMOS_ELEMENT_ELEVATION ? e->position[2] : 0;
        bool snap = e->flags & TRUEHD_ATMOS_ELEMENT_SNAP;
        nv_atmos_point_gains(e->position[0], e->position[1], z, e->zone, snap, out);
        // Spread power over eight corners of the authored extent, retaining
        // centre power for smaller objects. No LFE or implicit duplicate bed.
        float extent = snap ? 0 : fmaxf(e->size[0], fmaxf(e->size[1], e->size[2]));
        extent = clamp(extent, 0, 1);
        float power[NV_ATMOS_CHANNELS];
        for (int c = 0; c < NV_ATMOS_CHANNELS; c++) power[c] = out[c]*out[c]*(1-extent);
        if (extent > 0) {
            for (int corner = 0; corner < 8; corner++) {
                float g[NV_ATMOS_CHANNELS];
                nv_atmos_point_gains(e->position[0] + (corner&1 ? .5f : -.5f)*e->size[0],
                    e->position[1] + (corner&2 ? .5f : -.5f)*e->size[1],
                    z + (corner&4 ? .5f : -.5f)*e->size[2], e->zone, false, g);
                for (int c = 0; c < NV_ATMOS_CHANNELS; c++) power[c] += extent*g[c]*g[c]/8;
            }
        }
        float divergence = snap || !(e->flags & TRUEHD_ATMOS_ELEMENT_DIVERGENCE)
            ? 0 : clamp(e->divergence, 0, 1);
        if (divergence > 0) {
            float l[NV_ATMOS_CHANNELS], h[NV_ATMOS_CHANNELS];
            nv_atmos_point_gains(0, e->position[1], z, e->zone, false, l);
            nv_atmos_point_gains(1, e->position[1], z, e->zone, false, h);
            for (int c = 0; c < NV_ATMOS_CHANNELS; c++)
                power[c] = (1-divergence)*power[c] + divergence*(l[c]*l[c]+h[c]*h[c])/2;
        }
        for (int c = 0; c < NV_ATMOS_CHANNELS; c++) out[c] = sqrtf(power[c]);
    } else { return false; } // ISF positions are not decoded by LibTrueHD
    int bank = e->flags & TRUEHD_ATMOS_ELEMENT_HEAD_TRACK_DISABLE ? NV_ATMOS_CHANNELS : 0;
    for (int c = NV_ATMOS_CHANNELS-1; c >= 0; c--) {
        out[bank+c] = out[c] * e->gain;
        if (bank) out[c] = 0;
    }
    return true;
}

void nv_atmos_reset(struct nv_atmos_renderer *r) { memset(r, 0, sizeof(*r)); }

static int companion(const TrueHDAtmosBlock *b, float *const out[NV_ATMOS_BUSES])
{
    if (!b->bed_channel_count || b->bed_channel_count > TRUEHD_ATMOS_MAX_CHANNELS ||
        !b->bed_channels || !b->bed_speakers) return -1;
    for (unsigned i = 0; i < b->bed_channel_count; i++) {
        float g[NV_ATMOS_CHANNELS];
        if (!b->bed_channels[i] || !bed_gains(b->bed_speakers[i], g)) return -1;
        for (int c = 0; c < NV_ATMOS_CHANNELS; c++)
            for (unsigned f = 0; f < b->frame_count; f++) out[c][f] += b->bed_channels[i][f]*g[c];
    }
    return 1;
}

int nv_atmos_render(struct nv_atmos_renderer *r, const TrueHDAtmosBlock *b,
                    float *const out[NV_ATMOS_BUSES])
{
    if (!b || b->channel_count > TRUEHD_ATMOS_MAX_CHANNELS || !b->channel_count ||
        b->frame_count > TRUEHD_ATMOS_MAX_BLOCK_FRAMES || !b->channels || !b->speakers) return -1;
    for (int c = 0; c < NV_ATMOS_BUSES; c++) {
        if (!out[c]) return -1;
        memset(out[c], 0, sizeof(float) * b->frame_count);
    }
    for (unsigned i = 0; i < b->channel_count; i++) if (!b->channels[i]) return -1;
    const TrueHDAtmosMetadata *m = b->metadata;
    if (m && (m->element_count != b->channel_count || m->update_count > 256 ||
        (m->update_count && !m->updates))) return -1;
    if (m && m->isf_count) return companion(b, out);
    if (!r->configured || r->serial != b->layout_serial ||
        r->channels != b->channel_count || b->flags & TRUEHD_ATMOS_BLOCK_DISCONTINUITY) {
        nv_atmos_reset(r);
        r->serial = b->layout_serial; r->channels = b->channel_count;
        for (unsigned i = 0; i < b->channel_count; i++)
            if (!bed_gains(b->speakers[i], r->gain[i])) return companion(b, out);
        r->configured = true;
    }
    unsigned update = 0;
    for (unsigned f = 0; f < b->frame_count; f++) {
        while (m && update < m->update_count && m->updates[update].frame_offset == f) {
            const TrueHDAtmosMetadataUpdate *u = &m->updates[update++];
            if (!u->elements) return -1;
            for (unsigned i = 0; i < b->channel_count; i++) {
                const TrueHDAtmosElement *e = &u->elements[i];
                if (!(e->flags & TRUEHD_ATMOS_ELEMENT_CHANGED) && r->known[i]) continue;
                if (!element_gains(e, r->target[i])) return -1;
                r->remaining[i] = r->known[i] ? u->ramp_frames : 0;
                if (!r->remaining[i]) memcpy(r->gain[i], r->target[i], sizeof(r->gain[i]));
                r->known[i] = true;
            }
        }
        for (unsigned i = 0; i < b->channel_count; i++) {
            for (int c = 0; c < NV_ATMOS_BUSES; c++) {
                if (r->remaining[i]) r->gain[i][c] += (r->target[i][c]-r->gain[i][c])/r->remaining[i];
                out[c][f] += b->channels[i][f] * r->gain[i][c];
            }
            if (r->remaining[i]) r->remaining[i]--;
        }
    }
    return m && update != m->update_count ? -1 : 0;
}
