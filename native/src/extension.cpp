// Entry point of the loadable extension (native/build.sh --extension). SQLite derives
// the symbol from the file name: gitrochi.dylib, gitrochi.so or gitrochi.dll.

#include "gitrochi_text.h"

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

#if defined(_WIN32)
#define GITROCHI_EXPORT __declspec(dllexport)
#else
#define GITROCHI_EXPORT __attribute__((visibility("default")))
#endif

extern "C" GITROCHI_EXPORT int sqlite3_gitrochi_init(sqlite3 *db, char **, const sqlite3_api_routines *api) {
    SQLITE_EXTENSION_INIT2(api);
    return gitrochi_fts5_register(db);
}
