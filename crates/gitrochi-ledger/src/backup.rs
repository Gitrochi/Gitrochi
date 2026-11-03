//! Copies of the database made with SQLite's online backup, safe while other processes
//! write. They sit in `backups/` next to the database as `<name>-YYYYMMDD-HHMM.sqlite3`;
//! only files with exactly that shape are ever removed. Restoring one first keeps the
//! current database as `<name>-before-restore-YYYYMMDD-HHMMSS.sqlite3`, which retention
//! never removes, then copies the backup in with the same online backup.

use crate::db::{self, Db};
use crate::error::{Error, Result};
use crate::util::Ms;
use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, UNIX_EPOCH};

static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(0);

struct Temporary(PathBuf);

impl Drop for Temporary {
    fn drop(&mut self) {
        // a restore's working copy may have been opened in WAL mode
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let mut name = self.0.clone().into_os_string();
            name.push(suffix);
            let _ = std::fs::remove_file(name);
        }
    }
}

fn temporary(directory: &Path, name: &str, stamp: &str) -> Result<Temporary> {
    // App, bridge and CLI backups can run together, including several in this process.
    for _ in 0..100 {
        let unique = NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed);
        let path = directory.join(format!(
            ".{name}-{stamp}-{}-{unique}.sqlite3.tmp",
            std::process::id()
        ));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(_) => return Ok(Temporary(path)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(Error::new("DATABASE", format!("Backup failed: {error}"))),
        }
    }
    Err(Error::new(
        "DATABASE",
        "Could not allocate a temporary backup file",
    ))
}

pub fn directory(db_path: &Path) -> PathBuf {
    db_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
        .join("backups")
}

fn stem(db_path: &Path) -> String {
    db_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "ledger".into())
}

/// `<stem>-YYYYMMDD-HHMM.sqlite3`, nothing else.
fn is_backup_name(name: &str, stem: &str) -> bool {
    let Some(rest) = name
        .strip_prefix(stem)
        .and_then(|r| r.strip_prefix('-'))
        .and_then(|r| r.strip_suffix(".sqlite3"))
    else {
        return false;
    };
    let bytes = rest.as_bytes();
    bytes.len() == 13
        && bytes[8] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(i, b)| i == 8 || b.is_ascii_digit())
}

const SAFETY: &str = "before-restore";

/// `<stem>-before-restore-YYYYMMDD-HHMMSS.sqlite3`, or with `-N` when a second restore
/// came in the same second.
fn is_safety_name(name: &str, stem: &str) -> bool {
    let Some(rest) = name
        .strip_prefix(stem)
        .and_then(|r| r.strip_prefix('-'))
        .and_then(|r| r.strip_prefix(SAFETY))
        .and_then(|r| r.strip_prefix('-'))
        .and_then(|r| r.strip_suffix(".sqlite3"))
    else {
        return false;
    };
    let (stamp, count) = match rest.split_at_checked(15) {
        Some((stamp, "")) => (stamp, None),
        Some((stamp, count)) => (stamp, Some(count)),
        None => return false,
    };
    let bytes = stamp.as_bytes();
    bytes[8] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(i, b)| i == 8 || b.is_ascii_digit())
        && count.is_none_or(|c| {
            c.strip_prefix('-')
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        })
}

/// The backups of this database, oldest first (the names sort by time).
pub fn list(db_path: &Path) -> Vec<PathBuf> {
    let stem = stem(db_path);
    let mut out: Vec<PathBuf> = std::fs::read_dir(directory(db_path))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| is_backup_name(&e.file_name().to_string_lossy(), &stem))
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

fn local_stamp(connection: &Connection, now: Ms, format: &str) -> Result<String> {
    Ok(connection.query_row(
        "SELECT strftime(?2, ?1 / 1000, 'unixepoch', 'localtime')",
        rusqlite::params![now, format],
        |r| r.get(0),
    )?)
}

/// Whether today (local time) has no backup yet; the apps call this before a daily backup.
pub fn due(db: &Db, now: Ms) -> Result<bool> {
    let today = db.read(|c| local_stamp(c, now, "%Y%m%d"))?;
    let prefix = format!("{}-{today}-", stem(&db.path));
    Ok(!list(&db.path).iter().any(|p| {
        p.file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with(&prefix))
    }))
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupResult {
    pub path: String,
    pub created: bool,
    pub size: u64,
    pub removed: Vec<String>,
}

/// A consistent copy of the database under a temporary name in `dir`.
fn snapshot(db_path: &Path, dir: &Path, stamp: &str) -> Result<Temporary> {
    let temporary = temporary(dir, &stem(db_path), stamp)?;
    let source = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    source.busy_timeout(crate::db::BUSY_TIMEOUT)?;
    let mut target = Connection::open(&temporary.0)?;
    let backup = Backup::new(&source, &mut target)?;
    // All pages in one step: one consistent snapshot even while others write.
    backup.run_to_completion(i32::MAX, Duration::ZERO, None)?;
    drop(backup);
    Ok(temporary)
}

/// Writes a backup (under a temporary name, then renamed) and keeps the newest `keep`.
/// With `daily`, does nothing when today already has one.
pub fn run(db: &Db, now: Ms, keep: u32, daily: bool) -> Result<BackupResult> {
    let io = |e: std::io::Error| Error::new("DATABASE", format!("Backup failed: {e}"));
    if daily && !due(db, now)? {
        let latest = list(&db.path).pop().unwrap_or_default();
        return Ok(BackupResult {
            size: std::fs::metadata(&latest).map(|m| m.len()).unwrap_or(0),
            path: latest.to_string_lossy().into_owned(),
            created: false,
            removed: Vec::new(),
        });
    }
    let dir = directory(&db.path);
    std::fs::create_dir_all(&dir).map_err(io)?;
    let stamp = db.read(|c| local_stamp(c, now, "%Y%m%d-%H%M"))?;
    let path = dir.join(format!("{}-{stamp}.sqlite3", stem(&db.path)));
    let temporary = snapshot(&db.path, &dir, &stamp)?;
    std::fs::rename(&temporary.0, &path).map_err(io)?;
    let mut removed = Vec::new();
    let all = list(&db.path);
    let excess = all.len().saturating_sub(keep.max(1) as usize);
    for old in all.into_iter().take(excess) {
        if std::fs::remove_file(&old).is_ok() {
            removed.push(
                old.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned(),
            );
        }
    }
    Ok(BackupResult {
        size: std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
        path: path.to_string_lossy().into_owned(),
        created: true,
        removed,
    })
}

/// One file the apps offer to restore: a backup, or a copy kept before a restore.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub path: String,
    pub name: String,
    pub size: u64,
    /// When the file was written, from the file system.
    pub modified_at: Ms,
    /// `backup` (daily or Back up now) or `safety` (the database as it was before a restore).
    pub kind: &'static str,
}

/// Every backup and safety copy of this database, newest first.
pub fn snapshots(db_path: &Path) -> Vec<Snapshot> {
    let stem = stem(db_path);
    let mut out: Vec<Snapshot> = std::fs::read_dir(directory(db_path))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let kind = if is_backup_name(&name, &stem) {
                "backup"
            } else if is_safety_name(&name, &stem) {
                "safety"
            } else {
                return None;
            };
            let meta = entry.metadata().ok().filter(|m| m.is_file())?;
            let modified_at = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as Ms)
                .unwrap_or(0);
            Some(Snapshot {
                path: entry.path().to_string_lossy().into_owned(),
                name,
                size: meta.len(),
                modified_at,
                kind,
            })
        })
        .collect();
    out.sort_by(|a, b| {
        b.modified_at
            .cmp(&a.modified_at)
            .then_with(|| b.name.cmp(&a.name))
    });
    out
}

/// What a backup holds, read without writing to it.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Contents {
    /// Its storage schema (`PRAGMA user_version`).
    pub schema: i64,
    /// Its `meta.rev` when it was taken.
    pub rev: i64,
    pub sessions: i64,
    pub events: i64,
}

/// The result of `restore`.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreResult {
    pub ok: bool,
    /// Checked only: nothing was copied and no safety copy was taken.
    pub dry_run: bool,
    /// The backup, as given.
    pub path: String,
    pub contents: Contents,
    /// The database as it was just before the restore; absent for a dry run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub safety: Option<BackupResult>,
    /// The ledger's rev afterwards: above both the backup's and the one it replaced, so
    /// every client that polls it reads again.
    pub rev: i64,
}

fn not_a_backup(path: &Path, why: impl std::fmt::Display) -> Error {
    Error::invalid(format!("{} is not a Ledger backup ({why})", path.display()))
}

/// Opens a backup read-only and checks it: SQLite's integrity check, a Ledger database,
/// and no newer schema than this build writes.
pub fn inspect(path: &Path) -> Result<(Connection, Contents)> {
    let connection = crate::legacy::open(path)?;
    let integrity: Vec<String> = (|| -> rusqlite::Result<Vec<String>> {
        let mut statement = connection.prepare("PRAGMA integrity_check(5)")?;
        let rows = statement.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect()
    })()
    .map_err(|e| not_a_backup(path, e))?;
    if integrity.first().map(String::as_str) != Some("ok") {
        return Err(Error::invalid(format!(
            "{} is damaged and cannot be restored: {}",
            path.display(),
            integrity.join("; ")
        )));
    }
    let schema: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if schema > db::DB_SCHEMA {
        return Err(Error::new(
            "SCHEMA_MISMATCH",
            format!(
                "{} was written by a newer Gitrochi (schema {schema}; this build writes schema {})",
                path.display(),
                db::DB_SCHEMA
            ),
        ));
    }
    if schema < 1 {
        return Err(not_a_backup(path, "it has no Ledger schema"));
    }
    let rev: i64 = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'rev'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| not_a_backup(path, e))?;
    let count = |table: &str| -> Result<i64> {
        connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .map_err(|e| not_a_backup(path, e))
    };
    let contents = Contents {
        schema,
        rev,
        sessions: count("sessions")?,
        events: count("events")?,
    };
    Ok((connection, contents))
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// A name for the safety copy that no other file has.
fn safety_path(dir: &Path, stem: &str, stamp: &str) -> PathBuf {
    let base = format!("{stem}-{SAFETY}-{stamp}");
    let mut path = dir.join(format!("{base}.sqlite3"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{base}-{n}.sqlite3"));
        n += 1;
    }
    path
}

/// Copies `source` into the live database with the online backup API: one write
/// transaction, so every other connection sees the old ledger or the new one, never a mix,
/// and SQLite raises the schema cookie so they read the schema again.
fn copy_into_live(source: &Connection, db_path: &Path) -> Result<()> {
    let mut live = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    live.busy_timeout(db::BUSY_TIMEOUT)?;
    let backup = Backup::new(source, &mut live)?;
    let deadline = Instant::now() + db::BUSY_TIMEOUT;
    loop {
        match backup.step(-1)? {
            StepResult::Done => return Ok(()),
            StepResult::More => continue,
            // another writer kept the lock past the busy timeout
            _ if Instant::now() >= deadline => {
                return Err(Error::new(
                    "DATABASE",
                    "The ledger stayed busy, so the backup was not restored; try again",
                ))
            }
            _ => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

/// Replaces the ledger with a backup. The backup is opened read-only and checked first;
/// then a safety copy of the current database is kept next to the backups, and the backup
/// (migrated to this build's schema) is copied in with SQLite's online backup, so the apps,
/// agents and hooks that have the database open keep working and read the restored ledger.
/// Reports written between the safety copy and the copy are in neither.
pub fn restore(db: &Db, path: &Path, now: Ms, dry_run: bool) -> Result<RestoreResult> {
    let io = |e: std::io::Error| Error::new("DATABASE", format!("Restore failed: {e}"));
    if same_file(path, &db.path) {
        return Err(Error::invalid(
            "That is the ledger's own database; choose a backup",
        ));
    }
    let (source, contents) = inspect(path)?;
    db.ensure_writable()?;
    if dry_run {
        return Ok(RestoreResult {
            ok: true,
            dry_run: true,
            path: path.to_string_lossy().into_owned(),
            contents,
            safety: None,
            rev: db.rev()?,
        });
    }
    let dir = directory(&db.path);
    std::fs::create_dir_all(&dir).map_err(io)?;
    let stem = stem(&db.path);
    // A private working copy: the backup itself is never written, and a schema older than
    // this build's is migrated before anyone can see it.
    let working = temporary(&dir, &stem, "restore")?;
    let mut copy = Connection::open(&working.0)?;
    Backup::new(&source, &mut copy)?.run_to_completion(i32::MAX, Duration::ZERO, None)?;
    drop(source);
    copy.busy_timeout(db::BUSY_TIMEOUT)?;
    db::migrate(&mut copy)?;

    let stamp = db.read(|c| local_stamp(c, now, "%Y%m%d-%H%M%S"))?;
    let kept = snapshot(&db.path, &dir, &stamp)?;
    let safety = safety_path(&dir, &stem, &stamp);
    std::fs::rename(&kept.0, &safety).map_err(io)?;
    let safety = BackupResult {
        size: std::fs::metadata(&safety).map(|m| m.len()).unwrap_or(0),
        path: safety.to_string_lossy().into_owned(),
        created: true,
        removed: Vec::new(),
    };

    let rev = db.rev()?.max(contents.rev) + 1;
    copy.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'rev'",
        [rev.to_string()],
    )?;
    copy_into_live(&copy, &db.path)?;
    drop(copy);
    drop(working);
    Ok(RestoreResult {
        ok: true,
        dry_run: false,
        path: path.to_string_lossy().into_owned(),
        contents,
        safety: Some(safety),
        rev: db.rev()?,
    })
}

#[cfg(test)]
mod tests {
    use super::{is_backup_name, is_safety_name};

    #[test]
    fn only_the_safety_shape_counts_as_a_safety_copy() {
        let stem = "ledger";
        assert!(is_safety_name(
            "ledger-before-restore-20261103-142501.sqlite3",
            stem
        ));
        assert!(is_safety_name(
            "ledger-before-restore-20261103-142501-2.sqlite3",
            stem
        ));
        for name in [
            "ledger-before-restore-20261103-1425.sqlite3",
            "ledger-before-restore-20261103-142501-.sqlite3",
            "ledger-before-restore-20261103-142501-x.sqlite3",
            "other-before-restore-20261103-142501.sqlite3",
            "ledger-20261103-1425.sqlite3",
        ] {
            assert!(!is_safety_name(name, stem), "{name}");
        }
        // retention and the daily check never take a safety copy for a backup
        assert!(!is_backup_name(
            "ledger-before-restore-20261103-142501.sqlite3",
            stem
        ));
    }

    #[test]
    fn only_the_backup_shape_counts() {
        assert!(is_backup_name("ledger-20261026-0930.sqlite3", "ledger"));
        assert!(!is_backup_name("ledger-2026102-0930.sqlite3", "ledger"));
        assert!(!is_backup_name("ledger-old.sqlite3", "ledger"));
        assert!(!is_backup_name("notes.txt", "ledger"));
        assert!(!is_backup_name("other-20261026-0930.sqlite3", "ledger"));
        assert!(!is_backup_name(
            "ledger-20261026-0930.sqlite3-wal",
            "ledger"
        ));
        assert!(!is_backup_name("ledger-2026102a-0930.sqlite3", "ledger"));
    }
}
