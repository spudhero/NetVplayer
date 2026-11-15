#ifndef NV_MPV_DOLBY_VISION_H
#define NV_MPV_DOLBY_VISION_H
#include <stdint.h>
// A bounded first-frame observation, not a certification of the entire file.
typedef struct NVMPVDolbyVisionProbe {
    int status; // 0 unavailable, 1 inspected, 2 budget exhausted
    int profile, level, compatibility_id; // -1 means absent/unknown
    int rpu_flag, el_flag, bl_flag;
    int frame_rpu, frame_metadata, rpu_profile, full_range, disable_residual;
    int stream_index;
    int inferred_profile; // FFmpeg's HEVC RPU header rule; never a compatibility ID
    int64_t bytes_read;
} NVMPVDolbyVisionProbe;
// Local regular files only, custom AVIO, no network or nested URL opens.
// Uses the same library dependency tree as the active libmpv, with ABI checks.
NVMPVDolbyVisionProbe nv_mpv_probe_local_dovi(const char *library, const char *path);
#endif
