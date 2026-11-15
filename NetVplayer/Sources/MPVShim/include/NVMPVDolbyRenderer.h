#ifndef NETVPLAYER_DOLBY_RENDERER_H
#define NETVPLAYER_DOLBY_RENDERER_H
#include <stdint.h>

// Versioned, optional runtime ABI. A stock libmpv returns an unsupported error.
// Counters describe GPU reconstruction, never Dolby Vision HDMI signaling.
typedef struct NVMPVDolbyRendererStatus {
    uint32_t size, version;
    uint64_t capabilities, generation;
    uint64_t rendered_frames, dovi_frames, enhancement_frames, fel_frames;
    uint64_t failures, frame_flags;
    double pts;
} NVMPVDolbyRendererStatus;
#endif
