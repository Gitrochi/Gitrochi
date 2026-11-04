# Ledger contract

The API every Ledger client relies on: the macOS app (C ABI), the Windows app (Tauri command), the `gitrochi-ledger` CLI, its MCP server and the hook handler. This crate owns it. It started as contract v0, written before any code; [Changes from v0](#changes-from-v0) lists what the implementation added or settled. Additions are free; renaming, removing or changing the meaning of anything here needs a note in that list and the maintainer's agreement.

The shapes are also JSON Schemas (draft 2020-12) in [`schema/`](schema/): `state`, `session`, `session-detail`, `ledger-event`, `question`, `graph`, `pending-prompt`, `legacy-import`, `integration-status`, `hub-share`, `backups`, `restore`, `release-notes` and `insights`. The tests check real results against them.

## Decisions

The maintainer confirmed D1–D10 as recommended on 2026-10-31 ([DESIGN.md §14](../../docs/ledger/DESIGN.md#14-decisions)), and this contract follows them: D1 Ledger is a workspace destination `ledger`, titled "Ledger". D2 no document-format parsers in v1. D3 work log later. D4 no multi-PC sharing in v1; since 2026-11-03 an opt-in, default-off sharing of live sessions with the team hub ([`hub_share`](#sharing-with-the-team-hub)). D5 a read-only import of a claude-ledger database ([`import_legacy`](#importing-a-claude-ledger-database)). D6 baselines default to git tags. D7 re-implemented, with no code or text copied, and the compatibility surface kept: the MCP tool names `ledger_overview`, `ledger_report` and `ledger_session`, the report field names, the ```` ```ledger ```` block, the session ID shape and the input aliases. D8 auto-continue covers questions at the end of a turn, `AskUserQuestion` and permission requests; `ExitPlanMode` is a setting, off by default; Ledger questions are never closed automatically. D9 instant template replies. D10 app not running → synchronous hooks return no decision at once. D11–D13 stand there as working defaults.

## Storage

- One SQLite database per user. `default_db_path()`: macOS `~/Library/Application Support/Gitrochi/ledger/ledger.sqlite3`, Windows `%APPDATA%\Gitrochi\ledger\ledger.sqlite3`, elsewhere `$XDG_DATA_HOME/gitrochi/ledger/ledger.sqlite3` (or `~/.local/share/…`). `GITROCHI_LEDGER_DB` overrides it; `GITROCHI_LEDGER=0` turns the feature off (every method but `info` answers `DISABLED`, and nothing is created).
- WAL, `BEGIN IMMEDIATE` for every write, busy timeout 15 s (1 s for the hook handler), `synchronous = NORMAL`, `trusted_schema = OFF`.
- `PRAGMA user_version` is the storage schema (8). Schema 2 adds `questions.metadata TEXT NOT NULL DEFAULT '{}'` for optional question forms; schemas 3–7 add work, notebook, legacy evidence and document tables. Schema 8 adds `questions.browser_source_url`, `questions.browser_draft`, `browser_captures` and durable `browser_session_generations`. Populated browser previews that also used schema 3 retain their data, gain the missing production work tables and skip browser columns they already have. Migration steps only add tables and columns, each in its own IMMEDIATE transaction, guarded by its version and safe to open from two processes at once. A file written by a newer build is read but never written (`SCHEMA_MISMATCH`). The JSON API schema remains 1; the new question fields are optional.
- Only this crate writes the database, from any process. Every write is one transaction that also increments `meta.rev`; the apps poll `rev` and reload only when it moved. Reads run in one read transaction (one snapshot).
- Times are epoch milliseconds (i64). Input strings are NFC-normalised and trimmed (report bodies keep their layout).
- **Settings live in the database** (decided in wave 1): global settings in the `settings` table (key → JSON), per-project settings in the `projects` table. Every writer — the apps, the CLI, MCP and the hooks — then reads the same rules from the one file it already opens, changes reach the apps through `rev`, and there is no second file to keep in step. Only the apps change them.

| Global setting | Default | Meaning |
|---|---|---|
| `staleHours` | 72 | No agent activity for this long → `stale` |
| `kinds` | see below | kind → `{role, line?, handoff?}`; replaced as a whole |
| `autoContinue` | `{"enabled": false, "delaySec": 30}` | The global auto-continue policy (its other fields belong to `gitrochi-autocontinue` and are stored as given), and `repositories`: repository path → `{enabled, delaySec}`, the policy `track` gives the sessions of agents started there |
| `backupKeep` | 14 | Backups to keep |
| `wakeAgents` | `{"enabled": false, "waitSec": 300}` | Wake waiting agents with my answers: how long a launched agent's `Stop` hook waits for a person's answer or message (10–300 s), [Hooks](#hooks). A missing field takes its default |

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
- `verdict` (computed, first match wins): `archived` (archivedAt set) > `needs_human` (open questions) > `merged`/`closed`/`dropped` → `expirable` if acknowledged else `confirm` > `shelved` > `done` → `pending_merge` > no agent activity for `staleHours` and no running snooze → `stale` (an unreported launch only once its branch has moved on from where it started, [below](#sessions-for-agents-gitrochi-starts)) > `active`.
- `role` (from `kind` through `settings.kinds`): `decision | implementation | research | document | other`. Default kinds: `research` → research, `decision` → decision, `implementation` → implementation (line `core`, hands off), `llm-implementation` → implementation (line `llm`, no hand-off; the original tool's second channel), `document` → document, `review`, `baseline`, `task` (what `track` gives a launch, [below](#sessions-for-agents-gitrochi-starts)), `other` → other. Unknown kinds are kept as typed and have the role `other`. Known kinds are matched without case, spaces, `-`, `_` or `·`.
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
  wakeUntil?: Ms;             // its agent's Stop hook waits until then to wake it with a person's answer (wakeAgents)
}
interface LedgerEvent {
  id: number; sessionId: string; ts: Ms; type: string; actor: "agent" | "human" | "auto" | "hook";
  summary?: string; body?: string /* Markdown ≤ 60,000 characters */; version?: string;
  artifacts?: { name: string; ssot?: string; ver?: string; path?: string; note?: string; ssotInferred?: boolean }[];
  data?: Record<string, unknown>; channel?: string; deliveredAt?: Ms;
}
interface Question { id: number; sessionId: string; text: string; state: "open" | "answered" | "dismissed";
  options?: { label: string; description?: string; recommended?: boolean }[];
  multiSelect?: boolean; suggestedAnswer?: string;
  browserSourceUrl?: string; browserDraft?: string; // local browser observation, not a native prediction
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
  payload: Record<string, unknown>; createdAt: Ms; deadline: Ms /* 0: held for the person, no countdown */;
  state: "waiting" | "answered" | "auto" | "released" | "expired";
  answer?: Record<string, unknown>; answeredBy?: "human" | "auto"; answeredAt?: Ms; reviewedAt?: Ms }
interface Attention { questions: number; tidy: number; decide: number; autoReview: number;
  held: number /* waits held for the person; waits with a countdown are not counted */; total: number }
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
| `import` | `{text, project?}` | `{results: [{index, ok, duplicate, error?, sessionId?, event?, notices?}]}` — a duplicate is `ok` and skipped; imports have no agent recipient and never consume waiting answers or notes | app, agent |
| `import_legacy` | `{path, dryRun?}` | `{ok, dryRun, rev, counts: {projects, baselines, baselinesUpdated, sessions, events, questions, imports, workItems, notes, preservedRows}, skipped, errors}` ([below](#importing-a-claude-ledger-database)) | app, agent |
| `work` | `{action, project?, item?, bundle?, event?, date?, text?, refs?, …}` | Independent work items, dated history, reports and import results ([below](#work-documents-and-personal-records)) | app, agent |
| `documents` | `{action, project, id?, query?, roots?, root?, path?}` | Approved folders, source evidence, ID mentions, tasks, feedback and checksum changes | app, agent (folder changes and hold: app only) |
| `notebook` | `{action, id?, title?, body?, pinned?, expectedUpdatedAt?, query?}` | Personal notes, excluded from every agent output | app only |
| `records` | `{action: update \| delete \| version_note, sessionId?, project?, version?, …}` | Session metadata edits/deletion or a baseline note edit | app only |
| `scan` | `{project?}` | `{results: [{project, source, found, added, error?}]}` (forced, all projects without one) | app, agent |
| `register_baseline` | `{project, version, note?}` | `{ok, rev, project, version}` | app, agent |
| `backup` | `{daily?, keep?}` | `{path, created, size, removed}` | app, agent |
| `backups` | `{}` | `{directory, backups: [{path, name, size, modifiedAt, kind: "backup" \| "safety"}]}`, newest first ([below](#restoring-a-backup)) | app, agent |
| `insights` | `{project?, range?: "7d" \| "30d" \| "all"}` (default 7d; no project = all) | `{project?, range, from?, to, questions: {asked, answered, dismissed, resolvedByAgent, wait, open}, autoAnswers: {total, reviewed, corrected, unreviewed, byKind}, sessions: {total, byVerdict, byRole, stale, staleUnreported, unreported}, reports, reportsPerDay: [{day, reports}]}` ([below](#insights)) | app, agent |
| `release_notes` | `{project, version?}` (default HEAD; `latest`/`head` accepted) | `{project, version, previous?, releasedAt, releasedBy?, note?, versions, groups: [{role, title, sessions: [{id, title, kind, how: "merged" \| "absorbed", summary?, artifacts: [{name, ver?, path?}]}]}], markdown}` ([below](#release-notes)) | app, agent |
| `restore` | `{path, dryRun?}` | `{ok, dryRun, path, contents: {schema, rev, sessions, events}, safety?: {path, created, size, removed}, rev}` ([below](#restoring-a-backup)) | app |
| `settings` | `{}` | `{staleHours, kinds, autoContinue, backupKeep, wakeAgents}` with defaults | all |
| `projects` | `{}` | `{projects: [{key, name, repoPath?, baselineSource, baselinePattern, baselineDir?, scanFiles, scanSubdirs}]}` | app, agent |
| `human` | `{action, sessionId, …}` (below) | `{ok, rev}` | app only |
| `prompt_answer` | `{id, answer: {…}}` | `{ok, rev, state, prompt}` — `ok: false` when the prompt no longer waits | app only |
| `prompt_review` | `{id}` or `{all: true}` | `{ok, rev, reviewed}` | app only |
| `settings_set` | `{values: {key: value \| null}}` (null = default) | `{ok, rev, settings}` | app only |
| `project_set` | `{project, name?, repoPath?, baselineSource?, baselinePattern?, baselineDir?, scanFiles?, scanSubdirs?}` (null clears) | `{ok, rev, project}` | app only |
| `track` | `{project?, title?, base?, kind?, repoPath?, branch?, worktree?, agentId?, cwd?, autoContinue?}` | `{ok, rev, session}` ([below](#sessions-for-agents-gitrochi-starts)) | app only |
| `integration_command` | `{bundled?, create?, path?}` | `{path, exists, current, refreshed, held}` — the stable command ([below](#passive-external-observers)) | app only |
| `integration_status` | `{client, path?, config?, mcpConfig?}` | The `integrate --status` result ([`integration-status`](schema/integration-status.schema.json)) | app only |
| `integration_install` | `{client, bundled, path?, config?, mcpConfig?}` | The same, after installing hooks that run the stable command | app only |
| `integration_remove` | `{client, path?, config?, mcpConfig?}` | The same, after removing the client's owned hooks | app only |
| `hub_share` | `{client}` (4–32 letters, digits or `-`: the app's random name for this computer) | `{rev, sessions: [{sessionId, repo, client, presence}], unshared: [{sessionId, reason: "no_remote" \| "limit"}]}` ([below](#sharing-with-the-team-hub)); reads only | app only |
| `prompt_create` | `{kind, sessionId?, agentId?, payload?, delaySec? (30) \| deadline?}` | `{ok, rev, prompt}` | app, hook |
| `prompt_get` | `{id}` | `PendingPrompt` | app, hook |
| `prompt_resolve` | `{id, state: "auto" \| "released" \| "expired", answer? (auto), summary?}` | `{ok, rev, state, prompt}`; `auto` also records an `auto_reply` event | app, hook |
| `prompt_expire` | `{}` | `{ok, rev, expired}` — waiting prompts 10 minutes past their deadline (a wait held for the person has none) | app, hook |

Callers: **app** = the C ABI and the Tauri command (a person is at the controls); **agent** = the CLI's `call` and the MCP server; **hook** = the wave 2 hook handler. A method called by a caller it is not for answers `NOT_ALLOWED`; the caller comes from the entry point, never from the request.

### Report fields

`project` (needed for a new session), `session` (or `sessionId`; issued as `S<MMDD>-<nn>` in local time when absent; otherwise 3–48 letters of any script, digits, `.`, `_`, `-`), `event` (default `progress`), `kind`, `title`, `base`, `summary`, `body`, `question`, `questions` (a string is one question), `touches`, `related`, `artifacts` (list, one object, or names; `artifact` adds one), `version`, `into`, `absorbs`, `targets`, `resolves` (question numbers), `ssot`, `note` (release note), `chatUrl` (or `chat_url`; http(s) only), `work` (kept in `data.work`). Lists may be arrays, comma-separated text or one number. `latest`/`head` resolve to HEAD at that moment and are stored as the number. A version the trunk lacks is added as `inferred` and promoted when a scan or registration finds it. A non-start event on an unknown session creates it with an automatic start just before. A `start` with another title on an existing ID is a `CONFLICT`; with the same title it is recorded as `progress`.

`question` accepts text or `{text, options?, multiSelect?, suggestedAnswer?}`; `questions` accepts an array of those entries through MCP, and the CLI/import parser also preserves a single text or question object. Each option is a label string or `{label, description?, recommended?}`. Text and labels are normalized and trimmed, labels must be nonempty and distinct, booleans must be booleans, and suggestions must be text. Explicit `recommended` overrides inferred bracketed markers. Malformed structured entries reject the entire report without writing questions or advancing the revision. Existing plain-text lists remain valid. A question event supplied only with `questions` creates those questions without adding another from the summary.

Reported questions are the provider-neutral path for Claude and ChatGPT agents using the Ledger MCP tools or pasted reports. Options and suggestions survive storage and appear in app state and session detail. A person's selected or custom answer remains a text answer, queued for that session's next report/read and delivered once (or, with `wakeAgents` on, by a launched agent's waiting `Stop` hook; [Hooks](#hooks)). Reading through the apps never consumes it. This path neither controls a client's native question dialog nor reads or fills its native composer prediction. Answering or dismissing a question that is already settled returns `CONFLICT` and preserves the existing answer.

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

### Sessions for agents Gitrochi starts

With **Track agents I start** on, the app calls `track` before it starts an agent and passes the session's ID as `GITROCHI_LEDGER_SESSION` (DESIGN.md §7.11). The session is created active and unreported (no `lastAgentAt`), with an issued `S<MMDD>-<nn>` ID and one `hook` event, `data: {hook: "launch", agentId?, autoContinue?, head?}`; `head` is the commit `cwd` is on. What the app leaves out is filled in from the checkout:

- `branch`: what git says about `cwd` (a detached HEAD has no branch). `worktree`: the checkout's top folder when `cwd` is in a linked worktree; the main checkout is the repository itself and gets none.
- `project`: the project whose `repoPath` is `repoPath`, else the repository folder's name. A project that does not exist yet is created bound to `repoPath`, so its tags become its baselines. Paths compare without a trailing separator, with `~` expanded; a Windows path (on Windows, or one with a drive letter or a `\\server` share) also without case, with `\` and `/` alike.
- `title`: the branch, else the folder's name.
- `kind`: `task`, whose default role is `other`, so the session is on the Board and not a stream (decided 2026-11-03, DESIGN.md D14). The launch event then has `data.board: true`. A `kind` from the app is its explicit choice and has no such mark.
- `base`: the newest tag reachable from `cwd`'s HEAD that matches the project's pattern, when its baselines come from tags; `latest` is HEAD.
- `autoContinue`: the policy `autoContinue.repositories` keeps for `repoPath`; `null` follows the global default.

**Unreported launches (D13).** Until its agent reports, a quiet session turns `stale` only once its branch's tip is no longer `head`: a commit of its own, or a reset. While the tip is still `head` its verdict stays `active`, so it is not in `attention`; the apps show it under the Board's **Unreported** filter (no `lastAgentAt`). A launch on a detached HEAD compares its folder's HEAD instead. One `git for-each-ref` per repository answers for all of its launches. When git cannot tell (no `head` recorded, the folders are gone, the branch was deleted), it goes stale like any other session.

Until the agent reports, those values are Gitrochi's guess. The agent's first report replaces them: a `start` sets the title, kind and base it gives and is recorded as `start`, and a report naming another project moves the session there (its guessed base, from the other trunk, is dropped). After that report the usual rules hold, so another title on `start` or another project is a `CONFLICT` again.

**On the Board (D14).** On a session whose `launch` event has `data.board`, a reported kind with the implementation role is stored as `task` while the session does not have the implementation role; the event keeps the reported kind in `data.reportedKind`, and the reply has a notice when the stored kind changes or on `start`. Other kinds apply as reported. A person moves the session to Streams with `records` (`update` with an implementation kind), after which its agent's implementation kinds apply as reported, or maps `task` to the implementation role in `settings.kinds`. Sessions created before this rule have no mark and keep the earlier behaviour.

### Sharing with the team hub

`hub_share` builds what an app posts to the team hub (`services/hub`, `POST /api/v1/presence`) when a person turns on **Share this computer's Ledger sessions** (D4, opt-in, off by default). It only reads; the apps do the HTTP with the hub token they already keep in the system credential store. This method is the one definition of what leaves the computer, and `schema/hub-share.schema.json` closes every object in it.

- **Which sessions**: live and not streams — the sessions overlaps count ([Vocabulary](#vocabulary)) — most recently active first, at most 100 (`unshared` reason `limit` for the rest). A session needs a repository: the first of `links.repoPath`, `links.worktree`, `links.cwd` and its project's `repoPath` whose `origin` remote (else its first remote) gives a hub repository key; without one it is listed with reason `no_remote` and stays here. Keys are made as the hub's `repokey` makes them, so a user name or token in the remote URL never leaves the computer; they are read again after five minutes.
- **The body** (`presence`): `repo` (the key), `branch` (`links.branch`, else empty), `changed` (the touches that are repository-relative paths or identifiers — absolute, home and Windows paths, URLs, `..` and control characters are left out; at most 500), `related` (empty), `client` (`ledger/<client>/<session ID>`, one hub entry per session) and `ledger`: `session`, `project`, `title` (one line, at most 200 characters), `kind`, `role`, `verdict` and `lastActivity` (`lastAt` as RFC 3339 UTC, to the minute).
- **Never**: questions, answers, report summaries and bodies, messages, notes, the notebook, work and document records, artifacts, chat links, agent and Claude session IDs, folder paths, baselines and auto-continue policies.
- The hub computes overlaps between members from `changed`, as it does for the monitor; the apps read the session IDs of other computers' entries from their `client`. A hub older than the `ledger` field answers `400` for it; the apps then send the same body without `ledger`.

### Importing a claude-ledger database

`import_legacy` copies the database of the standalone claude-ledger tool (D5). `path` is the file, taken as given; `dryRun` counts without writing, for a preview. The file is never written: with nothing next to it, it is opened `immutable=1` (no locks, no files created); a `-wal`, `-shm` or `-journal` file next to it means the tool has it open or stopped mid-write, so it is opened `mode=ro` with SQLite's usual locking, which reads its newest committed data. Only these tables and columns are read — the compatibility surface — and a column an older file lacks reads as empty. Optional work and notebook tables are also read in the same snapshot, projected into their separate features and retained as original rows with provenance.

- `versions` (`project`, `version`, `ts`, `source`, `note`, `by_session`) → baselines. `scan` becomes `folder`, an unknown source `registered`. `by_session` is kept only for a session imported in the same run, because the same ID here may be another conversation and would misdirect hand-offs. A baseline the ledger already has keeps what it knows; an `inferred` one takes the file's source and time, and a missing releaser or note is filled in (`baselinesUpdated`).
- `sessions` (`id`, `project`, `kind`, `title`, `base_version`, `base_current`, `base_was_latest`, `status`, `merged_into`, `touches`, `related`, `chat_url`, `channel`, `color`, `created_ts`, `last_ts`, `ack_ts`, `snooze_ts`, `archived_ts`) → sessions. Kinds go through the alias table, unknown kinds are kept as typed. `snoozeUntil` is `snooze_ts` plus `staleHours`; `lastAgentAt` is the newest event its own agent sent (hand-off records from other sessions excluded); a chat link that is not http(s) is dropped.
- `events` (`session_id`, `ts`, `type`, `actor`, `summary`, `ssot`, `artifacts`, `data`, `channel`, `delivered_ts`) → events, in time order. The actor `claude` becomes `agent`; a person's `status` and `note` become `set_status` and `message`, so those still waiting are delivered once; `ssot` becomes `version`, `data.body` the `body`; the data keys `item`, `items`, `from_status` and `reopened_from` become `questionId`, `questionIds`, `fromStatus` and `reopenedFrom`, and the artifact key `ssot_inferred` becomes `ssotInferred`.
- `items` (`id`, `session_id`, `ts`, `text`, `state`, `answer`, `answered_by`, `answered_ts`, `delivered_ts`) → questions. `answered_by` `claude` becomes `resolvedBy: "agent"`. A question keeps its number where the ledger has it free, so an agent's `resolves` still finds it; the others are numbered after them and the events' references follow.
- `imports` (`hash`, `ts`) → import hashes, so pasted blocks the tool imported are duplicates here.
- Projects: a row per project name, with default settings (the tool keeps project settings outside its database).

A session whose ID the ledger already has is skipped with its events and questions and listed in `skipped`. Rows that cannot be read — an ID the ledger does not accept, an unknown status or question state, history that belongs to no session — are listed in `errors`, and the rest is imported. The copy is one write transaction; a dry run, or a file with nothing new, writes nothing and leaves `rev` alone, so a second import of the same file changes nothing.

### Restoring a backup

`backups` lists the files in `backups/` next to the database that `restore` is meant for: backups (`<name>-YYYYMMDD-HHMM.sqlite3`, kind `backup`) and the safety copies a restore keeps (`<name>-before-restore-YYYYMMDD-HHMMSS.sqlite3`, or with `-N` for a second one in the same second, kind `safety`). `modifiedAt` is the file's time from the file system. Retention (`backupKeep`) and `backup --daily` look only at backups, so a safety copy stays until a person removes it.

`restore` takes any file, as given:

1. It opens the file read-only, as `import_legacy` does (`immutable=1` with nothing next to it, else `mode=ro`), and runs `PRAGMA integrity_check`. A damaged file, one that is not a Ledger database (no storage schema, no `meta.rev`, no sessions or events tables) or the ledger's own file is `INVALID_ARGUMENT`; a storage schema newer than this build writes is `SCHEMA_MISMATCH`, and so is a live database a newer build wrote. Nothing has changed at that point. `dryRun` stops here and answers what the backup holds, without a `safety` entry.
2. It copies the backup into a private working file next to the backups, migrates that copy to this build's schema, and sets its `meta.rev` above both the backup's and the live ledger's.
3. It keeps the live database as a safety copy, with the online backup `backup` uses.
4. It copies the working file into the live database with SQLite's online backup API: one write transaction, so the apps, the CLI, MCP and hooks that have the file open keep their connections and see either the old ledger or the restored one; SQLite raises the schema cookie so they read the schema again. A writer that holds the lock past the busy timeout makes it fail with `DATABASE` and nothing restored (the safety copy stays).

The backup file is never written. Reports written between steps 3 and 4 are in neither file; agents that keep running report into the restored ledger, and a session the backup does not have comes back with its agent's next report that names the project (the usual rule for an unknown session). Restoring a safety copy undoes a restore. `rev` in the result is the new revision, so every poller reloads.

### Release notes

`release_notes` drafts notes for one baseline of a project's trunk (HEAD when `version` is absent; a version the trunk lacks is `NOT_FOUND`, and so is a project without baselines). It takes the project's sessions whose `mergedInto` is that version (`how: "merged"`) and those a `release` report of that version absorbed (`how: "absorbed"`, also when they were reopened since), whether archived or not.

- **Groups** follow the role of each session's kind, in the order decision, implementation, research, document, other; empty groups are left out. Within a group, sessions are ordered by kind, then creation.
- **Summary**: one line from the session's own agent: the newest `done` report, else the newest `decision`, else the newest `merged` (not the one another session's release wrote). The first non-empty line, spaces collapsed, at most 160 characters.
- **Artifacts**: every artifact its agent reported, the newest version of each name (`ver`, else `ssot`), with its path.
- `previous` is the baseline before it on the trunk, `releasedBy` the session whose release made it, `note` the baseline's note; `versions` lists the trunk newest first, for choosing another one.
- `markdown` is an English draft: a `# <project> <version>` title, a line with the date (local time), releaser and previous version, the note as a quote, then one `##` section per group with a bullet per session (its title in bold, its ID and, when it differs from the role, its kind, then the summary) and an `Artifacts:` line under it.

Only the baseline, sessions and agent events are read. Questions and their answers, a person's messages, set-status reasons, report bodies, notebook notes and work records never appear. It writes nothing.

### Insights

`insights` counts what happened in a period (`from` = now minus 7 or 30 days; none for `all`) for one project or all of them. It returns counts and durations only, never the text of a question, answer, report or note, and writes nothing.

- **Questions**: `asked` in the period; `answered` and `dismissed` in the period by a person (or auto-continue's earlier rules), with `wait` from asked to answered or dismissed; `resolvedByAgent`, closed by their own agent (`resolves`), is not a wait for a person. `open` is about now: the ages of the open questions of sessions that are not archived.
- A **spread** is `{count, medianMs?, p90Ms?, maxMs?}`: nearest-rank percentiles, absent without values.
- **Automatic answers**: pending prompts auto-continue answered in the period (`state: "auto"`), overall and per prompt kind. `reviewed` has `reviewedAt`; `corrected` is reviewed after a person's message to the session between the automatic answer and the review, which **Send correction…** sends; `unreviewed` still waits in the Inbox.
- **Sessions**: the sessions the Board shows for the period (not archived, or archived inside it), with every verdict and role present, zeros included; `stale` and `staleUnreported` (stale with no agent report), and `unreported`.
- **Reports**: agent events in the period, and per local day, oldest first with zero days included: 7, 30, or the last 90 days for `all`.

### Errors

`INVALID_ARGUMENT` (bad or missing input), `NOT_FOUND`, `CONFLICT` (a session ID with another title or project), `NOT_ALLOWED` (wrong caller), `DISABLED` (`GITROCHI_LEDGER=0`), `DATABASE`, `SCHEMA_MISMATCH`, `GIT_FAILED` (scans report it in their result instead).

## Entry points

- **C ABI** (macOS): `char *gitrochi_ledger_call(const char *method, const char *json)` and `void gitrochi_ledger_free(char *)` in [`include/gitrochi_ledger.h`](include/gitrochi_ledger.h). NULL `json` means `{}`; the result is never NULL; safe from several threads; panics become `DATABASE` errors. Linking it into `libgitrochi_core.a` is wave 2.
- **Windows**: one Tauri command `ledger_call(method: String, args: serde_json::Value) -> Result<serde_json::Value, String>` calling `gitrochi_ledger::call` (wave 2).
- **CLI** `gitrochi-ledger`: `report`, `overview`, `session`, `import`, `import-legacy <file> [--dry-run]`, `scan`, `register`, `backup`, `insights [-p <project>] [--range 7d|30d|all]`, `release-notes -p <project> [version]`, `restore <file> [--yes]` (a person at a terminal: without `--yes` it only checks the file), `demo <db> [--large]`, `call <method> [json]` (agent caller), `mcp`, `hook <event>` ([below](#hooks)). See the [README](README.md).
- **MCP** (`gitrochi-ledger mcp`): `ledger_overview`, `ledger_report`, `ledger_session`; delivery only for the caller's own session; no person's operations. Protocol versions as `tools/gitrochi-mcp`: `2025-11-25`, `2025-06-18`, `2024-11-05`.
- `GITROCHI_LEDGER_SESSION` is the default session of the CLI and the MCP tools (for agents Gitrochi launches).

## Auto-continue

The hook handler creates a `pending_prompts` row when an agent stops to ask (`prompt_create`, deadline = now + the delay), polls it (`prompt_get`), and closes it with `prompt_resolve`: `auto` when auto-continue answered (also an `auto_reply` event on the session, actor `auto`, `data: {promptId, kind, answer}`), `released` when it let go, `expired`. A person answers from the app with `prompt_answer`, which wins only while the prompt waits. Automatic answers count in `attention.autoReview` until `prompt_review`. The policy (what to answer, deny rules, hook outputs) belongs to `crates/gitrochi-autocontinue`; human answers are normalized and validated before the prompt closes. Auto-continue never answers Ledger questions and never acknowledges a session.

## Hooks

### Passive external observers

The CLI also has an independent opt-in path for local clients: `observe <claude|codex> EVENT` reads hook JSON from standard input. It does not call the auto-continue handler or broaden any API caller's permissions. `hook EVENT` keeps its existing launch-only behavior.

The observer atomically looks up or creates a session by the provider and client session ID in `links.observer`. A supplied `GITROCHI_LEDGER_SESSION` reuses that row; Claude's existing `links.agentSessionId` is also recognized. New rows have kind `other`, status `active`, a title of the provider and the checkout's branch (`Claude Code · feature/x`; the worktree or folder name for a detached checkout or outside a repository, also when the checkout cannot be read within 800 ms), `autoContinue.enabled: false`, and a launch `hook` event with `source: "external"` and no `board` mark. Existing rows retain their kind, status and auto-continue policy. The Board default for Gitrochi launches (D14) does not apply to them.

Allowed activity metadata is the client/session ID, event, tool name, tool-use ID, turn ID, subagent ID and the checkout context. Prompts, transcript paths/content, tool arguments/results and assistant output are ignored. These observations advance `lastAt` and append `hook` events; they never advance `lastAgentAt`, create questions or pending permission prompts, acknowledge, archive or change a session's status. `Stop` is a turn boundary, not task completion. Only actual agent reports establish reported progress and outcomes.

On `SessionStart` the handler may return bounded additional context naming the Ledger session ID and asking an available `ledger_report` tool to include it explicitly. No other event returns context or a decision. Invalid input, disabled Ledger, missing database, lock failure and unsupported events all end with exit 0. The observer opens existing databases only, with the hook lock budget.

`integrate <client> --install|--status|--remove [--cli FILE] [--config FILE]` manages passive callbacks in the user's `.claude/settings.json` or `.codex/hooks.json`. Installation is explicit, initializes the selected database if needed, uses a stable executable path, preserves unrelated keys and callbacks, backs up existing bytes privately and replaces the file atomically only if it has not changed meanwhile. Owned command callbacks carry `--managed-hook`; reinstalling replaces only those callbacks and removal deletes only that client's callbacks. Status/removal never initialize a database or missing settings file.

JSON status fields are `client`, `action`, `installed`, `configPath`, `cliPath`, `ownedHookCount`, `expectedHookCount`, `otherHookCount`, `backupPath`, `verification: "configuration_only"`, `requiresClientTrust` and `hooksDisabled`. Installed configuration does not prove execution, MCP registration or trust. Codex trust hashes, feature flags and all permission/auto-continue settings are outside this installer. Client settings, trust, disabled hooks and local/cloud execution determine coverage.

Connection fields ([`integration-status`](schema/integration-status.schema.json)) say whether the configuration can still deliver. `hookCommand` is the executable the owned callbacks run, parsed from their commands (the worst one when they differ); `mcp` is `{configPath, registered, command}` for the client's user-level entry named `gitrochi-ledger` (Claude Code `~/.claude.json` `mcpServers`, Codex `~/.codex/config.toml` `[mcp_servers]`, or `--mcp-config FILE`), read only. Each command is `{path, exists, executable, writesSchema, version, canWrite, dbPath, sameDatabase}`: `writesSchema` and `version` come from the executable's own `call info` run with `GITROCHI_LEDGER=0` (which never opens a database) and a three-second limit; `canWrite` compares `writesSchema` with `databaseSchema`, this database's `PRAGMA user_version` read through a read-only connection; `dbPath` is its `--db` (for MCP, the entry's `GITROCHI_LEDGER_DB` or the per-user default). Unknown values are null. `lastObservedAt` is the newest `observer` event and `lastReportAt` the newest `lastAgentAt` of sessions whose `links.observer.client` is the client. `health` is the most urgent of `missing_command`, `outdated_command`, `other_database`, then `incomplete` (owned callbacks missing for some events), `no_data_yet` (hooks installed, nothing observed or reported) and `ok`; `not_installed` when neither hooks nor an MCP entry exist. MCP reports carry no client, so an MCP-only connection is `ok` rather than `no_data_yet`. Checking never creates, migrates or writes a file.

**The stable command.** Hooks and MCP entries the apps set up name one stable copy of the ledger command instead of the one inside the app, which moves with the app and changes with every update: macOS `~/Library/Application Support/Gitrochi/bin/gitrochi-ledger`, Windows `%APPDATA%\Gitrochi\bin\gitrochi-ledger.exe` (`path` overrides it for tests). `integration_command` replaces that copy with the app's `bundled` command whenever their bytes differ, through a new file renamed over the old one (on Windows a running copy is renamed aside first), and reports `{path, exists, current, refreshed, held}`. Without `create` it never makes a missing copy; the apps call it so when the Ledger opens. With a database newer than the app (`held`), an existing copy is kept, so an older app never puts back a command that cannot write. `integration_install` creates or refreshes the copy (a person chose Set up or Repair) and installs hooks with it as `--cli`; `integration_status` and `integration_remove` are the CLI's `--status` and `--remove` for that command. No method edits a client's MCP settings.

`gitrochi-ledger hook <event>` handles the Claude Code hooks the apps add to the sessions they launch while **Track agents I start** is on: `SessionStart`, `UserPromptSubmit`, `Stop`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure` and `SessionEnd`. It is the `hook` caller, and Claude Code passes it the hook input as JSON on stdin (DESIGN.md §7.11, §9). Its session is `GITROCHI_LEDGER_SESSION`. An agent Gitrochi did not launch has no such session, and for it the handler does nothing. It only opens a database that already exists, never creating one, and waits at most one second for a lock.

- **Activity.**
  - `SessionStart`, `UserPromptSubmit`, `Stop` and `SessionEnd` move `lastAt` forward. They never touch `lastAgentAt` or a status.
  - `SessionStart` and `UserPromptSubmit` set `links.agentSessionId` to the input's `session_id`. A new ID is also recorded as a `hook` event, `data: {hook, agentSessionId, previous?, source?}`, so every ID the conversation had can still be found.
  - `SessionEnd` records a `hook` event with `data: {hook: "SessionEnd", reason?, agentSessionId?}`.
  - Nothing else from the input is stored: no prompt text and no tool input.
- **Pending prompts.** A stop question, an `AskUserQuestion`, an `ExitPlanMode` (when its setting is on) or a permission request becomes a `PendingPrompt`.
  - Its payload is `gitrochi-autocontinue`'s `PromptPayload`, and its deadline is now plus the delay. A permission prompt's payload also has `call: {key, agent?}`: a hash of the tool and what it acts on (the command, the file, the URL or the query, else the whole input), and the subagent it came from. `PermissionRequest` input has no `tool_use_id`, so this is how the call is recognised later.
  - Each structured question carries `question`, `header?`, `multiSelect`, `options: [{label, description?, recommended}]` and optional `suggestedAnswer`. Explicit recommendation booleans take precedence over label/description markers. A suggestion is an editable draft for the person, never an automatically selected free-text reply. The apps may fill it with Tab without submitting it; it is not a native client's composer prediction.
  - A well-formed `AskUserQuestion` with a question that has no options still waits on the live hook. Its payload has `autoAnswer: false`, a positive deadline, no `hold`, and an empty proposed answers map. The person can supply custom text for every question. At the deadline the hook releases the prompt without a decision or `auto_reply`; the terminal then asks. This manual wait counts in `attention.held` and never toward the automatic-answer limit. Missing `autoAnswer` means true for existing payloads.
  - The handler reads the prompt every 250 ms. It keeps the earlier of the stored deadline and its own, so the app can bring an answer forward but never push it past the hook's timeout.
  - At the deadline it resolves the prompt `auto`. The answer is the `AutoReply`, which also goes into the `auto_reply` event. The output is printed only if that write succeeded.
  - **A permission answer starts out unconfirmed.** The terminal shows its own dialog while the hook waits, and a decision sent after the person answered there is ignored (Claude Code 2.1.309, issue #171). So at the deadline the prompt becomes `auto` with `answer.outcome: "unconfirmed"`, and it has no `auto_reply` event yet. A `PostToolUse` or `PostToolUseFailure` for the same call settles it, judged by when the call started (now minus `duration_ms`):
    - It started before the answer went out, so the person's terminal answer applied. The prompt becomes `answered` by `human` with no answer, and nothing automatic is recorded.
    - It started after, so the automatic answer applied. `outcome` becomes `confirmed`, and the `auto_reply` event is recorded, dated when the answer went out.
    - There is no `duration_ms`, or nothing ran by the time the main agent's turn ended, the person typed, or the conversation started over or ended. `outcome` becomes `unknown`, and the `auto_reply` event is recorded with it.
- **Who settles a prompt.**
  - The person in the app, with `prompt_answer`:
    - `{text}` wakes a stop question with that text.
    - `{answers: {question: text}}` answers an `AskUserQuestion`; each answer may be a selected label, ordered comma-separated labels for multi-select, or custom text. Every known question must have a nonempty string answer, and unknown question keys are refused. Legacy `{text}` is normalized to this map only for a single question. The original tool input, including its questions and unrelated fields, is echoed with the answer map added.
    - `{decision: "allow" | "deny", message?}` decides a permission request or a plan.
    - `{release: true}` (answer in the terminal) and `{hold: true}` (not this time) end the hook without a decision. Invalid, empty, incomplete or incompatible answers return `INVALID_ARGUMENT` before changing the row or revision, so the person can correct them. Substantive replies to held terminal-only prompts are refused. If an answer loses a race with release or automatic resolution, `ok` is false and the earlier result is preserved.
  - The person typing in the terminal: a `UserPromptSubmit` with their own prompt marks waiting stop questions `answered` by `human`, and stores no answer. It also releases the session's other waiting prompts; a hook that Esc interrupted never closes its own. A prompt that Claude Code submitted itself only releases the stop questions. That includes a prompt starting with `<task-notification>`, which is how the wake-up of an automatic Stop answer arrives.
  - The person answering a permission dialog in the terminal:
    - The call running while the hook waits (`PostToolUse`, `PostToolUseFailure`) marks the prompt `answered` by `human`.
    - So does the same agent moving on while the hook waits: another `PermissionRequest`, a `PreToolUse`, another call running, or, for the main agent, its `Stop`. A No in the terminal leaves no other trace; `PermissionDenied` fires only for auto mode's own denials.
    - The hook still waiting then sends nothing.
  - Later events release what the conversation waited on before: a newer `Stop`, a `PreToolUse` or `PermissionRequest` of the main agent (one without `agent_id`), and every `SessionStart` and `SessionEnd`. A late automatic answer then never lands in the middle of other work.
  - The app's heartbeat stopping during a synchronous wait releases that prompt.
- **When nothing waits.** In these cases the hook ends at once with no decision, and no prompt is stored:
  - auto-continue is off for the session (the global `autoContinue` setting, with the session's own `enabled` and `delaySec` on top);
  - the session has the decision role;
  - the trigger for this kind of prompt is off;
  - the hook is synchronous and the app is not running (`app.alive`, next to the database, was last modified 15 s ago or more; D10). The app sets the file's modification time every 5 s while its **Track agents I start** switch is on: rewriting an empty file does not change it on Windows;
  - the turn did not end with a question;
  - `stop_hook_active` is set and there has been no automatic answer since the person's last input.
- **Waits held for the person.** With auto-continue on, some waits are never answered automatically: a request that is never auto-allowed, a risky question or plan, an `AskUserQuestion` without unique nonempty question texts, and anything past the limit in a row (a stop question only when the turn asked one). The hook still ends at once with no decision, so the terminal asks, but it stores a waiting prompt the apps can show and notify about:
  - `deadline` is 0 (no countdown), and `prompt_expire` leaves it alone.
  - Its payload has the `PromptPayload` keys for what is asked, no `proposed`, `call` (as for permission prompts), and `hold`: why, as `gitrochi-autocontinue`'s pass (`code`: `held` with `rule` and `detail`, `risky` with `kind` and `reason`, `no_answer`, `limit_reached` with `consecutive` and `max`) plus an English `message`.
  - It is settled like the other waits: the person's answer in the terminal (the call running, or the same agent going on, for a permission request; the `AskUserQuestion` or `ExitPlanMode` call running, or the agent going on, for a question or plan; their own prompt for a stop question) marks it `answered` by `human`. Their prompt otherwise, and SessionStart and SessionEnd, release it.
  - It never counts toward the limit in a row. Like other waits it is in `state.pendingPrompts`, and unlike waits with a countdown, which resolve themselves, it counts in `attention.held` and so in `total`: the agent waits in its terminal for the person.
  - `hold.message` is English. The apps show their own translated line for each `hold.code`, and the message only for a code they do not know.
  - No hook waits on it, so an answer from the app (`prompt_answer`) does not reach the agent: the apps send the person to the terminal.
- **In a row** counts the session's `auto_reply` events since the person's last input, plus the prompts that may still become one (waiting with a countdown, or permission answers still unconfirmed); `stop_hook_active` looks at the automatic answers alone. Events count by when they happened. The person's last input is the latest of:
  - a `hook` event with `data.person`, written when they type in the terminal;
  - any of their actions on the session in the app, except `link`;
  - a prompt they answered.
- **Waking a waiting agent** (`wakeAgents.enabled`, off by default; DESIGN.md §7.6). After the rest of `Stop` sent nothing, the hook goes on waiting, in the background, until `waitSec` after the `Stop`:
  - The `Stop` write stores a claim in `meta` under `wake:<session>`: `{token, until}`, replacing an older one. With the setting off it deletes the key instead, so an older wait ends. `SessionStart`, every `UserPromptSubmit` and `SessionEnd` delete it too.
  - The hook reads `rev` every 250 ms; when it moved, it checks its claim (gone or another token: it ends; a stored `until` can only bring the end forward), the setting (off: it ends) and the session's undelivered answers, dismissals and `message`s. With any, one write checks the claim again, delivers everything waiting (`deliver`, the same delivery as a report, status changes included), deletes the claim and exits 2 with `[Gitrochi] From a person to this session (act on these):` and the messages, one per line, on stderr. At `until` it deletes its claim and exits 0.
  - When the stop question's own wait sent an answer (exit 2), the claim is deleted and nothing else is sent.
  - `state` and `session` carry the claim as `Session.wakeUntil` while `until` is ahead.
- **Never in the way.** Without a decision, the hook exits 0 with no output. The Stop answer is exit 2 with the text on stderr. Any failure is exit 0, no decision and one line on stderr: input that is not a JSON object, a missing database, a lock held for more than a second, or a database with a newer schema.

## Browser extension boundary

The companion `gitrochi-ledger-browser` is a separate Chrome native-messaging entry point. It uses native-endian u32 byte lengths followed by UTF-8 JSON, a 65,536-byte request cap and a 1 MiB response cap. It validates Chrome's caller origin against its installed, exact extension allowlist and reloads that configuration on every request. Removing registration or changing its database invalidates previous bindings.

`browser_status`, `browser_install {extensionId, hostPath}` and `browser_remove` are **App-only** methods. Their result is `{installed, hostName, manifestPath, extensionId?, hostPath?, hostExists?, lastDataAt}`: `hostExists` is false for a registration whose host program moved or was deleted (then `installed` is false and the extension ID is kept for a repair), and `lastDataAt` is when the newest browser-captured question arrived, or null. The CLI exposes the equivalent explicit `browser-host install --extension-id ID [--host-path FILE]`, `browser-host status` and `browser-host remove`. The installer registers only the per-user Chrome host and refuses unrelated manifests or registry entries.

Native requests have `{version:1, id:string, op, ...fields}`. Replies have `{version:1, id, ok:true, data}` or `{version:1, id, ok:false, error}`. Operations are limited to:

| Operation | Fields and effect |
|---|---|
| `hello` | Returns `questionCapture:true`, `composerPredictions:false` and the host name. |
| `targets` | Bounded project and active-session summaries; no reports, answers or transcripts. |
| `bind` | `{conversationUrl, project, sessionId?}` creates a connection-scoped binding. An omitted session explicitly creates a browser session; an existing target must be active in the selected project. |
| `capture` | `{bindingId, sourceKey, question}` stores a normalized question and its source. The existing report/delivery dispatcher is never called. |
| `draft` | `{bindingId, sourceKey, text}` updates only the separate browser draft of the still-open captured question. Whitespace is preserved. |
| `unbind` | `{bindingId}` removes that port's binding. |

A binding pins the caller, database, canonical ChatGPT conversation and target session generation. Session insert/delete triggers allocate a durable, never-reused generation and remove the previous capture mapping, including when a session ID and creation timestamp are reused or SQLite replaces a row. The host checks the generation inside each capture/draft write transaction. Page-supplied method names, database paths and target overrides are rejected. Source deduplication is atomic by extension/conversation/session/message ID: an exact duplicate changes no revision; a settled question is not reopened, and changed content is reported for review without replacing the original question.

`browserSourceUrl` and `browserDraft` appear only on captured questions. The latter means text observed after a user accepted a browser draft with Tab; it is neither a model's `suggestedAnswer` nor an unaccepted native composer prediction. Apps label it separately and preserve existing edits. Answers and dismissals for these questions are excluded from agent message delivery; normal questions retain their existing delivery behavior.

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

12. Method `import_legacy` (D5, wave 2) with the schema `legacy-import` and the CLI command `import-legacy`.

Narrowed on purpose (the original tool was wider):

13. `applied` hands off only from implementation sessions on a hand-off line; from any other session it records the version and confirms nothing.
14. A person's `shelve` (and `set_status` shelved) is limited to research and document roles, like the agent's `shelved`.

Added for the hook handler (wave 2):

15. The CLI command `hook <event>` ([Hooks](#hooks)). `lastAt` also moves with a launched agent's hook activity, as DESIGN.md §6.1 and §7.11 describe; `lastAgentAt` stays the agent's own reports. `hook` events carry `data.hook` and the fields above. The handler moves waiting prompts to `answered` (the person answered in the terminal: `answeredBy: "human"`, no `answer`) and to `released`. A permission prompt's payload has `call`; its automatic answer has `outcome` (`unconfirmed`, `confirmed`, `unknown`), and its `auto_reply` event waits for the outcome.

Added for launch tracking (wave 2):

16. The app method `track` ([above](#sessions-for-agents-gitrochi-starts)) and its `hook` event `launch`. A `start` on a session `track` created, before its agent's first report, takes the agent's title, base and project instead of answering `CONFLICT` (DESIGN.md §7.2). The `autoContinue` setting may hold `repositories`. The launch event's `data.head` holds the commit the agent starts on, and an unreported launch turns `stale` only once its branch has moved on from it (D13). `links.worktree` is filled in for a linked worktree only, and Windows paths match whatever their case and separators.

Added for the apps' notifications (wave 2):

17. Waits held for the person ([Hooks](#hooks)): a waiting prompt with `deadline` 0 and `payload.hold`, which `prompt_expire` leaves alone and the limit in a row does not count. Before, these waits stored nothing. `Attention` gains `held`, their count, which `total` includes.

Added for opt-in local client activity:

18. Passive `observe` and reversible `integrate` CLI commands for Claude Code and Codex. External session bindings live in `links.observer`; observations are `hook` events and do not claim agent reports or change task status. Existing `hook EVENT`, app-launch tracking defaults and API caller permissions are unchanged.

19. Browser observation: optional `Question.browserSourceUrl` and `browserDraft`, storage schema 8, App-only host registration and the separate scoped native protocol above. Browser answers remain local and do not change normal agent delivery.

20. Connection health on the `integrate` status: `hookCommand`, `mcp`, `databaseSchema`, `lastObservedAt`, `lastReportAt` and `health`, the schema `integration-status`, and the CLI option `--mcp-config`. Existing status fields keep their meaning.

21. The stable command and the App-only methods `integration_command`, `integration_status`, `integration_install` and `integration_remove`.

22. `browser_status`, `browser_install` and `browser_remove` add `hostExists` and `lastDataAt`, for the apps' Connections list.

23. New observed sessions are titled `<client> · <branch>` instead of `<client>: <folder>`. Existing titles are not changed, and a `start` report still replaces an unreported observed session's title.

Requests for later waves: live `implementation` sessions are streams by contract, so agents Gitrochi launches with that kind would stay out of overlaps and clean-up until a person closes them. Settled by 24 below.

24. Launched agents on the Board (DESIGN.md D14, decided 2026-11-03): `track` without `kind` stores `task`, a new default kind with the role `other`, and marks its `launch` event `data.board: true`; an implementation kind its agent reports is stored as `task` with `data.reportedKind` on the event ([Sessions for agents Gitrochi starts](#sessions-for-agents-gitrochi-starts)). The maintainer approved this change of launch behaviour; sessions launched before it keep theirs.

Added for waking waiting agents:

25. The global setting `wakeAgents` (`{enabled, waitSec}`), `Session.wakeUntil` and the `meta` rows `wake:<session>` ([Hooks](#hooks)). With the setting off nothing changes; no storage schema change.

Added for team hub sharing (D4, opt-in, 2026-11-03):

26. The app method `hub_share` ([above](#sharing-with-the-team-hub)) and the schema `hub-share`. It reads only: no storage schema change, no new setting in the database (the switch is the app's own), and nothing changes while it is off.

Added for restoring backups:

27. Restoring a backup: the methods `backups` (app, agent) and `restore` (app only), the CLI command `restore`, safety copies named `<name>-before-restore-…` that retention leaves alone, and the schemas `backups` and `restore`. `backup` and its file names are unchanged.

Added for release notes:

28. Release notes: the method `release_notes` (app, agent), the CLI command `release-notes` and the schema `release-notes`.

Added for insights:

29. Insights: the method `insights` (app, agent), the CLI command `insights` and the schema `insights`.


## Work, documents and personal records

These additive methods share the same database transaction and caller boundaries. Database schema 7 adds separate tables; existing sessions and the API schema version stay compatible. Older executables refuse to write a newer database.

`work` supports `add_bundle`, `add_item`, `event`, `list`, `detail`, `report`, `unassigned`, `import` and `note`. Writes name a project. Work IDs are stable `W-<group>-<number>` identifiers; they cannot be reused. Items hold title, expected output, scope, bundle and optional stem/split origin. Dates are calendar dates in `YYYY-MM-DD`; a leading `~` marks an estimate. Events include registration, start, progress, completion, frozen/held/resumed/cancelled, plan (conservative/slack dates), issue, transfer, bundle completion/reopen, skipped session reports, stem, item metadata correction, text/date correction, move and issue carry. Corrections retain before/after history. Completion guards keep unfinished work out of completed bundles. `report` returns Markdown and can filter bundle, stem and dates, with optional evidence references. `report.work` links the new session event atomically; unknown or other-project item IDs roll the whole report back. `unassigned` excludes linked or skipped session events. Person-authored work notes are delivered once to an agent write or an explicit `deliver` read, never consumed by an app read. Fenced `work` imports process each line independently and preserve the original canonical duplicate hashes. A mixed `ledger`/`work` paste returns per-record results.

`documents` supports `roots`, `set_roots`, `scan`, `list`, `search`, `lookup`, `worklist`, `backflow` and `hold`. A person selects at most 16 absolute folders; agents cannot select or expand them. Scans read bounded Markdown/text files under those roots, reject symlinks and changed file identities, and remove unavailable source evidence. A result contains `files`, `ids`, `entries` with relative `path` and `line`, `relatedSessions`, truncation information and optionally a source excerpt. Markdown checkboxes, ID definitions/mentions and section labels become generic evidence; no team's private file formats are embedded. Held checksums expose changed sources. Source files are never modified. Explicit AI summaries run in the app through its configured AI service, not in the core or MCP. Their bounded evidence includes source references and is treated as data. No request runs from opening, scanning or selecting documents.

`notebook` supports `list`, `get`, `save`, `delete`. Notes have integer `id`, title, Markdown body, pinned flag and creation/update timestamps. Every existing save/delete requires the exact `expectedUpdatedAt`; mismatches return `CONFLICT` without changing the note, and timestamps advance monotonically. Only app callers can reach this method. Notes never appear in session search, state, overview, reports, MCP or the HTTP bridge.

`records` changes human-maintained session metadata or baseline notes, and offers confirmed session deletion in the apps. It is absent from MCP and the HTTP bridge. Status, confirmation and question-answer flows remain under `human`.

The opt-in CLI `serve` bridge accepts only literal loopback bindings, validates Host/Origin, rejects cross-site requests and bounds request headers, bodies and connection workers. It exposes reporting and approved evidence reads using legacy JSON adapters. It cannot choose a database from request data or expose notebook, human operations, settings or local files. This compatibility mode is experimental; native apps continue to use C ABI/Tauri directly. See [migration guide](../../docs/ledger/MIGRATION.md) for supported endpoints and client setup.

Document summaries are cached in the database under the current source checksum key. Only an explicit app AI request can save one; stale or revoked evidence rejects a late response. Monthly usage reports completed saved requests and input/output character counts, not billed tokens or prices. The app and the optional reporting bridge check the existing daily backup operation hourly while running and retry failed checks after five minutes.
