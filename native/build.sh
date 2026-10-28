#!/usr/bin/env bash
set -euo pipefail

# Builds and checks the C++ text module. The Rust index compiles the same sources
# itself (crates/gitrochi-index/build.rs); this script is for the module on its own.
#   native/build.sh              → unit tests + runtime-free check
#   native/build.sh --extension  → also build/gitrochi.{dylib,so}, a SQLite loadable extension
# SQLITE_INCLUDE points at a folder with sqlite3.h and sqlite3ext.h (default: the system's).

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${GITROCHI_NATIVE_OUT:-$ROOT/build}"
CXX="${CXX:-c++}"
FLAGS=(-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -fno-exceptions -fno-rtti -I "$ROOT/include")
mkdir -p "$OUT"

sqlite_include() {
    if [[ -n "${SQLITE_INCLUDE:-}" ]]; then printf '%s\n' "$SQLITE_INCLUDE"; return; fi
    if [[ "$(uname -s)" == Darwin ]]; then printf '%s/usr/include\n' "$(xcrun --show-sdk-path)"; return; fi
    printf '/usr/include\n'
}
SQLITE_DIR="$(sqlite_include)"
[[ -f "$SQLITE_DIR/sqlite3.h" ]] || { echo "sqlite3.h not found in $SQLITE_DIR (set SQLITE_INCLUDE)" >&2; exit 1; }

echo "▶ tokenizer tests"
"$CXX" "${FLAGS[@]}" -fexceptions "$ROOT/src/tokenizer.cpp" "$ROOT/tests/tokenizer_test.cpp" -o "$OUT/tokenizer_test"
"$OUT/tokenizer_test"

# The apps link these objects into Swift and Rust binaries without a C++ runtime, so
# they must not reference one (operator new, exceptions, RTTI, static destructors).
echo "▶ runtime-free check"
"$CXX" "${FLAGS[@]}" -c "$ROOT/src/tokenizer.cpp" -o "$OUT/tokenizer.o"
"$CXX" "${FLAGS[@]}" -I "$SQLITE_DIR" -c "$ROOT/src/fts5.cpp" -o "$OUT/fts5.o"
# Mach-O puts an underscore before every C symbol; ELF does not.
strip='s/^//'
[[ "$(uname -s)" != Darwin ]] || strip='s/^_//'
undefined="$(nm -u "$OUT/tokenizer.o" "$OUT/fts5.o" | awk 'NF { print $NF }' | grep -v ':$' | sed "$strip" | sort -u)"
# Allowed: SQLite, our own symbols across the two objects, the C library (memory
# helpers, stack protector) and the linker's own GOT symbol on position-independent Linux builds.
unexpected="$(printf '%s\n' "$undefined" | grep -v -E '^(sqlite3_[a-z0-9_]+|gitrochi_[a-z0-9_]+|memcpy|memset|memmove|strlen|__stack_chk_(fail|guard)|_GLOBAL_OFFSET_TABLE_)$' || true)"
if [[ -n "$unexpected" ]]; then
    echo "❌ unexpected runtime symbols:" >&2
    printf '  %s\n' $unexpected >&2
    exit 1
fi
echo "ok   only SQLite and C library symbols are referenced"

if [[ "${1:-}" == --extension ]]; then
    case "$(uname -s)" in
        Darwin) ext=dylib; shared=(-dynamiclib -undefined dynamic_lookup) ;;
        *) ext=so; shared=(-shared -fPIC) ;;
    esac
    echo "▶ loadable extension"
    "$CXX" "${FLAGS[@]}" -fPIC -DGITROCHI_SQLITE_EXTENSION -I "$SQLITE_DIR" "${shared[@]}" \
        "$ROOT/src/tokenizer.cpp" "$ROOT/src/fts5.cpp" "$ROOT/src/extension.cpp" -o "$OUT/gitrochi.$ext"
    echo "✅ $OUT/gitrochi.$ext (load it with: .load $OUT/gitrochi)"
    # With the amalgamation at hand (the Rust build's bundled copy has it), load the extension
    # into a plain SQLite that has no tokenizer of its own and search through it.
    if [[ -f "$SQLITE_DIR/sqlite3.c" ]]; then
        echo "▶ extension loaded into a plain SQLite"
        "${CC:-cc}" -O1 -w -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=0 -c "$SQLITE_DIR/sqlite3.c" -o "$OUT/sqlite3.o"
        libs=()
        [[ "$(uname -s)" == Darwin ]] || libs=(-ldl -lm -lpthread)
        "$CXX" -std=c++17 -O1 -I "$SQLITE_DIR" "$ROOT/tests/extension_test.cpp" "$OUT/sqlite3.o" ${libs[@]+"${libs[@]}"} \
            -o "$OUT/extension_test"
        "$OUT/extension_test" "$OUT/gitrochi.$ext"
    fi
fi
