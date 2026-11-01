//! Sessions as stored, and the view every caller sees: the computed verdict, the role,
//! whether it is a stream, and how far its base is behind HEAD.

use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::util::{compare_versions, string_list, Ms};
use crate::vocab::{self, Verdict};
use rusqlite::{Connection, OptionalExtension, Row};
use serde::Serialize;
use serde_json::{json, Value};
use std::cmp::Ordering;
use std::collections::HashMap;

pub const COLUMNS: &str = "id, project, kind, title, base_version, base_current, base_was_latest,
    status, merged_into, touches, related, chat_url, links, channel, color, created_at, last_at,
    last_agent_at, ack_at, snooze_until, archived_at, auto_continue";

#[derive(Clone, Debug)]
pub struct SessionRow {
    pub id: String,
    pub project: String,
    pub kind: String,
    pub title: String,
    pub base_version: Option<String>,
    pub base_current: Option<String>,
    pub base_was_latest: bool,
    pub status: String,
    pub merged_into: Option<String>,
    pub touches: Vec<String>,
    pub related: Vec<String>,
    pub chat_url: Option<String>,
    pub links: Value,
    pub channel: String,
    pub color: i64,
    pub created_at: Ms,
    pub last_at: Ms,
    pub last_agent_at: Option<Ms>,
    pub ack_at: Option<Ms>,
    pub snooze_until: Option<Ms>,
    pub archived_at: Option<Ms>,
    pub auto_continue: Option<Value>,
}

impl SessionRow {
    pub fn from_row(row: &Row) -> rusqlite::Result<SessionRow> {
        let touches: String = row.get(9)?;
        let related: String = row.get(10)?;
        let links: String = row.get(12)?;
        let auto: Option<String> = row.get(21)?;
        Ok(SessionRow {
            id: row.get(0)?,
            project: row.get(1)?,
            kind: row.get(2)?,
            title: row.get(3)?,
            base_version: row.get(4)?,
            base_current: row.get(5)?,
            base_was_latest: row.get::<_, i64>(6)? != 0,
            status: row.get(7)?,
            merged_into: row.get(8)?,
            touches: string_list(&touches),
            related: string_list(&related),
            chat_url: row.get(11)?,
            links: serde_json::from_str(&links).unwrap_or_else(|_| json!({})),
            channel: row.get(13)?,
            color: row.get(14)?,
            created_at: row.get(15)?,
            last_at: row.get(16)?,
            last_agent_at: row.get(17)?,
            ack_at: row.get(18)?,
            snooze_until: row.get(19)?,
            archived_at: row.get(20)?,
            auto_continue: auto.and_then(|t| serde_json::from_str(&t).ok()),
        })
    }

    pub fn is_live(&self) -> bool {
        vocab::is_live_status(&self.status) && self.archived_at.is_none()
    }
}

pub fn load(connection: &Connection, id: &str) -> Result<Option<SessionRow>> {
    Ok(connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM sessions WHERE id = ?1"),
            [id],
            SessionRow::from_row,
        )
        .optional()?)
}

pub fn require(connection: &Connection, id: &str) -> Result<SessionRow> {
    load(connection, id)?.ok_or_else(|| Error::not_found(format!("No session {id}")))
}

/// Sessions of one project (or all), oldest first.
pub fn list(connection: &Connection, project: Option<&str>) -> Result<Vec<SessionRow>> {
    let sql = match project {
        Some(_) => {
            format!("SELECT {COLUMNS} FROM sessions WHERE project = ?1 ORDER BY created_at, id")
        }
        None => format!("SELECT {COLUMNS} FROM sessions ORDER BY project, created_at, id"),
    };
    let mut statement = connection.prepare(&sql)?;
    let rows = match project {
        Some(p) => statement.query_map([p], SessionRow::from_row)?,
        None => statement.query_map([], SessionRow::from_row)?,
    };
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// Open questions per session.
pub fn open_counts(connection: &Connection, project: Option<&str>) -> Result<HashMap<String, i64>> {
    let mut statement = connection.prepare(
        "SELECT q.session_id, COUNT(*) FROM questions q JOIN sessions s ON s.id = q.session_id
         WHERE q.state = 'open' AND (?1 IS NULL OR s.project = ?1) GROUP BY q.session_id",
    )?;
    let rows = statement.query_map([project], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<HashMap<_, _>>>()?)
}

pub fn open_count(connection: &Connection, id: &str) -> Result<i64> {
    Ok(connection.query_row(
        "SELECT COUNT(*) FROM questions WHERE session_id = ?1 AND state = 'open'",
        [id],
        |r| r.get(0),
    )?)
}

/// The verdict, first match wins: archived, open questions, finished (confirmed or not),
/// shelved, done, quiet for longer than the stale limit, otherwise active.
pub fn verdict(row: &SessionRow, open_questions: i64, now: Ms, stale_ms: Ms) -> Verdict {
    if row.archived_at.is_some() {
        return Verdict::Archived;
    }
    if open_questions > 0 {
        return Verdict::NeedsHuman;
    }
    if vocab::is_terminal(&row.status) {
        return if row.ack_at.is_some() {
            Verdict::Expirable
        } else {
            Verdict::Confirm
        };
    }
    match row.status.as_str() {
        // Shelved work is kept on purpose; quiet is not a sign of abandonment.
        "shelved" => return Verdict::Shelved,
        "done" => return Verdict::PendingMerge,
        _ => {}
    }
    let snoozed = row.snooze_until.is_some_and(|until| until > now);
    if !snoozed && now - row.last_at > stale_ms {
        return Verdict::Stale;
    }
    Verdict::Active
}

#[derive(Clone, Debug, Serialize)]
pub struct StreamTag {
    pub line: String,
}

/// A session as the API returns it (`Session` in CONTRACT.md).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    pub id: String,
    pub project: String,
    pub title: String,
    pub kind: String,
    pub role: &'static str,
    pub status: String,
    pub verdict: Verdict,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_current: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub base_was_latest: bool,
    /// Baselines newer than `baseCurrent` (absent without a base).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub behind: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub merged_into: Option<String>,
    pub touches: Vec<String>,
    pub related: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat_url: Option<String>,
    pub links: Value,
    pub color: i64,
    pub created_at: Ms,
    pub last_at: Ms,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_agent_at: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ack_at: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snooze_until: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<Ms>,
    pub open_questions: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream: Option<StreamTag>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auto_continue: Option<Value>,
}

impl SessionView {
    pub fn is_stream(&self) -> bool {
        self.stream.is_some()
    }

    pub fn is_live(&self) -> bool {
        vocab::is_live_status(&self.status) && self.archived_at.is_none()
    }
}

/// Builds views with the trunk's versions (for `behind`) and the settings (roles, lines).
pub struct Viewer<'a> {
    pub settings: &'a Settings,
    pub versions: Vec<String>,
    pub now: Ms,
}

impl Viewer<'_> {
    pub fn behind(&self, base: Option<&str>) -> Option<i64> {
        let base = base?;
        Some(
            self.versions
                .iter()
                .filter(|v| compare_versions(v, base) == Ordering::Greater)
                .count() as i64,
        )
    }

    pub fn view(&self, row: &SessionRow, open_questions: i64) -> SessionView {
        let role = self.settings.role(&row.kind);
        // A stream is a live implementation session: it reports in cycles instead of ending.
        let stream = if vocab::is_terminal(&row.status) {
            None
        } else {
            self.settings.line(&row.kind).map(|line| StreamTag { line })
        };
        let links = match &row.links {
            Value::Object(map) if !map.is_empty() => row.links.clone(),
            _ => json!({}),
        };
        SessionView {
            id: row.id.clone(),
            project: row.project.clone(),
            title: row.title.clone(),
            kind: row.kind.clone(),
            role: role.as_str(),
            status: row.status.clone(),
            verdict: verdict(row, open_questions, self.now, self.settings.stale_ms()),
            base_version: row.base_version.clone(),
            base_current: row.base_current.clone(),
            base_was_latest: row.base_was_latest,
            behind: self.behind(row.base_current.as_deref()),
            merged_into: row.merged_into.clone(),
            touches: row.touches.clone(),
            related: row.related.clone(),
            chat_url: row.chat_url.clone(),
            links,
            color: row.color,
            created_at: row.created_at,
            last_at: row.last_at,
            last_agent_at: row.last_agent_at,
            ack_at: row.ack_at,
            snooze_until: row.snooze_until,
            archived_at: row.archived_at,
            open_questions,
            stream,
            auto_continue: row.auto_continue.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(status: &str) -> SessionRow {
        SessionRow {
            id: "S0101-01".into(),
            project: "p".into(),
            kind: "research".into(),
            title: "t".into(),
            base_version: None,
            base_current: None,
            base_was_latest: false,
            status: status.into(),
            merged_into: None,
            touches: vec![],
            related: vec![],
            chat_url: None,
            links: json!({}),
            channel: String::new(),
            color: 0,
            created_at: 0,
            last_at: 1_000,
            last_agent_at: Some(1_000),
            ack_at: None,
            snooze_until: None,
            archived_at: None,
            auto_continue: None,
        }
    }

    const STALE: Ms = 72 * 3_600_000;

    #[test]
    fn verdict_priority_is_fixed() {
        let now = 2_000;
        // archived beats everything, even open questions
        let mut r = row("merged");
        r.archived_at = Some(1);
        assert_eq!(verdict(&r, 3, now, STALE), Verdict::Archived);
        // open questions beat finished states
        let r = row("merged");
        assert_eq!(verdict(&r, 1, now, STALE), Verdict::NeedsHuman);
        let r = row("shelved");
        assert_eq!(verdict(&r, 1, now, STALE), Verdict::NeedsHuman);
        // finished: confirmed or not
        for status in ["merged", "closed", "dropped"] {
            let mut r = row(status);
            assert_eq!(verdict(&r, 0, now, STALE), Verdict::Confirm, "{status}");
            r.ack_at = Some(5);
            assert_eq!(verdict(&r, 0, now, STALE), Verdict::Expirable, "{status}");
        }
        // shelved is never stale, done waits for a merge decision
        let r = row("shelved");
        assert_eq!(verdict(&r, 0, now + 10 * STALE, STALE), Verdict::Shelved);
        let r = row("done");
        assert_eq!(
            verdict(&r, 0, now + 10 * STALE, STALE),
            Verdict::PendingMerge
        );
        // active until quiet for longer than the limit
        let r = row("active");
        assert_eq!(verdict(&r, 0, 1_000 + STALE, STALE), Verdict::Active);
        assert_eq!(verdict(&r, 0, 1_001 + STALE, STALE), Verdict::Stale);
        // a snooze holds the stale verdict off until it runs out
        let mut r = row("active");
        r.snooze_until = Some(5 * STALE);
        assert_eq!(verdict(&r, 0, 4 * STALE, STALE), Verdict::Active);
        assert_eq!(verdict(&r, 0, 5 * STALE + 1, STALE), Verdict::Stale);
    }
}
