# gitrochi-hub

Gitrochi's team service, written in Go: one static binary with no dependencies outside the standard library.

- **`gitrochi-hub serve`** is the collaboration server. Members report what they are working on, the hub tells them where that work overlaps, carries repository events to everyone over a live stream, and keeps team notes on commits and lines.
- **`gitrochi-hub monitor`** is the daemon on a developer's machine. It watches repositories with `git`, keeps the Rust repository index in sync, and publishes presence and events to the hub.

Rust stays the core and the index. Go talks to the index only through its command line, `gitrochi-index` (contract: [crates/gitrochi-index/README.md](../../crates/gitrochi-index/README.md)), and the index is optional.

```sh
services/hub/build.sh                              # dist/gitrochi-hub for this machine
dist/gitrochi-hub init --data ./hub-data           # prints the first admin token, once
dist/gitrochi-hub serve --data ./hub-data          # listens on 127.0.0.1:7420
dist/gitrochi-hub monitor --config monitor.json    # status on 127.0.0.1:7421
```

## Architecture

```
developer machine                                       team server
+-----------------------------------+                  +-------------------------------+
| gitrochi-hub monitor              |  presence,       | gitrochi-hub serve            |
|   one worker per repository       |  events (HTTPS,  |   HTTP API, SSE broker        |
|   process pool: git + index (4)   |  bearer token)   |   state in memory             |
|   git status / for-each-ref / ... | ---------------> |   journal.jsonl + snapshot    |
|   gitrochi-index sync / impact    | <--------------- |   hub.lock                    |
|   127.0.0.1:7421 /status          |  overlaps        +-------------------------------+
+-----------------------------------+                    ^ GET /api/v1/stream (SSE)
                                                         | the apps, other tools
```

| Package | Role |
| --- | --- |
| `cmd/gitrochi-hub` | `main`: sets the version, runs `internal/cli` |
| `internal/cli` | subcommands and flags |
| `internal/hub` | HTTP server: routes, auth, rate limit, validation, SSE, metrics, graceful shutdown |
| `internal/store` | tokens, events and notes in memory; group commit through the journal |
| `internal/journal` | append-only JSON lines plus snapshots; crash-safe replay |
| `internal/lockfile` | one process per data directory (`flock`; an unshared handle on Windows) |
| `internal/presence` | presence with expiry, and overlap computation |
| `internal/stream` | event fan-out with bounded per-subscriber buffers |
| `internal/auth`, `ratelimit`, `metrics`, `backoff`, `repokey` | tokens, token buckets, Prometheus text, retry delays, repository keys |
| `internal/api` | the JSON shapes, shared by server and client |
| `internal/client` | hub client used by the monitor and the CLI |
| `internal/monitor` | the daemon: configuration, workers, state file, local endpoints |
| `internal/gitexec` | bounded process runner: timeouts, process-tree kills |
| `internal/gitinfo` | git commands and parsers (`--porcelain=v2 -z`, `for-each-ref`) |
| `internal/index` | `gitrochi-index` wrapper |

## The hub

### Data directory and crash safety

`--data DIR` (or `GITROCHI_HUB_DATA`) holds three files, all mode 0600 in a 0700 directory:

| File | Contents |
| --- | --- |
| `hub.lock` | held by the process using the directory; the operating system releases it on exit |
| `snapshot.json` | `{"format":1,"seq":N,"written":…,"state":{…}}`: everything up to change `N` |
| `journal.jsonl` | one change per line after the snapshot: `{"seq":N,"op":"event","data":{…}}` |

State lives in memory. Every change goes through one writer goroutine: callers queue a record, the writer appends everything queued as one batch, **fsyncs once per batch**, applies the batch in sequence order, publishes its events, and only then answers the callers. A `201` therefore means the change is on disk, and stream subscribers see events in ID order.

Every 1000 changes (`--snapshot-every`), every 5 minutes while changes arrive (`--snapshot-interval`) and on shutdown, the writer writes `snapshot.json.tmp`, fsyncs it, renames it over `snapshot.json`, fsyncs the directory, and then truncates the journal. On start, records at or below the snapshot's sequence number are skipped, so a crash between the rename and the truncation applies nothing twice. An incomplete last line, or zero padding a file system left after a crash, belongs to a batch that was never acknowledged: it is dropped and cut off the file. Damage anywhere else stops the start with the line number. If the journal cannot be written (disk full, I/O error), the hub stops accepting changes, `/readyz` turns unavailable, and writes answer 503 until it is restarted.

Presence is not journaled: monitors report it on every change and at least every 4 minutes, so after a restart it is back within one poll interval. Events are retained for listing and stream resume up to `--event-retention` (10 000, the newest win); notes and tokens are kept until deleted.

### Tokens and roles

A token looks like `grh_<16 hex id>_<26 base32 characters>`. Only the SHA-256 of the whole token is stored; the id finds the record and the hash is compared in constant time. The secret is printed once, when the token is created. Roles are `admin` (may manage tokens and delete any note) and `member`.

```sh
gitrochi-hub init   --data DIR [--name admin]                    # first admin; refuses an initialized directory
gitrochi-hub token  create --data DIR --name alice [--role member]
gitrochi-hub token  list   --data DIR                            # never prints secrets or hashes
gitrochi-hub token  revoke --data DIR (--id ID | --name alice)
```

These work offline on the data directory and refuse while a server holds its lock. A running hub manages tokens over `/api/v1/tokens` with an admin token. Names are 1–64 letters, digits or `. _ @ + -`; the name is the member's identity in presence, events and notes.

### `serve` flags

| Flag | Default | |
| --- | --- | --- |
| `--data` | `$GITROCHI_HUB_DATA` | data directory (required) |
| `--listen` | `127.0.0.1:7420` | exposing the hub is a deliberate choice |
| `--tls-cert`, `--tls-key` | | serve HTTPS (TLS 1.2+, HTTP/2) |
| `--presence-ttl` | `10m` | presence lifetime |
| `--rate`, `--burst` | `20`, `60` | token bucket per token; a negative rate disables it |
| `--max-body` | `1048576` | request body limit in bytes |
| `--event-retention` | `10000` | events kept for listing and resume |
| `--snapshot-every`, `--snapshot-interval` | `1000`, `5m` | compaction |
| `--log-format`, `--log-level` | `text`, `info` | `log/slog` to stderr; `json` for collectors |

`serve` refuses a directory without an active token. SIGINT or SIGTERM starts a graceful shutdown: `/readyz` reports `draining`, every SSE stream gets a `shutdown` event and ends, in-flight requests get 15 seconds, then the journal is flushed, a final snapshot written and the lock released.

## HTTP API

JSON in and out, field names in camelCase. Times are RFC 3339 in UTC with whole seconds (`2026-05-01T09:00:00Z`). Every request except `/healthz`, `/readyz` and `/metrics` needs `Authorization: Bearer <token>`. Request bodies are decoded strictly: unknown fields, trailing data and bodies over the limit are rejected. Errors look like the index's:

```json
{"error": {"code": "INVALID_ARGUMENT", "message": "ref.updated needs old and new"}}
```

| Code | Status |
| --- | --- |
| `INVALID_ARGUMENT` | 400 |
| `UNAUTHORIZED` | 401 (with `WWW-Authenticate: Bearer`) |
| `FORBIDDEN` | 403 |
| `NOT_FOUND` | 404 |
| `PAYLOAD_TOO_LARGE` | 413 |
| `RATE_LIMITED` | 429 (with `Retry-After` in seconds) |
| `UNAVAILABLE` | 503 (journal unwritable, or shutting down) |
| `INTERNAL` | 500 |

### Repository keys

Repositories are named by their normalized remote URL: lower-cased host and the path, without scheme, user, port or `.git`. `git@example.com:team/app.git`, `https://example.com/team/app` and `ssh://git@example.com:2222/team/app.git` are all `example.com/team/app`. The path keeps its case. Local paths and `file://` URLs have no key. Wherever the API takes a repository, it accepts a key or any remote URL form. In URL paths the key's slashes may be literal or percent-encoded: `/api/v1/repos/example.com/team/app/overlaps` and `/api/v1/repos/example.com%2Fteam%2Fapp/overlaps` are the same.

### Endpoints

| Method and path | Who | Body → answer |
| --- | --- | --- |
| `GET /healthz` | anyone | `{"status":"ok","version":{…}}` |
| `GET /readyz` | anyone | 200 `{"status":"ready"}`, or 503 while draining or when the journal failed |
| `GET /metrics` | anyone | Prometheus text format |
| `GET /api/v1/me` | member | `{"tokenId","name","role"}` |
| `POST /api/v1/presence` | member | Presence → `{"presence": PresenceEntry, "overlaps": [Overlap]}` (the caller's overlaps) |
| `DELETE /api/v1/presence?repo=R&client=C` | member | 204; withdraws the caller's entry |
| `GET /api/v1/repos/{repo}/presence` | member | `{"repo","presence":[PresenceEntry]}` |
| `GET /api/v1/repos/{repo}/overlaps` | member | `{"repo","overlaps":[Overlap]}` |
| `POST /api/v1/repos/{repo}/notes` | member | NoteInput → 201 Note |
| `GET /api/v1/repos/{repo}/notes?commit=&path=&after=&limit=` | member | `{"repo","notes":[Note]}`, oldest first (limit 500, at most 5000) |
| `DELETE /api/v1/notes/{id}` | author or admin | 204 |
| `POST /api/v1/events` | member | EventInput → 201 Event |
| `GET /api/v1/events?repo=&after=&limit=` | member | `{"events":[Event],"last","more","oldest","truncated"}` (limit 100, at most 1000) |
| `GET /api/v1/stream?repo=` | member | Server-Sent Events, below |
| `GET /api/v1/tokens` | admin | `{"tokens":[{"id","name","role","created","revoked"}]}` |
| `POST /api/v1/tokens` | admin | `{"name","role"}` → 201 with `"token"`, the only copy of the secret |
| `DELETE /api/v1/tokens/{id}` | admin | the revoked token's info |

### Presence and overlaps

```jsonc
// POST /api/v1/presence
{
  "repo": "git@example.com:team/app.git",
  "branch": "feature/login", "head": "4f2c…", "base": "9a01…",   // base: merge-base with the default branch
  "ahead": 2, "behind": 0,                                        // against the upstream
  "changed": ["src/auth.go", "README.md"],                         // committed since base, plus staged and unstaged
  "related": ["docs/auth.md"],                                     // files that usually change with "changed"
  "client": "laptop"                                               // one entry per member and client
}
```

The hub stores it as a PresenceEntry: the same fields with `repo` normalized, the paths sorted and deduplicated, plus `member`, `updated` and `expires`. Lists hold at most 5000 repository-relative paths of up to 1024 bytes.

An Overlap is `{"kind", "a": Participant, "b": Participant, "paths": […]}` with Participant `{"member","client","branch","head"}`:

- `same-file`: both changed `paths`.
- `related-file`: `a` changed `paths` and they are in `b`'s related set, so `b`'s work probably has to touch them too. Paths both changed are left out (they are already a same-file overlap).

Entries of one member never overlap each other, whatever their clients. Expired entries are ignored at once and swept every 30 seconds.

### Events

```jsonc
// POST /api/v1/events
{"repo": "example.com/team/app", "type": "ref.updated", "ref": "refs/heads/main",
 "old": "<40 or 64 hex>", "new": "<40 or 64 hex>", "forced": true, "message": "", "at": "2026-05-01T09:00:00Z"}
```

Types clients may post: `ref.created` (needs `new`), `ref.updated` (needs `old` and `new`; `forced` only here), `ref.deleted` (needs `old`), `ci.passed` and `ci.failed` (`ref` is free text such as a branch, `new` an optional commit of 7+ hex digits, `message` up to 2000 characters). The hub emits `note.created` and `note.deleted` itself, with the note in `note`. A stored Event adds `id` (increasing across all repositories), `member` and `received`; an `at` more than 5 minutes in the future becomes the server's time.

In listings, `last` is the cursor for the next page and `truncated` is true when the client missed events: retention dropped some after its cursor, or its cursor is newer than any event, which happens after the hub's data was reset (the listing then starts from the beginning).

### Notes

`{"commit": "abc1234", "body": "…"}`, `{"path": "src/api.go", "line": 12, "body": "…"}`, or a path at a commit. The body is trimmed and holds up to 10 000 characters. `commit` filters match abbreviated SHAs in either direction; `path` matches exactly.

### The stream

`GET /api/v1/stream` (optionally `?repo=`) is `text/event-stream`:

```
retry: 3000

id: 42
event: ref.updated
data: {"id":42,"repo":"example.com/team/app","type":"ref.updated",…}

: ping
```

- Reconnect with `Last-Event-ID` (or `?after=`) to resume: retained events after that ID come first, then live ones, without gaps or repeats.
- When the client missed events, the first frame is `event: truncated` with `{"after","oldest"}`; refetch whatever is on screen.
- A comment is sent every 15 seconds on idle streams.
- Each subscriber has a buffer of 256 events. One that falls behind is dropped (its stream ends) instead of slowing anyone down; it reconnects with its last ID. A write that stalls for 10 seconds ends the stream too.
- On shutdown the stream gets `event: shutdown` and ends.
- Browsers' `EventSource` cannot send an `Authorization` header and tokens never go in URLs, so web clients need a fetch-based SSE reader.

## Security model

- The hub listens on loopback by default. Expose it through a TLS reverse proxy or with `--tls-cert`/`--tls-key`. The stream sends `X-Accel-Buffering: no`; a proxy must not buffer `/api/v1/stream`.
- Tokens carry 128 bits of secret; only their SHA-256 is stored, compared in constant time; revocation takes effect on the next request. Logs carry the member name and token id, never a token, and no request headers.
- Per-token rate limits, body limits, strict decoding, header and idle timeouts. Per-write deadlines keep a stalled stream from holding a handler.
- `/metrics`, `/healthz` and `/readyz` are open and expose counts only; restrict them at the proxy if that matters.
- Remote URLs are normalized before use, so credentials embedded in them never reach the hub; git error output is redacted (`https://***@host`) before it is logged.
- The monitor reads its token from `--token-file`, `GITROCHI_HUB_TOKEN` or the configured `tokenFile`, warns when the file is readable by others, and never prints it. Its local endpoints accept loopback host names only (against DNS rebinding) and refuse cross-origin POSTs.

## The monitor

```json
{
  "repos": [
    "~/src/app",
    {"path": "~/src/lib", "key": "example.com/team/lib", "remote": "origin", "defaultBranch": "origin/main"}
  ],
  "hub": "https://hub.example.com",
  "tokenFile": "~/.config/gitrochi/hub-token",
  "pollInterval": "30s",
  "fetchInterval": "0s",
  "maxGitProcesses": 4
}
```

| Field | Default | |
| --- | --- | --- |
| `repos` | | paths, or objects with `path`, `key` (else from the remote URL), `remote` (`origin`), `defaultBranch` (else `<remote>/HEAD`, then `main`, `master`) |
| `pollInterval` | `30s` | at least `1s`; durations are strings or seconds |
| `fetchInterval` | `0s` | `git fetch --prune` this often; off by default |
| `maxGitProcesses` | `4` | git and index processes at once, across all repositories (at most 64) |
| `gitTimeout`, `fetchTimeout`, `indexTimeout` | `1m`, `5m`, `10m` | per process; on expiry the whole process tree is killed |
| `git` | `git` on PATH | |
| `index` | `$GITROCHI_INDEX_BIN`, else `gitrochi-index` on PATH if present | `"off"` disables it |
| `impactLimit` | `20` | related files per repository |
| `hub`, `tokenFile`, `caFile` | | without `hub` everything stays local; `caFile` trusts a private CA |
| `client` | the host name | presence client name |
| `listen` | `127.0.0.1:7421` | local endpoints; `"off"` disables them |
| `state` | `<user cache dir>/gitrochi-hub/monitor-state.json` | ref snapshots and undelivered events between runs |
| `eventRefs` | `["refs/heads/"]` | ref prefixes whose changes become hub events |
| `presenceRefresh` | `4m` | resend unchanged presence this often (below the hub's TTL) |

Relative paths are relative to the configuration file, `~/` is the home directory, and unknown fields are errors.

### A pass over a repository

1. `git fetch --prune --quiet --no-write-fetch-head <remote>` when the fetch interval has passed (with `gc.auto=0` and `maintenance.auto=false`; nothing else ever changes the repository).
2. `git status --porcelain=v2 --branch -z --untracked-files=no`: HEAD, branch, upstream, ahead/behind, staged, unstaged and conflicted paths.
3. `git for-each-ref --format=%(objectname)%00%(refname)%00%(symref) refs/heads/ refs/remotes/ refs/tags/`, compared with the previous snapshot: created, deleted and updated refs; an update is `forced` when `git merge-base --is-ancestor old new` says the old tip is not an ancestor (or no longer exists).
4. `git merge-base <default> HEAD` and `git diff --name-only --no-renames -z <base> HEAD` (cached while HEAD and the default tip stay put), joined with the dirty paths: `changed`.
5. The index, below.
6. Undelivered events in order, then presence when it changed or is due. The hub's answer carries this member's overlaps, which `/status` shows.

The first time a repository is seen is a baseline, not a change. Every process runs with `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never` and `GIT_OPTIONAL_LOCKS=0` (a background status never takes the index lock from the user), in its own session without a terminal; on Windows without a console window, and a timeout ends the tree with `taskkill /T`.

**Concurrency.** One worker per repository; a pass holds the repository's lock, so a repository is never synced twice at once. Triggers coalesce: any number during a pass cause exactly one more. Every git and index process waits for a slot in one shared pool (`maxGitProcesses`). Failing fetches, hub requests and index runs back off exponentially with jitter (hub: 2 s doubling to 5 min; a longer `Retry-After` wins), while local polling goes on. Undelivered events (at most 200 per repository) are kept in the state file, so a restart or the next cron run still delivers them. An event the hub rejects outright (a 4xx other than 401, 403 or 429) is dropped rather than left to block the queue. On shutdown the monitor withdraws its presence.

### How the monitor uses the Rust index

The monitor never opens the SQLite file; it runs the CLI through the same process pool as git (the index runs git itself):

- `gitrochi-index --repo <top level> sync` the first time it sees a repository and after every ref change. Sync is incremental and idempotent.
- `gitrochi-index --repo <top level> impact -- <changed paths…>` whenever the changed set moves (at most 200 paths and 16 KiB of arguments). The suggestions, best first, minus the changed files and cut to `impactLimit`, become `related`, which is how the hub finds related-file overlaps.
- The index is optional: without the binary, with `"index": "off"`, or with **`GITROCHI_INDEX=0`** (the apps' switch) the monitor runs without it and `related` stays empty. `GITROCHI_INDEX_BIN` names the binary when the configuration does not. The environment reaches the index unchanged, so `GITROCHI_INDEX_DB` moves the database; by default it is the repository's shared `<git common dir>/gitrochi/index.sqlite3`, the same one the apps use.
- Index failures back off from 10 seconds to 30 minutes and show as `indexError`.

### Local endpoints and `--once`

| | |
| --- | --- |
| `GET /healthz` | `{"status":"ok"}` |
| `GET /status` | `{"tool","version","started","client","hub","index","git":{"limit","inFlight","peak","started","timeouts"},"repos":[RepoStatus]}` |
| `GET /metrics` | Prometheus text format |
| `POST /trigger?repo=<path or key>` | poll now (all repositories without `repo`); 202 `{"triggered":n}` |

RepoStatus has `path`, `key`, `branch`, `head`, `upstream`, `ahead`, `behind`, `defaultBranch`, `base`, `changed` and `dirty` counts, `related`, `refs`, `recentChanges` (`{"ref","kind","old","new","forced","at"}`), `overlaps`, `pendingEvents`, `polls`, `failures`, `lastPoll`, `lastPollMs`, `lastSync`, `lastFetch`, `lastPublish`, and `lastError`, `keyError`, `indexError`, `fetchError`, `hubError` with `hubRetryAt`.

`gitrochi-hub monitor --config FILE --once` polls every repository once, prints that status and exits 1 when anything failed, which suits cron. The state file makes consecutive runs see the ref changes in between.

## Other commands

```sh
gitrochi-hub overlaps --hub https://hub.example.com --repo . [--token-file F] [--ca-file F]
gitrochi-hub health   [--url http://127.0.0.1:7420/healthz] [--insecure]   # exit 0 when healthy
gitrochi-hub version                                                   # {"tool","version","commit","go","os","arch"}
```

`overlaps` takes a key, a remote URL or a local work tree (its `--remote`, default `origin`), and reads `GITROCHI_HUB_URL` and `GITROCHI_HUB_TOKEN`. Commands print their result as JSON on stdout and diagnostics on stderr. Exit status 0 is success, 1 a failure and 2 a usage error.

## Deployment

**Binary.** `services/hub/build.sh` builds `dist/gitrochi-hub` for the host; `--all` cross-compiles `linux/amd64`, `linux/arm64`, `darwin/arm64`, `darwin/amd64` and `windows/amd64` into `dist/` with `dist/SHA256SUMS`. Builds are static (`CGO_ENABLED=0`, `-trimpath -ldflags "-s -w -X main.version=…"`, the version from `git describe` or `VERSION`). Go comes from `$GITROCHI_GO`, else the repository's `.build/go-tools/go/bin/go` (found from linked worktrees too), else `go` on PATH.

**systemd.** [deploy/gitrochi-hub.service](deploy/gitrochi-hub.service) runs the hub as a dynamic user with `ProtectSystem=strict`, no capabilities, a system call filter and its data in `StateDirectory=gitrochi-hub` (`/var/lib/gitrochi-hub`). Create the first token as that kind of user before the first start:

```sh
sudo systemd-run --pty --wait --collect -p DynamicUser=yes -p User=gitrochi-hub \
  -p StateDirectory=gitrochi-hub /usr/local/bin/gitrochi-hub init --data /var/lib/gitrochi-hub
sudo systemctl enable --now gitrochi-hub
```

The unit's comments show TLS through `LoadCredential=`.

**Containers.** The [Dockerfile](Dockerfile) builds in `golang:1.27.3-alpine` and ships `FROM scratch`: the binary, CA roots and a `/data` volume owned by UID 65532, which the hub runs as. The exec-form `HEALTHCHECK` calls `gitrochi-hub health`, so it needs no shell; [deploy/compose.yaml](deploy/compose.yaml) repeats it for runtimes that ignore image health checks and runs the container read-only without capabilities:

```sh
docker compose -f services/hub/deploy/compose.yaml run --rm hub init --data /data
docker compose -f services/hub/deploy/compose.yaml up -d
```

## Metrics

Hub: `gitrochi_hub_http_requests_total{route,code}`, `gitrochi_hub_auth_failures_total`, `gitrochi_hub_rate_limited_total`, `gitrochi_hub_sse_subscribers`, `gitrochi_hub_sse_dropped_total`, `gitrochi_hub_journal_bytes`, `gitrochi_hub_journal_seq`, `gitrochi_hub_presence_entries`, `gitrochi_hub_events_retained`, `gitrochi_hub_notes`, `gitrochi_hub_tokens_active`, `gitrochi_hub_goroutines`, `gitrochi_hub_uptime_seconds`, `gitrochi_hub_build_info`. Routes are patterns (`GET /api/v1/repos/{repo}/overlaps`), never repository names.

Monitor: `gitrochi_monitor_polls_total`, `gitrochi_monitor_poll_failures_total`, `gitrochi_monitor_ref_changes_total{kind}`, `gitrochi_monitor_fetches_total{result}`, `gitrochi_monitor_hub_requests_total{kind,result}`, `gitrochi_monitor_index_runs_total{command,result}`, `gitrochi_monitor_processes`, `gitrochi_monitor_processes_peak`, `gitrochi_monitor_process_limit`, `gitrochi_monitor_processes_total`, `gitrochi_monitor_process_timeouts_total`, `gitrochi_monitor_pending_events`, `gitrochi_monitor_repos`, `gitrochi_monitor_build_info`.

## Development

```sh
services/hub/build.sh --check    # gofmt -l, go vet (also for Windows), go test -race ./..., then the build
```

Tests are hermetic: temporary directories, listeners on `127.0.0.1:0`, and git fixtures built in Go with `GIT_CONFIG_NOSYSTEM=1`, an empty `GIT_CONFIG_GLOBAL`, a temporary `HOME` and the identity set inside each fixture repository. Fake `git` and `gitrochi-index` shell scripts cover timeouts, process limits and the index contract; tests that need them are skipped on Windows. With a built index (`cargo build --release` of `crates/gitrochi-index`, or `GITROCHI_INDEX_BIN`) two more tests run the real binary against a temporary database; they are skipped otherwise.
