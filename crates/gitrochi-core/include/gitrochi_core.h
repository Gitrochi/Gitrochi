#ifndef GITROCHI_CORE_H
#define GITROCHI_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint8_t * _Nonnull gitrochi_alloc(size_t length);
uint8_t * _Nonnull gitrochi_compute(const uint8_t * _Nonnull input, size_t length);
uint8_t * _Nonnull gitrochi_graph(const uint8_t * _Nonnull input, size_t length);
void gitrochi_free(uint8_t * _Nonnull buffer, size_t length);

#ifdef __cplusplus
}
#endif

#endif
