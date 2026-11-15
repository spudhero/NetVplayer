// Offline regression for the FFmpeg 9 layout boundary used by f_swresample.
// Link against the runtime's libswresample/libavutil and matching public headers.
// No mpv client, CoreAudio API, output device, or playback is used.
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/log.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { INPUT_SAMPLES = 2048, OUTPUT_SAMPLES = 4096, MAX_CHANNELS = 8 };

static int convert(struct SwrContext *s, float output[MAX_CHANNELS][OUTPUT_SAMPLES],
                   int outputs, const float input[MAX_CHANNELS][INPUT_SAMPLES], int inputs)
{
    const uint8_t *in[MAX_CHANNELS];
    uint8_t *out[MAX_CHANNELS];
    for (int c = 0; c < inputs; c++) in[c] = (const uint8_t *)input[c];
    for (int c = 0; c < outputs; c++) out[c] = (uint8_t *)output[c];
    int count = swr_convert(s, out, OUTPUT_SAMPLES, in, INPUT_SAMPLES);
    if (count < 0) return count;
    for (;;) {
        for (int c = 0; c < outputs; c++) out[c] = (uint8_t *)&output[c][count];
        int added = swr_convert(s, out, OUTPUT_SAMPLES - count, NULL, 0);
        if (added < 0) return added;
        if (!added) break;
        count += added;
        if (count == OUTPUT_SAMPLES) return AVERROR(ENOSPC);
    }
    return count;
}

static int mono_reference(float *out, const float *in, int input_rate, int output_rate)
{
    struct SwrContext *s = NULL;
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    int ret = swr_alloc_set_opts2(&s, &mono, AV_SAMPLE_FMT_FLTP, output_rate,
                                 &mono, AV_SAMPLE_FMT_FLTP, input_rate, 0, NULL);
    if (ret < 0 || (ret = swr_init(s)) < 0) { swr_free(&s); return ret; }
    const uint8_t *input[] = {(const uint8_t *)in};
    uint8_t *output[] = {(uint8_t *)out};
    int count = swr_convert(s, output, OUTPUT_SAMPLES, input, INPUT_SAMPLES);
    if (count >= 0) {
        for (;;) {
            output[0] = (uint8_t *)(out + count);
            int added = swr_convert(s, output, OUTPUT_SAMPLES - count, NULL, 0);
            if (added < 0) { count = added; break; }
            if (!added) break;
            count += added;
        }
    }
    swr_free(&s);
    return count;
}

static bool identity_case(const char *name, int inputs, int outputs,
                          int input_rate, int output_rate, bool known)
{
    // Both endpoints are UNSPEC after mpv's no-remix branch. For a known
    // comparison case, give SWR real 6.1/7.1 masks rather than fake low bits.
    AVChannelLayout in = {.order=AV_CHANNEL_ORDER_UNSPEC,.nb_channels=inputs};
    AVChannelLayout out = {.order=AV_CHANNEL_ORDER_UNSPEC,.nb_channels=outputs};
    if (known) {
        av_channel_layout_default(&in, inputs);
        av_channel_layout_default(&out, outputs);
    }
    struct SwrContext *s = NULL;
    int ret = swr_alloc_set_opts2(&s, &out, AV_SAMPLE_FMT_FLTP, output_rate,
                                 &in, AV_SAMPLE_FMT_FLTP, input_rate, 0, NULL);
    if (ret >= 0 && !known && inputs != outputs) {
        double matrix[MAX_CHANNELS * MAX_CHANNELS] = {0};
        for (int i = 0; i < inputs && i < outputs; i++) matrix[i * inputs + i] = 1;
        ret = swr_set_matrix(s, matrix, inputs);
    }
    if (ret >= 0) ret = swr_init(s);
    if (ret < 0) {
        fprintf(stderr, "%s: initialization failed: %d\n", name, ret);
        swr_free(&s);
        return false;
    }
    float input[MAX_CHANNELS][INPUT_SAMPLES] = {{0}};
    float output[MAX_CHANNELS][OUTPUT_SAMPLES] = {{0}};
    for (int c = 0; c < inputs; c++) {
        for (int n = 0; n < INPUT_SAMPLES; n++)
            input[c][n] = (float)(0.07 * sin((c + 1) * 0.031 * n) + 0.003 * (c + 1));
        input[c][117 + 13 * c] += 0.2f;
    }
    int count = convert(s, output, outputs, input, inputs);
    swr_free(&s);
    bool passed = count > 0;
    double max_error = 0;
    for (int c = 0; c < outputs && passed; c++) {
        float expected[OUTPUT_SAMPLES] = {0};
        int mono_count = c < inputs ? mono_reference(expected, input[c], input_rate, output_rate) : count;
        passed = mono_count == count;
        for (int n = 0; n < count && passed; n++) {
            double error = fabs(output[c][n] - expected[n]);
            if (error > max_error) max_error = error;
            if (!isfinite(output[c][n]) || error > 0.000003) passed = false;
        }
    }
    printf("{\"case\":\"%s\",\"passed\":%s,\"frames\":%d,\"maxErrorVsIndependentMono\":%.9g}\n",
           name, passed ? "true" : "false", count, max_error);
    av_channel_layout_uninit(&in);
    av_channel_layout_uninit(&out);
    return passed;
}

static bool legacy_failure_is_reproduced(void)
{
    AVChannelLayout in = {.order=AV_CHANNEL_ORDER_UNSPEC,.nb_channels=7};
    AVChannelLayout out = {0};
    av_channel_layout_from_mask(&out, 0x7f);
    struct SwrContext *s = NULL;
    int ret = swr_alloc_set_opts2(&s, &out, AV_SAMPLE_FMT_FLTP, 48000,
                                 &in, AV_SAMPLE_FMT_FLTP, 48000, 0, NULL);
    if (ret >= 0) ret = swr_init(s);
    swr_free(&s);
    av_channel_layout_uninit(&out);
    bool passed = ret == AVERROR(EINVAL);
    printf("{\"case\":\"legacy-unspec7-to-fake-mask-0x7f\",\"passed\":%s,\"initCode\":%d}\n",
           passed ? "true" : "false", ret);
    return passed;
}

static bool known_remix_still_works(void)
{
    AVChannelLayout in = AV_CHANNEL_LAYOUT_6POINT1;
    AVChannelLayout out = AV_CHANNEL_LAYOUT_STEREO;
    struct SwrContext *s = NULL;
    int ret = swr_alloc_set_opts2(&s, &out, AV_SAMPLE_FMT_FLTP, 48000,
                                 &in, AV_SAMPLE_FMT_FLTP, 48000, 0, NULL);
    if (ret >= 0) ret = swr_init(s);
    float input[MAX_CHANNELS][INPUT_SAMPLES] = {{0}};
    float output[MAX_CHANNELS][OUTPUT_SAMPLES] = {{0}};
    input[2][100] = 0.5f; // Known center must reach both stereo speakers.
    int count = ret >= 0 ? convert(s, output, 2, input, 7) : ret;
    bool passed = count > 100 && output[0][100] > 0 && output[0][100] == output[1][100];
    printf("{\"case\":\"known-6.1-to-stereo-center-remix\",\"passed\":%s,\"frames\":%d}\n",
           passed ? "true" : "false", count);
    swr_free(&s);
    return passed;
}

int main(void)
{
    av_log_set_level(AV_LOG_ERROR);
    bool passed = legacy_failure_is_reproduced();
    passed &= identity_case("7ch-no-remix-48000", 7, 7, 48000, 48000, false);
    passed &= identity_case("7ch-no-remix-48000-to-44100", 7, 7, 48000, 44100, false);
    passed &= identity_case("7ch-no-remix-44100-to-48000", 7, 7, 44100, 48000, false);
    passed &= identity_case("known-6.1-identity", 7, 7, 48000, 48000, true);
    passed &= identity_case("known-7.1-identity", 8, 8, 48000, 48000, true);
    passed &= identity_case("unknown-8ch-identity", 8, 8, 48000, 48000, false);
    passed &= identity_case("unknown-7-to-8-index-preserving-zero-fill", 7, 8, 48000, 48000, false);
    passed &= identity_case("unknown-8-to-7-index-preserving-truncate", 8, 7, 48000, 48000, false);
    passed &= identity_case("unknown-7-to-8-resampled-zero-fill", 7, 8, 48000, 44100, false);
    passed &= known_remix_still_works();
    return passed ? 0 : 1;
}
