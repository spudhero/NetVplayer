#include "NVDolbyVisionMetadata.h"
#include <CommonCrypto/CommonDigest.h>
#include <string.h>

static uint32_t crc32_mpeg2(const uint8_t *bytes, size_t count)
{
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < count; i++) {
        crc ^= (uint32_t)bytes[i] << 24;
        for (int bit = 0; bit < 8; bit++)
            crc = crc & 0x80000000 ? (crc << 1) ^ 0x04c11db7 : crc << 1;
    }
    return crc;
}

static void set_bits(uint8_t *bytes, size_t bit, unsigned count, uint32_t value)
{
    for (unsigned i = 0; i < count; i++, bit++) {
        uint8_t mask = (uint8_t)(1u << (7 - bit % 8));
        bytes[bit / 8] = (bytes[bit / 8] & ~mask) |
            ((value >> (count - 1 - i)) & 1 ? mask : 0);
    }
}

bool nv_dovi_system_rpu_set_l1(const uint8_t *input, size_t length,
    uint16_t minimum, uint16_t maximum, uint16_t average,
    uint8_t *output, size_t capacity, size_t *output_length)
{
    if (output_length) *output_length = 0;
    if (!input || !output || !output_length || length < 344 || length > 1024 ||
        minimum > 12 || maximum < 2081 || maximum > 3079 || average < 819 || average >= maximum)
        return false;
    uint8_t raw[512]; size_t size = 0; unsigned zeroes = 0;
    for (size_t i = 0; i < length; i++) {
        uint8_t b = input[i];
        if (zeroes == 2 && b == 3) {
            if (i + 1 >= length || input[i + 1] > 3) return false;
            zeroes = 0; continue;
        }
        if (size == sizeof(raw)) return false;
        raw[size++] = b;
        zeroes = b == 0 ? zeroes + 1 : 0;
    }
    if (size != 344 || raw[0] != 0x19 || raw[size - 1] != 0x80) return false;
    size_t crc_at = size - 5;
    uint32_t stored = (uint32_t)raw[crc_at] << 24 | (uint32_t)raw[crc_at + 1] << 16 |
                      (uint32_t)raw[crc_at + 2] << 8 | raw[crc_at + 3];
    if (crc32_mpeg2(raw + 1, crc_at - 1) != stored) return false;
    // The system can supply a valid fixed HLG reshaping RPU with default L1
    // values even for different pixels. Match the WHOLE layout/coefficients,
    // ignoring only L1 and its CRC. No byte offset is trusted without this hash.
    // CMv2.9 Level 1 is three 12-bit PQ values; the surrounding syntax and the
    // generated output are checked independently using dovi_tool/libdovi.
    const size_t l1_bit = 2669;
    uint8_t shape[sizeof(raw)], hash[CC_SHA256_DIGEST_LENGTH];
    memcpy(shape, raw, size);
    set_bits(shape, l1_bit, 12, 0); set_bits(shape, l1_bit + 12, 12, 0); set_bits(shape, l1_bit + 24, 12, 0);
    memset(shape + crc_at, 0, 4);
    CC_SHA256(shape, (CC_LONG)size, hash);
    static const uint8_t supported_shape[32] = {
        0x87,0x26,0xde,0xf9,0xc1,0x64,0x58,0xa1,0x2a,0x82,0xff,0x36,0xf7,0x4b,0xb4,0xee,
        0xd9,0x8a,0xf5,0xa0,0xf5,0xd8,0x7a,0xfd,0xa2,0x0d,0xd5,0x44,0xf8,0xb5,0xa0,0x42};
    if (memcmp(hash, supported_shape, sizeof(hash))) return false;
    set_bits(raw, l1_bit, 12, minimum);
    set_bits(raw, l1_bit + 12, 12, maximum);
    set_bits(raw, l1_bit + 24, 12, average);
    uint32_t crc = crc32_mpeg2(raw + 1, crc_at - 1);
    for (int i = 0; i < 4; i++) raw[crc_at + i] = (uint8_t)(crc >> (24 - 8 * i));
    size_t written = 0; zeroes = 0;
    for (size_t i = 0; i < size; i++) {
        if (zeroes == 2 && raw[i] <= 3) {
            if (written == capacity) return false;
            output[written++] = 3; zeroes = 0;
        }
        if (written == capacity) return false;
        output[written++] = raw[i];
        zeroes = raw[i] == 0 ? zeroes + 1 : 0;
    }
    *output_length = written;
    return true;
}
