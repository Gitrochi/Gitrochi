//! Simultaneous app, CLI and bridge snapshots never share a temporary file.
mod common;

use common::{app, binary, json_of, TempDir};
use gitrochi_ledger::{backup, util::now_ms, Db};
use serde_json::json;
use std::sync::{Arc, Barrier};

#[test]
fn simultaneous_threads_publish_complete_snapshots_and_clean_temporary_files() {
    let temp = TempDir::new("backups-together");
    let path = temp.join("ledger.db");
    app(
        &path,
        "report",
        json!({"event":"start","project":"Example App","session":"backup-session","title":"Snapshot test","summary":"Started"}),
    );
    let db = Arc::new(Db::open(&path).unwrap());
    let barrier = Arc::new(Barrier::new(8));
    let now = now_ms();
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let db = db.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                backup::run(&db, now, 14, false).unwrap()
            })
        })
        .collect();
    for handle in handles {
        assert!(handle.join().unwrap().size > 0);
    }
    let files = backup::list(&path);
    assert_eq!(files.len(), 1);
    let snapshot = rusqlite::Connection::open(&files[0]).unwrap();
    assert_eq!(
        snapshot
            .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(
        snapshot
            .query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert!(std::fs::read_dir(backup::directory(&path))
        .unwrap()
        .all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")));
}

#[test]
fn simultaneous_cli_processes_share_daily_snapshots_safely() {
    let temp = TempDir::new("backup-processes");
    let path = temp.join("ledger.db");
    app(
        &path,
        "report",
        json!({"event":"start","project":"Example App","session":"backup-session","title":"Snapshot test","summary":"Started"}),
    );
    let children: Vec<_> = (0..4)
        .map(|_| {
            binary()
                .arg("--db")
                .arg(&path)
                .args(["--json", "backup", "--daily"])
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    for child in children {
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(json_of(&output)["size"].as_u64().unwrap() > 0);
    }
    assert_eq!(backup::list(&path).len(), 1);
}
