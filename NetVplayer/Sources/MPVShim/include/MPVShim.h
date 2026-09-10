#ifndef NETVPLAYER_MPV_SHIM_H
#define NETVPLAYER_MPV_SHIM_H

#include <stdint.h>

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
    const char *error_string;
    const char *log_prefix;
    const char *log_level;
    const char *log_text;
    double double_value;
    int flag_value;
    int64_t int64_value;
} NVMPVEvent;

typedef void (*NVMPVRenderUpdateCallback)(void *ctx);

NVMPVContext *nv_mpv_create(void);
void nv_mpv_destroy(NVMPVContext *context);

const char *nv_mpv_last_error(NVMPVContext *context);
const char *nv_mpv_loaded_library_path(NVMPVContext *context);

int nv_mpv_set_option_string(NVMPVContext *context, const char *name, const char *value);
int nv_mpv_set_option_int64(NVMPVContext *context, const char *name, int64_t value);
int nv_mpv_request_log_messages(NVMPVContext *context, const char *min_level);
int nv_mpv_initialize(NVMPVContext *context);

int nv_mpv_set_property_string(NVMPVContext *context, const char *name, const char *value);
int nv_mpv_set_property_double(NVMPVContext *context, const char *name, double value);
int nv_mpv_set_property_flag(NVMPVContext *context, const char *name, int value);

int nv_mpv_command1(NVMPVContext *context, const char *arg0);
int nv_mpv_command2(NVMPVContext *context, const char *arg0, const char *arg1);
int nv_mpv_command3(NVMPVContext *context, const char *arg0, const char *arg1, const char *arg2);
int nv_mpv_command3_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2);
int nv_mpv_command4(NVMPVContext *context, const char *arg0, const char *arg1, const char *arg2, const char *arg3);
int nv_mpv_command4_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2, const char *arg3);

int nv_mpv_clear_http_headers(NVMPVContext *context);
int nv_mpv_append_http_header(NVMPVContext *context, const char *header);

int nv_mpv_observe_double(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_observe_flag(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_observe_int64(NVMPVContext *context, uint64_t userdata, const char *name);
int nv_mpv_wait_event(NVMPVContext *context, double timeout, NVMPVEvent *event);

int nv_mpv_create_render_context(NVMPVContext *context, NVMPVRenderUpdateCallback callback, void *callback_context);
int nv_mpv_free_render_context(NVMPVContext *context);
int nv_mpv_render(NVMPVContext *context, int fbo, int width, int height, int flip_y);
void nv_mpv_report_swap(NVMPVContext *context);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import "NVMPVOpenGLView.h"
#endif

#endif
