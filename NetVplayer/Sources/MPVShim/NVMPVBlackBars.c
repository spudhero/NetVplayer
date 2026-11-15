#include "MPVShim.h"
#include <mpv/client.h>
#include <stdlib.h>
#include <string.h>

static int brightness(const unsigned char *pixel) {
    int value = pixel[0] > pixel[1] ? pixel[0] : pixel[1];
    return value > pixel[2] ? value : pixel[2];
}

static int dark_line(const unsigned char *pixels, int w, int h, int stride, int index, int vertical) {
    int bright = 0;
    for (int i = 0; i < 96; i++) {
        int x = vertical ? index : (i + 1) * w / 97;
        int y = vertical ? (i + 1) * h / 97 : index;
        if (brightness(pixels + (size_t)y * stride + x * 4) > 12 && ++bright > 1) return 0;
    }
    return 1;
}

int nv_mpv_detect_black_bars(const void *data, size_t length, int w, int h, int stride, NVMPVBlackBarSample *out) {
    if (!data || !out || w < 32 || h < 32 || w > 8192 || h > 8192 || stride < w * 4
        || (size_t)stride * (h - 1) + (size_t)w * 4 > length) return 0;
    const unsigned char *pixels = data;
    // Dark scenes and fades cannot establish a crop. Require a clearly visible picture.
    int bright = 0, minimum = 255, maximum = 0;
    for (int y = 1; y < 17; y++) for (int x = 1; x < 33; x++) {
        int value = brightness(pixels + (size_t)(h / 4 + y * h / 34) * stride + (w / 4 + x * w / 66) * 4);
        if (value > 40) bright++;
        if (value < minimum) minimum = value;
        if (value > maximum) maximum = value;
    }
    if (bright < 64 || maximum - minimum < 32) return 0;
    int top = 0, bottom = 0, left = 0, right = 0;
    while (top < h / 4 && dark_line(pixels, w, h, stride, top, 0)) top++;
    while (bottom < h / 4 && dark_line(pixels, w, h, stride, h - 1 - bottom, 0)) bottom++;
    while (left < w / 4 && dark_line(pixels, w, h, stride, left, 1)) left++;
    while (right < w / 4 && dark_line(pixels, w, h, stride, w - 1 - right, 1)) right++;
    if (top >= h / 4 || bottom >= h / 4 || abs(top - bottom) > h / 100 + 2 || top < h / 100) top = bottom = 0;
    if (left >= w / 4 || right >= w / 4 || abs(left - right) > w / 100 + 2 || left < w / 100) left = right = 0;
    *out = (NVMPVBlackBarSample){w, h, left, top, right, bottom};
    return 1;
}

int nv_mpv_event_black_bars(const NVMPVEvent *event, NVMPVBlackBarSample *out) {
    if (!event || event->event_id != MPV_EVENT_COMMAND_REPLY || event->error < 0 || !event->node_value) return 0;
    const mpv_node *node = event->node_value;
    if (node->format != MPV_FORMAT_NODE_MAP || !node->u.list || node->u.list->num > 32) return 0;
    int w = 0, h = 0, stride = 0;
    const mpv_byte_array *bytes = NULL;
    int bgr = 0;
    for (int i = 0; i < node->u.list->num; i++) {
        const char *key = node->u.list->keys[i];
        const mpv_node *value = &node->u.list->values[i];
        if (!key) continue;
        if (value->format == MPV_FORMAT_INT64 && value->u.int64 > 0 && value->u.int64 <= 1073741824) {
            if (!strcmp(key, "w")) w = (int)value->u.int64;
            if (!strcmp(key, "h")) h = (int)value->u.int64;
            if (!strcmp(key, "stride")) stride = (int)value->u.int64;
        }
        if (!strcmp(key, "format") && value->format == MPV_FORMAT_STRING && value->u.string)
            bgr = !strcmp(value->u.string, "bgr0");
        if (!strcmp(key, "data") && value->format == MPV_FORMAT_BYTE_ARRAY) bytes = value->u.ba;
    }
    return bgr && bytes ? nv_mpv_detect_black_bars(bytes->data, bytes->size, w, h, stride, out) : 0;
}
