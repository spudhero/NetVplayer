#include "NVBluray.h"
#include <libbluray/bluray.h>
#include <libbluray/filesystem.h>
#include <libbluray/bluray-version.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#if BLURAY_VERSION != BLURAY_VERSION_CODE(1, 5, 0)
#error "BlurayShim requires the frozen libbluray 1.5.0 public headers"
#endif

struct NVBluray {
    void *library, *context;
    NVBDSize size;
    NVBDRead read;
    NVBDList list;
    BLURAY *bd;
    uint32_t count;
    BLURAY_TITLE_INFO *cached_title;
    uint32_t cached_index;
    BLURAY *(*init)(void);
    int (*open_stream)(BLURAY *, void *, int (*)(void *, void *, int, int));
    int (*open_files)(BLURAY *, void *, BD_DIR_H *(*)(void *, const char *), BD_FILE_H *(*)(void *, const char *));
    void (*close)(BLURAY *);
    const BLURAY_DISC_INFO *(*disc_info)(BLURAY *);
    uint32_t (*titles)(BLURAY *, uint8_t, uint32_t);
    BLURAY_TITLE_INFO *(*title)(BLURAY *, uint32_t, unsigned);
    void (*free_title)(BLURAY_TITLE_INFO *);
    int (*select)(BLURAY *, uint32_t);
    int (*angle)(BLURAY *, unsigned);
    uint64_t (*title_size)(BLURAY *);
    int64_t (*seek)(BLURAY *, uint64_t);
    int64_t (*seek_clip)(BLURAY *, unsigned);
    uint64_t (*tell)(BLURAY *);
    int (*read_title)(BLURAY *, unsigned char *, int);
};
typedef struct { NVBluray *owner; char *path; int64_t size, position; } File;
typedef struct { NVBluray *owner; char *path; uint32_t index; } Directory;
static void file_close(BD_FILE_H *f) { File *v = f->internal; free(v->path); free(v); free(f); }
static int64_t file_seek(BD_FILE_H *f, int64_t off, int32_t whence) {
    File *v = f->internal;
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? v->position : whence == SEEK_END ? v->size : -1;
    if (base < 0 || (off > 0 && base > INT64_MAX - off) || (off < 0 && off < -base)) return -1;
    int64_t pos = base + off;
    if (pos > v->size) return -1;
    return v->position = pos;
}
static int64_t file_tell(BD_FILE_H *f) { return ((File *)f->internal)->position; }
static int64_t file_read(BD_FILE_H *f, uint8_t *buf, int64_t count) {
    File *v = f->internal;
    if (count < 0) return -1;
    if (count > v->size - v->position) count = v->size - v->position;
    int64_t done = 0;
    while (done < count) {
        int64_t n = count - done;
        if (n > 4 * 1024 * 1024) n = 4 * 1024 * 1024;
        int64_t got = v->owner->read(v->owner->context, v->path, v->position, buf + done, n);
        if (got <= 0 || got > n) return -1; // an unexpected short EOF is never success
        done += got; v->position += got;
    }
    return done;
}
static BD_FILE_H *open_file(void *context, const char *path) {
    NVBluray *b = context;
    int64_t size = b->size(b->context, path);
    if (size < 0) return NULL;
    BD_FILE_H *f = calloc(1, sizeof(*f)); File *v = calloc(1, sizeof(*v));
    if (!f || !v) { free(f); free(v); return NULL; }
    v->owner = b; v->size = size; v->path = strdup(path);
    if (!v->path) { free(f); free(v); return NULL; }
    f->internal = v; f->close = file_close; f->seek = file_seek; f->tell = file_tell; f->read = file_read;
    return f;
}
static void dir_close(BD_DIR_H *d) { Directory *v = d->internal; free(v->path); free(v); free(d); }
static int dir_read(BD_DIR_H *d, BD_DIRENT *entry) {
    Directory *v = d->internal;
    return v->owner->list(v->owner->context, v->path, v->index++, entry->d_name, sizeof(entry->d_name));
}
static BD_DIR_H *open_dir(void *context, const char *path) {
    NVBluray *b = context;
    char probe[256];
    if (b->list(b->context, path, 0, probe, sizeof(probe)) < 0) return NULL;
    BD_DIR_H *d = calloc(1, sizeof(*d)); Directory *v = calloc(1, sizeof(*v));
    if (!d || !v) { free(d); free(v); return NULL; }
    v->owner = b; v->path = strdup(path);
    if (!v->path) { free(d); free(v); return NULL; }
    d->internal = v; d->close = dir_close; d->read = dir_read;
    return d;
}
static int blocks(void *context, void *buffer, int lba, int count) {
    NVBluray *b = context;
    if (lba < 0 || count < 0 || count > INT_MAX / 2048) return -1;
    int64_t total = (int64_t)count * 2048, done = 0;
    while (done < total) {
        int64_t n = total - done;
        if (n > 4 * 1024 * 1024) n = 4 * 1024 * 1024;
        int64_t got = b->read(b->context, "", (int64_t)lba * 2048 + done, (uint8_t *)buffer + done, n);
        if (got <= 0 || got > n) return -1;
        done += got;
    }
    return count;
}
NVBluray *nv_bd_open(const char *path, int iso, void *context, NVBDSize size, NVBDRead read, NVBDList list, int *status) {
    *status = 1;
    NVBluray *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!b->library) goto fail;
    void (*version)(int *, int *, int *) = dlsym(b->library, "bd_get_version");
    int major = 0, minor = 0, micro = 0;
    if (!version) goto fail;
    version(&major, &minor, &micro);
    // Public structs are compiled against the frozen 1.5.0 / ABI 4 headers.
    if (major != 1 || minor != 5 || micro != 0) goto fail;
#define LOAD(field, symbol) do { *(void **)(&b->field) = dlsym(b->library, symbol); if (!b->field) goto fail; } while (0)
    LOAD(init, "bd_init"); LOAD(open_stream, "bd_open_stream"); LOAD(open_files, "bd_open_files");
    LOAD(close, "bd_close"); LOAD(disc_info, "bd_get_disc_info"); LOAD(titles, "bd_get_titles");
    LOAD(title, "bd_get_title_info"); LOAD(free_title, "bd_free_title_info"); LOAD(select, "bd_select_playlist");
    LOAD(angle, "bd_select_angle"); LOAD(title_size, "bd_get_title_size"); LOAD(seek, "bd_seek");
    LOAD(seek_clip, "bd_seek_playitem"); LOAD(tell, "bd_tell"); LOAD(read_title, "bd_read");
#undef LOAD
    b->context = context; b->size = size; b->read = read; b->list = list;
    b->bd = b->init(); *status = 2;
    if (!b->bd) goto fail;
    if (!(iso ? b->open_stream(b->bd, b, blocks) : b->open_files(b->bd, b, open_dir, open_file))) goto fail;
    const BLURAY_DISC_INFO *disc = b->disc_info(b->bd);
    if (!disc || !disc->bluray_detected) goto fail;
    // This feature does not provision keys, decrypt protected discs, or start menus.
    if (disc->aacs_detected || disc->bdplus_detected) { *status = 3; goto fail; }
    b->count = b->titles(b->bd, TITLES_ALL, 0);
    if (!b->count || b->count > 10000) goto fail;
    *status = 0; return b;
fail:
    nv_bd_close(b); return NULL;
}
void nv_bd_close(NVBluray *b) {
    if (!b) return;
    if (b->cached_title) b->free_title(b->cached_title);
    if (b->bd && b->close) b->close(b->bd);
    if (b->library) dlclose(b->library);
    free(b);
}
uint32_t nv_bd_title_count(NVBluray *b) { return b->count; }
static BLURAY_TITLE_INFO *title_info(NVBluray *b, uint32_t index) {
    if (b->cached_title && b->cached_index == index) return b->cached_title;
    if (b->cached_title) b->free_title(b->cached_title);
    b->cached_index = index;
    return b->cached_title = b->title(b->bd, index, 0);
}
int nv_bd_title(NVBluray *b, uint32_t index, NVBDTitle *out) {
    BLURAY_TITLE_INFO *t = title_info(b, index);
    if (!t) return 0;
    *out = (NVBDTitle){t->playlist, t->clip_count, t->chapter_count, t->duration, t->angle_count};
    return 1;
}
int nv_bd_clip(NVBluray *b, uint32_t index, uint32_t clip, NVBDClip *out) {
    BLURAY_TITLE_INFO *t = title_info(b, index);
    if (!t) return 0;
    int valid = clip < t->clip_count;
    if (valid) { BLURAY_CLIP_INFO *c = &t->clips[clip];
        memcpy(out->id, c->clip_id, 6); out->start = c->start_time; out->in_time = c->in_time; out->out_time = c->out_time;
    }
    return valid;
}
int nv_bd_chapter(NVBluray *b, uint32_t index, uint32_t chapter, NVBDChapter *out) {
    BLURAY_TITLE_INFO *t = title_info(b, index);
    if (!t) return 0;
    int valid = chapter < t->chapter_count;
    if (valid) { BLURAY_TITLE_CHAPTER *c = &t->chapters[chapter];
        out->ticks = c->start; out->clip = c->clip_ref;
        snprintf(out->name, sizeof(out->name), "%s", c->chapter_name ? c->chapter_name : "");
    }
    return valid;
}
int nv_bd_select(NVBluray *b, uint32_t playlist, uint32_t angle) {
    return b->select(b->bd, playlist) && b->angle(b->bd, angle);
}
int64_t nv_bd_size(NVBluray *b) { uint64_t s = b->title_size(b->bd); return s <= INT64_MAX ? (int64_t)s : -1; }
int64_t nv_bd_playitem_offset(NVBluray *b, uint32_t clip) { return b->seek_clip(b->bd, clip); }
int64_t nv_bd_read(NVBluray *b, int64_t offset, uint8_t *buffer, int64_t count) {
    if (offset < 0 || count < 0 || count > 4 * 1024 * 1024) return -1;
    if (b->tell(b->bd) != (uint64_t)offset) {
        int64_t actual = b->seek(b->bd, offset);
        // bd_seek snaps to an earlier access point, not merely a 6144-byte
        // boundary. Discard bounded preroll to satisfy an exact HTTP byte range.
        if (actual < 0 || actual > offset || offset - actual > 64 * 1024 * 1024) return -1;
        uint8_t discard[64 * 1024];
        while (actual < offset) {
            int count = (int)((offset - actual) < sizeof(discard) ? offset - actual : sizeof(discard));
            int n = b->read_title(b->bd, discard, count);
            if (n <= 0) return -1;
            actual += n;
        }
    }
    int64_t done = 0;
    while (done < count) {
        int n = b->read_title(b->bd, buffer + done, (int)(count - done));
        if (n <= 0) return -1;
        done += n;
    }
    return done;
}
