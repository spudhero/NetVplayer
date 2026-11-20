/* HDR Vivid display adaptation, GY/T 358-2022 sections 9-11 and annex A.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * FFmpeg owns/parses the bitstream metadata. This module consumes the decoded
 * AVFrame side data; all luminance curve coordinates are normalized PQ, not
 * nits. No HDMI signalling or decoder state is inferred from the container.
 */
#ifndef NETVPLAYER_HDR_VIVID_H
#define NETVPLAYER_HDR_VIVID_H
#include <math.h>
#include <stdbool.h>
#include <string.h>
#include <libavutil/hdr_dynamic_vivid_metadata.h>

struct nv_vivid_base { double p, m, n, a, b, k1, k2, k3; };
struct nv_vivid_spline { double x[3], c[2][4], end, slope; bool active, tail; };
struct nv_vivid_curve {
    struct nv_vivid_base base;
    struct nv_vivid_spline first, second;
    double linear_end, linear_slope, offset;
    double target, reference, saturation[2];
    int saturation_count;
};

static inline double nv_vivid_clip(double x, double lo, double hi)
{ return fmin(fmax(x, lo), hi); }
static inline double nv_vivid_mix(double a, double b, double t)
{ return a + (b - a) * nv_vivid_clip(t, 0, 1); }
static inline double nv_vivid_pq(double nits)
{
    double p = pow(nv_vivid_clip(nits / 10000, 0, 1), 2610.0 / 16384);
    return pow((3424.0 / 4096 + 2413.0 / 128 * p) /
               (1 + 2392.0 / 128 * p), 2523.0 / 32);
}
static inline double nv_vivid_nits(double pq)
{
    double p = pow(nv_vivid_clip(pq, 0, 1), 32.0 / 2523);
    return 10000 * pow(fmax(p - 3424.0 / 4096, 0) /
                      (2413.0 / 128 - 2392.0 / 128 * p), 16384.0 / 2610);
}
static inline double nv_vivid_rational(AVRational q, double hi, bool *ok)
{
    if (q.den <= 0 || q.num < 0 || (double)q.num > hi * q.den) {
        *ok = false;
        return 0;
    }
    return (double)q.num / q.den;
}
static inline double nv_vivid_unit(const struct nv_vivid_base *b, double x)
{
    double xn = pow(fmax(x, 0), b->n);
    double den = (b->k1 * b->p - b->k2) * xn + b->k3;
    return den > 0 ? pow(b->p * xn / den, b->m) : NAN;
}
static inline double nv_vivid_base_at(const struct nv_vivid_base *b, double x)
{ return b->a * nv_vivid_unit(b, x) + b->b; }
static inline double nv_vivid_derivative(const struct nv_vivid_base *b, double x)
{
    // The analytic derivative at zero may diverge for legal fractional powers.
    x = fmax(x, 1e-7);
    double xn = pow(x, b->n), den = (b->k1 * b->p - b->k2) * xn + b->k3;
    return b->a * b->m * b->n * b->p * b->k3 * pow(x, b->n - 1) *
           pow(b->p * xn / den, b->m - 1) / (den * den);
}

// Two C2 cubic intervals with the specified endpoint derivatives (§10.3.3).
static inline bool nv_vivid_spline_make(struct nv_vivid_spline *s,
                                       double x0, double x1, double x2,
                                       double y0, double y1, double y2,
                                       double d0, double d2)
{
    double h1 = x1 - x0, h2 = x2 - x1;
    if (h1 < 1e-7 || h2 < 1e-7)
        return false;
    double d1 = (3 * h2 * h2 * (y1 - y0) + 3 * h1 * h1 * (y2 - y1) -
                 d0 * h1 * h2 * h2 - d2 * h1 * h1 * h2) /
                (2 * h1 * h2 * (h1 + h2));
    double y[] = {y0, y1, y2}, d[] = {d0, d1, d2}, h[] = {h1, h2};
    s->x[0] = x0; s->x[1] = x1; s->x[2] = x2;
    for (int i = 0; i < 2; i++) {
        s->c[i][0] = y[i];
        s->c[i][1] = d[i];
        s->c[i][2] = (3 * (y[i+1] - y[i]) / h[i] - 2 * d[i] - d[i+1]) / h[i];
        s->c[i][3] = (2 * (y[i] - y[i+1]) / h[i] + d[i] + d[i+1]) / (h[i] * h[i]);
        for (int j = 0; j < 4; j++)
            if (!isfinite(s->c[i][j])) return false;
    }
    s->end = y2; s->slope = d2; s->active = true;
    return true;
}
static inline double nv_vivid_spline_at(const struct nv_vivid_spline *s, double x)
{
    int i = x < s->x[1] ? 0 : 1;
    const double *c = s->c[i];
    double t = x - s->x[i];
    return ((c[3] * t + c[2]) * t + c[1]) * t + c[0];
}
static inline double nv_vivid_curve_at(const struct nv_vivid_curve *c, double x)
{
    double y;
    if (x <= c->linear_end) y = c->linear_slope * x + c->offset;
    else if (x < c->first.x[2]) y = nv_vivid_spline_at(&c->first, x);
    else if (c->second.active && x >= c->second.x[0]) {
        if (x <= c->second.x[2]) y = nv_vivid_spline_at(&c->second, x);
        else if (c->second.tail) y = c->second.end + c->second.slope * (x - c->second.x[2]);
        else y = nv_vivid_base_at(&c->base, x);
    } else y = nv_vivid_base_at(&c->base, x);
    return nv_vivid_clip(y, 0, c->target);
}

static inline bool nv_vivid_prepare(const AVDynamicHDRVivid *v, double peak,
                                    double black, double mastering_peak, bool sdr,
                                    struct nv_vivid_curve *c)
{
    memset(c, 0, sizeof(*c));
    // New system-start codes have different semantics and must never be
    // silently treated as version 1. Fall back to the ordinary PQ/HLG path.
    if (!v || v->system_start_code != 1 || v->num_windows != 1 ||
        !isfinite(peak) || peak <= 0 || peak > 10000 || !isfinite(black) ||
        black < 0 || black >= peak)
        return false;
    const AVHDRVividColorTransformParams *w = &v->params[0];
    bool ok = true;
    double minimum = nv_vivid_rational(w->minimum_maxrgb, 1, &ok);
    double avg = nv_vivid_rational(w->average_maxrgb, 1, &ok);
    double variance = nv_vivid_rational(w->variance_maxrgb, 1, &ok);
    double maximum = nv_vivid_rational(w->maximum_maxrgb, 1, &ok);
    if (!ok || minimum > maximum || avg < minimum || avg > maximum ||
        (w->tone_mapping_mode_flag != 0 && w->tone_mapping_mode_flag != 1) ||
        (w->color_saturation_mapping_flag != 0 && w->color_saturation_mapping_flag != 1))
        return false;
    c->target = nv_vivid_pq(peak);
    c->reference = nv_vivid_pq(isfinite(mastering_peak) && mastering_peak > 0
                              ? mastering_peak : 1000);
    double minpq = nv_vivid_pq(black);
    double maxlum = fmax(c->target, nv_vivid_clip(.2 * maximum + .8 * avg +
                                                .4 * variance, .5081, c->reference));
    struct nv_vivid_base def = {.m = 2.4, .n = 1, .b = minpq, .k1 = 1, .k2 = 1, .k3 = 1};
    def.p = sdr ? nv_vivid_mix(6, 3.5, (avg - .1) / .5) +
                  nv_vivid_mix(.3, .6, (maxlum - .67) / .08)
                : nv_vivid_mix(4, 3.5, (avg - .3) / .3) +
                  nv_vivid_mix(0, .6, (maxlum - .75) / .15);
    def.a = (c->target - minpq) / nv_vivid_unit(&def, maxlum);
    c->base = def;
    const AVHDRVividColorToneMappingParams *tm = NULL;
    int mode = 0;
    bool authored = false, fixed = false;
    if (w->tone_mapping_mode_flag) {
        if (w->tone_mapping_param_num < 1 || w->tone_mapping_param_num > 2) return false;
        // Pick the authored target nearest to this display in PQ coordinates.
        // Adapt its base curve to the actual peak, rather than changing the
        // OS display mode or outputting the nominal mastering target.
        double distance = 2;
        for (int i = 0; i < w->tone_mapping_param_num; i++) {
            double t = nv_vivid_rational(w->tm_params[i].targeted_system_display_maximum_luminance, 1, &ok);
            if (!ok || t <= 0) return false;
            if (fabs(t - c->target) < distance) { distance = fabs(t - c->target); tm = &w->tm_params[i]; }
        }
        if (tm->base_enable_flag != 0 && tm->base_enable_flag != 1) return false;
        authored = tm->base_enable_flag;
        if (authored) {
            double target0 = nv_vivid_rational(tm->targeted_system_display_maximum_luminance, 1, &ok);
            mode = tm->base_param_Delta_enable_mode;
            if (mode < 0 || mode > 6 || tm->base_param_k1 < 0 || tm->base_param_k1 > 1 ||
                tm->base_param_k2 < 0 || tm->base_param_k2 > 1 ||
                tm->base_param_k3 < 1 || tm->base_param_k3 > 2) return false;
            struct nv_vivid_base b = {
                .p = 10 * nv_vivid_rational(tm->base_param_m_p, 1, &ok),
                .m = nv_vivid_rational(tm->base_param_m_m, 6.3, &ok),
                .n = nv_vivid_rational(tm->base_param_m_n, 6.3, &ok),
                .a = nv_vivid_rational(tm->base_param_m_a, 1, &ok),
                .b = .25 * nv_vivid_rational(tm->base_param_m_b, 1, &ok),
                .k1 = tm->base_param_k1, .k2 = tm->base_param_k2,
                .k3 = tm->base_param_k3 == 2 ? maximum : 1,
            };
            double delta = nv_vivid_rational(tm->base_param_Delta, 1, &ok);
            if (!ok || b.p <= 0 || b.m <= 0 || b.n <= 0 || b.k3 <= 0) return false;
            fixed = fabs(target0 - c->target) <= .5 / 4095 || mode == 3;
            if (!fixed) {
                double amount = delta * sqrt(fabs(peak - nv_vivid_nits(target0)) / 100);
                if (mode == 1 || mode == 5) {
                    b.p = nv_vivid_mix(b.p, def.p, amount);
                    b.m = nv_vivid_mix(b.m, def.m, amount);
                    b.n = nv_vivid_mix(b.n, def.n, amount);
                    b.k1 = nv_vivid_mix(b.k1, def.k1, amount);
                    b.k2 = nv_vivid_mix(b.k2, def.k2, amount);
                    b.k3 = nv_vivid_mix(b.k3, def.k3, amount);
                    b.b = minpq;
                    b.a = (c->target - minpq) / nv_vivid_unit(&b, maxlum);
                } else {
                    b.a *= (c->target - minpq) / target0;
                    b.b *= (c->target - minpq) / target0;
                    b.p = nv_vivid_clip(b.p + (mode == 2 || mode == 6 ? -amount : amount), 3, 7.5);
                }
            }
            c->base = b;
        }
    }
    const AVHDRVivid3SplineParams *sp[2] = {0};
    double th[2] = {0}, d1[2] = {0}, d2[2] = {0}, strength[2] = {0}, mb[2] = {0};
    if (tm && tm->three_Spline_enable_flag) {
        if (tm->three_Spline_enable_flag != 1 || tm->three_Spline_num < 1 || tm->three_Spline_num > 2) return false;
        for (int i = 0; i < tm->three_Spline_num; i++) {
            const AVHDRVivid3SplineParams *s = &tm->three_spline[i];
            int slot = s->th_mode == 0 ? 0 : 1;
            if (s->th_mode < 0 || s->th_mode > 3 || sp[slot] || (i == 1 && slot == 0)) return false;
            sp[slot] = s;
            th[slot] = nv_vivid_rational(s->th_enable, 1, &ok);
            // FFmpeg exposes these two codewords divided by 1023 (despite
            // the public header's older 0.25/1023 wording).
            d1[slot] = .25 * nv_vivid_rational(s->th_delta1, 1, &ok);
            d2[slot] = .25 * nv_vivid_rational(s->th_delta2, 1, &ok);
            double raw = slot == 0 || s->th_mode == 2
                ? round(255 * nv_vivid_rational(s->th_enable_mb, 1, &ok)) : 0;
            // Mode 0 packs a six-bit slope and a two-bit dark offset. Extract
            // the six MSBs before normalizing (T/UWA 005.1 §7.4.23, range 0..1).
            // Masking alone leaves the slope four times too large, folding
            // the shadow spline back on itself for legal authored metadata.
            mb[slot] = slot == 0 ? ((int)raw >> 2) / 63.0 : raw * 1.1 / 255;
            strength[slot] = nv_vivid_clip((255 * nv_vivid_rational(s->enable_strength, 1, &ok) - 127) / 127, -1, 1);
            if (slot == 0) c->offset = ((int)raw & 3) * .1 / 3;
            if (!ok || d1[slot] <= 0 || d2[slot] <= 0) return false;
        }
    }
    struct nv_vivid_base *b = &c->base;
    double at = b->p < 2.5 ? .990 : b->p < 3.5 ? .990 - (b->p - 2.5) * .111 :
                b->p < 4.5 ? .879 - (b->p - 3.5) * .102 :
                b->p < 7.5 ? .777 - (b->p - 4.5) * .079 : .540;
    double wa = 0;
    if (authored && b->a > at) {
        double h = at * nv_vivid_unit(b, maxlum) / maxlum;
        wa = (c->target / maxlum - h) / (1 - h);
    }
    if (!fixed) {
        double b0 = mode >= 3 || !authored || b->a <= at ? b->b : (1 - wa) * b->b;
        double x = th[0] + d1[0] + d2[0], y = b->a * nv_vivid_unit(b, x) + b0;
        b->b = mode != 2 && mode != 3 && mode != 6 && y > x && y > 0 ? b0 - (y - x) : b0;
    }
    c->linear_end = sdr ? 0 : nv_vivid_mix(.25, .1, (avg - .3) / .3);
    c->linear_slope = nv_vivid_mix(1, sdr ? .9 : .96, (avg - .3) / .3);
    if (sp[0]) { c->linear_end = th[0]; c->linear_slope = mb[0]; }
    if (authored && mode < 3 && b->a > at) {
        c->linear_slope = nv_vivid_clip(c->linear_slope + (1 - c->linear_slope) * wa, c->linear_slope, 1);
        c->linear_end = nv_vivid_clip(c->linear_end + (maxlum - c->linear_end) * wa, c->linear_end, 1);
    }
    double x0 = c->linear_end, x1 = x0 + (sp[0] ? d1[0] : .15),
           x2 = x1 + (sp[0] ? d2[0] : .075);
    double y0 = c->linear_slope * x0 + c->offset, y2 = nv_vivid_base_at(b, x2);
    double y1 = sdr && !sp[0] ? nv_vivid_base_at(b, x1) :
                y0 + (y2 - y0) * (x1 - x0) / (x2 - x0);
    if (sp[0]) {
        y1 += (y2 - y0) * strength[0] / 2;
        if (mode != 2 && mode != 3 && mode != 6) { y1 = fmin(y1, x1); y2 = fmin(y2, x2); }
    }
    if (!nv_vivid_spline_make(&c->first, x0, x1, x2, y0, y1, y2,
                               c->linear_slope, nv_vivid_derivative(b, x2))) return false;
    if (sp[1]) {
        x0 = th[1]; x1 = x0 + d1[1]; x2 = x1 + d2[1];
        if (x2 > c->first.x[2]) {
            if (x0 < c->first.x[2]) { x0 = c->first.x[2]; x1 = (x0 + x2) / 2; }
            y0 = nv_vivid_base_at(b, x0); y2 = nv_vivid_base_at(b, x2);
            int smode = sp[1]->th_mode;
            if (smode == 1 || smode == 2) {
                y2 = mode == 3 ? av_q2d(tm->targeted_system_display_maximum_luminance) : c->target;
                if (y2 > x2 && mode != 2 && mode != 3 && mode != 6) { x2 = y2; x1 = (x0 + x2) / 2; }
            }
            y1 = y0 + (y2 - y0) * (x1 - x0) / (x2 - x0) + (y2 - y0) * strength[1] / 2;
            if ((smode == 1 || smode == 2) && mode != 2 && mode != 3 && mode != 6) y1 = fmin(y1, x1);
            double slope0 = nv_vivid_derivative(b, x0), slope2 = nv_vivid_derivative(b, x2);
            if (smode == 1) {
                double mid = (y2 - y0) / (x2 - x0);
                slope2 = strength[1] < 0 ? nv_vivid_mix(mid, fmax(slope0, .1 * mid), -strength[1]) :
                                          nv_vivid_mix(mid, fmax(slope0, (y2 - y0) / (x2 - x1)), strength[1]);
            } else if (smode == 2) slope2 -= mb[1];
            if ((smode == 1 || smode == 2) && fabs(y2 - x2) < 1e-10 && mode != 2 && mode != 3 && mode != 6) slope2 = 1;
            if (!nv_vivid_spline_make(&c->second, x0, x1, x2, y0, y1, y2, slope0, slope2)) return false;
            c->second.tail = smode == 1 || smode == 2;
        }
    }
    if (w->color_saturation_mapping_flag) {
        if (w->color_saturation_num < 0 || w->color_saturation_num > 7) return false;
        c->saturation_count = w->color_saturation_num;
        for (int i = 0; i < w->color_saturation_num; i++) {
            double gain = nv_vivid_rational(w->color_saturation_gain[i], 255.0 / 128, &ok);
            if (i < 2) c->saturation[i] = gain;
        }
    }
    // Validate every sampled interval before sending coefficients to the GPU.
    for (int i = 0; i <= 256; i++)
        if (!isfinite(nv_vivid_base_at(b, i / 256.0))) ok = false;
    return ok;
}

// Compact, dynamic uniforms shared with the RGB-stage GPU hook. Coefficients
// change per decoded frame; GLSL source stays stable to avoid shader churn.
static inline void nv_vivid_pack(const struct nv_vivid_curve *c, float u[48])
{
    memset(u, 0, 48 * sizeof(*u));
    const struct nv_vivid_base *b = &c->base;
    double base[] = {b->p,b->m,b->n,b->a,b->b,b->k1,b->k2,b->k3};
    for (int i = 0; i < 8; i++) u[i] = base[i];
    u[8] = c->linear_end; u[9] = c->linear_slope; u[10] = c->offset;
    const struct nv_vivid_spline *splines[] = {&c->first, &c->second};
    for (int s = 0; s < 2; s++) {
        int o = 11 + s * 11;
        for (int i = 0; i < 3; i++) u[o+i] = splines[s]->x[i];
        for (int i = 0; i < 8; i++) u[o+3+i] = splines[s]->c[i/4][i%4];
    }
    u[33] = c->second.active; u[34] = c->second.tail;
    u[35] = c->second.end; u[36] = c->second.slope;
    u[37] = c->target; u[38] = c->reference;
    u[39] = c->saturation_count; u[40] = c->saturation[0];
    int raw = (int)round(c->saturation[1] * 128);
    u[41] = (raw & 0xfc) / 128.0; u[42] = pow(2, 2 * (raw & 3));
    u[43] = nv_vivid_clip(pow(nv_vivid_curve_at(c, c->target) / c->target,
                             c->saturation[0]), .8, 1);
}
#endif
