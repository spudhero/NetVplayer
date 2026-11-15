/* Original CC0 test-signal authoring only; not part of the player runtime. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    const double rate = strtod(argv[1], NULL), frequency = strtod(argv[3], NULL);
    const uint64_t count = strtoull(argv[2], NULL, 10);
    if (rate < 2822400 || rate > 5644800 || count == 0 || count > 140000000 || count % 8 ||
        frequency < 20 || frequency > 20000) return 2;
    double integrator1 = 0, integrator2 = 0, previous = 0;
    uint8_t bytes[4096] = {0};
    unsigned used = 0;
    for (uint64_t i = 0; i < count; ++i) {
        double input = .08 * sin(6.2831853071795864769 * frequency * (double)i / rate);
        integrator1 += input - previous;
        integrator2 += integrator1 - previous;
        previous = integrator2 >= 0 ? 1 : -1;
        if (previous > 0) bytes[used] |= (uint8_t)(1u << (i % 8));
        if (i % 8 == 7) {
            ++used;
            if (used == sizeof(bytes) || i + 1 == count) {
                if (fwrite(bytes, 1, used, stdout) != used) return 3;
                for (unsigned j = 0; j < used; ++j) bytes[j] = 0;
                used = 0;
            }
        }
    }
    return fflush(stdout) == 0 ? 0 : 3;
}
