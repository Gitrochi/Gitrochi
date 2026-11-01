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

/* Repository index (crates/gitrochi-index): {"repo", "command", "args"} in, {"result"} or
   {"error"} out, in the same length-prefixed format. Release with gitrochi_index_free. */
uint8_t * _Nonnull gitrochi_index_call(const uint8_t * _Nonnull input, size_t length);
void gitrochi_index_free(uint8_t * _Nonnull buffer, size_t length);

/* Session ledger (crates/gitrochi-ledger, include/gitrochi_ledger.h): a method and a JSON object
   (NULL means {}) in, a NUL-terminated JSON string or {"error": {"code", "message"}} out. Callable
   from several threads; may block on the database. Release each result once with gitrochi_ledger_free. */
char * _Nonnull gitrochi_ledger_call(const char * _Nonnull method, const char * _Nullable json);
void gitrochi_ledger_free(char * _Nullable result);

#ifdef __cplusplus
}
#endif

#endif
