/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <libplacebo/gpu.h>
#include <libplacebo/opengl.h>
#include <libplacebo/shaders/icc.h>
#include "mpv/render_gl.h"
#include "mpv/render_netvplayer.h"
#include <libplacebo/options.h>
#include <libplacebo/renderer.h>
#include <libplacebo/shaders/lut.h>
#include <libplacebo/shaders/custom.h>
#include <libplacebo/shaders/colorspace.h>
#include <libplacebo/log.h>
#include <libplacebo/swapchain.h>
#include <libplacebo/utils/libav.h>
#include <libplacebo/utils/frame_queue.h>

#include "osdep/threads.h"
#include "misc/mp_assert.h"
#include "common/common.h"
#include "common/msg.h"
#include "options/m_config.h"
#include "video/out/libmpv.h"
#include "video/out/gpu/video.h"
#include "video/out/gpu/video_shaders.h"
#include "video/out/placebo/utils.h"
#include "video/mp_image.h"
#include "hdr_vivid.h"

#include "sub/osd.h"
#include "sub/draw_bmp.h"

#include "mpv/render_placebo.h"



struct osd_entry {
    pl_tex tex;
    struct pl_overlay_part *parts;
    int num_parts;
};

struct overlay_state {
    struct osd_entry entries[MAX_OSD_PARTS];
    struct pl_overlay overlays[MAX_OSD_PARTS];
};

struct frame_priv {
    struct priv *p;  // Back-reference to main priv
    struct overlay_state subs;
    uint64_t osd_sync;
    struct pl_frame el_frame;
    pl_tex el_tex[4];
};

struct priv {
    struct mp_log *log;
    struct mpv_global *global;
    // Keep the established color/ICC renderer for SDR output. Dolby frames and
    // HDR-to-FP16 output use libplacebo; both share the same libmpv clock, GL
    // context, subtitles and presentation FBO.
    struct render_backend legacy;
    bool using_placebo;

    // libplacebo objects
    pl_log pllog;
    pl_gpu gpu;
    pl_renderer rr;
    pl_queue queue;
    pl_swapchain swapchain;
    bool external_pllog;
    pl_opengl gl;
    pl_tex target_tex;
    mpv_opengl_fbo target_fbo;
    struct pl_icc_profile target_profile;
    mp_mutex status_lock;
    mpv_netvplayer_render_status status;
    uint64_t vivid_frame_flags;
    struct voctrl_performance_data performance;

    // Allocated DR buffers
    mp_mutex dr_lock;
    pl_buf *dr_buffers;
    int num_dr_buffers;

    // OSD state
    pl_fmt osd_fmt[SUBBITMAP_COUNT];
    pl_tex *sub_tex;
    int num_sub_tex;
    struct overlay_state osd_state;
    uint64_t osd_sync;

    // Frame state
    struct mp_rect src, dst;
    struct mp_osd_res osd_res;
    struct mp_image_params img_params;
    struct osd_state *osd;  // OSD source from vo
    uint64_t last_id;
    double last_pts;
    bool want_reset;

    // Rendering options
    pl_options pars;
    struct m_config_cache *opts_cache;

    int last_w;
    int last_h;
};

static void update_options(struct priv *p);

static void render_info(void *opaque, const struct pl_render_info *info)
{
    struct priv *p = opaque;
    if (info->index < 0 || info->index >= VO_PASS_PERF_MAX)
        return;
    struct mp_frame_perf *frame = info->stage == PL_RENDER_STAGE_FRAME
        ? &p->performance.fresh : &p->performance.redraw;
    const struct pl_dispatch_info *pass = info->pass;
    struct mp_pass_perf *perf = &frame->perf[info->index];
    frame->count = info->index + 1;
    perf->count = MPMIN(pass->num_samples, VO_PERF_SAMPLE_COUNT);
    memcpy(perf->samples, pass->samples, perf->count * sizeof(pass->samples[0]));
    perf->last = pass->last; perf->avg = pass->average; perf->peak = pass->peak;
    snprintf(frame->desc[info->index], VO_PASS_DESC_MAX_LEN, "%s", pass->shader->description);
}

static pl_buf get_dr_buf(struct priv *p, const uint8_t *ptr)
{
    mp_mutex_lock(&p->dr_lock);

    for (int i = 0; i < p->num_dr_buffers; i++) {
        pl_buf buf = p->dr_buffers[i];
        if (ptr >= buf->data && ptr < buf->data + buf->params.size) {
            mp_mutex_unlock(&p->dr_lock);
            return buf;
        }
    }

    mp_mutex_unlock(&p->dr_lock);
    return NULL;
}

static void free_dr_buf(void *opaque, uint8_t *data)
{
    struct priv *p = opaque;
    mp_mutex_lock(&p->dr_lock);

    for (int i = 0; i < p->num_dr_buffers; i++) {
        if (p->dr_buffers[i]->data == data) {
            pl_buf_destroy(p->gpu, &p->dr_buffers[i]);
            MP_TARRAY_REMOVE_AT(p->dr_buffers, p->num_dr_buffers, i);
            mp_mutex_unlock(&p->dr_lock);
            return;
        }
    }

    MP_ASSERT_UNREACHABLE();
}

static int plane_data_from_imgfmt(struct pl_plane_data out_data[4],
                                  struct pl_bit_encoding *out_bits,
                                  enum mp_imgfmt imgfmt)
{
    struct mp_imgfmt_desc desc = mp_imgfmt_get_desc(imgfmt);
    if (!desc.num_planes || !(desc.flags & MP_IMGFLAG_HAS_COMPS))
        return 0;
    if (desc.flags & MP_IMGFLAG_HWACCEL)
        return 0;

    if (!(desc.flags & MP_IMGFLAG_NE))
        return 0;

    if (desc.flags & MP_IMGFLAG_PAL)
        return 0;

    if ((desc.flags & MP_IMGFLAG_TYPE_FLOAT) && (desc.flags & MP_IMGFLAG_YUV))
        return 0;

    bool has_bits = false;

    for (int p = 0; p < desc.num_planes; p++) {
        struct pl_plane_data *data = &out_data[p];
        struct mp_imgfmt_comp_desc sorted[MP_NUM_COMPONENTS];
        int num_comps = 0;
        if (desc.bpp[p] % 8)
            return 0;

        for (int c = 0; c < mp_imgfmt_desc_get_num_comps(&desc); c++) {
            if (desc.comps[c].plane != p)
                continue;

            data->component_map[num_comps] = c;
            sorted[num_comps] = desc.comps[c];
            num_comps++;

            for (int i = num_comps - 1; i > 0; i--) {
                if (sorted[i].offset >= sorted[i - 1].offset)
                    break;
                MPSWAP(struct mp_imgfmt_comp_desc, sorted[i], sorted[i - 1]);
                MPSWAP(int, data->component_map[i], data->component_map[i - 1]);
            }
        }

        uint64_t total_bits = 0;
        memset(data->component_size, 0, sizeof(data->component_size));
        for (int c = 0; c < num_comps; c++) {
            data->component_size[c] = sorted[c].size;
            data->component_pad[c] = sorted[c].offset - total_bits;
            total_bits += data->component_pad[c] + data->component_size[c];

            if (!out_bits || data->component_map[c] == PL_CHANNEL_A)
                continue;

            struct pl_bit_encoding bits = {
                .sample_depth = data->component_size[c],
                .color_depth = sorted[c].size - abs(sorted[c].pad),
                .bit_shift = MPMAX(sorted[c].pad, 0),
            };

            if (!has_bits) {
                *out_bits = bits;
                has_bits = true;
            } else {
                if (!pl_bit_encoding_equal(out_bits, &bits)) {
                    *out_bits = (struct pl_bit_encoding) {0};
                    out_bits = NULL;
                }
            }
        }

        data->pixel_stride = desc.bpp[p] / 8;
        data->type = (desc.flags & MP_IMGFLAG_TYPE_FLOAT)
                            ? PL_FMT_FLOAT
                            : PL_FMT_UNORM;
    }

    return desc.num_planes;
}

static bool format_supported(struct priv *p, int format)
{
    struct pl_bit_encoding bits;
    struct pl_plane_data data[4] = {0};
    int planes = plane_data_from_imgfmt(data, &bits, format);
    if (!planes)
        return false;

    for (int i = 0; i < planes; i++) {
        if (!pl_plane_find_fmt(p->gpu, NULL, &data[i]))
            return false;
    }

    return true;
}

static int init(struct render_backend *ctx, mpv_render_param *params)
{
    ctx->priv = talloc_zero(NULL, struct priv);
    struct priv *p = ctx->priv;
    p->log = ctx->log;
    p->global = ctx->global;
    mp_mutex_init(&p->dr_lock);
    mp_mutex_init(&p->status_lock);
    p->status = (mpv_netvplayer_render_status) {
        .size = sizeof(p->status), .version = MPV_NETVPLAYER_STATUS_VERSION,
        .capabilities = MPV_NETVPLAYER_CAP_DOVI | MPV_NETVPLAYER_CAP_ENHANCEMENT |
                        MPV_NETVPLAYER_CAP_ICC | MPV_NETVPLAYER_CAP_FLOAT_TARGET |
                        MPV_NETVPLAYER_CAP_HDR_VIVID | MPV_NETVPLAYER_CAP_SOURCE_FRAME,
    };

    char *api = get_mpv_render_param(params, MPV_RENDER_PARAM_API_TYPE, NULL);
    if (!api || (strcmp(api, MPV_RENDER_API_TYPE_LIBPLACEBO) != 0 && strcmp(api, "opengl-placebo") != 0))
        return MPV_ERROR_NOT_IMPLEMENTED;

    // Get optional pl_log
    pl_log external_log = get_mpv_render_param(params, (mpv_render_param_type) MPV_RENDER_PARAM_LIBPLACEBO_PL_LOG, NULL);

    // Get required swapchain
    p->swapchain = get_mpv_render_param(params, (mpv_render_param_type) MPV_RENDER_PARAM_LIBPLACEBO_SWAPCHAIN, NULL);
    if (!p->swapchain && strcmp(api, "opengl-placebo") != 0) {
        MP_ERR(p, "MPV_RENDER_PARAM_LIBPLACEBO_SWAPCHAIN is required\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }

    // Create or use pl_log
    if (external_log) {
        p->pllog = external_log;
        p->external_pllog = true;
    } else {
        p->pllog = mppl_log_create(p, p->log);
        if (!p->pllog) {
            MP_ERR(p, "Failed to create libplacebo log\n");
            return MPV_ERROR_GENERIC;
        }
        p->external_pllog = false;
    }

    if (strcmp(api, "opengl-placebo") == 0) {
        mpv_opengl_init_params *gl = get_mpv_render_param(params, MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, NULL);
        if (!gl || !gl->get_proc_address)
            return MPV_ERROR_INVALID_PARAMETER;
        p->gl = pl_opengl_create(p->pllog, pl_opengl_params(
            .get_proc_addr_ex = (pl_voidfunc_t (*)(void *, const char *)) gl->get_proc_address,
            .proc_ctx = gl->get_proc_address_ctx,
        ));
        if (!p->gl)
            return MPV_ERROR_UNSUPPORTED;
        p->gpu = p->gl->gpu;
    } else {
        p->gpu = p->swapchain->gpu;
    }
    if (!p->gpu) {
        MP_ERR(p, "Failed to obtain GPU context\n");
        return MPV_ERROR_GENERIC;
    }

    // Create renderer and queue
    p->rr = pl_renderer_create(p->pllog, p->gpu);
    if (!p->rr) {
        MP_ERR(p, "Failed to create libplacebo renderer\n");
        return MPV_ERROR_GENERIC;
    }

    p->queue = pl_queue_create(p->gpu);
    if (!p->queue) {
        MP_ERR(p, "Failed to create frame queue\n");
        return MPV_ERROR_GENERIC;
    }

    // Initialize OSD formats
    p->osd_fmt[SUBBITMAP_LIBASS] = pl_find_named_fmt(p->gpu, "r8");
    p->osd_fmt[SUBBITMAP_BGRA] = pl_find_named_fmt(p->gpu, "bgra8");
    p->osd_sync = 1;

    // Initialize render options
    p->pars = pl_options_alloc(p->pllog);
    p->opts_cache = m_config_cache_alloc(p, p->global, &gl_video_conf);

    if (p->gl) {
        int count = 0;
        while (params[count].type)
            count++;
        mpv_render_param *legacy_params = talloc_memdup(p, params,
            (count + 1) * sizeof(*params));
        for (int i = 0; i < count; i++) {
            if (legacy_params[i].type == MPV_RENDER_PARAM_API_TYPE)
                legacy_params[i].data = MPV_RENDER_API_TYPE_OPENGL;
        }
        p->legacy = (struct render_backend) {
            .global = ctx->global, .log = ctx->log, .fns = &render_backend_gpu,
        };
        int err = p->legacy.fns->init(&p->legacy, legacy_params);
        talloc_free(legacy_params);
        if (err < 0)
            return err;
    }

    // Note: Hardware decoding not supported by this backend.
    // libmpv render API with external swapchain doesn't have ra_ctx,
    // required by libmpv's hwdec structure.
    // TODO: Implement an alternative to ra_hwdec_driver for this backend.
    // Or find some other way.
    ctx->hwdec_devs = NULL;

    // Set capabilities
    ctx->driver_caps = VO_CAP_ROTATE90 | VO_CAP_FILM_GRAIN | VO_CAP_VFLIP;
    if (p->legacy.priv)
        ctx->driver_caps &= p->legacy.driver_caps;

    p->last_h = p->last_w = 0;
    return 0;
}

static bool check_format(struct render_backend *ctx, int imgfmt)
{
    struct priv *p = ctx->priv;

    return format_supported(p, imgfmt) && (!p->legacy.priv ||
        p->legacy.fns->check_format(&p->legacy, imgfmt));
}

static int set_parameter(struct render_backend *ctx, mpv_render_param param)
{
    struct priv *p = ctx->priv;

    switch (param.type) {
    case MPV_RENDER_PARAM_ICC_PROFILE: {
        mpv_byte_array *data = param.data;
        if (!data || data->size > 16 * 1024 * 1024)
            return MPV_ERROR_INVALID_PARAMETER;
        if (p->legacy.priv) {
            int err = p->legacy.fns->set_parameter(&p->legacy, param);
            if (err < 0)
                return err;
        }
        talloc_free((void *) p->target_profile.data);
        p->target_profile.data = data->size ? talloc_memdup(p, data->data, data->size) : NULL;
        p->target_profile.len = data->size;
        pl_icc_profile_compute_signature(&p->target_profile);
        return 0;
    }
    default:
        return p->legacy.priv ? p->legacy.fns->set_parameter(&p->legacy, param)
                              : MPV_ERROR_NOT_IMPLEMENTED;
    }
}

static void clear_status(struct priv *p)
{
    mp_mutex_lock(&p->status_lock);
    p->status = (mpv_netvplayer_render_status) {
        .size = sizeof(p->status), .version = MPV_NETVPLAYER_STATUS_VERSION,
        .capabilities = p->status.capabilities, .generation = p->status.generation + 1,
    };
    mp_mutex_unlock(&p->status_lock);
}

static int get_info(struct render_backend *ctx, mpv_render_param param)
{
    struct priv *p = ctx->priv;
    if ((int)param.type != MPV_RENDER_PARAM_NETVPLAYER_STATUS)
        return MPV_ERROR_NOT_IMPLEMENTED;
    mpv_netvplayer_render_status *out = param.data;
    if (!out || out->size != sizeof(*out) || out->version != MPV_NETVPLAYER_STATUS_VERSION)
        return MPV_ERROR_INVALID_PARAMETER;
    mp_mutex_lock(&p->status_lock);
    *out = p->status;
    mp_mutex_unlock(&p->status_lock);
    return 0;
}

static void publish_status(struct priv *p, const struct pl_frame *frame, bool success)
{
    mp_mutex_lock(&p->status_lock);
    p->status.frame_flags = 0;
    p->status.pts = p->last_pts;
    if (!success) {
        p->status.failures++;
        p->status.frame_flags = MPV_NETVPLAYER_FRAME_FAILED;
    } else if (frame) {
        p->status.frame_flags |= p->vivid_frame_flags;
        p->status.rendered_frames++;
        if (frame->repr.sys == PL_COLOR_SYSTEM_DOLBYVISION && frame->repr.dovi) {
            p->status.dovi_frames++;
            p->status.frame_flags |= MPV_NETVPLAYER_FRAME_DOVI;
            if (frame->enhancement_layer) {
                p->status.enhancement_frames++;
                p->status.frame_flags |= MPV_NETVPLAYER_FRAME_ENHANCEMENT;
                if (frame->repr.dovi->nlq_active) {
                    p->status.fel_frames++;
                    p->status.frame_flags |= MPV_NETVPLAYER_FRAME_FEL;
                }
            }
            if (p->status.dovi_frames == 1 || p->status.dovi_frames % 120 == 0)
                MP_INFO(p, "NetVplayer Dolby renderer: frames=%llu dovi=%llu enhancement=%llu fel=%llu pts=%.6f\n",
                    (unsigned long long)p->status.rendered_frames, (unsigned long long)p->status.dovi_frames,
                    (unsigned long long)p->status.enhancement_frames, (unsigned long long)p->status.fel_frames,
                    p->last_pts);
        }
    }
    mp_mutex_unlock(&p->status_lock);
}

static const AVBufferRef *vivid_side_data(const struct mp_image *mpi)
{
    if (mpi) {
        for (int i = 0; i < mpi->num_ff_side_data; i++)
            if (mpi->ff_side_data[i].type == AV_FRAME_DATA_DYNAMIC_HDR_VIVID)
                return mpi->ff_side_data[i].buf;
    }
    return NULL;
}

struct vivid_hook_context {
    struct nv_vivid_curve curve;
    double peak, black, nominal_black;
    int width, height;
    bool called;
};

static struct pl_hook_res vivid_rgb_hook(void *priv, const struct pl_hook_params *hp)
{
    struct vivid_hook_context *v = priv;
    struct pl_hook_res res = {
        .output = PL_HOOK_SIG_COLOR, .sh = hp->sh, .repr = hp->repr,
        .color = hp->color, .components = hp->components, .rect = hp->rect,
    };
    if (hp->color.transfer == PL_COLOR_TRC_HLG) {
        // Annex A: HLG is converted to display-referred PQ before using the
        // accompanying PQ-domain metadata. Use the source mastering peak for
        // the HLG OOTF, never the destination screen's headroom.
        struct pl_color_space src = hp->color;
        src.hdr.max_luma = nv_vivid_nits(v->curve.reference);
        src.hdr.min_luma = 0;
        pl_shader_linearize(hp->sh, &src);
        src.transfer = PL_COLOR_TRC_PQ;
        pl_shader_delinearize(hp->sh, &src);
    }
    float u[48];
    nv_vivid_pack(&v->curve, u);
    int w = 0, h = 0;
    if (!pl_shader_output_size(hp->sh, &w, &h)) { w = v->width; h = v->height; }
    struct pl_shader_var uniform = {
        .var = {.name = "nvv", .type = PL_VAR_FLOAT, .dim_v = 1, .dim_m = 1, .dim_a = 48},
        .data = u, .dynamic = true,
    };
    bool ok = pl_shader_custom(hp->sh, &(struct pl_custom_shader) {
        .input = PL_SHADER_SIG_COLOR, .output = PL_SHADER_SIG_COLOR,
        .description = "HDR Vivid dynamic display adaptation",
        .output_w = w, .output_h = h,
        .variables = &uniform, .num_variables = 1,
        .header =
            "vec3 nvv_nits(vec3 q) {\n"
            " vec3 p=pow(clamp(q,0.0,1.0),vec3(32.0/2523.0));\n"
            " return 10000.0*pow(max(p-3424.0/4096.0,0.0)/(2413.0/128.0-2392.0/128.0*p),vec3(16384.0/2610.0));\n"
            "}\n"
            "vec3 nvv_pq(vec3 l) {\n"
            " vec3 p=pow(clamp(l/10000.0,0.0,1.0),vec3(2610.0/16384.0));\n"
            " return pow((3424.0/4096.0+2413.0/128.0*p)/(1.0+2392.0/128.0*p),vec3(2523.0/32.0));\n"
            "}\n"
            "float nvv_base(float x) {\n"
            " float xn=pow(max(x,0.0),nvv[2]);\n"
            " return nvv[3]*pow(nvv[0]*xn/((nvv[5]*nvv[0]-nvv[6])*xn+nvv[7]),nvv[1])+nvv[4];\n"
            "}\n"
            "float nvv_spline(float x,int o) {\n"
            " int i=x<nvv[o+1]?0:1; float t=x-nvv[o+i]; int j=o+3+4*i;\n"
            " return ((nvv[j+3]*t+nvv[j+2])*t+nvv[j+1])*t+nvv[j];\n"
            "}\n"
            "float nvv_curve(float x) {\n"
            " float y;\n"
            " if(x<=nvv[8]) y=nvv[9]*x+nvv[10];\n"
            " else if(x<nvv[13]) y=nvv_spline(x,11);\n"
            " else if(nvv[33]>0.5 && x>=nvv[22]) {\n"
            "  if(x<=nvv[24]) y=nvv_spline(x,22);\n"
            "  else if(nvv[34]>0.5) y=nvv[35]+nvv[36]*(x-nvv[24]);\n"
            "  else y=nvv_base(x);\n"
            " } else y=nvv_base(x);\n"
            " return clamp(y,0.0,nvv[37]);\n"
            "}\n",
        .body =
            "vec3 q=clamp(color.rgb,0.0,1.0);\n"
            "float mx=max(max(q.r,q.g),q.b);\n"
            "float mapped=nvv_curve(mx);\n"
            "float gain=nvv_nits(vec3(mapped)).x/max(nvv_nits(vec3(mx)).x,1e-8);\n"
            "vec3 lin=nvv_nits(q)*gain;\n"
            "if(nvv[39]>0.5 && mx>1e-6) {\n"
            " vec3 t=nvv_pq(lin); float mt=max(max(t.r,t.g),t.b);\n"
            " float sat=clamp(pow(max(mt/mx,1e-8),nvv[40]),0.8,1.0);\n"
            " if(mx>nvv[37] && nvv[39]>1.5) {\n"
            "  float z=clamp((mx-0.4*nvv[38])/max(0.6*nvv[38],1e-6),0.0,1.0);\n"
            "  sat=clamp(nvv[43]-nvv[41]*0.4*pow(z,nvv[42]),0.0,1.0);\n"
            " }\n"
            " float y=dot(t,vec3(0.2627,0.6780,0.0593));\n"
            " float cb=dot(t,vec3(-0.1396,-0.3604,0.5))*sat;\n"
            " float cr=dot(t,vec3(0.5,-0.4598,-0.0402))*sat;\n"
            " lin=nvv_nits(vec3(y+1.4746*cr,y-0.1645*cb-0.5713*cr,y+1.8814*cb-0.0001*cr));\n"
            "}\n"
            "color.rgb=lin/203.0;\n",
    });
    res.failed = !ok;
    v->called = ok;
    res.color.transfer = PL_COLOR_TRC_LINEAR;
    // The dynamic curve already maps to this display. Remove the source's
    // mastering/scene peaks so generic tone mapping cannot compress it again.
    res.color.hdr = (struct pl_hdr_metadata) {.max_luma = v->peak, .min_luma = v->nominal_black};
    return res;
}

static bool render_vivid_image(struct priv *p, const struct pl_frame *image,
                               const struct pl_frame *target,
                               struct pl_render_params params, bool *applied)
{
    *applied = false;
    const AVBufferRef *sd = vivid_side_data(image->user_data);
    struct vivid_hook_context v = {0};
    float peak = 0, nominal_black = 0;
    pl_color_space_nominal_luma_ex(pl_nominal_luma_params(
        .color = &target->color, .metadata = PL_HDR_METADATA_HDR10,
        .scaling = PL_HDR_NITS, .out_max = &peak, .out_min = &nominal_black));
    // An inferred SDR contrast ratio is not a measured display black level.
    // Use an explicit black point when present; otherwise assume ideal black.
    v.peak = peak; v.black = target->color.hdr.min_luma;
    v.nominal_black = nominal_black;
    v.width = image->planes[0].texture->params.w;
    v.height = image->planes[0].texture->params.h;
    if (!sd || sd->size < sizeof(AVDynamicHDRVivid) ||
        image->color.primaries != PL_COLOR_PRIM_BT_2020 ||
        (image->color.transfer != PL_COLOR_TRC_PQ && image->color.transfer != PL_COLOR_TRC_HLG) ||
        !nv_vivid_prepare((const AVDynamicHDRVivid *)sd->data, peak, v.black,
                           image->color.hdr.max_luma, !pl_color_space_is_hdr(&target->color), &v.curve))
        return pl_render_image(p->rr, image, target, &params);
    struct pl_render_params fallback = params;
    struct pl_hook hook = {.stages = PL_HOOK_RGB, .input = PL_HOOK_SIG_COLOR,
                           .priv = &v, .hook = vivid_rgb_hook, .signature = 0x4e56564956494401ULL};
    const struct pl_hook **hooks = talloc_array(NULL, const struct pl_hook *, params.num_hooks + 1);
    for (int i = 0; i < params.num_hooks; i++) hooks[i] = params.hooks[i];
    hooks[params.num_hooks++] = &hook;
    params.hooks = hooks;
    params.peak_detect_params = NULL;
    struct pl_color_map_params color_map = params.color_map_params
        ? *params.color_map_params : pl_color_map_default_params;
    color_map.tone_mapping_function = &pl_tone_map_clip;
    color_map.inverse_tone_mapping = false;
    color_map.contrast_recovery = 0;
    params.color_map_params = &color_map;
    params.frame_mixer = NULL;
    params.skip_caching_single_frame = true;
    params.preserve_mixing_cache = false;
    // The renderer's final color conversion consults the original pl_frame
    // metadata, even after a hook changes the intermediate image metadata.
    // Describe the post-curve range there too, while retaining the original
    // transfer for plane decoding and any nonlinear scaling stages.
    struct pl_frame adapted = *image;
    adapted.color.hdr = (struct pl_hdr_metadata) {.max_luma = peak, .min_luma = nominal_black};
    bool ok = pl_render_image(p->rr, &adapted, target, &params);
    struct pl_render_errors errors = pl_renderer_get_errors(p->rr);
    bool disabled = false;
    for (int i = 0; i < errors.num_disabled_hooks; i++)
        disabled |= errors.disabled_hooks[i] == hook.signature;
    *applied = ok && v.called && !disabled;
    if (!*applied) {
        // A GPU hook failure must return the ordinary decoded image and a
        // fallback status, never a stale/partly transformed Vivid picture.
        ok = pl_render_image(p->rr, image, target, &fallback);
    }
    talloc_free(hooks);
    return ok;
}

static void reconfig(struct render_backend *ctx, struct mp_image_params *params)
{
    struct priv *p = ctx->priv;
    p->img_params = *params;
    clear_status(p);
    p->want_reset = true;
    if (p->legacy.priv)
        p->legacy.fns->reconfig(&p->legacy, params);
}

static void reset(struct render_backend *ctx)
{
    struct priv *p = ctx->priv;
    clear_status(p);
    p->want_reset = true;
    if (p->legacy.priv)
        p->legacy.fns->reset(&p->legacy);
}

static void update_external(struct render_backend *ctx, struct vo *vo)
{
    struct priv *p = ctx->priv;
    p->osd = vo ? vo->osd : NULL;
    if (p->legacy.priv)
        p->legacy.fns->update_external(&p->legacy, vo);
}

static void resize(struct render_backend *ctx, struct mp_rect *src,
                   struct mp_rect *dst, struct mp_osd_res *osd)
{
    struct priv *p = ctx->priv;

    // Store the positioning info - dst contains the centered position
    // calculated by mp_get_src_dst_rects based on video alignment options
    p->src = *src;
    p->dst = *dst;
    p->osd_res = *osd;
    if (p->legacy.priv)
        p->legacy.fns->resize(&p->legacy, src, dst, osd);
}

static int get_target_size(struct render_backend *ctx, mpv_render_param *params,
                           int *out_w, int *out_h)
{
    struct priv *p = ctx->priv;

    if (p->gl) {
        mpv_opengl_fbo *fbo = get_mpv_render_param(params, MPV_RENDER_PARAM_OPENGL_FBO, NULL);
        if (!fbo || fbo->w <= 0 || fbo->h <= 0)
            return MPV_ERROR_INVALID_PARAMETER;
        *out_w = fbo->w;
        *out_h = fbo->h;
    } else {
        *out_w = p->last_w;
        *out_h = p->last_h;
    }
    return 0;
}

static void update_overlays(struct priv *p, struct mp_osd_res res,
                            struct pl_frame *frame, struct overlay_state *state,
                            struct osd_state *osd, double pts, int flags)
{
    if (!osd)
        return;

    struct sub_bitmap_list *subs = osd_render(osd, res, pts, flags, mp_draw_sub_formats);

    frame->overlays = state->overlays;
    frame->num_overlays = 0;

    for (int n = 0; n < subs->num_items; n++) {
        const struct sub_bitmaps *item = subs->items[n];
        if (!item->num_parts || !item->packed)
            continue;

        struct osd_entry *entry = &state->entries[item->render_index];
        pl_fmt tex_fmt = p->osd_fmt[item->format];

        if (!entry->tex)
            MP_TARRAY_POP(p->sub_tex, p->num_sub_tex, &entry->tex);

        bool ok = pl_tex_recreate(p->gpu, &entry->tex, &(struct pl_tex_params) {
            .format = tex_fmt,
            .w = item->packed_w,
            .h = item->packed_h,
            .host_writable = true,
            .sampleable = true,
        });

        if (!ok) {
            MP_ERR(p, "Failed recreating OSD texture!\n");
            break;
        }

        ok = pl_tex_upload(p->gpu, &(struct pl_tex_transfer_params) {
            .tex        = entry->tex,
            .rc         = { .x1 = item->packed_w, .y1 = item->packed_h, },
            .row_pitch  = item->packed->stride[0],
            .ptr        = item->packed->planes[0],
        });

        if (!ok) {
            MP_ERR(p, "Failed uploading OSD texture!\n");
            break;
        }

        entry->num_parts = 0;
        for (int i = 0; i < item->num_parts; i++) {
            const struct sub_bitmap *b = &item->parts[i];
            if (b->dw == 0 || b->dh == 0)
                continue;

            uint32_t c = b->libass.color;
            struct pl_overlay_part part = {
                .src = { b->src_x, b->src_y, b->src_x + b->w, b->src_y + b->h },
                .dst = { b->x, b->y, b->x + b->dw, b->y + b->dh },
                .color = {
                    (c >> 24) / 255.0f,
                    ((c >> 16) & 0xFF) / 255.0f,
                    ((c >> 8) & 0xFF) / 255.0f,
                    (255 - (c & 0xFF)) / 255.0f,
                }
            };
            MP_TARRAY_APPEND(p, entry->parts, entry->num_parts, part);
        }

        struct pl_overlay *ol = &state->overlays[frame->num_overlays++];
        *ol = (struct pl_overlay) {
            .tex = entry->tex,
            .parts = entry->parts,
            .num_parts = entry->num_parts,
            .color = {
                .primaries = PL_COLOR_PRIM_BT_709,
                .transfer = PL_COLOR_TRC_SRGB,
            },
            .coords = PL_OVERLAY_COORDS_DST_FRAME,
        };

        switch (item->format) {
        case SUBBITMAP_BGRA:
            ol->mode = PL_OVERLAY_NORMAL;
            ol->repr.alpha = PL_ALPHA_PREMULTIPLIED;
            break;
        case SUBBITMAP_LIBASS:
            ol->mode = PL_OVERLAY_MONOCHROME;
            ol->repr.alpha = PL_ALPHA_INDEPENDENT;
            break;
        }
    }

    talloc_free(subs);
}

static bool map_frame(pl_gpu gpu, pl_tex *tex, const struct pl_source_frame *src,
                      struct pl_frame *frame)
{
    struct mp_image *mpi = src->frame_data;
    if (!mpi)
        return false;

    struct frame_priv *fp = mpi->priv;
    struct priv *p = fp->p;

    struct mp_image_params par = mpi->params;
    mp_image_params_guess_csp(&par);
    if (par.repr.sys == PL_COLOR_SYSTEM_DOLBYVISION &&
        (!par.repr.dovi || (par.repr.dovi->nlq_active && !mpi->enhancement_layer))) {
        MP_ERR(p, "Incomplete Dolby frame metadata or enhancement layer.\n");
        talloc_free(mpi);
        return false;
    }

    *frame = (struct pl_frame) {
        .color = par.color,
        .repr = par.repr,
        .profile = {
            .data = mpi->icc_profile ? mpi->icc_profile->data : NULL,
            .len = mpi->icc_profile ? mpi->icc_profile->size : 0,
        },
        .rotation = par.rotate / 90,
        .user_data = mpi,
    };

    // Software decoding path (hwdec not supported in this backend)
    struct pl_plane_data data[4] = {0};
    frame->num_planes = plane_data_from_imgfmt(data, &frame->repr.bits, mpi->imgfmt);

    if (!frame->num_planes) {
        // Unsupported format (likely hwdec frame - use --hwdec=no)
        MP_ERR(p, "Unsupported frame format: %s (use --hwdec=no)\n", mp_imgfmt_to_name(mpi->imgfmt));
        talloc_free(mpi);
        return false;
    }

    for (int n = 0; n < frame->num_planes; n++) {
        struct pl_plane *plane = &frame->planes[n];
        data[n].width = mp_image_plane_w(mpi, n);
        data[n].height = mp_image_plane_h(mpi, n);

        if (mpi->stride[n] < 0) {
            data[n].pixels = mpi->planes[n] + (data[n].height - 1) * mpi->stride[n];
            data[n].row_stride = -mpi->stride[n];
            plane->flipped = true;
        } else {
            data[n].pixels = mpi->planes[n];
            data[n].row_stride = mpi->stride[n];
        }

        // Check if frame is in a DR buffer (zero-copy path)
        pl_buf buf = get_dr_buf(p, data[n].pixels);
        if (buf) {
            data[n].buf = buf;
            data[n].buf_offset = (uint8_t *) data[n].pixels - buf->data;
            data[n].pixels = NULL;
        } else if (gpu->limits.callbacks) {
            data[n].callback = talloc_free;
            data[n].priv = mp_image_new_ref(mpi);
        }

        if (!pl_upload_plane(gpu, plane, &tex[n], &data[n])) {
            MP_ERR(p, "Failed uploading frame!\n");
            talloc_free(data[n].priv);
            talloc_free(mpi);
            return false;
        }
    }

    pl_frame_set_chroma_location(frame, par.chroma_location);

    if (mpi->enhancement_layer) {
        struct mp_image *el = mpi->enhancement_layer;
        struct mp_image_params ep = el->params;
        mp_image_params_guess_csp(&ep);
        fp->el_frame = (struct pl_frame) { .color = ep.color, .repr = ep.repr, .user_data = mpi };
        struct pl_plane_data planes[4] = {0};
        fp->el_frame.num_planes = plane_data_from_imgfmt(planes, &fp->el_frame.repr.bits, el->imgfmt);
        if (!fp->el_frame.num_planes)
            goto el_error;
        for (int n = 0; n < fp->el_frame.num_planes; n++) {
            planes[n].width = mp_image_plane_w(el, n);
            planes[n].height = mp_image_plane_h(el, n);
            planes[n].pixels = el->planes[n];
            planes[n].row_stride = el->stride[n];
            if (el->stride[n] < 0) {
                planes[n].pixels = el->planes[n] + (planes[n].height - 1) * el->stride[n];
                planes[n].row_stride = -el->stride[n];
                fp->el_frame.planes[n].flipped = true;
            }
            if (gpu->limits.callbacks) {
                planes[n].callback = talloc_free;
                planes[n].priv = mp_image_new_ref(el);
            }
            if (!pl_upload_plane(gpu, &fp->el_frame.planes[n], &fp->el_tex[n], &planes[n])) {
                talloc_free(planes[n].priv);
                goto el_error;
            }
        }
        pl_frame_set_chroma_location(&fp->el_frame, ep.chroma_location);
        frame->enhancement_layer = &fp->el_frame;
    }

    if (mpi->film_grain)
        pl_film_grain_from_av(&frame->film_grain, (AVFilmGrainParams *) mpi->film_grain->data);

    pl_icc_profile_compute_signature(&frame->profile);
    return true;
el_error:
    MP_ERR(p, "Cannot upload Dolby Vision enhancement layer; refusing incomplete reconstruction.\n");
    for (int n = 0; n < 4; n++)
        pl_tex_destroy(gpu, &fp->el_tex[n]);
    talloc_free(mpi);
    return false;
}

static void unmap_frame(pl_gpu gpu, struct pl_frame *frame,
                        const struct pl_source_frame *src)
{
    struct mp_image *mpi = src->frame_data;
    struct frame_priv *fp = mpi->priv;
    struct priv *p = fp->p;

    // Save OSD textures for reuse
    for (int i = 0; i < MP_ARRAY_SIZE(fp->subs.entries); i++) {
        pl_tex tex = fp->subs.entries[i].tex;
        if (tex)
            MP_TARRAY_APPEND(p, p->sub_tex, p->num_sub_tex, tex);
    }
    for (int n = 0; n < 4; n++)
        pl_tex_destroy(gpu, &fp->el_tex[n]);
    talloc_free(mpi);
}

static void discard_frame(const struct pl_source_frame *src)
{
    struct mp_image *mpi = src->frame_data;
    talloc_free(mpi);
}

// Match vo_gpu_next: mpv's crop is already rotated; libplacebo rotates it later.
static void apply_crop(struct pl_frame *frame, struct mp_rect crop, int w, int h)
{
    frame->crop = (struct pl_rect2df) {crop.x0, crop.y0, crop.x1, crop.y1};
    pl_rect2df_rotate(&frame->crop, -frame->rotation);
    if (frame->crop.x1 < frame->crop.x0) {
        frame->crop.x0 = w - frame->crop.x0;
        frame->crop.x1 = w - frame->crop.x1;
    }
    if (frame->crop.y1 < frame->crop.y0) {
        frame->crop.y0 = h - frame->crop.y0;
        frame->crop.y1 = h - frame->crop.y1;
    }
}

static int render(struct render_backend *ctx, mpv_render_param *params,
                  struct vo_frame *frame)
{
    struct priv *p = ctx->priv;
    bool dolby = frame->current &&
                 frame->current->params.repr.sys == PL_COLOR_SYSTEM_DOLBYVISION;
    bool vivid = vivid_side_data(frame->current) != NULL;
    p->vivid_frame_flags = 0;
    bool vivid_supported = false;
    if (vivid && !dolby) {
        update_options(p);
        const struct gl_video_opts *opts = p->opts_cache->opts;
        const AVBufferRef *sd = vivid_side_data(frame->current);
        struct mp_image_params par = frame->current->params;
        mp_image_params_guess_csp(&par);
        struct nv_vivid_curve curve;
        vivid_supported = sd->size >= sizeof(AVDynamicHDRVivid) &&
            par.color.primaries == PL_COLOR_PRIM_BT_2020 &&
            (par.color.transfer == PL_COLOR_TRC_PQ || par.color.transfer == PL_COLOR_TRC_HLG) &&
            nv_vivid_prepare((const AVDynamicHDRVivid *)sd->data, opts->target_peak ?: 203, 0,
                              par.color.hdr.max_luma, true, &curve);
    }
    mpv_opengl_fbo *requested_fbo = get_mpv_render_param(params, MPV_RENDER_PARAM_OPENGL_FBO, NULL);
    bool hdr_float = frame->current && requested_fbo &&
                     requested_fbo->internal_format == 0x881A /* GL_RGBA16F */ &&
                     pl_color_space_is_hdr(&frame->current->params.color);
    if (p->legacy.priv && !dolby && !vivid_supported && !hdr_float) {
        if (p->using_placebo || p->want_reset) {
            pl_queue_reset(p->queue);
            pl_renderer_flush_cache(p->rr);
            p->last_id = 0;
            p->want_reset = false;
        }
        p->using_placebo = false;
        int err = p->legacy.fns->render(&p->legacy, params, frame);
        p->last_pts = frame->current ? frame->current->pts : 0;
        // Never carry proof of a previous Dolby frame into ordinary video.
        struct pl_frame ordinary = {0};
        p->vivid_frame_flags = vivid ? MPV_NETVPLAYER_FRAME_HDR_VIVID |
                                      MPV_NETVPLAYER_FRAME_VIVID_FALLBACK : 0;
        publish_status(p, frame->current ? &ordinary : NULL, err >= 0);
        return err;
    }
    if (!p->using_placebo)
        p->want_reset = true;
    p->using_placebo = true;
    mpv_render_rect viewport = get_mpv_render_param(
        params, (mpv_render_param_type)MPV_RENDER_PARAM_LIBPLACEBO_VIEWPORT,
        NULL);
    update_options(p);

    const struct gl_video_opts *opts = p->opts_cache->opts;
    bool can_interpolate = !vivid && opts->interpolation && frame->display_synced &&
                           !frame->still && frame->num_frames > 1;
    double pts_offset = can_interpolate ? frame->ideal_frame_vsync : 0;

    struct pl_source_frame vpts;
    if (frame->current && !p->want_reset) {
        // Check for backward PTS jump
        if (pl_queue_peek(p->queue, 0, &vpts) &&
            frame->current->pts + MPMAX(0, pts_offset) < vpts.pts)
        {
            MP_VERBOSE(p, "PTS discontinuity (backward): current=%f queue=%f\n",
                       frame->current->pts, vpts.pts);
            p->want_reset = true;
        }
        // Check for large forward PTS jump (common in streams)
        if (p->last_pts > 0 && frame->current->pts > p->last_pts + 5.0) {
            MP_VERBOSE(p, "PTS discontinuity (forward): current=%f last=%f\n",
                       frame->current->pts, p->last_pts);
            p->want_reset = true;
        }
    }

    // Push incoming frames to queue
    for (int n = 0; n < frame->num_frames; n++) {
        int id = frame->frame_id + n;

        // Handle reset inside the loop to properly handle discontinuities
        if (p->want_reset) {
            pl_renderer_flush_cache(p->rr);
            pl_queue_reset(p->queue);
            p->last_pts = 0.0;
            p->last_id = 0;
            p->want_reset = false;
        }

        if (id <= p->last_id)
            continue;

        struct mp_image *mpi = mp_image_new_ref(frame->frames[n]);
        if (!mpi) {
            MP_ERR(p, "Failed to ref frame\n");
            continue;
        }
        struct frame_priv *fp = talloc_zero(mpi, struct frame_priv);
        fp->p = p;
        mpi->priv = fp;

        pl_queue_push(p->queue, &(struct pl_source_frame) {
            .pts = mpi->pts,
            .duration = can_interpolate ? frame->approx_duration : 0,
            .frame_data = mpi,
            .map = map_frame,
            .unmap = unmap_frame,
            .discard = discard_frame,
        });

        p->last_id = id;
    }

    struct pl_swapchain_frame *swframe = NULL;
    struct pl_swapchain_frame internal_swframe = {0};
    bool use_application_swframe = false;
    if (p->gl) {
        mpv_opengl_fbo *fbo = get_mpv_render_param(params, MPV_RENDER_PARAM_OPENGL_FBO, NULL);
        if (!fbo || fbo->w <= 0 || fbo->h <= 0)
            return MPV_ERROR_INVALID_PARAMETER;
        if (!p->target_tex || fbo->fbo != p->target_fbo.fbo || fbo->w != p->target_fbo.w ||
            fbo->h != p->target_fbo.h || fbo->internal_format != p->target_fbo.internal_format) {
            pl_tex_destroy(p->gpu, &p->target_tex);
            p->target_tex = pl_opengl_wrap(p->gpu, pl_opengl_wrap_params(
                .framebuffer = fbo->fbo, .width = fbo->w, .height = fbo->h,
                .iformat = fbo->internal_format,
            ));
            if (!p->target_tex)
                return MPV_ERROR_GENERIC;
            p->target_fbo = *fbo;
        }
        int flip = *(int *)get_mpv_render_param(params, MPV_RENDER_PARAM_FLIP_Y, &(int){0});
        internal_swframe = (struct pl_swapchain_frame) {
            .fbo = p->target_tex, .flipped = !!flip,
            .color_repr = { .sys = PL_COLOR_SYSTEM_RGB, .levels = PL_COLOR_LEVELS_FULL },
            .color_space = {
                .primaries = opts->target_prim ?: PL_COLOR_PRIM_BT_709,
                .transfer = opts->target_trc ?: PL_COLOR_TRC_SRGB,
                .hdr.max_luma = opts->target_peak ?: 203,
            },
        };
        swframe = &internal_swframe;
        use_application_swframe = true;
    } else {
        swframe = get_mpv_render_param(params, (mpv_render_param_type)MPV_RENDER_PARAM_LIBPLACEBO_FRAME, NULL);
        use_application_swframe = !!swframe;
        if (!swframe) {
            if (!pl_swapchain_start_frame(p->swapchain, &internal_swframe))
                return MPV_ERROR_GENERIC;
            swframe = &internal_swframe;
        }
    }

    p->last_w = swframe->fbo->params.w;
    p->last_h = swframe->fbo->params.h;

    if (viewport) {
        // Get video dimensions
        int video_w = p->src.x1 - p->src.x0;
        int video_h = p->src.y1 - p->src.y0;
        if (video_w <= 0 || video_h <= 0) {
            // Fallback to image params if src not set
            video_w = swframe->fbo->params.w;
            video_h = swframe->fbo->params.h;
        }

        // Get viewport dimensions
        double vp_w = viewport->x1 - viewport->x0;
        double vp_h = viewport->y1 - viewport->y0;

        // Calculate aspect ratios
        double video_aspect = (double)video_w / video_h;
        double viewport_aspect = vp_w / vp_h;

        // Calculate destination rect that fits video in viewport with aspect ratio
        double dst_w, dst_h;
        if (video_aspect > viewport_aspect) {
            // Video is wider - fit to width
            dst_w = vp_w;
            dst_h = vp_w / video_aspect;
        } else {
            // Video is taller - fit to height
            dst_h = vp_h;
            dst_w = vp_h * video_aspect;
        }

        // Center in viewport
        double offset_x = (vp_w - dst_w) / 2.0;
        double offset_y = (vp_h - dst_h) / 2.0;

        // Set destination crop
        p->dst.x0 = viewport->x0 + offset_x;
        p->dst.y0 = viewport->y0 + offset_y;
        p->dst.x1 = viewport->x0 + offset_x + dst_w;
        p->dst.y1 = viewport->y0 + offset_y + dst_h;
    }


    struct pl_frame target;
    pl_frame_from_swapchain(&target, swframe);
    target.overlays = NULL;
    target.num_overlays = 0;
    target.profile = p->target_profile;

    // Set up target crop
    if (p->dst.x1 > p->dst.x0 && p->dst.y1 > p->dst.y0) {
        target.crop = (struct pl_rect2df) {
            .x0 = p->dst.x0,
            .y0 = p->dst.y0,
            .x1 = p->dst.x1,
            .y1 = p->dst.y1,
        };
    } else {
        target.crop = (struct pl_rect2df) {
            .x0 = 0,
            .y0 = 0,
            .x1 = swframe->fbo->params.w,
            .y1 = swframe->fbo->params.h,
        };
    }

    // Get frame mix from queue
    struct pl_frame_mix mix = {0};
    if (frame->current) {
        struct pl_queue_params qparams = *pl_queue_params(
            .pts = frame->current->pts + pts_offset,
            .radius = pl_frame_mix_radius(&p->pars->params),
            .vsync_duration = can_interpolate ? frame->ideal_frame_vsync_duration : 0,
            .interpolation_threshold = opts->interpolation_threshold,
        );
#if PL_API_VER >= 340
        qparams.drift_compensation = 0;
#endif

        struct pl_source_frame first;
        if (pl_queue_peek(p->queue, 0, &first) && qparams.pts < first.pts) {
            qparams.pts = first.pts;
        }
        p->last_pts = qparams.pts;

        switch (pl_queue_update(p->queue, &mix, &qparams)) {
        case PL_QUEUE_ERR:
            MP_ERR(p, "Failed updating frame queue!\n");
            pl_tex_clear(p->gpu, swframe->fbo, (float[4]){ 0.0, 0.0, 0.0, 1.0 });
            publish_status(p, NULL, false);
            goto submit;
        case PL_QUEUE_EOF:
        case PL_QUEUE_MORE:
        case PL_QUEUE_OK:
            break;
        }

        // Apply source crop to all frames
        for (int i = 0; i < mix.num_frames; i++) {
            struct pl_frame *image = (struct pl_frame *) mix.frames[i];
            struct mp_image *mpi = image->user_data;
            if (p->src.x1 > p->src.x0 && p->src.y1 > p->src.y0) {
                apply_crop(image, p->src, mpi->params.w, mpi->params.h);
            } else if (mpi) {
                image->crop = (struct pl_rect2df) {
                    .x0 = 0,
                    .y0 = 0,
                    .x1 = mpi->params.w,
                    .y1 = mpi->params.h,
                };
            }
        }
    }
    // Update OSD overlays on target frame
    double pts = frame->current ? frame->current->pts : 0;
    update_overlays(p, p->osd_res, &target, &p->osd_state, p->osd, pts, 0);

    // Render
    struct pl_render_params render_params = p->pars->params;
    render_params.info_callback = render_info;
    render_params.info_priv = p;

    // Only enable frame mixing when we can actually interpolate
    if (!can_interpolate || mix.num_frames < 2)
        render_params.frame_mixer = NULL;

    if (mix.num_frames > 0) {
        // Vivid coefficients belong to one decoded frame. Do not interpolate
        // frames with different dynamic curves or reuse the frame-mixing cache.
        int selected = 0;
        for (int i = 1; i < mix.num_frames; i++)
            if (fabs(mix.timestamps[i]) < fabs(mix.timestamps[selected])) selected = i;
        const struct pl_frame *shown = mix.frames[selected];
        bool has_vivid = vivid_side_data(shown->user_data) != NULL, applied = false;
        bool rendered = has_vivid ? render_vivid_image(p, shown, &target, render_params, &applied)
                                 : pl_render_image_mix(p->rr, &mix, &target, &render_params);
        p->vivid_frame_flags = has_vivid ? MPV_NETVPLAYER_FRAME_HDR_VIVID |
            (applied ? MPV_NETVPLAYER_FRAME_VIVID_MAPPED : MPV_NETVPLAYER_FRAME_VIVID_FALLBACK) : 0;
        if (!rendered) {
            MP_ERR(p, "Failed rendering frame!\n");
            pl_tex_clear(p->gpu, swframe->fbo, (float[4]){ 0.0, 0.0, 0.0, 1.0 });
            publish_status(p, NULL, false);
        } else {
            publish_status(p, shown, true);
              mpv_netvplayer_source_frame *source = get_mpv_render_param(params,
                  (mpv_render_param_type)MPV_RENDER_PARAM_NETVPLAYER_SOURCE_FRAME, NULL);
              if (source && source->size == sizeof(*source) && source->version == 1 &&
                  source->avutil_major == LIBAVUTIL_VERSION_MAJOR && source->capture) {
                  struct mp_image *mpi = shown->user_data;
                  // Keep original samples paired with their RPU. Any operation
                  // that needs compositing stays on the reconstructed path.
                  bool untouched = mpi && !opts->interpolation && !target.num_overlays &&
                      !shown->num_overlays && !mpi->params.rotate && !mpi->params.vflip &&
                      mpi->params.p_w == mpi->params.p_h &&
                      p->src.x0 == 0 && p->src.y0 == 0 &&
                      p->src.x1 == mpi->w && p->src.y1 == mpi->h &&
                      fabs(mpi->pts - p->last_pts) < 0.000001;
                  AVFrame *original = untouched ? mp_image_to_av_frame(mpi) : NULL;
                  source->capture(source->opaque, original, p->last_pts, p->status.generation);
                  av_frame_free(&original);
              }
        }
    } else {
        publish_status(p, NULL, true);
        pl_tex_clear(p->gpu, swframe->fbo, (float[4]){ 0.0, 0.0, 0.0, 1.0 });
    }

    // Flush GPU commands
    pl_gpu_flush(p->gpu);

submit:
    if (!use_application_swframe) {
        if (!pl_swapchain_submit_frame(p->swapchain)) {
            MP_ERR(p, "Failed submitting frame to swapchain!\n");
            return MPV_ERROR_GENERIC;
        }

        pl_swapchain_swap_buffers(p->swapchain);
    }

    return 0;
}

static struct mp_image *get_image(struct render_backend *ctx, int imgfmt,
                                  int w, int h, int stride_align, int flags)
{
    struct priv *p = ctx->priv;
    pl_gpu gpu = p->gpu;

    if (!gpu->limits.thread_safe || !gpu->limits.max_mapped_size)
        return NULL;

    if ((flags & VO_DR_FLAG_HOST_CACHED) && !gpu->limits.host_cached)
        return NULL;

    stride_align = mp_lcm(stride_align, gpu->limits.align_tex_xfer_pitch);
    stride_align = mp_lcm(stride_align, gpu->limits.align_tex_xfer_offset);
    int size = mp_image_get_alloc_size(imgfmt, w, h, stride_align);
    if (size < 0)
        return NULL;

    pl_buf buf = pl_buf_create(gpu, &(struct pl_buf_params) {
        .memory_type = PL_BUF_MEM_HOST,
        .host_mapped = true,
        .size = size + stride_align,
    });

    if (!buf)
        return NULL;

    struct mp_image *mpi = mp_image_from_buffer(imgfmt, w, h, stride_align,
                                                buf->data, buf->params.size,
                                                p, free_dr_buf);
    if (!mpi) {
        pl_buf_destroy(gpu, &buf);
        return NULL;
    }

    mp_mutex_lock(&p->dr_lock);
    MP_TARRAY_APPEND(p, p->dr_buffers, p->num_dr_buffers, buf);
    mp_mutex_unlock(&p->dr_lock);

    return mpi;
}

static void screenshot(struct render_backend *ctx, struct vo_frame *frame,
                       struct voctrl_screenshot *args)
{
    struct priv *p = ctx->priv;
    if (p->legacy.priv && !p->using_placebo) {
        p->legacy.fns->screenshot(&p->legacy, frame, args);
        return;
    }
    args->res = NULL;
    update_options(p);
    struct pl_frame_mix mix = {0};
    enum pl_queue_status status = pl_queue_update(p->queue, &mix, pl_queue_params(
        .pts = p->last_pts, .drift_compensation = 0));
    if (status == PL_QUEUE_ERR || !mix.num_frames)
        return;
    struct pl_frame image = *mix.frames[0];
    struct mp_image *mpi = image.user_data;
    if (!mpi)
        return;
    int w = p->last_w, h = p->last_h;
    struct mp_osd_res osd = p->osd_res;
    if (!args->scaled) {
        mp_image_params_get_dsize(&mpi->params, &w, &h);
        if (mpi->params.rotate % 180 == 90)
            MPSWAP(int, w, h);
        image.crop = (struct pl_rect2df) {0, 0, mpi->params.w, mpi->params.h};
        osd = (struct mp_osd_res) {.w = w, .h = h, .display_par = 1};
    }
    if (w <= 0 || h <= 0)
        return;
    int depth = args->high_bit_depth ? 16 : 8;
    pl_fmt fmt = pl_find_fmt(p->gpu, PL_FMT_UNORM, 4, depth, depth,
                            PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_HOST_READABLE);
    if (!fmt && depth == 16) {
        depth = 8;
        fmt = pl_find_fmt(p->gpu, PL_FMT_UNORM, 4, 8, 8,
                         PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_HOST_READABLE);
    }
    if (!fmt)
        return;
    pl_tex fbo = pl_tex_create(p->gpu, pl_tex_params(
        .w = w, .h = h, .format = fmt, .renderable = true,
        .host_readable = true, .blit_dst = true));
    if (!fbo)
        return;
    struct pl_frame target = {
        .repr = pl_color_repr_rgb, .color = pl_color_space_srgb,
        .num_planes = 1, .planes[0] = {
            .texture = fbo, .components = 4, .component_mapping = {0, 1, 2, 3},
        }, .crop = {0, 0, w, h},
    };
    const struct gl_video_opts *opts = p->opts_cache->opts;
    if (args->scaled) {
        target.color.primaries = opts->target_prim ?: PL_COLOR_PRIM_BT_709;
        target.color.transfer = opts->target_trc ?: PL_COLOR_TRC_SRGB;
        target.color.hdr.max_luma = opts->target_peak ?: 203;
        target.profile = p->target_profile;
        target.crop = (struct pl_rect2df) {p->dst.x0, p->dst.y0, p->dst.x1, p->dst.y1};
    } else if (args->native_csp) {
        target.color = image.color;
    }
    int flags = (!args->subs ? OSD_DRAW_OSD_ONLY : 0) | (!args->osd ? OSD_DRAW_SUB_ONLY : 0);
    update_overlays(p, osd, &target, &p->osd_state, p->osd,
                    frame->current ? frame->current->pts : 0, flags);
    struct pl_render_params params = p->pars->params;
    params.info_callback = NULL;
    params.frame_mixer = NULL;
    params.skip_caching_single_frame = true;
    params.preserve_mixing_cache = false;
    bool vivid_applied = false;
    if (!render_vivid_image(p, &image, &target, params, &vivid_applied))
        goto done;
    args->res = mp_image_alloc(depth == 16 ? IMGFMT_RGBA64 : IMGFMT_RGBA, w, h);
    if (!args->res)
        goto done;
    args->res->params.color = target.color;
    args->res->params.repr.levels = PL_COLOR_LEVELS_FULL;
    if (!pl_tex_download(p->gpu, pl_tex_transfer_params(
        .tex = fbo, .ptr = args->res->planes[0], .row_pitch = args->res->stride[0])))
        TA_FREEP(&args->res);
done:
    pl_tex_destroy(p->gpu, &fbo);
}

static void perfdata(struct render_backend *ctx,
                     struct voctrl_performance_data *out)
{
    struct priv *p = ctx->priv;
    if (p->legacy.priv && !p->using_placebo) {
        p->legacy.fns->perfdata(&p->legacy, out);
        return;
    }
    *out = p->performance;
}

static void destroy(struct render_backend *ctx)
{
    struct priv *p = ctx->priv;

    if (!p)
        return;

    // Destroy queue first
    pl_queue_destroy(&p->queue);
    if (p->legacy.priv) {
        p->legacy.fns->destroy(&p->legacy);
        talloc_free(p->legacy.priv);
        p->legacy.priv = NULL;
    }

    // Destroy OSD textures
    for (int i = 0; i < MP_ARRAY_SIZE(p->osd_state.entries); i++)
        pl_tex_destroy(p->gpu, &p->osd_state.entries[i].tex);
    for (int i = 0; i < p->num_sub_tex; i++)
        pl_tex_destroy(p->gpu, &p->sub_tex[i]);

    // Destroy hwdec
    mp_assert(p->num_dr_buffers == 0);
    mp_mutex_destroy(&p->dr_lock);
    mp_mutex_destroy(&p->status_lock);

    // Destroy renderer
    pl_renderer_destroy(&p->rr);

    // Destroy options
    pl_options_free(&p->pars);

    pl_tex_destroy(p->gpu, &p->target_tex);
    if (p->gl)
        pl_opengl_destroy(&p->gl);

    // Destroy pl_log if we created it
    if (!p->external_pllog && p->pllog)
        pl_log_destroy(&p->pllog);

    talloc_free(p);
    ctx->priv = NULL;
}

static void update_options(struct priv *p)
{
    m_config_cache_update(p->opts_cache);

    // Apply basic render options from config
    pl_options pars = p->pars;
    const struct gl_video_opts *opts = p->opts_cache->opts;

    pars->params.background_color[0] = opts->background_color.r / 255.0;
    pars->params.background_color[1] = opts->background_color.g / 255.0;
    pars->params.background_color[2] = opts->background_color.b / 255.0;
    pars->params.background_transparency = 1 - opts->background_color.a / 255.0;

    pars->params.color_map_params = &pars->color_map_params;
    const struct pl_tone_map_function *tone_maps[] = {
        [TONE_MAPPING_AUTO] = &pl_tone_map_auto,
        [TONE_MAPPING_CLIP] = &pl_tone_map_clip,
        [TONE_MAPPING_MOBIUS] = &pl_tone_map_mobius,
        [TONE_MAPPING_REINHARD] = &pl_tone_map_reinhard,
        [TONE_MAPPING_HABLE] = &pl_tone_map_hable,
        [TONE_MAPPING_GAMMA] = &pl_tone_map_gamma,
        [TONE_MAPPING_LINEAR] = &pl_tone_map_linear,
        [TONE_MAPPING_SPLINE] = &pl_tone_map_spline,
        [TONE_MAPPING_BT_2390] = &pl_tone_map_bt2390,
        [TONE_MAPPING_BT_2446A] = &pl_tone_map_bt2446a,
        [TONE_MAPPING_ST2094_40] = &pl_tone_map_st2094_40,
        [TONE_MAPPING_ST2094_10] = &pl_tone_map_st2094_10,
    };
    const struct pl_gamut_map_function *gamut_maps[] = {
        [GAMUT_AUTO] = pl_color_map_default_params.gamut_mapping,
        [GAMUT_CLIP] = &pl_gamut_map_clip,
        [GAMUT_PERCEPTUAL] = &pl_gamut_map_perceptual,
        [GAMUT_RELATIVE] = &pl_gamut_map_relative,
        [GAMUT_SATURATION] = &pl_gamut_map_saturation,
        [GAMUT_ABSOLUTE] = &pl_gamut_map_absolute,
        [GAMUT_DESATURATE] = &pl_gamut_map_desaturate,
        [GAMUT_DARKEN] = &pl_gamut_map_darken,
        [GAMUT_WARN] = &pl_gamut_map_highlight,
        [GAMUT_LINEAR] = &pl_gamut_map_linear,
    };
    pars->color_map_params.tone_mapping_function = tone_maps[opts->tone_map.curve];
    pars->color_map_params.gamut_mapping = gamut_maps[opts->tone_map.gamut_mode];
    pars->color_map_params.tone_mapping_param = isnan(opts->tone_map.curve_param) ? 0 : opts->tone_map.curve_param;
    pars->color_map_params.inverse_tone_mapping = opts->tone_map.inverse;
    pars->color_map_params.contrast_recovery = opts->tone_map.contrast_recovery;
    pars->color_map_params.contrast_smoothness = opts->tone_map.contrast_smoothness;
    pars->params.peak_detect_params = opts->tone_map.compute_peak >= 0 ? &pars->peak_detect_params : NULL;
    pars->peak_detect_params.smoothing_period = opts->tone_map.decay_rate;
    pars->peak_detect_params.scene_threshold_low = opts->tone_map.scene_threshold_low;
    pars->peak_detect_params.scene_threshold_high = opts->tone_map.scene_threshold_high;
    pars->peak_detect_params.percentile = opts->tone_map.peak_percentile;

    // Deband params
    pars->params.deband_params = opts->deband ? &pars->deband_params : NULL;
    if (opts->deband && opts->deband_opts) {
        pars->deband_params.iterations = opts->deband_opts->iterations;
        pars->deband_params.radius = opts->deband_opts->range;
        pars->deband_params.threshold = opts->deband_opts->threshold / 16.384;
        pars->deband_params.grain = opts->deband_opts->grain / 8.192;
    }

    // Sigmoid params
    pars->params.sigmoid_params = opts->sigmoid_upscaling ? &pars->sigmoid_params : NULL;
    if (opts->sigmoid_upscaling) {
        pars->sigmoid_params.center = opts->sigmoid_center;
        pars->sigmoid_params.slope = opts->sigmoid_slope;
    }
}

const struct render_backend_fns render_backend_libplacebo = {
    .init = init,
    .check_format = check_format,
    .set_parameter = set_parameter,
    .get_info = get_info,
    .reconfig = reconfig,
    .reset = reset,
    .update_external = update_external,
    .resize = resize,
    .get_target_size = get_target_size,
    .render = render,
    .get_image = get_image,
    .screenshot = screenshot,
    .perfdata = perfdata,
    .destroy = destroy,
};
