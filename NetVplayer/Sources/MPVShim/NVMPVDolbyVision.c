#include "NVMPVDolbyVision.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/time.h>
#include <dlfcn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>

typedef struct ProbeIO { FILE *file; int64_t size, bytes; double deadline; int exhausted; } ProbeIO;
static double monotonic(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int interrupted(void *opaque) {
    ProbeIO *p = opaque;
    if (monotonic() > p->deadline || p->bytes >= 8 * 1024 * 1024) p->exhausted = 1;
    return p->exhausted;
}
static int read_bytes(void *opaque, uint8_t *buf, int count) {
    ProbeIO *p = opaque;
    if (interrupted(p)) return AVERROR_EXIT;
    int64_t remaining = 8 * 1024 * 1024 - p->bytes;
    if (count > remaining) count = (int)remaining;
    size_t n = fread(buf, 1, count, p->file); p->bytes += n;
    return n ? (int)n : AVERROR_EOF;
}
static int64_t seek_bytes(void *opaque, int64_t offset, int whence) {
    ProbeIO *p = opaque;
    if (interrupted(p)) return AVERROR_EXIT;
    if (whence == AVSEEK_SIZE) return p->size;
    whence &= ~AVSEEK_FORCE;
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) return AVERROR(EINVAL);
    return fseeko(p->file, offset, whence) == 0 ? ftello(p->file) : AVERROR(EIO);
}
static int refuse_nested_io(AVFormatContext *s, AVIOContext **pb, const char *url, int flags, AVDictionary **options) {
    return AVERROR(EPERM);
}

NVMPVDolbyVisionProbe nv_mpv_probe_local_dovi(const char *library, const char *path) {
    NVMPVDolbyVisionProbe result = {.profile=-1, .level=-1, .compatibility_id=-1,
        .rpu_flag=-1, .el_flag=-1, .bl_flag=-1, .rpu_profile=-1, .full_range=-1,
        .disable_residual=-1, .stream_index=-1};
    if (!library || !path || path[0] != '/') return result;
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return result;
    void *lib = dlopen(library, RTLD_LAZY | RTLD_LOCAL);
    if (!lib) return result;
    // Resolve locally, without changing process-wide FFmpeg logging or allocators.
#define SYMBOL(n) __typeof__(&n) f_##n = (__typeof__(&n))dlsym(lib, #n); if (!f_##n) { dlclose(lib); return result; }
    SYMBOL(avformat_version) SYMBOL(avcodec_version) SYMBOL(avutil_version)
    SYMBOL(av_malloc) SYMBOL(av_free) SYMBOL(avio_alloc_context) SYMBOL(avio_context_free)
    SYMBOL(avformat_alloc_context) SYMBOL(avformat_open_input) SYMBOL(avformat_close_input)
    SYMBOL(av_dict_set) SYMBOL(av_dict_free) SYMBOL(av_packet_side_data_get)
    SYMBOL(avcodec_find_decoder) SYMBOL(avcodec_alloc_context3) SYMBOL(avcodec_parameters_to_context)
    SYMBOL(avcodec_open2) SYMBOL(avcodec_free_context) SYMBOL(avcodec_send_packet) SYMBOL(avcodec_receive_frame)
    SYMBOL(av_packet_alloc) SYMBOL(av_packet_unref) SYMBOL(av_packet_free) SYMBOL(av_read_frame)
    SYMBOL(av_frame_alloc) SYMBOL(av_frame_free) SYMBOL(av_frame_get_side_data)
#undef SYMBOL
    if ((f_avformat_version() >> 16) != LIBAVFORMAT_VERSION_MAJOR ||
        (f_avcodec_version() >> 16) != LIBAVCODEC_VERSION_MAJOR ||
        (f_avutil_version() >> 16) != LIBAVUTIL_VERSION_MAJOR) { dlclose(lib); return result; }
    ProbeIO io = {.file=fopen(path,"rb"), .size=st.st_size, .deadline=monotonic()+2.0};
    if (!io.file) { dlclose(lib); return result; }
    uint8_t *buffer = f_av_malloc(32768);
    AVIOContext *avio = buffer ? f_avio_alloc_context(buffer,32768,0,&io,read_bytes,NULL,seek_bytes) : NULL;
    AVFormatContext *format = f_avformat_alloc_context();
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL; AVFrame *frame = NULL; AVDictionary *options = NULL;
    if (!avio || !format) goto done;
    format->pb = avio; format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->interrupt_callback = (AVIOInterruptCB){interrupted,&io};
    format->io_open = refuse_nested_io;
    format->probesize = 1024 * 1024; format->max_analyze_duration = 100000;
    format->max_streams = 64; format->max_index_size = 1024 * 1024;
    // No playlists, external references, archive or network demuxers.
    f_av_dict_set(&options,"format_whitelist","mov,matroska,webm,hevc",0);
    f_av_dict_set(&options,"enable_drefs","0",0);
    if (f_avformat_open_input(&format,NULL,NULL,&options) < 0) goto done;
    for (unsigned i=0; i<format->nb_streams && i<64; ++i) {
        AVCodecParameters *par = format->streams[i]->codecpar;
        if (par->codec_type != AVMEDIA_TYPE_VIDEO || (format->streams[i]->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        result.stream_index = (int)i;
        if (par->codec_id != AV_CODEC_ID_HEVC) { result.status=1; goto done; }
        const AVPacketSideData *sd = f_av_packet_side_data_get(par->coded_side_data,par->nb_coded_side_data,AV_PKT_DATA_DOVI_CONF);
        if (sd && sd->size >= 8) {
            const AVDOVIDecoderConfigurationRecord *c = (const void *)sd->data;
            result.profile=c->dv_profile; result.level=c->dv_level;
            result.compatibility_id=c->dv_bl_signal_compatibility_id;
            result.rpu_flag=c->rpu_present_flag; result.el_flag=c->el_present_flag; result.bl_flag=c->bl_present_flag;
        }
        const AVCodec *codec=f_avcodec_find_decoder(AV_CODEC_ID_HEVC);
        decoder=f_avcodec_alloc_context3(codec);
        if (!decoder || f_avcodec_parameters_to_context(decoder,par)<0) goto done;
        decoder->thread_count=1; decoder->max_pixels=16*1024*1024;
        if (f_avcodec_open2(decoder,codec,NULL)<0) goto done;
        break;
    }
    if (!decoder) goto done;
    packet=f_av_packet_alloc(); frame=f_av_frame_alloc();
    if (!packet || !frame) goto done;
    for (int n=0; n<64 && !interrupted(&io); ++n) {
        int code=f_av_read_frame(format,packet);
        if (code<0) { f_avcodec_send_packet(decoder,NULL); }
        else if (packet->stream_index==result.stream_index) { f_avcodec_send_packet(decoder,packet); }
        f_av_packet_unref(packet);
        if (f_avcodec_receive_frame(decoder,frame)==0) {
            result.status=1;
            result.frame_rpu=f_av_frame_get_side_data(frame,AV_FRAME_DATA_DOVI_RPU_BUFFER)!=NULL;
            AVFrameSideData *md=f_av_frame_get_side_data(frame,AV_FRAME_DATA_DOVI_METADATA);
            if (md && md->size>=sizeof(AVDOVIMetadata)) {
                const AVDOVIMetadata *m=(void *)md->data;
                if (m->header_offset<=md->size && sizeof(AVDOVIRpuDataHeader)<=md->size-m->header_offset) {
                    const AVDOVIRpuDataHeader *h=av_dovi_get_header(m);
                    result.frame_metadata=1; result.rpu_profile=h->vdr_rpu_profile;
                    result.full_range=h->bl_video_full_range_flag; result.disable_residual=h->disable_residual_flag;
                    if (h->vdr_rpu_profile==0 && h->bl_video_full_range_flag) result.inferred_profile=5;
                    if (h->vdr_rpu_profile==1) result.inferred_profile=
                        h->el_spatial_resampling_filter_flag && !h->disable_residual_flag ? (h->vdr_bit_depth==12 ? 7 : 4) : 8;
                }
            }
            break;
        }
        if (code<0) break;
    }
done:
    if (io.exhausted) result.status=2;
    result.bytes_read=io.bytes;
    f_av_dict_free(&options); f_av_frame_free(&frame); f_av_packet_free(&packet);
    f_avcodec_free_context(&decoder); f_avformat_close_input(&format);
    if (avio) { f_av_free(avio->buffer); f_avio_context_free(&avio); }
    else f_av_free(buffer);
    fclose(io.file); dlclose(lib); return result;
}
