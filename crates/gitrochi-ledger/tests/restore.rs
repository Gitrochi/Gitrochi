//! Restoring a backup: checked read-only first, a safety copy of the current ledger kept,
//! the backup copied in with the online backup so open connections stay consistent.
mod common;

use common::{app, cli, json_of, stderr, stdout, Schemas, TempDir};
use gitrochi_ledger::{backup, call_as, Caller};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn start(db: &Path, session: &str, title: &str) {
    app(
        db,
        "report",
        json!({"event":"start","project":"Example App","session":session,"title":title,"summary":"Started"}),
    );
}

fn session_ids(db: &Path) -> Vec<String> {
    let state = app(db, "state", json!({"range":"all"}));
    let mut ids: Vec<String> = state["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap().to_string())
        .collect();
    ids.sort();
    ids
}

fn error_of(db: &Path, caller: Caller, method: &str, mut args: Value) -> (String, String) {
    args["db"] = json!(db);
    let error = call_as(caller, method, &args).unwrap_err();
    (error.code.to_string(), error.message)
}

/// A ledger with one session and a backup of it, then a second session after the backup.
fn ledger_with_backup(temp: &TempDir) -> (PathBuf, PathBuf) {
    let db = temp.join("ledger.sqlite3");
    start(&db, "kept-session", "Before the backup");
    let made = app(&db, "backup", json!({}));
    start(&db, "later-session", "After the backup");
    (db, PathBuf::from(made["path"].as_str().unwrap()))
}

#[test]
fn a_restore_keeps_a_safety_copy_and_brings_the_backup_back() {
    let temp = TempDir::new("restore");
    let (db, file) = ledger_with_backup(&temp);
    // a connection opened before the restore, as another app or agent would hold
    let other = rusqlite::Connection::open(&db).unwrap();
    let count = |c: &rusqlite::Connection| -> i64 {
        c.query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))
            .unwrap()
    };
    assert_eq!(count(&other), 2);
    let rev_before = app(&db, "rev", json!({}))["rev"].as_i64().unwrap();

    let result = app(&db, "restore", json!({"path": file}));
    Schemas::load().check("restore.schema.json", &result);
    assert_eq!(result["ok"], true);
    assert_eq!(result["dryRun"], false);
    assert_eq!(result["contents"]["sessions"], 1);
    let rev = result["rev"].as_i64().unwrap();
    assert!(rev > rev_before, "{rev} after {rev_before}");
    assert_eq!(app(&db, "rev", json!({}))["rev"].as_i64().unwrap(), rev);

    // the same process's pooled connections and the other connection read the backup
    assert_eq!(session_ids(&db), vec!["kept-session"]);
    assert_eq!(count(&other), 1);

    // the safety copy holds the ledger as it was, and is listed as one
    let safety = PathBuf::from(result["safety"]["path"].as_str().unwrap());
    assert!(safety
        .file_name()
        .unwrap()
        .to_string_lossy()
        .starts_with("ledger-before-restore-"));
    let kept = backup::inspect(&safety).unwrap();
    assert_eq!(kept.1.sessions, 2);
    drop(kept);
    let listed = app(&db, "backups", json!({}));
    Schemas::load().check("backups.schema.json", &listed);
    let kinds: Vec<(&str, &str)> = listed["backups"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| (b["name"].as_str().unwrap(), b["kind"].as_str().unwrap()))
        .collect();
    assert_eq!(kinds.len(), 2, "{listed}");
    assert!(kinds.iter().any(|(_, kind)| *kind == "safety"));
    assert!(kinds.iter().any(|(_, kind)| *kind == "backup"));
    // retention never counts the safety copy, and the backup itself was not written
    assert_eq!(backup::list(&db).len(), 1);
    assert_eq!(backup::inspect(&file).unwrap().1.sessions, 1);

    // writing goes on as usual, and restoring the safety copy undoes the restore
    start(&db, "after-restore", "Written to the restored ledger");
    let undone = app(&db, "restore", json!({"path": safety}));
    assert!(undone["rev"].as_i64().unwrap() > rev);
    assert_eq!(session_ids(&db), vec!["kept-session", "later-session"]);
    // no working copies are left, and the backups were only read (no WAL files beside them)
    for entry in std::fs::read_dir(backup::directory(&db)).unwrap() {
        let name = entry.unwrap().file_name().to_string_lossy().into_owned();
        assert!(
            name.ends_with(".sqlite3") && !name.contains(".tmp"),
            "{name}"
        );
    }
}

#[test]
fn a_dry_run_checks_without_writing_anything() {
    let temp = TempDir::new("restore-dry");
    let (db, file) = ledger_with_backup(&temp);
    let rev = app(&db, "rev", json!({}))["rev"].clone();
    let result = app(&db, "restore", json!({"path": file, "dryRun": true}));
    Schemas::load().check("restore.schema.json", &result);
    assert_eq!(result["dryRun"], true);
    assert!(result.get("safety").is_none());
    assert_eq!(result["contents"]["schema"], 8);
    assert_eq!(result["rev"], rev);
    assert_eq!(app(&db, "rev", json!({}))["rev"], rev);
    assert_eq!(session_ids(&db).len(), 2);
    assert_eq!(
        app(&db, "backups", json!({}))["backups"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn damaged_foreign_newer_and_live_files_are_refused_before_anything_changes() {
    let temp = TempDir::new("restore-refused");
    let (db, file) = ledger_with_backup(&temp);
    let rev = app(&db, "rev", json!({}))["rev"].clone();

    let garbage = temp.join("garbage.sqlite3");
    std::fs::write(&garbage, b"not a database at all, just some text").unwrap();
    let (code, _) = error_of(&db, Caller::App, "restore", json!({"path": garbage}));
    assert_eq!(code, "INVALID_ARGUMENT");

    let foreign = temp.join("foreign.sqlite3");
    rusqlite::Connection::open(&foreign)
        .unwrap()
        .execute_batch("CREATE TABLE notes (body TEXT); PRAGMA user_version = 3;")
        .unwrap();
    let (code, message) = error_of(&db, Caller::App, "restore", json!({"path": foreign}));
    assert_eq!(code, "INVALID_ARGUMENT");
    assert!(message.contains("not a Ledger backup"), "{message}");

    let damaged = temp.join("damaged.sqlite3");
    std::fs::copy(&file, &damaged).unwrap();
    let mut bytes = std::fs::read(&damaged).unwrap();
    let page = 4096;
    assert!(bytes.len() > 3 * page);
    for byte in &mut bytes[2 * page + 8..3 * page] {
        *byte = 0xA5;
    }
    std::fs::write(&damaged, bytes).unwrap();
    let (code, _) = error_of(&db, Caller::App, "restore", json!({"path": damaged}));
    assert_eq!(code, "INVALID_ARGUMENT");

    let newer = temp.join("newer.sqlite3");
    std::fs::copy(&file, &newer).unwrap();
    rusqlite::Connection::open(&newer)
        .unwrap()
        .execute_batch("PRAGMA user_version = 99;")
        .unwrap();
    let (code, message) = error_of(&db, Caller::App, "restore", json!({"path": newer}));
    assert_eq!(code, "SCHEMA_MISMATCH");
    assert!(message.contains("newer Gitrochi"), "{message}");

    let (code, _) = error_of(&db, Caller::App, "restore", json!({"path": db}));
    assert_eq!(code, "INVALID_ARGUMENT");
    let (code, _) = error_of(
        &db,
        Caller::App,
        "restore",
        json!({"path": temp.join("missing.sqlite3")}),
    );
    assert_eq!(code, "INVALID_ARGUMENT");
    let (code, _) = error_of(&db, Caller::App, "restore", json!({}));
    assert_eq!(code, "INVALID_ARGUMENT");

    // agents may list backups but never restore one
    let (code, _) = error_of(&db, Caller::Agent, "restore", json!({"path": file}));
    assert_eq!(code, "NOT_ALLOWED");
    let mut args = json!({"db": db});
    args["db"] = json!(db);
    assert!(call_as(Caller::Agent, "backups", &args).is_ok());

    assert_eq!(app(&db, "rev", json!({}))["rev"], rev);
    assert_eq!(session_ids(&db).len(), 2);
    assert_eq!(
        app(&db, "backups", json!({}))["backups"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn an_older_schema_is_migrated_as_it_is_restored() {
    let temp = TempDir::new("restore-older");
    let (db, file) = ledger_with_backup(&temp);
    let older = temp.join("older.sqlite3");
    std::fs::copy(&file, &older).unwrap();
    rusqlite::Connection::open(&older)
        .unwrap()
        .execute_batch(
            "DROP TRIGGER browser_session_insert; DROP TRIGGER browser_session_delete;
             DROP TABLE browser_captures; DROP TABLE browser_session_generations;
             PRAGMA user_version = 7;",
        )
        .unwrap();
    let result = app(&db, "restore", json!({"path": older}));
    assert_eq!(result["contents"]["schema"], 7);
    let live = rusqlite::Connection::open(&db).unwrap();
    let version: i64 = live
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 8);
    let generations: i64 = live
        .query_row(
            "SELECT COUNT(*) FROM browser_session_generations",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(generations, 1);
    // and the restored ledger takes reports as before
    start(&db, "next-session", "After an older restore");
    assert_eq!(session_ids(&db), vec!["kept-session", "next-session"]);
}

#[test]
fn the_command_line_checks_first_and_restores_with_yes() {
    let temp = TempDir::new("restore-cli");
    let (db, file) = ledger_with_backup(&temp);
    let file_arg = file.to_string_lossy().into_owned();

    let checked = cli(&db, &["restore", &file_arg]);
    assert!(checked.status.success(), "{}", stderr(&checked));
    assert!(
        stdout(&checked).contains("Run again with --yes"),
        "{}",
        stdout(&checked)
    );
    assert_eq!(session_ids(&db).len(), 2);

    let restored = cli(&db, &["--json", "restore", &file_arg, "--yes"]);
    assert!(restored.status.success(), "{}", stderr(&restored));
    let result = json_of(&restored);
    Schemas::load().check("restore.schema.json", &result);
    assert!(Path::new(result["safety"]["path"].as_str().unwrap()).is_file());
    assert_eq!(session_ids(&db), vec!["kept-session"]);

    let missing = cli(&db, &["restore"]);
    assert_eq!(missing.status.code(), Some(2), "{}", stderr(&missing));
}
