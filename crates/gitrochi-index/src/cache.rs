//! Search cache for searches only git can answer. `grep` results belong to a tree;
//! `pickaxe` results belong to a set of ref tips and are extended by searching just
//! the new commits when the tips move.

use crate::db::{self, Shared};
use crate::error::{Error, Result};
use crate::git::Repo;
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::collections::BTreeSet;

const MAX_ENTRIES: i64 = 256;
const MAX_BYTES: i64 = 32 * 1024 * 1024;

fn key(kind: &str, options: &str, query: &str) -> String {
    // Readable and exact: the key holds the whole query, so different queries never share
    // an entry.
    format!("{kind}\u{1f}{options}\u{1f}{query}")
}

fn lookup(shared: &Shared, key: &str) -> Result<Option<(String, Value)>> {
    let connection = shared.reader();
    let found: Option<(String, String)> = connection
        .prepare_cached("SELECT scope, result FROM search_cache WHERE key = ?1")?
        .query_row([key], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?;
    Ok(found.and_then(|(scope, result)| Some((scope, serde_json::from_str(&result).ok()?))))
}

fn touch(shared: &Shared, key: &str) -> Result<()> {
    shared.writer().execute(
        "UPDATE search_cache SET used = ?2, hits = hits + 1 WHERE key = ?1",
        params![key, db::now()],
    )?;
    Ok(())
}

fn store(
    shared: &Shared,
    key: &str,
    kind: &str,
    query: &str,
    scope: &str,
    result: &Value,
) -> Result<()> {
    let text = result.to_string();
    let now = db::now();
    let connection = shared.writer();
    connection.execute(
        "INSERT INTO search_cache (key, kind, query, scope, created, used, hits, bytes, result)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0, ?6, ?7)
         ON CONFLICT (key) DO UPDATE SET scope = excluded.scope, created = excluded.created,
             used = excluded.used, bytes = excluded.bytes, result = excluded.result",
        params![key, kind, query, scope, now, text.len() as i64, text],
    )?;
    // Least recently used entries go first once either bound is passed.
    connection.execute(
        "DELETE FROM search_cache WHERE key IN (
             SELECT key FROM (
                 SELECT key, SUM(bytes) OVER (ORDER BY used DESC, key) AS running,
                        ROW_NUMBER() OVER (ORDER BY used DESC, key) AS position
                 FROM search_cache)
             WHERE running > ?1 OR position > ?2)",
        params![MAX_BYTES, MAX_ENTRIES],
    )?;
    Ok(())
}

/// `git grep` over the HEAD tree, cached per tree.
pub fn grep(
    shared: &Shared,
    repo: &Repo,
    pattern: &str,
    ignore_case: bool,
    fixed: bool,
    limit: usize,
) -> Result<Value> {
    if pattern.is_empty() {
        return Err(Error::invalid("Missing pattern"));
    }
    let Some(tree) = repo.head_tree()? else {
        return Ok(
            json!({"kind": "grep", "cached": false, "scope": null, "matches": [], "truncated": false}),
        );
    };
    let options = format!("i={ignore_case},F={fixed},n={limit}");
    let key = key("grep", &options, pattern);
    if let Some((scope, result)) = lookup(shared, &key)? {
        if scope == tree {
            touch(shared, &key)?;
            return Ok(with_cached(result, true));
        }
    }
    let mut args = vec!["grep", "-z", "-n", "-I", "--no-color", "--full-name"];
    if ignore_case {
        args.push("-i");
    }
    args.push(if fixed { "-F" } else { "-E" });
    args.extend(["-e", pattern, &tree]);
    let prefix = format!("{tree}:");
    let mut matches = Vec::new();
    let mut truncated = false;
    // Records are "<tree>:<path>\0<line>\0<text>"; git stops once the limit is passed.
    let (code, stderr) = repo.stream_lines(&args, |record| {
        if record.is_empty() {
            return true;
        }
        if matches.len() == limit {
            truncated = true;
            return false;
        }
        let mut fields = record.splitn(3, |b| *b == 0);
        let path = String::from_utf8_lossy(fields.next().unwrap_or_default()).into_owned();
        let line: i64 = String::from_utf8_lossy(fields.next().unwrap_or_default())
            .parse()
            .unwrap_or(0);
        let text = String::from_utf8_lossy(fields.next().unwrap_or_default());
        matches.push(json!({
            "path": path.strip_prefix(&prefix).unwrap_or(&path),
            "line": line,
            "text": text.chars().take(400).collect::<String>(),
        }));
        true
    })?;
    // Exit code 1 means no match, which is a result rather than a failure.
    if !truncated && !matches!(code, Some(0) | Some(1)) {
        return Err(Error::git(format!(
            "git grep failed: {}",
            String::from_utf8_lossy(&stderr)
                .lines()
                .next()
                .unwrap_or("")
                .trim()
        )));
    }
    let result = json!({"kind": "grep", "scope": tree, "matches": matches, "truncated": truncated});
    store(shared, &key, "grep", pattern, &tree, &result)?;
    Ok(with_cached(result, false))
}

fn with_cached(mut result: Value, cached: bool) -> Value {
    result["cached"] = json!(cached);
    result
}

fn pickaxe_log(
    repo: &Repo,
    text: &str,
    regex: bool,
    include: &[String],
    exclude: &[String],
    max: usize,
) -> Result<Vec<Value>> {
    if include.is_empty() {
        return Ok(vec![]);
    }
    let flag = if regex {
        format!("-G{text}")
    } else {
        format!("-S{text}")
    };
    let count = format!("--max-count={max}");
    let mut input = String::new();
    for sha in include {
        input.push_str(sha);
        input.push('\n');
    }
    for sha in exclude {
        input.push('^');
        input.push_str(sha);
        input.push('\n');
    }
    let output = repo.output_with_input(
        &[
            "log",
            "--stdin",
            "--no-ext-diff",
            "--no-textconv",
            "--format=%H%x1f%ct%x1f%s",
            &count,
            &flag,
        ],
        Some(input.into_bytes()),
    )?;
    Ok(String::from_utf8_lossy(&output)
        .lines()
        .filter_map(|line| {
            let mut fields = line.splitn(3, '\u{1f}');
            let sha = fields.next()?;
            let time: i64 = fields.next()?.parse().ok()?;
            Some(json!({"sha": sha, "commitTime": time, "subject": fields.next().unwrap_or("")}))
        })
        .collect())
}

/// `git log -S` (or `-G` with `regex`) over every indexed ref, cached per set of tips.
/// Git stops after `limit` matches like a plain `git log -n`; the entry records whether
/// it holds every match, so a later, larger limit searches again only when needed.
pub fn pickaxe(
    shared: &Shared,
    repo: &Repo,
    text: &str,
    regex: bool,
    limit: usize,
) -> Result<Value> {
    if text.is_empty() {
        return Err(Error::invalid("Missing text"));
    }
    let limit = limit.max(1);
    let tips: Vec<String> = repo
        .refs()?
        .into_iter()
        .map(|(_, sha)| sha)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let scope = tips.join(",");
    let key = key("pickaxe", &format!("regex={regex}"), text);
    let cached = lookup(shared, &key)?;
    let list = |result: &Value| result["commits"].as_array().cloned().unwrap_or_default();
    if let Some((old_scope, result)) = &cached {
        let complete = result["complete"].as_bool().unwrap_or(false);
        if *old_scope == scope && (complete || list(result).len() >= limit) {
            touch(shared, &key)?;
            return Ok(shape(list(result), limit, &scope, true));
        }
    }
    let (mut commits, complete) = match cached {
        // Tips moved: search only what is new, then put it in front of the old result.
        Some((old_scope, result)) if old_scope != scope => {
            let old: Vec<String> = old_scope
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
            let existing = repo.existing_commits(&old)?;
            if existing.len() == old.len() {
                let mut commits = pickaxe_log(repo, text, regex, &tips, &existing, limit)?;
                // A cut-off new part leaves a gap before the old matches.
                let complete =
                    commits.len() < limit && result["complete"].as_bool().unwrap_or(false);
                commits.extend(list(&result));
                (commits, complete)
            } else {
                let commits = pickaxe_log(repo, text, regex, &tips, &[], limit)?;
                let complete = commits.len() < limit;
                (commits, complete)
            }
        }
        _ => {
            let commits = pickaxe_log(repo, text, regex, &tips, &[], limit)?;
            let complete = commits.len() < limit;
            (commits, complete)
        }
    };
    commits.sort_by(|a, b| b["commitTime"].as_i64().cmp(&a["commitTime"].as_i64()));
    let mut seen = std::collections::HashSet::new();
    commits.retain(|c| seen.insert(c["sha"].as_str().unwrap_or("").to_string()));
    store(
        shared,
        &key,
        "pickaxe",
        text,
        &scope,
        &json!({"commits": commits, "complete": complete}),
    )?;
    Ok(shape(commits, limit, &scope, false))
}

fn shape(mut commits: Vec<Value>, limit: usize, scope: &str, cached: bool) -> Value {
    let truncated = commits.len() > limit;
    commits.truncate(limit);
    json!({
        "kind": "pickaxe",
        "cached": cached,
        "scope": format!("{} tips", scope.split(',').filter(|s| !s.is_empty()).count()),
        "commits": commits,
        "truncated": truncated,
    })
}

pub fn stats(shared: &Shared) -> Result<Value> {
    let connection = shared.reader();
    let (entries, bytes, hits): (i64, i64, i64) = connection.query_row(
        "SELECT COUNT(*), coalesce(SUM(bytes), 0), coalesce(SUM(hits), 0) FROM search_cache",
        [],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    Ok(json!({"entries": entries, "bytes": bytes, "hits": hits}))
}

pub fn clear(shared: &Shared) -> Result<Value> {
    let removed = shared.writer().execute("DELETE FROM search_cache", [])?;
    Ok(json!({"removed": removed}))
}
