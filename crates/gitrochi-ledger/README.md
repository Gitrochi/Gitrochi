# gitrochi-ledger

The session ledger. Agents report which baseline their work started from and where it stands — started, produced something, needs a person, synced to a newer baseline, finished, merged, released — and a person answers, confirms and cleans up conversations in Gitrochi. Information flows one way: agent → ledger → screen. What a person writes waits in the ledger until that session's next report or read picks it up.

| Consumer | How it reaches the ledger |
| --- | --- |
| macOS app | C ABI `gitrochi_ledger_call` / `gitrochi_ledger_free` ([`include/gitrochi_ledger.h`](include/gitrochi_ledger.h)); linking it into `libgitrochi_core.a` comes with the screens |
| Windows app | Rust crate dependency, one Tauri command `ledger_call` (with the screens) |
| Agents (Claude Code and other MCP clients) | `gitrochi-ledger mcp`: `ledger_overview`, `ledger_report`, `ledger_session` |
| Scripts, terminals, pasted reports | The `gitrochi-ledger` command line |
| Claude Code hooks of agents Gitrochi launches | `gitrochi-ledger hook <event>`: activity, and auto-continue where a person turned it on ([below](#hooks)) |

[CONTRACT.md](CONTRACT.md) is the API: storage, vocabulary, verdicts, hand-offs, types, methods, callers and errors. [`schema/`](schema/) has JSON Schemas for `State`, `Session`, `LedgerEvent`, `Question`, `Graph`, `PendingPrompt`, the session detail and the result of a claude-ledger import.

## The rules in short

- **Verdicts** are computed, never stored, first match wins: archived → needs a person (open questions) → finished (merged, closed, dropped): ready to archive once confirmed, else waiting for confirmation → shelved → done (merge undecided) → stale (no agent activity for 72 hours) → active.
- **Resuming.** New work on a finished, shelved or archived session makes it active again and withdraws the confirmation, so a conversation someone cleaned up but is still using cannot slip by.
- **A person confirms.** Confirming, archiving, setting a status and answering are for the apps only; the CLI and MCP refuse them. The one exception is the hand-off: an implementation session's `applied vX` confirms the decision session that released vX (`sync vX` moves it to merged without confirming).
- **Exactly once.** Answers, dismissals, notes and status changes reach the session's agent once, in the transaction that marks them delivered. Reading (the apps, `session` without `--deliver`) never consumes them.
- **Streams.** Live implementation sessions report in cycles (`sync vX` → work → `applied vX`) instead of finishing, so they are shown as cycles and kept out of overlaps and clean-up.
- **Baselines** come from git tags (the default, through the system `git`), folder or file names, registration, `release` reports, or are inferred from a report and promoted later.

## Where the database lives

One file per user: `~/Library/Application Support/Gitrochi/ledger/ledger.sqlite3` on macOS, `%APPDATA%\Gitrochi\ledger\ledger.sqlite3` on Windows, `$XDG_DATA_HOME/gitrochi/ledger/ledger.sqlite3` elsewhere. Only this crate writes it, from any process: WAL, `BEGIN IMMEDIATE`, a 15-second busy timeout (one second for hooks, which also never create the file), and `meta.rev` incremented by every write so the apps reload only when something changed. Backups go to `backups/` next to it.

| Variable | Effect |
| --- | --- |
| `GITROCHI_LEDGER_DB` | Another database file |
| `GITROCHI_LEDGER=0` | The ledger is off: every call but `info` answers `DISABLED`, nothing is created |
| `GITROCHI_LEDGER_SESSION` | The default session of the CLI and the MCP tools (for agents Gitrochi launches) |
| `GITROCHI_GIT` | The git to run for tag baselines (default: `git` on PATH) |

## Connecting an agent

```sh
claude mcp add --scope user gitrochi-ledger -- <path to gitrochi-ledger> mcp
```

Other MCP clients start the same command (`gitrochi-ledger mcp`, optionally with `--db FILE`). The server's instructions tell the agent when to report: an overview at the start, `start` once the work is clear (with `project`, `kind`, `title`, `base` and `touches`), then milestones only. Conversations that cannot call tools end their answer with a block a person pastes into the import:

````
```ledger
{"project": "Example App", "session": "web-chat-17", "event": "start", "kind": "research", "title": "Cache study", "base": "1.4.2", "summary": "Comparing two caches"}
```
````

## Command line

```
gitrochi-ledger [--db FILE] [--json] [--pretty] <command> [arguments]

  report [-p PROJECT] [-s SESSION] [-e EVENT] [-k KIND] [-t TITLE] [-b BASE] [-m SUMMARY]
         [--body TEXT | --body-file FILE] [--ask QUESTION]... [--question TEXT]
         [--touches A,B] [--related A,B] [-a NAME[@VERSION][#REVISION]]...
         [--version V] [--into V] [--absorbs A,B] [--targets A,B] [--resolves 1,2]
         [--chat-url URL] [--note TEXT] [--ssot V] [--work A,B]
  overview [-p PROJECT] [-s SESSION --deliver]
  session ID [--deliver]
  import FILE|- [-p PROJECT]
  import-legacy FILE [--dry-run]
  scan [-p PROJECT]
  register VERSION -p PROJECT [--note TEXT]
  backup [--daily] [--keep N] [--list]
  demo DB [--large] [--force]
  call METHOD [JSON]
  mcp
  hook EVENT < input.json
```

`report`, `overview` and `session` print short English text for agents; `--json` prints the data instead. `call` runs any method of the contract as an agent (a person's operations answer `NOT_ALLOWED`). Exit code 0 is success, 1 a failure, 2 a usage error or invalid input.

```sh
gitrochi-ledger report -p "Example App" -e start -k research -t "Cache study" -b 1.4.2 --touches src/cache
gitrochi-ledger report -s S1031-02 -e artifact -m "Benchmark table" -a "benchmark@1.4.2#r2"
gitrochi-ledger report -s S1031-02 -m "Checked" --body-file answer.md --ask "Keep the old cache?"
gitrochi-ledger report -s S1031-05 -e release --version 1.4.3 --absorbs S1031-02
gitrochi-ledger overview -p "Example App"
gitrochi-ledger session S1031-02 --deliver   # only the session itself
gitrochi-ledger demo /tmp/ledger-demo.sqlite3 --large
```

`import-legacy` copies a database of the standalone claude-ledger tool, which the ledger re-implements, without ever writing to that file: projects, baselines, sessions with their events and questions, and the hashes of pasted blocks it imported. Sessions the ledger already has are skipped and listed, so running it again changes nothing; `--dry-run` only counts (see [CONTRACT.md](CONTRACT.md#importing-a-claude-ledger-database)).

## Hooks

`gitrochi-ledger hook EVENT` is the handler for the Claude Code hooks the apps add to the sessions they launch while **Track agents I start** is on; Claude Code passes the hook input as JSON on stdin. It finds its ledger session through `GITROCHI_LEDGER_SESSION` (set at launch) and does nothing for any other agent.

| Event | What it does |
| --- | --- |
| `SessionStart` | `lastAt`, links the Claude session ID (a new one, after `/clear` say, is also kept in a `hook` event with the previous one); with auto-continue on, context that asks the agent to ask with `AskUserQuestion`, recommendation first |
| `UserPromptSubmit` | `lastAt`, the link; the person's prompt answers a waiting stop question, ends what is left of the previous turn and starts the count of automatic answers again (the `<task-notification>` prompt of an automatic answer's wake-up is not the person's) |
| `Stop` | `lastAt`; with auto-continue on, a turn that ended with a question waits, then the answer goes out as exit 2 with the text on stderr (the entry is `async` with `asyncRewake`) |
| `PreToolUse` (`AskUserQuestion`, `ExitPlanMode`) | With auto-continue on: waits, then `allow` with `updatedInput` carrying the questions and the answers, or the plan approval |
| `PermissionRequest` | With auto-continue on: waits, then allows this one request; never-auto-allowed requests get no decision. The terminal shows its own dialog meanwhile, so the answer counts as automatic only once the call is seen to start after it |
| `PostToolUse`, `PostToolUseFailure` | A call ran: settles a permission prompt for it (the person allowed it in the terminal, or the automatic allow applied), and one of the same agent that it moved past; one read when nothing waits |
| `SessionEnd` | `lastAt` and a `hook` event with the reason; nothing it waited on stays open |

A wait is a pending prompt that the apps show with a countdown and can answer (`prompt_answer`); the handler checks it every 250 ms until its deadline. It never stores prompt text or tool input for activity, never changes a status and never touches a person's operations. Bad input, a missing database and a locked file all end with exit 0, no decision and one line on stderr; the only other exit code is the Stop hook's 2. The rules are in [CONTRACT.md](CONTRACT.md#hooks) and DESIGN.md §9.

`demo` writes neutral demo data into a new file: two projects, a session in every verdict, a stream with three cycles, questions, a waiting prompt, an automatic answer to review and an overlap; `--large` adds a project with 1,000 sessions and 50,000 events.

## Layout

| File | What it does |
| --- | --- |
| `db.rs`, `schema.sql` | Path, opening, migrations, the one write path |
| `report.rs`, `human.rs` | Agent reports, hand-offs; a person's operations |
| `session.rs`, `views.rs`, `streams.rs`, `overlap.rs` | Verdicts, state, session detail, overview, cycles, overlaps |
| `baseline.rs`, `git.rs` | The trunk: tags, folders, registration, releases, inferred versions |
| `graph.rs`, `search.rs` | The graph layout; search |
| `import.rs`, `sha1.rs` | Pasted blocks and their duplicate hash (the original tool's canonical JSON) |
| `legacy.rs` | The read-only import of a claude-ledger database |
| `backup.rs`, `prompts.rs`, `settings.rs` | Backups, pending prompts for auto-continue, global settings |
| `api.rs`, `ffi.rs`, `mcp.rs`, `main.rs` | The dispatcher and its callers, the C ABI, the MCP server, the CLI |
| `hook.rs` | The Claude Code hook handler: activity and auto-continue's waits |
| `text.rs`, `demo.rs`, `vocab.rs` | Text for agents, demo data, the vocabulary and input aliases |

## Checks

```sh
cargo test --locked --manifest-path crates/Cargo.toml -p gitrochi-ledger
cargo clippy --locked --manifest-path crates/Cargo.toml --all-targets -- -D warnings
cargo test --release --manifest-path crates/Cargo.toml -p gitrochi-ledger --test scale -- --nocapture   # timings
cargo test --release --manifest-path crates/Cargo.toml -p gitrochi-ledger --test hooks -- --nocapture   # hook timings
```

The tests port the original tool's scenarios as Rust tests on temporary databases: every verdict and its order, resuming, release and absorbs, the sync and applied hand-offs, inferred baselines and their promotion, titles, imports and duplicates, the claude-ledger import from a generated file, exactly-once delivery, shelving, staleness and snoozing, streams and lines, git tag and folder scans, migrations, backups while writing, threads and real processes writing at once, many threads and processes opening a brand-new file at the same moment (`LEDGER_STRESS_ROUNDS` repeats it), the C ABI (and the header with a C and a C++ compiler), the CLI, an MCP conversation and the hook handler (every auto-continue path, with fake hook input) as real processes, the schemas against the demo, graph determinism, and timings on the large demo. On this development Mac (Apple Silicon, release build, median of five, 1,011 sessions and 50,036 events): `state` 10 ms, `graph` 32 ms for 7 days and 84 ms for everything (50,000 nodes), `session` 5 ms, `search` 12 ms, `rev` under 0.1 ms. Hooks (release build, 40 runs): an activity hook takes under 0.4 ms at the 95th percentile inside the handler and about 2.5 ms as a whole process; with auto-continue off a `PermissionRequest` ends in about 0.2 ms (2 ms as a process).
