//! Search across sessions (ID, title, kind, touches), questions, events (summary and body)
//! and baselines. Every word must appear; case is ignored for ASCII letters.

use crate::error::{Error, Result};
use crate::util::{clean, truncate};
use rusqlite::{params_from_iter, Connection};
use serde::Serialize;

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    /// `session`, `question`, `event` or `baseline`.
    pub kind: &'static str,
    /// The session ID, the question or event number, or the version — always as text.
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub title: String,
    pub snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ts: Option<i64>,
}

fn escape_like(word: &str) -> String {
    word.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// `(… LIKE ?n ESCAPE '\' AND …)` over one text expression, a parameter per word.
fn all_words(expression: &str, words: usize, first: usize) -> String {
    (0..words)
        .map(|i| format!("{expression} LIKE ?{} ESCAPE '\\'", first + i))
        .collect::<Vec<_>>()
        .join(" AND ")
}

/// A window of text around the first word that matches.
fn snippet(text: &str, words: &[String]) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let lower = flat.to_lowercase();
    let at = words
        .iter()
        .filter_map(|w| lower.find(&w.to_lowercase()))
        .min()
        .unwrap_or(0);
    // Counted on the lowercase text: lowercasing can change byte lengths, never boundaries there.
    let start_char = lower[..at].chars().count().saturating_sub(60);
    let tail: String = flat.chars().skip(start_char).collect();
    let mut out = truncate(&tail, 160);
    if start_char > 0 {
        out.insert(0, '…');
    }
    out
}

pub fn search(
    connection: &Connection,
    query: &str,
    project: Option<&str>,
    limit: usize,
) -> Result<Vec<Hit>> {
    let query = clean(query).ok_or_else(|| Error::invalid("Missing query"))?;
    let words: Vec<String> = query.split_whitespace().map(str::to_string).collect();
    let patterns: Vec<String> = words
        .iter()
        .map(|w| format!("%{}%", escape_like(w)))
        .collect();
    let limit = limit.clamp(1, 500);
    let n = words.len();
    // Parameters: ?1 = project (or NULL), ?2.. = the word patterns.
    let mut values: Vec<Option<String>> = vec![project.map(str::to_string)];
    values.extend(patterns.iter().cloned().map(Some));
    let mut hits = Vec::new();

    let session_text = "(s.id || ' ' || s.title || ' ' || s.kind || ' ' || s.touches)";
    let mut statement = connection.prepare(&format!(
        "SELECT s.id, s.title, s.kind, s.touches, s.last_at FROM sessions s
         WHERE (?1 IS NULL OR s.project = ?1) AND {}
         ORDER BY (lower(s.id) = lower(?2)) DESC, s.last_at DESC LIMIT {limit}",
        all_words(session_text, n, 2)
    ))?;
    let rows = statement.query_map(params_from_iter(values.iter()), |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, i64>(4)?,
        ))
    })?;
    for row in rows {
        let (id, title, kind, touches, last_at) = row?;
        let touches = crate::util::string_list(&touches).join(", ");
        hits.push(Hit {
            kind: "session",
            session_id: Some(id.clone()),
            snippet: snippet(&format!("{kind} · {touches}"), &words),
            id,
            title,
            ts: Some(last_at),
        });
    }

    let question_text = "(q.text || ' ' || COALESCE(q.answer, ''))";
    let mut statement = connection.prepare(&format!(
        "SELECT q.id, q.session_id, s.title, q.text, q.answer, q.created_at FROM questions q
         JOIN sessions s ON s.id = q.session_id
         WHERE (?1 IS NULL OR s.project = ?1) AND {}
         ORDER BY q.id DESC LIMIT {limit}",
        all_words(question_text, n, 2)
    ))?;
    let rows = statement.query_map(params_from_iter(values.iter()), |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, i64>(5)?,
        ))
    })?;
    for row in rows {
        let (id, session_id, title, text, answer, at) = row?;
        let full = match answer {
            Some(answer) => format!("{text} → {answer}"),
            None => text,
        };
        hits.push(Hit {
            kind: "question",
            id: id.to_string(),
            session_id: Some(session_id),
            title,
            snippet: snippet(&full, &words),
            ts: Some(at),
        });
    }

    let event_text = "(e.summary || ' ' || COALESCE(e.body, ''))";
    let mut statement = connection.prepare(&format!(
        "SELECT e.id, e.session_id, s.title, e.summary, e.body, e.ts FROM events e
         JOIN sessions s ON s.id = e.session_id
         WHERE (?1 IS NULL OR e.project = ?1) AND {}
         ORDER BY e.ts DESC, e.id DESC LIMIT {limit}",
        all_words(event_text, n, 2)
    ))?;
    let rows = statement.query_map(params_from_iter(values.iter()), |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, i64>(5)?,
        ))
    })?;
    for row in rows {
        let (id, session_id, title, summary, body, ts) = row?;
        let text = match body {
            Some(body) => format!("{summary} {body}"),
            None => summary,
        };
        hits.push(Hit {
            kind: "event",
            id: id.to_string(),
            session_id: Some(session_id),
            title,
            snippet: snippet(&text, &words),
            ts: Some(ts),
        });
    }

    let baseline_text = "(b.version || ' ' || b.note || ' ' || COALESCE(b.ref_name, ''))";
    let mut statement = connection.prepare(&format!(
        "SELECT b.version, b.project, b.note, b.ts, b.by_session FROM baselines b
         WHERE (?1 IS NULL OR b.project = ?1) AND {} LIMIT {limit}",
        all_words(baseline_text, n, 2)
    ))?;
    let rows = statement.query_map(params_from_iter(values.iter()), |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, Option<String>>(4)?,
        ))
    })?;
    let mut baselines = Vec::new();
    for row in rows {
        let (version, project, note, ts, by) = row?;
        baselines.push(Hit {
            kind: "baseline",
            id: version.clone(),
            session_id: by,
            title: format!("{project} v{version}"),
            snippet: snippet(&note, &words),
            ts: Some(ts),
        });
    }
    baselines.sort_by(|a, b| crate::util::compare_versions(&b.id, &a.id));
    hits.extend(baselines);
    hits.truncate(limit);
    Ok(hits)
}
