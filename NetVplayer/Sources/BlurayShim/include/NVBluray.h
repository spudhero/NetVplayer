#ifndef NV_BLURAY_H
#define NV_BLURAY_H
#include <stdint.h>
#include <stddef.h>

typedef struct NVBluray NVBluray;
// All callbacks run on the caller's serial worker, never a libbluray global hook.
typedef int64_t (*NVBDSize)(void *, const char *);
typedef int64_t (*NVBDRead)(void *, const char *, int64_t, uint8_t *, int64_t);
typedef int (*NVBDList)(void *, const char *, uint32_t, char *, size_t);
typedef struct { uint32_t playlist, clip_count, chapter_count; uint64_t ticks; uint8_t angles; } NVBDTitle;
typedef struct { char id[6]; uint64_t start, in_time, out_time; } NVBDClip;
typedef struct { uint64_t ticks; uint32_t clip; char name[256]; } NVBDChapter;

// library_path is the bundled ABI-4 library (or an explicit development fixture).
// status: 1 unavailable/version mismatch, 2 not a disc/I/O, 3 protected, 4 invalid selection.
NVBluray *nv_bd_open(const char *library_path, int iso, void *context,
                    NVBDSize size, NVBDRead read, NVBDList list, int *status);
void nv_bd_close(NVBluray *);
uint32_t nv_bd_title_count(NVBluray *);
int nv_bd_title(NVBluray *, uint32_t index, NVBDTitle *);
int nv_bd_clip(NVBluray *, uint32_t index, uint32_t clip, NVBDClip *);
int nv_bd_chapter(NVBluray *, uint32_t index, uint32_t chapter, NVBDChapter *);
int nv_bd_select(NVBluray *, uint32_t playlist, uint32_t angle);
int64_t nv_bd_size(NVBluray *);
int64_t nv_bd_playitem_offset(NVBluray *, uint32_t clip);
int64_t nv_bd_read(NVBluray *, int64_t offset, uint8_t *buffer, int64_t count);
#endif
