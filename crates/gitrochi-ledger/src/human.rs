//! A person's operations from the apps: confirming, archiving, setting a status, answering
//! and the like. They are judgements, so no agent path (MCP, the CLI) reaches them. Each
//! one is recorded as an event with `actor = human`; answers, notes and status changes
//! wait there until the session's agent picks them up.

use crate::baseline;
use crate::db::Db;
use crate::error::{Error, Result};
use crate::event::{self, NewEvent};
use crate::session;
use crate::settings::{self, Settings};
use crate::util::{self, arg_str, arg_str_any, Ms, HOUR};
use crate::vocab::{self, HUMAN_ACTIONS, STATUSES};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};

const LINK_KEYS: [&str; 6] = [
    "repoPath",
    "branch",
    "worktree",
    "agentId",
    "agentSessionId",
    "cwd",
];

struct Recorder<'a> {
    connection: &'a Connection,
    session_id: String,
    project: String,
    now: Ms,
}

impl Recorder<'_> {
    /// Records the operation; `deliver` keeps it waiting for the session's agent.
    fn record(&self, kind: &str, summary: &str, data: Value, deliver: bool) -> Result<i64> {
        event::insert(
            self.connection,
            &NewEvent {
                session_id: &self.session_id,
                project: &self.project,
                ts: self.now,
                kind,
                actor: "human",
                summary,
                body: None,
                version: None,
                artifacts: &json!([]),
                data: &data,
                channel: "app",
                delivered_at: (!deliver).then_some(self.now),
            },
        )
    }
}

fn question_id(args: &Value) -> Result<i64> {
    ["questionId", "question", "id", "item"]
        .iter()
        .find_map(|key| util::arg_i64(args, key).ok().flatten())
        .ok_or_else(|| Error::invalid("Missing questionId"))
}

/// Runs one operation. `args` = `{action, sessionId, …}`.
pub fn apply(connection: &Connection, settings: &Settings, args: &Value, now: Ms) -> Result<()> {
    let action = arg_str(args, "action").ok_or_else(|| Error::invalid("Missing action"))?;
    if !HUMAN_ACTIONS.contains(&action.as_str()) {
        return Err(Error::invalid(format!(
            "Unknown action {action} (allowed: {})",
            HUMAN_ACTIONS.join(", ")
        )));
    }
    if action == "answer" || action == "dismiss" {
        return answer(connection, args, &action, now);
    }
    let id = arg_str_any(args, &["sessionId", "session"])
        .ok_or_else(|| Error::invalid("Missing sessionId"))?;
    let row = session::require(connection, &id)?;
    let recorder = Recorder {
        connection,
        session_id: row.id.clone(),
        project: row.project.clone(),
        now,
    };
    match action.as_str() {
        "ack" => {
            connection.execute(
                "UPDATE sessions SET ack_at = ?2 WHERE id = ?1",
                params![id, now],
            )?;
            recorder.record("ack", "Confirmed by a person", json!({}), false)?;
        }
        "unack" => {
            connection.execute("UPDATE sessions SET ack_at = NULL WHERE id = ?1", [&id])?;
            recorder.record("unack", "Confirmation withdrawn", json!({}), false)?;
        }
        "archive" => {
            connection.execute(
                "UPDATE sessions SET archived_at = ?2 WHERE id = ?1",
                params![id, now],
            )?;
            recorder.record(
                "archive",
                "Archived: the conversation was cleaned up",
                json!({}),
                false,
            )?;
        }
        "unarchive" => {
            connection.execute(
                "UPDATE sessions SET archived_at = NULL WHERE id = ?1",
                [&id],
            )?;
            recorder.record("unarchive", "Unarchived", json!({}), false)?;
        }
        "set_status" | "shelve" => {
            let status = if action == "shelve" {
                "shelved".to_string()
            } else {
                arg_str(args, "status").ok_or_else(|| Error::invalid("Missing status"))?
            };
            set_status(
                connection, settings, &recorder, &row, &action, &status, args,
            )?;
        }
        "snooze" => {
            let until = match (util::arg_i64(args, "until")?, args["hours"].as_f64()) {
                (Some(until), _) => until,
                (None, Some(hours)) if hours > 0.0 => now + (hours * HOUR as f64) as Ms,
                _ => now + settings.stale_ms(),
            };
            if until <= now {
                return Err(Error::invalid("until must be in the future"));
            }
            connection.execute(
                "UPDATE sessions SET snooze_until = ?2 WHERE id = ?1",
                params![id, until],
            )?;
            recorder.record(
                "snooze",
                "Marked as still active (not abandoned)",
                json!({"until": until}),
                false,
            )?;
        }
        "link" => link(connection, &recorder, &row, args)?,
        "message" => {
            let text = arg_str_any(args, &["text", "message"])
                .ok_or_else(|| Error::invalid("The message is empty"))?;
            recorder.record("message", &text, json!({}), true)?;
        }
        "auto_continue" => {
            let policy = match args.get("autoContinue").or_else(|| args.get("policy")) {
                None | Some(Value::Null) => None,
                Some(value) => Some(settings::session_auto_continue(value)?),
            };
            connection.execute(
                "UPDATE sessions SET auto_continue = ?2 WHERE id = ?1",
                params![id, policy.as_ref().map(Value::to_string)],
            )?;
            let summary = match &policy {
                Some(p) if p["enabled"] == json!(true) => {
                    format!("Auto-continue on after {} s", p["delaySec"])
                }
                Some(_) => "Auto-continue off".to_string(),
                None => "Auto-continue follows the default".to_string(),
            };
            recorder.record(
                "auto_continue",
                &summary,
                json!({"autoContinue": policy}),
                false,
            )?;
        }
        _ => unreachable!("checked against HUMAN_ACTIONS"),
    }
    Ok(())
}

fn set_status(
    connection: &Connection,
    settings: &Settings,
    recorder: &Recorder,
    row: &session::SessionRow,
    action: &str,
    status: &str,
    args: &Value,
) -> Result<()> {
    if !STATUSES.contains(&status) {
        return Err(Error::invalid(format!(
            "Unknown status {status} (allowed: {})",
            STATUSES.join(", ")
        )));
    }
    if status == "shelved" && !settings.role(&row.kind).may_shelve() {
        return Err(Error::invalid(
            "Only research and document sessions can be shelved",
        ));
    }
    let now = recorder.now;
    let mut into = None;
    if status == "merged" {
        let head = baseline::head(connection, &row.project)?;
        let version = util::resolve_version(
            arg_str_any(args, &["into", "version"]).as_deref(),
            head.as_deref(),
        )
        .ok_or_else(|| {
            Error::invalid("Name the baseline it was merged into (for example 1.4.2)")
        })?;
        baseline::ensure(connection, &row.project, &version, now + 1000)?;
        into = Some(version);
    }
    // A finishing status a person chooses counts as confirmed; going back to active also
    // brings an archived session back.
    let ack = vocab::is_terminal(status).then_some(now);
    let archived = if status == "active" {
        None
    } else {
        row.archived_at
    };
    connection.execute(
        "UPDATE sessions SET status = ?2, merged_into = ?3, ack_at = ?4, archived_at = ?5 WHERE id = ?1",
        params![row.id, status, into, ack, archived],
    )?;
    let mut summary = format!("Status → {}", vocab::status_label(status));
    if let Some(into) = &into {
        summary.push_str(&format!(" ({into})"));
    }
    if let Some(reason) = arg_str_any(args, &["reason", "text"]) {
        summary.push_str(&format!(": {reason}"));
    }
    recorder.record(
        action,
        &summary,
        json!({"status": status, "into": into, "fromStatus": row.status}),
        true,
    )?;
    Ok(())
}

fn link(
    connection: &Connection,
    recorder: &Recorder,
    row: &session::SessionRow,
    args: &Value,
) -> Result<()> {
    let mut links = match &row.links {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    let mut changed = Vec::new();
    for key in LINK_KEYS {
        match args.get(key) {
            None => {}
            Some(Value::Null) => {
                if links.remove(key).is_some() {
                    changed.push(key.to_string());
                }
            }
            Some(Value::String(text)) => {
                match util::clean(text) {
                    Some(text) => links.insert(key.into(), json!(text)),
                    None => links.remove(key),
                };
                changed.push(key.to_string());
            }
            Some(_) => return Err(Error::invalid(format!("{key} must be text"))),
        }
    }
    match args.get("pr") {
        None => {}
        Some(Value::Null) => {
            links.remove("pr");
            changed.push("pr".into());
        }
        Some(pr) => {
            let url = arg_str(pr, "url")
                .filter(|u| u.starts_with("https://") || u.starts_with("http://"));
            let number = pr["number"].as_i64();
            let host = arg_str(pr, "host");
            match (host, number, url) {
                (Some(host), Some(number), Some(url)) => {
                    links.insert(
                        "pr".into(),
                        json!({"host": host, "number": number, "url": url}),
                    );
                    changed.push("pr".into());
                }
                _ => return Err(Error::invalid("pr needs host, number and an http(s) url")),
            }
        }
    }
    let mut chat_url = row.chat_url.clone();
    if let Some(value) = args.get("chatUrl") {
        chat_url = match value {
            Value::Null => None,
            Value::String(text) => match util::clean(text) {
                None => None,
                Some(url) if url.starts_with("https://") || url.starts_with("http://") => Some(url),
                Some(_) => {
                    return Err(Error::invalid(
                        "A chat link starts with http:// or https://",
                    ))
                }
            },
            _ => return Err(Error::invalid("chatUrl must be text")),
        };
        changed.push("chatUrl".into());
    }
    if changed.is_empty() {
        return Err(Error::invalid(
            "Nothing to link: give branch, worktree, repoPath, pr, chatUrl, agentId, agentSessionId or cwd",
        ));
    }
    connection.execute(
        "UPDATE sessions SET links = ?2, chat_url = ?3 WHERE id = ?1",
        params![row.id, Value::Object(links).to_string(), chat_url],
    )?;
    recorder.record(
        "link",
        &format!("Linked: {}", changed.join(", ")),
        json!({"changed": changed}),
        false,
    )?;
    Ok(())
}

fn answer(connection: &Connection, args: &Value, action: &str, now: Ms) -> Result<()> {
    let id = question_id(args)?;
    let found: Option<(String, String, String)> = connection
        .query_row(
            "SELECT q.session_id, s.project, q.state FROM questions q JOIN sessions s ON s.id = q.session_id
             WHERE q.id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let (session_id, project, state) =
        found.ok_or_else(|| Error::not_found(format!("No question #{id}")))?;
    if state != "open" {
        return Err(Error::new("CONFLICT", "The question was already answered."));
    }
    if let Some(given) = arg_str_any(args, &["sessionId", "session"]) {
        if given != session_id {
            return Err(Error::invalid(format!(
                "Question #{id} belongs to session {session_id}"
            )));
        }
    }
    let recorder = Recorder {
        connection,
        session_id,
        project,
        now,
    };
    if action == "answer" {
        let text = arg_str_any(args, &["answer", "text"])
            .ok_or_else(|| Error::invalid("The answer is empty"))?;
        connection.execute(
            "UPDATE questions SET state = 'answered', answer = ?2, answered_by = 'human',
                answered_at = ?3, delivered_at = NULL WHERE id = ?1",
            params![id, text, now],
        )?;
        recorder.record(
            "answer",
            &format!("Answered question #{id}: {text}"),
            json!({"questionId": id}),
            false,
        )?;
    } else {
        connection.execute(
            "UPDATE questions SET state = 'dismissed', answered_by = 'human', answered_at = ?2,
                delivered_at = NULL WHERE id = ?1",
            params![id, now],
        )?;
        recorder.record(
            "dismiss",
            &format!("Dismissed question #{id}"),
            json!({"questionId": id}),
            false,
        )?;
    }
    Ok(())
}

fn metadata_text(args: &Value, key: &str, maximum: usize, empty: bool) -> Result<String> {
    let raw = args[key]
        .as_str()
        .ok_or_else(|| Error::invalid(format!("{key} must be text")))?;
    let text = util::nfc_text(raw).trim().to_string();
    if (!empty && text.is_empty())
        || text.chars().count() > maximum
        || text
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err(Error::invalid(format!(
            "{key} is empty, too long or contains unsupported control characters"
        )));
    }
    Ok(text)
}

fn metadata_list(args: &Value, key: &str) -> Result<Vec<String>> {
    let rows = args[key]
        .as_array()
        .filter(|rows| rows.len() <= 500)
        .ok_or_else(|| {
            Error::invalid(format!("{key} must be a list of at most 500 text values"))
        })?;
    let mut result = Vec::new();
    for row in rows {
        let text = row
            .as_str()
            .and_then(util::clean)
            .filter(|s| s.chars().count() <= 1000 && !s.chars().any(char::is_control))
            .ok_or_else(|| {
                Error::invalid(format!(
                    "Every {key} value must be nonempty text of at most 1000 characters"
                ))
            })?;
        if key == "related" && !util::valid_session_id(&text) {
            return Err(Error::invalid("A related session ID is invalid"));
        }
        if !result.contains(&text) {
            result.push(text);
        }
    }
    Ok(result)
}

fn update_metadata(connection: &Connection, args: &Value, now: Ms) -> Result<()> {
    let id = arg_str_any(args, &["sessionId", "session"])
        .ok_or_else(|| Error::invalid("Missing sessionId"))?;
    let row = session::require(connection, &id)?;
    let title = if args.get("title").is_some() {
        metadata_text(args, "title", 500, false)?
    } else {
        row.title.clone()
    };
    let kind = if args.get("kind").is_some() {
        vocab::kind(&metadata_text(args, "kind", 100, false)?)
    } else {
        row.kind.clone()
    };
    let touches = if args.get("touches").is_some() {
        metadata_list(args, "touches")?
    } else {
        row.touches.clone()
    };
    let related = if args.get("related").is_some() {
        metadata_list(args, "related")?
    } else {
        row.related.clone()
    };
    let changed = ["title", "kind", "touches", "related", "chatUrl"]
        .into_iter()
        .filter(|key| args.get(*key).is_some())
        .collect::<Vec<_>>();
    if changed.is_empty() {
        return Err(Error::invalid("Choose session details to update"));
    }
    let settings = Settings::load(connection)?;
    if row.status == "shelved" && !settings.role(&kind).may_shelve() {
        return Err(Error::invalid(
            "Resume the shelved session before assigning this kind",
        ));
    }
    let recorder = Recorder {
        connection,
        session_id: row.id.clone(),
        project: row.project.clone(),
        now,
    };
    if args.get("chatUrl").is_some() {
        link(
            connection,
            &recorder,
            &row,
            &json!({"chatUrl":args["chatUrl"]}),
        )?;
    }
    connection.execute(
        "UPDATE sessions SET title=?2,kind=?3,touches=?4,related=?5 WHERE id=?1",
        params![
            id,
            title,
            kind,
            serde_json::to_string(&touches)?,
            serde_json::to_string(&related)?
        ],
    )?;
    recorder.record("update", "Session details updated by a person", json!({"changed":changed,"before":{"title":row.title,"kind":row.kind,"touches":row.touches,"related":row.related}}), false)?;
    Ok(())
}

/// Edits record metadata or deletes a session; only the app dispatcher exposes this entry point.
pub fn manage(db: &Db, args: &Value, now: Ms) -> Result<Value> {
    let action = arg_str(args, "action").ok_or_else(|| Error::invalid("Missing record action"))?;
    let ((), rev) = db.write(|c| {
        match action.as_str() {
            "update" => update_metadata(c, args, now),
            "version_note" => {
                let project = arg_str(args, "project").ok_or_else(|| Error::invalid("Missing project"))?;
                let version = arg_str(args, "version").and_then(|v| util::parse_version(&v)).filter(|v| v != "latest")
                    .ok_or_else(|| Error::invalid("Choose a baseline version"))?;
                let note = metadata_text(args, "note", 60_000, true)?;
                let changed = c.execute("UPDATE baselines SET note=?3 WHERE project=?1 AND version=?2", params![project,version,note])?;
                if changed == 0 { return Err(Error::not_found("That baseline does not exist")); }
                Ok(())
            }
            "delete" => {
                if args["confirmed"] != true { return Err(Error::invalid("Confirm session deletion in the app first")); }
                let id = arg_str_any(args, &["sessionId", "session"]).ok_or_else(|| Error::invalid("Missing sessionId"))?;
                session::require(c, &id)?;
                // Keep baselines and work evidence; neither can safely hand off to a deleted conversation.
                c.execute("UPDATE baselines SET by_session=NULL WHERE by_session=?1",[&id])?;
                c.execute("DELETE FROM ledger_legacy_event_ids WHERE event_id IN (SELECT id FROM events WHERE session_id=?1)",[&id])?;
                c.execute("DELETE FROM pending_prompts WHERE session_id=?1",[&id])?;
                c.execute("DELETE FROM questions WHERE session_id=?1",[&id])?;
                c.execute("DELETE FROM events WHERE session_id=?1",[&id])?;
                c.execute("DELETE FROM sessions WHERE id=?1",[&id])?;
                Ok(())
            }
            _ => Err(Error::invalid("Unknown record action")),
        }
    })?;
    Ok(json!({"ok":true,"rev":rev}))
}
