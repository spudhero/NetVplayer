/* Scalar curve validation independent of a window/GPU. Run with sanitizers.
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#include <assert.h>
#include <stdio.h>
#include "../mpv/video/out/hdr_vivid.h"

static AVDynamicHDRVivid scene(void)
{
    AVDynamicHDRVivid v = {.system_start_code = 1, .num_windows = 1};
    v.params[0] = (AVHDRVividColorTransformParams) {
        .minimum_maxrgb = {0,4095}, .average_maxrgb = {1843,4095},
        .variance_maxrgb = {1843,4095}, .maximum_maxrgb = {3686,4095},
    };
    return v;
}

int main(void)
{
    struct nv_vivid_curve c;
    AVDynamicHDRVivid v = scene();
    // Published ST 2084 anchors and separately calculated §11.2 base curve.
    assert(fabs(nv_vivid_pq(100) - .508078421517) < 1e-10);
    assert(fabs(nv_vivid_nits(.751827096247) - 1000) < 1e-6);
    assert(nv_vivid_prepare(&v, 203, .001, 1000, true, &c));
    assert(fabs(c.base.p - 4.73756105006105) < 1e-10);
    assert(fabs(c.base.a - .694055953333995) < 1e-10);
    assert(fabs(nv_vivid_curve_at(&c, .6) - .506017239845577) < 1e-10);
    for (int i = 0; i <= 4096; i++) {
        double x = i / 4096.0, y = nv_vivid_curve_at(&c, x);
        assert(isfinite(y) && y >= 0 && y <= c.target);
    }
    // First spline is continuous in both value and first derivative.
    assert(fabs(nv_vivid_spline_at(&c.first, c.first.x[0]) -
                (c.linear_slope * c.first.x[0] + c.offset)) < 1e-10);
    assert(fabs(nv_vivid_spline_at(&c.first, c.first.x[2]) -
                nv_vivid_base_at(&c.base, c.first.x[2])) < 1e-10);
    assert(!nv_vivid_prepare(&v, NAN, 0, 1000, false, &c));
    assert(!nv_vivid_prepare(&v, 100, 100, 1000, false, &c));
    v.system_start_code = 2;
    assert(!nv_vivid_prepare(&v, 400, 0, 1000, false, &c));
    v = scene(); v.params[0].average_maxrgb.den = 0;
    assert(!nv_vivid_prepare(&v, 400, 0, 1000, false, &c));
    v = scene(); v.params[0].tone_mapping_mode_flag = 1;
    assert(!nv_vivid_prepare(&v, 400, 0, 1000, false, &c));

    // Modes 1 and 3 have no MB codeword in the FFmpeg structure. Inactive
    // rationals must not be read; delta codewords are normalized by 1023.
    v = scene();
    AVHDRVividColorTransformParams *w = &v.params[0];
    w->tone_mapping_mode_flag = 1; w->tone_mapping_param_num = 1;
    AVHDRVividColorToneMappingParams *tm = &w->tm_params[0];
    tm->targeted_system_display_maximum_luminance = (AVRational){2672,4095};
    tm->three_Spline_enable_flag = 1; tm->three_Spline_num = 1;
    tm->three_spline[0] = (AVHDRVivid3SplineParams) {
        .th_mode = 1, .th_enable = {2200,4095}, .th_delta1 = {400,1023},
        .th_delta2 = {400,1023}, .enable_strength = {127,255},
    };
    assert(nv_vivid_prepare(&v, 400, 0, 1000, false, &c));
    assert(c.second.active && c.second.tail);
    tm->three_spline[0].th_mode = 3;
    assert(nv_vivid_prepare(&v, 400, 0, 1000, false, &c));
    assert(c.second.active && !c.second.tail);
    w->color_saturation_mapping_flag = 1; w->color_saturation_num = 0;
    assert(nv_vivid_prepare(&v, 400, 0, 1000, false, &c));
    puts("HDR Vivid scalar references, splines, metadata validation: passed");
    return 0;
}
