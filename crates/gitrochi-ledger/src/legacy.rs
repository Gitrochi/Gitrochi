//! Importing a claude-ledger database (decision D5), the standalone tool this ledger
//! re-implements. The file is opened read-only and never written. Its projects, baselines,
//! sessions, events, questions and the hashes of pasted blocks are copied in one write
//! transaction; a session whose ID the ledger already has is skipped with its history.
//! Only the file's table and column names are relied on — the compatibility surface that
//! reading it needs. Work-ledger and note tables are not read (D3).

use crate::db::{self, Db};
use crate::error::{Error, Result};
use crate::event::{self, NewEvent};
use crate::report;
use crate::settings::Settings;
use crate::util::{self, clean, json_text, Ms};
use crate::vocab;
use rusqlite::types::ValueRef;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, Row, TransactionBehavior};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// What the import copied, or with `dryRun` would copy (`import_legacy` in CONTRACT.md).
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    /// Project rows created (the file keeps no project settings, only names).
    pub projects: usize,
    pub baselines: usize,
    /// Baselines the ledger had that the file completed: an inferred version promoted, or a
    /// missing releaser or note filled in.
    pub baselines_updated: usize,
    pub sessions: usize,
    pub events: usize,
    pub questions: usize,
    /// Hashes of pasted blocks, so blocks imported there count as duplicates here.
    pub imports: usize,
}

impl Counts {
    pub fn is_empty(&self) -> bool {
        *self == Counts::default()
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyImport {
    pub ok: bool,
    pub dry_run: bool,
    pub rev: i64,
    pub counts: Counts,
    /// Sessions whose ID the ledger already has; neither they nor their history were copied.
    pub skipped: Vec<String>,
    /// Rows that could not be read; everything else was imported.
    pub errors: Vec<String>,
}

/// Imports the claude-ledger database at `path`. A dry run, or a file with nothing new,
/// writes nothing, so `rev` stays and the apps do not reload.
pub fn import(db: &Db, path: &Path, dry_run: bool) -> Result<LegacyImport> {
    let source = read(path)?;
    let (preview, rev) = db.read(|c| {
        let settings = Settings::load(c)?;
        Ok((copy(c, &source, &settings, false)?, db::rev(c)?))
    })?;
    if dry_run || preview.counts.is_empty() {
        return Ok(preview.result(dry_run, rev));
    }
    let (outcome, rev) = db.write(|c| {
        let settings = Settings::load(c)?;
        copy(c, &source, &settings, true)
    })?;
    Ok(outcome.result(false, rev))
}

// ── Reading the file

/// Files SQLite keeps next to a database while it is open, or after a crash.
const SIDECARS: [&str; 3] = ["-wal", "-shm", "-journal"];

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

/// A `file:` URI SQLite accepts on every platform: `%`, `?`, `#`, spaces and bytes outside
/// printable ASCII are escaped, and a Windows drive gets the leading slash.
fn file_uri(path: &Path, query: &str) -> String {
    let mut bytes = path.as_os_str().as_encoded_bytes().to_vec();
    if cfg!(windows) {
        for byte in &mut bytes {
            if *byte == b'\\' {
                *byte = b'/';
            }
        }
    }
    let mut uri = String::from("file://");
    if bytes.first() != Some(&b'/') {
        uri.push('/');
    }
    for byte in bytes {
        match byte {
            b'%' | b'?' | b'#' => uri.push_str(&format!("%{byte:02X}")),
            0x21..=0x7e => uri.push(byte as char),
            _ => uri.push_str(&format!("%{byte:02X}")),
        }
    }
    uri.push('?');
    uri.push_str(query);
    uri
}

/// Opens the file without ever writing to it. With nothing next to it nobody has it open,
/// so `immutable=1` reads it with no locks and creates no files. A `-wal`, `-shm` or
/// `-journal` file means the tool has it open or stopped mid-write: then `mode=ro` with
/// SQLite's usual locking reads the newest committed data consistently.
fn open(path: &Path) -> Result<Connection> {
    let absolute = std::path::absolute(path)
        .map_err(|e| Error::invalid(format!("Could not read {}: {e}", path.display())))?;
    if !absolute.is_file() {
        return Err(Error::invalid(format!("No such file: {}", path.display())));
    }
    let in_use = SIDECARS.iter().any(|s| sidecar(&absolute, s).exists());
    let query = if in_use { "mode=ro" } else { "immutable=1" };
    let connection = Connection::open_with_flags(
        file_uri(&absolute, query),
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| Error::invalid(format!("Could not open {}: {e}", path.display())))?;
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.execute_batch("PRAGMA query_only = ON; PRAGMA trusted_schema = OFF;")?;
    Ok(connection)
}

fn not_legacy(path: &Path, why: impl std::fmt::Display) -> Error {
    Error::invalid(format!(
        "{} is not a claude-ledger database ({why})",
        path.display()
    ))
}

struct Session {
    id: String,
    project: String,
    kind: String,
    title: String,
    base_version: Option<String>,
    base_current: Option<String>,
    base_was_latest: bool,
    status: String,
    merged_into: Option<String>,
    touches: Vec<String>,
    related: Vec<String>,
    chat_url: Option<String>,
    channel: String,
    color: i64,
    created_at: Ms,
    last_at: Ms,
    last_agent_at: Ms,
    ack_at: Option<Ms>,
    snooze_at: Option<Ms>,
    archived_at: Option<Ms>,
}

struct Event {
    session_id: String,
    ts: Ms,
    kind: String,
    actor: &'static str,
    summary: String,
    version: Option<String>,
    artifacts: Vec<Value>,
    data: Value,
    channel: String,
    delivered_at: Option<Ms>,
}

struct Question {
    id: i64,
    session_id: String,
    text: String,
    state: String,
    answer: Option<String>,
    answered_by: Option<&'static str>,
    created_at: Ms,
    answered_at: Option<Ms>,
    delivered_at: Option<Ms>,
}

#[derive(Clone, Debug, PartialEq)]
struct Baseline {
    project: String,
    version: String,
    ts: Ms,
    source: String,
    note: String,
    by_session: Option<String>,
}

/// Everything the import copies, read in one snapshot and already in the contract's terms.
struct Source {
    sessions: Vec<Session>,
    /// In time order, so events at the same time keep their order.
    events: Vec<Event>,
    questions: Vec<Question>,
    baselines: Vec<Baseline>,
    hashes: Vec<(String, Ms)>,
    /// Rows that could not be read, whatever the ledger already holds.
    errors: Vec<String>,
}

fn text_at(row: &Row, index: usize) -> rusqlite::Result<Option<String>> {
    Ok(match row.get_ref(index)? {
        ValueRef::Text(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        ValueRef::Integer(n) => Some(n.to_string()),
        ValueRef::Real(f) => Some(f.to_string()),
        ValueRef::Null | ValueRef::Blob(_) => None,
    })
}

fn int_at(row: &Row, index: usize) -> rusqlite::Result<Option<i64>> {
    Ok(match row.get_ref(index)? {
        ValueRef::Integer(n) => Some(n),
        ValueRef::Real(f) => Some(f as i64),
        ValueRef::Text(bytes) => std::str::from_utf8(bytes)
            .ok()
            .and_then(|t| t.trim().parse().ok()),
        ValueRef::Null | ValueRef::Blob(_) => None,
    })
}

/// NFC, trimmed, `None` when empty — how identifiers are compared everywhere in the ledger.
fn ident(row: &Row, index: usize) -> rusqlite::Result<Option<String>> {
    Ok(text_at(row, index)?.as_deref().and_then(clean))
}

fn json_at(row: &Row, index: usize) -> rusqlite::Result<Value> {
    Ok(text_at(row, index)?
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null))
}

/// `SELECT` of the wanted columns in order, `NULL` for any this file lacks, so an older file
/// with fewer columns still reads.
fn select(
    path: &Path,
    connection: &Connection,
    table: &str,
    wanted: &[&str],
    required: &[&str],
    order: &str,
) -> Result<String> {
    let have = connection
        .prepare(&format!("PRAGMA table_info(\"{table}\")"))?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<rusqlite::Result<HashSet<_>>>()?;
    if let Some(missing) = required.iter().find(|c| !have.contains(**c)) {
        return Err(not_legacy(
            path,
            format!("its {table} table has no {missing} column"),
        ));
    }
    let list: Vec<String> = wanted
        .iter()
        .map(|c| {
            if have.contains(*c) {
                format!("\"{c}\"")
            } else {
                "NULL".to_string()
            }
        })
        .collect();
    Ok(format!(
        "SELECT {} FROM \"{table}\" ORDER BY {order}",
        list.join(", ")
    ))
}

/// Runs `sql` and keeps what `each` makes of every row.
fn collect<T>(
    connection: &Connection,
    sql: &str,
    mut each: impl FnMut(&Row) -> Result<Option<T>>,
) -> Result<Vec<T>> {
    let mut statement = connection.prepare(sql)?;
    let mut rows = statement.query([])?;
    let mut out = Vec::new();
    while let Some(row) = rows.next()? {
        if let Some(item) = each(row)? {
            out.push(item);
        }
    }
    Ok(out)
}

fn read(path: &Path) -> Result<Source> {
    let mut connection = open(path)?;
    let tx = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
    let tables: HashSet<String> = collect(
        &tx,
        "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')",
        |r| Ok(Some(r.get(0)?)),
    )
    .map_err(|e| not_legacy(path, e.message))?
    .into_iter()
    .collect();
    if let Some(missing) = ["sessions", "events", "items", "versions"]
        .iter()
        .find(|t| !tables.contains(**t))
    {
        let why = if tables.contains("questions") && tables.contains("baselines") {
            "it looks like a Gitrochi ledger".to_string()
        } else {
            format!("no {missing} table")
        };
        return Err(not_legacy(path, why));
    }
    let mut errors = Vec::new();
    let (mut sessions, known) = read_sessions(path, &tx, &mut errors)?;
    let questions = read_questions(path, &tx, &known, &mut errors)?;
    let events = read_events(path, &tx, &known, &mut errors)?;
    let baselines = read_baselines(path, &tx, &mut errors)?;
    let hashes = if tables.contains("imports") {
        let sql = select(path, &tx, "imports", &["hash", "ts"], &["hash"], "1")?;
        collect(&tx, &sql, |r| {
            let ts = int_at(r, 1)?.unwrap_or(0);
            Ok(ident(r, 0)?.map(|hash| (hash, ts)))
        })?
    } else {
        Vec::new()
    };
    tx.commit()?;

    // The newest report each session's own agent sent; hand-off records (`data.by` naming
    // another session) are activity on the session but not its agent's reports.
    let mut own_last: HashMap<&str, Ms> = HashMap::new();
    for e in &events {
        let by = e.data["by"].as_str();
        if e.actor == "agent" && by.is_none_or(|by| by == e.session_id) {
            let last = own_last.entry(e.session_id.as_str()).or_insert(e.ts);
            *last = (*last).max(e.ts);
        }
    }
    for s in &mut sessions {
        if let Some(&ts) = own_last.get(s.id.as_str()) {
            s.last_agent_at = ts.max(s.created_at);
        }
        s.last_at = s.last_at.max(s.last_agent_at);
    }
    Ok(Source {
        sessions,
        events,
        questions,
        baselines,
        hashes,
        errors,
    })
}

/// The readable sessions, oldest first, and every ID in the file (readable or not, so the
/// history of an unreadable session is not reported as belonging to none).
fn read_sessions(
    path: &Path,
    c: &Connection,
    errors: &mut Vec<String>,
) -> Result<(Vec<Session>, HashSet<String>)> {
    let sql = select(
        path,
        c,
        "sessions",
        &[
            "id",
            "project",
            "kind",
            "title",
            "base_version",
            "base_current",
            "base_was_latest",
            "status",
            "merged_into",
            "touches",
            "related",
            "chat_url",
            "channel",
            "color",
            "created_ts",
            "last_ts",
            "ack_ts",
            "snooze_ts",
            "archived_ts",
        ],
        &["id", "project"],
        "15, 1",
    )?;
    let mut known = HashSet::new();
    let sessions = collect(c, &sql, |row| {
        let Some(id) = ident(row, 0)? else {
            errors.push("A session without an ID was not imported.".to_string());
            return Ok(None);
        };
        if !known.insert(id.clone()) {
            errors.push(format!(
                "Session {id} appears twice; the second was not imported."
            ));
            return Ok(None);
        }
        if !util::valid_session_id(&id) {
            errors.push(format!(
                "Session {id}: the ledger does not accept this ID shape; not imported."
            ));
            return Ok(None);
        }
        let Some(project) = ident(row, 1)? else {
            errors.push(format!("Session {id}: no project; not imported."));
            return Ok(None);
        };
        let status = ident(row, 7)?.unwrap_or_else(|| "active".to_string());
        if !vocab::STATUSES.contains(&status.as_str()) {
            errors.push(format!(
                "Session {id}: unknown status '{status}'; not imported."
            ));
            return Ok(None);
        }
        let created_at = int_at(row, 14)?.or(int_at(row, 15)?).unwrap_or(0);
        Ok(Some(Session {
            id,
            project,
            kind: ident(row, 2)?.map_or_else(String::new, |k| vocab::kind(&k)),
            title: text_at(row, 3)?.unwrap_or_default(),
            base_version: ident(row, 4)?,
            base_current: ident(row, 5)?,
            base_was_latest: int_at(row, 6)?.unwrap_or(0) != 0,
            status,
            merged_into: ident(row, 8)?,
            touches: util::list_of(&json_at(row, 9)?),
            related: util::list_of(&json_at(row, 10)?),
            chat_url: ident(row, 11)?.filter(|url| report::is_link(url)),
            channel: text_at(row, 12)?.unwrap_or_default(),
            color: int_at(row, 13)?.unwrap_or(0).rem_euclid(8),
            created_at,
            last_at: int_at(row, 15)?.unwrap_or(created_at).max(created_at),
            last_agent_at: created_at,
            ack_at: int_at(row, 16)?,
            snooze_at: int_at(row, 17)?,
            archived_at: int_at(row, 18)?,
        }))
    })?;
    Ok((sessions, known))
}

/// Questions (the file's `items`), oldest first.
fn read_questions(
    path: &Path,
    c: &Connection,
    known: &HashSet<String>,
    errors: &mut Vec<String>,
) -> Result<Vec<Question>> {
    let sql = select(
        path,
        c,
        "items",
        &[
            "id",
            "session_id",
            "ts",
            "text",
            "state",
            "answer",
            "answered_by",
            "answered_ts",
            "delivered_ts",
        ],
        &["id", "session_id", "text"],
        "1",
    )?;
    let mut orphans = 0;
    let questions = collect(c, &sql, |row| {
        let (Some(id), Some(session_id)) = (int_at(row, 0)?, ident(row, 1)?) else {
            errors.push("A question without an ID or session was not imported.".to_string());
            return Ok(None);
        };
        if !known.contains(&session_id) {
            orphans += 1;
            return Ok(None);
        }
        let state = ident(row, 4)?.unwrap_or_else(|| "open".to_string());
        if !["open", "answered", "dismissed"].contains(&state.as_str()) {
            errors.push(format!(
                "Question #{id} of {session_id}: unknown state '{state}'; not imported."
            ));
            return Ok(None);
        }
        Ok(Some(Question {
            id,
            session_id,
            text: text_at(row, 3)?.unwrap_or_default(),
            state,
            answer: text_at(row, 5)?,
            answered_by: ident(row, 6)?.as_deref().and_then(answered_by),
            created_at: int_at(row, 2)?.unwrap_or(0),
            answered_at: int_at(row, 7)?,
            delivered_at: int_at(row, 8)?,
        }))
    })?;
    if orphans > 0 {
        errors.push(format!(
            "{orphans} question(s) belong to no session in the file and were not imported."
        ));
    }
    Ok(questions)
}

/// Events in time order.
fn read_events(
    path: &Path,
    c: &Connection,
    known: &HashSet<String>,
    errors: &mut Vec<String>,
) -> Result<Vec<Event>> {
    let sql = select(
        path,
        c,
        "events",
        &[
            "id",
            "session_id",
            "ts",
            "type",
            "actor",
            "summary",
            "ssot",
            "artifacts",
            "data",
            "channel",
            "delivered_ts",
        ],
        &["session_id", "ts", "type"],
        "3, 1",
    )?;
    let (mut unreadable, mut orphans) = (0, 0);
    let events = collect(c, &sql, |row| {
        let (Some(session_id), Some(ts), Some(raw_type)) =
            (ident(row, 1)?, int_at(row, 2)?, ident(row, 3)?)
        else {
            unreadable += 1;
            return Ok(None);
        };
        if !known.contains(&session_id) {
            orphans += 1;
            return Ok(None);
        }
        let actor = actor(ident(row, 4)?.as_deref().unwrap_or(""));
        Ok(Some(Event {
            session_id,
            ts,
            kind: event_type(&raw_type, actor),
            actor,
            summary: text_at(row, 5)?.unwrap_or_default(),
            version: ident(row, 6)?,
            artifacts: artifacts(&json_at(row, 7)?),
            data: json_at(row, 8)?,
            channel: text_at(row, 9)?.unwrap_or_default(),
            delivered_at: int_at(row, 10)?,
        }))
    })?;
    if unreadable > 0 {
        errors.push(format!(
            "{unreadable} event(s) without a session, time or type were not imported."
        ));
    }
    if orphans > 0 {
        errors.push(format!(
            "{orphans} event(s) belong to no session in the file and were not imported."
        ));
    }
    Ok(events)
}

/// Baselines (the file's `versions`).
fn read_baselines(path: &Path, c: &Connection, errors: &mut Vec<String>) -> Result<Vec<Baseline>> {
    let sql = select(
        path,
        c,
        "versions",
        &["project", "version", "ts", "source", "note", "by_session"],
        &["project", "version"],
        "1, 2",
    )?;
    let mut seen = HashSet::new();
    let mut nameless = 0;
    let baselines = collect(c, &sql, |row| {
        let (Some(project), Some(version)) = (ident(row, 0)?, ident(row, 1)?) else {
            nameless += 1;
            return Ok(None);
        };
        if !seen.insert((project.clone(), version.clone())) {
            return Ok(None);
        }
        Ok(Some(Baseline {
            project,
            version,
            ts: int_at(row, 2)?.unwrap_or(0),
            source: baseline_source(ident(row, 3)?.as_deref().unwrap_or("")),
            note: text_at(row, 4)?.unwrap_or_default(),
            by_session: ident(row, 5)?,
        }))
    })?;
    if nameless > 0 {
        errors.push(format!(
            "{nameless} baseline(s) without a project or version were not imported."
        ));
    }
    Ok(baselines)
}

// ── The original's words in the contract's terms

/// The original records a person as `human` and its agent as `claude`.
fn actor(raw: &str) -> &'static str {
    match raw {
        "human" => "human",
        _ => "agent",
    }
}

/// A person's `status` and `note` are `set_status` and `message` here (both are delivered to
/// the agent once). Agent events go through the alias table; unknown types are kept.
fn event_type(raw: &str, actor: &str) -> String {
    if actor == "human" {
        return match raw {
            "status" => "set_status",
            "note" => "message",
            other => other,
        }
        .to_string();
    }
    vocab::agent_event(raw).map_or_else(|| raw.to_string(), str::to_string)
}

/// Who settled a question: `claude` there is the session itself (`resolves`), `agent` here.
fn answered_by(raw: &str) -> Option<&'static str> {
    match raw {
        "human" => Some("human"),
        "claude" => Some("agent"),
        _ => None,
    }
}

/// `scan` there is a folder scan here; an unknown source is treated as registered.
fn baseline_source(raw: &str) -> String {
    match raw {
        "scan" => "folder",
        "registered" | "release" | "inferred" => raw,
        _ => "registered",
    }
    .to_string()
}

/// Artifacts with the contract's keys; empty fields are dropped.
fn artifacts(raw: &Value) -> Vec<Value> {
    let items = match raw {
        Value::Array(items) => items.clone(),
        Value::Object(_) => vec![raw.clone()],
        _ => Vec::new(),
    };
    items
        .into_iter()
        .filter_map(|item| {
            let item = match item {
                Value::String(name) => json!({"name": name}),
                Value::Object(_) => item,
                _ => return None,
            };
            let mut artifact = json!({"name": util::arg_str(&item, "name")?});
            if let Some(ssot) = util::arg_str(&item, "ssot") {
                artifact["ssot"] = json!(ssot);
                if item["ssot_inferred"] == json!(true) {
                    artifact["ssotInferred"] = json!(true);
                }
            }
            for key in ["ver", "path", "note"] {
                if let Some(value) = util::arg_str(&item, key) {
                    artifact[key] = json!(value);
                }
            }
            Some(artifact)
        })
        .collect()
}

// Event data keys the original spelled differently.
const DATA_KEYS: [(&str, &str); 4] = [
    ("reopened_from", "reopenedFrom"),
    ("from_status", "fromStatus"),
    ("item", "questionId"),
    ("items", "questionIds"),
];

/// The event's data with the contract's keys and renumbered question IDs; the report body,
/// kept in the data there, moves to its own column.
fn event_data(raw: &Value, renumbered: &HashMap<i64, i64>) -> (Value, Option<String>) {
    let mut data = match raw {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    let body = match data.remove("body") {
        Some(Value::String(text)) => {
            let text = util::nfc_text(&text).replace("\r\n", "\n");
            let text = text.trim();
            (!text.is_empty()).then(|| report::cut_body(text).0)
        }
        _ => None,
    };
    for (old, new) in DATA_KEYS {
        if let Some(value) = data.remove(old) {
            data.entry(new).or_insert(value);
        }
    }
    let renumber = |value: &mut Value| {
        if let Some(id) = value.as_i64().and_then(|id| renumbered.get(&id)) {
            *value = json!(id);
        }
    };
    if let Some(value) = data.get_mut("questionId") {
        renumber(value);
    }
    if let Some(Value::Array(ids)) = data.get_mut("questionIds") {
        ids.iter_mut().for_each(renumber);
    }
    (Value::Object(data), body)
}

// ── Copying

struct Outcome {
    counts: Counts,
    skipped: Vec<String>,
    errors: Vec<String>,
}

impl Outcome {
    fn result(self, dry_run: bool, rev: i64) -> LegacyImport {
        LegacyImport {
            ok: true,
            dry_run,
            rev,
            counts: self.counts,
            skipped: self.skipped,
            errors: self.errors,
        }
    }
}

fn exists(c: &Connection, sql: &str, params: impl rusqlite::Params) -> Result<bool> {
    Ok(c.prepare_cached(sql)?.query_row(params, |r| r.get(0))?)
}

/// The row a baseline has after the import: a version the ledger only inferred takes the
/// file's source and time, a missing releaser or note is filled in, and anything the ledger
/// already knows stays.
fn merged(existing: &Baseline, incoming: &Baseline) -> Baseline {
    let promote = existing.source == "inferred" && incoming.source != "inferred";
    Baseline {
        project: existing.project.clone(),
        version: existing.version.clone(),
        ts: if promote { incoming.ts } else { existing.ts },
        source: if promote {
            incoming.source.clone()
        } else {
            existing.source.clone()
        },
        note: if existing.note.is_empty() {
            incoming.note.clone()
        } else {
            existing.note.clone()
        },
        by_session: existing
            .by_session
            .clone()
            .or_else(|| incoming.by_session.clone()),
    }
}

/// Decides and, with `write`, performs every copy. The dry run and the real import share
/// this code, so the preview counts are exactly what the import does.
fn copy(c: &Connection, source: &Source, settings: &Settings, write: bool) -> Result<Outcome> {
    let mut counts = Counts::default();
    let mut skipped = Vec::new();

    let mut sessions = Vec::new();
    for session in &source.sessions {
        if exists(
            c,
            "SELECT EXISTS (SELECT 1 FROM sessions WHERE id = ?1)",
            [&session.id],
        )? {
            skipped.push(session.id.clone());
        } else {
            sessions.push(session);
        }
    }
    let imported: HashSet<&str> = sessions.iter().map(|s| s.id.as_str()).collect();

    // Projects: the file keeps only their names, so the rows take the default settings.
    let mut first_seen: BTreeMap<&str, Ms> = BTreeMap::new();
    let seen = sessions
        .iter()
        .map(|s| (s.project.as_str(), s.created_at))
        .chain(source.baselines.iter().map(|b| (b.project.as_str(), b.ts)));
    for (project, ts) in seen {
        let first = first_seen.entry(project).or_insert(ts);
        *first = (*first).min(ts);
    }
    for (project, created_at) in first_seen {
        if !exists(
            c,
            "SELECT EXISTS (SELECT 1 FROM projects WHERE key = ?1)",
            [project],
        )? {
            counts.projects += 1;
            if write {
                c.execute(
                    "INSERT INTO projects (key, name, created_at) VALUES (?1, ?1, ?2)",
                    params![project, created_at],
                )?;
            }
        }
    }

    // Baselines. A releaser is kept only when that session is imported now: the same ID in
    // the ledger may be another conversation, and a wrong releaser would misdirect hand-offs.
    for incoming in &source.baselines {
        let incoming = Baseline {
            by_session: incoming
                .by_session
                .clone()
                .filter(|id| imported.contains(id.as_str())),
            ..incoming.clone()
        };
        let existing = c
            .query_row(
                "SELECT ts, source, note, by_session FROM baselines WHERE project = ?1 AND version = ?2",
                params![incoming.project, incoming.version],
                |r| {
                    Ok(Baseline {
                        project: incoming.project.clone(),
                        version: incoming.version.clone(),
                        ts: r.get(0)?,
                        source: r.get(1)?,
                        note: r.get(2)?,
                        by_session: r.get(3)?,
                    })
                },
            )
            .optional()?;
        let row = match existing {
            None => {
                counts.baselines += 1;
                incoming
            }
            Some(existing) => {
                let row = merged(&existing, &incoming);
                if row == existing {
                    continue;
                }
                counts.baselines_updated += 1;
                row
            }
        };
        if write {
            c.execute(
                "INSERT INTO baselines (project, version, ts, source, note, by_session)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT (project, version) DO UPDATE SET ts = excluded.ts,
                   source = excluded.source, note = excluded.note, by_session = excluded.by_session",
                params![
                    row.project,
                    row.version,
                    row.ts,
                    row.source,
                    row.note,
                    row.by_session
                ],
            )?;
        }
    }

    // Sessions. The file's "still active" time becomes the end of the snooze it started.
    let stale = settings.stale_ms();
    for s in &sessions {
        counts.sessions += 1;
        if write {
            c.execute(
                "INSERT INTO sessions (id, project, kind, title, base_version, base_current,
                    base_was_latest, status, merged_into, touches, related, chat_url, channel,
                    color, created_at, last_at, last_agent_at, ack_at, snooze_until, archived_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
                    ?17, ?18, ?19, ?20)",
                params![
                    s.id,
                    s.project,
                    s.kind,
                    s.title,
                    s.base_version,
                    s.base_current,
                    s.base_was_latest as i64,
                    s.status,
                    s.merged_into,
                    json_text(&s.touches),
                    json_text(&s.related),
                    s.chat_url,
                    s.channel,
                    s.color,
                    s.created_at,
                    s.last_at,
                    s.last_agent_at,
                    s.ack_at,
                    s.snooze_at.map(|at| at + stale),
                    s.archived_at,
                ],
            )?;
        }
    }

    // Questions keep their numbers where the ledger has them free, so an agent's `resolves`
    // and a person's answers still point at the right one; the rest are renumbered after
    // them and the events' references follow.
    let mut kept = Vec::new();
    let mut moved = Vec::new();
    for q in source
        .questions
        .iter()
        .filter(|q| imported.contains(q.session_id.as_str()))
    {
        if exists(
            c,
            "SELECT EXISTS (SELECT 1 FROM questions WHERE id = ?1)",
            [q.id],
        )? {
            moved.push(q);
        } else {
            kept.push(q);
        }
    }
    let mut renumbered = HashMap::new();
    for (q, keep) in kept
        .into_iter()
        .map(|q| (q, true))
        .chain(moved.into_iter().map(|q| (q, false)))
    {
        counts.questions += 1;
        if write {
            c.execute(
                "INSERT INTO questions (id, session_id, text, state, answer, answered_by,
                    created_at, answered_at, delivered_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    keep.then_some(q.id),
                    q.session_id,
                    q.text,
                    q.state,
                    q.answer,
                    q.answered_by,
                    q.created_at,
                    q.answered_at,
                    q.delivered_at
                ],
            )?;
            if !keep {
                renumbered.insert(q.id, c.last_insert_rowid());
            }
        }
    }

    let projects: HashMap<&str, &str> = sessions
        .iter()
        .map(|s| (s.id.as_str(), s.project.as_str()))
        .collect();
    for e in &source.events {
        let Some(project) = projects.get(e.session_id.as_str()) else {
            continue;
        };
        counts.events += 1;
        if write {
            let (data, body) = event_data(&e.data, &renumbered);
            event::insert(
                c,
                &NewEvent {
                    session_id: &e.session_id,
                    project,
                    ts: e.ts,
                    kind: &e.kind,
                    actor: e.actor,
                    summary: &e.summary,
                    body: body.as_deref(),
                    version: e.version.as_deref(),
                    artifacts: &Value::Array(e.artifacts.clone()),
                    data: &data,
                    channel: &e.channel,
                    delivered_at: e.delivered_at,
                },
            )?;
        }
    }

    for (hash, ts) in &source.hashes {
        if !exists(
            c,
            "SELECT EXISTS (SELECT 1 FROM imports WHERE hash = ?1)",
            [hash],
        )? {
            counts.imports += 1;
            if write {
                c.execute(
                    "INSERT OR IGNORE INTO imports (hash, ts) VALUES (?1, ?2)",
                    params![hash, ts],
                )?;
            }
        }
    }

    Ok(Outcome {
        counts,
        skipped,
        errors: source.errors.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uris_escape_what_sqlite_reads_as_syntax() {
        let uri = file_uri(Path::new("/tmp/a b/50%?#/ledger.db"), "mode=ro");
        assert_eq!(uri, "file:///tmp/a%20b/50%25%3F%23/ledger.db?mode=ro");
        let uri = file_uri(Path::new("/tmp/é/l.db"), "immutable=1");
        assert_eq!(uri, "file:///tmp/%C3%A9/l.db?immutable=1");
    }

    #[test]
    fn the_original_words_map_to_the_contract() {
        assert_eq!(actor("claude"), "agent");
        assert_eq!(actor("human"), "human");
        assert_eq!(actor(""), "agent");
        assert_eq!(event_type("status", "human"), "set_status");
        assert_eq!(event_type("note", "human"), "message");
        assert_eq!(event_type("note", "agent"), "note");
        assert_eq!(event_type("update", "human"), "update");
        assert_eq!(event_type("이행", "agent"), "applied");
        assert_eq!(event_type("custom", "agent"), "custom");
        assert_eq!(answered_by("claude"), Some("agent"));
        assert_eq!(answered_by("someone"), None);
        assert_eq!(baseline_source("scan"), "folder");
        assert_eq!(baseline_source("release"), "release");
        assert_eq!(baseline_source("?"), "registered");
    }

    #[test]
    fn artifacts_and_data_take_the_contract_keys() {
        let raw = json!([
            {"name": "table", "ssot": "1.0.3", "ver": "", "path": "", "note": "", "ssot_inferred": true},
            {"name": "", "ssot": "1.0.3"},
            "plain",
            7
        ]);
        assert_eq!(
            artifacts(&raw),
            [
                json!({"name": "table", "ssot": "1.0.3", "ssotInferred": true}),
                json!({"name": "plain"})
            ]
        );
        let raw = json!({"body": " text\r\n", "item": 4, "items": [4, 9], "from_status": "done",
                         "reopened_from": "merged", "by": "x-1"});
        let (data, body) = event_data(&raw, &HashMap::from([(4, 40)]));
        assert_eq!(body.as_deref(), Some("text"));
        assert_eq!(
            data,
            json!({"questionId": 40, "questionIds": [40, 9], "fromStatus": "done",
                   "reopenedFrom": "merged", "by": "x-1"})
        );
        let long = "x".repeat(report::BODY_MAX + 10);
        let (_, body) = event_data(&json!({"body": long}), &HashMap::new());
        assert_eq!(body.unwrap().chars().count(), report::BODY_MAX);
    }

    #[test]
    fn baselines_fill_in_without_overriding() {
        let base = Baseline {
            project: "P".into(),
            version: "1.0.0".into(),
            ts: 10,
            source: "inferred".into(),
            note: String::new(),
            by_session: None,
        };
        let incoming = Baseline {
            ts: 5,
            source: "release".into(),
            note: "first".into(),
            by_session: Some("S1".into()),
            ..base.clone()
        };
        let row = merged(&base, &incoming);
        assert_eq!(
            (row.ts, row.source.as_str(), row.note.as_str()),
            (5, "release", "first")
        );
        assert_eq!(row.by_session.as_deref(), Some("S1"));
        let known = Baseline {
            source: "tag".into(),
            note: "kept".into(),
            by_session: Some("S2".into()),
            ..base.clone()
        };
        assert_eq!(merged(&known, &incoming), known);
    }
}
