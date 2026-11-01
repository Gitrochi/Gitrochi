//! Events (a session's history), questions, and delivering a person's answers and notes
//! to the agent exactly once.

use crate::error::Result;
use crate::util::{json_text, Ms};
use rusqlite::{params, Connection, Row};
use serde::Serialize;
use serde_json::{json, Value};

/// An event to insert.
pub struct NewEvent<'a> {
    pub session_id: &'a str,
    pub project: &'a str,
    pub ts: Ms,
    pub kind: &'a str,
    pub actor: &'a str,
    pub summary: &'a str,
    pub body: Option<&'a str>,
    pub version: Option<&'a str>,
    pub artifacts: &'a Value,
    pub data: &'a Value,
    pub channel: &'a str,
    /// `None` = waiting for delivery to the agent (a person's message or status change).
    pub delivered_at: Option<Ms>,
}

pub fn insert(connection: &Connection, event: &NewEvent) -> Result<i64> {
    connection.execute(
        "INSERT INTO events (session_id, project, ts, type, actor, summary, body, version,
                             artifacts, data, channel, delivered_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            event.session_id,
            event.project,
            event.ts,
            event.kind,
            event.actor,
            event.summary,
            event.body,
            event.version,
            json_text(event.artifacts),
            json_text(event.data),
            event.channel,
            event.delivered_at,
        ],
    )?;
    Ok(connection.last_insert_rowid())
}

/// An event as the API returns it (`LedgerEvent` in CONTRACT.md).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventView {
    pub id: i64,
    pub session_id: String,
    pub ts: Ms,
    #[serde(rename = "type")]
    pub kind: String,
    pub actor: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<Value>,
    #[serde(skip_serializing_if = "is_empty_object")]
    pub data: Value,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub channel: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivered_at: Option<Ms>,
}

fn is_empty_object(value: &Value) -> bool {
    value.as_object().is_none_or(|m| m.is_empty())
}

pub const COLUMNS: &str =
    "id, session_id, ts, type, actor, summary, body, version, artifacts, data, channel, delivered_at";

impl EventView {
    pub fn from_row(row: &Row) -> rusqlite::Result<EventView> {
        let artifacts: String = row.get(8)?;
        let data: String = row.get(9)?;
        Ok(EventView {
            id: row.get(0)?,
            session_id: row.get(1)?,
            ts: row.get(2)?,
            kind: row.get(3)?,
            actor: row.get(4)?,
            summary: row.get(5)?,
            body: row.get(6)?,
            version: row.get(7)?,
            artifacts: serde_json::from_str(&artifacts).unwrap_or_default(),
            data: serde_json::from_str(&data).unwrap_or_else(|_| json!({})),
            channel: row.get(10)?,
            delivered_at: row.get(11)?,
        })
    }

    pub fn artifact_names(&self) -> Vec<String> {
        self.artifacts
            .iter()
            .filter_map(|a| a["name"].as_str().map(str::to_string))
            .collect()
    }
}

/// A session's events in time order.
pub fn for_session(connection: &Connection, session_id: &str) -> Result<Vec<EventView>> {
    let mut statement = connection.prepare_cached(&format!(
        "SELECT {COLUMNS} FROM events WHERE session_id = ?1 ORDER BY ts, id"
    ))?;
    let rows = statement.query_map([session_id], EventView::from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// A question (`Question` in CONTRACT.md).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionView {
    pub id: i64,
    pub session_id: String,
    pub text: String,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
    /// `human` or `auto`; absent when the session settled the question itself.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answered_by: Option<String>,
    /// `agent` when the session settled the question itself (`resolves`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved_by: Option<String>,
    pub created_at: Ms,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answered_at: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivered_at: Option<Ms>,
}

pub const QUESTION_COLUMNS: &str =
    "id, session_id, text, state, answer, answered_by, created_at, answered_at, delivered_at";

impl QuestionView {
    pub fn from_row(row: &Row) -> rusqlite::Result<QuestionView> {
        let by: Option<String> = row.get(5)?;
        let (answered_by, resolved_by) = match by.as_deref() {
            Some("agent") => (None, Some("agent".to_string())),
            _ => (by, None),
        };
        Ok(QuestionView {
            id: row.get(0)?,
            session_id: row.get(1)?,
            text: row.get(2)?,
            state: row.get(3)?,
            answer: row.get(4)?,
            answered_by,
            resolved_by,
            created_at: row.get(6)?,
            answered_at: row.get(7)?,
            delivered_at: row.get(8)?,
        })
    }
}

pub fn questions_for(connection: &Connection, session_id: &str) -> Result<Vec<QuestionView>> {
    let mut statement = connection.prepare_cached(&format!(
        "SELECT {QUESTION_COLUMNS} FROM questions WHERE session_id = ?1 ORDER BY id"
    ))?;
    let rows = statement.query_map([session_id], QuestionView::from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn add_question(connection: &Connection, session_id: &str, text: &str, ts: Ms) -> Result<i64> {
    connection.execute(
        "INSERT INTO questions (session_id, text, created_at) VALUES (?1, ?2, ?3)",
        params![session_id, text, ts],
    )?;
    Ok(connection.last_insert_rowid())
}

/// Something a person left for the agent, handed over with its next report or read.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub from: &'static str,
    pub text: String,
    pub at: Ms,
    /// `answer`, `dismissed`, `message` or `status`.
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub question_id: Option<i64>,
}

/// Hands the session's waiting messages to its agent and marks them delivered in the same
/// transaction, so each one arrives exactly once. Oldest first.
pub fn deliver(connection: &Connection, session_id: &str, now: Ms) -> Result<Vec<Message>> {
    let mut messages: Vec<(Ms, i64, Message)> = Vec::new();
    {
        let mut statement = connection.prepare_cached(
            "SELECT id, text, state, answer, COALESCE(answered_at, created_at) FROM questions
             WHERE session_id = ?1 AND delivered_at IS NULL AND answered_by = 'human'
               AND state IN ('answered', 'dismissed')
             ORDER BY id",
        )?;
        let rows = statement.query_map([session_id], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Ms>(4)?,
            ))
        })?;
        for row in rows {
            let (id, text, state, answer, at) = row?;
            let message = if state == "answered" {
                Message {
                    from: "human",
                    text: format!(
                        "[Answer to question #{id}] Q: {text} → A: {}",
                        answer.unwrap_or_default()
                    ),
                    at,
                    kind: "answer",
                    question_id: Some(id),
                }
            } else {
                Message {
                    from: "human",
                    text: format!("[Question #{id} dismissed] {text}"),
                    at,
                    kind: "dismissed",
                    question_id: Some(id),
                }
            };
            messages.push((at, 0, message));
        }
    }
    connection.execute(
        "UPDATE questions SET delivered_at = ?2 WHERE session_id = ?1 AND delivered_at IS NULL
           AND answered_by = 'human' AND state IN ('answered', 'dismissed')",
        params![session_id, now],
    )?;
    {
        let mut statement = connection.prepare_cached(
            "SELECT id, type, summary, ts FROM events
             WHERE session_id = ?1 AND actor = 'human' AND delivered_at IS NULL
               AND type IN ('message', 'set_status', 'shelve')
             ORDER BY id",
        )?;
        let rows = statement.query_map([session_id], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Ms>(3)?,
            ))
        })?;
        for row in rows {
            let (id, kind, summary, at) = row?;
            let message = if kind == "message" {
                Message {
                    from: "human",
                    text: format!("[Note from a person] {summary}"),
                    at,
                    kind: "message",
                    question_id: None,
                }
            } else {
                Message {
                    from: "human",
                    text: format!("[Status set by a person] {summary}"),
                    at,
                    kind: "status",
                    question_id: None,
                }
            };
            messages.push((at, id, message));
        }
    }
    connection.execute(
        "UPDATE events SET delivered_at = ?2 WHERE session_id = ?1 AND actor = 'human'
           AND delivered_at IS NULL AND type IN ('message', 'set_status', 'shelve')",
        params![session_id, now],
    )?;
    messages.sort_by_key(|(at, id, _)| (*at, *id));
    Ok(messages.into_iter().map(|(_, _, m)| m).collect())
}

/// How many messages wait for the session (never delivers).
pub fn waiting(connection: &Connection, session_id: &str) -> Result<i64> {
    Ok(connection.query_row(
        "SELECT (SELECT COUNT(*) FROM questions WHERE session_id = ?1 AND delivered_at IS NULL
                   AND answered_by = 'human' AND state IN ('answered', 'dismissed'))
              + (SELECT COUNT(*) FROM events WHERE session_id = ?1 AND actor = 'human'
                   AND delivered_at IS NULL AND type IN ('message', 'set_status', 'shelve'))",
        [session_id],
        |r| r.get(0),
    )?)
}
