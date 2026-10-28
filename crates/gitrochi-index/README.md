# gitrochi-index

The repository index: a SQLite database of a repository's commits, the files each commit changed, how often files change together, and cached results of searches that need git. Rust writes it; the apps, gitch, the Python tools and the Go services read it.

| Consumer | How it reaches the index |
| --- | --- |
| macOS app | C ABI in `libgitrochi_core.a` (`gitrochi_index_call`, declared in `crates/gitrochi-core/include/gitrochi_core.h`) |
| Windows app | Rust crate dependency of `windows/src-tauri` (Tauri commands `index_call`) |
| Python tools, Go services, scripts | `gitrochi-index` executable: one JSON document per command, or `serve` for many requests over stdio |
| Read-only analysis | The SQLite file itself (`schema.sql`), opened read-only |

Git stays the system `git`: the index runs `git for-each-ref`, `git log`, `git grep` and parses their machine-readable output. Nothing is written to the repository's objects or refs. The indexed refs are the ones the apps' search covers (`--all --exclude=refs/stash`) minus `refs/notes/`, `refs/original/` and `refs/replace/`, whose commits would distort the history.

## Where the database lives

`<git common dir>/gitrochi/index.sqlite3`, so every worktree of a repository shares one index (they share commits). `--db FILE` or `GITROCHI_INDEX_DB` overrides it. The database uses WAL mode: readers never block the writer, and several processes may sync at once (each insert is idempotent).

Both apps sync after every full reload and watch the git dir, so the apps' watchers skip `gitrochi/`, and a sync that finds nothing new writes nothing. `GITROCHI_INDEX=0` turns the index off in both apps (the search bar then uses git, as before). Keep the repository on a local disk: SQLite's WAL mode needs shared memory, so the Windows app leaves `\\wsl$` and network paths to git.

## Tables (schema 1)

`schema.sql` is the reference. In short:

- `commits` — one row per commit (author fields follow `.mailmap`; times are Unix seconds).
- `commit_parents` — parent SHAs in order.
- `paths` — every path that ever changed, interned; `file_changes` — what each non-merge commit changed (status letter, rename source, line counts, NULL for binary files).
- `path_stats` — per-path totals; `cochange` — pairs of paths changed in the same commit (`a < b`), the change relationships. Commits touching more than `max_files` paths (default 30) are left out.
- `refs` — tips whose full ancestry is indexed; `meta` — `schema`, `created`, `last_sync`, `max_files`, `shallow`.
- `search_cache` — results of `git log -S`/`-G` and `git grep`, keyed by query and options, bounded (least recently used entries go first).
- `commit_text`, `path_text` (`fts.sql`) — FTS5 tables using the C++ `gitrochi` tokenizer. Other SQLite readers cannot open these without the tokenizer; use `gitrochi-index search` or load the extension built from `native/`.

Readers check `PRAGMA user_version` (1) and open with `?mode=ro`.

## Command line

```
gitrochi-index [--repo DIR] [--db FILE] [--pretty] <command> [arguments]
```

Options may come anywhere; after `--` every word is an argument (for paths that start with `-`). Every command prints one JSON object on stdout. Exit code 0 is success; 1 is a failure and prints `{"error": {"code": "…", "message": "…"}}`; 2 is a usage error. Paths are repository-relative with `/`. Times are Unix seconds. Field names are camelCase.

Shared shapes:

- **Commit** `{"sha", "parents": [], "authorName", "authorEmail", "authorTime", "committerName", "committerEmail", "commitTime", "subject", "body", "filesChanged", "additions", "deletions"}`
- **FileChange** `{"path", "oldPath": null | "…", "status": "A|M|D|R|C|T", "similarity": null | 0–100, "additions": null | n, "deletions": null | n}`
- **Author** `{"name", "email", "commits", "additions", "deletions", "lastTime"}`
- **Partner** `{"path", "commits", "confidence", "jaccard", "lastTime"}` — `confidence` = shared commits / commits of the asked path; `jaccard` = shared / (either path's commits − shared + shared).

| Command | Output |
| --- | --- |
| `version` | `{"tool": "gitrochi-index", "version", "schemaVersion": 1, "sqliteVersion", "tokenizer": "gitrochi"}` |
| `path` | `{"repository", "gitCommonDir", "database", "exists"}` |
| `sync [--max-files N] [--no-renames] [--limit N]` | `{"repository", "database", "upToDate", "newCommits", "totalCommits", "refs", "durationMs", "shallow"}` — incremental: only commits past the indexed tips are read. `--limit` indexes at most N new commits and marks the index shallow. |
| `status` | `{"repository", "database", "schemaVersion", "commits", "paths", "fileChanges", "cochangePairs", "refs", "lastSync", "newestCommitTime", "oldestCommitTime", "shallow", "sizeBytes", "stale"}` — `stale` is true when the repository's refs differ from the indexed ones. |
| `match QUERY [--scope commits\|files] [--limit 20000]` | `{"scope", "shas": [], "truncated", "stale"}` — the apps' search bar semantics: commits whose message has a line containing the query with whitespace and case ignored (as `git log -i --grep`), or that touched a path containing it (as `':(glob,icase)**/*QUERY*'`), newest first. `stale` tells the caller to ask git instead. |
| `search QUERY [--scope commits\|paths] [--limit 50] [--offset 0] [--sort rank\|time]` | commits: `{"query", "scope", "results": [Commit + {"rank", "highlight"}]}`; paths: `{"query", "scope", "results": [{"path", "commits", "lastTime", "highlight"}]}`. `highlight` wraps matches in U+0002 … U+0003. |
| `log [--path P] [--follow] [--author TEXT] [--since T] [--until T] [--limit 100] [--offset 0]` | `{"commits": [Commit]}` — `--follow` continues through renames. |
| `show SHA` | `{"commit": Commit, "files": [FileChange]}` |
| `file PATH [--limit 20]` | `{"path", "stats": null \| {"commits", "additions", "deletions", "firstTime", "lastTime"}, "authors": [Author], "coupled": [Partner], "history": [Commit]}` |
| `coupled PATH [--limit 20] [--min-commits 2]` | `{"path", "commits", "partners": [Partner]}` |
| `hotspots [--since T] [--prefix P] [--limit 50]` | `{"since", "prefix", "files": [{"path", "commits", "additions", "deletions", "churn", "authors", "lastTime", "score"}]}` |
| `owners [PREFIX] [--since T] [--limit 20]` | `{"prefix", "commits", "authors": [Author + {"share"}], "busFactor"}` — `busFactor` is the fewest authors who together made at least half of the commits. |
| `impact PATH… [--limit 20] [--min-confidence 0.3] [--min-commits 2]` | `{"changed": [], "suggestions": [{"path", "score", "because": [{"path", "commits", "confidence"}]}]}` — files that usually change with the given ones but are not among them. |
| `cache grep PATTERN [--ignore-case] [--fixed] [--limit 500]` | `{"kind": "grep", "cached", "scope", "matches": [{"path", "line", "text"}], "truncated"}` — `git grep` on the `HEAD` tree, cached per tree. |
| `cache pickaxe TEXT [--regex] [--limit 500]` | `{"kind": "pickaxe", "cached", "scope", "commits": [{"sha", "subject", "commitTime"}], "truncated"}` — `git log -S` (or `-G` with `--regex`); after new commits only the new part of history is searched. |
| `cache stats` / `cache clear` | `{"entries", "bytes", "hits"}` / `{"removed"}` |
| `tokenize TEXT [--query]` | `{"tokens": [{"text", "start", "end", "colocated"}]}` — the C++ tokenizer's output (byte offsets). |
| `prune` | `{"removedCommits"}` — drops commits no ref reaches any more and rebuilds `path_stats` and `cochange`. |
| `serve` | JSON lines on stdin/stdout, handled in order until EOF. |

### Search queries

Words must all match; `"quoted words"` match as a phrase; a trailing `*` matches a prefix. Filters: `author:TEXT`, `path:PREFIX`, `since:YYYY-MM-DD`, `until:YYYY-MM-DD`, `merge:yes|no`, and `sha:PREFIX` (a bare word of 7 or more hex digits is treated as a SHA prefix too). The tokenizer splits code identifiers (`parseHTTPResponse` also matches `response`) and indexes Korean, Japanese and Chinese text as overlapping two-character pieces, so `로그인` finds `로그인오류`.

### serve

One request per line, one response per line:

```json
{"id": 1, "command": "search", "args": {"query": "login", "limit": 10}}
{"id": 1, "result": {"query": "login", "scope": "commits", "results": []}}
{"id": 2, "error": {"code": "INVALID_ARGUMENT", "message": "…"}}
```

`args` use the option names in camelCase (`maxFiles`, `minConfidence`, `ignoreCase`); positional arguments are `query`, `path`, `paths`, `pattern`, `text`, `sha` and `prefix`, and `cache` takes its action as `{"action": "grep", "pattern": "…"}`. `args.repo` selects another repository for that request and `args.git` another git executable (default: `GITROCHI_GIT`, then `git` on PATH).

Error codes: `NOT_A_REPOSITORY`, `NOT_INDEXED` (no database yet: run `sync`), `GIT_FAILED`, `DATABASE`, `SCHEMA_MISMATCH`, `INVALID_ARGUMENT`, `NOT_FOUND`, and `DISABLED` from the Windows app's backend when `GITROCHI_INDEX=0`.

## C ABI

`gitrochi_index_call(input, length)` takes `{"repo": "/abs/path", "git": "…" (optional), "command": "search", "args": {…}}` and returns a buffer in the shared core's format (8-byte little-endian length, then `{"result": …}` or `{"error": …}`), released with `gitrochi_index_free`. Connections are cached per database (one writer, one reader); calls from several threads are safe, and a search does not wait for a running sync. The Windows backend calls the same dispatcher (`gitrochi_index::call`) from its `index_call` command.

## Checks

```sh
cargo test --locked --manifest-path crates/Cargo.toml -p gitrochi-index
cargo clippy --locked --manifest-path crates/Cargo.toml --all-targets -- -D warnings
bash native/build.sh                         # the C++ tokenizer on its own
bash macos/Tools/test-repository-index.sh    # Swift → C ABI → Rust → SQLite
cd windows && npx vitest run tests/repo-index.test.ts
```

The integration tests build throwaway repositories (with a private HOME and git config) and cover incremental and limited syncs, renames, rewritten history and `prune`, concurrent syncs from threads and processes, the search cache, the C ABI, `serve`, schema and tokenizer changes, and that a sync with nothing new writes nothing.
