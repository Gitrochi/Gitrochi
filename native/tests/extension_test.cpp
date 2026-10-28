// Loads the built extension into a plain SQLite (no tokenizer compiled in) and searches
// through it, as the sqlite3 shell or Python would. native/build.sh --extension runs it
// when the SQLite amalgamation is available.

#include <sqlite3.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int failures = 0;

std::string first_match(sqlite3 *db, const char *query) {
    sqlite3_stmt *statement = nullptr;
    std::string found;
    if (sqlite3_prepare_v2(db, "SELECT x FROM t WHERE t MATCH ?1 ORDER BY rowid", -1, &statement, nullptr) != SQLITE_OK) {
        std::printf("FAIL prepare: %s\n", sqlite3_errmsg(db));
        ++failures;
        return found;
    }
    sqlite3_bind_text(statement, 1, query, -1, SQLITE_STATIC);
    if (sqlite3_step(statement) == SQLITE_ROW) {
        found = reinterpret_cast<const char *>(sqlite3_column_text(statement, 0));
    }
    sqlite3_finalize(statement);
    return found;
}

void expect(const char *query, const char *expected, sqlite3 *db) {
    const std::string actual = first_match(db, query);
    if (actual != expected) {
        std::printf("FAIL %s: expected \"%s\", got \"%s\"\n", query, expected, actual.c_str());
        ++failures;
    } else {
        std::printf("ok   %s → %s\n", query, expected);
    }
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 2) {
        std::printf("usage: extension_test <path to the extension>\n");
        return 2;
    }
    sqlite3 *db = nullptr;
    sqlite3_open(":memory:", &db);
    char *error = nullptr;
    // Before loading: the tokenizer must not exist, or this test would prove nothing.
    if (sqlite3_exec(db, "CREATE VIRTUAL TABLE early USING fts5(x, tokenize = gitrochi)", nullptr, nullptr, &error) == SQLITE_OK) {
        std::printf("FAIL the tokenizer existed before loading the extension\n");
        return 1;
    }
    sqlite3_free(error);
    sqlite3_enable_load_extension(db, 1);
    if (sqlite3_load_extension(db, argv[1], nullptr, &error) != SQLITE_OK) {
        std::printf("FAIL load: %s\n", error ? error : "unknown error");
        return 1;
    }
    const char *setup =
        "CREATE VIRTUAL TABLE t USING fts5(x, tokenize = gitrochi);"
        "INSERT INTO t VALUES ('unrelated'), ('로그인오류 수정'), ('parseHTTPResponse added');";
    if (sqlite3_exec(db, setup, nullptr, nullptr, &error) != SQLITE_OK) {
        std::printf("FAIL setup: %s\n", error);
        return 1;
    }
    expect("로그인", "로그인오류 수정", db);
    expect("response", "parseHTTPResponse added", db);
    expect("\"parse\"*", "parseHTTPResponse added", db);
    expect("류", "로그인오류 수정", db);
    sqlite3_close(db);
    if (failures != 0) return 1;
    std::printf("the loadable extension works in a plain SQLite\n");
    return 0;
}
