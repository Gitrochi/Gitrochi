//! Read queries: full-text search, the apps' substring matching, history, ownership and
//! change relationships.

use crate::db;
use crate::error::{Error, Result};
use crate::git::Repo;
use crate::text;
use rusqlite::types::Value as Sql;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

const COMMIT_COLUMNS: &str = "c.sha, c.author_name, c.author_email, c.author_time, \
    c.committer_name, c.committer_email, c.commit_time, c.subject, c.body, c.files_changed, \
    c.additions, c.deletions, \
    (SELECT group_concat(parent_sha, ' ' ORDER BY position) FROM commit_parents WHERE commit_id = c.id)";
const COMMIT_FIELDS: usize = 13;
const DAY: i64 = 86_400;

fn commit(row: &Row, at: usize) -> rusqlite::Result<Value> {
    let parents: Option<String> = row.get(at + 12)?;
    Ok(json!({
        "sha": row.get::<_, String>(at)?,
        "authorName": row.get::<_, String>(at + 1)?,
        "authorEmail": row.get::<_, String>(at + 2)?,
        "authorTime": row.get::<_, i64>(at + 3)?,
        "committerName": row.get::<_, String>(at + 4)?,
        "committerEmail": row.get::<_, String>(at + 5)?,
        "commitTime": row.get::<_, i64>(at + 6)?,
        "subject": row.get::<_, String>(at + 7)?,
        "body": row.get::<_, String>(at + 8)?,
        "filesChanged": row.get::<_, i64>(at + 9)?,
        "additions": row.get::<_, i64>(at + 10)?,
        "deletions": row.get::<_, i64>(at + 11)?,
        "parents": parents.unwrap_or_default().split_whitespace().collect::<Vec<_>>(),
    }))
}

fn rows<F>(connection: &Connection, sql: &str, params: Vec<Sql>, map: F) -> Result<Vec<Value>>
where
    F: FnMut(&Row) -> rusqlite::Result<Value>,
{
    let mut statement = connection.prepare_cached(sql)?;
    let mapped = statement.query_map(params_from_iter(params), map)?;
    Ok(mapped.collect::<rusqlite::Result<_>>()?)
}

pub fn path_id(connection: &Connection, path: &str) -> Result<Option<i64>> {
    Ok(connection
        .prepare_cached("SELECT id FROM paths WHERE path = ?1")?
        .query_row([path], |r| r.get(0))
        .optional()?)
}

// ---- Query language -------------------------------------------------------------

const FILTERS: [&str; 6] = ["author", "path", "since", "until", "merge", "sha"];

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Query {
    pub terms: Vec<Term>,
    pub authors: Vec<String>,
    pub paths: Vec<String>,
    pub shas: Vec<String>,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub merge: Option<bool>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Term {
    pub text: String,
    pub phrase: bool,
}

impl Query {
    fn has_filters(&self) -> bool {
        !self.authors.is_empty()
            || !self.paths.is_empty()
            || !self.shas.is_empty()
            || self.since.is_some()
            || self.until.is_some()
            || self.merge.is_some()
    }
}

/// Splits a query into (filter key, value, quoted) pieces. Only known filter names
/// count as keys, so `https://example.com` stays a word.
fn lex(input: &str) -> Vec<(Option<String>, String, bool)> {
    let chars: Vec<char> = input.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        let mut key = None;
        let mut j = i;
        while j < chars.len() && chars[j].is_ascii_alphabetic() {
            j += 1;
        }
        if j > i && j < chars.len() && chars[j] == ':' {
            let name: String = chars[i..j].iter().collect::<String>().to_ascii_lowercase();
            if FILTERS.contains(&name.as_str()) {
                key = Some(name);
                i = j + 1;
            }
        }
        let (value, quoted) = if i < chars.len() && chars[i] == '"' {
            let start = i + 1;
            let mut end = start;
            while end < chars.len() && chars[end] != '"' {
                end += 1;
            }
            i = (end + 1).min(chars.len());
            (chars[start..end].iter().collect::<String>(), true)
        } else {
            let start = i;
            while i < chars.len() && !chars[i].is_whitespace() {
                i += 1;
            }
            (chars[start..i].iter().collect::<String>(), false)
        };
        if !value.is_empty() {
            out.push((key, value, quoted));
        }
    }
    out
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    // Howard Hinnant's algorithm: days since 1970-01-01 in the proleptic Gregorian calendar.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `2026-01-31` (UTC; `until` includes the whole day), `@1767225600`, or `30d`, `2w`,
/// `6m`, `1y` before now.
pub fn parse_time(value: &str, now: i64, end_of_day: bool) -> Result<i64> {
    let invalid = || {
        Error::invalid(format!(
            "Unknown date: {value} (use YYYY-MM-DD, @seconds or 30d)"
        ))
    };
    if let Some(seconds) = value.strip_prefix('@') {
        return seconds.parse().map_err(|_| invalid());
    }
    if let Some(unit) = value.chars().last().filter(|c| "dwmy".contains(*c)) {
        let count: i64 = value[..value.len() - 1].parse().map_err(|_| invalid())?;
        let days = match unit {
            'd' => 1,
            'w' => 7,
            'm' => 30,
            _ => 365,
        };
        return Ok(now - count * days * DAY);
    }
    let parts: Vec<i64> = value
        .split('-')
        .map(|p| p.parse::<i64>())
        .collect::<std::result::Result<_, _>>()
        .map_err(|_| invalid())?;
    if parts.len() != 3 || !(1..=12).contains(&parts[1]) || !(1..=31).contains(&parts[2]) {
        return Err(invalid());
    }
    let start = days_from_civil(parts[0], parts[1], parts[2]) * DAY;
    Ok(if end_of_day { start + DAY } else { start })
}

pub fn parse(input: &str, now: i64) -> Result<Query> {
    let mut query = Query::default();
    for (key, value, quoted) in lex(input) {
        match key.as_deref() {
            Some("author") => query.authors.push(value),
            Some("path") => query.paths.push(
                value
                    .trim_start_matches("./")
                    .trim_start_matches('/')
                    .to_string(),
            ),
            Some("sha") => query.shas.push(value.to_ascii_lowercase()),
            Some("since") => query.since = Some(parse_time(&value, now, false)?),
            Some("until") => query.until = Some(parse_time(&value, now, true)?),
            Some("merge") => {
                query.merge = Some(match value.to_ascii_lowercase().as_str() {
                    "yes" | "true" | "1" => true,
                    "no" | "false" | "0" => false,
                    _ => return Err(Error::invalid("merge: takes yes or no")),
                })
            }
            _ if !quoted && value.len() >= 7 && value.bytes().all(|b| b.is_ascii_hexdigit()) => {
                query.shas.push(value.to_ascii_lowercase())
            }
            _ => query.terms.push(Term {
                text: value,
                phrase: quoted,
            }),
        }
    }
    Ok(query)
}

/// The FTS5 MATCH expression: every term quoted (no query syntax gets through), bare
/// words as prefixes, and terms the tokenizer drops entirely left out.
pub fn fts_match(terms: &[Term]) -> Option<String> {
    let parts: Vec<String> = terms
        .iter()
        .filter_map(|term| {
            let text = term.text.trim_end_matches('*');
            if text::tokenize(text, true).is_empty() {
                return None;
            }
            let quoted = format!("\"{}\"", text.replace('"', "\"\""));
            Some(if term.phrase { quoted } else { quoted + "*" })
        })
        .collect();
    (!parts.is_empty()).then(|| parts.join(" AND "))
}

fn like(text: &str) -> String {
    let mut escaped = String::from("%");
    for c in text.chars() {
        if matches!(c, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped.push('%');
    escaped
}

fn prefix_range(prefix: &str) -> (String, String) {
    (prefix.to_string(), format!("{prefix}{}", char::MAX))
}

fn filters(query: &Query, clauses: &mut Vec<String>, params: &mut Vec<Sql>) {
    for author in &query.authors {
        clauses
            .push("(c.author_name LIKE ? ESCAPE '\\' OR c.author_email LIKE ? ESCAPE '\\')".into());
        params.push(Sql::Text(like(author)));
        params.push(Sql::Text(like(author)));
    }
    for path in &query.paths {
        clauses.push(
            "c.id IN (SELECT fc.commit_id FROM file_changes fc WHERE fc.path_id IN \
             (SELECT id FROM paths WHERE path >= ? AND path < ?))"
                .into(),
        );
        let (low, high) = prefix_range(path);
        params.push(Sql::Text(low));
        params.push(Sql::Text(high));
    }
    for sha in &query.shas {
        // Hex digits sort below 'g', so prefix..prefix+"g" holds every SHA with the prefix.
        clauses.push("(c.sha >= ? AND c.sha < ?)".into());
        params.push(Sql::Text(sha.clone()));
        params.push(Sql::Text(format!("{sha}g")));
    }
    if let Some(since) = query.since {
        clauses.push("c.commit_time >= ?".into());
        params.push(Sql::Integer(since));
    }
    if let Some(until) = query.until {
        clauses.push("c.commit_time < ?".into());
        params.push(Sql::Integer(until));
    }
    match query.merge {
        Some(true) => clauses.push("c.parent_count > 1".into()),
        Some(false) => clauses.push("c.parent_count <= 1".into()),
        None => {}
    }
}

// ---- Search ------------------------------------------------------------------------

pub fn search(
    connection: &Connection,
    input: &str,
    scope: &str,
    sort: &str,
    limit: i64,
    offset: i64,
) -> Result<Value> {
    let query = parse(input, db::now())?;
    let results = match scope {
        "commits" => search_commits(connection, &query, sort, limit, offset)?,
        "paths" => search_paths(connection, &query, limit, offset)?,
        other => return Err(Error::invalid(format!("Unknown scope: {other}"))),
    };
    Ok(json!({"query": input, "scope": scope, "results": results}))
}

fn search_commits(
    connection: &Connection,
    query: &Query,
    sort: &str,
    limit: i64,
    offset: i64,
) -> Result<Vec<Value>> {
    let mut clauses = Vec::new();
    let mut params = Vec::new();
    let fts = fts_match(&query.terms);
    let sql = if let Some(expression) = &fts {
        params.push(Sql::Text(expression.clone()));
        filters(query, &mut clauses, &mut params);
        let order = if sort == "time" {
            "c.commit_time DESC, c.seq DESC"
        } else {
            "rank, c.commit_time DESC, c.seq DESC"
        };
        format!(
            "SELECT {COMMIT_COLUMNS},
                    bm25(commit_text, 10.0, 1.0, 4.0, 2.0) AS rank,
                    highlight(commit_text, 0, char(2), char(3)),
                    snippet(commit_text, 1, char(2), char(3), '…', 16)
             FROM commit_text JOIN commits c ON c.id = commit_text.rowid
             WHERE commit_text MATCH ? {}
             ORDER BY {order} LIMIT ? OFFSET ?",
            clauses
                .iter()
                .map(|c| format!("AND {c}"))
                .collect::<String>()
        )
    } else {
        if !query.has_filters() {
            return Ok(vec![]);
        }
        filters(query, &mut clauses, &mut params);
        format!(
            "SELECT {COMMIT_COLUMNS}, 0.0, c.subject, '' FROM commits c
             WHERE {} ORDER BY c.commit_time DESC, c.seq DESC LIMIT ? OFFSET ?",
            clauses.join(" AND ")
        )
    };
    params.push(Sql::Integer(limit));
    params.push(Sql::Integer(offset));
    rows(connection, &sql, params, |row| {
        let mut value = commit(row, 0)?;
        value["rank"] = json!(row.get::<_, f64>(COMMIT_FIELDS)?);
        value["highlight"] = json!(row.get::<_, String>(COMMIT_FIELDS + 1)?);
        let snippet: String = row.get(COMMIT_FIELDS + 2)?;
        if snippet.contains('\u{2}') {
            value["bodySnippet"] = json!(snippet);
        }
        Ok(value)
    })
}

fn search_paths(
    connection: &Connection,
    query: &Query,
    limit: i64,
    offset: i64,
) -> Result<Vec<Value>> {
    let Some(expression) = fts_match(&query.terms) else {
        return Ok(vec![]);
    };
    let mut params = vec![Sql::Text(expression)];
    let mut clauses = String::new();
    for path in &query.paths {
        let (low, high) = prefix_range(path);
        clauses.push_str(" AND p.path >= ? AND p.path < ?");
        params.push(Sql::Text(low));
        params.push(Sql::Text(high));
    }
    params.push(Sql::Integer(limit));
    params.push(Sql::Integer(offset));
    let sql = format!(
        "SELECT p.path, coalesce(s.commits, 0), s.last_time, highlight(path_text, 0, char(2), char(3))
         FROM path_text JOIN paths p ON p.id = path_text.rowid
         LEFT JOIN path_stats s ON s.path_id = p.id
         WHERE path_text MATCH ?{clauses}
         ORDER BY bm25(path_text), coalesce(s.last_time, 0) DESC LIMIT ? OFFSET ?"
    );
    rows(connection, &sql, params, |row| {
        Ok(json!({
            "path": row.get::<_, String>(0)?,
            "commits": row.get::<_, i64>(1)?,
            "lastTime": row.get::<_, Option<i64>>(2)?,
            "highlight": row.get::<_, String>(3)?,
        }))
    })
}

/// Whether the index lags the repository: different ref tips, or history still missing.
pub fn stale(connection: &Connection, repo: &Repo) -> Result<bool> {
    let shallow = db::meta(connection, "shallow")?.as_deref() == Some("1");
    Ok(shallow || repo.refs()? != crate::sync::stored_refs(connection)?)
}

fn compact(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_lowercase()
}

/// The apps' search semantics, answered from the index instead of `git log`: commits
/// whose message has a line containing the query with whitespace and case ignored
/// (`--grep`), or commits that touched a path containing it (`':(glob,icase)**/*q*'`).
/// macOS: RepoStore+Search.swift; Windows: entities/repo/model/layers/search.ts.
pub fn match_shas(
    connection: &Connection,
    repo: &Repo,
    input: &str,
    scope: &str,
    limit: usize,
) -> Result<Value> {
    let mut shas = Vec::new();
    let mut truncated = false;
    match scope {
        "commits" => {
            let key = compact(input);
            if !key.is_empty() {
                let mut statement = connection.prepare_cached(
                    "SELECT sha, subject, body FROM commits ORDER BY commit_time DESC, seq DESC",
                )?;
                let mut found = statement.query([])?;
                while let Some(row) = found.next()? {
                    let subject: String = row.get(1)?;
                    let body: String = row.get(2)?;
                    let hit = compact(&subject).contains(&key)
                        || body.lines().any(|line| compact(line).contains(&key));
                    if hit {
                        if shas.len() == limit {
                            truncated = true;
                            break;
                        }
                        shas.push(row.get::<_, String>(0)?);
                    }
                }
            }
        }
        "files" => {
            let needle = input.trim().to_lowercase();
            if !needle.is_empty() {
                let ids: Vec<i64> = {
                    let mut statement = connection.prepare_cached("SELECT id, path FROM paths")?;
                    let all = statement
                        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
                    let mut ids = Vec::new();
                    for row in all {
                        let (id, path) = row?;
                        if path.to_lowercase().contains(&needle) {
                            ids.push(id);
                        }
                    }
                    ids
                };
                if !ids.is_empty() {
                    let mut statement = connection.prepare_cached(
                        "SELECT c.sha FROM commits c WHERE c.id IN (
                             SELECT fc.commit_id FROM file_changes fc
                             WHERE fc.path_id IN (SELECT value FROM json_each(?1)))
                         ORDER BY c.commit_time DESC, c.seq DESC LIMIT ?2",
                    )?;
                    let found = statement
                        .query_map(params![json!(ids).to_string(), limit as i64 + 1], |r| {
                            r.get(0)
                        })?;
                    for sha in found {
                        shas.push(sha?);
                    }
                    if shas.len() > limit {
                        shas.truncate(limit);
                        truncated = true;
                    }
                }
            }
        }
        other => return Err(Error::invalid(format!("Unknown scope: {other}"))),
    }
    Ok(json!({
        "scope": scope,
        "shas": shas,
        "truncated": truncated,
        "stale": stale(connection, repo)?,
    }))
}

// ---- History -----------------------------------------------------------------------

pub struct LogFilter<'a> {
    pub path: Option<&'a str>,
    pub follow: bool,
    pub author: Option<&'a str>,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub limit: i64,
    pub offset: i64,
}

/// A name of the path and, for older names, the commit time and id of the rename that
/// ended it.
type NameSpan = (i64, Option<(i64, i64)>);

/// The path's names through renames, newest first.
fn rename_chain(connection: &Connection, start: i64) -> Result<Vec<NameSpan>> {
    let mut chain = vec![(start, None)];
    let mut seen = HashSet::from([start]);
    let mut statement = connection.prepare_cached(
        "SELECT fc.old_path_id, c.commit_time, c.id FROM file_changes fc
         JOIN commits c ON c.id = fc.commit_id
         WHERE fc.path_id = ?1 AND fc.status = 'R' AND fc.old_path_id IS NOT NULL
           AND (?2 IS NULL OR c.commit_time <= ?2)
         ORDER BY c.commit_time DESC, c.seq DESC LIMIT 1",
    )?;
    while chain.len() < 64 {
        let (current, until): NameSpan = chain[chain.len() - 1];
        let rename: Option<(i64, i64, i64)> = statement
            .query_row(params![current, until.map(|u| u.0)], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()?;
        match rename {
            Some((old, time, id)) if seen.insert(old) => chain.push((old, Some((time, id)))),
            _ => break,
        }
    }
    Ok(chain)
}

pub fn log(connection: &Connection, filter: &LogFilter) -> Result<Value> {
    let mut clauses = Vec::new();
    let mut params = Vec::new();
    if let Some(path) = filter.path {
        let Some(id) = path_id(connection, path)? else {
            return Ok(json!({"commits": []}));
        };
        let chain = if filter.follow {
            rename_chain(connection, id)?
        } else {
            vec![(id, None)]
        };
        let mut options = Vec::new();
        for (path, until) in chain {
            match until {
                None => {
                    options.push("fc.path_id = ?".to_string());
                    params.push(Sql::Integer(path));
                }
                Some((time, rename)) => {
                    options
                        .push("(fc.path_id = ? AND c.commit_time <= ? AND c.id <> ?)".to_string());
                    params.extend([Sql::Integer(path), Sql::Integer(time), Sql::Integer(rename)]);
                }
            }
        }
        clauses.push(format!(
            "c.id IN (SELECT fc.commit_id FROM file_changes fc JOIN commits c ON c.id = fc.commit_id WHERE {})",
            options.join(" OR ")
        ));
    }
    let query = Query {
        authors: filter
            .author
            .map(|a| vec![a.to_string()])
            .unwrap_or_default(),
        since: filter.since,
        until: filter.until,
        ..Default::default()
    };
    filters(&query, &mut clauses, &mut params);
    params.push(Sql::Integer(filter.limit));
    params.push(Sql::Integer(filter.offset));
    let sql = format!(
        "SELECT {COMMIT_COLUMNS} FROM commits c {} ORDER BY c.commit_time DESC, c.seq DESC LIMIT ? OFFSET ?",
        if clauses.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", clauses.join(" AND "))
        }
    );
    Ok(json!({"commits": rows(connection, &sql, params, |r| commit(r, 0))?}))
}

pub fn show(connection: &Connection, sha: &str) -> Result<Value> {
    let sql = format!("SELECT c.id, {COMMIT_COLUMNS} FROM commits c WHERE c.sha = ?1");
    let found = connection
        .query_row(&sql, [sha], |row| {
            Ok((row.get::<_, i64>(0)?, commit(row, 1)?))
        })
        .optional()?;
    let Some((id, commit)) = found else {
        return Err(Error::new(
            "NOT_FOUND",
            format!("Commit not indexed: {sha}"),
        ));
    };
    let files = rows(
        connection,
        "SELECT p.path, o.path, fc.status, fc.similarity, fc.additions, fc.deletions
         FROM file_changes fc JOIN paths p ON p.id = fc.path_id
         LEFT JOIN paths o ON o.id = fc.old_path_id
         WHERE fc.commit_id = ? ORDER BY p.path",
        vec![Sql::Integer(id)],
        |r| {
            Ok(json!({
                "path": r.get::<_, String>(0)?,
                "oldPath": r.get::<_, Option<String>>(1)?,
                "status": r.get::<_, String>(2)?,
                "similarity": r.get::<_, Option<i64>>(3)?,
                "additions": r.get::<_, Option<i64>>(4)?,
                "deletions": r.get::<_, Option<i64>>(5)?,
            }))
        },
    )?;
    Ok(json!({"commit": commit, "files": files}))
}

// ---- Ownership and change relationships -------------------------------------------

fn author(row: &Row) -> rusqlite::Result<Value> {
    Ok(json!({
        "name": row.get::<_, String>(0)?,
        "email": row.get::<_, String>(1)?,
        "commits": row.get::<_, i64>(2)?,
        "additions": row.get::<_, i64>(3)?,
        "deletions": row.get::<_, i64>(4)?,
        "lastTime": row.get::<_, i64>(5)?,
    }))
}

pub fn coupled(connection: &Connection, path: &str, limit: i64, min_commits: i64) -> Result<Value> {
    let Some(id) = path_id(connection, path)? else {
        return Ok(json!({"path": path, "commits": 0, "partners": []}));
    };
    let own: i64 = connection
        .query_row(
            "SELECT coupling_commits FROM path_stats WHERE path_id = ?1",
            [id],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0);
    let partners = rows(
        connection,
        "SELECT p.path, x.commits, x.last_time, coalesce(s.coupling_commits, 0) FROM (
             SELECT b AS other, commits, last_time FROM cochange WHERE a = ?1
             UNION ALL
             SELECT a AS other, commits, last_time FROM cochange WHERE b = ?1
         ) x JOIN paths p ON p.id = x.other LEFT JOIN path_stats s ON s.path_id = x.other
         WHERE x.commits >= ?2
         ORDER BY x.commits DESC, x.last_time DESC LIMIT ?3",
        vec![
            Sql::Integer(id),
            Sql::Integer(min_commits),
            Sql::Integer(limit),
        ],
        |r| {
            let shared: i64 = r.get(1)?;
            let other: i64 = r.get(3)?;
            let union = (own + other - shared).max(1);
            Ok(json!({
                "path": r.get::<_, String>(0)?,
                "commits": shared,
                "confidence": ratio(shared, own),
                "jaccard": ratio(shared, union),
                "lastTime": r.get::<_, i64>(2)?,
            }))
        },
    )?;
    Ok(json!({"path": path, "commits": own, "partners": partners}))
}

fn ratio(part: i64, whole: i64) -> f64 {
    if whole <= 0 {
        0.0
    } else {
        ((part as f64 / whole as f64) * 1000.0).round() / 1000.0
    }
}

pub fn file(connection: &Connection, path: &str, limit: i64) -> Result<Value> {
    let Some(id) = path_id(connection, path)? else {
        return Ok(
            json!({"path": path, "stats": null, "authors": [], "coupled": [], "history": []}),
        );
    };
    let stats = connection
        .query_row(
            "SELECT commits, additions, deletions, first_time, last_time FROM path_stats WHERE path_id = ?1",
            [id],
            |r| {
                Ok(json!({
                    "commits": r.get::<_, i64>(0)?,
                    "additions": r.get::<_, i64>(1)?,
                    "deletions": r.get::<_, i64>(2)?,
                    "firstTime": r.get::<_, i64>(3)?,
                    "lastTime": r.get::<_, i64>(4)?,
                }))
            },
        )
        .optional()?;
    let authors = rows(
        connection,
        "SELECT c.author_name, c.author_email, COUNT(*), SUM(coalesce(fc.additions, 0)),
                SUM(coalesce(fc.deletions, 0)), MAX(c.commit_time)
         FROM file_changes fc JOIN commits c ON c.id = fc.commit_id
         WHERE fc.path_id = ?1 GROUP BY lower(c.author_email)
         ORDER BY 3 DESC, 6 DESC LIMIT ?2",
        vec![Sql::Integer(id), Sql::Integer(limit)],
        author,
    )?;
    let coupled = coupled(connection, path, limit, 2)?["partners"].take();
    let history = log(
        connection,
        &LogFilter {
            path: Some(path),
            follow: true,
            author: None,
            since: None,
            until: None,
            limit,
            offset: 0,
        },
    )?["commits"]
        .take();
    Ok(
        json!({"path": path, "stats": stats, "authors": authors, "coupled": coupled, "history": history}),
    )
}

pub fn hotspots(
    connection: &Connection,
    repo: &Repo,
    since: Option<i64>,
    prefix: Option<&str>,
    limit: usize,
) -> Result<Value> {
    let now = db::now();
    let (low, high) = prefix_range(prefix.unwrap_or(""));
    let mut statement = connection.prepare_cached(
        "SELECT p.path, COUNT(*), SUM(coalesce(fc.additions, 0)), SUM(coalesce(fc.deletions, 0)),
                COUNT(DISTINCT lower(c.author_email)), MAX(c.commit_time),
                SUM(1.0 / (1.0 + (?1 - c.commit_time) / 7776000.0))
         FROM file_changes fc JOIN commits c ON c.id = fc.commit_id JOIN paths p ON p.id = fc.path_id
         WHERE c.commit_time >= ?2 AND p.path >= ?3 AND p.path < ?4
         GROUP BY fc.path_id",
    )?;
    // Only files that still exist; a repository without HEAD keeps every path.
    let present = repo.head_paths()?;
    let mut files: Vec<Value> = statement
        .query_map(params![now, since.unwrap_or(i64::MIN), low, high], |r| {
            let additions: i64 = r.get(2)?;
            let deletions: i64 = r.get(3)?;
            let decayed: f64 = r.get(6)?;
            let churn = additions + deletions;
            Ok(json!({
                "path": r.get::<_, String>(0)?,
                "commits": r.get::<_, i64>(1)?,
                "additions": additions,
                "deletions": deletions,
                "churn": churn,
                "authors": r.get::<_, i64>(4)?,
                "lastTime": r.get::<_, i64>(5)?,
                // Recent commits weigh more (90-day half weight); churn adds a log factor.
                "score": ((decayed * (1.0 + (1.0 + churn as f64).ln())) * 100.0).round() / 100.0,
            }))
        })?
        .collect::<rusqlite::Result<_>>()?;
    if let Some(present) = present {
        files.retain(|f| present.contains(f["path"].as_str().unwrap_or("")));
    }
    files.sort_by(|a, b| {
        b["score"]
            .as_f64()
            .partial_cmp(&a["score"].as_f64())
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a["path"].as_str().cmp(&b["path"].as_str()))
    });
    files.truncate(limit);
    Ok(json!({"since": since, "prefix": prefix, "files": files}))
}

pub fn owners(
    connection: &Connection,
    prefix: Option<&str>,
    since: Option<i64>,
    limit: i64,
) -> Result<Value> {
    let (low, high) = prefix_range(prefix.unwrap_or(""));
    let base = "FROM file_changes fc JOIN commits c ON c.id = fc.commit_id JOIN paths p ON p.id = fc.path_id
                WHERE p.path >= ?1 AND p.path < ?2 AND c.commit_time >= ?3";
    let since = since.unwrap_or(i64::MIN);
    let total: i64 = connection.query_row(
        &format!("SELECT COUNT(DISTINCT c.id) {base}"),
        params![low, high, since],
        |r| r.get(0),
    )?;
    let mut authors = rows(
        connection,
        &format!(
            "SELECT c.author_name, c.author_email, COUNT(DISTINCT c.id), SUM(coalesce(fc.additions, 0)),
                    SUM(coalesce(fc.deletions, 0)), MAX(c.commit_time)
             {base} GROUP BY lower(c.author_email) ORDER BY 3 DESC, 6 DESC"
        ),
        vec![Sql::Text(low), Sql::Text(high), Sql::Integer(since)],
        author,
    )?;
    // The fewest authors who together made at least half of the commits.
    let mut covered = 0;
    let mut bus_factor = 0;
    for a in &authors {
        if total == 0 || covered * 2 >= total {
            break;
        }
        covered += a["commits"].as_i64().unwrap_or(0);
        bus_factor += 1;
    }
    for a in &mut authors {
        let commits = a["commits"].as_i64().unwrap_or(0);
        a["share"] = json!(ratio(commits, total));
    }
    authors.truncate(limit.max(0) as usize);
    Ok(json!({"prefix": prefix, "commits": total, "authors": authors, "busFactor": bus_factor}))
}

/// Files that usually change with the given ones but are missing from them. A file's
/// score combines its pairs as independent signals: 1 - Π(1 - confidence).
pub fn impact(
    connection: &Connection,
    paths: &[String],
    limit: usize,
    min_confidence: f64,
    min_commits: i64,
) -> Result<Value> {
    let changed: HashSet<&str> = paths.iter().map(String::as_str).collect();
    let mut found: HashMap<String, (f64, Vec<Value>)> = HashMap::new();
    for path in paths {
        let partners = coupled(connection, path, 200, min_commits)?;
        for partner in partners["partners"].as_array().into_iter().flatten() {
            let other = partner["path"].as_str().unwrap_or("");
            let confidence = partner["confidence"].as_f64().unwrap_or(0.0);
            if changed.contains(other) || confidence < min_confidence {
                continue;
            }
            let entry = found.entry(other.to_string()).or_insert((1.0, vec![]));
            entry.0 *= 1.0 - confidence.min(1.0);
            entry.1.push(
                json!({"path": path, "commits": partner["commits"], "confidence": confidence}),
            );
        }
    }
    let mut suggestions: Vec<Value> = found
        .into_iter()
        .map(|(path, (miss, because))| {
            json!({"path": path, "score": ((1.0 - miss) * 1000.0).round() / 1000.0, "because": because})
        })
        .collect();
    suggestions.sort_by(|a, b| {
        b["score"]
            .as_f64()
            .partial_cmp(&a["score"].as_f64())
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a["path"].as_str().cmp(&b["path"].as_str()))
    });
    suggestions.truncate(limit);
    Ok(json!({"changed": paths, "suggestions": suggestions}))
}
