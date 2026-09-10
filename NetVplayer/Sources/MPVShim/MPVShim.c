#include "MPVShim.h"

#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct NVMPVContext {
    void *library;
    mpv_handle *handle;
    mpv_render_context *render;
    char last_error[512];
    char loaded_path[PATH_MAX];
};

typedef mpv_handle *(*mpv_create_fn)(void);
typedef int (*mpv_initialize_fn)(mpv_handle *);
typedef void (*mpv_terminate_destroy_fn)(mpv_handle *);
typedef int (*mpv_set_option_fn)(mpv_handle *, const char *, mpv_format, void *);
typedef int (*mpv_set_option_string_fn)(mpv_handle *, const char *, const char *);
typedef int (*mpv_set_property_fn)(mpv_handle *, const char *, mpv_format, void *);
typedef int (*mpv_set_property_string_fn)(mpv_handle *, const char *, const char *);
typedef int (*mpv_command_fn)(mpv_handle *, const char **);
typedef int (*mpv_command_async_fn)(mpv_handle *, uint64_t, const char **);
typedef int (*mpv_observe_property_fn)(mpv_handle *, uint64_t, const char *, mpv_format);
typedef mpv_event *(*mpv_wait_event_fn)(mpv_handle *, double);
typedef int (*mpv_request_log_messages_fn)(mpv_handle *, const char *);
typedef const char *(*mpv_event_name_fn)(mpv_event_id);
typedef const char *(*mpv_error_string_fn)(int);
typedef int (*mpv_render_context_create_fn)(mpv_render_context **, mpv_handle *, mpv_render_param *);
typedef void (*mpv_render_context_free_fn)(mpv_render_context *);
typedef void (*mpv_render_context_set_update_callback_fn)(mpv_render_context *, mpv_render_update_fn, void *);
typedef void (*mpv_render_context_render_fn)(mpv_render_context *, mpv_render_param *);
typedef uint64_t (*mpv_render_context_update_fn)(mpv_render_context *);
typedef void (*mpv_render_context_report_swap_fn)(mpv_render_context *);

static mpv_create_fn p_mpv_create = NULL;
static mpv_initialize_fn p_mpv_initialize = NULL;
static mpv_terminate_destroy_fn p_mpv_terminate_destroy = NULL;
static mpv_set_option_fn p_mpv_set_option = NULL;
static mpv_set_option_string_fn p_mpv_set_option_string = NULL;
static mpv_set_property_fn p_mpv_set_property = NULL;
static mpv_set_property_string_fn p_mpv_set_property_string = NULL;
static mpv_command_fn p_mpv_command = NULL;
static mpv_command_async_fn p_mpv_command_async = NULL;
static mpv_observe_property_fn p_mpv_observe_property = NULL;
static mpv_wait_event_fn p_mpv_wait_event = NULL;
static mpv_request_log_messages_fn p_mpv_request_log_messages = NULL;
static mpv_event_name_fn p_mpv_event_name = NULL;
static mpv_error_string_fn p_mpv_error_string = NULL;
static mpv_render_context_create_fn p_mpv_render_context_create = NULL;
static mpv_render_context_free_fn p_mpv_render_context_free = NULL;
static mpv_render_context_set_update_callback_fn p_mpv_render_context_set_update_callback = NULL;
static mpv_render_context_render_fn p_mpv_render_context_render = NULL;
static mpv_render_context_update_fn p_mpv_render_context_update = NULL;
static mpv_render_context_report_swap_fn p_mpv_render_context_report_swap = NULL;

static void set_error(NVMPVContext *context, const char *message) {
    if (!context) { return; }
    snprintf(context->last_error, sizeof(context->last_error), "%s", message ? message : "unknown libmpv error");
}

static void set_mpv_error(NVMPVContext *context, int code) {
    if (!context) { return; }
    const char *message = p_mpv_error_string ? p_mpv_error_string(code) : "libmpv error";
    snprintf(context->last_error, sizeof(context->last_error), "%s (%d)", message ? message : "libmpv error", code);
}

static int executable_framework_path(char *buffer, size_t length) {
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) {
        return 0;
    }
    char resolved[PATH_MAX];
    if (!realpath(exe, resolved)) {
        snprintf(resolved, sizeof(resolved), "%s", exe);
    }
    char *macos = strstr(resolved, "/Contents/MacOS/");
    if (!macos) {
        return 0;
    }
    *macos = '\0';
    snprintf(buffer, length, "%s/Contents/Frameworks/libmpv.2.dylib", resolved);
    return 1;
}

static void *load_library(char *loaded_path, size_t length) {
    const char *env = getenv("NETVPLAYER_LIBMPV_PATH");
    const char *paths[6] = {0};
    char bundled[PATH_MAX] = {0};
    int index = 0;
    if (env && env[0]) {
        paths[index++] = env;
    }
    if (executable_framework_path(bundled, sizeof(bundled))) {
        paths[index++] = bundled;
    }
    paths[index++] = "@rpath/libmpv.2.dylib";
    paths[index++] = "/opt/homebrew/opt/mpv/lib/libmpv.2.dylib";
    paths[index++] = "/usr/local/opt/mpv/lib/libmpv.2.dylib";

    for (int i = 0; i < index; i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            snprintf(loaded_path, length, "%s", paths[i]);
            return handle;
        }
    }
    return NULL;
}

static int load_symbol(void *library, const char *name, void **out) {
    *out = dlsym(library, name);
    return *out != NULL;
}

static int load_symbols(void *library, NVMPVContext *context) {
    if (!load_symbol(library, "mpv_create", (void **)&p_mpv_create)) { set_error(context, "libmpv 缺少 mpv_create"); return 0; }
    if (!load_symbol(library, "mpv_initialize", (void **)&p_mpv_initialize)) { set_error(context, "libmpv 缺少 mpv_initialize"); return 0; }
    if (!load_symbol(library, "mpv_terminate_destroy", (void **)&p_mpv_terminate_destroy)) { set_error(context, "libmpv 缺少 mpv_terminate_destroy"); return 0; }
    if (!load_symbol(library, "mpv_set_option", (void **)&p_mpv_set_option)) { set_error(context, "libmpv 缺少 mpv_set_option"); return 0; }
    if (!load_symbol(library, "mpv_set_option_string", (void **)&p_mpv_set_option_string)) { set_error(context, "libmpv 缺少 mpv_set_option_string"); return 0; }
    if (!load_symbol(library, "mpv_set_property", (void **)&p_mpv_set_property)) { set_error(context, "libmpv 缺少 mpv_set_property"); return 0; }
    if (!load_symbol(library, "mpv_set_property_string", (void **)&p_mpv_set_property_string)) { set_error(context, "libmpv 缺少 mpv_set_property_string"); return 0; }
    if (!load_symbol(library, "mpv_command", (void **)&p_mpv_command)) { set_error(context, "libmpv 缺少 mpv_command"); return 0; }
    if (!load_symbol(library, "mpv_command_async", (void **)&p_mpv_command_async)) { set_error(context, "libmpv 缺少 mpv_command_async"); return 0; }
    if (!load_symbol(library, "mpv_observe_property", (void **)&p_mpv_observe_property)) { set_error(context, "libmpv 缺少 mpv_observe_property"); return 0; }
    if (!load_symbol(library, "mpv_wait_event", (void **)&p_mpv_wait_event)) { set_error(context, "libmpv 缺少 mpv_wait_event"); return 0; }
    if (!load_symbol(library, "mpv_request_log_messages", (void **)&p_mpv_request_log_messages)) { set_error(context, "libmpv 缺少 mpv_request_log_messages"); return 0; }
    if (!load_symbol(library, "mpv_event_name", (void **)&p_mpv_event_name)) { set_error(context, "libmpv 缺少 mpv_event_name"); return 0; }
    if (!load_symbol(library, "mpv_error_string", (void **)&p_mpv_error_string)) { set_error(context, "libmpv 缺少 mpv_error_string"); return 0; }
    if (!load_symbol(library, "mpv_render_context_create", (void **)&p_mpv_render_context_create)) { set_error(context, "libmpv 缺少 mpv_render_context_create"); return 0; }
    if (!load_symbol(library, "mpv_render_context_free", (void **)&p_mpv_render_context_free)) { set_error(context, "libmpv 缺少 mpv_render_context_free"); return 0; }
    if (!load_symbol(library, "mpv_render_context_set_update_callback", (void **)&p_mpv_render_context_set_update_callback)) { set_error(context, "libmpv 缺少 mpv_render_context_set_update_callback"); return 0; }
    if (!load_symbol(library, "mpv_render_context_render", (void **)&p_mpv_render_context_render)) { set_error(context, "libmpv 缺少 mpv_render_context_render"); return 0; }
    if (!load_symbol(library, "mpv_render_context_update", (void **)&p_mpv_render_context_update)) { set_error(context, "libmpv 缺少 mpv_render_context_update"); return 0; }
    if (!load_symbol(library, "mpv_render_context_report_swap", (void **)&p_mpv_render_context_report_swap)) { set_error(context, "libmpv 缺少 mpv_render_context_report_swap"); return 0; }
    return 1;
}

NVMPVContext *nv_mpv_create(void) {
    NVMPVContext *context = calloc(1, sizeof(NVMPVContext));
    if (!context) { return NULL; }

    context->library = load_library(context->loaded_path, sizeof(context->loaded_path));
    if (!context->library) {
        set_error(context, "未找到 libmpv.2.dylib，请先运行打包脚本内置 libmpv，或安装 Homebrew mpv。");
        return context;
    }
    if (!load_symbols(context->library, context)) {
        return context;
    }

    context->handle = p_mpv_create();
    if (!context->handle) {
        set_error(context, "mpv_create 返回空句柄。");
    }
    return context;
}

void nv_mpv_destroy(NVMPVContext *context) {
    if (!context) { return; }
    if (context->render && p_mpv_render_context_free) {
        p_mpv_render_context_free(context->render);
    }
    context->render = NULL;
    if (context->handle && p_mpv_terminate_destroy) {
        p_mpv_terminate_destroy(context->handle);
    }
    context->handle = NULL;
    free(context);
}

const char *nv_mpv_last_error(NVMPVContext *context) {
    return context ? context->last_error : "libmpv context is null";
}

const char *nv_mpv_loaded_library_path(NVMPVContext *context) {
    return context ? context->loaded_path : "";
}

int nv_mpv_set_option_string(NVMPVContext *context, const char *name, const char *value) {
    if (!context || !context->handle || !p_mpv_set_option_string) { return -1; }
    int code = p_mpv_set_option_string(context->handle, name, value);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_set_option_int64(NVMPVContext *context, const char *name, int64_t value) {
    if (!context || !context->handle || !p_mpv_set_option) { return -1; }
    int code = p_mpv_set_option(context->handle, name, MPV_FORMAT_INT64, &value);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_initialize(NVMPVContext *context) {
    if (!context || !context->handle || !p_mpv_initialize) { return -1; }
    int code = p_mpv_initialize(context->handle);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_request_log_messages(NVMPVContext *context, const char *min_level) {
    if (!context || !context->handle || !p_mpv_request_log_messages) { return -1; }
    int code = p_mpv_request_log_messages(context->handle, min_level ? min_level : "info");
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_set_property_string(NVMPVContext *context, const char *name, const char *value) {
    if (!context || !context->handle || !p_mpv_set_property_string) { return -1; }
    int code = p_mpv_set_property_string(context->handle, name, value);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_set_property_double(NVMPVContext *context, const char *name, double value) {
    if (!context || !context->handle || !p_mpv_set_property) { return -1; }
    int code = p_mpv_set_property(context->handle, name, MPV_FORMAT_DOUBLE, &value);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_set_property_flag(NVMPVContext *context, const char *name, int value) {
    if (!context || !context->handle || !p_mpv_set_property) { return -1; }
    int code = p_mpv_set_property(context->handle, name, MPV_FORMAT_FLAG, &value);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

static int run_command(NVMPVContext *context, const char **args) {
    if (!context || !context->handle || !p_mpv_command) { return -1; }
    int code = p_mpv_command(context->handle, args);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_command1(NVMPVContext *context, const char *arg0) {
    const char *args[] = { arg0, NULL };
    return run_command(context, args);
}

int nv_mpv_command2(NVMPVContext *context, const char *arg0, const char *arg1) {
    const char *args[] = { arg0, arg1, NULL };
    return run_command(context, args);
}

int nv_mpv_command3(NVMPVContext *context, const char *arg0, const char *arg1, const char *arg2) {
    const char *args[] = { arg0, arg1, arg2, NULL };
    return run_command(context, args);
}

int nv_mpv_command3_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2) {
    if (!context || !context->handle || !p_mpv_command_async) { return -1; }
    const char *args[] = { arg0, arg1, arg2, NULL };
    int code = p_mpv_command_async(context->handle, reply_userdata, args);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_command4_async(NVMPVContext *context, uint64_t reply_userdata, const char *arg0, const char *arg1, const char *arg2, const char *arg3) {
    if (!context || !context->handle || !p_mpv_command_async) { return -1; }
    const char *args[] = { arg0, arg1, arg2, arg3, NULL };
    int code = p_mpv_command_async(context->handle, reply_userdata, args);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_command4(NVMPVContext *context, const char *arg0, const char *arg1, const char *arg2, const char *arg3) {
    const char *args[] = { arg0, arg1, arg2, arg3, NULL };
    return run_command(context, args);
}

int nv_mpv_clear_http_headers(NVMPVContext *context) {
    return nv_mpv_set_property_string(context, "http-header-fields", "");
}

int nv_mpv_append_http_header(NVMPVContext *context, const char *header) {
    const char *args[] = { "change-list", "http-header-fields", "append", header, NULL };
    return run_command(context, args);
}

int nv_mpv_observe_double(NVMPVContext *context, uint64_t userdata, const char *name) {
    if (!context || !context->handle || !p_mpv_observe_property) { return -1; }
    int code = p_mpv_observe_property(context->handle, userdata, name, MPV_FORMAT_DOUBLE);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_observe_flag(NVMPVContext *context, uint64_t userdata, const char *name) {
    if (!context || !context->handle || !p_mpv_observe_property) { return -1; }
    int code = p_mpv_observe_property(context->handle, userdata, name, MPV_FORMAT_FLAG);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_observe_int64(NVMPVContext *context, uint64_t userdata, const char *name) {
    if (!context || !context->handle || !p_mpv_observe_property) { return -1; }
    int code = p_mpv_observe_property(context->handle, userdata, name, MPV_FORMAT_INT64);
    if (code < 0) { set_mpv_error(context, code); }
    return code;
}

int nv_mpv_wait_event(NVMPVContext *context, double timeout, NVMPVEvent *out) {
    if (!out) { return -1; }
    memset(out, 0, sizeof(NVMPVEvent));
    if (!context || !context->handle || !p_mpv_wait_event) { return -1; }

    mpv_event *event = p_mpv_wait_event(context->handle, timeout);
    if (!event) { return -1; }

    out->event_id = event->event_id;
    out->error = event->error;
    out->reply_userdata = event->reply_userdata;
    out->event_name = p_mpv_event_name ? p_mpv_event_name(event->event_id) : NULL;
    if (event->error < 0 && p_mpv_error_string) {
        out->error_string = p_mpv_error_string(event->error);
    }

    if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && event->data) {
        mpv_event_property *property = (mpv_event_property *)event->data;
        out->property_name = property->name;
        out->format = property->format;
        if (property->data) {
            switch (property->format) {
            case MPV_FORMAT_DOUBLE:
                out->double_value = *(double *)property->data;
                break;
            case MPV_FORMAT_FLAG:
                out->flag_value = *(int *)property->data;
                break;
            case MPV_FORMAT_INT64:
                out->int64_value = *(int64_t *)property->data;
                break;
            case MPV_FORMAT_STRING:
                out->string_value = *(char **)property->data;
                break;
            default:
                break;
            }
        }
    } else if (event->event_id == MPV_EVENT_END_FILE && event->data) {
        mpv_event_end_file *end = (mpv_event_end_file *)event->data;
        out->end_file_error = end->error;
        out->end_file_reason = end->reason;
        if (end->error < 0 && p_mpv_error_string) {
            out->error_string = p_mpv_error_string(end->error);
        }
    } else if (event->event_id == MPV_EVENT_LOG_MESSAGE && event->data) {
        mpv_event_log_message *log = (mpv_event_log_message *)event->data;
        out->log_prefix = log->prefix;
        out->log_level = log->level;
        out->log_text = log->text;
    }

    return 0;
}

static void *opengl_proc_address(void *ctx, const char *name) {
    (void)ctx;
    static void *opengl = NULL;
    if (!opengl) {
        opengl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_GLOBAL);
    }
    void *address = opengl ? dlsym(opengl, name) : NULL;
    if (!address) {
        address = dlsym(RTLD_DEFAULT, name);
    }
    return address;
}

typedef unsigned int (*gl_get_error_fn)(void);

static void clear_opengl_errors(void) {
    static gl_get_error_fn p_gl_get_error = NULL;
    static int did_lookup = 0;
    if (!did_lookup) {
        did_lookup = 1;
        p_gl_get_error = (gl_get_error_fn)opengl_proc_address(NULL, "glGetError");
    }
    if (!p_gl_get_error) { return; }

    for (int i = 0; i < 16; i++) {
        if (p_gl_get_error() == 0) {
            break;
        }
    }
}

int nv_mpv_create_render_context(NVMPVContext *context, NVMPVRenderUpdateCallback callback, void *callback_context) {
    if (!context || !context->handle || !p_mpv_render_context_create) { return -1; }
    if (context->render) { return 0; }

    mpv_opengl_init_params gl_init = {
        .get_proc_address = opengl_proc_address,
        .get_proc_address_ctx = NULL
    };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };

    int code = p_mpv_render_context_create(&context->render, context->handle, params);
    if (code < 0) {
        set_mpv_error(context, code);
        return code;
    }
    if (callback && p_mpv_render_context_set_update_callback) {
        p_mpv_render_context_set_update_callback(context->render, callback, callback_context);
    }
    return 0;
}

int nv_mpv_free_render_context(NVMPVContext *context) {
    if (!context || !p_mpv_render_context_free) { return -1; }
    if (context->render) {
        p_mpv_render_context_free(context->render);
        context->render = NULL;
    }
    return 0;
}

int nv_mpv_render(NVMPVContext *context, int fbo, int width, int height, int flip_y) {
    if (!context || !context->render || !p_mpv_render_context_render) { return -1; }
    if (width <= 0 || height <= 0) { return 0; }

    clear_opengl_errors();
    if (p_mpv_render_context_update) {
        p_mpv_render_context_update(context->render);
    }
    clear_opengl_errors();

    mpv_opengl_fbo target = {
        .fbo = fbo,
        .w = width,
        .h = height,
        .internal_format = 0x8058 /* GL_RGBA8 */
    };
    int flip = flip_y ? 1 : 0;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &target },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    p_mpv_render_context_render(context->render, params);
    return 0;
}

void nv_mpv_report_swap(NVMPVContext *context) {
    if (!context || !context->render || !p_mpv_render_context_report_swap) { return; }
    p_mpv_render_context_report_swap(context->render);
}
