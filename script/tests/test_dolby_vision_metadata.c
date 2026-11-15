#include "NVDolbyVisionMetadata.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    assert(argc == 3);
    FILE *file = fopen(argv[1], "rb"); assert(file);
    uint8_t input[1024], output[1024];
    size_t length = fread(input, 1, sizeof(input), file); fclose(file);
    size_t count = 0;
    assert(nv_dovi_system_rpu_set_l1(input, length, 0, 3079, 1500, output, sizeof(output), &count));
    file = fopen(argv[2], "wb"); assert(file);
    fwrite("\0\0\0\1", 1, 4, file); fwrite(output, 1, count, file); fclose(file);
    // Every single-byte corruption must be rejected, including reserved bits,
    // mapping coefficients, metadata padding, emulation prevention and CRC.
    for (size_t i = 0; i < length; i++) {
        input[i] ^= 1;
        assert(!nv_dovi_system_rpu_set_l1(input, length, 0, 3079, 1500, output, sizeof(output), &count));
        assert(count == 0);
        input[i] ^= 1;
    }
    for (size_t i = 0; i < length; i++) {
        assert(!nv_dovi_system_rpu_set_l1(input, i, 0, 3079, 1500, output, sizeof(output), &count));
    }
    for (size_t capacity = 0; capacity < 344; capacity++) {
        assert(!nv_dovi_system_rpu_set_l1(input, length, 0, 3079, 1500, output, capacity, &count));
        assert(count == 0);
    }
    assert(!nv_dovi_system_rpu_set_l1(input, length, 13, 3079, 1500, output, sizeof(output), &count));
    assert(!nv_dovi_system_rpu_set_l1(input, length, 0, 2080, 1500, output, sizeof(output), &count));
    assert(!nv_dovi_system_rpu_set_l1(input, length, 0, 3079, 3079, output, sizeof(output), &count));
    assert(!nv_dovi_system_rpu_set_l1(input, length, 0, 3080, 1500, output, sizeof(output), &count));
    assert(!nv_dovi_system_rpu_set_l1(input, length, 0, 3079, 818, output, sizeof(output), &count));
    assert(!nv_dovi_system_rpu_set_l1(NULL, length, 0, 3079, 1500, output, sizeof(output), &count));
    puts("PASS: RPU shape/CRC, bit packing, 350 corruptions, truncation, output bounds, invalid metadata");
    return 0;
}
