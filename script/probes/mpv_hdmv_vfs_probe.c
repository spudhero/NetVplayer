// Research only: does bd:// reuse public libmpv custom stream callbacks?
// The control is an ordinary local MPEG-TS file served through the same API.
#include <mpv/client.h>
#include <mpv/stream_cb.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define API_LIST(X) X(mpv_create) X(mpv_initialize) X(mpv_set_option_string) \
    X(mpv_command) X(mpv_wait_event) X(mpv_request_log_messages) \
    X(mpv_stream_cb_add_ro) X(mpv_terminate_destroy)
#define DECLARE(name) static __typeof__(&name) p_##name;
API_LIST(DECLARE)

static const char *disc_path, *control_path;
static atomic_uint disc_opens, control_opens, closes;
static atomic_ullong bytes_read;
static unsigned file_loads, end_errors;
struct cookie { FILE *file; atomic_bool cancelled; };

static int64_t read_cb(void *opaque, char *buffer, uint64_t size) {
    struct cookie *c = opaque;
    if (atomic_load(&c->cancelled)) return -1;
    size_t n = fread(buffer, 1, size, c->file);
    atomic_fetch_add(&bytes_read, n);
    return ferror(c->file) ? -1 : (int64_t)n;
}

static int64_t seek_cb(void *opaque, int64_t offset) {
    struct cookie *c = opaque;
    if (atomic_load(&c->cancelled) || offset < 0 || fseeko(c->file, offset, SEEK_SET)) return -1;
    return ftello(c->file);
}

static int64_t size_cb(void *opaque) {
    struct cookie *c = opaque;
    off_t offset = ftello(c->file);
    if (offset < 0 || fseeko(c->file, 0, SEEK_END)) return -1;
    off_t size = ftello(c->file);
    if (fseeko(c->file, offset, SEEK_SET)) return -1;
    return size;
}

static void close_cb(void *opaque) {
    struct cookie *c = opaque;
    fclose(c->file);
    free(c);
    atomic_fetch_add(&closes, 1);
}

static void cancel_cb(void *opaque) {
    struct cookie *c = opaque;
    atomic_store(&c->cancelled, true);
}

static int open_cb(void *unused, char *uri, mpv_stream_cb_info *info) {
    (void)unused;
    const char *path;
    if (!strcmp(uri, "hdmvprobe://disc")) {
        atomic_fetch_add(&disc_opens, 1);
        path = disc_path;
    } else if (!strcmp(uri, "hdmvprobe://control")) {
        atomic_fetch_add(&control_opens, 1);
        path = control_path;
    } else return MPV_ERROR_LOADING_FAILED;
    struct cookie *c = calloc(1, sizeof(*c));
    if (!c) return MPV_ERROR_NOMEM;
    atomic_init(&c->cancelled, false);
    c->file = fopen(path, "rb");
    if (!c->file) { free(c); return MPV_ERROR_LOADING_FAILED; }
    *info = (mpv_stream_cb_info){c, read_cb, seek_cb, size_cb, close_cb, cancel_cb};
    return 0;
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void pump(mpv_handle *h, double seconds) {
    double deadline = now() + seconds;
    do {
        mpv_event *e = p_mpv_wait_event(h, 0.02);
        if (e->event_id == MPV_EVENT_FILE_LOADED) file_loads++;
        if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = e->data;
            if (end->error < 0) end_errors++;
        }
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = e->data;
            fprintf(stderr, "%s: %s", log->prefix, log->text);
        }
    } while (now() < deadline);
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: probe LIBMPV LOCAL_ISO CONTROL_M2TS\n");
        return 2;
    }
    disc_path = argv[2]; control_path = argv[3];
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 3; }
#define LOAD(name) p_##name = dlsym(lib, #name); if (!p_##name) return 4;
    API_LIST(LOAD)
#undef LOAD
    mpv_handle *h = p_mpv_create();
    if (!h) return 5;
    const char *options[][2] = {{"config","no"},{"vo","null"},{"ao","null"},
        {"terminal","no"},{"disc-menu","yes"},{"bluray-device","hdmvprobe://disc"}};
    for (unsigned i=0; i<sizeof(options)/sizeof(options[0]); i++) {
        if (p_mpv_set_option_string(h, options[i][0], options[i][1]) < 0) return 6;
    }
    int registered = p_mpv_stream_cb_add_ro(h, "hdmvprobe", NULL, open_cb);
    if (registered < 0 || p_mpv_initialize(h) < 0) return 7;
    p_mpv_request_log_messages(h, "v");
    const char *disc[] = {"loadfile", "bd://", NULL};
    int disc_command = p_mpv_command(h, disc);
    pump(h, 2);
    unsigned disc_loaded = file_loads, disc_failed = end_errors;
    unsigned opened_before_control = atomic_load(&disc_opens);
    const char *stop[] = {"stop", NULL};
    p_mpv_command(h, stop); pump(h, 0.1);
    const char *control[] = {"loadfile", "hdmvprobe://control", NULL};
    int control_command = p_mpv_command(h, control);
    pump(h, 2);
    p_mpv_command(h, stop); pump(h, 0.1);
    p_mpv_terminate_destroy(h);
    printf("{\"schema\":1,\"registrationCode\":%d,\"discCommandCode\":%d,"
        "\"discOpens\":%u,\"discFileLoads\":%u,\"discEndErrors\":%u,"
        "\"controlCommandCode\":%d,\"controlOpens\":%u,\"controlFileLoads\":%u,"
        "\"closes\":%u,\"bytesRead\":%llu,\"realRemoteReadPassed\":false}\n",
        registered, disc_command, opened_before_control, disc_loaded, disc_failed,
        control_command, atomic_load(&control_opens), file_loads-disc_loaded,
        atomic_load(&closes), atomic_load(&bytes_read));
    return 0;
}
