# Flows (gitch flow)

A flow assembles a repository's **tests, checks, services, remote CI and deployment steps like blocks**, and runs them **the same way** from the app's Flows tab, from `gitch flow`, before a push and in CI. The flow engine (`gitch-flow`, Rust) always makes the verdict; the apps and gitch only send the actions a person takes and show the results.

- **Composable**: nodes (commands, blocks, suites, sub-flows) form a graph joined by `needs`. Composite blocks (`.gitch/blocks/*.yml`), sub-flows and `matrix` combinations build on each other.
- **No false passes**: exit code 0 alone is not trusted. A report must exist (T2), tests must actually have run (T3, zero is a failure), and the exit code must agree with the report (X1). A verdict that cannot be made counts as a failure.
- **Any repository**: `gitch flow init` reads the project's files only and proposes a flow file from the test tools, package managers and runtime versions it finds.
- **Efficient**: only the tests affected by the change (affected selection), no rerun for the same inputs (result cache), parallelism with locks and weights, installs skipped while the lock file is unchanged, a one-line summary for AI agents.
- **Docker and remote CI**: run in containers (`executor: docker:<image>`), service containers and compose, and drive GitLab, GitHub, Jenkins and plain HTTP CI.
- **Rollback and production guard**: undo steps are registered before anything changes and run in reverse on failure or cancel; if a rollback fails, the environment is put on hold. Destructive blocks are refused in production-class environments by default.

> The design and decisions are in [DESIGN.md](DESIGN.md); what is tested and how far, in [../flow-validation.md](../flow-validation.md).

## Quick start

```bash
gitch flow init            # what was detected and the proposal (writes nothing)
gitch flow init --yes      # write .gitch/flow.yml (never overwrites one)
gitch flow trust           # a person reviews and approves the commands (in a terminal only; AI agents cannot)
gitch flow run pre-push    # run a flow
gitch test --affected      # only the affected tests, ad hoc
gitch flow gate on         # check the pre-push flow before every push (no rerun when the same commit passed)
gitch flow export github   # propose a workflow that runs the same flow in CI
```

In the app it is the sidebar's **Flows** tab: the flows, ▶ to run, live progress, failure locations (file:line), rollback, copying a summary and turning on the pre-push check. Without a flow file, **Set up flows…** shows the proposal and creates the file.

## The flow file

`.gitch/flow.yml` is a safe subset of YAML: anchors, aliases, tags and multiple documents are errors. Files overlay in the order `flow.yml` ⊕ `flows/*.yml` ⊕ the uncommitted `flow.local.yml` (init adds it to `.gitignore`). Unknown keys are errors (keys starting with `x-` are allowed). Schema: `gitch schema flow`.

```yaml
version: 1
project: { name: shop }
defaults: { timeout: 15m, env: [CI, TZ] }      # env: the host variables passed on to nodes (allow list)

environments:
  local:   { class: dev }
  sandbox: { class: sandbox, executor: "docker:node:22-bookworm" }
  prod:    { class: prod }                     # destructive blocks are refused with GUARD-01 unless user settings allow them

services:
  db:   { use: docker.service, with: { image: "postgres:16-alpine", ports: ["5432"], env: { POSTGRES_PASSWORD: test }, health: { cmd: "pg_isready -U postgres" } } }
  api:  { use: process.service, needs: [db], with: { run: "npm start", ready: { http: "${{ services.api.url }}/health" } } }
  pay:  { use: mock.http }                     # .gitch/mocks/pay/routes.yml

suites:
  unit:
    use: test.vitest
    select: { affected: true }                 # with --affected, only the tests the change affects
    expect: { minTests: 1, passRate: 1.0 }
    retry: { max: 1, flaky: warn }             # passing on a retry is flaky (by default flaky also fails)
  smoke: { use: check.http, tags: [smoke], with: { url: "${{ services.api.url }}/health" } }

flows:
  pre-push:
    trigger: [manual, pre-push]
    failFast: true
    nodes:
      install: { use: setup.node }
      lint: npm run lint                       # a string is a run node
      unit: { needs: [install], suite: unit }
      api-smoke: { needs: [unit], suite: smoke, services: [api] }
  deploy:
    env: sandbox
    rollback: { scope: flow, onCheckFailure: true, timeout: 10m }
    notify: [{ on: failure, webhook: team-hook }]
    nodes:
      image: { use: docker.build }
      push: { needs: [image], use: docker.push, with: { image: "${{ nodes.image.outputs.image }}" } }
      web: { needs: [push], use: deploy.compose, with: { project: shop, service: web, image: "${{ nodes.image.outputs.image }}", health: { url: "http://127.0.0.1:8080/health" } } }
      smoke: { needs: [web], suite: smoke }
```

### Nodes

A node is one of `run` (a shell command, short for the `cmd` block), `use` (a block), `suite` or `flow` (a sub-flow), with these keys:

| Key | Meaning |
|---|---|
| `needs` | Nodes that must finish first. A sub-flow, composite block or matrix name stands for all of its members |
| `if` | `success()`, `failure()`, `always()`, `cancelled()`, `changed('glob')` with `&&`, `\|\|` and `!` |
| `with` · `env` · `secrets` | Block inputs, environment, secrets (`secrets: { TOKEN: deploy-token }`: names only, the engine finds the values) |
| `services` | Services to start before this node (once, when first needed, and always stopped when the run ends) |
| `executor` | `local` (default) or `docker:<image>`: shell commands (`cmd`, `test.*`) run in a container |
| `timeout` · `retry` · `expect` | Time limit, retries, verdict expectations (`exit`, `output`, `minTests`, `passRate`) |
| `cache` | `{ inputs: [glob] }`: replay an earlier pass for the same inputs (pure nodes only; network, Docker and remote nodes are never cached) |
| `locks` · `weight` · `optional` | Named locks, parallel slot weight, a failure that does not fail the flow |
| `on-failure` | Nodes that run only when this node fails (collecting logs, say) |
| `undo` | A run node's undo step (`"script"` or `{ run, check, timeout, always }`); see Rollback below |
| `matrix` | `{ node: [20, 22] }` → one node per combination (`unit/node-20`), read with `${{ matrix.node }}` (at most 64) |
| `shell` · `cwd` · `description` | `bash` (default; Git Bash on Windows), `sh`, `pwsh` or `cmd`; working folder; description |

Expressions `${{ … }}` only **reference values**: `git.sha`, `git.short`, `git.branch`, `run.id`, `node.out`, `inputs.X`, `services.S.host|port|url`, `env.X` (allow list only), `matrix.X`, `nodes.N.outputs.X`, `project.name`. Values that go into `run` and `undo` are shell-quoted by the engine (no injection), and `secrets` cannot be used in `run` or `with` (only through `env` and `secrets:`).

### Verdict rules

| Rule | What it looks at | Failure codes |
|---|---|---|
| E1 | Exit code (`expect.exit`), timeout, cancel, hung process | EXEC-01 to 05 |
| T1 · T2 · T3 · X1 | Pass rate, report present (written by this run only), executed count (0 = failure), exit code agrees with the report | TEST-01 to 06 |
| S1 to S4 · O1 | Response, build identity, log line, log line that must not appear, output | VERIFY-01 to 04 |
| C1 | The remote CI's result contract (CI's own success or failure is only a hint) | CI-02 · CI-03 |
| M1 to M3 · V1 · G3 · G4 · D1 | Mock server calls, runtime version, gitch checks, dependency rules, compare-then-replace | VERIFY-01 · SETUP-01 · GITCH-01/02 · DEPLOY-01 |

A verdict that cannot be made (INDETERMINATE) counts as a failure. What a failure code means and what to do: `gitch flow explain <code>` (all of them: `gitch flow explain`).

## Efficiency

- **Affected selection** `--affected[=base|worktree|staged]`: when a dependency or configuration file changes (`package.json`, lock files, `tsconfig*`, `Cargo.toml`, `.gitch/**` …) everything runs; otherwise the changed tests, naming conventions (`math.ts` → `math.test.ts`) and the dependency graph from `gitch graph affected`. The plan records why each test was picked or left out (no candidates ≠ no tests needed; `alwaysRun` and the `smoke` tag always run). `if: changed('glob')` uses the same base.
- **Result cache**: a node with `cache: { inputs: [...] }` replays its pass when block, inputs, environment, selection, matrix values, executor and input file contents are unchanged (`--no-cache` turns it off).
- **Setup blocks** `setup.*`: the install is skipped while the lock file, install command and executor match the last success and the install folder still exists (`force: true`).
- **Parallelism** `--jobs N` (default: logical CPUs), `weight` and `locks`. `gitch flow watch <flow>` reruns only what a save affects.
- **For AI agents** `--summary` prints one deterministic line plus failure locations (`FLOW=FAILED flow=… nodes=… failed=…`). Reports: `gitch flow report <run> --format md|junit|html`.

## Services and test environments

| Block | What it does |
|---|---|
| `process.service` | A background process (given `$PORT`) with a readiness check (`ready: { http · port · log }`) |
| `docker.service` · `compose.up` | One container (health check, ports) or a compose file (`--wait`), on the run's own network, cleaned up by the `gitch.flow.run` label only |
| `mock.http` | A deterministic fake HTTP server inside the engine: `routes` (`json`, `body`, `file`) and named **fault switches** (`delay`, `status`, `drop`), from `.gitch/mocks/<service>/routes.yml` or `with` |
| `mock.fault` · `check.mock` | Turn faults on and off within a flow; check the expected calls (`count`, `min`, `max`, `contains`) and requests missing from the table |
| `fixture.seed` | Puts in test data and removes it (by default at the end of every run; with `keep: true` only on failure or cancel) |
| `check.http` · `check.port` · `check.version` · `check.log` | The basics of a smoke test: response, body, JSON fields, ports, build identity, service log lines |
| `gate.manual` · `gate.window` | A person's approval (exit code 2 when not interactive); blocked and allowed time windows (time zone required, refused early by the expected start time) |
| `gitch.preflight` · `gitch.graph.check` | gitch's check before commit and push; dependency rules |
| `notify.webhook` · `notify.desktop` · a flow's `notify:` | Notifications; a failure to send never changes the result |

The full list with inputs: `gitch flow blocks` and `gitch flow block <ID>`.

## Docker

- `executor: docker:<image>` (on a node or an environment): one labelled `--rm` container per node. **The repository and the run folder are mounted at the same path**, so report paths and `GITCH_FLOW_OUT` are the same inside and out; environment values pass by name only (`-e NAME`, so secrets never appear on a command line). Host-only variables (`PATH`, `HOME` …) are not passed, and services are reachable by network alias (container services) or `host.docker.internal` (host processes). On Linux the container runs with `--user`, so files stay owned by you. With the same image as CI, local equals CI.
- `docker.run` (a one-off container; exit code 125 is told apart as docker's own failure), `docker.build` (tag `<project>:<short sha>`, a revision label, build arguments by name only; `null` takes the secret from the node environment) and `docker.push` (an outward action that outputs the digest).
- When Docker is down, only that node is refused with `DOCKER-01`; the rest runs as planned. `GITCH_DOCKER` picks another CLI than `docker` (podman and the like).

## Remote CI

```bash
gitch flow connect add gitlab --name company --url https://gitlab.example.com --allow 'pipeline:*'
gitch flow connect add jenkins --name ci --url https://jenkins.example.com --user bot --secret-from env:JENKINS_TOKEN
gitch flow connect test company
```

Connections live outside the repository (`~/.config/gitsw/flow/connections.json`); tokens come only from the OS secret store, environment variables (`env:`), the app's accounts (`app:`) or gh (`gh:`). Blocks: `ci.gitlab.pipeline`, `ci.gitlab.job` (▶ a manual job), `ci.github.workflow`, `ci.jenkins.job` and `ci.http` (trigger and status URLs with JSON pointers).

Every adapter follows the same rules. It puts a **correlation ID** (`gitch-<run>-<node>`) into the run title, variables or parameters; **looks before sending**; **never resends a trigger whose response was lost** (if it cannot find the run, CI-01: outcome unknown); waits within the deadline and cancels remotely on deadline or cancel (CI-05); treats a cancel it did not ask for as external (CI-04); honours rate limits (`Retry-After`); and never sends credentials on a redirect to another host. The verdict comes from the **result contract**: in CI, `gitch flow run <flow> --ci` leaves `gitch-flow-out/gitch-flow-result.json` and a log marker line `GITCH-FLOW-RESULT {…}`, and the adapter reads the artifact, then the marker, then (when both are missing) the CI's own test report. `gitch flow export github|gitlab|jenkins` proposes such CI files, and `gitch flow import` proposes a flow from existing CI files.

## Rollback and production guard

- A block registers its undo step **right before it changes** the target (also in the run folder's `undo.ndjson`). A run node uses `undo:`: `migrate: { run: "npm run db:migrate", undo: "npm run db:rollback" }`. A change that fails midway may still be partial, so the undo step always runs and must be **safe even when nothing changed**.
- On failure or cancel the steps run in reverse, **before** the services stop. Scope `node` (default) undoes only what the failed node changed; `flow` undoes every node that changed something (after a failed check node, which changes nothing, only with `onCheckFailure: true`); a cancel undoes everything. `check:` verifies a step after it runs, and `rollback.timeout` is the budget. A step with `always: true` is cleanup that runs at the end whatever the result.
- **When a rollback fails** the run ends as `ROLLBACK_FAILED` and the environment goes on hold: until it is released, new runs there are refused with `GUARD-02`. A person checks the state and runs `gitch flow hold release <environment>` (AI agents cannot). A run whose engine was killed is closed by the next run: with traces of changes it is held without undoing anything, otherwise it closes with `EXEC-06`.
- `deploy.compose` replaces the image of one compose service (on this machine, or on a remote Docker over SSH with `host:`): observe the current image → compare with `expectCurrent` before replacing (DEPLOY-01) → pull → tag the current image for rollback → restart → check that the new image runs and is healthy. On failure it switches back to the tagged image and checks again. Database schemas are not rolled back (forward only).
- Destructive blocks in a production-class environment (`class: prod`) run only when user settings (`allowProd` in `~/.config/gitsw/flow/settings.json`) name that repository and environment. An environment class a block does not allow gives `GUARD-03`.

## Trust, AI agents and secrets

- A flow file is code, so it runs unattended only **when its hash matches one a person reviewed and approved** (`TRUST-01`). The records live outside the repository in `~/.config/gitsw/flow/trust/`; a changed file asks again. A CI runner is the exception with `--ci` and `CI=true` (never for an AI actor).
- AI agents (Claude Code, Codex, Cursor, Gemini) can plan, run and read flows, but **cannot approve trust, release a hold or switch the gate**, and skipping a manual approval with `--yes` needs the user's confirmation (gitch guard).
- Secrets are looked up in this order: values the app passed on stdin → `GITCH_SECRET_<name>` → (in CI) the environment variable of that name → the OS secret store. The values found, plus URL credentials, token prefixes, JWTs, high-entropy strings and home paths, are masked in events, logs and reports.
- Run records (`<git common dir>/gitch/flow/runs/<worktree>/<run>/`) are signed by the engine with HMAC, and the gate trusts only signed records.

## Commands

```
gitch flow init|validate|list|plan|run|rerun|watch|status|events|logs|report|cancel|explain|blocks|block
gitch flow trust|hold|gate|connect|export|import|doctor|gc|schema
gitch test [suite|tag …] [--affected] [--watch] [--summary]
gitch ci status|logs|report            # this repository's remote CI (what the app's CI/CD tab does)
```

`--json` is for machines (schemas: `gitch schema flow-plan|flow-run|flow-event|flow-report|flow-error`), `--events` streams NDJSON events, and `--detach` runs in the background and returns the run ID and events file. Exit codes: 0 passed · 1 failed · 2 a person must confirm.
