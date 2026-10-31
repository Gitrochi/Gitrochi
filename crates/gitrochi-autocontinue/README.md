# gitrochi-autocontinue

Auto-continue for Claude Code sessions nobody is answering. When an agent that Gitrochi launched stops to ask the person something — a turn that ends with a question, an `AskUserQuestion` prompt, a plan to approve or a permission request — this crate decides whether Gitrochi may answer on the person's behalf once the delay (30 seconds by default) has passed, and builds exactly what the hook prints then.

It is pure logic: no database, network, clock or waiting. The Ledger hook handler (`gitrochi-ledger hook`, built later) reads the hook input, calls [`decide`](src/decide.rs), stores the pending prompt, waits, and sends the prepared output only if nobody answered in the meantime. The apps' countdown screens show the same payload.

```
Claude Code hook ──stdin──▶ handler ──▶ decide(input, policy, state, context, app_alive)
                                          ├─ Pass(reason)  → exit 0 at once, no output
                                          └─ Wait { payload, output, reply }
                                               store payload in pending_prompts, wait delaySec
                                               ├─ the person answered → drop it
                                               └─ no answer → print output, record auto_reply
```

Hook reference: <https://code.claude.com/docs/en/hooks>.

## Policy

Stored by the apps as JSON with camelCase fields; missing fields take the defaults, and `Policy::from_json` clamps the numbers.

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Answering for someone is their choice, so it is off until the person turns it on. |
| `delaySec` | `30` | Seconds to wait, clamped to 10–300. The reply states the real number. |
| `maxConsecutive` | `3` | Automatic answers to questions in a row (0–20). A person's prompt or answer resets the count. |
| `triggers` | `{"stopQuestion": true, "askUserQuestion": true, "exitPlanMode": false, "permission": true}` | Which prompts may be answered. Approving a plan ends plan mode, so it is off by default. |
| `extraDeny` | `[]` | More rules that hold a permission request (see [Extra rules](#extra-rules)). |
| `protectedBranches` | `[]` | Protected in addition to `main` and `master`, which always are. `release/*` patterns work. |
| `allowMcp` | `[]` | MCP tools that may be allowed (`mcp__server__*`); every other MCP tool waits. |
| `template` | `null` | Replaces the guidance after the reply's first line; `{seconds}` and `{question}` are filled in. |
| `language` | `"auto"` | `auto` follows the question; `ko`, `en`, `ja`, `zh` fix the reply language. |

## What is answered

`decide` passes at once when auto-continue is off, the trigger is off, the count has reached `maxConsecutive`, or — for synchronous hooks — the app is closed (D10, below). Otherwise:

**A turn that ends with a question** (`classify_stop`). Only the end of `last_assistant_message` counts: the last sentence, stepping back over a recommendation ("I recommend 2."), a polite closing ("Let me know if you have any questions") or a sign-off. Fenced code is ignored. It is a question when that sentence ends with `?`/`？`, asks for a decision in Korean, English, Japanese or Chinese ("Should I", "Do you want", "Would you like", "Let me know which", "진행할까요", "알려 주세요", "確認ください", "要不要", …), ends in a question form (`…까요`, `…습니까`, `…ますか`, `…吗`), or offers more work with a condition ("If you'd like, I can …", "원하시면 …하겠습니다"). A list next to the question becomes its options; a list before it only when the question asks to choose. A missed question costs the person a reply, a false one makes the agent carry on unasked, so the rules prefer misses: reports, rhetorical questions in the middle of a summary, "which" as a relative pronoun and closings are not questions. `tests/questions.rs` holds the cases.

**`AskUserQuestion`** (`pick_answers`). For each question the option marked as recommended — `(Recommended)`, `(추천)`, `(권장)`, `（推奨）`, `(推荐)` and the like in brackets on the label or description — else the first option. A multi-select question takes every recommended option, joined with `, `, else the first. No answer is made when a question has no text or options, or two questions share a text.

**`ExitPlanMode`** (only with `triggers.exitPlanMode`). The plan is approved with Claude Code's own input echoed back.

**Permission requests** (`evaluate_permission`). Allowed unless a rule below holds them; a held request passes with no decision, so Claude Code shows its own prompt.

**Hard-to-reverse prompts** wait for the person: a question, chosen option or plan that mentions force pushing, pushing or merging into a protected branch, deleting data, deploying or releasing, or credentials and accounts (`risky`). The reply would tell the agent to stop before those anyway.

**`stop_hook_active`**: when another stop hook is already continuing the turn and Gitrochi has not answered since the person's last input, the turn is left alone, so two hooks never feed each other.

**Counting**: `SessionState { consecutive }` is the handler's per-session counter: automatic answers of every kind, permissions included, since the person last answered or typed (the design's "at most three in a row", §9.4). `after_auto_reply()` adds one; `after_prompt(prompt)` resets it when the prompt is the person's. These do not reset it:
- prompts Claude Code submits for scheduled tasks, background agents and other sessions, which arrive wrapped in one XML-like element;
- a prompt that starts with `<task-notification>`, which is how the wake-up of an automatic Stop answer arrives (#171);
- anything quoting `[Gitrochi]`.

At the limit every prompt waits for the person.

**App closed (D10)**: `should_wait(kind, app_alive)`. A synchronous hook (PreToolUse, PermissionRequest) may keep Claude Code's own prompt from appearing while it waits, so with nobody able to see the countdown it ends at once without a decision. The Stop hook runs in the background and the person can still type, so it does not need the app. `app_alive(last_heartbeat, now)` counts the app as running while its heartbeat (`ledger/app.alive`, touched every 5 seconds) is under 15 seconds old.

## Permission rules

The Bash tool's command is tokenized as POSIX shell: quotes, escapes, `&&`, `||`, `;`, `|`, `&`, newlines, subshells, redirections and here-documents. What cannot be read before it runs is held: command substitution, backticks, process substitution, arithmetic, `$'…'`, functions, `case`. The one exception is the usual commit-message idiom `"$(cat <<'EOF' … EOF)"`, whose value is a literal. Wrappers are looked through (`env`, `nice`, `nohup`, `time`, `command`, `exec`, `timeout`, `xargs`, `npx`, `pnpm dlx` …), `cd` and subshells are followed, and every command that is not read-only must run inside the repository. The PowerShell tool gets a strict subset: script blocks, `$( )`, the call operator and the backtick escape are held, cmdlets are mapped to the same rules, and an unknown cmdlet is held.

| Rule id | Held |
| --- | --- |
| `ambiguous-shell` | `$( )`, backticks, `eval`, `sh -c`/`bash -c`, `python -c`/`node -e`/`perl -e`, an interpreter reading code from its input, `watch`, `git rebase --exec`, unknown git commands (aliases), a dynamic command name, `PATH=`/`HOME=`/`DYLD_*=`/`GIT_DIR=`/editor overrides, unknown PowerShell cmdlets, `Invoke-Expression`, `Start-Process` |
| `outside-repo-write` | Writes outside the repository and the writable folders (scratchpad): redirections, `cp`/`mv`/`touch`/`mkdir`/`tee`/`sed -i`/`tar -x`/`curl -o`/`wget`/`git clone`/`git worktree add` targets, Docker volume sources, `xargs` into a program that writes its operands, unknown targets (`$VAR`), any non-read-only command run outside the repository, `gitch clone`/`wt`/`work` |
| `git-internals` | Writes into `.git` (hooks, config, index) |
| `agent-settings` | Writes to `.claude/settings*.json` or `.mcp.json` |
| `recursive-delete` | `rm -r`/`rm -f`, `find -delete`, `rsync --delete`, `shred`, `docker volume rm`, `docker system prune`, `Remove-Item -Recurse/-Force` |
| `git-clean` | `git clean` without `-n` |
| `discard-changes` | `git reset --hard`, `git checkout -- <paths>`/`.`/a file, `git restore` (not `--staged` only), `git switch --discard-changes`, `git stash drop/clear`, `git branch -D`, `git tag -d`, `git reflog expire`, `git gc --prune=now`, `git update-ref`, `git filter-branch`, `gitch prune --yes` |
| `force-push` | `git push -f`/`--force`/`--force-with-lease`/`+refspec`, `gitch p --force` |
| `protected-branch-push` | Pushes to `main`, `master` or a configured branch (`HEAD:main`, `x:refs/heads/main`), `--all`/`--mirror`, pattern refspecs, a bare `git push`/`gitch p` whose current or upstream branch is protected, `gh pr merge`, `glab mr merge`, `gitch sync` |
| `push-target-unclear` | A bare push when the branch is unknown, a refspec or remote only known at run time, `gitch work push` |
| `remote-delete` | `git push --delete`/`:branch`/`--prune`, `gh repo delete`, `aws s3 rm` |
| `skip-checks` | `--no-verify` (and `git commit -n`), `core.hooksPath`, `GITSW_SKIP=`, `HUSKY=0`, `SKIP=`, `GIT_CONFIG*=`, `gitch ignore` |
| `sudo` | `sudo`, `doas`, `su`, `pkexec`, `Start-Process -Verb RunAs` |
| `deploy` | Publishing and deploy tools (`npm publish`, `cargo publish`, `docker push`, `kubectl apply`, `terraform apply`, `vercel`, `fly deploy`, `gh release`, `gh workflow run` …), tag pushes, scripts and make/npm targets named deploy/release/publish, `gitch publish` |
| `remote-shell` | `ssh`, `scp`/`rsync` to a host, `kubectl exec` |
| `pipe-to-shell` | A download piped into an interpreter (`curl … \| sh`), or run right after downloading it |
| `credentials` | Any path into `~/.ssh`, `~/.gitconfig`, `~/.config/gitsw`, `~/.git-credentials`, `~/.netrc`, `~/.aws`, `~/.config/gh`, `.npmrc` …; `security`, `ssh-keygen`, `gh auth`, `npm login`, `docker login`; git identity and credential settings (`user.*`, `credential.*`, `--global`), `GIT_AUTHOR_*=` |
| `gitch-account` | `gitch use`, `unlock`, `undo`, `amend`, `remove`, `abort`, `rescue --restore`, `fix --yes`, `sign`, `import`, `add`, `setup`, `login`, `config` changes, `ai`, `flow trust` |
| `system-change` | System settings and services (`defaults write`, `launchctl`, `systemctl`, `killall`, `crontab -r`, `Stop-Process` …) |
| `system-install` | Installs outside the repository (`npm -g`, `brew install`, `pip install` outside a repository virtualenv, `cargo install`, `rustup`, `make install` …) |
| `remote-api` | `gh api`/`glab api` requests other than GET, GraphQL mutations, `gh repo edit` |
| `mcp` | MCP tools not in `allowMcp` |
| `unknown-tool` | Tools this check does not know |
| `extra-deny` | A configured extra rule |

Edit, Write, MultiEdit and NotebookEdit must write inside the repository (or a writable folder) and not into `.git`, agent settings or credential files. Read, Glob, Grep, WebFetch, WebSearch, Agent and Claude Code's own bookkeeping tools are allowed, except reads of credential files. Paths are compared lexically (`..` folded, symlinks not followed): Windows paths without case, POSIX paths exactly, Git Bash's `/c/…` as `C:\…`. The context's `repo_root` should be canonical. `tests/permissions.rs` has every rule both ways.

### Extra rules

`extraDeny` entries use Claude Code's permission-rule style. `Bash(npm run e2e*)` matches a shell command (its words joined by spaces; `*` is any text, a trailing `:*` the command and anything after it); `Edit(docs/legal/*)` matches a file a tool writes (relative to the repository, or starting at `/`, a drive or `~/`); `Read(~/notes/*)` a file a tool reads; `WebFetch(*example.org*)` any text field of that tool's input; a bare `Workflow` or `mcp__server__*` a whole tool. Extra rules are checked first, so they also override `allowMcp`.

## The reply

```
[Gitrochi] 자동 진행 — 질문: 어떻게 할까요? — 기존 API를 그대로 둔다 / 새 API로 바꾼다 (추천)
30초 동안 답이 없어 자동으로 진행합니다. 당신이 추천한 안으로 진행하세요. 추천이 없었다면 되돌리기 쉬운 안을 고르세요. 되돌리기 어려운 작업(데이터 삭제, force push, main/보호 브랜치 push, 배포, 자격 증명·계정 설정 변경)은 하지 말고 멈춰서 다시 물어보세요. 고른 가정은 마지막 요약에 적으세요.
```

The first line names Gitrochi and summarizes the question (or the chosen answers, or the approved plan) in one line of at most 160 characters; the second is the guidance, in Korean, English, Japanese or Chinese after the question's script (others get English), with the real delay. The text is read by the agent, not shown as UI, so it lives in `src/reply.rs` as constants rather than in the apps' localization files. D9: the template is sent as is; polishing it with a model is for the handler to add, behind a setting.

## Hook outputs

| Prompt | Answered | Not answered |
| --- | --- | --- |
| Stop (`async` + `asyncRewake`) | exit 2, the reply on stderr — this wakes Claude even when the session is idle | exit 0, no output |
| PreToolUse `AskUserQuestion` / `ExitPlanMode` | exit 0 and `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": {…the original input…, "answers": {"<question>": "<label>"}}, "additionalContext": "<note>"}}` | exit 0, no output |
| PermissionRequest | exit 0 and `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}` | exit 0, no output |

`permission_deny(message)` builds `{"decision": {"behavior": "deny", "message": …}}` for when the person denies from the app, and `pre_tool_use_deny(reason)` the PreToolUse `permissionDecision: "deny"` for a plan the person turns down. `session_start_context(text)` puts `compose_session_context(lang, policy)` into a SessionStart hook's `additionalContext`: with auto-continue on, it asks the agent to ask with `AskUserQuestion` and to put its recommendation first, marked "(Recommended)", so the automatic answer is the agent's own pick (design §9.2). No output ever sets `updatedPermissions`, so nothing outlives the call. A background hook's decision fields have no effect, which is why the Stop answer travels as exit code 2 and stderr. The `additionalContext` note tells Claude the answer was chosen automatically, so it can say so in its summary. `tests/snapshots/` pins every output with the fixtures in `tests/fixtures/`.

`hook_settings(command, delaySec)` returns the `hooks` entries the handler installs next to Gitrochi's status hooks in the app's `hooks.json` (passed with `--settings`): `Stop` with `"async": true, "asyncRewake": true`, `PreToolUse` with matcher `AskUserQuestion|ExitPlanMode`, `PermissionRequest`, each with `timeout` = delay + 10 (design §9.1), and a `UserPromptSubmit` entry (timeout 10) that only tells the handler the person typed. Each runs `command <Event>`; [`tests/snapshots/hook-settings.json`](tests/snapshots/hook-settings.json) shows the result.

## What the Ledger stores

The pending prompt's `payload` (`PromptPayload`) and the `data` of the `auto_reply` event, actor `auto` (`AutoReply`). Both have `schemaVersion: 1` and camelCase fields; `kind` is `stop_question`, `ask_user_question`, `exit_plan_mode` or `permission`.

```json
{
  "schemaVersion": 1,
  "kind": "ask_user_question",
  "question": "카운트다운은 어디에 보여 줄까요?",
  "questions": [{"question": "카운트다운은 어디에 보여 줄까요?", "header": "화면", "multiSelect": true,
                 "options": [{"label": "Inbox (추천)", "description": "다른 질문과 함께", "recommended": true}]}],
  "language": "ko",
  "delaySec": 30,
  "proposed": {"type": "answers", "answers": {"카운트다운은 어디에 보여 줄까요?": "Inbox (추천)"}, "note": "[Gitrochi] …"}
}
```

| Payload field | Present for | Meaning |
| --- | --- | --- |
| `question` | all | One line: the question, the questions joined with ` / `, the plan's title, or `Tool: summary` |
| `text` | stop question, plan | The paragraphs that ask (up to 1,000 characters), or the plan (up to 4,000) |
| `options` | stop question | `[{label, recommended}]` from a list next to the question |
| `questions` | `AskUserQuestion` | `[{question, header, multiSelect, options: [{label, description, recommended}]}]` |
| `tool` | permission, plan | `{name, summary}`: the command, file, URL or query; for a plan, its file |
| `proposed` | all | What will be sent: `{"type": "reply", "text"}`, `{"type": "answers", "answers", "note"}`, `{"type": "approve_plan", "note"}` or `{"type": "allow"}` |

`AutoReply` has `kind`, `question`, `options` (labels), `sent` (same shape as `proposed`), `rule` (`question:<cue>` such as `question:ko:까요`, `answers:recommended`, `answers:first-option`, `answers:mixed`, `plan:approve` or `permission:no-rule`), `delaySec`, `language` and `consecutive` (this answer included). When nothing is answered, `Pass` says why, serialized with a `code`: `disabled`, `trigger_off`, `app_closed`, `limit_reached`, `stop_hook_active`, `not_a_question`, `risky`, `no_answer`, `held` (with `rule` and an English `detail`) or `not_handled`. Rule ids are stable for the apps to translate.

## Command line

```sh
gitrochi-autocontinue eval Stop < tests/fixtures/stop-question-ko.json            # the decision as JSON
gitrochi-autocontinue eval PreToolUse --emit < tests/fixtures/ask-user-question.json  # exactly what the hook prints
gitrochi-autocontinue eval PermissionRequest --branch feature/x --pretty < input.json
gitrochi-autocontinue settings '"/path/to/handler" hook' --delay 30
```

`eval EVENT` never waits. Without `--policy FILE` it uses the defaults with auto-continue on. `--repo DIR` is the repository root (default: the input's `cwd`), `--home DIR` the home folder (default: `HOME` or `USERPROFILE`), `--branch`/`--upstream` the checked-out branch and its upstream's name on the remote, `--consecutive N` the answers so far, `--app-closed` D10. Exit codes: 0, 1 for unreadable input, 2 for usage errors; with `--emit`, the hook's own code.

## Checks

```sh
cargo test --locked --manifest-path crates/Cargo.toml -p gitrochi-autocontinue
cargo clippy --locked --manifest-path crates/Cargo.toml --all-targets -- -D warnings
UPDATE_SNAPSHOTS=1 cargo test --manifest-path crates/Cargo.toml -p gitrochi-autocontinue --test outputs  # after a deliberate format change; review the diff
```

## Confirmed and not yet confirmed

Checked against the hooks documentation on 2026-10-31:

- `AskUserQuestion` and `ExitPlanMode` need `permissionDecision: "allow"` together with `updatedInput`; `allow` alone does not answer them. `answers` maps question text to the chosen label, and multi-select labels are joined with commas.
- Stop input has `stop_hook_active` and `last_assistant_message` (plus `background_tasks` and `session_crons`). Synchronous continuations are capped at 8 in a row (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`), and the count resets when Claude calls a tool.
- Decision fields have no effect in an `async` hook. An `asyncRewake` hook that exits 2 wakes Claude at once even when the session is idle, its stderr (or stdout) shown as a system reminder. `timeout` is enforced for `asyncRewake` hooks but not for plain `async` ones. With `-p`, async hooks still running at teardown are killed.
- PermissionRequest decides with `hookSpecificOutput.decision.behavior`; `updatedPermissions` and `updatedInput` are for `allow`, `message` and `interrupt` for `deny`. Exit 2 is not honoured there, and a hook that ends without a decision leaves the normal flow. In sessions that cannot prompt, no decision means deny.
- PreToolUse `additionalContext` is added to Claude's context alongside the tool result.
- The `permission_prompt` notification comes after about six seconds and has no decision control.
- UserPromptSubmit also fires for scheduled tasks, background subagents reporting back and messages from other sessions.
- Write, Edit and Read paths arrive absolute (`~` and relative paths expanded); on Windows with backslashes.

Seen in a real run (Claude Code 2.1.309, hooks passed with `--settings`): the UserPromptSubmit input (`session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `prompt`) parses, and the prompt counts as the person's.

Not yet confirmed in a real session, because no logged-in standalone `claude` was available where this was built:

- that Claude Code applies the three outputs above end to end (the Stop wake-up with the reply, the `AskUserQuestion` answers with `additionalContext`, the PermissionRequest allow);
- whether Claude Code shows its permission dialog while a PermissionRequest hook is still running (the documentation does not say);
- whether the wake-up from `asyncRewake` fires UserPromptSubmit or sets `stop_hook_active` on the next Stop (the counting above is written so either way stays bounded);
- the exact separator Claude Code's own picker uses for multi-select answers (`, ` here; the documentation says "commas").

## For the hook handler

- Only the four kinds above are ever answered; the Ledger's own questions and decisions are never answered or closed automatically, and sessions with the decision role never auto-continue: pass them a policy with `enabled: false` (D8, design §9.4).
- Add the repository's default branch to `protected_branches` when it is not `main` or `master`.
- Supersede a waiting prompt when the same session sends any newer event (a prompt, a tool call, another Stop, SessionEnd), so a late wake-up never lands in the middle of other work.
- While a PreToolUse or PermissionRequest hook waits, the terminal shows no prompt; the app's countdown is the only place to answer. An answer from the app goes back through `updatedInput` (or `permission_deny`); "answer in the terminal" ends the hook with no output.
- Keep `SessionState` per session (or count the session's `auto_reply` events since the person's last input); call `after_prompt` on every UserPromptSubmit, `after_person` when the person answers in the app, `after_auto_reply` after sending.
- Fill `PermissionContext` with the canonical repository root, the session's scratchpad (from the input), and the current branch and its upstream (`git rev-parse --abbrev-ref HEAD @{upstream}`, remote name removed); without them a bare push is held.
- Finish before the hook's timeout (delay + 10 seconds).
