/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef NV_ATMOS_BINAURAL_H
#define NV_ATMOS_BINAURAL_H
#include <stdbool.h>
#include <stdint.h>
#include "atmos_render.h"
struct nv_binaural_status {
    uint64_t frames, poses;
    bool tracking_requested, tracking_active;
    double pose_age;
};
void *nv_binaural_create(int rate, bool tracking);
void nv_binaural_destroy(void *handle);
void nv_binaural_reset(void *handle);
bool nv_binaural_render(void *handle, float *const planes[NV_ATMOS_BUSES],
                        int frames, float *left, float *right);
void nv_binaural_get_status(void *handle, struct nv_binaural_status *out);
/* Test hook: explicit synthetic listener rotation; never counts as a sensor. */
bool nv_binaural_set_test_orientation(void *handle, float yaw, float pitch, float roll);
#endif
