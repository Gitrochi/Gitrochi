//! Where the database lives, opening and migrating it, and the one write path: every write
//! is a single `BEGIN IMMEDIATE` transaction that also bumps `meta.rev`, so the apps can
//! poll one number and redraw only when something changed.

use crate::error::{Error, Result};
use crate::util::now_ms;
use rusqlite::{Connection, OpenFlags, TransactionBehavior};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

/// The newest schema this build writes (`PRAGMA user_version`).
pub const DB_SCHEMA: i64 = 1;

/// Writers wait this long for another process's transaction before giving up.
pub const BUSY_TIMEOUT: Duration = Duration::from_secs(15);

const READER_POOL: usize = 4;

// Additive steps only: a later schema adds tables and columns and never edits a shipped step.
const MIGRATIONS: [(i64, &str); 1] = [(1, include_str!("schema.sql"))];

/// The database file: `GITROCHI_LEDGER_DB` when set, else one file per user next to the
/// apps' other data, so the apps, the CLI, MCP and the hooks all agree on it.
pub fn default_db_path() -> PathBuf {
    if let Some(path) = std::env::var_os("GITROCHI_LEDGER_DB").filter(|v| !v.is_empty()) {
        return PathBuf::from(path);
    }
    data_dir().join("ledger").join("ledger.sqlite3")
}

fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

fn data_dir() -> PathBuf {
    let home = || env_dir("HOME").unwrap_or_else(|| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        home()
            .join("Library")
            .join("Application Support")
            .join("Gitrochi")
    } else if cfg!(windows) {
        env_dir("APPDATA")
            .unwrap_or_else(|| env_dir("USERPROFILE").unwrap_or_else(home))
            .join("Gitrochi")
    } else {
        env_dir("XDG_DATA_HOME")
            .unwrap_or_else(|| home().join(".local").join("share"))
            .join("gitrochi")
    }
}

/// `GITROCHI_LEDGER=0` turns the feature off in the apps, the hooks and the binary.
pub fn enabled() -> bool {
    !matches!(std::env::var("GITROCHI_LEDGER"), Ok(v) if v.trim() == "0")
}

fn is_busy(error: &rusqlite::Error) -> bool {
    error.sqlite_error_code() == Some(rusqlite::ErrorCode::DatabaseBusy)
}

/// Switches the file to WAL. Only the first open of a new file changes anything, and
/// SQLite does it by turning the read lock the pragma holds into a write lock — an upgrade
/// it never waits for, so that two connections doing the same cannot deadlock. When the
/// app, a hook and an agent open a new file at once, all but one of them get SQLITE_BUSY
/// immediately, whatever the busy timeout. They wait for the one switching with BEGIN
/// IMMEDIATE, which does honour the timeout, and ask again: by then the file is in WAL mode
/// and the pragma needs no lock.
fn enable_wal(connection: &Connection) -> Result<()> {
    let deadline = Instant::now() + BUSY_TIMEOUT;
    loop {
        match connection.query_row("PRAGMA journal_mode = WAL", [], |r| r.get::<_, String>(0)) {
            // Network file systems can refuse WAL; the ledger then keeps working in rollback mode.
            Ok(_) => return Ok(()),
            Err(error) if is_busy(&error) && Instant::now() < deadline => {
                connection.execute_batch("BEGIN IMMEDIATE; ROLLBACK;")?;
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn configure(connection: &Connection) -> Result<()> {
    connection.busy_timeout(BUSY_TIMEOUT)?;
    enable_wal(connection)?;
    connection.execute_batch(
        "PRAGMA trusted_schema = OFF;
         PRAGMA synchronous = NORMAL;
         PRAGMA temp_store = MEMORY;",
    )?;
    Ok(())
}

fn open_connection(path: &Path) -> Result<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| {
        Error::new(
            "DATABASE",
            format!("Could not open {}: {e}", path.display()),
        )
    })?;
    configure(&connection)?;
    Ok(connection)
}

fn user_version(connection: &Connection) -> Result<i64> {
    Ok(connection.query_row("PRAGMA user_version", [], |r| r.get(0))?)
}

/// Applies the steps newer than the file's `user_version`, each in its own IMMEDIATE
/// transaction. Two processes opening a new file at once queue on the lock; the second
/// finds the work done. Every step is written to be harmless when run twice.
pub fn migrate(connection: &mut Connection) -> Result<i64> {
    let mut version = user_version(connection)?;
    for (number, sql) in MIGRATIONS {
        if version >= number {
            continue;
        }
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = user_version(&tx)?;
        if current < number {
            tx.execute_batch(sql)?;
            tx.execute_batch(&format!("PRAGMA user_version = {number}"))?;
            tx.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('created', ?1)",
                [now_ms().to_string()],
            )?;
        }
        tx.commit()?;
        version = current.max(number);
    }
    Ok(version)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panic while holding the lock leaves SQLite consistent (transactions roll back).
    mutex.lock().unwrap_or_else(|p| p.into_inner())
}

/// One database: a writer connection and a few readers, shared by every caller in the
/// process, so reads never queue behind a write in this process.
pub struct Db {
    pub path: PathBuf,
    writer: Mutex<Connection>,
    readers: Mutex<Vec<Connection>>,
    /// Set when the file was written by a newer build: reads still work, writes refuse.
    newer_schema: Option<i64>,
}

impl Db {
    pub fn open(path: &Path) -> Result<Db> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|e| {
                Error::new(
                    "DATABASE",
                    format!("Could not create {}: {e}", parent.display()),
                )
            })?;
        }
        let mut writer = open_connection(path)?;
        let version = migrate(&mut writer)?;
        Ok(Db {
            path: path.to_path_buf(),
            writer: Mutex::new(writer),
            readers: Mutex::new(Vec::new()),
            newer_schema: (version > DB_SCHEMA).then_some(version),
        })
    }

    /// Runs `body` in one read transaction, so every query sees the same snapshot.
    pub fn read<T>(&self, body: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let pooled = lock(&self.readers).pop();
        let connection = match pooled {
            Some(connection) => connection,
            None => {
                let connection = open_connection(&self.path)?;
                connection.execute_batch("PRAGMA query_only = ON")?;
                connection
            }
        };
        let result = (|| {
            let tx = connection.unchecked_transaction()?;
            let value = body(&tx)?;
            tx.commit()?;
            Ok(value)
        })();
        let mut readers = lock(&self.readers);
        if readers.len() < READER_POOL {
            readers.push(connection);
        }
        result
    }

    /// The only way to change the ledger: `body` runs inside `BEGIN IMMEDIATE`, then
    /// `meta.rev` goes up by one and everything commits together. Returns the new rev.
    pub fn write<T>(&self, body: impl FnOnce(&Connection) -> Result<T>) -> Result<(T, i64)> {
        if let Some(found) = self.newer_schema {
            return Err(Error::new(
                "SCHEMA_MISMATCH",
                format!("The ledger has schema {found}; this build writes schema {DB_SCHEMA}"),
            ));
        }
        let mut connection = lock(&self.writer);
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let value = body(&tx)?;
        let rev: i64 = tx.query_row(
            "UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'rev'
             RETURNING CAST(value AS INTEGER)",
            [],
            |r| r.get(0),
        )?;
        tx.commit()?;
        Ok((value, rev))
    }

    pub fn rev(&self) -> Result<i64> {
        self.read(rev)
    }
}

pub fn rev(connection: &Connection) -> Result<i64> {
    Ok(connection.query_row(
        "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'rev'",
        [],
        |r| r.get(0),
    )?)
}

/// The shared connections for a database file, opening (and creating) it on first use.
pub fn shared(path: &Path) -> Result<Arc<Db>> {
    static REGISTRY: OnceLock<Mutex<HashMap<PathBuf, Arc<Db>>>> = OnceLock::new();
    let mut registry = lock(REGISTRY.get_or_init(Default::default));
    if let Some(found) = registry.get(path) {
        return Ok(found.clone());
    }
    let db = Arc::new(Db::open(path)?);
    registry.insert(path.to_path_buf(), db.clone());
    Ok(db)
}
