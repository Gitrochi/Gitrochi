// FTS5 binding for the tokenizer. Compiled against sqlite3.h inside the Rust index
// (its bundled SQLite), or against sqlite3ext.h for the loadable extension, where every
// sqlite3_* call goes through the host's API table instead.

#include "gitrochi_text.h"

#if defined(GITROCHI_SQLITE_EXTENSION)
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3
#else
#include <sqlite3.h>
#endif

namespace {

// The tokenizer keeps no state, but FTS5 wants a distinct object per table.
struct Tokenizer {
    int unused;
};

int create(void *, const char **, int arguments, Fts5Tokenizer **out) {
    *out = nullptr;
    if (arguments != 0) return SQLITE_ERROR;  // no options: a typo should not pass silently
    void *memory = sqlite3_malloc(int(sizeof(Tokenizer)));
    if (memory == nullptr) return SQLITE_NOMEM;
    *out = static_cast<Fts5Tokenizer *>(memory);
    return SQLITE_OK;
}

void destroy(Fts5Tokenizer *tokenizer) { sqlite3_free(tokenizer); }

int tokenize(Fts5Tokenizer *, void *context, int flags, const char *text, int length,
             int (*token)(void *, int, const char *, int, int, int)) {
    // Highlighting (FTS5_TOKENIZE_AUX) must see exactly the document's tokens.
    const int mode = (flags & FTS5_TOKENIZE_QUERY) ? GITROCHI_TOKENIZE_QUERY : GITROCHI_TOKENIZE_DOCUMENT;
    return gitrochi_tokenize(text, length, mode, context, token);
}

}  // namespace

extern "C" int gitrochi_fts5_register(sqlite3 *db) {
    fts5_api *api = nullptr;
    sqlite3_stmt *statement = nullptr;
    int rc = sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &statement, nullptr);
    if (rc != SQLITE_OK) return rc;
    sqlite3_bind_pointer(statement, 1, static_cast<void *>(&api), "fts5_api_ptr", nullptr);
    sqlite3_step(statement);
    rc = sqlite3_finalize(statement);
    if (rc != SQLITE_OK) return rc;
    if (api == nullptr || api->iVersion < 2) return SQLITE_ERROR;
    fts5_tokenizer methods = {create, destroy, tokenize};
    return api->xCreateTokenizer(api, "gitrochi", nullptr, &methods, nullptr);
}
