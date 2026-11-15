#include "NVMPVColorProfile.h"

#include <ColorSync/ColorSync.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

enum { maximum_profile_bytes = 4 * 1024 * 1024, curve_samples = 4097 };

static uint32_t read_be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

// Do not reinterpret LUT profiles, sampled curves, non-RGB profiles, or malformed
// tag tables. Their existing mpv/LittleCMS handling remains authoritative.
static int is_matrix_gamma_profile(const uint8_t *bytes, size_t length, unsigned *identity) {
    if (length < 132 || read_be32(bytes) != length ||
        memcmp(bytes + 16, "RGB XYZ ", 8) || memcmp(bytes + 36, "acsp", 4)) { return 0; }
    uint32_t count = read_be32(bytes + 128);
    if (count > (length - 132) / 12) { return 0; }
    unsigned curves = 0, columns = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *entry = bytes + 132 + 12 * i;
        size_t offset = read_be32(entry + 4), size = read_be32(entry + 8);
        if (offset > length || size > length - offset) { return 0; }
        if (!memcmp(entry, "A2B", 3) || !memcmp(entry, "B2A", 3) ||
            !memcmp(entry, "D2B", 3) || !memcmp(entry, "B2D", 3)) { return 0; }
        int channel = entry[0] == 'r' ? 0 : entry[0] == 'g' ? 1 : entry[0] == 'b' ? 2 : -1;
        if (channel < 0) { continue; }
        unsigned bit = 1U << channel;
        if (!memcmp(entry + 1, "TRC", 3)) {
            // Some display profiles include the 4-byte alignment padding in
            // the tag size (16), while generated profiles report 14 bytes.
            if (size < 14 || size > 16 || memcmp(bytes + offset, "curv", 4) ||
                read_be32(bytes + offset + 8) != 1 || (curves & bit)) { return 0; }
            unsigned gamma = (unsigned)bytes[offset + 12] << 8 | bytes[offset + 13];
            if (!gamma || gamma > 8 * 256) { return 0; }
            if (gamma == 256) { *identity |= bit; }
            curves |= bit;
        } else if (!memcmp(entry + 1, "XYZ", 3)) {
            if (size != 20 || memcmp(bytes + offset, "XYZ ", 4) || (columns & bit)) { return 0; }
            columns |= bit;
        }
    }
    return curves == 7 && columns == 7;
}

static double response(const double p[7], int type, double x) {
    if (type == 0) { return pow(x, p[0]); }
    return x < p[4] ? p[3] * x + (type == 4 ? p[6] : 0)
        : pow(p[1] * x + p[2], p[0]) + (type == 4 ? p[5] : 0);
}

static CFDataRef copy_inverse_curve(CFDictionaryRef fragment) {
    const CFStringRef keys[] = { kColorSyncConversionParamCurve0,
        kColorSyncConversionParamCurve3, kColorSyncConversionParamCurve4 };
    const int types[] = { 0, 3, 4 };
    CFArrayRef values = NULL;
    int type = -1;
    for (int i = 0; i < 3; i++) {
        CFTypeRef value = CFDictionaryGetValue(fragment, keys[i]);
        if (value) {
            if (type >= 0 || CFGetTypeID(value) != CFArrayGetTypeID()) { return NULL; }
            type = types[i];
            values = value;
        }
    }
    if (!values || CFArrayGetCount(values) != 7) { return NULL; }
    double p[7];
    for (int i = 0; i < 7; i++) {
        CFTypeRef number = CFArrayGetValueAtIndex(values, i);
        if (CFGetTypeID(number) != CFNumberGetTypeID() ||
            !CFNumberGetValue(number, kCFNumberDoubleType, &p[i]) || !isfinite(p[i])) { return NULL; }
    }
    if (p[0] <= 0 || (type && (p[1] <= 0 || p[3] <= 0 || p[4] < 0 || p[4] > 1))) { return NULL; }
    double previous = response(p, type, 0);
    if (!isfinite(previous) || fabs(previous) > 0.0001) { return NULL; }
    for (int i = 1; i <= 256; i++) {
        double value = response(p, type, (double)i / 256);
        if (!isfinite(value) || value < previous) { return NULL; }
        previous = value;
    }
    if (fabs(previous - 1) > 0.0001) { return NULL; }

    // ICC TRCs describe device -> linear, the inverse of the public native
    // PCS -> device response. Sample in device-code space, not linear XYZ:
    // a coarse uniform XYZ CLUT loses near-black precision.
    uint8_t table[12 + 2 * curve_samples] = { 'c', 'u', 'r', 'v' };
    table[8] = (curve_samples >> 24) & 255;
    table[9] = (curve_samples >> 16) & 255;
    table[10] = (curve_samples >> 8) & 255;
    table[11] = curve_samples & 255;
    for (int i = 0; i < curve_samples; i++) {
        double target = (double)i / (curve_samples - 1), low = 0, high = 1;
        for (int step = 0; step < 28; step++) {
            double mid = (low + high) * 0.5;
            if (response(p, type, mid) < target) { low = mid; } else { high = mid; }
        }
        uint16_t value = (uint16_t)lround((low + high) * 0.5 * 65535);
        table[12 + 2 * i] = value >> 8;
        table[13 + 2 * i] = value & 255;
    }
    return CFDataCreate(kCFAllocatorDefault, table, sizeof(table));
}

CFDataRef nv_mpv_copy_render_profile(const void *bytes, size_t length) {
    if (!bytes || !length || length > maximum_profile_bytes) { return NULL; }
    CFDataRef input = CFDataCreate(kCFAllocatorDefault, bytes, length);
    unsigned identity = 0;
    if (!input || !is_matrix_gamma_profile(bytes, length, &identity) || identity == 7) { return input; }

    // ColorSync smooths the inverse of a single-gamma display TRC near black;
    // LittleCMS interprets the same bytes as a pure power. Export the native
    // response into a private render profile, keeping the real display matrix
    // and the original AppKit window tag. No profile ID, gamma or slope is fixed.
    ColorSyncProfileRef profile = ColorSyncProfileCreate(input, NULL);
    ColorSyncMutableProfileRef output = profile ? ColorSyncProfileCreateMutableCopy(profile) : NULL;
    const void *keys[] = { kColorSyncProfile, kColorSyncRenderingIntent,
        kColorSyncTransformTag, kColorSyncBlackPointCompensation };
    const void *values[] = { profile, kColorSyncRenderingIntentRelative,
        kColorSyncTransformPCSToDevice, kCFBooleanFalse };
    CFDictionaryRef stage = profile ? CFDictionaryCreate(kCFAllocatorDefault, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
    CFArrayRef sequence = stage ? CFArrayCreate(kCFAllocatorDefault, (const void **)&stage, 1,
        &kCFTypeArrayCallBacks) : NULL;
    ColorSyncTransformRef transform = sequence ? ColorSyncTransformCreate(sequence, NULL) : NULL;
    CFTypeRef fragments = transform ? ColorSyncTransformCopyProperty(transform,
        kColorSyncTransformParametricConversionData, NULL) : NULL;
    unsigned channels = 0;
    int valid = output && fragments && CFGetTypeID(fragments) == CFArrayGetTypeID();
    const CFStringRef tags[] = { CFSTR("rTRC"), CFSTR("gTRC"), CFSTR("bTRC") };
    for (CFIndex i = 0; valid && i < CFArrayGetCount(fragments); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(fragments, i);
        if (CFGetTypeID(item) != CFDictionaryGetTypeID()) { valid = 0; break; }
        CFDictionaryRef fragment = item;
        if (CFDictionaryContainsKey(fragment, kColorSyncConversionMatrix)) { continue; }
        CFTypeRef channel = CFDictionaryGetValue(fragment, kColorSyncConversionChannelID);
        int number = -1;
        if (!channel || CFGetTypeID(channel) != CFNumberGetTypeID() ||
            !CFNumberGetValue(channel, kCFNumberIntType, &number) || number < 0 || number > 2 ||
            (channels & (1U << number))) { valid = 0; break; }
        CFDataRef curve = copy_inverse_curve(fragment);
        if (!curve) { valid = 0; break; }
        ColorSyncProfileSetTag(output, tags[number], curve);
        CFRelease(curve);
        channels |= 1U << number;
    }
    // ColorSync omits identity channels from the fragment list. Their original
    // gamma=1 tags already describe the native response and must stay intact.
    CFDataRef result = valid && (channels | identity) == 7 ? ColorSyncProfileCopyData(output, NULL) : NULL;
    if (result && CFDataGetLength(result) > maximum_profile_bytes) { CFRelease(result); result = NULL; }
    if (fragments) { CFRelease(fragments); }
    if (transform) { CFRelease(transform); }
    if (sequence) { CFRelease(sequence); }
    if (stage) { CFRelease(stage); }
    if (output) { CFRelease(output); }
    if (profile) { CFRelease(profile); }
    CFRelease(input);
    return result;
}
