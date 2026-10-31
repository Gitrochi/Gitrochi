//! Agent reports. Every path an agent has (MCP, the CLI, pasted blocks) ends here, inside
//! one write transaction: find or create the session, apply the resume rules and the
//! event's effect, store questions and the body, then hand the agent what a person left.

use crate::baseline;
use crate::error::{Error, Result};
use crate::event::{self, Message, NewEvent};
use crate::overlap;
use crate::session::{self, SessionRow, SessionView, Viewer};
use crate::settings::Settings;
use crate::util::{self, arg_str, arg_str_any, clean, json_text, resolve_version, Ms};
use crate::vocab::{self, Role, AGENT_EVENTS, REOPEN_EVENTS};
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::cmp::Ordering;

/// Report bodies are kept up to this many characters (the cut note included).
pub const BODY_MAX: usize = 60_000;
const CUT_NOTE: &str = "\n\n…(cut by the ledger: the report body was too long)";

/// What a report changed, and what the agent should know now.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportReply {
    pub session_id: String,
    pub notices: Vec<String>,
    pub messages: Vec<Message>,
    pub created: bool,
    pub event: &'static str,
    pub session: SessionView,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    pub question_ids: Vec<i64>,
}

/// The project a report belongs to, for scanning its baselines before the write.
pub fn project_of(connection: &Connection, args: &Value) -> Result<Option<String>> {
    if let Some(project) = arg_str(args, "project") {
        return Ok(Some(project));
    }
    match arg_str_any(args, &["session", "sessionId"]) {
        Some(id) => Ok(session::load(connection, &id)?.map(|s| s.project)),
        None => Ok(None),
    }
}

fn new_id(connection: &Connection, ts: Ms) -> Result<String> {
    let day: String = connection.query_row(
        "SELECT strftime('%m%d', ?1 / 1000, 'unixepoch', 'localtime')",
        [ts],
        |r| r.get(0),
    )?;
    let prefix = format!("S{day}-");
    let mut n: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sessions WHERE id LIKE ?1",
        [format!("{prefix}%")],
        |r| r.get(0),
    )?;
    loop {
        n += 1;
        let id = format!("{prefix}{n:02}");
        if session::load(connection, &id)?.is_none() {
            return Ok(id);
        }
    }
}

/// `questions`: one text, or a list of texts (a single string is one question, commas and all).
fn question_texts(value: &Value) -> Vec<String> {
    match value {
        Value::String(text) => clean(text).into_iter().collect(),
        Value::Array(items) => items
            .iter()
            .filter_map(|v| match v {
                Value::String(s) => clean(s),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn is_link(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

fn cut_body(text: &str) -> (String, bool) {
    if text.chars().count() <= BODY_MAX {
        return (text.to_string(), false);
    }
    let keep = BODY_MAX - CUT_NOTE.chars().count();
    let mut out: String = text.chars().take(keep).collect();
    out.push_str(CUT_NOTE);
    (out, true)
}

/// Records one report. `ts` is the event's time; `now` is used for the reply's verdicts.
pub fn report(
    connection: &Connection,
    settings: &Settings,
    args: &Value,
    channel: &str,
    ts: Ms,
    now: Ms,
) -> Result<ReportReply> {
    if !args.is_object() {
        return Err(Error::invalid("A report is a JSON object"));
    }
    let raw_event = arg_str(args, "event").unwrap_or_else(|| "progress".into());
    let mut event = vocab::agent_event(&raw_event).ok_or_else(|| {
        Error::invalid(format!(
            "Unknown event '{raw_event}' (allowed: {})",
            AGENT_EVENTS.join(", ")
        ))
    })?;
    let session_arg = arg_str_any(args, &["session", "sessionId"]);
    let project_arg = arg_str(args, "project");
    let mut summary = arg_str(args, "summary").unwrap_or_default();
    let mut notices: Vec<String> = Vec::new();

    let existing = match &session_arg {
        Some(id) => session::load(connection, id)?,
        None => None,
    };
    if let (Some(found), Some(project)) = (&existing, &project_arg) {
        if *project != found.project {
            return Err(Error::conflict(format!(
                "Session {} belongs to project '{}'",
                found.id, found.project
            )));
        }
    }
    let project = match (&existing, project_arg) {
        (Some(found), _) => found.project.clone(),
        (None, Some(project)) => project,
        (None, None) => {
            return Err(Error::invalid(
                "A new session needs a project (for example \"Example App\")",
            ))
        }
    };
    baseline::ensure_project(connection, &project, ts)?;
    let head = baseline::head(connection, &project)?;

    let mut created = false;
    let mut row: SessionRow = match existing {
        Some(found) => {
            if event == "start" {
                if let Some(title) = arg_str(args, "title") {
                    if title != found.title {
                        return Err(Error::conflict(format!(
                            "Session ID '{}' already exists with another title ('{}'); use another ID",
                            found.id, found.title
                        )));
                    }
                }
                event = "progress";
                notices.push(
                    "The session had already started, so this was recorded as progress.".into(),
                );
            }
            found
        }
        None => {
            if let Some(id) = &session_arg {
                if !util::valid_session_id(id) {
                    return Err(Error::invalid(
                        "A session ID is 3–48 letters, digits, '.', '_' or '-'",
                    ));
                }
            }
            let id = match &session_arg {
                Some(id) => id.clone(),
                None => new_id(connection, ts)?,
            };
            let (base, was_latest) = match arg_str(args, "base") {
                None => {
                    notices.push(
                        "No base (the baseline this work started from), so the graph cannot connect the session to the trunk."
                            .into(),
                    );
                    (None, false)
                }
                Some(text) => match util::parse_version(&text).as_deref() {
                    None => {
                        notices.push(format!(
                            "Could not read base '{text}' as a version (for example 1.4.2)."
                        ));
                        (None, false)
                    }
                    Some("latest") => match &head {
                        Some(head) => (Some(head.clone()), true),
                        None => {
                            notices.push(
                                "No baseline is known yet, so 'latest' could not be resolved; send a version number as base."
                                    .into(),
                            );
                            (None, false)
                        }
                    },
                    Some(version) => (Some(version.to_string()), false),
                },
            };
            if let Some(base) = &base {
                baseline::ensure(connection, &project, base, ts - 1000)?;
            }
            let count: i64 = connection.query_row(
                "SELECT COUNT(*) FROM sessions WHERE project = ?1",
                [&project],
                |r| r.get(0),
            )?;
            let title = arg_str(args, "title").unwrap_or_else(|| {
                if summary.is_empty() {
                    "(untitled)".into()
                } else {
                    util::truncate(&summary, 40)
                }
            });
            let kind = arg_str(args, "kind").map_or_else(String::new, |k| vocab::kind(&k));
            connection.execute(
                "INSERT INTO sessions (id, project, kind, title, base_version, base_current,
                    base_was_latest, status, channel, color, created_at, last_at, last_agent_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, 'active', ?7, ?8, ?9, ?9, ?9)",
                params![
                    id,
                    project,
                    kind,
                    title,
                    base,
                    was_latest as i64,
                    channel,
                    count % 8,
                    ts
                ],
            )?;
            created = true;
            if event != "start" {
                event::insert(
                    connection,
                    &NewEvent {
                        session_id: &id,
                        project: &project,
                        ts: ts - 1,
                        kind: "start",
                        actor: "agent",
                        summary: &format!("(automatic start) {title}"),
                        body: None,
                        version: base.as_deref(),
                        artifacts: &json!([]),
                        data: &json!({"automatic": true}),
                        channel,
                        delivered_at: None,
                    },
                )?;
                notices.push("There was no such session, so it was registered.".into());
            }
            session::require(connection, &id)?
        }
    };
    let sid = row.id.clone();

    // Plain field updates.
    if !created {
        if let Some(title) = arg_str(args, "title") {
            row.title = title;
        }
    }
    if let Some(kind) = arg_str(args, "kind") {
        row.kind = vocab::kind(&kind);
    }
    if let Some(url) = arg_str_any(args, &["chatUrl", "chat_url"]) {
        if is_link(&url) {
            row.chat_url = Some(url);
        } else {
            notices.push("chatUrl was ignored: only http(s) links are kept.".into());
        }
    }
    util::union(&mut row.touches, util::arg_list(args, "touches"));
    util::union(&mut row.related, util::arg_list(args, "related"));

    // Resume rules: new work on a session that is not active makes it active again, and any
    // report but a note or heartbeat brings an archived session back.
    let mut data = Map::new();
    if !created && REOPEN_EVENTS.contains(&event) && row.status != "active" {
        notices.push(format!(
            "The session was {}; new work made it active again and cleared its confirmation.",
            vocab::status_label(&row.status)
        ));
        data.insert("reopenedFrom".into(), json!(row.status));
        row.status = "active".into();
        row.merged_into = None;
        row.archived_at = None;
    }
    if !created && row.archived_at.is_some() && !matches!(event, "note" | "heartbeat") {
        row.archived_at = None;
        notices.push("The session was archived; this report brought it back.".into());
    }

    let role = settings.role(&row.kind);
    let mut version = resolve_version(arg_str(args, "ssot").as_deref(), head.as_deref());
    match event {
        "sync" => {
            let target = resolve_version(
                arg_str_any(args, &["version", "base"]).as_deref(),
                head.as_deref(),
            )
            .ok_or_else(|| Error::invalid("sync needs version (the newer baseline)"))?;
            baseline::ensure(connection, &project, &target, ts - 1000)?;
            data.insert("from".into(), json!(row.base_current));
            data.insert("to".into(), json!(target));
            row.base_current = Some(target.clone());
            version = Some(target.clone());
            if settings.hands_off(&row.kind) {
                let handed = hand_off_sync(
                    connection,
                    settings,
                    &row,
                    &target,
                    ts,
                    channel,
                    &mut notices,
                )?;
                if !handed.is_empty() {
                    data.insert("handoff".into(), json!(handed));
                }
            }
        }
        "done" => row.status = "done".into(),
        "shelved" => {
            if !role.may_shelve() {
                return Err(Error::invalid(format!(
                    "Only research and document sessions can be shelved (this one is '{}'). \
                     Use closed when nothing needs merging, or dropped to discard the result.",
                    if row.kind.is_empty() { "-" } else { &row.kind }
                )));
            }
            row.status = "shelved".into();
        }
        "closed" | "dropped" => row.status = event.into(),
        "merged" => {
            match resolve_version(arg_str_any(args, &["into", "version"]).as_deref(), head.as_deref()) {
                Some(into) => {
                    baseline::ensure(connection, &project, &into, ts + 1000)?;
                    data.insert("into".into(), json!(into));
                    row.merged_into = Some(into.clone());
                    version = Some(into);
                }
                None => notices.push(
                    "No into (the baseline it was merged into), so the graph cannot join it to the trunk."
                        .into(),
                ),
            }
            row.status = "merged".into();
        }
        "release" => {
            let released = arg_str(args, "version")
                .and_then(|v| util::parse_version(&v))
                .filter(|v| v != "latest")
                .ok_or_else(|| {
                    Error::invalid("release needs version (the new baseline's number)")
                })?;
            let note = arg_str(args, "note").unwrap_or_else(|| summary.clone());
            baseline::release(connection, &project, &released, ts + 1, &note, &sid)?;
            if let Some(head) = &head {
                if util::compare_versions(&released, head) == Ordering::Less {
                    notices.push(format!("Release {released} is lower than HEAD {head}."));
                }
            }
            row.base_current = Some(released.clone());
            data.insert("version".into(), json!(released));
            version = Some(released.clone());
            let mut absorbed = Vec::new();
            for other in util::arg_list(args, "absorbs") {
                let target = session::load(connection, &other)?;
                let Some(target) = target.filter(|t| t.project == project && t.id != sid) else {
                    notices.push(format!("Could not find session {other} to absorb."));
                    continue;
                };
                connection.execute(
                    "UPDATE sessions SET status = 'merged', merged_into = ?2, ack_at = NULL,
                        archived_at = NULL, last_at = ?3 WHERE id = ?1",
                    params![target.id, released, ts],
                )?;
                event::insert(
                    connection,
                    &NewEvent {
                        session_id: &target.id,
                        project: &project,
                        ts,
                        kind: "merged",
                        actor: "agent",
                        summary: &format!("Merged into {released} by {sid}'s release"),
                        body: None,
                        version: Some(&released),
                        artifacts: &json!([]),
                        data: &json!({"into": released, "by": sid, "fromStatus": target.status}),
                        channel,
                        delivered_at: None,
                    },
                )?;
                absorbed.push(target.id);
            }
            data.insert("absorbs".into(), json!(absorbed));
        }
        "applied" => {
            let applied = resolve_version(
                arg_str_any(args, &["version", "ssot"]).as_deref(),
                head.as_deref(),
            )
            .ok_or_else(|| {
                Error::invalid("applied needs version (the baseline that was applied)")
            })?;
            baseline::ensure(connection, &project, &applied, ts - 1000)?;
            let ahead = row.base_current.as_deref().is_none_or(|current| {
                util::compare_versions(&applied, current) == Ordering::Greater
            });
            if ahead {
                // The session's own base only moves forward.
                data.insert("from".into(), json!(row.base_current));
                row.base_current = Some(applied.clone());
            }
            data.insert("version".into(), json!(applied));
            version = Some(applied.clone());
            if role != Role::Implementation {
                data.insert("targets".into(), json!([]));
                notices.push(format!(
                    "Recorded v{applied} as applied. Only implementation sessions confirm decision sessions with applied."
                ));
            } else if !settings.hands_off(&row.kind) {
                let line = settings.line(&row.kind).unwrap_or_default();
                data.insert("line".into(), json!(line));
                data.insert("targets".into(), json!([]));
                notices.push(format!(
                    "The {line} line's applied v{applied} marks its cycle only; decision sessions are confirmed by hand-off lines."
                ));
            } else {
                let (done, skipped) = hand_off_applied(
                    connection,
                    settings,
                    args,
                    &row,
                    &applied,
                    ts,
                    channel,
                    &mut notices,
                )?;
                data.insert("targets".into(), json!(done));
                if !skipped.is_empty() {
                    data.insert("skipped".into(), json!(skipped));
                }
            }
        }
        _ => {}
    }

    if !matches!(event, "note" | "heartbeat") {
        // New information: a person has to confirm again.
        row.ack_at = None;
    }

    let artifacts = artifacts(connection, args, &project, &row, head.as_deref(), ts)?;
    if version.is_none() && !artifacts.is_empty() {
        // The event points at a baseline when all its artifacts agree on one.
        let versions: std::collections::BTreeSet<&str> = artifacts
            .iter()
            .filter_map(|a| a["ssot"].as_str())
            .collect();
        if versions.len() == 1 {
            version = versions.into_iter().next().map(str::to_string);
        }
    }

    let mut body = None;
    if event != "heartbeat" {
        if let Some(text) = args["body"].as_str() {
            let text = util::nfc_text(text).replace("\r\n", "\n");
            let text = text.trim();
            if !text.is_empty() {
                let (kept, cut) = cut_body(text);
                if cut {
                    notices.push(format!(
                        "The body was longer than {BODY_MAX} characters and was cut."
                    ));
                }
                body = Some(kept);
            }
        }
    }
    let work = util::arg_list(args, "work");
    if !work.is_empty() {
        data.insert("work".into(), json!(work));
    }

    let mut question_ids = Vec::new();
    for text in question_texts(&args["questions"]) {
        question_ids.push(event::add_question(connection, &sid, &text, ts)?);
    }
    if !question_ids.is_empty() {
        data.insert("questionIds".into(), json!(question_ids));
    }
    if event == "question" {
        let text = arg_str(args, "question")
            .or_else(|| (!summary.is_empty()).then(|| summary.clone()))
            .ok_or_else(|| Error::invalid("A question event needs question (the text to ask)"))?;
        let id = event::add_question(connection, &sid, &text, ts)?;
        data.insert("questionId".into(), json!(id));
        question_ids.insert(0, id);
        if summary.is_empty() {
            summary = text;
        }
    }

    for id in util::arg_ints(args, "resolves") {
        connection.execute(
            "UPDATE questions SET state = 'answered', answer = COALESCE(answer, ?3),
                answered_by = 'agent', answered_at = ?4, delivered_at = ?4
             WHERE id = ?1 AND session_id = ?2 AND state = 'open'",
            params![
                id,
                sid,
                if summary.is_empty() {
                    "(settled in the session)"
                } else {
                    summary.as_str()
                },
                ts
            ],
        )?;
    }

    if event != "heartbeat" {
        event::insert(
            connection,
            &NewEvent {
                session_id: &sid,
                project: &project,
                ts,
                kind: event,
                actor: "agent",
                summary: &summary,
                body: body.as_deref(),
                version: version.as_deref(),
                artifacts: &Value::Array(artifacts),
                data: &Value::Object(data),
                channel,
                delivered_at: None,
            },
        )?;
    }

    connection.execute(
        "UPDATE sessions SET kind = ?2, title = ?3, base_current = ?4, status = ?5, merged_into = ?6,
            touches = ?7, related = ?8, chat_url = ?9, last_at = ?10, last_agent_at = ?10,
            ack_at = ?11, archived_at = ?12
         WHERE id = ?1",
        params![
            sid,
            row.kind,
            row.title,
            row.base_current,
            row.status,
            row.merged_into,
            json_text(&row.touches),
            json_text(&row.related),
            row.chat_url,
            ts,
            row.ack_at,
            row.archived_at,
        ],
    )?;

    // The reply: the session as it is now, what the agent should know, a person's messages.
    let trunk = baseline::trunk(connection, &project)?;
    let head = trunk.last().map(|b| b.version.clone());
    let viewer = Viewer {
        settings,
        versions: trunk.iter().map(|b| b.version.clone()).collect(),
        now,
    };
    let counts = session::open_counts(connection, Some(&project))?;
    let views: Vec<SessionView> = session::list(connection, Some(&project))?
        .iter()
        .map(|s| viewer.view(s, counts.get(&s.id).copied().unwrap_or(0)))
        .collect();
    let view = views
        .iter()
        .find(|v| v.id == sid)
        .cloned()
        .ok_or_else(|| Error::not_found(format!("No session {sid}")))?;
    add_context_notices(&view, &views, event, head.as_deref(), &mut notices);
    let messages = event::deliver(connection, &sid, now)?;
    Ok(ReportReply {
        session_id: sid,
        notices,
        messages,
        created,
        event,
        session: view,
        head,
        question_ids,
    })
}

fn artifacts(
    connection: &Connection,
    args: &Value,
    project: &str,
    row: &SessionRow,
    head: Option<&str>,
    ts: Ms,
) -> Result<Vec<Value>> {
    let mut raw: Vec<Value> = match &args["artifacts"] {
        Value::Array(items) => items.clone(),
        value @ (Value::Object(_) | Value::String(_)) => vec![value.clone()],
        _ => Vec::new(),
    };
    if !args["artifact"].is_null() {
        raw.push(args["artifact"].clone());
    }
    let mut out = Vec::new();
    for item in raw {
        let item = match item {
            Value::String(name) => json!({"name": name}),
            Value::Object(_) => item,
            _ => continue,
        };
        let Some(name) = arg_str(&item, "name") else {
            continue;
        };
        let mut ssot = resolve_version(arg_str(&item, "ssot").as_deref(), head);
        let inferred = ssot.is_none();
        if inferred {
            ssot = row.base_current.clone();
        }
        if let Some(version) = &ssot {
            baseline::ensure(connection, project, version, ts - 1000)?;
        }
        let mut artifact = json!({"name": name});
        if let Some(version) = ssot {
            artifact["ssot"] = json!(version);
            if inferred {
                artifact["ssotInferred"] = json!(true);
            }
        }
        for key in ["ver", "path", "note"] {
            if let Some(value) = arg_str(&item, key) {
                artifact[key] = json!(value);
            }
        }
        out.push(artifact);
    }
    Ok(out)
}

/// An implementation session synced vX: the live decision session that released vX moves
/// to merged, not confirmed. Finished or archived sessions are left alone, so syncing the
/// same version twice hands off once.
fn hand_off_sync(
    connection: &Connection,
    settings: &Settings,
    from: &SessionRow,
    version: &str,
    ts: Ms,
    channel: &str,
    notices: &mut Vec<String>,
) -> Result<Vec<String>> {
    let Some(target) = baseline::released_by(connection, &from.project, version)? else {
        return Ok(Vec::new());
    };
    if target == from.id {
        return Ok(Vec::new());
    }
    let Some(target) = session::load(connection, &target)? else {
        return Ok(Vec::new());
    };
    if target.project != from.project
        || settings.role(&target.kind) != Role::Decision
        || vocab::is_terminal(&target.status)
        || target.archived_at.is_some()
    {
        return Ok(Vec::new());
    }
    connection.execute(
        "UPDATE sessions SET status = 'merged', merged_into = ?2, last_at = ?3 WHERE id = ?1",
        params![target.id, version, ts],
    )?;
    event::insert(
        connection,
        &NewEvent {
            session_id: &target.id,
            project: &target.project,
            ts,
            kind: "merged",
            actor: "agent",
            summary: &format!(
                "{} synced v{version}: merged (its applied report will confirm it)",
                from.id
            ),
            body: None,
            version: Some(version),
            artifacts: &json!([]),
            data: &json!({"into": version, "by": from.id, "via": "sync", "fromStatus": target.status}),
            channel,
            delivered_at: None,
        },
    )?;
    let open = session::open_count(connection, &target.id)?;
    notices.push(format!(
        "{} → v{version} merged (sync seen; applied will confirm it){}",
        target.id,
        if open > 0 {
            format!(". Its {open} open question(s) still need a person.")
        } else {
            String::new()
        }
    ));
    Ok(vec![target.id])
}

/// An implementation session applied vX because a person told it to: the targets (or the
/// session that released vX) that are decision sessions become merged and confirmed. This
/// is the only way an agent's report confirms anything. Open questions are left alone.
#[allow(clippy::too_many_arguments)]
fn hand_off_applied(
    connection: &Connection,
    settings: &Settings,
    args: &Value,
    from: &SessionRow,
    version: &str,
    ts: Ms,
    channel: &str,
    notices: &mut Vec<String>,
) -> Result<(Vec<String>, Vec<String>)> {
    let mut targets = util::arg_list(args, "targets");
    if targets.is_empty() {
        match baseline::released_by(connection, &from.project, version)? {
            Some(by) => targets.push(by),
            None => notices.push(format!(
                "No session is recorded as releasing v{version}, so no decision session was confirmed. \
                 Name it in targets if you know it."
            )),
        }
    }
    let (mut done, mut skipped) = (Vec::new(), Vec::new());
    for id in targets {
        if id == from.id {
            continue;
        }
        let target = session::load(connection, &id)?.filter(|t| t.project == from.project);
        let Some(target) = target else {
            notices.push(format!("Could not find session {id} to confirm."));
            skipped.push(id);
            continue;
        };
        if settings.role(&target.kind) != Role::Decision {
            notices.push(format!(
                "{id} is not a decision session (kind '{}'), so it was skipped; a person handles it.",
                if target.kind.is_empty() { "-" } else { &target.kind }
            ));
            skipped.push(id);
            continue;
        }
        if target.status == "merged"
            && target.merged_into.as_deref() == Some(version)
            && target.ack_at.is_some()
        {
            notices.push(format!(
                "{id} is already merged into v{version} and confirmed."
            ));
            continue;
        }
        connection.execute(
            "UPDATE sessions SET status = 'merged', merged_into = ?2, ack_at = ?3, archived_at = NULL,
                last_at = ?3 WHERE id = ?1",
            params![id, version, ts],
        )?;
        event::insert(
            connection,
            &NewEvent {
                session_id: &id,
                project: &from.project,
                ts,
                kind: "applied",
                actor: "agent",
                summary: &format!(
                    "{} reported v{version} applied: merged and confirmed",
                    from.id
                ),
                body: None,
                version: Some(version),
                artifacts: &json!([]),
                data: &json!({"by": from.id, "version": version, "fromStatus": target.status}),
                channel,
                delivered_at: None,
            },
        )?;
        let open = session::open_count(connection, &id)?;
        notices.push(if open > 0 {
            format!(
                "{id} → v{version} merged and confirmed. Its {open} open question(s) keep it at Needs a person."
            )
        } else {
            format!("{id} → v{version} merged and confirmed: ready to archive.")
        });
        done.push(id);
    }
    Ok((done, skipped))
}

fn add_context_notices(
    view: &SessionView,
    views: &[SessionView],
    event: &str,
    head: Option<&str>,
    notices: &mut Vec<String>,
) {
    if event == "done" && view.open_questions > 0 {
        notices.push(format!(
            "{} open question(s) remain, so the session shows Needs a person.",
            view.open_questions
        ));
    }
    if let (Some(behind), Some(base), Some(head)) = (view.behind, &view.base_current, head) {
        if behind > 0
            && matches!(event, "start" | "sync" | "artifact" | "release" | "applied")
            && !vocab::is_terminal(&view.status)
        {
            notices.push(format!(
                "This session's base {base} is {behind} baseline(s) behind HEAD {head}."
            ));
        }
    }
    let others: Vec<&SessionView> = views
        .iter()
        .filter(|o| o.id != view.id && o.archived_at.is_none())
        .collect();
    let live: Vec<&&SessionView> = others
        .iter()
        .filter(|o| o.is_live() && !o.is_stream())
        .collect();
    if !view.touches.is_empty() && view.status != "shelved" && !view.is_stream() {
        for other in &live {
            let common = overlap::shared(&view.touches, &other.touches);
            if !common.is_empty() {
                notices.push(format!(
                    "Overlap: {} ({}, base {}, {}) also touches {} — watch for conflicting results.",
                    other.id,
                    if other.kind.is_empty() { "-" } else { &other.kind },
                    other.base_current.as_deref().unwrap_or("?"),
                    other.verdict.label(),
                    common.join(", ")
                ));
            }
        }
    }
    if event == "start" && !live.is_empty() {
        let list: Vec<String> = live
            .iter()
            .take(8)
            .map(|o| {
                format!(
                    "{} {} “{}” (base {})",
                    o.id,
                    o.kind,
                    o.title,
                    o.base_current.as_deref().unwrap_or("?")
                )
            })
            .collect();
        notices.push(format!(
            "Other open sessions in this project ({}): {}",
            live.len(),
            list.join("; ")
        ));
    }
    if event == "start" && !view.touches.is_empty() {
        for other in others.iter().filter(|o| o.status == "shelved") {
            let common = overlap::shared(&view.touches, &other.touches);
            if !common.is_empty() {
                notices.push(format!(
                    "For reference: shelved {} ({} “{}”, base {}) also covered {}; its material may help.",
                    other.id,
                    if other.kind.is_empty() { "-" } else { &other.kind },
                    other.title,
                    other.base_current.as_deref().unwrap_or("?"),
                    common.join(", ")
                ));
            }
        }
    }
}
