/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef NV_TRUEHD_OBJECTS_H
#define NV_TRUEHD_OBJECTS_H
#include <stdbool.h>
#include <stdint.h>
struct nv_object_audio_status {
    int mode, rate, presentation, elements;
    bool has_objects, metadata_seen, tracking_requested, tracking_active;
    uint64_t frames, object_blocks, metadata_updates, fallback_blocks;
    uint64_t decode_errors, sync_errors, metadata_errors, binaural_frames, poses;
    double pose_age;
};
#endif
