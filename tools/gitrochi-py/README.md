# gitrochi-py

Gitrochi's Python layer: **AI code review**, **repository analysis**, **test automation** and **runtime management** of deployed apps and of Gitrochi's own services. Rust owns the data — the repository index (`crates/gitrochi-index`, SQLite) and the flow engine (`tools/gitch-flow`, test and CI execution) — and this package orchestrates on top of them. Git is always the system `git`.

- Standard library only; Python 3.9 or later (macOS ships 3.9; CI also runs 3.13).
- Every command prints human text by default and one JSON document with `--json`.
- Exit codes: `0` success, `1` failure or findings above the threshold, `2` usage error. With `--json`, errors are `{"schemaVersion": 1, "tool": "gitrochi-py", "command": "error", "error": {"code", "message", "details"}}` on stdout.

```sh
python3 tools/gitrochi-py/gitrochi-py --help           # launcher, no install needed
PYTHONPATH=tools/gitrochi-py python3 -m gitrochi --help  # or as a module
```

| Command | What it does |
| --- | --- |
| `review` | AI code review of a change, plus local checks that run without AI |
| `analyze` | Hotspots, change coupling, ownership and bus factor, knowledge-loss risk, weekly trends, large-commit outliers |
| `test plan` · `test run` | The tests a change needs and why; runs them (or delegates to gitch-flow) |
| `test history` · `flaky` · `slow` · `trends` | Test history: flaky tests, slowest tests, failure rates by week |
| `runtime check` · `up` · `down` · `status` · `restart` · `logs` · `deploy` | A supervisor for services from `gitrochi-runtime.json`, with blue/green deploys |

## The repository index

The index is `<git common dir>/gitrochi/index.sqlite3` (shared by all worktrees), written only by Rust. This package reaches it in two ways, following `crates/gitrochi-index/README.md`:

1. The `gitrochi-index` executable (`file`, `coupled`, `impact`, `owners`, `sync`): found through `--index-bin`, then `GITROCHI_INDEX_BIN`, then `PATH`, then `crates/target/release/gitrochi-index` of the repository (or of this checkout). A setting that points at a missing file is reported and not replaced by another binary.
2. The SQLite file itself, opened **read-only** (`file:…?mode=ro`) after checking `PRAGMA user_version = 1`. Used by `analyze` and as the fallback when the executable is missing; co-change confidence is `cochange.commits / path_stats.coupling_commits` and Jaccard `shared / (a + b − shared)`, as the index defines them. Full-text search is never read directly (it needs the C++ tokenizer); use `gitrochi-index search`.

Everything degrades gracefully: without the executable the database is read directly, and without a database the commands run without index context and say so in `notes`. `--index-db FILE` (or `GITROCHI_INDEX_DB`) picks another database, `--no-index` or `GITROCHI_INDEX=0` (the apps' switch) turns the index off; explicit `--index-bin`/`--index-db` flags win over the switch. `analyze --sync` runs `gitrochi-index sync` first.

## review

```sh
gitrochi-py review                          # merge-base with the default branch ... HEAD, text report
gitrochi-py review --staged --no-ai         # local checks only, on the staged changes
gitrochi-py review --worktree --format markdown --out review.md
gitrochi-py review --base origin/main --format sarif --out review.sarif --fail-on error   # CI
gitrochi-py review --provider compatible --model qwen2.5-coder --base-url http://localhost:11434/v1
```

1. **Collect** the change with `git diff --no-ext-diff --no-color --no-textconv -M --src-prefix=a/ --dst-prefix=b/` (default range: merge-base of the default branch and HEAD; `--base`/`--head`; `--staged`; `--worktree` includes untracked files) and parse it into files, hunks and numbered lines.
2. **Local checks** (always, also with `--no-ai`): co-change partners missing from the change (`gitrochi-index impact`), very large diffs and files, binary files, added TODO/FIXME, debug statements (`breakpoint()`, `debugger`, `dbg!`, `console.log` …), merge-conflict markers, probable secrets, deleted test files, lock-file-only changes and lock files changed without their manifest.
3. **Chunk**: binary, deleted, lock, generated/vendored and `--exclude GLOB` files are left out of the AI review (and listed); the rest is split per file and hunk under `--max-chunk-bytes` (48 KB) and `--max-diff-bytes` (400 KB in total; docs go last), with oversized hunks truncated and marked.
4. **Review** chunks in parallel (`--jobs 4`, a bounded thread pool). Each prompt carries index context for its files: change frequency and last change, main authors (**names only**, never emails), and co-change partners that are missing from the change. The diff shows new-side line numbers, so findings map to the new side; the model's paths and lines are validated and moved to the nearest changed line when needed (`lineAdjusted`).
5. **Synthesis**: one more call merges duplicates, drops likely false positives, corrects severities and writes the summary and verdict. It may only keep or drop findings it was given (by id), never invent new ones. If it fails, the chunk findings are kept.

Findings are `{file, line, endLine, severity: error|warning|info, category, message, suggestion, source: ai|local, rule}`. Model output is parsed tolerantly (code fences, prose around JSON, trailing commas, a reply cut off by the token limit keeps its complete findings). `--format text|markdown|json|sarif`; SARIF is 2.1.0 with relative URIs, rule metadata and `partialFingerprints`, and every result has a location (change-wide findings point at the first changed line), as GitHub code scanning expects. `--fail-on error` (default) / `warning` / `never`; a review whose every AI request failed also exits 1.

### Providers

| `--provider` | Request | Key (first found) | Default model |
| --- | --- | --- | --- |
| `anthropic` (default) | `POST /v1/messages`, streamed, `anthropic-version: 2026-10-21`, adaptive thinking, `output_config.effort` (`--effort`, default `high`), and the app's server-side refusal fallback (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`; not for Haiku) | `ANTHROPIC_API_KEY`, `GITROCHI_AI_KEY`, Keychain/Credential Manager `ai:anthropic` | `claude-opus-5-5` |
| `openai` | `POST /chat/completions` | `OPENAI_API_KEY`, `GITROCHI_AI_KEY`, `ai:openai` | `gpt-5` |
| `compatible` | `POST {base}/chat/completions` (Ollama, LM Studio, OpenRouter …), key optional | `GITROCHI_AI_KEY`, `ai:compatible` | — (`--model` required) |
| `gemini` | `POST /v1beta/models/{model}:generateContent` (JSON response type) | `GEMINI_API_KEY`, `GITROCHI_AI_KEY`, `ai:gemini` | `gemini-2.5-flash` |

The request bodies mirror `macos/Sources/Services/AI.swift`. Requests are retried with exponential backoff and jitter on 429, 408, 409, 5xx and 529 and on network errors (`--retries 3`, `Retry-After` honoured), time out per read (`--timeout 300`), never follow redirects, and bypass proxies only for loopback servers. A refusal (`stop_reason: refusal`) is reported, not retried.

**Keys** come from an explicit environment variable first, then the OS store the apps already use: macOS `security find-generic-password -s com.ensnif.Gitrochi -a ai:<provider> -w` (the system may ask to allow access), Windows `CredReadW` on the generic credential `ai:<provider>.Gitrochi` (UTF-16, as keyring v3 writes it). `--no-keychain` or `GITROCHI_NO_KEYCHAIN=1` skips the OS store (CI).

## analyze

```sh
gitrochi-py analyze                                  # all sections, text
gitrochi-py analyze --since 90d --prefix src/ --top 20 --format markdown
gitrochi-py analyze --sync --format html --out analysis.html
gitrochi-py analyze --only hotspots,knowledge-loss --json
```

| Section | Definition |
| --- | --- |
| `hotspots` | Σ over changes of `0.5^(age / half-life) × (1 + ln(1 + lines))` (`--half-life 90` days); files missing from HEAD are left out (`--include-deleted`) |
| `coupling` | Connected components of file pairs with ≥ `--min-coupling 3` shared commits and Jaccard ≥ `--min-jaccard 0.3` (the `cochange` table; recomputed for the window with `--since`) |
| `ownership` | Per folder (`--depth 1`): main authors, shares and bus factor (fewest authors with at least half of the commits) |
| `knowledgeLoss` | Files whose main author and at least half of their commits come from authors inactive for `--inactive-days 180` |
| `trends` | Commits, churn and active authors per ISO week (`--weeks 26`), least-squares slope, last 4 weeks vs the 4 before |
| `outliers` | Commits whose size is a robust outlier: `0.6745 × (x − median) / MAD` of `ln(1 + lines)` ≥ `--outlier-z 3.5` |

`--format text|json|markdown|html`. The HTML report is one offline file: a Content-Security-Policy of `default-src 'none'` with a hash for its only stylesheet, no scripts, no external resources, every value escaped. `--now` fixes the reference time for reproducible reports.

## test

```sh
gitrochi-py test plan                       # what to run for this change, and why
gitrochi-py test plan --base origin/main --json > plan.json
gitrochi-py test run                        # run the plan
gitrochi-py test run --all --rerun-failures 2 --jobs 4
gitrochi-py test run --plan plan.json --timeout 600
gitrochi-py test flaky --since 30d --fail   # exit 1 when flaky tests exist
```

**Plan.** The changed files (since the merge-base, including uncommitted and untracked work unless `--committed-only` or `--head`) become ranked candidates; evidence is combined as `1 − Π(1 − score)`:

- `changed`: the test file itself changed (1.0);
- `naming`: `foo.ts` ↔ `foo.test.ts`/`foo.spec.ts`/`__tests__/foo.ts`, `Foo.swift` ↔ `FooTests.swift`, `foo.py` ↔ `test_foo.py`/`foo_test.py`, `foo.go` ↔ `foo_test.go` (and the rest of its package), Rust `src/x.rs` with `#[cfg(test)]` and the crate's `tests/`, Java/Kotlin `FooTest`; mirrored folders (`src/a/x.py` ↔ `tests/a/test_x.py`) score a little lower;
- `cochange`: source and test changed together before (`gitrochi-index coupled`), score = confidence (at most 0.9);
- `graph`: the test depends on changed code according to `gitch graph affected --json` (`--no-graph` to skip; `--gitch-bin`, `GITCH`, `PATH`, `tools/gitch/gitch`).

Changes to dependency or configuration files (`package.json`, lock files, `Cargo.toml`, `go.mod`, `pyproject.toml`, `.gitch/**` …) set `runAll`. Candidates below `--min-score 0.3` are listed but not run. No candidates does not mean no tests are needed; the plan says so.

**Run.** When `.gitch/flow.yml` exists, `test run` delegates to the flow engine: `gitch-flow test --json [--affected]` (`--flow-bin`, `GITCH_FLOW`, `PATH`, `tools/gitch-flow/target/release`, or `gitch flow`), whose run summary (flow-run v1) and per-suite report files become the result. Trust, approvals and the verdict stay with gitch-flow: an untrusted flow file fails with its code and asks a person to run `gitch flow trust`. `--no-flow` uses the built-in runners instead:

| Runner | Command | Results from |
| --- | --- | --- |
| pytest (when installed and used by the project) | `python -m pytest --junitxml` | JUnit XML |
| unittest | `pyunit.py` (this package) | JUnit XML, one case per test |
| go | `go test -json -count=1 -run '^(TestA|TestB)$' ./pkg` | `go test -json` events |
| cargo | `cargo test --manifest-path … [--test t] [--lib -- module::]` | libtest lines |
| vitest / jest | `npx --no-install vitest run --reporter=junit` / `jest --ci --json` | JUnit XML / jest JSON |
| swift | `swift test --parallel --xunit-output [--filter]` | xUnit XML |

Suites run in parallel (`--jobs 2`) in their own process groups with a timeout each (`--timeout 900`; the whole group is stopped). Exit code 0 alone is not trusted: a suite passes only when tests ran and none failed. `--rerun-failures N` reruns only the failing tests; a test that passes on a rerun is **flaky** (`--flaky warn|fail`). `--dry-run` prints the commands.

**History** lives in `<git common dir>/gitrochi/tests.sqlite3` (owned by this package; `--history-db` to override, `--no-history` to skip). Each run stores the commit, branch and a tree key (the HEAD tree, plus a hash of the uncommitted changes when the worktree is dirty) and every attempt of every test. `test flaky` flags tests that passed and failed on the same tree, or whose results flip often (`--min-runs 3`, `--min-flip-rate 0.2`); `test slow` lists average/p95/max durations; `test trends` gives weekly run and test failure rates and the most failing tests.

## runtime

```sh
gitrochi-py runtime check                    # runtimes and commands vs requirements
gitrochi-py runtime up                       # start the supervisor in the background
gitrochi-py runtime up --foreground hub      # supervise in this terminal (Ctrl-C / SIGTERM stops everything)
gitrochi-py runtime status --json
gitrochi-py runtime restart hub
gitrochi-py runtime logs hub -n 100 --follow
gitrochi-py runtime deploy web --version 1.4.2
gitrochi-py runtime down                     # stop the supervisor and every service
```

`gitrochi-runtime.json` (found in `--repo` or the repository root, or `--manifest`):

```json
{
  "version": 1,
  "requires": {"git": ">=2.30", "python3": ">=3.9"},
  "services": {
    "hub": {
      "command": ["gitrochi-hub", "serve", "--listen", "127.0.0.1:${PORT}", "--log-format", "json"],
      "port": 7420,
      "env": {"GITROCHI_HUB_DATA": "${STATE_DIR}/hub-data"},
      "health": {"http": "http://127.0.0.1:${PORT}/healthz", "interval": 10, "timeout": 3, "retries": 3, "startPeriod": 2},
      "restart": {"policy": "on-failure", "maxRestarts": 5, "window": 300, "backoff": {"initial": 1, "max": 60, "factor": 2}},
      "log": {"file": "logs/hub.log", "maxBytes": 10485760, "keep": 5},
      "stopTimeout": 30
    },
    "monitor": {
      "command": ["gitrochi-hub", "monitor", "--config", "monitor.json"],
      "passEnv": ["GITROCHI_HUB_TOKEN"],
      "health": {"http": "http://127.0.0.1:7421/healthz"}
    },
    "index-sync": {"command": ["gitrochi-index", "--repo", ".", "sync"], "every": 600},
    "web": {
      "command": ["node", "server.js"],
      "cwd": "${RELEASE_DIR}",
      "requires": {"node": ">=20"},
      "health": {"http": "http://127.0.0.1:${PORT}/health", "interval": 2},
      "deploy": {"slots": {"blue": 8080, "green": 8081}, "release": "releases/${VERSION}", "healthTimeout": 60}
    }
  }
}
```

- `command` is an argv list; strings may use `${PORT}`, `${SERVICE}`, `${VERSION}`, `${RELEASE_DIR}`, `${SLOT}`, `${STATE_DIR}` and `${MANIFEST_DIR}` (anything else is an error). `cwd` is relative to the manifest.
- **No secrets in the manifest.** `env` holds plain settings; a key named like a secret or a value that looks like one is refused. `passEnv` names variables copied from the supervisor's environment. A service sees only a small base environment (`PATH`, `HOME`, locale, temp …), its `env`, its `passEnv`, and `PORT`/`VERSION`/`RELEASE_DIR`/`SLOT`/`GITROCHI_SERVICE`.
- `health`: exactly one of `http` (2xx/3xx; proxies bypassed), `tcp` (`host:port`) or `command` (exit 0). After `startPeriod`, `retries` consecutive failures count as a failure of the service.
- `restart.policy`: `always`, `on-failure` (non-zero exit or failed health) or `never`. At most `maxRestarts` within `window` seconds, with exponential backoff; then the service is `failed`. `every: N` makes a periodic job (run, wait N seconds, run again).
- `log`: output goes through `pump.py` into `<state>/logs/<service>.log`, rotated by size (`maxBytes`, `keep` old files).
- `requires` (top level and per service): minimum versions as `>=1.22`, `>=3.9,<4`, `^20`, `~1.2`; `runtime check` compares them with `git`, `python3`, `node`, `cargo`, `go`, `docker` or any tool answering `--version`, and checks that each service's executable exists.

**Supervisor.** `runtime up` starts `runtime up --foreground` detached; state lives in `<git common dir>/gitrochi/runtime/<manifest id>/` (or `stateDir` in the manifest, or `--state-dir`): `supervisor.json`, `services/<name>.json`, `logs/`, `deploy/` and `control/` (requests from `restart` and `down <service>`). Each service runs in its own process group; stopping sends SIGTERM to the group, then SIGKILL after `stopTimeout`. SIGTERM, SIGINT or SIGHUP to the supervisor stops every service and removes its pid file. `runtime down` without a supervisor stops process groups left behind in the state files.

**Blue/green deploys** on one host: `runtime deploy SERVICE --version V` finds the release folder (`release` template), starts it on the slot that is not serving (`slots`, the port becomes `${PORT}`), waits until it is healthy (`healthTimeout`, `--health-timeout`), switches `deploy/<service>.json` and the `deploy/<service>/current` symlink, stops the old release, and checks the new one once more. If the new release never becomes healthy it is stopped and the old one keeps serving (`rolled_back`, exit 1); if it fails right after the switch, the old release is started again and the switch is undone. A running supervisor follows the current release and restarts it on its slot if it dies. Put a proxy (or DNS) in front of the two ports; switching traffic between them is outside this tool.

## Configuration

Optional JSON settings: the user's file (`~/.config/gitrochi/gitrochi-py.json`, `%APPDATA%\Gitrochi\gitrochi-py.json`, or `GITROCHI_PY_CONFIG`; `--config` for review) overlaid by the repository's `.gitrochi/gitrochi-py.json`:

```json
{"review": {"provider": "anthropic", "model": "claude-opus-5-5", "effort": "high", "jobs": 4, "failOn": "error",
            "maxDiffBytes": 400000, "maxChunkBytes": 48000, "exclude": ["docs/**", "*.snap"],
            "instructions": ["Pay extra attention to SQL injection."], "baseUrl": "http://localhost:11434/v1"}}
```

Command-line flags win over settings. `instructions` are appended to the system prompt like the app's own rules. **`baseUrl` is honoured only from your own file, `--base-url` or `GITROCHI_AI_BASE_URL`**: a repository must not be able to send your key to another server. A settings file that contains anything that looks like a key or token is refused.

| Variable | Meaning |
| --- | --- |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GITROCHI_AI_KEY` | AI keys (before the Keychain / Credential Manager) |
| `GITROCHI_AI_BASE_URL` | AI server address |
| `GITROCHI_NO_KEYCHAIN=1` | never read the OS credential store |
| `GITROCHI_INDEX_BIN`, `GITROCHI_INDEX_DB`, `GITROCHI_INDEX=0` | index executable, database, off switch |
| `GITCH`, `GITCH_FLOW` | gitch and gitch-flow executables |
| `GITROCHI_DEBUG=1` | print a traceback on internal errors |

## Security notes

- Keys are read only from the environment or the OS credential store, are sent only in request headers to the provider you chose, and never appear in output, logs, history or error messages (errors are built from the status code and a redacted excerpt; anything that looks like a secret is masked in every error message).
- Before anything is sent to an AI provider, diffs, commit subjects and index notes are redacted (private keys, provider tokens, AWS keys, JWTs, URL credentials, `password = "…"` assignments, high-entropy strings); the review counts redactions. Author emails are never sent.
- The prompt marks the diff as untrusted data; the model's findings are validated against the diff, and synthesis can only keep or drop them.
- The Rust index database is opened read-only; this package writes only `tests.sqlite3` and the runtime state folder.
- `runtime` and `test run` execute commands from the repository (manifest, test suites) like any build tool: review them as code. Flow files keep gitch-flow's trust rules.

## JSON output

All documents start with `{"schemaVersion": 1, "tool": "gitrochi-py", "version", "command"}`.

- `review`: `range{mode,base,baseRef,mergeBase,head,headRef}`, `stats{files,additions,deletions,chunks,reviewedFiles,skippedFiles,bytes}`, `files[{path,oldPath,status,similarity,binary,additions,deletions,skipped,firstLine}]`, `summary`, `verdict`, `findings[]`, `counts{error,warning,info}`, `ai{enabled,provider,model,chunks,failedChunks,synthesis,redactions,droppedFindings,errors[],parts[]}`, `index{source,missingPartners}`, `failOn`, `failed`, `failReasons[]`, `notes[]`.
- `analyze`: `generatedAt`, `now`, `since`, `prefix`, `sections[]`, `index{commits,paths,newestCommitTime,oldestCommitTime,lastSync,maxFiles,shallow,database,schemaVersion}`, `hotspots[{path,commits,churn,additions,deletions,authors,lastTime,score}]`, `coupling{minCommits,minJaccard,pairs,clusters[{id,files,size,truncated,strength,commits,edges[{a,b,commits,lastTime,jaccard,confidence}]}]}`, `ownership[{directory,commits,authorCount,busFactor,authors[{name,email,commits,lastTime,share}]}]`, `knowledgeLoss{inactiveDays,atRisk,files[{path,commits,inactiveShare,lastTime,activeAuthors,mainAuthor{name,email,commits,lastActive}}]}`, `trends{weeks[{week,start,commits,churn,authors}],slope,recentAverage,previousAverage,change,direction}`, `outliers{threshold,median,considered,commits[{sha,subject,authorName,authorEmail,commitTime,filesChanged,additions,deletions,size,score}]}`, `notes[]`.
- `test plan`: `range{base,baseRef,mergeBase,head,headRef,includesWorktree}`, `changed[{path,status,oldPath}]`, `runAll`, `runAllReason`, `minScore`, `candidates[{path,score,runner,project,selected,reasons[{kind,detail,from,score}]}]`, `suites[{id,runner,cwd,tests,selectors,all,command}]`, `sources{naming,index,graph}`, `notes[]`.
- `test run`: `mode`, `source` (`builtin`|`gitch-flow`), `runId`, `commit`, `branch`, `treeKey`, `dirty`, `suites[{id,runner,cwd,command,exitCode,timedOut,durationMs,ok,counts,reruns,error,cases[{id,name,classname,file,status,durationMs,message,attempts,flaky}],outputTail}]`, `counts{executed,passed,failed,skipped,flaky}`, `flaky[]`, `failures[{suite,id,file,message}]`, `result` (`passed`|`failed`|`flaky`|`no-tests`), `exitCode`, `history`, `notes[]`, and `flowRun{runId,state,code,exitCode}` when delegated.
- `test history`: `runs[{id,started,finished,commit,treeKey,branch,dirty,source,selection,counts,durationMs,exitCode}]` (or `test`, `results[]` with `--test`); `test flaky`: `tests[{suite,test,runs,attempts,passes,fails,flips,flipRate,sameTreeConflicts,lastSeen,reason}]`; `test slow`: `tests[{suite,test,samples,averageMs,p95Ms,maxMs}]`; `test trends`: `weeks[{week,start,runs,failedRuns,results,failedResults,runFailureRate,testFailureRate}]`, `topFailing[]`.
- `runtime check`: `manifest`, `ok`, `requirements[{tool,required,neededBy,found,path,version,ok,error}]`, `commands[{service,executable,found,path}]`.
- `runtime status|up|down|restart`: `supervisor{running,pid,startedAt}`, `stateDir`, `services[{name,state,message,pid,port,restarts,lastExit,health{ok,detail,checkedAt,failures},startedAt,log,slot,version,deploy{current,previous,running,last}}]`, `notes[]`. `runtime logs`: `services[{name,file,lines[]}]`.
- `runtime deploy`: `service`, `version`, `result` (`deployed`|`rolled_back`|`failed`), `from`, `to{version,slot,port,pid}`, `health{ok,detail,attempts}`, `steps[{step,ok,detail,at}]`, `symlink`, `supervisor`, `notes[]`.

## Platforms

macOS and Linux are supported. Windows is best effort and untested: processes start in a new process group and are stopped with `taskkill /T /F` (no graceful SIGTERM), `runtime down` terminates the supervisor without letting it stop its services first, the `current` link falls back to `current.txt` without symlink rights, `/dev/null` diffs for untracked files rely on Git for Windows, gitch's bash script is started through `bash`, and the gitch-flow report path may not match the engine's canonical path form.

## Tests

```sh
python3 -m unittest discover -s tools/gitrochi-py/tests          # from the repository root
```

The tests are hermetic: temporary repositories with an empty global git config (`GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL`, `HOME` in a temp folder), index databases built from `crates/gitrochi-index/src/schema.sql`, loopback mock servers on port 0 for every AI provider, fake `gitch`/`gitch-flow`/`gitrochi-index` scripts, and no Keychain access. When `crates/target/release/gitrochi-index` is built, `test_index_binary.py` also runs against the real executable with a temporary `--db`.
