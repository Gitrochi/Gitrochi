# Flow design

[README.md](README.md) explains how to use flows; this document explains **why they are built this way** and the contracts they keep. What has been verified is in [../flow-validation.md](../flow-validation.md).

## Structure

```
 Apps (macOS SwiftUI · Windows Tauri)     gitch (bash front door)            CI runner
   Flows tab · trust prompt · run view    gitch flow · gitch test            gitch flow run <flow> --ci
   turn on the pre-push check             pre-push hook · FLOW line in preflight
        │  CLI + JSON / NDJSON                │ exec                              │
        └──────────────► gitch-flow (Rust executable, tools/gitch-flow) ◄─────────┘
                  spec → plan → (preflight) → run → verdict → rollback → record (signed)
                  blocks: cmd · test.* · check.* · setup.* · docker.* · deploy.* · ci.* · mock · fixture · gate · gitch · notify
```

- **The engine is the only judge.** The apps and gitch send the actions a person takes and show the JSON the engine writes; they never judge. The same flow gives the same result in the app, in a terminal, before a push and in CI (local = CI).
- **The app ↔ engine contract**: `--json` for `list`, `plan`, `status`, `report`, `init` and `gate`; `run --detach --json` (run ID and events file), then following `events.ndjson`; errors as the envelope `{"schemaVersion":1,"error":{…}}` on stderr. The schemas are in `tools/gitch-flow/schema/` and come out with `gitch schema flow*`. On macOS, `macos/Tools/test-flow.sh` reads the real engine's output with the app's models; on Windows, unit tests and the self-test cover reading events.
- **Run records**: `<git common dir>/gitch/flow/runs/<worktree id>/<run id>/` holds `run.json` (HMAC-signed), `plan.json`, `events.ndjson`, `logs/`, `reports/`, `out/<node>/` and `undo.ndjson`. Records are kept per worktree, so agents in different worktrees never mix.

## States and verdicts

- Nodes: `PENDING → RUNNING → PASSED | FAILED | INDETERMINATE`, plus `SKIPPED · CACHED · REJECTED · CANCELLED`. Runs: `PENDING → PREFLIGHT → RUNNING → SUCCEEDED | FAILED | CANCELLED | REJECTED`, and when something changed, `FAILED | CANCELLED → ROLLING_BACK → ROLLED_BACK | ROLLBACK_FAILED`. The allowed transitions live in one table; any other transition is recorded as an engine violation.
- **Flow preflight**: before anything changes, every node's preconditions are observed (connections, allow lists, blocked time windows at the expected start time, held environments). If any fails, the run is `REJECTED` and nothing has changed. Something that blocks only one node, like Docker being down, rejects that node only; the rest runs as planned.
- **Verdicts are pure functions of observations** (`verify.rs`): the exit code is one observation among several, and a verdict that cannot be made counts as a failure. Zero tests executed, a report written before this run, and an exit code that contradicts the report are never a pass.

## Efficiency

- Affected selection is "everything when unsure": changed dependency or configuration files, files that cannot be resolved statically, and runners that cannot take a file list all mean the whole suite runs, with the reason in the plan.
- The cache is for **pure nodes only** (inputs declared; no services, network, Docker, remote calls or outward actions). Its key covers the block version, inputs, environment, selection, matrix values, executor, input file contents, engine version and OS.
- A detached run (`--detach`) finishes even if the app quits; the app only follows the files. A run whose engine was killed is closed by the next run (held, without touching the target, when it left traces of changes).

## Safety

- **Trust**: a flow file runs unattended only after a person has approved its hash. The records live outside the repository, so whoever changes the repository (AI agents included) cannot forge an approval, and gitch guard keeps AI agents from editing that folder.
- **AI actors**: the actor is identified by the same rules as gitch (Claude Code, Codex, Cursor, Gemini …). AI agents cannot approve trust, release a hold or switch the gate, and never get the CI exception. The apps identify a person's actions with `GITSW_ACTOR=gitrochi-app`.
- **Injection and secrets**: values that go into `run` and `undo` are shell-quoted; secrets pass only through `env` and `secrets:` and enter the masking dictionary at that moment. Containers get environment values by name only. HTTP follows redirects by hand, drops every credential header when the origin changes and refuses https → http (the library drops only `Authorization` and `Cookie`, which would leak headers such as `PRIVATE-TOKEN`).
- **Production guard and rollback**: destructive blocks are refused in production-class environments unless user settings allow them. Undo steps are registered before anything changes; when a rollback fails, the environment is put on hold for a person to check. The engine never retries a rollback on its own.
- **Processes**: process groups on Unix and Job Objects on Windows end grandchildren together with their parent. After the stop signal and a grace period a process counts as hung (EXEC-03) and is killed. No console windows open on Windows.

## Concepts carried over from earlier work

These ideas come, in general form, from earlier work on a block- and flow-based operations tool (no code was copied): a failure while preparing = refused (nothing changed) and a failure while changing = rolled back; `mutates ⇒ undo`; rollback scopes node and flow with a switch for rolling back on a failed check; a failed rollback = the environment on hold; checking blocked time windows ahead by the expected start time; the rules for driving remote CI (correlation IDs, look first, never resend a POST whose response was lost, CI's conclusion is only a hint, the last marker line wins); deterministic fake servers with fault switches; the masking order. What changed on the way: support for Jenkins, GitLab and GitHub from the start instead of one remote engine; small capability-based blocks instead of one large target interface; a DAG instead of a straight line; events written to the file first and sent afterwards, instead of the other way round; a required time zone instead of a fixed one. Organization-specific deployment strategies and verdict rules belong in a private block pack outside this public repository.

## Decisions

Each decision is a **working default** chosen when the work started. The maintainer asked for everything to be built, so it is implemented this way; each item still waits for confirmation. To change one, change this table and the code together.

| # | Topic | Working default | Status |
|---|---|---|---|
| D1 | Engine language | One Rust executable (`tools/gitch-flow`): three systems, bundled with the apps, statically linked on Linux | Working default, awaiting confirmation |
| D2 | cargo in the macOS build | Optional for development builds (without it, no engine); required for releases (universal) | Working default, awaiting confirmation |
| D3 | Flow files | `.gitch/flow.yml` ⊕ `flows/*.yml` ⊕ `flow.local.yml`; composite blocks in `.gitch/blocks/`; quarantine in `.gitch/flaky.yml` | Working default, awaiting confirmation |
| D4 | Where run records live | Per worktree under the git common dir | Working default, awaiting confirmation |
| D5 | App ↔ engine | CLI + JSON/NDJSON; after `--detach`, follow the events file | Working default, awaiting confirmation |
| D6 | Editing flows | Native screens per platform. For now the flow file (text) plus the apps' run, trust and proposal screens (a visual editor is a later step) | Working default, awaiting confirmation |
| D7 | Pre-push gate | Off by default (per repository with `gitch flow gate on`, or in the app) | Working default, awaiting confirmation |
| D8 | Remote CI order | GitLab and GitHub → Jenkins → plain HTTP | Working default, awaiting confirmation |
| D9 | Organization-specific blocks | A private block pack outside the public repository (existing in-house consoles stay) | Working default, awaiting confirmation |
| D10 | Writing results to pull and merge requests | Off | Working default, awaiting confirmation |
| D11 | Linux | CLI only (engine + gitch) | Working default, awaiting confirmation |
| D12 | Remote cache and remote runners | Out of scope | Working default, awaiting confirmation |
| D13 | Flow schemas | Separate from gitch's schemas; `gitch schema flow*` hands off to the engine | Working default, awaiting confirmation |
| D14 | App accounts and hosting model | Unchanged (github.com, self-hosted GitLab); engine connections take an API address | Working default, awaiting confirmation |
| D15 | The apps' existing CI code | Left as it is (moving it into the engine is a proposal for after measuring) | Working default, awaiting confirmation |

## Where the code is

| What | Where |
|---|---|
| Engine | `tools/gitch-flow/src/`: `spec`, `plan`, `run`, `rollback`, `verify`, `blocks/`, `ci/`, `services`, `docker`, `executor`, `mock`, `affected`, `cache`, `store`, `trust`, `mask` |
| Engine tests | `tools/gitch-flow/tests/`: the executable in a temporary repository and HOME (a fake docker CLI; fake GitLab, GitHub, Jenkins and HTTP CI servers; real Docker in `real_docker.rs`) |
| gitch front door | `flow_cmd`, `hook_flow_gate` and the guard rules in `tools/gitch/gitch`; tests in `tools/gitch/tests/test_flow.sh` |
| macOS app | `macos/Sources/Core/FlowModels.swift`, `Services/FlowEngine.swift`, `Store/FlowStore.swift`, `Views/Sidebar/FlowPanel.swift`, `Views/Sheets/FlowSheets.swift` |
| Windows app | `windows/src/entities/flow/`, `windows/src/widgets/sidebar/ui/FlowPanel.tsx` |
| Build and release | `tools/gitch-flow/build.sh`, `macos/build.sh`, `windows/src-tauri/tauri.windows.conf.json`, `.github/workflows/flow.yml` |
