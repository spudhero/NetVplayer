#include "NVSubtitleBitmap.h"
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct NVSubtitleBitmapDecoder {
    void *library;
    const uint8_t *data;
    size_t length, offset;
    AVCodecContext *context;
    AVPacket *packet;
    uint8_t *pixels;
    double last_position;
    __typeof__(&avcodec_find_decoder) find_decoder;
    __typeof__(&avcodec_alloc_context3) alloc_context;
    __typeof__(&avcodec_open2) open;
    __typeof__(&avcodec_free_context) free_context;
    __typeof__(&avcodec_decode_subtitle2) decode;
    __typeof__(&avsubtitle_free) free_subtitle;
    __typeof__(&av_packet_alloc) alloc_packet;
    __typeof__(&av_packet_free) free_packet;
    __typeof__(&av_packet_unref) unref_packet;
    __typeof__(&av_new_packet) new_packet;
};

void nv_subtitle_bitmap_free(NVSubtitleBitmapDecoder *d) {
    if (!d) return;
    if (d->packet && d->free_packet) d->free_packet(&d->packet);
    if (d->context && d->free_context) d->free_context(&d->context);
    free(d->pixels);
    if (d->library) dlclose(d->library);
    free(d);
}

NVSubtitleBitmapDecoder *nv_subtitle_bitmap_create(const char *library, const uint8_t *sup, size_t length) {
    if (!library || !sup || length < 13 || length > 16*1024*1024) return NULL;
    NVSubtitleBitmapDecoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->library = dlopen(library, RTLD_LAZY | RTLD_LOCAL);
    if (!d->library) goto fail;
    __typeof__(&avcodec_version) version = dlsym(d->library, "avcodec_version");
    if (!version || version() >> 16 != LIBAVCODEC_VERSION_MAJOR) goto fail;
#define LOAD(field, name) d->field = dlsym(d->library, #name); if (!d->field) goto fail
    LOAD(find_decoder,avcodec_find_decoder); LOAD(alloc_context,avcodec_alloc_context3);
    LOAD(open,avcodec_open2); LOAD(free_context,avcodec_free_context);
    LOAD(decode,avcodec_decode_subtitle2); LOAD(free_subtitle,avsubtitle_free);
    LOAD(alloc_packet,av_packet_alloc); LOAD(free_packet,av_packet_free);
    LOAD(unref_packet,av_packet_unref); LOAD(new_packet,av_new_packet);
#undef LOAD
    const AVCodec *codec = d->find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE);
    if (!codec) goto fail;
    d->context = d->alloc_context(codec);
    d->packet = d->alloc_packet();
    if (!d->context || !d->packet) goto fail;
    d->context->pkt_timebase = (AVRational){1,90000};
    d->context->max_pixels = 3840*2160;
    if (d->open(d->context,codec,NULL) < 0) goto fail;
    d->data = sup; d->length = length; d->last_position = -1;
    return d;
fail:
    nv_subtitle_bitmap_free(d); return NULL;
}

int nv_subtitle_bitmap_next(NVSubtitleBitmapDecoder *d, NVSubtitleBitmap *out) {
    if (!d || !out) return -1;
    free(d->pixels); d->pixels = NULL; memset(out,0,sizeof(*out));
    while (d->offset < d->length) {
        if (d->length - d->offset < 13) return -1;
        const uint8_t *p = d->data + d->offset;
        if (p[0] != 'P' || p[1] != 'G') return -1;
        uint32_t pts = ((uint32_t)p[2]<<24)|((uint32_t)p[3]<<16)|((uint32_t)p[4]<<8)|p[5];
        int size = ((int)p[11]<<8)|p[12];
        if ((size_t)size > d->length - d->offset - 13) return -1;
        if (d->new_packet(d->packet,size+3) < 0) return -2;
        memcpy(d->packet->data,p+10,size+3); d->packet->pts = pts; d->packet->dts = pts;
        d->offset += size + 13;
        AVSubtitle sub = {0}; int got = 0;
        int status = d->decode(d->context,&sub,&got,d->packet);
        d->unref_packet(d->packet);
        if (status < 0) { d->free_subtitle(&sub); return -1; }
        if (!got) { d->free_subtitle(&sub); continue; }
        double position = pts / 90000.0;
        if (position < d->last_position) { d->free_subtitle(&sub); return -1; }
        d->last_position = position; out->position = position;
        if (sub.num_rects > 64) { d->free_subtitle(&sub); return -2; }
        if (!sub.num_rects) { d->free_subtitle(&sub); return 1; }
        int left = 8192, top = 8192, right = 0, bottom = 0;
        for (unsigned i=0;i<sub.num_rects;i++) {
            AVSubtitleRect *r = sub.rects[i];
            if (!r || r->type != SUBTITLE_BITMAP || !r->data[0] || !r->data[1] ||
                r->x < 0 || r->y < 0 || r->w <= 0 || r->h <= 0 || r->x > 8192-r->w ||
                r->y > 4320-r->h || r->linesize[0] < r->w || r->nb_colors < 1 || r->nb_colors > 256) {
                d->free_subtitle(&sub); return -1;
            }
            if (r->x < left) left=r->x; if (r->y < top) top=r->y;
            if (r->x+r->w > right) right=r->x+r->w; if (r->y+r->h > bottom) bottom=r->y+r->h;
        }
        int w=right-left, h=bottom-top;
        if (w <= 0 || h <= 0 || (size_t)w*h > 2*1024*1024) { d->free_subtitle(&sub); return -2; }
        d->pixels = malloc((size_t)w*h*4);
        if (!d->pixels) { d->free_subtitle(&sub); return -2; }
        for (size_t i=0;i<(size_t)w*h;i++) { memset(d->pixels+i*4,16,3); d->pixels[i*4+3]=255; }
        for (unsigned i=0;i<sub.num_rects;i++) {
            AVSubtitleRect *r=sub.rects[i];
            const uint32_t *palette=(const uint32_t *)r->data[1];
            for (int y=0;y<r->h;y++) for (int x=0;x<r->w;x++) {
                unsigned index=r->data[0][(size_t)y*r->linesize[0]+x];
                if (index >= (unsigned)r->nb_colors) { d->free_subtitle(&sub); return -1; }
                uint32_t color=palette[index]; unsigned a=color>>24;
                uint8_t *pixel=d->pixels+((size_t)(r->y-top+y)*w+r->x-left+x)*4;
                for (int c=0;c<3;c++) pixel[c]=(((color>>(16-c*8))&255)*a+pixel[c]*(255-a)+127)/255;
            }
        }
        d->free_subtitle(&sub); out->width=w; out->height=h; out->rgba=d->pixels; return 1;
    }
    return 0;
}
