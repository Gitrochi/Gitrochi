# Ledger contract

The API every Ledger client relies on: the macOS app (C ABI), the Windows app (Tauri command), the `gitrochi-ledger` CLI, its MCP server and the hook handler. This crate owns it. It started as contract v0, written before any code; [Changes from v0](#changes-from-v0) lists what the implementation added or settled. Additions are free; renaming, removing or changing the meaning of anything here needs a note in that list and the maintainer's agreement.

The shapes are also JSON Schemas (draft 2020-12) in [`schema/`](schema/): `state`, `session`, `session-detail`, `ledger-event`, `question`, `graph` and `pending-prompt`. The tests check real results against them.

## Decisions assumed

Until the maintainer answers the design's questions, the recommended options hold: D1 Ledger is a workspace destination `ledger`, titled "Ledger". D2 no document-format parsers in v1. D3 work log later. D4 no multi-PC sharing in v1. D5 legacy claude-ledger import (wave 2). D6 baselines default to git tags. D7 re-implemented; no code or text copied. D8 auto-continue covers questions at the end of a turn, `AskUserQuestion` and permission requests; `ExitPlanMode` is a setting, off by default; Ledger questions are never closed automatically. D9 instant template replies. D10 app not running → synchronous hooks return no decision at once.

## Storage

- One SQLite database per user. `default_db_path()`: macOS `~/Library/Application Support/Gitrochi/ledger/ledger.sqlite3`, Windows `%APPDATA%\Gitrochi\ledger\ledger.sqlite3`, elsewhere `$XDG_DATA_HOME/gitrochi/ledger/ledger.sqlite3` (or `~/.local/share/…`). `GITROCHI_LEDGER_DB` overrides it; `GITROCHI_LEDGER=0` turns the feature off (every method but `info` answers `DISABLED`, and nothing is created).
- WAL, `BEGIN IMMEDIATE` for every write, busy timeout 15 s, `synchronous = NORMAL`, `trusted_schema = OFF`.
- `PRAGMA user_version` is the schema (1). Migration steps only add tables and columns, each in its own IMMEDIATE transaction, safe to run twice and from two processes at once. A file written by a newer build is read but never written (`SCHEMA_MISMATCH`).
- Only this crate writes the database, from any process. Every write is one transaction that also increments `meta.rev`; the apps poll `rev` and reload only when it moved. Reads run in one read transaction (one snapshot).
- Times are epoch milliseconds (i64). Input strings are NFC-normalised and trimmed (report bodies keep their layout).
- **Settings live in the database** (decided in wave 1): global settings in the `settings` table (key → JSON), per-project settings in the `projects` table. Every writer — the apps, the CLI, MCP and the hooks — then reads the same rules from the one file it already opens, changes reach the apps through `rev`, and there is no second file to keep in step. Only the apps change them.

| Global setting | Default | Meaning |
|---|---|---|
| `staleHours` | 72 | No agent activity for this long → `stale` |
| `kinds` | see below | kind → `{role, line?, handoff?}`; replaced as a whole |
| `autoContinue` | `{"enabled": false, "delaySec": 30}` | The global auto-continue policy (its other fields belong to `gitrochi-autocontinue` and are stored as given) |
| `backupKeep` | 14 | Backups to keep |

| Per project (`projects`) | Default | Meaning |
|---|---|---|
| `key`, `name` | the reported name | Agents report the key; the apps may show another name |
| `repoPath` | none | The repository whose tags are baselines |
| `baselineSource` | `tags` | `tags` (system git, `for-each-ref refs/tags`), `folder` (names under `baselineDir`), `manual` (registration and releases only) |
| `baselinePattern` | `^v?(\d+(?:\.\d+)+)$` | Regular expression, case-insensitive; the first group, or the whole match without one |
| `baselineDir`, `scanFiles`, `scanSubdirs` | none, false, `[]` | For `folder`: also files, and these sub-folders (not recursive) |

A project row appears with its first report. Scans run before reports and reads, at most every 15 s per project and process, write only when a version is new (or promotes an inferred one), and never stop the report when they fail.

## Vocabulary

- `status` (stored): `active | done | merged | closed | dropped | shelved`.
- `verdict` (computed, first match wins): `archived` (archivedAt set) > `needs_human` (open questions) > `merged`/`closed`/`dropped` → `expirable` if acknowledged else `confirm` > `shelved` > `done` → `pending_merge` > no agent activity for `staleHours` and no running snooze → `stale` > `active`.
- `role` (from `kind` through `settings.kinds`): `decision | implementation | research | document | other`. Default kinds: `research` → research, `decision` → decision, `implementation` → implementation (line `core`, hands off), `llm-implementation` → implementation (line `llm`, no hand-off; the original tool's second channel), `document` → document, `review`, `baseline`, `other` → other. Unknown kinds are kept as typed and have the role `other`. Known kinds are matched without case, spaces, `-`, `_` or `·`.
- **Stream**: a session whose role is `implementation` and whose status is not `merged`/`closed`/`dropped`. Streams keep their verdict but stay out of overlaps, the open-session lists, project open counts and the clean-up board; they are shown as cycles.
- Agent events: `start progress artifact question decision sync done merged closed dropped shelved release applied note heartbeat` (a heartbeat leaves no event). Korean aliases from the original tool (`시작`, `이행` …) and `rebase`, `merge`, `close`, `drop`, `apply`, `shelve` are accepted and stored in English; so are the original's kind names (`연구`, `판정`, `구현`, `LLM구현` …) and the latest words (`latest`, `head`, `최신` …).
- Other event types: `auto_reply` (actor `auto`), `hook` (actor `hook`, wave 2), and a person's actions (actor `human`): `ack unack archive unarchive set_status answer dismiss snooze shelve link message auto_continue`.
- `actor`: `agent | human | auto | hook`.
- **Resume rule**: `start`, `progress`, `artifact`, `question`, `decision`, `sync` or `applied` on a session that is not active makes it active and clears `ackAt`, `archivedAt` and `mergedInto` (the event keeps `data.reopenedFrom`). Any agent report but `note`/`heartbeat` clears `archivedAt` and `ackAt`.
- **A finishing status a person chooses also acknowledges** (`merged`, `closed`, `dropped`); `active` clears the acknowledgement and the archive. Shelving never acknowledges.
- **Hand-offs** — the only way an agent's report changes another session: an implementation session on a hand-off line that reports `sync vX` moves the live decision session that released vX (`baselines.bySession`) to `merged` without acknowledging it (finished or archived sessions are left alone, so syncing again does nothing); its `applied vX` moves the targets (`targets`, else the releaser) that are decision sessions to `merged` **and** acknowledges them, leaving open questions open. Agents have no other way to acknowledge.

## Types

```ts
type Ms = number;
interface Session {
  id: string; project: string; title: string; kind: string;
  role: "decision" | "implementation" | "research" | "document" | "other";
  status: "active" | "done" | "merged" | "closed" | "dropped" | "shelved";
  verdict: "archived" | "needs_human" | "expirable" | "confirm" | "shelved" | "pending_merge" | "stale" | "active";
  baseVersion?: string; baseCurrent?: string; baseWasLatest?: true; behind?: number; mergedInto?: string;
  touches: string[]; related: string[]; chatUrl?: string;
  links: { repoPath?: string; branch?: string; worktree?: string;
           pr?: { host: string; number: number; url: string };
           agentId?: string; agentSessionId?: string; cwd?: string };
  color: number;              // 0…7: creation order within the project, modulo 8
  createdAt: Ms; lastAt: Ms; lastAgentAt?: Ms; ackAt?: Ms; snoozeUntil?: Ms; archivedAt?: Ms;
  openQuestions: number;
  stream?: { line: string };  // live implementation sessions only
  autoContinue?: { enabled: boolean; delaySec: number };  // absent: the global default
}
interface LedgerEvent {
  id: number; sessionId: string; ts: Ms; type: string; actor: "agent" | "human" | "auto" | "hook";
  summary?: string; body?: string /* Markdown ≤ 60,000 characters */; version?: string;
  artifacts?: { name: string; ssot?: string; ver?: string; path?: string; note?: string; ssotInferred?: boolean }[];
  data?: Record<string, unknown>; channel?: string; deliveredAt?: Ms;
}
interface Question { id: number; sessionId: string; text: string; state: "open" | "answered" | "dismissed";
  answer?: string; answeredBy?: "human" | "auto"; resolvedBy?: "agent";
  createdAt: Ms; answeredAt?: Ms; deliveredAt?: Ms }
interface Baseline { project: string; version: string; ts: Ms; effTs: Ms;
  source: "tag" | "folder" | "registered" | "release" | "inferred"; note?: string; bySession?: string;
  ref?: string /* tag or folder name */; commit?: string }
interface StreamCycle { sessionId: string; line: string; version: string /* "" before a base */;
  state: "applied" | "active" | "skipped"; syncedAt?: Ms; appliedAt?: Ms; releasedBy?: string; eventIds: number[];
  firstAt: Ms; lastAt: Ms; events: number; questions: number; artifacts: string[];
  syncSummary?: string; appliedSummary?: string }
interface Overlap { a: string; b: string; paths: string[]; kind: "same" | "coupled" }
interface PendingPrompt { id: number; sessionId?: string; agentId?: string;
  kind: "stop_question" | "ask_user_question" | "exit_plan_mode" | "permission";
  payload: Record<string, unknown>; createdAt: Ms; deadline: Ms;
  state: "waiting" | "answered" | "auto" | "released" | "expired";
  answer?: Record<string, unknown>; answeredBy?: "human" | "auto"; answeredAt?: Ms; reviewedAt?: Ms }
interface Attention { questions: number; tidy: number; decide: number; autoReview: number; total: number }
interface State { schemaVersion: 1; rev: number; now: Ms;
  projects: { key: string; name: string; open: number; head?: string; lastAt?: Ms }[];
  baselines: Baseline[];       // every trunk of the selected project(s), ascending per project
  sessions: Session[];         // not archived, plus archived ones inside the range
  questions: Question[];       // open, of sessions that are not archived
  streams: StreamCycle[];      // live streams, most recently active first, newest cycle first
  overlaps: Overlap[]; pendingPrompts: PendingPrompt[] /* waiting */;
  autoReview: PendingPrompt[]; // answered by auto-continue, not reviewed yet
  attention: Attention; hiddenBefore: number /* archived sessions older than the range */ }
interface GraphNode { id: string /* "b:<version>" or "e:<event id>" */; lane: number; row: number; ts: Ms; color: number;
  kind: "baseline" | "start" | "event" | "merge" | "release" | "end"; sessionId?: string; version?: string; label?: string;
  type?: string; eventId?: number; actor?: string; source?: string; head?: true;
  handoff?: "awaiting" | "synced" | "applied"; bySession?: string }
interface GraphEdge { from: string; to: string; kind: "trunk" | "branch" | "merge" | "handoff"; color: number }
interface GraphTail { sessionId: string; lane: number; row: number; color: number }
interface Graph { lanes: number; rows: number; nodes: GraphNode[]; edges: GraphEdge[]; tails: GraphTail[];
  from: Ms; to: Ms; hiddenBefore: number }
interface Message { from: "human"; text: string; at: Ms; kind: "answer" | "dismissed" | "message" | "status"; questionId?: number }
```

### The graph

Computed here so both apps only draw. Rows: baselines (at `effTs`) and events, newest first; at equal times a baseline sits above events. Lane 0 is the trunk. Each session's interval covers its nodes, its base's row and the row of the baseline it merged into; a live session reaches row 0 (drawn as a dashed `tail` from its newest node up). Sessions are placed oldest fork first, each in the lowest lane that keeps one free row from the other intervals in it. Edges: `trunk` (older baseline → newer), `branch` (base → first node, then node → node within a session), `merge` (a session's newest merge event → the baseline it went into, and a release → the new baseline; none when the session released that baseline itself), `handoff` (dashed: a baseline → the session's `sync` node, and a report → the record it left on another session). Nodes and edges use the session's color; the trunk uses 0 (lane 0 identifies it). Drawn events: every agent event, `auto_reply`, and a person's `set_status`, `shelve`, `ack` and `archive`; with `keyOnly`, only start, artifact, question, decision, sync, done, merged, closed, dropped, release, applied, shelved, resumed events, status changes and each session's first event. Baselines and events before the range are not drawn and are counted in `hiddenBefore`, except HEAD. `from`/`to` are the window (`to` = now). The same database gives the same nodes, edges and tails.

## Methods

Every entry point takes a method name and a JSON object and returns JSON; failures are `{"error": {"code", "message"}}`. Any method accepts `db` (a path) to use another database than the default — for tests and tools; the apps never pass it.

| Method | Args | Returns | Callers |
|---|---|---|---|
| `info` | `{}` | `{schemaVersion: 1, dbPath, rev, enabled, dbSchema, version}` | all |
| `rev` | `{}` | `{rev}` | all (one statement; the apps poll it) |
| `state` | `{project?, range?: "7d" \| "30d" \| "all"}` (default 7d; no project = all) | `State` | app, agent |
| `session` | `{id}` | `{session, events, questions, overlaps, cycles, head?, waitingMessages}`; never delivers | app, agent |
| `graph` | `{project, range?, keyOnly?, includeArchived?}` | `Graph` | app, agent |
| `search` | `{query, project?, limit? (50)}` | `{hits: [{kind: "session" \| "question" \| "event" \| "baseline", id: string, sessionId?, title, snippet, ts?}]}` — every word must appear (ASCII case ignored) | app, agent |
| `attention` | `{project?}` | `{rev, attention: Attention}` | app, agent |
| `overview` | `{project?, session?, deliver?}` | `{text, data}` — messages are delivered only with `session` and `deliver: true` | app, agent |
| `report` | the report fields below | `{sessionId, notices, messages: Message[], created, event, session, head?, questionIds, text}`; the session's waiting messages are delivered exactly once | app, agent |
| `import` | `{text, project?}` | `{results: [{index, ok, duplicate, error?, sessionId?, event?, notices?}]}` — a duplicate is `ok` and skipped | app, agent |
| `scan` | `{project?}` | `{results: [{project, source, found, added, error?}]}` (forced, all projects without one) | app, agent |
| `register_baseline` | `{project, version, note?}` | `{ok, rev, project, version}` | app, agent |
| `backup` | `{daily?, keep?}` | `{path, created, size, removed}` | app, agent |
| `settings` | `{}` | `{staleHours, kinds, autoContinue, backupKeep}` with defaults | all |
| `projects` | `{}` | `{projects: [{key, name, repoPath?, baselineSource, baselinePattern, baselineDir?, scanFiles, scanSubdirs}]}` | app, agent |
| `human` | `{action, sessionId, …}` (below) | `{ok, rev}` | app only |
| `prompt_answer` | `{id, answer: {…}}` | `{ok, rev, state, prompt}` — `ok: false` when the prompt no longer waits | app only |
| `prompt_review` | `{id}` or `{all: true}` | `{ok, rev, reviewed}` | app only |
| `settings_set` | `{values: {key: value \| null}}` (null = default) | `{ok, rev, settings}` | app only |
| `project_set` | `{project, name?, repoPath?, baselineSource?, baselinePattern?, baselineDir?, scanFiles?, scanSubdirs?}` (null clears) | `{ok, rev, project}` | app only |
| `prompt_create` | `{kind, sessionId?, agentId?, payload?, delaySec? (30) \| deadline?}` | `{ok, rev, prompt}` | app, hook |
| `prompt_get` | `{id}` | `PendingPrompt` | app, hook |
| `prompt_resolve` | `{id, state: "auto" \| "released" \| "expired", answer? (auto), summary?}` | `{ok, rev, state, prompt}`; `auto` also records an `auto_reply` event | app, hook |
| `prompt_expire` | `{}` | `{ok, rev, expired}` — waiting prompts 10 minutes past their deadline | app, hook |

Callers: **app** = the C ABI and the Tauri command (a person is at the controls); **agent** = the CLI's `call` and the MCP server; **hook** = the wave 2 hook handler. A method called by a caller it is not for answers `NOT_ALLOWED`; the caller comes from the entry point, never from the request.

### Report fields

`project` (needed for a new session), `session` (or `sessionId`; issued as `S<MMDD>-<nn>` in local time when absent; otherwise 3–48 letters of any script, digits, `.`, `_`, `-`), `event` (default `progress`), `kind`, `title`, `base`, `summary`, `body`, `question`, `questions` (a string is one question), `touches`, `related`, `artifacts` (list, one object, or names; `artifact` adds one), `version`, `into`, `absorbs`, `targets`, `resolves` (question numbers), `ssot`, `note` (release note), `chatUrl` (or `chat_url`; http(s) only), `work` (kept in `data.work`). Lists may be arrays, comma-separated text or one number. `latest`/`head` resolve to HEAD at that moment and are stored as the number. A version the trunk lacks is added as `inferred` and promoted when a scan or registration finds it. A non-start event on an unknown session creates it with an automatic start just before. A `start` with another title on an existing ID is a `CONFLICT`; with the same title it is recorded as `progress`.

### A person's operations (`human`)

| Action | Args | Effect |
|---|---|---|
| `ack` / `unack` | `sessionId` | Acknowledge / withdraw |
| `archive` / `unarchive` | `sessionId` | The conversation was cleaned up / undo |
| `set_status` | `sessionId, status, into? (merged), reason?` | Finishing statuses acknowledge; `active` also unarchives; `shelved` only for research and document roles; delivered to the agent |
| `shelve` | `sessionId, reason?` | `set_status` shelved |
| `answer` / `dismiss` | `questionId (or question, id), answer` | Delivered to the agent with its next report or read |
| `snooze` | `sessionId, until? \| hours?` | Not stale until then (default: `staleHours` from now); `lastAt` is left as the agent left it |
| `link` | `sessionId`, any of `branch, worktree, repoPath, agentId, agentSessionId, cwd, pr: {host, number, url}, chatUrl` (null removes) | Links shown in the inspector |
| `message` | `sessionId, text` | A note for the agent, delivered once |
| `auto_continue` | `sessionId, autoContinue: {enabled, delaySec} \| null` | The session's policy; null = the global default |

### Errors

`INVALID_ARGUMENT` (bad or missing input), `NOT_FOUND`, `CONFLICT` (a session ID with another title or project), `NOT_ALLOWED` (wrong caller), `DISABLED` (`GITROCHI_LEDGER=0`), `DATABASE`, `SCHEMA_MISMATCH`, `GIT_FAILED` (scans report it in their result instead).

## Entry points

- **C ABI** (macOS): `char *gitrochi_ledger_call(const char *method, const char *json)` and `void gitrochi_ledger_free(char *)` in [`include/gitrochi_ledger.h`](include/gitrochi_ledger.h). NULL `json` means `{}`; the result is never NULL; safe from several threads; panics become `DATABASE` errors. Linking it into `libgitrochi_core.a` is wave 2.
- **Windows**: one Tauri command `ledger_call(method: String, args: serde_json::Value) -> Result<serde_json::Value, String>` calling `gitrochi_ledger::call` (wave 2).
- **CLI** `gitrochi-ledger`: `report`, `overview`, `session`, `import`, `scan`, `register`, `backup`, `demo <db> [--large]`, `call <method> [json]` (agent caller), `mcp`; `hook <event>` arrives in wave 2. See the [README](README.md).
- **MCP** (`gitrochi-ledger mcp`): `ledger_overview`, `ledger_report`, `ledger_session`; delivery only for the caller's own session; no person's operations. Protocol versions as `tools/gitrochi-mcp`: `2025-11-25`, `2025-06-18`, `2024-11-05`.
- `GITROCHI_LEDGER_SESSION` is the default session of the CLI and the MCP tools (for agents Gitrochi launches).

## Auto-continue

The hook handler creates a `pending_prompts` row when an agent stops to ask (`prompt_create`, deadline = now + the delay), polls it (`prompt_get`), and closes it with `prompt_resolve`: `auto` when auto-continue answered (also an `auto_reply` event on the session, actor `auto`, `data: {promptId, kind, answer}`), `released` when it let go, `expired`. A person answers from the app with `prompt_answer`, which wins only while the prompt waits. Automatic answers count in `attention.autoReview` until `prompt_review`. The policy (what to answer, deny rules, hook outputs) belongs to `crates/gitrochi-autocontinue`; the payload and the answer are stored as given. Auto-continue never answers Ledger questions and never acknowledges a session.

## Changes from v0

Additions (optional fields and new methods; nothing renamed or removed):

1. `Session`: `behind`, `baseWasLatest`; `autoContinue` only when the session has its own policy.
2. `LedgerEvent`: `channel`; artifacts carry `path`, `note`, `ssotInferred`.
3. `Question`: `resolvedBy: "agent"` when the session settled the question itself (`resolves`); `answeredBy` is then absent, so its two values stay `human | auto`.
4. `Baseline`: `effTs` (the inferred-version time correction), `ref`, `commit`.
5. `StreamCycle`: `firstAt`, `lastAt`, `events`, `questions`, `artifacts`, `syncSummary`, `appliedSummary`; `version` is `""` for reports before the session had a base.
6. `PendingPrompt`: `reviewedAt`.
7. `State`: `projects[].head`, `projects[].lastAt`, `autoReview`; `range` defaults to `7d`; without `project`, every project.
8. `Graph`: `rows`, `tails`, `hiddenBefore`; nodes `row`, `type`, `eventId`, `actor`, `source`, `head`, `handoff`, `bySession`; args `keyOnly`, `includeArchived`.
9. `session`: `head`, `waitingMessages`. `report`: `created`, `event`, `session`, `head`, `questionIds`, `text`. `Message`: `kind`, `questionId`. `import` results: `event`, `notices`, and a duplicate is `ok: true`. Search hits: `id` is always text, `ts`.
10. Methods `attention`, `scan`, `register_baseline`, `settings`, `projects`, `settings_set`, `project_set`, `prompt_create`, `prompt_get`, `prompt_resolve`, `prompt_expire`, `prompt_review`; the human action `auto_continue`; the `hook` caller; `args.db`; the CLI command `register`.
11. Settled: settings live in the database (above); kinds are stored in canonical English, with `llm-implementation` as a default second line without hand-offs; `lastAt` is the last agent activity on the session (its own reports, and hand-offs that changed it) and drives `stale`; a snooze sets `snoozeUntil`.

Narrowed on purpose (the original tool was wider):

12. `applied` hands off only from implementation sessions on a hand-off line; from any other session it records the version and confirms nothing.
13. A person's `shelve` (and `set_status` shelved) is limited to research and document roles, like the agent's `shelved`.

Requests for later waves (not changed here): live `implementation` sessions are streams by contract, so agents Gitrochi launches with that kind would stay out of overlaps and clean-up until a person closes them — wave 2 may want launched agents to use another kind, or a different default in `settings.kinds`.
