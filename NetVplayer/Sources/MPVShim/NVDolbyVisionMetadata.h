#ifndef NV_DOLBY_VISION_METADATA_H
#define NV_DOLBY_VISION_METADATA_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
// Adapter for one independently validated Apple-generated HLG/P8.4 RPU shape.
// Unknown layouts, corrupt CRC, invalid statistics or insufficient space fail.
bool nv_dovi_system_rpu_set_l1(const uint8_t *input, size_t length,
    uint16_t minimum, uint16_t maximum, uint16_t average,
    uint8_t *output, size_t capacity, size_t *output_length);
#endif
