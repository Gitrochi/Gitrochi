//! Incremental indexing. Each sync reads only the commits past the indexed ref tips,
//! in batches of one transaction each; inserts are idempotent, so processes that sync
//! the same repository at once stay correct.

use crate::db::{self, Shared};
use crate::error::Result;
use crate::git::{LogOptions, RawCommit, Repo};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::Ordering;
use std::time::Instant;

const BATCH: usize = 500;

#[derive(Debug, Clone)]
pub struct Options {
    pub max_files: Option<i64>,
    pub renames: bool,
    pub limit: Option<usize>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_files: None,
            renames: true,
            limit: None,
        }
    }
}

#[derive(Default)]
struct PathStat {
    commits: i64,
    coupling: i64,
    additions: i64,
    deletions: i64,
    first: i64,
    last: i64,
}

struct Progress<'a>(&'a Shared);

impl Drop for Progress<'_> {
    fn drop(&mut self) {
        self.0.syncing.store(false, Ordering::SeqCst);
    }
}

pub fn stored_refs(connection: &Connection) -> Result<Vec<(String, String)>> {
    let mut statement = connection.prepare_cached("SELECT name, sha FROM refs ORDER BY name")?;
    let rows = statement.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn max_files(connection: &Connection) -> Result<i64> {
    Ok(db::meta(connection, "max_files")?
        .and_then(|v| v.parse().ok())
        .unwrap_or(db::DEFAULT_MAX_FILES))
}

pub fn sync(shared: &Shared, repo: &Repo, options: &Options) -> Result<Value> {
    let _serial = shared.sync_guard();
    let started = Instant::now();
    shared.syncing.store(true, Ordering::SeqCst);
    shared.processed.store(0, Ordering::SeqCst);
    let _progress = Progress(shared);

    let current = repo.refs()?;
    let (stored, was_shallow, stored_max) = {
        let connection = shared.writer();
        (
            stored_refs(&connection)?,
            db::meta(&connection, "shallow")?.as_deref() == Some("1"),
            max_files(&connection)?,
        )
    };
    let max_files = options.max_files.unwrap_or(stored_max).max(2);
    if max_files != stored_max {
        let mut connection = shared.writer();
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        rebuild_derived(&tx, max_files)?;
        db::set_meta(&tx, "max_files", &max_files.to_string())?;
        tx.commit()?;
    }

    let up_to_date = current == stored && !was_shallow;
    let mut inserted = 0usize;
    let mut shallow = was_shallow;
    if !up_to_date {
        let tips: Vec<String> = current
            .iter()
            .map(|(_, sha)| sha.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let old: Vec<String> = stored
            .iter()
            .map(|(_, sha)| sha.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let old = repo.existing_commits(&old)?;
        let mut budget = options.limit;
        let mut cut = false;
        if !tips.is_empty() {
            let (count, seen) = ingest(shared, repo, &tips, &old, options, budget, max_files)?;
            inserted += count;
            cut = budget.is_some_and(|limit| seen >= limit);
            budget = budget.map(|limit| limit.saturating_sub(seen));
        }
        // A shallow index continues below its oldest commits, from parents not yet indexed.
        if was_shallow && !cut && budget != Some(0) {
            let boundary = boundary_parents(&shared.writer())?;
            let boundary = repo.existing_commits(&boundary)?;
            if !boundary.is_empty() {
                let (count, seen) =
                    ingest(shared, repo, &boundary, &[], options, budget, max_files)?;
                inserted += count;
                cut = budget.is_some_and(|limit| seen >= limit);
            }
        }
        shallow = cut;
        let mut connection = shared.writer();
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute("DELETE FROM refs", [])?;
        {
            let mut insert = tx.prepare_cached("INSERT INTO refs (name, sha) VALUES (?1, ?2)")?;
            for (name, sha) in &current {
                insert.execute([name, sha])?;
            }
        }
        db::set_meta(&tx, "shallow", if shallow { "1" } else { "0" })?;
        db::set_meta(&tx, "last_sync", &db::now().to_string())?;
        tx.commit()?;
    }
    // An up-to-date sync writes nothing, so file watchers see no change from it.
    let total: i64 = shared
        .writer()
        .query_row("SELECT COUNT(*) FROM commits", [], |r| r.get(0))?;
    Ok(json!({
        "repository": repo.top.to_string_lossy(),
        "database": shared.path.to_string_lossy(),
        "upToDate": up_to_date,
        "newCommits": inserted,
        "totalCommits": total,
        "refs": current.len(),
        "durationMs": started.elapsed().as_millis() as u64,
        "shallow": shallow,
    }))
}

/// Returns (newly inserted commits, commits git produced).
fn ingest(
    shared: &Shared,
    repo: &Repo,
    include: &[String],
    exclude: &[String],
    options: &Options,
    limit: Option<usize>,
    max_files: i64,
) -> Result<(usize, usize)> {
    let stream = repo.log(
        include,
        exclude,
        &LogOptions {
            renames: options.renames,
            limit,
        },
    )?;
    let walk = next_walk(shared)?;
    let mut paths: HashMap<String, i64> = HashMap::new();
    let mut batch = Vec::with_capacity(BATCH);
    let (mut inserted, mut seen) = (0, 0);
    for commit in stream {
        // Later walks sort above earlier ones; within a walk, git's order (newest first) holds.
        let seq = (walk << 32) | i64::from(u32::MAX - seen as u32);
        batch.push((commit?, seq));
        seen += 1;
        if batch.len() == BATCH {
            inserted += write_batch(shared, &batch, max_files, &mut paths)?;
            batch.clear();
        }
    }
    if !batch.is_empty() {
        inserted += write_batch(shared, &batch, max_files, &mut paths)?;
    }
    Ok((inserted, seen))
}

/// Numbers the walks over history, so ties in commit time keep git's order across syncs.
/// One statement, so processes syncing at once never share a number.
fn next_walk(shared: &Shared) -> Result<i64> {
    Ok(shared.writer().query_row(
        "INSERT INTO meta (key, value) VALUES ('walks', '1')
         ON CONFLICT (key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
         RETURNING CAST(value AS INTEGER)",
        [],
        |r| r.get(0),
    )?)
}

fn intern(tx: &Transaction, cache: &mut HashMap<String, i64>, path: &str) -> Result<i64> {
    if let Some(id) = cache.get(path) {
        return Ok(*id);
    }
    let found: Option<i64> = tx
        .prepare_cached("SELECT id FROM paths WHERE path = ?1")?
        .query_row([path], |r| r.get(0))
        .optional()?;
    let id = match found {
        Some(id) => id,
        None => {
            tx.prepare_cached("INSERT INTO paths (path) VALUES (?1)")?
                .execute([path])?;
            let id = tx.last_insert_rowid();
            tx.prepare_cached("INSERT INTO path_text (rowid, path) VALUES (?1, ?2)")?
                .execute(params![id, path])?;
            id
        }
    };
    cache.insert(path.to_string(), id);
    Ok(id)
}

fn write_batch(
    shared: &Shared,
    commits: &[(RawCommit, i64)],
    max_files: i64,
    cache: &mut HashMap<String, i64>,
) -> Result<usize> {
    let mut connection = shared.writer();
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut stats: HashMap<i64, PathStat> = HashMap::new();
    let mut pairs: HashMap<(i64, i64), (i64, i64)> = HashMap::new();
    let mut inserted = 0;
    let mut written: Vec<(&RawCommit, i64)> = Vec::new();
    {
        let mut insert_commit = tx.prepare_cached(
            "INSERT OR IGNORE INTO commits (sha, tree, author_name, author_email, author_time,
                 committer_name, committer_email, commit_time, subject, body, parent_count,
                 files_changed, additions, deletions, seq)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        )?;
        for (commit, seq) in commits {
            let additions: i64 = commit.files.iter().filter_map(|f| f.additions).sum();
            let deletions: i64 = commit.files.iter().filter_map(|f| f.deletions).sum();
            let changed = insert_commit.execute(params![
                commit.sha,
                commit.tree,
                commit.author_name,
                commit.author_email,
                commit.author_time,
                commit.committer_name,
                commit.committer_email,
                commit.commit_time,
                commit.subject,
                commit.body,
                commit.parents.len() as i64,
                commit.files.len() as i64,
                additions,
                deletions,
                seq,
            ])?;
            // Already indexed (by an earlier walk or another process): nothing else to add.
            if changed == 1 {
                written.push((commit, tx.last_insert_rowid()));
            }
        }
    }
    {
        let mut insert_parent = tx.prepare_cached(
            "INSERT INTO commit_parents (commit_id, position, parent_sha) VALUES (?1, ?2, ?3)",
        )?;
        let mut insert_text = tx.prepare_cached(
            "INSERT INTO commit_text (rowid, subject, body, author_name, author_email)
             VALUES (?1, ?2, ?3, ?4, ?5)",
        )?;
        let mut insert_change = tx.prepare_cached(
            "INSERT OR IGNORE INTO file_changes
                 (commit_id, path_id, status, old_path_id, similarity, additions, deletions)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )?;
        for (commit, id) in &written {
            inserted += 1;
            for (position, parent) in commit.parents.iter().enumerate() {
                insert_parent.execute(params![id, position as i64, parent])?;
            }
            insert_text.execute(params![
                id,
                commit.subject,
                commit.body,
                commit.author_name,
                commit.author_email
            ])?;
            let mut ids = Vec::with_capacity(commit.files.len());
            for file in &commit.files {
                let path = intern(&tx, cache, &file.path)?;
                let old = match &file.old_path {
                    Some(old) => Some(intern(&tx, cache, old)?),
                    None => None,
                };
                if insert_change.execute(params![
                    id,
                    path,
                    file.status.to_string(),
                    old,
                    file.similarity,
                    file.additions,
                    file.deletions
                ])? == 0
                {
                    continue;
                }
                ids.push(path);
                let stat = stats.entry(path).or_insert_with(|| PathStat {
                    first: i64::MAX,
                    last: i64::MIN,
                    ..Default::default()
                });
                stat.commits += 1;
                stat.additions += file.additions.unwrap_or(0);
                stat.deletions += file.deletions.unwrap_or(0);
                stat.first = stat.first.min(commit.commit_time);
                stat.last = stat.last.max(commit.commit_time);
            }
            ids.sort_unstable();
            ids.dedup();
            if ids.len() as i64 <= max_files {
                for path in &ids {
                    if let Some(stat) = stats.get_mut(path) {
                        stat.coupling += 1;
                    }
                }
                for (i, a) in ids.iter().enumerate() {
                    for b in &ids[i + 1..] {
                        let entry = pairs.entry((*a, *b)).or_insert((0, i64::MIN));
                        entry.0 += 1;
                        entry.1 = entry.1.max(commit.commit_time);
                    }
                }
            }
        }
    }
    flush(&tx, &stats, &pairs)?;
    tx.commit()?;
    shared
        .processed
        .fetch_add(commits.len() as u64, Ordering::SeqCst);
    Ok(inserted)
}

fn flush(
    tx: &Transaction,
    stats: &HashMap<i64, PathStat>,
    pairs: &HashMap<(i64, i64), (i64, i64)>,
) -> Result<()> {
    let mut upsert_stat = tx.prepare_cached(
        "INSERT INTO path_stats (path_id, commits, coupling_commits, additions, deletions, first_time, last_time)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT (path_id) DO UPDATE SET
             commits = commits + excluded.commits,
             coupling_commits = coupling_commits + excluded.coupling_commits,
             additions = additions + excluded.additions,
             deletions = deletions + excluded.deletions,
             first_time = min(first_time, excluded.first_time),
             last_time = max(last_time, excluded.last_time)",
    )?;
    for (path, s) in stats {
        upsert_stat.execute(params![
            path,
            s.commits,
            s.coupling,
            s.additions,
            s.deletions,
            s.first,
            s.last
        ])?;
    }
    let mut upsert_pair = tx.prepare_cached(
        "INSERT INTO cochange (a, b, commits, last_time) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (a, b) DO UPDATE SET
             commits = commits + excluded.commits,
             last_time = max(last_time, excluded.last_time)",
    )?;
    for ((a, b), (count, last)) in pairs {
        upsert_pair.execute(params![a, b, count, last])?;
    }
    Ok(())
}

/// Parents of indexed commits that are not indexed themselves: where a shallow index
/// continues.
fn boundary_parents(connection: &Connection) -> Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT DISTINCT p.parent_sha FROM commit_parents p
         WHERE NOT EXISTS (SELECT 1 FROM commits c WHERE c.sha = p.parent_sha)",
    )?;
    let rows = statement.query_map([], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Recomputes path_stats and cochange from file_changes (after pruning, or when the
/// commit size limit for change relationships changes).
pub fn rebuild_derived(tx: &Transaction, max_files: i64) -> Result<()> {
    tx.execute_batch("DELETE FROM path_stats; DELETE FROM cochange;")?;
    tx.execute(
        "INSERT INTO path_stats (path_id, commits, coupling_commits, additions, deletions, first_time, last_time)
         SELECT fc.path_id, COUNT(*),
                SUM(CASE WHEN c.files_changed <= ?1 THEN 1 ELSE 0 END),
                SUM(coalesce(fc.additions, 0)), SUM(coalesce(fc.deletions, 0)),
                MIN(c.commit_time), MAX(c.commit_time)
         FROM file_changes fc JOIN commits c ON c.id = fc.commit_id
         GROUP BY fc.path_id",
        [max_files],
    )?;
    let mut pairs: HashMap<(i64, i64), (i64, i64)> = HashMap::new();
    {
        let mut statement = tx.prepare(
            "SELECT fc.commit_id, c.commit_time, fc.path_id FROM file_changes fc
             JOIN commits c ON c.id = fc.commit_id
             WHERE c.files_changed BETWEEN 2 AND ?1
             ORDER BY fc.commit_id, fc.path_id",
        )?;
        let mut rows = statement.query([max_files])?;
        let mut current = (-1i64, 0i64);
        let mut ids: Vec<i64> = Vec::new();
        let mut add = |ids: &mut Vec<i64>, time: i64| {
            for (i, a) in ids.iter().enumerate() {
                for b in &ids[i + 1..] {
                    let entry = pairs.entry((*a, *b)).or_insert((0, i64::MIN));
                    entry.0 += 1;
                    entry.1 = entry.1.max(time);
                }
            }
            ids.clear();
        };
        while let Some(row) = rows.next()? {
            let (commit, time, path): (i64, i64, i64) = (row.get(0)?, row.get(1)?, row.get(2)?);
            if commit != current.0 {
                add(&mut ids, current.1);
                current = (commit, time);
            }
            ids.push(path);
        }
        add(&mut ids, current.1);
    }
    flush(tx, &HashMap::new(), &pairs)?;
    Ok(())
}

/// Drops commits that no indexed ref reaches any more, then rebuilds the derived tables.
pub fn prune(shared: &Shared, repo: &Repo) -> Result<Value> {
    let _serial = shared.sync_guard();
    let tips: Vec<String> = repo
        .refs()?
        .into_iter()
        .map(|(_, sha)| sha)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let reachable: HashSet<String> = if tips.is_empty() {
        HashSet::new()
    } else {
        let input = tips
            .iter()
            .flat_map(|s| format!("{s}\n").into_bytes())
            .collect();
        String::from_utf8_lossy(&repo.output_with_input(&["rev-list", "--stdin"], Some(input))?)
            .lines()
            .map(str::to_string)
            .collect()
    };
    let mut connection = shared.writer();
    let max_files = max_files(&connection)?;
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let gone: Vec<(i64, String, String, String, String)> = {
        let mut statement =
            tx.prepare("SELECT id, sha, subject, body, author_name, author_email FROM commits")?;
        let rows = statement.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })?;
        let mut gone = Vec::new();
        for row in rows {
            let (id, sha, subject, body, name, email) = row?;
            if !reachable.contains(&sha) {
                gone.push((id, subject, body, name, email));
            }
        }
        gone
    };
    {
        // External-content FTS rows are removed with the values they were indexed with.
        let mut remove_text = tx.prepare_cached(
            "INSERT INTO commit_text (commit_text, rowid, subject, body, author_name, author_email)
             VALUES ('delete', ?1, ?2, ?3, ?4, ?5)",
        )?;
        let mut remove = tx.prepare_cached("DELETE FROM commits WHERE id = ?1")?;
        for (id, subject, body, name, email) in &gone {
            remove_text.execute(params![id, subject, body, name, email])?;
            remove.execute([id])?;
        }
    }
    tx.execute(
        "DELETE FROM refs WHERE sha NOT IN (SELECT sha FROM commits)",
        [],
    )?;
    rebuild_derived(&tx, max_files)?;
    tx.commit()?;
    Ok(json!({"removedCommits": gone.len()}))
}
