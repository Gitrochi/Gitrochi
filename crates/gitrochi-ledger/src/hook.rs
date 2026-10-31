//! `gitrochi-ledger hook <event>`: the Claude Code hooks of agents Gitrochi launched
//! (DESIGN.md §7.11, §9). Activity on SessionStart, UserPromptSubmit, Stop and SessionEnd:
//! `lastAt`, the Claude session link and `hook` events — never prompt text or tool input,
//! never a status. Auto-continue on Stop, PreToolUse (`AskUserQuestion`, `ExitPlanMode`) and
//! PermissionRequest, only for sessions where a person turned it on: `gitrochi-autocontinue`
//! decides and formats, this module stores the pending prompt, waits for it and prints.
//! PostToolUse and PostToolUseFailure tell it which permission answers applied: the terminal
//! shows its own dialog while a PermissionRequest hook waits (Claude Code 2.1.309, #171).
//!
//! A hook must never get in the agent's way. Every failure — bad input, no database, a
//! locked file — ends with exit 0, no decision and one short line on stderr; the only other
//! exit code is the 2 that wakes Claude from the Stop hook. The handler writes activity, the
//! link and pending prompts only: a person's operations (`human`, `prompt_answer`, settings)
//! are out of its reach (§8).

use crate::db::{Db, OpenOptions};
use crate::error::Result;
use crate::event::{self, NewEvent};
use crate::git;
use crate::prompts::{self, PendingPrompt};
use crate::session::{self, SessionRow};
use crate::settings::Settings;
use crate::util::{self, now_ms, Ms};
use crate::vocab::Role;
use gitrochi_autocontinue::{
    app_alive, approve_plan, compose_session_context, decide, is_person_prompt, permission_allow,
    permission_deny, pre_tool_use_allow, pre_tool_use_deny, reply_language, session_start_context,
    should_wait, stop_wake, Decision, HookEvent, HookInput, HookOutput, PermissionContext, Policy,
    PromptKind, Proposed, SessionState, Wait, REPLY_TAG,
};
use rusqlite::{params, Connection};
use serde_json::{json, Map, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The events the handler knows; any other ends at once, silently.
pub const EVENTS: [&str; 8] = [
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PostToolUseFailure",
    "SessionEnd",
];

/// How often a waiting hook looks for an answer (design §9.1).
pub const POLL: Duration = Duration::from_millis(250);

// Read by the agent, not shown as UI (like gitrochi-autocontinue's replies).
const PERSON_ANSWER: &str = "The person answered in Gitrochi:";
const PERSON_DENIED: &str = "The person denied this in Gitrochi.";
const PLAN_NOT_APPROVED: &str =
    "The person did not approve the plan in Gitrochi. Keep planning, then ask again.";

/// What the handler reads from its process: the database, the ledger session Gitrochi
/// launched the agent for (`GITROCHI_LEDGER_SESSION`) and its agent ID.
#[derive(Clone, Debug, Default)]
pub struct HookEnv {
    pub db: PathBuf,
    pub session: Option<String>,
    pub agent_id: Option<String>,
    /// The person's home folder, for `~` in permission checks.
    pub home: String,
    /// `GITROCHI_LEDGER=0` turns the handler off with the rest of the ledger.
    pub enabled: bool,
}

impl HookEnv {
    pub fn from_process(db: Option<PathBuf>) -> HookEnv {
        let var = |name: &str| std::env::var(name).ok().and_then(|v| util::clean(&v));
        HookEnv {
            db: db.unwrap_or_else(crate::db::default_db_path),
            session: var("GITROCHI_LEDGER_SESSION"),
            agent_id: var("GITROCHI_AGENT_ID"),
            home: var("HOME")
                .or_else(|| var("USERPROFILE"))
                .unwrap_or_default(),
            enabled: crate::db::enabled(),
        }
    }
}

/// What the hook prints, and its exit code.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HookResult {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

impl HookResult {
    fn emit(output: &HookOutput) -> HookResult {
        HookResult {
            stdout: output.stdout(),
            stderr: output.stderr(),
            code: output.exit_code(),
        }
    }

    /// No decision, and a line for Claude Code's debug output.
    fn note(message: &str) -> HookResult {
        HookResult {
            stderr: format!("gitrochi-ledger hook: {message}"),
            ..HookResult::default()
        }
    }

    fn noted(mut self, message: Option<&str>) -> HookResult {
        if let Some(message) = message {
            if self.stderr.is_empty() {
                self.stderr = format!("gitrochi-ledger hook: {message}");
            }
        }
        self
    }
}

/// The app touches this file next to the database every 5 seconds while it runs.
pub fn heartbeat_path(db: &Path) -> PathBuf {
    db.with_file_name("app.alive")
}

fn heartbeat(db: &Path) -> Option<u64> {
    let modified = std::fs::metadata(heartbeat_path(db))
        .ok()?
        .modified()
        .ok()?;
    modified
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

fn seconds(ms: Ms) -> u64 {
    u64::try_from(ms / 1000).unwrap_or(0)
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Handles one hook call. Never panics and never exits with anything but 0, or 2 for the
/// Stop hook's wake-up: exit 2 blocks a prompt or a tool call on other events.
pub fn run(event: &str, input: &str, env: &HookEnv) -> HookResult {
    let result = catch_unwind(AssertUnwindSafe(|| handle(event, input, env)))
        .unwrap_or_else(|_| HookResult::note("the hook handler failed; no decision"));
    guarded(event, result)
}

fn guarded(event: &str, result: HookResult) -> HookResult {
    match result.code {
        0 => result,
        2 if event == "Stop" => result,
        _ => HookResult::note("an unexpected exit code was dropped; no decision"),
    }
}

fn handle(event: &str, text: &str, env: &HookEnv) -> HookResult {
    if !env.enabled || !EVENTS.contains(&event) {
        return HookResult::default();
    }
    // Only agents Gitrochi launched with tracking on carry a ledger session.
    let Some(session_id) = env.session.as_deref() else {
        return HookResult::default();
    };
    if !util::valid_session_id(session_id) {
        return HookResult::note("GITROCHI_LEDGER_SESSION is not a session ID");
    }
    let raw: Value = match serde_json::from_str(text) {
        Ok(value @ Value::Object(_)) => value,
        _ => return HookResult::note("the hook input is not a JSON object"),
    };
    let mut input = HookInput::from_value(&raw);
    // the event on the command line wins, as with the entries Gitrochi installs
    input.hook_event_name = event.to_string();
    if event == "PreToolUse"
        && !matches!(input.tool_name.as_str(), "AskUserQuestion" | "ExitPlanMode")
    {
        return HookResult::default();
    }
    let db = match Db::open_with(&env.db, OpenOptions::hook()) {
        Ok(db) => db,
        Err(error) => return HookResult::note(&error.message),
    };
    let result = match event {
        "SessionStart" => session_start(&db, session_id, &input, &raw),
        "UserPromptSubmit" => prompt_submitted(&db, session_id, &input),
        "SessionEnd" => session_end(&db, session_id, &input, &raw),
        "PostToolUse" | "PostToolUseFailure" => tool_ran(&db, session_id, &input, &raw),
        _ => auto_continue(&db, env, session_id, &input),
    };
    result.unwrap_or_else(|error| HookResult::note(&format!("{}; no decision", error.message)))
}

fn missing(session_id: &str) -> HookResult {
    HookResult::note(&format!("no ledger session {session_id}"))
}

/// The policy for a session: the global `autoContinue` setting with the session's own
/// `enabled` and `delaySec` on top. Sessions with the decision role never auto-continue
/// (§9.4). `None` when the stored setting cannot be read; it then stays off.
fn policy_for(settings: &Settings, row: &SessionRow) -> Option<Policy> {
    let mut value = match &settings.auto_continue {
        Value::Object(map) => Value::Object(map.clone()),
        _ => json!({}),
    };
    if let Some(Value::Object(own)) = &row.auto_continue {
        for key in ["enabled", "delaySec"] {
            if let Some(setting) = own.get(key) {
                value[key] = setting.clone();
            }
        }
    }
    let mut policy = serde_json::from_value::<Policy>(value).ok()?.normalized();
    if settings.role(&row.kind) == Role::Decision {
        policy.enabled = false;
    }
    Some(policy)
}

const UNREADABLE: &str = "the auto-continue settings cannot be read, so it stays off";

/// Short identifiers from the input (Claude session IDs, `source`, `reason`); anything
/// long or with control characters is not an identifier and is left out.
fn identifier(text: &str) -> Option<String> {
    util::clean(text).filter(|t| t.chars().count() <= 200 && !t.chars().any(char::is_control))
}

/// `lastAt` moves forward only.
fn touch(connection: &Connection, row: &SessionRow, now: Ms) -> Result<()> {
    connection.execute(
        "UPDATE sessions SET last_at = MAX(last_at, ?2) WHERE id = ?1",
        params![row.id, now],
    )?;
    Ok(())
}

fn hook_event(
    connection: &Connection,
    row: &SessionRow,
    summary: &str,
    data: &Value,
    now: Ms,
) -> Result<i64> {
    event::insert(
        connection,
        &NewEvent {
            session_id: &row.id,
            project: &row.project,
            ts: now,
            kind: "hook",
            actor: "hook",
            summary,
            body: None,
            version: None,
            artifacts: &json!([]),
            data,
            channel: "hook",
            delivered_at: Some(now),
        },
    )
}

/// Links the Claude session ID (`links.agentSessionId`). A new ID — the first one, or the
/// one `/clear`, `--fork-session` or `/branch` gave the conversation — is also recorded as
/// a `hook` event with the one before, so the session can still be found by every ID its
/// conversation had.
fn link(
    connection: &Connection,
    row: &SessionRow,
    hook: &str,
    claude_session: &str,
    source: Option<&str>,
    now: Ms,
) -> Result<()> {
    let Some(claude_session) = identifier(claude_session) else {
        return Ok(());
    };
    let previous = row.links["agentSessionId"].as_str();
    if previous == Some(claude_session.as_str()) {
        return Ok(());
    }
    let mut links = match &row.links {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    links.insert("agentSessionId".into(), json!(claude_session));
    connection.execute(
        "UPDATE sessions SET links = ?2 WHERE id = ?1",
        params![row.id, Value::Object(links).to_string()],
    )?;
    let mut data = json!({"hook": hook, "agentSessionId": claude_session});
    if let Some(previous) = previous {
        data["previous"] = json!(previous);
    }
    if let Some(source) = source {
        data["source"] = json!(source);
    }
    hook_event(
        connection,
        row,
        "Linked the Claude Code session",
        &data,
        now,
    )?;
    Ok(())
}

/// SessionStart: activity and the link; earlier prompts can no longer be answered. With
/// auto-continue on, the context asks the agent to ask with `AskUserQuestion` and to
/// recommend first, so the automatic answer is its own pick (§9.2).
fn session_start(db: &Db, id: &str, input: &HookInput, raw: &Value) -> Result<HookResult> {
    let Some((row, settings)) = db.read(|c| {
        Ok(match session::load(c, id)? {
            Some(row) => Some((row, Settings::load(c)?)),
            None => None,
        })
    })?
    else {
        return Ok(missing(id));
    };
    let source = raw["source"].as_str().and_then(identifier);
    let now = now_ms();
    let written = db.write(|c| {
        let Some(row) = session::load(c, id)? else {
            return Ok(());
        };
        touch(c, &row, now)?;
        link(
            c,
            &row,
            "SessionStart",
            &input.session_id,
            source.as_deref(),
            now,
        )?;
        prompts::settle_unconfirmed(c, id, None)?;
        prompts::release_session(c, id)?;
        Ok(())
    });
    let failed = written
        .err()
        .map(|error| format!("{}; activity not recorded", error.message));
    let policy = policy_for(&settings, &row);
    let result = match &policy {
        Some(policy) if policy.enabled && policy.triggers.ask_user_question => {
            let context = compose_session_context(reply_language("", policy), policy);
            HookResult::emit(&session_start_context(&context))
        }
        _ => HookResult::default(),
    };
    Ok(result
        .noted(failed.as_deref())
        .noted(policy.is_none().then_some(UNREADABLE)))
}

/// UserPromptSubmit: Claude Code holds the prompt until this returns, so it is one short
/// write. A waiting stop question is answered by the person's prompt, or released by a
/// prompt Claude Code submitted on its own — the wake-up of Gitrochi's own Stop answer is
/// one of those. The person's prompt also ends what is left of the turn before (a hook that
/// Esc interrupted never closes its prompt itself) and starts the count of automatic
/// answers again.
fn prompt_submitted(db: &Db, id: &str, input: &HookInput) -> Result<HookResult> {
    let now = now_ms();
    let person = is_person_prompt(&input.prompt);
    let (found, _) = db.write(|c| {
        let Some(row) = session::load(c, id)? else {
            return Ok(false);
        };
        touch(c, &row, now)?;
        link(c, &row, "UserPromptSubmit", &input.session_id, None, now)?;
        prompts::settle_stop_questions(c, id, person, now)?;
        if person {
            prompts::settle_unconfirmed(c, id, None)?;
            prompts::release_session(c, id)?;
        }
        if person && prompts::in_a_row(c, id)? > 0 {
            hook_event(
                c,
                &row,
                "The person typed in the terminal",
                &json!({"hook": "UserPromptSubmit", "person": true}),
                now,
            )?;
        }
        Ok(true)
    })?;
    Ok(if found {
        HookResult::default()
    } else {
        missing(id)
    })
}

/// SessionEnd (a 1.5 s budget): activity, a `hook` event with the reason, and nothing the
/// conversation waited on stays open.
fn session_end(db: &Db, id: &str, input: &HookInput, raw: &Value) -> Result<HookResult> {
    let now = now_ms();
    let reason = raw["reason"].as_str().and_then(identifier);
    let (found, _) = db.write(|c| {
        let Some(row) = session::load(c, id)? else {
            return Ok(false);
        };
        touch(c, &row, now)?;
        prompts::settle_unconfirmed(c, id, None)?;
        prompts::release_session(c, id)?;
        let mut data = json!({"hook": "SessionEnd"});
        if let Some(reason) = &reason {
            data["reason"] = json!(reason);
        }
        if let Some(claude_session) = identifier(&input.session_id) {
            data["agentSessionId"] = json!(claude_session);
        }
        let summary = match &reason {
            Some(reason) => format!("Claude Code session ended ({reason})"),
            None => "Claude Code session ended".to_string(),
        };
        hook_event(c, &row, &summary, &data, now)?;
        Ok(true)
    })?;
    Ok(if found {
        HookResult::default()
    } else {
        missing(id)
    })
}

fn prompt_kind(input: &HookInput) -> Option<PromptKind> {
    match (input.event(), input.tool_name.as_str()) {
        (HookEvent::Stop, _) => Some(PromptKind::StopQuestion),
        (HookEvent::PreToolUse, "AskUserQuestion") => Some(PromptKind::AskUserQuestion),
        (HookEvent::PreToolUse, "ExitPlanMode") => Some(PromptKind::ExitPlanMode),
        (HookEvent::PermissionRequest, _) => Some(PromptKind::Permission),
        _ => None,
    }
}

fn trigger_on(policy: &Policy, kind: PromptKind) -> bool {
    let t = &policy.triggers;
    match kind {
        PromptKind::StopQuestion => t.stop_question,
        PromptKind::AskUserQuestion => t.ask_user_question,
        PromptKind::ExitPlanMode => t.exit_plan_mode,
        PromptKind::Permission => t.permission,
    }
}

/// The permission check's view of the session: the checkout git reports for the agent's
/// folder (else the folder itself), its branch, the branch it pushes to, and origin's
/// default branch as one more protected branch.
fn permission_context(
    input: &HookInput,
    policy: &Policy,
    env: &HookEnv,
    with_git: bool,
) -> PermissionContext {
    let checkout = if with_git && !input.cwd.is_empty() {
        git::checkout(Path::new(&input.cwd))
    } else {
        None
    };
    let root = checkout
        .as_ref()
        .map_or_else(|| input.cwd.clone(), |c| c.root.clone());
    let mut ctx = PermissionContext::new(input, policy, &root, &env.home);
    if let Some(checkout) = checkout {
        ctx.current_branch = checkout.branch;
        ctx.upstream_branch = checkout.upstream;
        if let Some(default) = checkout.default_branch {
            if !ctx.protected_branches.contains(&default) {
                ctx.protected_branches.push(default);
            }
        }
    }
    ctx
}

/// Which call a permission prompt is about, so the PostToolUse of that call can be matched
/// to it: PermissionRequest input has no `tool_use_id` (issue #171). The key hashes the tool
/// and what it acts on (the command, the file, the URL or the query, else the whole input),
/// so fields Claude Code adds to the input later do not matter; `agent` keeps a subagent's
/// calls apart from the main agent's.
fn call_of(input: &HookInput) -> Value {
    let field = |key: &str| input.tool_input.get(key).and_then(Value::as_str);
    let subject = match input.tool_name.as_str() {
        "Bash" | "PowerShell" => field("command"),
        "Edit" | "MultiEdit" | "Write" | "Read" | "NotebookEdit" => {
            field("file_path").or_else(|| field("notebook_path"))
        }
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        _ => None,
    }
    .map_or_else(|| input.tool_input.to_string(), str::to_string);
    let key = crate::sha1::hex(format!("{}\0{subject}", input.tool_name).as_bytes());
    json!({"key": key, "agent": input.agent_id})
}

/// PostToolUse and PostToolUseFailure: a call ran. While a permission hook waits, the
/// terminal shows its own dialog and the person may answer there; the hook does not learn
/// of it, and its later decision is ignored (issue #171). The call running settles that:
/// see `prompts::settle_call`. One read when nothing waits.
fn tool_ran(db: &Db, id: &str, input: &HookInput, raw: &Value) -> Result<HookResult> {
    let agent = input.agent_id.as_deref();
    let (_, waiting, unconfirmed) = db.read(|c| prompts::open_work(c, id, agent))?;
    if !waiting && !unconfirmed {
        return Ok(HookResult::default());
    }
    let key = call_of(input)["key"].as_str().unwrap_or("").to_string();
    let duration = raw["duration_ms"].as_i64();
    let now = now_ms();
    db.write(|c| prompts::settle_call(c, id, agent, &key, duration, now))?;
    Ok(HookResult::default())
}

/// Stop, PreToolUse and PermissionRequest. With auto-continue off for the session, or the
/// app closed for a synchronous hook (D10), this ends after one read (plus the Stop's
/// activity, and settling what the agent moved past). Otherwise `decide` runs inside the
/// write that stores the pending prompt, so the count of automatic answers in a row cannot
/// move under it.
fn auto_continue(db: &Db, env: &HookEnv, id: &str, input: &HookInput) -> Result<HookResult> {
    let kind = prompt_kind(input);
    let stop = kind == Some(PromptKind::StopQuestion);
    // Stop is always the main agent's; the others say whose call it is.
    let agent = if stop {
        None
    } else {
        input.agent_id.as_deref()
    };
    let call = (kind == Some(PromptKind::Permission)).then(|| call_of(input));
    let own_key = call
        .as_ref()
        .and_then(|c| c["key"].as_str())
        .map(str::to_string);
    // The app's countdown is the only place to answer while a synchronous hook waits.
    let alive = app_alive(heartbeat(&env.db), now_seconds());
    let Some((row, settings, (stop_waiting, permission_waiting, unconfirmed))) = db.read(|c| {
        Ok(match session::load(c, id)? {
            Some(row) => Some((row, Settings::load(c)?, prompts::open_work(c, id, agent)?)),
            None => None,
        })
    })?
    else {
        return Ok(missing(id));
    };
    let policy = policy_for(&settings, &row);
    let unreadable = policy.is_none().then_some(UNREADABLE);
    let policy = policy.unwrap_or_default();
    let may_wait =
        kind.is_some_and(|k| policy.enabled && trigger_on(&policy, k) && should_wait(k, alive));
    // the main agent working again means its stop question was moved past
    let supersede = stop_waiting && (stop || agent.is_none());
    // an agent asking about something else, or ending its turn, answered its earlier
    // permission dialog in the terminal
    let moved_on = permission_waiting;
    // the turn ended: automatic permission answers nothing confirmed stay unknown
    let unconfirmed_end = stop && unconfirmed;
    if !may_wait && !stop && !supersede && !moved_on {
        return Ok(HookResult::default().noted(unreadable));
    }
    let ctx = permission_context(
        input,
        &policy,
        env,
        may_wait && kind == Some(PromptKind::Permission),
    );
    let now = now_ms();
    let ((decision, prompt), _) = db.write(|c| {
        let Some(row) = session::load(c, id)? else {
            return Ok((None, None));
        };
        if stop {
            touch(c, &row, now)?;
        }
        if supersede {
            prompts::settle_stop_questions(c, id, false, now)?;
        }
        if moved_on {
            prompts::settle_moved_on(c, id, agent, own_key.as_deref(), now)?;
        }
        if unconfirmed_end {
            prompts::settle_unconfirmed(c, id, Some(None))?;
        }
        if !may_wait {
            return Ok((None, None));
        }
        let replies = prompts::in_a_row(c, id)?;
        // another stop hook's loop, with no automatic answer since the person's last input
        // (a subagent's prompt waiting meanwhile is not one)
        if stop && input.stop_hook_active && replies == 0 {
            return Ok((None, None));
        }
        let state = SessionState {
            consecutive: replies + prompts::open_count(c, id)?,
        };
        let decision = decide(input, &policy, state, &ctx, alive);
        let prompt = match &decision {
            Decision::Wait(wait) => {
                let mut payload = serde_json::to_value(&wait.payload)?;
                if let Some(call) = &call {
                    payload["call"] = call.clone();
                }
                Some(prompts::create(
                    c,
                    &json!({
                        "kind": wait.kind.as_str(),
                        "sessionId": id,
                        "agentId": env.agent_id,
                        "payload": payload,
                        "delaySec": wait.delay_sec,
                    }),
                    now,
                )?)
            }
            Decision::Pass(_) => None,
        };
        Ok((Some(decision), prompt))
    })?;
    match (decision, prompt) {
        (Some(Decision::Wait(wait)), Some(prompt)) => {
            Ok(wait_for_answer(db, env, input, &wait, &prompt).noted(unreadable))
        }
        _ => Ok(HookResult::default().noted(unreadable)),
    }
}

/// Checks the prompt every 250 ms until its deadline. A person's answer from the app wins;
/// a prompt that was released (answered in the terminal, superseded) ends without a
/// decision; so does a synchronous one whose countdown nobody can see any more because the
/// app stopped (D10). At the deadline the automatic answer is recorded first and sent only
/// if that worked, so nothing goes out that is not on record.
fn wait_for_answer(
    db: &Db,
    env: &HookEnv,
    input: &HookInput,
    wait: &Wait,
    prompt: &PendingPrompt,
) -> HookResult {
    // The stored deadline can only bring the answer forward; the handler keeps its own, so
    // it always ends before the hook's timeout (the delay plus a 10 s margin).
    let own = prompt.deadline;
    let mut deadline = own;
    loop {
        if let Ok(current) = db.read(|c| prompts::get(c, prompt.id)) {
            match current.state.as_str() {
                "waiting" => deadline = current.deadline.min(own),
                "answered" => return answered(wait, input, current.answer.as_ref()),
                _ => return HookResult::default(),
            }
        }
        let now = now_ms();
        if now >= deadline {
            break;
        }
        if wait.kind.requires_app() && !app_alive(heartbeat(&env.db), seconds(now)) {
            return close(
                db,
                wait,
                input,
                &json!({"id": prompt.id, "state": "released"}),
            );
        }
        let left = u64::try_from(deadline - now).unwrap_or(0);
        std::thread::sleep(POLL.min(Duration::from_millis(left.max(1))));
    }
    let reply = match serde_json::to_value(&wait.reply) {
        Ok(reply) => reply,
        Err(_) => return HookResult::note("the automatic answer could not be recorded"),
    };
    let summary = format!(
        "Auto-continue answered: {}",
        util::one_line(&wait.reply.question, 120)
    );
    close(
        db,
        wait,
        input,
        &json!({"id": prompt.id, "state": "auto", "answer": reply, "summary": summary}),
    )
}

/// Closes a prompt that still waits (`auto` with the answer, or `released`) and says what
/// the hook sends: the automatic answer only once it is on record, the person's answer if
/// they were a moment faster, else nothing. An automatic permission answer is recorded as
/// unconfirmed: the person may already have answered the terminal's own dialog, and which
/// decision applied shows only when the call runs (`tool_ran`).
fn close(db: &Db, wait: &Wait, input: &HookInput, args: &Value) -> HookResult {
    let unconfirmed = wait.kind == PromptKind::Permission && args["state"] == "auto";
    let closed = db.write(|c| {
        let now = now_ms();
        if unconfirmed {
            let id = args["id"].as_i64().unwrap_or(0);
            prompts::resolve_unconfirmed(c, id, &args["answer"], now)
        } else {
            prompts::resolve(c, args, now)
        }
    });
    match closed {
        Ok(((true, closed), _)) if closed.state == "auto" => HookResult::emit(&wait.output),
        Ok(((false, current), _)) if current.state == "answered" => {
            answered(wait, input, current.answer.as_ref())
        }
        Ok(_) => HookResult::default(),
        Err(error) if args["state"] == "auto" => HookResult::note(&format!(
            "{}; the automatic answer was not recorded, so none was sent",
            error.message
        )),
        Err(error) => HookResult::note(&error.message),
    }
}

/// What the hook sends for a person's answer from the app (`prompt_answer`), in the shapes
/// both apps send: `{text}`, `{answers}`, `{decision: allow | deny, message?}`; `{release}`
/// (answer in the terminal) and `{hold}` (not this time) end the hook without a decision,
/// and so does anything that does not fit the prompt.
fn answered(wait: &Wait, input: &HookInput, answer: Option<&Value>) -> HookResult {
    let Some(answer) = answer.filter(|a| a.is_object()) else {
        return HookResult::default();
    };
    if answer["release"] == json!(true) || answer["hold"] == json!(true) {
        return HookResult::default();
    }
    let text = |key: &str| {
        answer[key]
            .as_str()
            .map(str::trim)
            .filter(|t| !t.is_empty())
    };
    let output = match wait.kind {
        PromptKind::StopQuestion => {
            text("text").map(|reply| stop_wake(&format!("{REPLY_TAG} {PERSON_ANSWER} {reply}")))
        }
        PromptKind::AskUserQuestion => answer["answers"].as_object().map(|chosen| {
            pre_tool_use_allow(
                with_answers(&input.tool_input, chosen, &wait.payload.proposed),
                None,
            )
        }),
        PromptKind::ExitPlanMode => match text("decision") {
            Some("allow") => Some(pre_tool_use_allow(approve_plan(&input.tool_input), None)),
            Some("deny") => Some(pre_tool_use_deny(
                text("message").unwrap_or(PLAN_NOT_APPROVED),
            )),
            _ => None,
        },
        PromptKind::Permission => match text("decision") {
            Some("allow") => Some(permission_allow()),
            Some("deny") => Some(permission_deny(text("message").unwrap_or(PERSON_DENIED))),
            _ => None,
        },
    };
    output.map_or_else(HookResult::default, |output| HookResult::emit(&output))
}

/// `AskUserQuestion`'s input with the person's answers; a question they left open takes the
/// answer the countdown showed.
fn with_answers(tool_input: &Value, chosen: &Map<String, Value>, proposed: &Proposed) -> Value {
    let shown = match proposed {
        Proposed::Answers { answers, .. } => Some(answers),
        _ => None,
    };
    let mut answers = Map::new();
    for question in tool_input["questions"].as_array().into_iter().flatten() {
        let Some(text) = question["question"].as_str() else {
            continue;
        };
        let mine = chosen
            .get(text)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|a| !a.is_empty())
            .map(str::to_string);
        if let Some(answer) = mine.or_else(|| shown.and_then(|s| s.get(text).cloned())) {
            answers.insert(text.to_string(), json!(answer));
        }
    }
    let mut updated = match tool_input {
        Value::Object(_) => tool_input.clone(),
        _ => json!({}),
    };
    updated["answers"] = Value::Object(answers);
    updated
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_for(kind: PromptKind, proposed: Proposed) -> Wait {
        Wait {
            kind,
            delay_sec: 30,
            output: HookOutput::Silent,
            payload: gitrochi_autocontinue::PromptPayload {
                schema_version: 1,
                kind,
                question: "Which one?".into(),
                text: String::new(),
                options: Vec::new(),
                questions: Vec::new(),
                tool: None,
                language: gitrochi_autocontinue::Lang::En,
                delay_sec: 30,
                proposed: proposed.clone(),
            },
            reply: gitrochi_autocontinue::AutoReply {
                schema_version: 1,
                kind,
                question: "Which one?".into(),
                options: Vec::new(),
                sent: proposed,
                rule: "test".into(),
                delay_sec: 30,
                language: gitrochi_autocontinue::Lang::En,
                consecutive: 1,
            },
        }
    }

    fn input(tool: &str, tool_input: Value) -> HookInput {
        HookInput::from_value(
            &json!({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input}),
        )
    }

    #[test]
    fn a_persons_answers_fill_in_the_proposed_ones() {
        let questions = json!({"questions": [
            {"question": "A?", "options": [{"label": "x"}, {"label": "y"}]},
            {"question": "B?", "options": [{"label": "p"}, {"label": "q"}]},
        ]});
        let proposed = Proposed::Answers {
            answers: [
                ("A?".to_string(), "x".to_string()),
                ("B?".to_string(), "p".to_string()),
            ]
            .into_iter()
            .collect(),
            note: String::new(),
        };
        let wait = wait_for(PromptKind::AskUserQuestion, proposed);
        let result = answered(
            &wait,
            &input("AskUserQuestion", questions.clone()),
            Some(&json!({"answers": {"B?": "q", "C?": "nope", "A?": " "}})),
        );
        let out: Value = serde_json::from_str(&result.stdout).unwrap();
        let specific = &out["hookSpecificOutput"];
        assert_eq!(specific["permissionDecision"], "allow");
        assert_eq!(
            specific["updatedInput"]["questions"],
            questions["questions"]
        );
        assert_eq!(
            specific["updatedInput"]["answers"],
            json!({"A?": "x", "B?": "q"})
        );
        assert!(specific.get("additionalContext").is_none());
    }

    #[test]
    fn answers_that_do_not_fit_the_prompt_send_nothing() {
        let wait = wait_for(PromptKind::Permission, Proposed::Allow);
        let tool = input("Bash", json!({"command": "ls"}));
        for answer in [
            json!({"release": true}),
            json!({"hold": true}),
            json!({"text": "yes"}),
            json!({"decision": "maybe"}),
            json!("allow"),
        ] {
            assert_eq!(
                answered(&wait, &tool, Some(&answer)),
                HookResult::default(),
                "{answer}"
            );
        }
        assert_eq!(answered(&wait, &tool, None), HookResult::default());
        let denied = answered(&wait, &tool, Some(&json!({"decision": "deny"})));
        assert!(denied.stdout.contains(PERSON_DENIED), "{}", denied.stdout);
        let stop = wait_for(
            PromptKind::StopQuestion,
            Proposed::Reply { text: "go".into() },
        );
        let woke = answered(
            &stop,
            &tool,
            Some(&json!({"text": "  Use the second one "})),
        );
        assert_eq!(woke.code, 2);
        assert_eq!(
            woke.stderr,
            "[Gitrochi] The person answered in Gitrochi: Use the second one"
        );
        assert_eq!(
            answered(&stop, &tool, Some(&json!({"decision": "allow"}))),
            HookResult::default()
        );
        let plan = wait_for(
            PromptKind::ExitPlanMode,
            Proposed::ApprovePlan {
                note: String::new(),
            },
        );
        let refused = answered(
            &plan,
            &input("ExitPlanMode", json!({"plan": "1. Do it"})),
            Some(&json!({"decision": "deny", "message": "Split it in two"})),
        );
        let out: Value = serde_json::from_str(&refused.stdout).unwrap();
        assert_eq!(out["hookSpecificOutput"]["permissionDecision"], "deny");
        assert_eq!(
            out["hookSpecificOutput"]["permissionDecisionReason"],
            "Split it in two"
        );
    }

    #[test]
    fn only_the_stop_hook_may_exit_2() {
        let wake = HookResult {
            stderr: "go".into(),
            code: 2,
            ..HookResult::default()
        };
        assert_eq!(guarded("Stop", wake.clone()), wake);
        for event in [
            "PreToolUse",
            "UserPromptSubmit",
            "PermissionRequest",
            "SessionStart",
        ] {
            let dropped = guarded(event, wake.clone());
            assert_eq!(dropped.code, 0, "{event}");
            assert!(dropped.stdout.is_empty());
        }
        let failed = HookResult {
            code: 101,
            ..HookResult::default()
        };
        assert_eq!(guarded("Stop", failed).code, 0);
    }

    #[test]
    fn bad_input_ends_quietly_with_a_note() {
        let env = HookEnv {
            enabled: true,
            ..HookEnv::default()
        };
        // no session: nothing to do, and quiet
        assert_eq!(run("Stop", "{}", &env), HookResult::default());
        let env = HookEnv {
            session: Some("x y".into()),
            ..env
        };
        let bad = run("PreToolUse", "{}", &env);
        assert_eq!(bad.code, 0);
        assert!(bad.stderr.starts_with("gitrochi-ledger hook: "), "{bad:?}");
        assert_eq!(run("Notification", "{}", &env), HookResult::default());
    }

    #[test]
    fn pushes_to_origins_default_branch_are_held() {
        let dir =
            std::env::temp_dir().join(format!("gitrochi-ledger-hook-push-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = crate::git::tests::fixture_repo(&dir);
        let cwd = repo.to_string_lossy().into_owned();
        let input =
            HookInput::from_value(&json!({"hook_event_name": "PermissionRequest", "cwd": cwd}));
        let policy = Policy {
            enabled: true,
            ..Policy::default()
        };
        let env = HookEnv {
            home: dir.join("home").to_string_lossy().into_owned(),
            ..HookEnv::default()
        };
        let ctx = permission_context(&input, &policy, &env, true);
        assert_eq!(ctx.current_branch.as_deref(), Some("feature/hooks"));
        assert_eq!(ctx.upstream_branch.as_deref(), Some("develop"));
        assert_eq!(ctx.protected_branches, ["develop"]);
        let verdict = |command: &str| {
            gitrochi_autocontinue::evaluate_permission("Bash", &json!({"command": command}), &ctx)
        };
        // a bare push goes to the upstream, origin's default branch here
        assert_eq!(
            verdict("git push").rule(),
            Some(gitrochi_autocontinue::Rule::ProtectedBranchPush)
        );
        assert_eq!(
            verdict("git push origin HEAD:develop").rule(),
            Some(gitrochi_autocontinue::Rule::ProtectedBranchPush)
        );
        assert!(verdict("git push origin feature/hooks").is_allow());
        // without git the branch is unknown, so a bare push is held for the person
        let blind = permission_context(&input, &policy, &env, false);
        assert_eq!(
            (blind.current_branch, blind.repo_root.as_str()),
            (None, cwd.as_str())
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn identifiers_are_short_and_plain() {
        assert_eq!(identifier(" clear ").as_deref(), Some("clear"));
        assert_eq!(identifier("a\u{7}b"), None);
        assert_eq!(identifier(&"x".repeat(201)), None);
        assert_eq!(identifier(""), None);
    }
}
