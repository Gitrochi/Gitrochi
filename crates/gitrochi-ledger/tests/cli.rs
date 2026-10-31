//! The `gitrochi-ledger` command line, run as a real process.

mod common;

use common::{app, binary, cli, json_of, stderr, stdout, TempDir};
use serde_json::json;

#[test]
fn reports_reads_and_delivery_from_the_command_line() {
    let dir = TempDir::new("cli");
    let db = dir.join("ledger.sqlite3");
    app(
        &db,
        "register_baseline",
        json!({"project": "Example App", "version": "1.0.0"}),
    );
    app(
        &db,
        "register_baseline",
        json!({"project": "Example App", "version": "1.0.3"}),
    );

    let output = cli(
        &db,
        &[
            "report",
            "-p",
            "Example App",
            "-e",
            "start",
            "-k",
            "구현",
            "-t",
            "CLI session",
            "-b",
            "1.0.0",
            "-m",
            "started",
            "-a",
            "table@1.0.0#r1",
            "--touches",
            "src/a.rs,src/b.rs",
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    assert!(text.starts_with("Recorded ✓ S"), "{text}");
    assert!(text.contains("New session ID: S"));
    assert!(text.contains("1 baseline(s) behind HEAD 1.0.3"));
    let id = text.split_whitespace().nth(2).unwrap().to_string();

    let body = dir.join("body.md");
    std::fs::write(&body, "## Check\n| a | b |\n|---|---|\n| 1 | 2 |\n").unwrap();
    let output = cli(
        &db,
        &[
            "--json",
            "report",
            "-s",
            &id,
            "-m",
            "checked",
            "--body-file",
            body.to_str().unwrap(),
            "--ask",
            "Fix it?",
            "--ask",
            "Add a note?",
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let reply = json_of(&output);
    assert_eq!(reply["questionIds"].as_array().unwrap().len(), 2);
    assert_eq!(reply["session"]["verdict"], "needs_human");
    let detail = app(&db, "session", json!({"id": id}));
    let event = detail["events"].as_array().unwrap().last().unwrap().clone();
    assert!(event["body"].as_str().unwrap().starts_with("## Check"));
    let first = &detail["events"][0];
    assert_eq!(
        first["artifacts"][0],
        json!({"name": "table", "ssot": "1.0.0", "ver": "r1"})
    );
    assert_eq!(detail["session"]["kind"], "implementation");

    let output = cli(&db, &["overview", "-p", "Example App"]);
    assert!(output.status.success());
    assert!(
        stdout(&output).contains("Streams (ongoing implementation, not for clean-up)"),
        "{}",
        stdout(&output)
    );

    // A person answers in the app; reading the session does not consume it.
    let question = reply["questionIds"][0].as_i64().unwrap();
    app(
        &db,
        "human",
        json!({"action": "answer", "questionId": question, "answer": "Yes"}),
    );
    let output = cli(&db, &["session", &id]);
    assert!(output.status.success());
    assert!(!stdout(&output).contains("From a person"));
    let output = cli(&db, &["session", &id, "--deliver"]);
    assert!(
        stdout(&output).contains("[Answer to question #"),
        "{}",
        stdout(&output)
    );
    let output = cli(&db, &["session", &id, "--deliver"]);
    assert!(!stdout(&output).contains("From a person"), "delivered once");

    // GITROCHI_LEDGER_SESSION is the default session.
    let output = binary()
        .env("GITROCHI_LEDGER_SESSION", &id)
        .args([
            "--db",
            db.to_str().unwrap(),
            "--json",
            "report",
            "-e",
            "note",
            "-m",
            "from the environment",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(json_of(&output)["sessionId"], id.as_str());
}

#[test]
fn import_scan_register_backup_and_call() {
    let dir = TempDir::new("cli-misc");
    let db = dir.join("ledger.sqlite3");
    let pasted = dir.join("chat.txt");
    std::fs::write(
        &pasted,
        "answer text\n```ledger\n{\"project\":\"Docs Site\",\"session\":\"web-55\",\"event\":\"start\",\"title\":\"links\"}\n```\n```ledger\n{\"session\":\"web-55\",\"event\":\"done\"}\n```\n",
    )
    .unwrap();
    let output = cli(&db, &["import", pasted.to_str().unwrap()]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).starts_with("Imported 2 block(s): 2 recorded · 0 duplicate · 0 failed"));
    let output = binary()
        .args(["--db", db.to_str().unwrap(), "import", "-"])
        .stdin(std::fs::File::open(&pasted).unwrap())
        .output()
        .unwrap();
    assert!(
        stdout(&output).starts_with("Imported 2 block(s): 0 recorded · 2 duplicate"),
        "{}",
        stdout(&output)
    );

    let output = cli(
        &db,
        &["register", "2.1", "-p", "Docs Site", "--note", "published"],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output).trim(), "Registered Docs Site 2.1");
    let output = cli(&db, &["scan"]);
    assert!(output.status.success());
    assert!(
        stdout(&output).contains("Docs Site: 0 found, 0 added (tags)"),
        "{}",
        stdout(&output)
    );

    let output = cli(&db, &["backup"]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).starts_with("Backed up ✓ "));
    let output = cli(&db, &["backup", "--daily"]);
    assert!(stdout(&output).starts_with("Today's backup already exists"));
    let output = cli(&db, &["backup", "--list"]);
    assert_eq!(stdout(&output).lines().count(), 1);

    let output = cli(&db, &["call", "info"]);
    let info = json_of(&output);
    assert_eq!(
        (info["enabled"].clone(), info["schemaVersion"].clone()),
        (json!(true), json!(1))
    );
    let output = cli(&db, &["call", "state", "{\"range\": \"all\"}"]);
    assert_eq!(json_of(&output)["sessions"][0]["id"], "web-55");
    // The command line is an agent: a person's operations are refused.
    let output = cli(
        &db,
        &[
            "call",
            "human",
            "{\"action\": \"ack\", \"sessionId\": \"web-55\"}",
        ],
    );
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(json_of(&output)["error"]["code"], "NOT_ALLOWED");
    assert!(app(&db, "session", json!({"id": "web-55"}))["session"]["ackAt"].is_null());
    let output = cli(
        &db,
        &["call", "settings_set", "{\"values\": {\"staleHours\": 1}}"],
    );
    assert_eq!(json_of(&output)["error"]["code"], "NOT_ALLOWED");
}

#[test]
fn usage_errors_and_the_off_switch() {
    let dir = TempDir::new("cli-errors");
    let db = dir.join("ledger.sqlite3");
    let output = cli(&db, &["--help"]);
    assert!(output.status.success());
    assert!(stdout(&output).starts_with("gitrochi-ledger [--db FILE]"));
    let output = cli(&db, &["frobnicate"]);
    assert_eq!(output.status.code(), Some(2));
    let output = cli(&db, &["report", "-p", "P", "-e", "frobnicate"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(stderr(&output).contains("Unknown event 'frobnicate'"));
    let output = cli(&db, &["report", "--title"]);
    assert_eq!(output.status.code(), Some(2));
    let output = cli(&db, &["--json", "report", "-s", "web-1", "-e", "note"]);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(json_of(&output)["error"]["code"], "INVALID_ARGUMENT");
    let off = dir.join("off.sqlite3");
    let output = binary()
        .env("GITROCHI_LEDGER", "0")
        .args([
            "--db",
            off.to_str().unwrap(),
            "report",
            "-p",
            "P",
            "-e",
            "start",
            "-t",
            "x",
        ])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("turned off"));
    let output = binary()
        .env("GITROCHI_LEDGER", "0")
        .args(["--db", off.to_str().unwrap(), "call", "info"])
        .output()
        .unwrap();
    assert_eq!(json_of(&output)["enabled"], false);
    assert!(!off.exists(), "nothing is created while the ledger is off");
}

#[test]
fn the_default_database_is_in_the_per_user_data_folder() {
    let dir = TempDir::new("cli-default");
    // HOME, APPDATA and XDG_DATA_HOME all point here, so no real ledger is touched.
    let info = || {
        let mut command = binary();
        command
            .env("HOME", &dir.0)
            .env("APPDATA", &dir.0)
            .env("XDG_DATA_HOME", &dir.0)
            .args(["call", "info"]);
        command
    };
    let output = info().output().unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    let data = if cfg!(target_os = "macos") {
        dir.join("Library")
            .join("Application Support")
            .join("Gitrochi")
    } else if cfg!(windows) {
        dir.join("Gitrochi")
    } else {
        dir.join("gitrochi")
    };
    let db = data.join("ledger").join("ledger.sqlite3");
    assert_eq!(json_of(&output)["dbPath"], db.to_str().unwrap());
    assert!(db.is_file(), "the folders are created on first use");
    let moved = dir.join("moved.sqlite3");
    let output = info().env("GITROCHI_LEDGER_DB", &moved).output().unwrap();
    assert_eq!(json_of(&output)["dbPath"], moved.to_str().unwrap());
}

#[test]
fn demo_writes_a_fresh_database_only() {
    let dir = TempDir::new("cli-demo");
    let target = dir.join("demo.sqlite3");
    let output = binary()
        .args(["demo", target.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).contains(": 2 projects, "));
    let output = binary()
        .args(["demo", target.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(2),
        "an existing file is not overwritten"
    );
    let output = binary()
        .args(["demo", target.to_str().unwrap(), "--force"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let state = app(&target, "state", json!({"range": "all"}));
    assert_eq!(state["projects"].as_array().unwrap().len(), 2);
}
