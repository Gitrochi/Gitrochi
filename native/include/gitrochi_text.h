#ifndef GITROCHI_TEXT_H
#define GITROCHI_TEXT_H

/*
 * Gitrochi text tokenizer: the C ABI of native/ (C++17).
 *
 * One implementation serves every consumer: the Rust repository index links it
 * statically (and through it both apps), and native/build.sh also builds it as a
 * SQLite loadable extension for the sqlite3 shell or Python.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors FTS5_TOKEN_COLOCATED: the token shares the previous token's position. */
#define GITROCHI_TOKEN_COLOCATED 0x0001

/* Documents also get identifier parts and single CJK characters; queries do not. */
#define GITROCHI_TOKENIZE_DOCUMENT 0
#define GITROCHI_TOKENIZE_QUERY 1

/*
 * Receives each token: folded UTF-8 bytes (not NUL-terminated) and the byte range
 * [start, end) it came from. A non-zero return stops tokenizing and is returned.
 * The signature matches the xToken callback of SQLite's FTS5 tokenizer API.
 */
typedef int (*gitrochi_token_fn)(void *context, int flags, const char *token, int length, int start, int end);

/* Splits UTF-8 text into search tokens. Invalid UTF-8 bytes act as separators. */
int gitrochi_tokenize(const char *text, int length, int mode, void *context, gitrochi_token_fn emit);

struct sqlite3;

/* Registers the FTS5 tokenizer `gitrochi` on a connection; returns a SQLite result code. */
int gitrochi_fts5_register(struct sqlite3 *db);

/* Tokenizer version; bump it when tokens change, since indexes must then be rebuilt. */
const char *gitrochi_text_version(void);

#ifdef __cplusplus
}
#endif

#endif
