//! The baseline trunk of a project: versions from git tags, from folder or file names, from
//! registration, from `release` reports, and versions first seen in a report (`inferred`).

use crate::db::Db;
use crate::error::{Error, Result};
use crate::git;
use crate::util::{self, compare_versions, now_ms, Ms};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const DEFAULT_PATTERN: &str = r"^v?(\d+(?:\.\d+)+)$";
pub const SOURCES: [&str; 3] = ["tags", "folder", "manual"];
const SCAN_INTERVAL: Duration = Duration::from_secs(15);

/// One version on the trunk (`Baseline` in CONTRACT.md).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Baseline {
    pub project: String,
    pub version: String,
    pub ts: Ms,
    /// Where it is drawn: an inferred version is kept below the next higher one.
    pub eff_ts: Ms,
    pub source: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub note: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by_session: Option<String>,
    #[serde(rename = "ref", skip_serializing_if = "Option::is_none")]
    pub ref_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
}

fn sort_and_place(rows: &mut [Baseline]) {
    rows.sort_by(|a, b| compare_versions(&a.version, &b.version));
    // Inferred versions have no trustworthy time; keep them just below the next higher one.
    let mut next: Option<Ms> = None;
    for row in rows.iter_mut().rev() {
        let mut ts = row.ts;
        if row.source == "inferred" {
            if let Some(next) = next {
                ts = ts.min(next - 1000);
            }
        }
        row.eff_ts = ts;
        next = Some(ts);
    }
}

fn from_row(row: &rusqlite::Row) -> rusqlite::Result<Baseline> {
    let ts: Ms = row.get(2)?;
    Ok(Baseline {
        project: row.get(0)?,
        version: row.get(1)?,
        ts,
        eff_ts: ts,
        source: row.get(3)?,
        note: row.get(4)?,
        by_session: row.get(5)?,
        ref_name: row.get(6)?,
        commit: row.get(7)?,
    })
}

const COLUMNS: &str = "project, version, ts, source, note, by_session, ref_name, commit_sha";

/// The trunk in ascending version order (HEAD last).
pub fn trunk(connection: &Connection, project: &str) -> Result<Vec<Baseline>> {
    let mut statement = connection.prepare_cached(&format!(
        "SELECT {COLUMNS} FROM baselines WHERE project = ?1"
    ))?;
    let mut rows = statement
        .query_map([project], from_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    sort_and_place(&mut rows);
    Ok(rows)
}

/// Every project's trunk.
pub fn trunks(connection: &Connection) -> Result<BTreeMap<String, Vec<Baseline>>> {
    let mut statement = connection.prepare(&format!("SELECT {COLUMNS} FROM baselines"))?;
    let mut out: BTreeMap<String, Vec<Baseline>> = BTreeMap::new();
    for row in statement.query_map([], from_row)? {
        let row = row?;
        out.entry(row.project.clone()).or_default().push(row);
    }
    for rows in out.values_mut() {
        sort_and_place(rows);
    }
    Ok(out)
}

pub fn head(connection: &Connection, project: &str) -> Result<Option<String>> {
    let mut statement =
        connection.prepare_cached("SELECT version FROM baselines WHERE project = ?1")?;
    let versions = statement
        .query_map([project], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(versions.into_iter().max_by(|a, b| compare_versions(a, b)))
}

/// Adds a version first seen in a report; a later scan or registration promotes it.
pub fn ensure(connection: &Connection, project: &str, version: &str, ts: Ms) -> Result<()> {
    connection.execute(
        "INSERT OR IGNORE INTO baselines (project, version, ts, source) VALUES (?1, ?2, ?3, 'inferred')",
        params![project, version, ts],
    )?;
    Ok(())
}

pub fn released_by(
    connection: &Connection,
    project: &str,
    version: &str,
) -> Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT by_session FROM baselines WHERE project = ?1 AND version = ?2",
            params![project, version],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten())
}

/// A session made this version: it becomes (or stays) a release by that session.
pub fn release(
    connection: &Connection,
    project: &str,
    version: &str,
    ts: Ms,
    note: &str,
    by_session: &str,
) -> Result<()> {
    connection.execute(
        "INSERT INTO baselines (project, version, ts, source, note, by_session)
         VALUES (?1, ?2, ?3, 'release', ?4, ?5)
         ON CONFLICT (project, version) DO UPDATE SET
           by_session = excluded.by_session,
           note = CASE WHEN baselines.note = '' THEN excluded.note ELSE baselines.note END,
           ts = CASE WHEN baselines.source = 'inferred' THEN excluded.ts ELSE baselines.ts END,
           source = CASE WHEN baselines.source = 'inferred' THEN 'release' ELSE baselines.source END",
        params![project, version, ts, note, by_session],
    )?;
    Ok(())
}

/// A version a person (or a script) registered by hand.
pub fn register(
    connection: &Connection,
    project: &str,
    version: &str,
    note: &str,
    ts: Ms,
) -> Result<()> {
    ensure_project(connection, project, ts)?;
    connection.execute(
        "INSERT INTO baselines (project, version, ts, source, note) VALUES (?1, ?2, ?3, 'registered', ?4)
         ON CONFLICT (project, version) DO UPDATE SET
           ts = CASE WHEN baselines.source = 'inferred' THEN excluded.ts ELSE baselines.ts END,
           source = CASE WHEN baselines.source = 'inferred' THEN 'registered' ELSE baselines.source END,
           note = CASE WHEN excluded.note = '' THEN baselines.note ELSE excluded.note END",
        params![project, version, ts, note],
    )?;
    Ok(())
}

// ── Projects

/// How a project finds its baselines.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectConfig {
    pub key: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo_path: Option<String>,
    pub baseline_source: String,
    pub baseline_pattern: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseline_dir: Option<String>,
    pub scan_files: bool,
    pub scan_subdirs: Vec<String>,
}

pub fn ensure_project(connection: &Connection, key: &str, now: Ms) -> Result<()> {
    connection.execute(
        "INSERT OR IGNORE INTO projects (key, name, created_at) VALUES (?1, ?1, ?2)",
        params![key, now],
    )?;
    Ok(())
}

pub fn project(connection: &Connection, key: &str) -> Result<Option<ProjectConfig>> {
    Ok(connection
        .query_row(
            "SELECT key, name, repo_path, baseline_source, baseline_pattern, baseline_dir,
                    scan_files, scan_subdirs FROM projects WHERE key = ?1",
            [key],
            |r| {
                let pattern: Option<String> = r.get(4)?;
                let subdirs: String = r.get(7)?;
                Ok(ProjectConfig {
                    key: r.get(0)?,
                    name: r.get(1)?,
                    repo_path: r.get(2)?,
                    baseline_source: r.get(3)?,
                    baseline_pattern: pattern.unwrap_or_else(|| DEFAULT_PATTERN.into()),
                    baseline_dir: r.get(5)?,
                    scan_files: r.get::<_, i64>(6)? != 0,
                    scan_subdirs: util::string_list(&subdirs),
                })
            },
        )
        .optional()?)
}

pub fn projects(connection: &Connection) -> Result<Vec<ProjectConfig>> {
    let mut statement = connection.prepare("SELECT key FROM projects ORDER BY key")?;
    let keys = statement
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut out = Vec::new();
    for key in keys {
        out.extend(project(connection, &key)?);
    }
    Ok(out)
}

fn compile(pattern: &str) -> Result<regex_lite::Regex> {
    regex_lite::Regex::new(&format!("(?i){pattern}"))
        .map_err(|e| Error::invalid(format!("Invalid baseline pattern {pattern:?}: {e}")))
}

/// Changes a project's settings (apps only). Unset fields stay as they are; `null` clears.
pub fn set_project(connection: &Connection, args: &Value, now: Ms) -> Result<ProjectConfig> {
    let key = util::arg_str(args, "project").ok_or_else(|| Error::invalid("Missing project"))?;
    ensure_project(connection, &key, now)?;
    let text = |name: &str| -> Result<Option<Option<String>>> {
        match &args[name] {
            Value::Null if args.get(name).is_some() => Ok(Some(None)),
            Value::Null => Ok(None),
            Value::String(s) => Ok(Some(util::clean(s))),
            _ => Err(Error::invalid(format!("{name} must be text"))),
        }
    };
    if let Some(name) = text("name")? {
        connection.execute(
            "UPDATE projects SET name = ?2 WHERE key = ?1",
            params![key, name.unwrap_or_else(|| key.clone())],
        )?;
    }
    if let Some(repo) = text("repoPath")? {
        connection.execute(
            "UPDATE projects SET repo_path = ?2 WHERE key = ?1",
            params![key, repo],
        )?;
    }
    if let Some(source) = text("baselineSource")? {
        let source = source.unwrap_or_else(|| "tags".into());
        if !SOURCES.contains(&source.as_str()) {
            return Err(Error::invalid(
                "baselineSource must be tags, folder or manual",
            ));
        }
        connection.execute(
            "UPDATE projects SET baseline_source = ?2 WHERE key = ?1",
            params![key, source],
        )?;
    }
    if let Some(pattern) = text("baselinePattern")? {
        if let Some(pattern) = &pattern {
            compile(pattern)?;
        }
        connection.execute(
            "UPDATE projects SET baseline_pattern = ?2 WHERE key = ?1",
            params![key, pattern],
        )?;
    }
    if let Some(dir) = text("baselineDir")? {
        connection.execute(
            "UPDATE projects SET baseline_dir = ?2 WHERE key = ?1",
            params![key, dir],
        )?;
    }
    if let Some(files) = util::arg_bool(args, "scanFiles") {
        connection.execute(
            "UPDATE projects SET scan_files = ?2 WHERE key = ?1",
            params![key, files as i64],
        )?;
    }
    if args.get("scanSubdirs").is_some() {
        let subdirs = util::arg_list(args, "scanSubdirs");
        connection.execute(
            "UPDATE projects SET scan_subdirs = ?2 WHERE key = ?1",
            params![key, util::json_text(&subdirs)],
        )?;
    }
    project(connection, &key)?.ok_or_else(|| Error::not_found(format!("No project {key}")))
}

// ── Scanning

/// A version found by a scan, with where it came from.
#[derive(Clone, Debug, PartialEq)]
pub struct Found {
    pub version: String,
    pub ts: Ms,
    pub source: &'static str,
    pub ref_name: String,
    pub commit: Option<String>,
}

fn version_in(regex: &regex_lite::Regex, name: &str) -> Option<String> {
    let captures = regex.captures(name)?;
    // The first group when the pattern has one, else the whole match.
    let text = captures.get(1).or_else(|| captures.get(0))?.as_str();
    util::parse_version(text).filter(|v| v != "latest")
}

fn keep_earliest(found: &mut HashMap<String, Found>, candidate: Found) {
    match found.get(&candidate.version) {
        Some(existing) if existing.ts <= candidate.ts => {}
        _ => {
            found.insert(candidate.version.clone(), candidate);
        }
    }
}

/// Tags of the bound repository that match the pattern.
pub fn scan_tags(repo: &Path, pattern: &str) -> Result<Vec<Found>> {
    let regex = compile(pattern)?;
    let mut found = HashMap::new();
    for tag in git::tags(repo)? {
        let name = util::nfc_text(&tag.name);
        if let Some(version) = version_in(&regex, &name) {
            keep_earliest(
                &mut found,
                Found {
                    version,
                    ts: tag.time * 1000,
                    source: "tag",
                    ref_name: tag.name,
                    commit: Some(tag.commit),
                },
            );
        }
    }
    Ok(sorted(found))
}

/// The newest version among the tags reachable from the checkout at `dir` that match the
/// pattern: the baseline work started there builds on. `None` when no tag matches.
pub fn newest_reachable(dir: &Path, pattern: &str) -> Result<Option<String>> {
    let regex = compile(pattern)?;
    Ok(git::reachable_tags(dir)?
        .iter()
        .filter_map(|tag| version_in(&regex, &util::nfc_text(&tag.name)))
        .max_by(|a, b| compare_versions(a, b)))
}

fn system_ms(time: std::io::Result<SystemTime>) -> Option<Ms> {
    time.ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_millis() as Ms)
}

/// Folder names (and file names with `files`) directly under `dir` and the listed
/// sub-folders; not recursive. The time is the earlier of created and modified, because a
/// copied file is created after it was last modified.
pub fn scan_folder(
    dir: &Path,
    subdirs: &[String],
    files: bool,
    pattern: &str,
) -> Result<Vec<Found>> {
    let regex = compile(pattern)?;
    let mut found = HashMap::new();
    let mut bases = vec![dir.to_path_buf()];
    bases.extend(subdirs.iter().map(|s| dir.join(s)));
    for base in bases {
        let Ok(entries) = std::fs::read_dir(&base) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if !(meta.is_dir() || (files && meta.is_file())) {
                continue;
            }
            let name = util::nfc_text(&entry.file_name().to_string_lossy());
            let Some(version) = version_in(&regex, &name) else {
                continue;
            };
            let modified = system_ms(meta.modified());
            let created = system_ms(meta.created());
            let ts = match (created, modified) {
                (Some(c), Some(m)) => c.min(m),
                (Some(t), None) | (None, Some(t)) => t,
                (None, None) => now_ms(),
            };
            keep_earliest(
                &mut found,
                Found {
                    version,
                    ts,
                    source: "folder",
                    ref_name: name,
                    commit: None,
                },
            );
        }
    }
    Ok(sorted(found))
}

fn sorted(found: HashMap<String, Found>) -> Vec<Found> {
    let mut out: Vec<Found> = found.into_values().collect();
    out.sort_by(|a, b| compare_versions(&a.version, &b.version));
    out
}

/// What one project's scan found and added.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
    pub project: String,
    pub source: String,
    pub found: usize,
    pub added: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

fn throttle(db: &Db, project: &str) -> bool {
    static LAST: OnceLock<Mutex<HashMap<(PathBuf, String), Instant>>> = OnceLock::new();
    let mut last = LAST
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    let key = (db.path.clone(), project.to_string());
    if last.get(&key).is_some_and(|t| t.elapsed() < SCAN_INTERVAL) {
        return true;
    }
    last.insert(key, Instant::now());
    false
}

/// Reads the project's baseline source and records new versions (or promotes inferred
/// ones). Throttled to once per 15 s per project unless forced; a failure is reported in
/// the result and never stops the caller's work. Writes only when something is new.
pub fn refresh(db: &Db, project: &str, force: bool) -> Result<ScanResult> {
    let config = db.read(|c| self::project(c, project))?;
    let mut result = ScanResult {
        project: project.to_string(),
        source: config
            .as_ref()
            .map_or("tags".into(), |c| c.baseline_source.clone()),
        found: 0,
        added: 0,
        error: None,
    };
    let Some(config) = config else {
        return Ok(result);
    };
    if !force && throttle(db, project) {
        return Ok(result);
    }
    let scanned = match config.baseline_source.as_str() {
        "tags" => match &config.repo_path {
            Some(repo) => scan_tags(Path::new(repo), &config.baseline_pattern),
            None => Ok(Vec::new()),
        },
        "folder" => match &config.baseline_dir {
            Some(dir) => scan_folder(
                Path::new(dir),
                &config.scan_subdirs,
                config.scan_files,
                &config.baseline_pattern,
            ),
            None => Ok(Vec::new()),
        },
        _ => Ok(Vec::new()),
    };
    let found = match scanned {
        Ok(found) => found,
        Err(error) => {
            result.error = Some(error.message);
            return Ok(result);
        }
    };
    result.found = found.len();
    let existing: HashMap<String, String> = db.read(|c| {
        let mut statement =
            c.prepare("SELECT version, source FROM baselines WHERE project = ?1")?;
        let rows = statement.query_map([project], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<HashMap<_, _>>>()?)
    })?;
    let todo: Vec<Found> = found
        .into_iter()
        .filter(|f| existing.get(&f.version).is_none_or(|s| s == "inferred"))
        .collect();
    if todo.is_empty() {
        return Ok(result);
    }
    let (added, _) = db.write(|c| {
        let mut added = 0;
        for f in &todo {
            added += c.execute(
                "INSERT INTO baselines (project, version, ts, source, ref_name, commit_sha)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT (project, version) DO UPDATE SET
                   ts = excluded.ts, source = excluded.source,
                   ref_name = excluded.ref_name, commit_sha = excluded.commit_sha
                 WHERE baselines.source = 'inferred'",
                params![project, f.version, f.ts, f.source, f.ref_name, f.commit],
            )?;
        }
        Ok(added)
    })?;
    result.added = added;
    Ok(result)
}

pub fn baseline_json(baseline: &Baseline) -> Value {
    serde_json::to_value(baseline).unwrap_or_else(|_| json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(version: &str, ts: Ms, source: &str) -> Baseline {
        Baseline {
            project: "p".into(),
            version: version.into(),
            ts,
            eff_ts: ts,
            source: source.into(),
            note: String::new(),
            by_session: None,
            ref_name: None,
            commit: None,
        }
    }

    #[test]
    fn inferred_versions_are_placed_below_the_next() {
        let mut rows = vec![
            b("1.0.5", 1_000_000, "registered"),
            b("1.0.1", 5_000_000, "inferred"),
            b("1.0.0", 10, "tag"),
        ];
        sort_and_place(&mut rows);
        let order: Vec<_> = rows.iter().map(|r| r.version.as_str()).collect();
        assert_eq!(order, ["1.0.0", "1.0.1", "1.0.5"]);
        assert_eq!(rows[1].eff_ts, 999_000);
        assert_eq!(rows[0].eff_ts, 10);
        assert_eq!(rows[2].eff_ts, 1_000_000);
    }

    #[test]
    fn patterns_take_the_group_or_the_match() {
        let default = compile(DEFAULT_PATTERN).unwrap();
        assert_eq!(version_in(&default, "v1.4.2").as_deref(), Some("1.4.2"));
        assert_eq!(version_in(&default, "V2.0").as_deref(), Some("2.0"));
        assert_eq!(version_in(&default, "v1.4.2-rc.1"), None);
        assert_eq!(version_in(&default, "backup_old"), None);
        let whole = compile(r"Example \d+\.\d+\.\d+$").unwrap();
        assert_eq!(
            version_in(&whole, "Release Example 2.5.107").as_deref(),
            Some("2.5.107")
        );
        let files = compile(r"^SPEC_v(\d+(?:\.\d+)+)\.md$").unwrap();
        assert_eq!(
            version_in(&files, "SPEC_v2.5.110.md").as_deref(),
            Some("2.5.110")
        );
        assert_eq!(version_in(&files, "REF_SPEC_v2.5.120.md"), None);
        assert!(compile("(").is_err());
    }
}
