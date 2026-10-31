//! Prompts an agent is waiting on (a question at the end of a turn, `AskUserQuestion`, a
//! plan to approve, a permission request), for auto-continue. The hook handler creates and
//! polls them and records what happened; the apps answer them. What to answer is decided
//! by `gitrochi-autocontinue`; the payload and the answer are stored as given.

use crate::error::{Error, Result};
use crate::event::{self, NewEvent};
use crate::session;
use crate::util::{self, arg_str, Ms};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;
use serde_json::{json, Value};

pub const KINDS: [&str; 4] = [
    "stop_question",
    "ask_user_question",
    "exit_plan_mode",
    "permission",
];
pub const STATES: [&str; 5] = ["waiting", "answered", "auto", "released", "expired"];
const DEFAULT_DELAY_SEC: i64 = 30;
/// A prompt nobody resolved is expired this long after its deadline.
pub const EXPIRE_GRACE: Ms = 10 * 60_000;

/// A waiting prompt (`PendingPrompt` in CONTRACT.md).
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PendingPrompt {
    pub id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub kind: String,
    pub payload: Value,
    pub created_at: Ms,
    pub deadline: Ms,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answer: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answered_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answered_at: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reviewed_at: Option<Ms>,
}

const COLUMNS: &str =
    "id, session_id, agent_id, kind, payload, created_at, deadline, state, answer,
    answered_by, answered_at, reviewed_at";

fn from_row(row: &Row) -> rusqlite::Result<PendingPrompt> {
    let payload: String = row.get(4)?;
    let answer: Option<String> = row.get(8)?;
    Ok(PendingPrompt {
        id: row.get(0)?,
        session_id: row.get(1)?,
        agent_id: row.get(2)?,
        kind: row.get(3)?,
        payload: serde_json::from_str(&payload).unwrap_or_else(|_| json!({})),
        created_at: row.get(5)?,
        deadline: row.get(6)?,
        state: row.get(7)?,
        answer: answer.and_then(|a| serde_json::from_str(&a).ok()),
        answered_by: row.get(9)?,
        answered_at: row.get(10)?,
        reviewed_at: row.get(11)?,
    })
}

pub fn get(connection: &Connection, id: i64) -> Result<PendingPrompt> {
    connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM pending_prompts WHERE id = ?1"),
            [id],
            from_row,
        )
        .optional()?
        .ok_or_else(|| Error::not_found(format!("No pending prompt #{id}")))
}

/// Prompts in the given states (of one project's sessions, or all), oldest first.
/// `unreviewed` keeps only automatic answers nobody has looked at.
pub fn list(
    connection: &Connection,
    project: Option<&str>,
    states: &[&str],
    unreviewed: bool,
) -> Result<Vec<PendingPrompt>> {
    let placeholders = states
        .iter()
        .map(|s| format!("'{}'", s.replace('\'', "")))
        .collect::<Vec<_>>()
        .join(", ");
    let columns = COLUMNS
        .split(',')
        .map(|c| format!("p.{}", c.trim()))
        .collect::<Vec<_>>()
        .join(", ");
    let mut statement = connection.prepare(&format!(
        "SELECT {columns} FROM pending_prompts p LEFT JOIN sessions s ON s.id = p.session_id
         WHERE p.state IN ({placeholders}) AND (?1 IS NULL OR s.project = ?1)
           AND (?2 = 0 OR p.reviewed_at IS NULL)
         ORDER BY p.id"
    ))?;
    let rows = statement.query_map(params![project, unreviewed as i64], from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// A new waiting prompt. `deadline` defaults to now + `delaySec` (30 s).
pub fn create(connection: &Connection, args: &Value, now: Ms) -> Result<PendingPrompt> {
    let kind = arg_str(args, "kind").ok_or_else(|| Error::invalid("Missing kind"))?;
    if !KINDS.contains(&kind.as_str()) {
        return Err(Error::invalid(format!(
            "kind must be one of {}",
            KINDS.join(", ")
        )));
    }
    let session_id = util::arg_str_any(args, &["sessionId", "session"]);
    if let Some(id) = &session_id {
        session::require(connection, id)?;
    }
    let payload = match &args["payload"] {
        Value::Null => json!({}),
        value @ Value::Object(_) => value.clone(),
        _ => return Err(Error::invalid("payload must be an object")),
    };
    let deadline = match util::arg_i64(args, "deadline")? {
        Some(deadline) => deadline,
        None => {
            now + util::arg_i64(args, "delaySec")?
                .unwrap_or(DEFAULT_DELAY_SEC)
                .max(0)
                * 1000
        }
    };
    connection.execute(
        "INSERT INTO pending_prompts (session_id, agent_id, kind, payload, created_at, deadline)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            session_id,
            arg_str(args, "agentId"),
            kind,
            payload.to_string(),
            now,
            deadline
        ],
    )?;
    get(connection, connection.last_insert_rowid())
}

fn answer_value(args: &Value) -> Result<Value> {
    match &args["answer"] {
        value @ Value::Object(_) => Ok(value.clone()),
        Value::Null => Err(Error::invalid("Missing answer")),
        _ => Err(Error::invalid("answer must be an object")),
    }
}

/// A person answered in the app (`prompt_answer`). Returns false when the prompt was no
/// longer waiting, for example because auto-continue answered first.
pub fn answer(connection: &Connection, args: &Value, now: Ms) -> Result<(bool, PendingPrompt)> {
    let id = util::arg_i64(args, "id")?.ok_or_else(|| Error::invalid("Missing id"))?;
    let answer = answer_value(args)?;
    let changed = connection.execute(
        "UPDATE pending_prompts SET state = 'answered', answer = ?2, answered_by = 'human',
            answered_at = ?3, reviewed_at = ?3
         WHERE id = ?1 AND state = 'waiting'",
        params![id, answer.to_string(), now],
    )?;
    Ok((changed == 1, get(connection, id)?))
}

/// The hook handler closes a waiting prompt: `auto` (auto-continue answered it), `released`
/// (the agent went on without it) or `expired`. An automatic answer is also recorded on the
/// session as an `auto_reply` event, for a person to review.
pub fn resolve(connection: &Connection, args: &Value, now: Ms) -> Result<(bool, PendingPrompt)> {
    let id = util::arg_i64(args, "id")?.ok_or_else(|| Error::invalid("Missing id"))?;
    let state = arg_str(args, "state").ok_or_else(|| Error::invalid("Missing state"))?;
    if !matches!(state.as_str(), "auto" | "released" | "expired") {
        return Err(Error::invalid("state must be auto, released or expired"));
    }
    let answer = if state == "auto" {
        Some(answer_value(args)?)
    } else {
        None
    };
    let changed = connection.execute(
        "UPDATE pending_prompts SET state = ?2, answer = ?3,
            answered_by = CASE WHEN ?2 = 'auto' THEN 'auto' ELSE answered_by END,
            answered_at = CASE WHEN ?2 = 'auto' THEN ?4 ELSE answered_at END
         WHERE id = ?1 AND state = 'waiting'",
        params![id, state, answer.as_ref().map(Value::to_string), now],
    )?;
    let prompt = get(connection, id)?;
    if changed == 1 && state == "auto" {
        if let Some(session_id) = &prompt.session_id {
            if let Some(row) = session::load(connection, session_id)? {
                let summary = arg_str(args, "summary").unwrap_or_else(|| {
                    format!(
                        "Auto-continue answered a {} prompt",
                        prompt.kind.replace('_', " ")
                    )
                });
                event::insert(
                    connection,
                    &NewEvent {
                        session_id,
                        project: &row.project,
                        ts: now,
                        kind: "auto_reply",
                        actor: "auto",
                        summary: &summary,
                        body: None,
                        version: None,
                        artifacts: &json!([]),
                        data: &json!({"promptId": id, "kind": prompt.kind, "answer": answer}),
                        channel: "hook",
                        delivered_at: Some(now),
                    },
                )?;
            }
        }
    }
    Ok((changed == 1, prompt))
}

/// The hook handler settles the session's waiting stop questions once the agent moved on:
/// `answered` (by the person) when they typed in the terminal — what they typed is not
/// stored — else `released`, so a late automatic answer never lands in other work.
pub fn settle_stop_questions(
    connection: &Connection,
    session_id: &str,
    by_person: bool,
    now: Ms,
) -> Result<usize> {
    let changed = if by_person {
        connection.execute(
            "UPDATE pending_prompts SET state = 'answered', answered_by = 'human',
                answered_at = ?2, reviewed_at = ?2
             WHERE session_id = ?1 AND state = 'waiting' AND kind = 'stop_question'",
            params![session_id, now],
        )?
    } else {
        connection.execute(
            "UPDATE pending_prompts SET state = 'released'
             WHERE session_id = ?1 AND state = 'waiting' AND kind = 'stop_question'",
            [session_id],
        )?
    };
    Ok(changed)
}

/// Whether the session has a stop question waiting (a read before deciding to write).
pub fn stop_question_waiting(connection: &Connection, session_id: &str) -> Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS (SELECT 1 FROM pending_prompts
                        WHERE session_id = ?1 AND state = 'waiting' AND kind = 'stop_question')",
        [session_id],
        |r| r.get(0),
    )?)
}

/// Releases every prompt the session still waits on: its conversation ended or started over,
/// so nothing earlier can be answered any more.
pub fn release_session(connection: &Connection, session_id: &str) -> Result<usize> {
    Ok(connection.execute(
        "UPDATE pending_prompts SET state = 'released' WHERE session_id = ?1 AND state = 'waiting'",
        [session_id],
    )?)
}

/// Automatic answers in a row (design §9.4): the session's `auto_reply` events since the
/// person last typed in the terminal (a `hook` event with `person`), acted on the session
/// in the app, or answered one of its prompts.
pub fn in_a_row(connection: &Connection, session_id: &str) -> Result<u32> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM events e
         WHERE e.session_id = ?1 AND e.type = 'auto_reply'
           AND e.id > COALESCE((SELECT MAX(id) FROM events
                                WHERE session_id = ?1
                                  AND ((actor = 'human' AND type <> 'link')
                                       OR (type = 'hook' AND json_extract(data, '$.person') = 1))), 0)
           AND e.ts > COALESCE((SELECT MAX(answered_at) FROM pending_prompts
                                WHERE session_id = ?1 AND answered_by = 'human'), 0)",
        [session_id],
        |r| r.get(0),
    )?;
    Ok(count.clamp(0, i64::from(u32::MAX)) as u32)
}

/// The session's prompts still waiting: each may become an automatic answer, so the limit
/// counts them too and two parallel requests never add up past it.
pub fn waiting(connection: &Connection, session_id: &str) -> Result<u32> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM pending_prompts WHERE session_id = ?1 AND state = 'waiting'",
        [session_id],
        |r| r.get(0),
    )?;
    Ok(count.clamp(0, i64::from(u32::MAX)) as u32)
}

/// Expires prompts nobody resolved long after their deadline; returns how many.
pub fn expire(connection: &Connection, now: Ms) -> Result<usize> {
    Ok(connection.execute(
        "UPDATE pending_prompts SET state = 'expired' WHERE state = 'waiting' AND deadline < ?1",
        [now - EXPIRE_GRACE],
    )?)
}

/// A person looked at automatic answers (one, or all of them).
pub fn review(connection: &Connection, args: &Value, now: Ms) -> Result<usize> {
    match util::arg_i64(args, "id")? {
        Some(id) => Ok(connection.execute(
            "UPDATE pending_prompts SET reviewed_at = ?2 WHERE id = ?1 AND reviewed_at IS NULL",
            params![id, now],
        )?),
        None if util::arg_bool(args, "all") == Some(true) => Ok(connection.execute(
            "UPDATE pending_prompts SET reviewed_at = ?1 WHERE state = 'auto' AND reviewed_at IS NULL",
            [now],
        )?),
        None => Err(Error::invalid("Give id, or all: true")),
    }
}
