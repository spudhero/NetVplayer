// Test-host-only CoreAudio IOProc interposer. Never link into the product.
// clang -std=c11 -O2 -Wall -Wextra -dynamiclib -framework CoreAudio \
//   script/probes/coreaudio_io_capture.c -o /private/tmp/coreaudio_io_capture.dylib
// Opt in for this process only with DYLD_INSERT_LIBRARIES and an unused absolute
// NETVPLAYER_CA_CAPTURE_PREFIX. Normal process exit writes PREFIX.raw, .json and
// .callbacks.csv. Without that variable the interposer does nothing.
// The callback calls the real producer first, then copies at most the first
// 64 MiB into prefaulted memory (87.38 s at 768000 B/s). No file IO, allocations
// or logging occur there. Statistics continue after the byte capture is full.

#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

enum { CAPTURE_BYTES = 64 * 1024 * 1024, MAX_PROCS = 32,
       MAX_EVENTS = 131072, HIST_BUCKETS = 32 };

struct callback_event {
    uint64_t start, producer_ticks, wrapper_ticks, interval;
    uint64_t output_host, capture_offset;
    double output_sample_time;
    uint32_t bytes, channels, buffers, copied;
    uint32_t current_flags, output_flags, slot;
    int32_t status;
};

struct proc_slot {
    AudioDeviceIOProc producer;
    void *producer_context;
    AudioDeviceID device;
    AudioDeviceIOProcID proc;
    atomic_uint_fast64_t callbacks, total_bytes, last_start, first_start;
    atomic_uint_fast64_t max_interval, max_producer, max_wrapper;
    atomic_uint_fast64_t output_host_valid, output_sample_valid, current_host_valid;
    atomic_uint_fast64_t errors, multi_buffer, null_buffer, bytes_copied;
    atomic_uint_fast64_t first_output_host, last_output_host;
    atomic_uint_fast64_t sample_steps, sample_step_mismatches;
    atomic_bool destroyed;
    double first_sample_time, last_sample_time, previous_sample_time;
    double min_sample_step, max_sample_step;
    uint32_t first_output_flags, last_output_flags, previous_bytes;
};

struct size_bucket { atomic_uint size; atomic_uint_fast64_t callbacks; };

static OSStatus (*real_create)(AudioDeviceID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);
static OSStatus (*real_destroy)(AudioDeviceID, AudioDeviceIOProcID);
static bool enabled;
static char *prefix;
static unsigned char *capture;
static struct callback_event *events;
static struct proc_slot slots[MAX_PROCS];
static struct size_bucket histogram[HIST_BUCKETS];
static atomic_uint slot_count;
static atomic_uint_fast64_t event_count, reserved_bytes;
static mach_timebase_info_data_t timebase;

static void atomic_max(atomic_uint_fast64_t *value, uint64_t candidate)
{
    uint_fast64_t old = atomic_load_explicit(value, memory_order_relaxed);
    while (old < candidate && !atomic_compare_exchange_weak_explicit(
            value, &old, candidate, memory_order_relaxed, memory_order_relaxed)) {}
}

static double ns(uint64_t ticks)
{
    return (double)ticks * timebase.numer / timebase.denom;
}

static void count_size(uint32_t size)
{
    if (!size) return;
    for (unsigned i = 0; i < HIST_BUCKETS; i++) {
        unsigned expected = 0;
        unsigned known = atomic_load_explicit(&histogram[i].size, memory_order_relaxed);
        if (known == size || (!known && atomic_compare_exchange_strong_explicit(
                &histogram[i].size, &expected, size, memory_order_relaxed, memory_order_relaxed))) {
            atomic_fetch_add_explicit(&histogram[i].callbacks, 1, memory_order_relaxed);
            return;
        }
    }
}

static OSStatus capture_callback(AudioDeviceID device, const AudioTimeStamp *now,
        const AudioBufferList *input, const AudioTimeStamp *input_time,
        AudioBufferList *output, const AudioTimeStamp *output_time, void *context)
{
    struct proc_slot *s = context;
    uint64_t start = mach_absolute_time();
    OSStatus status = s->producer(device, now, input, input_time, output, output_time,
                                  s->producer_context);
    uint64_t producer_end = mach_absolute_time();
    uint64_t previous = atomic_exchange_explicit(&s->last_start, start, memory_order_relaxed);
    uint64_t interval = previous && start >= previous ? start - previous : 0;
    uint64_t ordinal = atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    uint32_t buffers = output ? output->mNumberBuffers : 0;
    AudioBuffer b = buffers == 1 ? output->mBuffers[0] : (AudioBuffer){0};
    uint64_t offset = 0;
    uint32_t copied = 0;

    if (!ordinal) {
        atomic_store_explicit(&s->first_start, start, memory_order_relaxed);
        s->first_output_flags = output_time ? output_time->mFlags : 0;
    }
    if (buffers != 1) atomic_fetch_add_explicit(&s->multi_buffer, 1, memory_order_relaxed);
    if (buffers == 1 && !b.mData) atomic_fetch_add_explicit(&s->null_buffer, 1, memory_order_relaxed);
    if (b.mData && b.mDataByteSize) {
        offset = atomic_fetch_add_explicit(&reserved_bytes, b.mDataByteSize, memory_order_relaxed);
        if (offset < CAPTURE_BYTES) {
            copied = (uint32_t)((CAPTURE_BYTES - offset < b.mDataByteSize)
                ? CAPTURE_BYTES - offset : b.mDataByteSize);
            memcpy(capture + offset, b.mData, copied);
            atomic_fetch_add_explicit(&s->bytes_copied, copied, memory_order_relaxed);
        }
    }
    atomic_fetch_add_explicit(&s->total_bytes, b.mDataByteSize, memory_order_relaxed);
    if (status) atomic_fetch_add_explicit(&s->errors, 1, memory_order_relaxed);
    if (now && (now->mFlags & kAudioTimeStampHostTimeValid))
        atomic_fetch_add_explicit(&s->current_host_valid, 1, memory_order_relaxed);
    if (output_time) {
        s->last_output_flags = output_time->mFlags;
        if (output_time->mFlags & kAudioTimeStampHostTimeValid) {
            uint64_t count = atomic_fetch_add_explicit(&s->output_host_valid, 1, memory_order_relaxed);
            if (!count) atomic_store_explicit(&s->first_output_host, output_time->mHostTime, memory_order_relaxed);
            atomic_store_explicit(&s->last_output_host, output_time->mHostTime, memory_order_relaxed);
        }
        if (output_time->mFlags & kAudioTimeStampSampleTimeValid) {
            uint64_t count = atomic_fetch_add_explicit(&s->output_sample_valid, 1, memory_order_relaxed);
            double sample = output_time->mSampleTime;
            if (!count) s->first_sample_time = sample;
            else {
                double step = sample - s->previous_sample_time;
                uint64_t steps = atomic_fetch_add_explicit(&s->sample_steps, 1, memory_order_relaxed);
                if (!steps || step < s->min_sample_step) s->min_sample_step = step;
                if (!steps || step > s->max_sample_step) s->max_sample_step = step;
                // Diagnostic hypothesis only: cec3 is 4 bytes/carrier frame.
                if (step != s->previous_bytes / 4.0)
                    atomic_fetch_add_explicit(&s->sample_step_mismatches, 1, memory_order_relaxed);
            }
            s->last_sample_time = s->previous_sample_time = sample;
            s->previous_bytes = b.mDataByteSize;
        }
    }
    count_size(b.mDataByteSize);
    atomic_max(&s->max_interval, interval);
    atomic_max(&s->max_producer, producer_end - start);
    uint64_t index = atomic_fetch_add_explicit(&event_count, 1, memory_order_relaxed);
    uint64_t end = mach_absolute_time();
    atomic_max(&s->max_wrapper, end - start);
    if (index < MAX_EVENTS) events[index] = (struct callback_event){
        .start = start, .producer_ticks = producer_end - start, .wrapper_ticks = end - start,
        .interval = interval, .output_host = output_time ? output_time->mHostTime : 0,
        .capture_offset = offset, .output_sample_time = output_time ? output_time->mSampleTime : 0,
        .bytes = b.mDataByteSize, .channels = b.mNumberChannels, .buffers = buffers,
        .copied = copied, .current_flags = now ? now->mFlags : 0,
        .output_flags = output_time ? output_time->mFlags : 0,
        .slot = (uint32_t)(s - slots), .status = status,
    };
    return status;
}

static OSStatus capture_create(AudioDeviceID device, AudioDeviceIOProc proc,
                               void *context, AudioDeviceIOProcID *result)
{
    if (!enabled) return real_create(device, proc, context, result);
    unsigned index = atomic_fetch_add_explicit(&slot_count, 1, memory_order_relaxed);
    if (index >= MAX_PROCS) return real_create(device, proc, context, result);
    struct proc_slot *s = &slots[index];
    s->producer = proc;
    s->producer_context = context;
    s->device = device;
    OSStatus status = real_create(device, capture_callback, s, result);
    if (!status) s->proc = *result;
    return status;
}

static OSStatus capture_destroy(AudioDeviceID device, AudioDeviceIOProcID proc)
{
    OSStatus status = real_destroy(device, proc);
    if (enabled && !status) {
        unsigned count = atomic_load_explicit(&slot_count, memory_order_relaxed);
        if (count > MAX_PROCS) count = MAX_PROCS;
        for (unsigned i = 0; i < count; i++)
            if (slots[i].device == device && slots[i].proc == proc)
                atomic_store_explicit(&slots[i].destroyed, true, memory_order_relaxed);
    }
    return status;
}

__attribute__((used)) static const struct { const void *replacement, *original; }
interpose[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)capture_create, (const void *)AudioDeviceCreateIOProcID },
    { (const void *)capture_destroy, (const void *)AudioDeviceDestroyIOProcID },
};

__attribute__((constructor)) static void initialize_capture(void)
{
    // dyld excludes the interposer image's own symbol bindings from its
    // replacement table. dlsym(RTLD_NEXT), in contrast, can return our own
    // replacement and recurse indefinitely on current macOS.
    real_create = AudioDeviceCreateIOProcID;
    real_destroy = AudioDeviceDestroyIOProcID;
    const char *value = getenv("NETVPLAYER_CA_CAPTURE_PREFIX");
    if (!value || value[0] != '/' || !value[1] || !real_create || !real_destroy) return;
    if (!atomic_is_lock_free(&event_count) || !atomic_is_lock_free(&slot_count)) return;
    prefix = strdup(value);
    capture = calloc(1, CAPTURE_BYTES);
    events = calloc(MAX_EVENTS, sizeof(*events));
    if (!prefix || !capture || !events) return;
    // Fault memory in before any IOProc is registered.
    volatile unsigned char *pages = capture;
    for (size_t i = 0; i < CAPTURE_BYTES; i += 4096) pages[i] = 0;
    pages = (volatile unsigned char *)events;
    for (size_t i = 0; i < MAX_EVENTS * sizeof(*events); i += 4096) pages[i] = 0;
    mach_timebase_info(&timebase);
    enabled = true;
}

// Software-only dyld smoke test entry point. The caller need not open a device.
int netvplayer_ca_capture_verify_bindings(void)
{
    Dl_info create = {0}, destroy = {0};
    dladdr((const void *)real_create, &create);
    dladdr((const void *)real_destroy, &destroy);
    bool valid = real_create && real_destroy && real_create != capture_create
        && real_destroy != capture_destroy;
    fprintf(stdout, "{\"bindingsValid\":%s,\"createOriginal\":\"%p\",\"createWrapper\":\"%p\",\"createImage\":\"%s\",\"destroyOriginal\":\"%p\",\"destroyWrapper\":\"%p\",\"destroyImage\":\"%s\"}\n",
            valid ? "true" : "false", (const void *)real_create, (const void *)capture_create,
            create.dli_fname ? create.dli_fname : "", (const void *)real_destroy,
            (const void *)capture_destroy, destroy.dli_fname ? destroy.dli_fname : "");
    return valid ? 0 : 1;
}

static FILE *new_output(const char *suffix)
{
    size_t length = strlen(prefix) + strlen(suffix) + 1;
    char *path = malloc(length);
    if (!path) return NULL;
    snprintf(path, length, "%s%s", prefix, suffix);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    free(path);
    if (fd < 0) return NULL;
    FILE *file = fdopen(fd, "wb");
    if (!file) close(fd);
    return file;
}

__attribute__((destructor)) static void finish_capture(void)
{
    if (!enabled) return;
    // This test host destroys all IOProcs before exiting. Do not race a live one.
    unsigned count = atomic_load_explicit(&slot_count, memory_order_relaxed);
    if (count > MAX_PROCS) count = MAX_PROCS;
    for (unsigned i = 0; i < count; i++)
        if (slots[i].proc && !atomic_load_explicit(&slots[i].destroyed, memory_order_relaxed)) return;
    uint64_t bytes = atomic_load_explicit(&reserved_bytes, memory_order_relaxed);
    uint64_t captured = bytes < CAPTURE_BYTES ? bytes : CAPTURE_BYTES;
    uint64_t total_events = atomic_load_explicit(&event_count, memory_order_relaxed);
    uint64_t stored_events = total_events < MAX_EVENTS ? total_events : MAX_EVENTS;
    FILE *raw = new_output(".raw");
    bool raw_ok = raw && fwrite(capture, 1, captured, raw) == captured;
    if (raw && fclose(raw)) raw_ok = false;
    FILE *csv = new_output(".callbacks.csv");
    if (csv) {
        fprintf(csv, "slot,start_ns,interval_ns,producer_ns,wrapper_ns,bytes,channels,buffers,output_host_ns,output_sample_time,current_flags,output_flags,status,capture_offset,copied\n");
        for (uint64_t i = 0; i < stored_events; i++) {
            struct callback_event *e = &events[i];
            fprintf(csv, "%u,%.0f,%.0f,%.0f,%.0f,%u,%u,%u,%.0f,%.17g,%u,%u,%d,%llu,%u\n",
                e->slot, ns(e->start), ns(e->interval), ns(e->producer_ticks), ns(e->wrapper_ticks),
                e->bytes, e->channels, e->buffers, ns(e->output_host), e->output_sample_time,
                e->current_flags, e->output_flags, e->status,
                (unsigned long long)e->capture_offset, e->copied);
        }
        fclose(csv);
    }
    FILE *json = new_output(".json");
    if (json) {
        fprintf(json, "{\n  \"schema\":1,\n  \"scope\":\"Test host IOProc output only; no receiver-lock claim\",\n  \"rawWritten\":%s,\n  \"captureLimitBytes\":%u,\n  \"capturedBytes\":%llu,\n  \"totalCallbacks\":%llu,\n  \"storedCallbackEvents\":%llu,\n  \"totalOutputBytes\":%llu,\n  \"ioProcs\":[\n",
            raw_ok ? "true" : "false", CAPTURE_BYTES, (unsigned long long)captured,
            (unsigned long long)total_events, (unsigned long long)stored_events, (unsigned long long)bytes);
        for (unsigned i = 0; i < count; i++) {
            struct proc_slot *s = &slots[i];
            uint64_t callbacks = atomic_load(&s->callbacks);
            uint64_t output_valid = atomic_load(&s->output_host_valid);
            double elapsed = ns(atomic_load(&s->last_start) - atomic_load(&s->first_start)) / 1e9;
            double output_elapsed = output_valid > 1
                ? ns(atomic_load(&s->last_output_host) - atomic_load(&s->first_output_host)) / 1e9 : 0;
            fprintf(json, "    {\"slot\":%u,\"destroyed\":%s,\"callbacks\":%llu,\"totalBytes\":%llu,\"capturedBytes\":%llu,\"callbackElapsedSeconds\":%.9f,\"outputHostElapsedSeconds\":%.9f,\"bytesPerCallbackElapsedSecond\":%.3f,\"currentHostValid\":%llu,\"outputHostValid\":%llu,\"outputSampleValid\":%llu,\"firstOutputHostNs\":%.0f,\"lastOutputHostNs\":%.0f,\"firstOutputSampleTime\":%.17g,\"lastOutputSampleTime\":%.17g,\"minSampleStep\":%.17g,\"maxSampleStep\":%.17g,\"sampleStepMismatchesVs4ByteFrames\":%llu,\"firstOutputFlags\":%u,\"lastOutputFlags\":%u,\"maxCallbackGapNs\":%.0f,\"maxProducerNs\":%.0f,\"maxWrapperNs\":%.0f,\"callbackErrors\":%llu,\"notSingleOutputBuffer\":%llu,\"nullOutputBuffer\":%llu}%s\n",
                i, atomic_load(&s->destroyed) ? "true" : "false", (unsigned long long)callbacks,
                (unsigned long long)atomic_load(&s->total_bytes), (unsigned long long)atomic_load(&s->bytes_copied),
                elapsed, output_elapsed, elapsed > 0 ? atomic_load(&s->total_bytes) / elapsed : 0,
                (unsigned long long)atomic_load(&s->current_host_valid), (unsigned long long)output_valid,
                (unsigned long long)atomic_load(&s->output_sample_valid),
                ns(atomic_load(&s->first_output_host)), ns(atomic_load(&s->last_output_host)),
                s->first_sample_time, s->last_sample_time, s->min_sample_step, s->max_sample_step,
                (unsigned long long)atomic_load(&s->sample_step_mismatches), s->first_output_flags,
                s->last_output_flags, ns(atomic_load(&s->max_interval)), ns(atomic_load(&s->max_producer)),
                ns(atomic_load(&s->max_wrapper)), (unsigned long long)atomic_load(&s->errors),
                (unsigned long long)atomic_load(&s->multi_buffer), (unsigned long long)atomic_load(&s->null_buffer),
                i + 1 < count ? "," : "");
        }
        fprintf(json, "  ],\n  \"callbackByteSizeHistogram\":[");
        bool comma = false;
        for (unsigned i = 0; i < HIST_BUCKETS; i++) {
            unsigned size = atomic_load(&histogram[i].size);
            if (!size) continue;
            fprintf(json, "%s{\"bytes\":%u,\"callbacks\":%llu}", comma ? "," : "", size,
                    (unsigned long long)atomic_load(&histogram[i].callbacks));
            comma = true;
        }
        fprintf(json, "]\n}\n");
        fclose(json);
    }
}
