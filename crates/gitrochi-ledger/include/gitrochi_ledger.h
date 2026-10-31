#ifndef GITROCHI_LEDGER_H
#define GITROCHI_LEDGER_H

/* The session ledger (crates/gitrochi-ledger). Methods, arguments and results are
   described in crates/gitrochi-ledger/CONTRACT.md. */

#ifdef __cplusplus
extern "C" {
#endif

/* Runs `method` with `json`, a JSON object (NULL means {}), and returns the result as a
   NUL-terminated UTF-8 JSON string, or {"error": {"code", "message"}}. Never NULL.
   Callable from several threads. Release the result with gitrochi_ledger_free. */
char *gitrochi_ledger_call(const char *method, const char *json);

/* Releases a result of gitrochi_ledger_call, once. NULL is ignored. */
void gitrochi_ledger_free(char *result);

#ifdef __cplusplus
}
#endif

#endif
