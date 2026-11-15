#ifndef NV_SUBTITLE_BITMAP_H
#define NV_SUBTITLE_BITMAP_H
#include <stddef.h>
#include <stdint.h>
typedef struct NVSubtitleBitmapDecoder NVSubtitleBitmapDecoder;
typedef struct {
    double position;
    int width, height;
    const uint8_t *rgba;
} NVSubtitleBitmap;
/* Borrowed SUP bytes must outlive decoder. Output is borrowed until next/free.
 * 1=display/clear, 0=EOF, negative=malformed/unsupported/over-limit. */
NVSubtitleBitmapDecoder *nv_subtitle_bitmap_create(const char *library, const uint8_t *sup, size_t length);
int nv_subtitle_bitmap_next(NVSubtitleBitmapDecoder *, NVSubtitleBitmap *);
void nv_subtitle_bitmap_free(NVSubtitleBitmapDecoder *);
#endif
