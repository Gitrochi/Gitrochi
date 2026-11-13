//! Opening, creating and migrating the database, and the per-database connection cache
//! the apps use (one writer and one reader, so searches never wait for a sync).

use crate::error::{Error, Result};
use crate::text;
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const SCHEMA_VERSION: i64 = 1;
pub const DEFAULT_MAX_FILES: i64 = 30;
const SCHEMA: &str = include_str!("schema.sql");
const FTS: &str = include_str!("fts.sql");
const BUSY_TIMEOUT: Duration = Duration::from_secs(10);

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// Wait through WAL's non-blocking read-to-write lock upgrade.
fn enable_wal(connection: &Connection, path: &Path, patience: Duration) -> Result<()> {
    let deadline = Instant::now() + patience;
    let is_busy = |error: &rusqlite::Error| {
        error.sqlite_error_code() == Some(rusqlite::ErrorCode::DatabaseBusy)
    };
    let gave_up = || {
        Error::new(
            "DATABASE",
            format!(
                "Could not open {}: another process kept it locked for {} s while it was being set up",
                path.display(),
                patience.as_secs_f64()
            ),
        )
    };
    loop {
        match connection.query_row("PRAGMA journal_mode = WAL", [], |r| r.get::<_, String>(0)) {
            // Network file systems can refuse WAL; rollback mode still works.
            Ok(_) => return Ok(()),
            Err(error) if !is_busy(&error) => return Err(error.into()),
            Err(_) if Instant::now() >= deadline => return Err(gave_up()),
            // BEGIN IMMEDIATE honours busy_timeout, unlike the pragma's lock upgrade.
            Err(_) => match connection.execute_batch("BEGIN IMMEDIATE; ROLLBACK;") {
                Ok(()) => {}
                Err(error) if is_busy(&error) => return Err(gave_up()),
                Err(error) => return Err(error.into()),
            },
        }
    }
}

fn configure(connection: &Connection, path: &Path) -> Result<()> {
    connection.busy_timeout(BUSY_TIMEOUT)?;
    text::register(connection)?;
    enable_wal(connection, path, BUSY_TIMEOUT)?;
    // A database copied in with a repository is untrusted: its triggers and views may not
    // call functions with side effects (trusted_schema), and the defensive flag blocks
    // writes that could corrupt the file on purpose.
    connection.set_db_config(rusqlite::config::DbConfig::SQLITE_DBCONFIG_DEFENSIVE, true)?;
    connection.execute_batch(
        "PRAGMA trusted_schema = OFF;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;
         PRAGMA temp_store = MEMORY;
         PRAGMA cache_size = -16000;",
    )?;
    Ok(())
}

fn schema_mismatch(found: i64) -> Error {
    Error::new(
        "SCHEMA_MISMATCH",
        format!("The index has schema {found}; this build reads schema {SCHEMA_VERSION}"),
    )
}

/// Opens the database for writing, creating it (and its folder) on first use.
pub fn open(path: &Path) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            Error::new(
                "DATABASE",
                format!("Could not create {}: {e}", parent.display()),
            )
        })?;
    }
    let mut connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    configure(&connection, path)?;
    migrate(&mut connection)?;
    Ok(connection)
}

/// Opens an existing database that refuses writes.
pub fn open_reader(path: &Path) -> Result<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    configure(&connection, path)?;
    connection.execute_batch("PRAGMA query_only = ON")?;
    let version: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != SCHEMA_VERSION {
        return Err(schema_mismatch(version));
    }
    Ok(connection)
}

fn migrate(connection: &mut Connection) -> Result<()> {
    let version: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > SCHEMA_VERSION {
        return Err(schema_mismatch(version));
    }
    if version == SCHEMA_VERSION {
        return refresh_tokenizer(connection);
    }
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // Another process may have created the schema while this one waited for the lock.
    let version: i64 = tx.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version == 0 {
        tx.execute_batch(SCHEMA)?;
        tx.execute_batch(FTS)?;
        set_meta(&tx, "schema", &SCHEMA_VERSION.to_string())?;
        set_meta(&tx, "created", &now().to_string())?;
        set_meta(&tx, "tokenizer", &text::version())?;
        set_meta(&tx, "max_files", &DEFAULT_MAX_FILES.to_string())?;
        set_meta(&tx, "shallow", "0")?;
        tx.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))?;
    } else if version > SCHEMA_VERSION {
        return Err(schema_mismatch(version));
    }
    tx.commit()?;
    Ok(())
}

// Tokens change with the tokenizer version, so its tables are re-tokenized then.
fn refresh_tokenizer(connection: &mut Connection) -> Result<()> {
    let current = text::version();
    if meta(connection, "tokenizer")?.as_deref() == Some(current.as_str()) {
        return Ok(());
    }
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute("INSERT INTO commit_text(commit_text) VALUES('rebuild')", [])?;
    tx.execute("INSERT INTO path_text(path_text) VALUES('rebuild')", [])?;
    set_meta(&tx, "tokenizer", &current)?;
    tx.commit()?;
    Ok(())
}

pub fn meta(connection: &Connection, key: &str) -> Result<Option<String>> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |r| r.get(0))
        .optional()?)
}

pub fn set_meta(connection: &Connection, key: &str, value: &str) -> Result<()> {
    connection.execute(
        "INSERT INTO meta (key, value) VALUES (?1, ?2)
         ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        [key, value],
    )?;
    Ok(())
}

/// The connections of one database, shared by every caller in this process.
pub struct Shared {
    pub path: PathBuf,
    writer: Mutex<Connection>,
    reader: Mutex<Connection>,
    sync: Mutex<()>,
    pub syncing: AtomicBool,
    pub processed: AtomicU64,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panic while holding the lock leaves SQLite consistent (transactions roll back).
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Shared {
    pub fn writer(&self) -> MutexGuard<'_, Connection> {
        lock(&self.writer)
    }

    pub fn reader(&self) -> MutexGuard<'_, Connection> {
        lock(&self.reader)
    }

    /// Serializes syncs in this process; other processes rely on idempotent inserts.
    pub fn sync_guard(&self) -> MutexGuard<'_, ()> {
        lock(&self.sync)
    }
}

/// The cached connections for a database, opening (and creating) it on first use.
pub fn shared(path: &Path) -> Result<Arc<Shared>> {
    static REGISTRY: OnceLock<Mutex<HashMap<PathBuf, Arc<Shared>>>> = OnceLock::new();
    let mut registry = lock(REGISTRY.get_or_init(Default::default));
    if let Some(found) = registry.get(path) {
        return Ok(found.clone());
    }
    let writer = open(path)?;
    let reader = open_reader(path)?;
    let entry = Arc::new(Shared {
        path: path.to_path_buf(),
        writer: Mutex::new(writer),
        reader: Mutex::new(reader),
        sync: Mutex::new(()),
        syncing: AtomicBool::new(false),
        processed: AtomicU64::new(0),
    });
    registry.insert(path.to_path_buf(), entry.clone());
    Ok(entry)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Barrier;

    fn test_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gitrochi-index-{name}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn wal_setup_reports_a_persistent_lock_and_can_retry_once_free() {
        let dir = test_dir("wal-lock");
        let path = dir.join("index.sqlite3");
        let holder = Connection::open(&path).unwrap();
        holder.execute_batch("BEGIN EXCLUSIVE").unwrap();
        let opener = Connection::open(&path).unwrap();
        opener.busy_timeout(Duration::from_millis(50)).unwrap();
        let started = Instant::now();
        let error = enable_wal(&opener, &path, Duration::from_millis(200)).unwrap_err();
        assert_eq!(error.code, "DATABASE");
        assert!(error.message.contains("kept it locked for 0.2 s"));
        assert!(error.message.contains("index.sqlite3"));
        assert!(started.elapsed() < Duration::from_secs(5));
        holder.execute_batch("ROLLBACK").unwrap();
        enable_wal(&opener, &path, Duration::from_millis(200)).unwrap();
        let mode: String = opener
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        drop((holder, opener));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn concurrent_first_opens_create_one_readable_schema() {
        let dir = test_dir("wal-open");
        let path = dir.join("index.sqlite3");
        let ready = Barrier::new(8);
        std::thread::scope(|scope| {
            for _ in 0..8 {
                scope.spawn(|| {
                    ready.wait();
                    let writer = open(&path).unwrap();
                    let reader = open_reader(&path).unwrap();
                    assert_eq!(meta(&writer, "schema").unwrap(), Some("1".into()));
                    assert_eq!(meta(&reader, "schema").unwrap(), Some("1".into()));
                });
            }
        });
        std::fs::remove_dir_all(dir).unwrap();
    }
}
