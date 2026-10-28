# native — C++ text module

Low-level text processing that plugs into a native library's C API: the `gitrochi` tokenizer for SQLite's FTS5 full-text search, used by the repository index (`crates/gitrochi-index`).

## Why C++ here

- **It is a SQLite extension.** FTS5 tokenizers are C callbacks over raw UTF-8 buffers (`fts5_tokenizer`); C++ writes them directly against `sqlite3.h`, with no binding layer.
- **One implementation, every consumer.** The same sources are compiled into the Rust index (and through it the macOS app's `libgitrochi_core.a`, the Windows Tauri backend and the `gitrochi-index` CLI), and, by `build.sh --extension`, into a loadable SQLite extension for any other SQLite host — the `sqlite3` shell or a Python build that allows extensions.
- **Byte-level work.** UTF-8 decoding, Unicode classification and byte offsets are tight loops over the caller's buffer.
- **No C++ runtime.** Built with `-fno-exceptions -fno-rtti` and without heap allocation (one fixed stack buffer per token), so the static library the Swift app links needs no `libc++`. `build.sh` checks that the objects reference only SQLite and C library symbols.

## What it does

`gitrochi_tokenize()` (declared in `include/gitrochi_text.h`) splits text into search tokens:

| Input | Document tokens | Query tokens |
| --- | --- | --- |
| `Fix Login Bug` | `fix` `login` `bug` | the same |
| `parseHTTPResponse` | `parsehttpresponse` +`parse` +`http` +`response` | `parsehttpresponse` |
| `user_name`, `sha256sum` | `user_name` +`user` +`name`; `sha256sum` +`sha` +`256` +`sum` | the whole word |
| `로그인오류` | `로그` +`로` `그인` +`그` `인오` +`인` `오류` +`오` `류` | `로그인` → `로그` `그인` |
| `テスト追加`, `修复错误` | overlapping pairs (+ single characters) | overlapping pairs |
| `ÀÉÎ Straße ΑΒΓ Привет`, `ＡＢＣ１２` | `àéî` `straße` `αβγ` `привет`, `abc12` | the same |

`+` marks a token at the same position as the one before (`FTS5_TOKEN_COLOCATED`): searching `response` finds `parseHTTPResponse` while phrase searches still line up. Korean, Japanese and Chinese have no spaces between words, so runs of those scripts become overlapping two-character tokens: the query `로그인` is the phrase `로그 그인`, which matches inside `로그인오류`. Documents also carry each character on its own, so one-character queries work. Lower-casing covers Latin (with Vietnamese), Greek, Cyrillic and Armenian, and full-width ASCII folds to ASCII. Invalid UTF-8 bytes, punctuation and emoji separate tokens; identifiers over 128 bytes are not indexed whole (their parts still are).

`gitrochi_fts5_register(db)` makes the tokenizer available as `tokenize = 'gitrochi'` on a connection. Changing the tokens changes the index, so bump `gitrochi_text_version()`; the Rust index re-tokenizes its tables when the stored version differs.

## Build and check

```sh
bash native/build.sh               # unit tests + runtime-free check
bash native/build.sh --extension   # also build/gitrochi.dylib (or .so), a loadable extension
```

`SQLITE_INCLUDE` points at a folder with `sqlite3.h` and `sqlite3ext.h` (default: the macOS SDK or `/usr/include`). Load the extension with `.load native/build/gitrochi` in a `sqlite3` shell that allows extensions (Apple's `/usr/bin/sqlite3` does not). The Rust build compiles the same files with the `cc` crate against its bundled SQLite (`crates/gitrochi-index/build.rs`), with MSVC on Windows.
