//! Copies of the database made with SQLite's online backup, safe while other processes
//! write. They sit in `backups/` next to the database as `<name>-YYYYMMDD-HHMM.sqlite3`;
//! only files with exactly that shape are ever removed.

use crate::db::Db;
use crate::error::{Error, Result};
use crate::util::Ms;
use rusqlite::backup::Backup;
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::path::{Path, PathBuf};

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
    let temporary = dir.join(format!(".{}-{stamp}.sqlite3.tmp", stem(&db.path)));
    let _ = std::fs::remove_file(&temporary);
    {
        let source = Connection::open_with_flags(
            &db.path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        source.busy_timeout(crate::db::BUSY_TIMEOUT)?;
        let mut target = Connection::open(&temporary)?;
        let backup = Backup::new(&source, &mut target)?;
        // All pages in one step: one consistent snapshot even while others write.
        backup.run_to_completion(i32::MAX, std::time::Duration::ZERO, None)?;
    }
    std::fs::rename(&temporary, &path).map_err(io)?;
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

#[cfg(test)]
mod tests {
    use super::is_backup_name;

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
