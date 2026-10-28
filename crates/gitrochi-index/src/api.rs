//! The one command dispatcher behind the command line, `serve`, the C ABI (macOS) and
//! the Tauri commands (Windows), so every consumer gets the same JSON.

use crate::db::{self, Shared};
use crate::error::{Error, Result};
use crate::git::Repo;
use crate::{cache, query, sync, text};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

/// Handles `{"repo", "db"?, "command", "args"}` and answers `{"result"}` or `{"error"}`.
pub fn call(request: &Value) -> Value {
    let repo = request["repo"].as_str().map(PathBuf::from);
    let db = request["db"].as_str().map(PathBuf::from);
    let command = request["command"].as_str().unwrap_or("");
    let mut args = match &request["args"] {
        Value::Object(map) => map.clone(),
        _ => Default::default(),
    };
    if let Some(git) = request["git"].as_str() {
        args.insert("git".into(), json!(git));
    }
    match run(
        repo.as_deref(),
        db.as_deref(),
        command,
        &Value::Object(args),
    ) {
        Ok(result) => json!({"result": result}),
        Err(error) => json!({"error": error.to_json()}),
    }
}

fn string(args: &Value, key: &str) -> Option<String> {
    match &args[key] {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn required(args: &Value, key: &str) -> Result<String> {
    string(args, key)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::invalid(format!("Missing {key}")))
}

fn int(args: &Value, key: &str) -> Result<Option<i64>> {
    match &args[key] {
        Value::Null => Ok(None),
        Value::Number(n) => n
            .as_i64()
            .map(Some)
            .ok_or_else(|| Error::invalid(format!("{key} must be a whole number"))),
        Value::String(s) => s
            .parse()
            .map(Some)
            .map_err(|_| Error::invalid(format!("{key} must be a whole number"))),
        _ => Err(Error::invalid(format!("{key} must be a whole number"))),
    }
}

fn count(args: &Value, key: &str, default: i64) -> Result<i64> {
    Ok(int(args, key)?.unwrap_or(default).clamp(0, 1_000_000))
}

fn float(args: &Value, key: &str, default: f64) -> Result<f64> {
    match &args[key] {
        Value::Null => Ok(default),
        Value::Number(n) => Ok(n.as_f64().unwrap_or(default)),
        Value::String(s) => s
            .parse()
            .map_err(|_| Error::invalid(format!("{key} must be a number"))),
        _ => Err(Error::invalid(format!("{key} must be a number"))),
    }
}

fn flag(args: &Value, key: &str) -> bool {
    match &args[key] {
        Value::Bool(b) => *b,
        Value::String(s) => s == "true" || s == "1",
        Value::Number(n) => n.as_i64() == Some(1),
        _ => false,
    }
}

fn strings(args: &Value, key: &str) -> Vec<String> {
    match &args[key] {
        Value::Array(items) => items
            .iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect(),
        Value::String(s) => vec![s.clone()],
        _ => vec![],
    }
}

fn time(args: &Value, key: &str) -> Result<Option<i64>> {
    match &args[key] {
        Value::Null => Ok(None),
        Value::Number(n) => Ok(n.as_i64()),
        Value::String(s) => query::parse_time(s, db::now(), key == "until").map(Some),
        _ => Err(Error::invalid(format!("{key} must be a date"))),
    }
}

pub fn version() -> Value {
    json!({
        "tool": "gitrochi-index",
        "version": env!("CARGO_PKG_VERSION"),
        "schemaVersion": db::SCHEMA_VERSION,
        "sqliteVersion": rusqlite::version(),
        "tokenizer": text::version(),
    })
}

fn tokenize(args: &Value) -> Result<Value> {
    let tokens: Vec<Value> = text::tokenize(&required(args, "text")?, flag(args, "query"))
        .into_iter()
        .map(|t| json!({"text": t.text, "start": t.start, "end": t.end, "colocated": t.colocated}))
        .collect();
    Ok(json!({"tokens": tokens}))
}

fn status(shared: &Shared, repo: &Repo) -> Result<Value> {
    let connection = shared.reader();
    let counts: (i64, i64, i64, i64, i64, Option<i64>, Option<i64>) = connection.query_row(
        "SELECT (SELECT COUNT(*) FROM commits), (SELECT COUNT(*) FROM paths),
                (SELECT COUNT(*) FROM file_changes), (SELECT COUNT(*) FROM cochange),
                (SELECT COUNT(*) FROM refs), (SELECT MAX(commit_time) FROM commits),
                (SELECT MIN(commit_time) FROM commits)",
        [],
        |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
            ))
        },
    )?;
    let size = |path: PathBuf| std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let mut wal = shared.path.clone().into_os_string();
    wal.push("-wal");
    Ok(json!({
        "indexed": true,
        "repository": repo.top.to_string_lossy(),
        "database": shared.path.to_string_lossy(),
        "schemaVersion": db::SCHEMA_VERSION,
        "commits": counts.0,
        "paths": counts.1,
        "fileChanges": counts.2,
        "cochangePairs": counts.3,
        "refs": counts.4,
        "newestCommitTime": counts.5,
        "oldestCommitTime": counts.6,
        "lastSync": db::meta(&connection, "last_sync")?.and_then(|v| v.parse::<i64>().ok()),
        "shallow": db::meta(&connection, "shallow")?.as_deref() == Some("1"),
        "maxFiles": sync::max_files(&connection)?,
        "sizeBytes": size(shared.path.clone()) + size(PathBuf::from(wal)),
        "stale": query::stale(&connection, repo)?,
        "syncing": shared.syncing.load(Ordering::SeqCst),
        "syncProcessed": shared.processed.load(Ordering::SeqCst),
    }))
}

/// Runs one command. `repo_dir` defaults to the current folder and `db` to the index
/// in the repository's git common dir (or `GITROCHI_INDEX_DB`); `args.git` picks the git.
pub fn run(
    repo_dir: Option<&Path>,
    db_path: Option<&Path>,
    command: &str,
    args: &Value,
) -> Result<Value> {
    const COMMANDS: [&str; 17] = [
        "version", "tokenize", "path", "status", "sync", "prune", "search", "match", "log", "show",
        "file", "coupled", "hotspots", "owners", "impact", "cache", "serve",
    ];
    match command {
        "version" => return Ok(version()),
        "tokenize" => return tokenize(args),
        "serve" => return Err(Error::invalid("serve runs only from the command line")),
        _ if !COMMANDS.contains(&command) => {
            return Err(Error::invalid(format!("Unknown command: {command}")))
        }
        _ => {}
    }
    let dir = string(args, "repo")
        .map(PathBuf::from)
        .or_else(|| repo_dir.map(Path::to_path_buf))
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));
    let repo = Repo::discover(&dir, string(args, "git").as_deref())?;
    let path = db_path
        .map(Path::to_path_buf)
        .or_else(|| {
            std::env::var_os("GITROCHI_INDEX_DB")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .unwrap_or_else(|| repo.database());
    match command {
        "path" => {
            return Ok(json!({
                "repository": repo.top.to_string_lossy(),
                "gitCommonDir": repo.common_dir.to_string_lossy(),
                "database": path.to_string_lossy(),
                "exists": path.exists(),
            }))
        }
        "status" if !path.exists() => {
            return Ok(json!({
                "indexed": false,
                "repository": repo.top.to_string_lossy(),
                "database": path.to_string_lossy(),
                "schemaVersion": db::SCHEMA_VERSION,
                "stale": true,
            }))
        }
        "sync" | "prune" => {}
        _ if !path.exists() => {
            return Err(Error::new(
                "NOT_INDEXED",
                "This repository has no index yet; run `gitrochi-index sync` first",
            ))
        }
        _ => {}
    }
    let shared = db::shared(&path)?;
    match command {
        "sync" => sync::sync(
            &shared,
            &repo,
            &sync::Options {
                max_files: int(args, "maxFiles")?,
                renames: !flag(args, "noRenames"),
                limit: int(args, "limit")?.map(|l| l.max(1) as usize),
            },
        ),
        "status" => status(&shared, &repo),
        "search" => query::search(
            &shared.reader(),
            &required(args, "query")?,
            string(args, "scope").as_deref().unwrap_or("commits"),
            string(args, "sort").as_deref().unwrap_or("rank"),
            count(args, "limit", 50)?,
            count(args, "offset", 0)?,
        ),
        "match" => query::match_shas(
            &shared.reader(),
            &repo,
            &required(args, "query")?,
            string(args, "scope").as_deref().unwrap_or("commits"),
            count(args, "limit", 20_000)? as usize,
        ),
        "log" => {
            let path = string(args, "path");
            let author = string(args, "author");
            query::log(
                &shared.reader(),
                &query::LogFilter {
                    path: path.as_deref(),
                    follow: flag(args, "follow"),
                    author: author.as_deref(),
                    since: time(args, "since")?,
                    until: time(args, "until")?,
                    limit: count(args, "limit", 100)?,
                    offset: count(args, "offset", 0)?,
                },
            )
        }
        "show" => query::show(&shared.reader(), &required(args, "sha")?),
        "file" => query::file(
            &shared.reader(),
            &required(args, "path")?,
            count(args, "limit", 20)?,
        ),
        "coupled" => query::coupled(
            &shared.reader(),
            &required(args, "path")?,
            count(args, "limit", 20)?,
            count(args, "minCommits", 2)?,
        ),
        "hotspots" => query::hotspots(
            &shared.reader(),
            &repo,
            time(args, "since")?,
            string(args, "prefix").as_deref(),
            count(args, "limit", 50)? as usize,
        ),
        "owners" => query::owners(
            &shared.reader(),
            string(args, "prefix").as_deref(),
            time(args, "since")?,
            count(args, "limit", 20)?,
        ),
        "impact" => {
            let paths = strings(args, "paths");
            if paths.is_empty() {
                return Err(Error::invalid("Missing paths"));
            }
            query::impact(
                &shared.reader(),
                &paths,
                count(args, "limit", 20)? as usize,
                float(args, "minConfidence", 0.3)?,
                count(args, "minCommits", 2)?,
            )
        }
        "cache" => match string(args, "action").as_deref().unwrap_or("") {
            "grep" => cache::grep(
                &shared,
                &repo,
                &required(args, "pattern")?,
                flag(args, "ignoreCase"),
                flag(args, "fixed"),
                count(args, "limit", 500)? as usize,
            ),
            "pickaxe" => cache::pickaxe(
                &shared,
                &repo,
                &required(args, "text")?,
                flag(args, "regex"),
                count(args, "limit", 500)? as usize,
            ),
            "stats" => cache::stats(&shared),
            "clear" => cache::clear(&shared),
            other => Err(Error::invalid(format!(
                "Unknown cache action: {other} (grep, pickaxe, stats or clear)"
            ))),
        },
        "prune" => sync::prune(&shared, &repo),
        other => Err(Error::invalid(format!("Unknown command: {other}"))),
    }
}
