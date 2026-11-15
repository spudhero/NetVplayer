#ifndef NETVPLAYER_MPV_SHIM_H
#define NETVPLAYER_MPV_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include "NVMPVDolbyVision.h"
#include "NVMPVDolbyRenderer.h"
#include "NVSubtitleBitmap.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NVMPVContext NVMPVContext;

typedef struct NVMPVEvent {
    int event_id;
    int error;
    uint64_t reply_userdata;
    int end_file_error;
    int end_file_reason;
    int format;
    const char *event_name;
    const char *property_name;
    const char *string_value;
    // Borrowed mpv_node; valid only until the next nv_mpv_wait_event call.
    const void *node_value;
    const char *error_string;
    const char *log_prefix;
    const char *log_level;
    const char *log_text;
    double double_value;
    int flag_value;
    int64_t int64_value;
} NVMPVEvent;

typedef void (*NVMPVRenderUpdateCallback)(void *ctx);
typedef void (*NVMPVEventWakeupCallback)(void *ctx);

typedef struct NVMPVBlackBarSample {
    int width, height;
    int left, top, right, bottom;
} NVMPVBlackBarSample;
// Examines borrowed, in-memory screenshot pixels. No image is written or retained.
int nv_mpv_detect_black_bars(const void *pixels, size_t length, int width, int height, int stride, NVMPVBlackBarSample *sample);
int nv_mpv_event_black_bars(const NVMPVEvent *event, NVMPVBlackBarSample *sample);

NVMPVContext *nv_mpv_create(void);
void nv_mpv_destroy(NVMPVContext *context);

const char *nv_mpv_last_error(NVMPVContext *context);
const char *nv_mpv_loaded_library_path(NVMPVContext *context);
uint64_t nv_mpv_runtime_capabilities(NVMPVContext *context);

int nv_mpv_set_option_string(NVMPVContext *context, const char *name, const char *value);
int nv_mpv_set_option_int64(NVMPVContext *context, const char *name, int64_t value);
int nv_mpv_request_log_messages(NVMPVContext *context, const char *min_level);
int nv_mpv_initialize(NVMPVContext *context);
// Returns -1 when an older runtime lacks this optional API. The callback only
// signals the host; its userdata must outlive unregistration and native destroy.
int nv_mpv_set_wakeup_callback(NVMPVContext *context, NVMPVEventWakeupCallback callback, void *userdata);

int nv_mpv_set_property_string(NVMPVContext *context, const char *name, const char *value);
int nv_mpv_set_property_double(NVMPVContext *context, const char *name, double value);
int nv_mpv_set_property_flag(NVMPVContext *context, const char *name, int value);
// Queue runtime changes without waiting for the core/render threads.
int nv_mpv_set_property_double_async(NVMPVContext *context, uint64_t reply_userdata, const char *name, double value);
int nv_mpv_set_property_flag_async(NVMPVContext *context, uint64_t reply_userdata, const char *name, int value);
int nv_mpv_set_property_string_async(NVMPVContext *context, uint64_t reply_userdata, const char *name, const char *value);
// Copies a structured property as bounded JSON; caller frees it with nv_mpv_free_string.
char *nv_mpv_copy_property_json(NVMPVContext *context, const char *name);
// Nonblocking NODE request. Replies retain their request ID across media changes.
int nv_mpv_get_property_async(NVMPVContext *context, uint64_t reply_userdata, const char *name);
char *nv_mpv_copy_event_property_json(const NVMPVEvent *event);
// Last format actually submitted by this host, or 0 before a frame is rendered.
int nv_mpv_render_target_format(NVMPVContext *context);
// mpv's option string representation can be round-tripped to restore runtime defaults.
char *nv_mpv_copy_property_string(NVMPVContext *context, const char *name);
void nv_mpv_free_string(char *value);
int nv_mpv_observe_change(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_get_media_track_counts(NVMPVContext *context, int64_t *audio_count, int64_t *video_count);

int nv_mpv_command1(NVMPVContext *context, const char *arg0);
int nv_mpv_command2(NVMPVContext *context, const char *arg0, const char *arg1);
int nv_mpv_command3(NVMPVContext *context, const char *arg0, const char *arg1, const char *arg2);
int nv_mpv_command3_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2);
int nv_mpv_command4(NVMPVContext *context, const char *arg0, const char *arg1, const char *arg2, const char *arg3);
int nv_mpv_command4_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2, const char *arg3);
int nv_mpv_command5_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2, const char *arg3, const char *arg4);

int nv_mpv_clear_http_headers(NVMPVContext *context);
int nv_mpv_append_http_header(NVMPVContext *context, const char *header);

int nv_mpv_observe_double(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_observe_flag(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_observe_int64(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_wait_event(NVMPVContext *context, double timeout, NVMPVEvent *event);

int nv_mpv_create_render_context(NVMPVContext *context, NVMPVRenderUpdateCallback callback, void *callback_context);
int nv_mpv_free_render_context(NVMPVContext *context);
NVMPVDolbyRendererStatus nv_mpv_dolby_renderer_status(NVMPVContext *context);
int nv_mpv_set_render_icc(NVMPVContext *context, const void *bytes, size_t length);
int nv_mpv_render(NVMPVContext *context, int fbo, int width, int height, int flip_y);
// Consume pending frame work without drawing it; clear the host target to black.
int nv_mpv_render_suppressed(NVMPVContext *context, int fbo);
int nv_mpv_render_fp16(NVMPVContext *context, int fbo, int width, int height, int flip_y);
// Synchronous, borrowed AVFrame capture; presentation must happen after return.
typedef void (*NVMPVSourceFrameCapture)(void *opaque, const void *frame, double pts, uint64_t generation);
int nv_mpv_render_fp16_source(NVMPVContext *context, int fbo, int width, int height,
                             NVMPVSourceFrameCapture capture, void *opaque);
// Opt-in render-context facts; -1 means unavailable/failed. No core property read.
void nv_mpv_observe_render_frames(NVMPVContext *context, int enabled);
int64_t nv_mpv_last_render_frame_flags(NVMPVContext *context);
void nv_mpv_report_swap(NVMPVContext *context);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import "NVMPVOpenGLView.h"
#import "NVMPVHDRSurface.h"
#import "NVDolbyVisionSurface.h"
#import "NVSystemHDRDisplay.h"
#import "NVMPVThumbnailSurface.h"
#endif

#endif
