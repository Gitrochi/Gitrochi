//! Passive local-client hooks, run as real processes on isolated databases.

mod common;

use common::{app, binary, json_of, stderr, stdout, Schemas, TempDir};
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;
use std::process::{Output, Stdio};

fn observe(db: &Path, client: &str, event: &str, input: Value, issued: Option<&str>) -> Output {
    let mut command = binary();
    command
        .args(["--db", db.to_str().unwrap(), "observe", client, event])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(issued) = issued {
        command.env("GITROCHI_LEDGER_SESSION", issued);
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.to_string().as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn sessions(db: &Path) -> Vec<Value> {
    app(db, "state", json!({"range": "all"}))["sessions"]
        .as_array()
        .unwrap()
        .clone()
}

#[test]
fn both_clients_bind_resume_record_metadata_and_leave_reporting_semantics_alone() {
    for client in ["claude", "codex"] {
        let dir = TempDir::new(client);
        let db = dir.join("ledger.sqlite3");
        let cwd = dir.join("harbor");
        std::fs::create_dir_all(&cwd).unwrap();
        app(&db, "info", json!({}));
        app(
            &db,
            "settings_set",
            json!({"values": {"autoContinue": {"enabled": true, "delaySec": 30}}}),
        );
        let input = json!({
            "session_id": "client-session-01", "cwd": cwd, "source": "startup",
            "prompt": "PRIVATE_PROMPT_SENTINEL", "transcript_path": "PRIVATE_TRANSCRIPT_SENTINEL",
            "last_assistant_message": "PRIVATE_OUTPUT_SENTINEL",
            "tool_input": {"command": "PRIVATE_ARGUMENT_SENTINEL"}
        });
        let first = observe(&db, client, "SessionStart", input.clone(), None);
        assert!(first.status.success(), "{}", stderr(&first));
        let context = json_of(&first);
        assert!(context["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap()
            .contains("ledger_report"));
        assert!(context.get("decision").is_none());
        let rows = sessions(&db);
        assert_eq!(rows.len(), 1);
        Schemas::load().check("session.schema.json", &rows[0]);
        let id = rows[0]["id"].as_str().unwrap().to_owned();
        assert!(stdout(&first).contains(&id));
        assert_eq!(rows[0]["kind"], "other");
        assert_eq!(rows[0]["status"], "active");
        assert!(rows[0]["lastAgentAt"].is_null());
        assert_eq!(rows[0]["autoContinue"]["enabled"], false);
        let mut resume = input.clone();
        resume["source"] = json!("resume");
        let resumed = observe(&db, client, "SessionStart", resume, None);
        assert!(resumed.status.success());
        assert!(stdout(&resumed).contains(&id));
        assert_eq!(sessions(&db).len(), 1);
        let tool = json!({
            "session_id": "client-session-01", "cwd": cwd, "tool_name": "Edit",
            "tool_use_id": "tool-1", "turn_id": "turn-1",
            "tool_input": {"file_path": "PRIVATE_FILE_SENTINEL", "new_string": "PRIVATE_ARGUMENT_SENTINEL"},
            "tool_response": "PRIVATE_RESULT_SENTINEL"
        });
        let output = observe(&db, client, "PostToolUse", tool.clone(), None);
        assert!(output.status.success());
        assert!(stdout(&output).is_empty());
        let before = app(&db, "session", json!({"id": id}))["events"]
            .as_array()
            .unwrap()
            .len();
        observe(&db, client, "PostToolUse", tool, None);
        assert_eq!(
            app(&db, "session", json!({"id": id}))["events"]
                .as_array()
                .unwrap()
                .len(),
            before
        );
        let stopped = observe(&db, client, "Stop", input.clone(), None);
        assert!(stopped.status.success() && stdout(&stopped).is_empty());
        let ended = observe(&db, client, "SessionEnd", input, None);
        assert!(ended.status.success() && stdout(&ended).is_empty());
        let detail = app(&db, "session", json!({"id": id}));
        assert_eq!(detail["session"]["status"], "active");
        assert!(detail["session"]["lastAgentAt"].is_null());
        assert!(detail.to_string().contains("Tool finished"));
        for secret in [
            "PRIVATE_PROMPT",
            "PRIVATE_TRANSCRIPT",
            "PRIVATE_OUTPUT",
            "PRIVATE_ARGUMENT",
            "PRIVATE_FILE",
            "PRIVATE_RESULT",
        ] {
            assert!(!detail.to_string().contains(secret), "{secret} was stored");
        }
        let launch = detail["events"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["data"]["hook"] == "launch")
            .unwrap();
        assert_eq!(launch["data"]["source"], "external");
        assert_ne!(launch["summary"], "Started from Gitrochi");
        assert_eq!(
            app(&db, "state", json!({"range": "all"}))["attention"]["total"],
            0
        );
        assert!(app(&db, "state", json!({"range": "all"}))["pendingPrompts"]
            .as_array()
            .unwrap()
            .is_empty());
        app(
            &db,
            "report",
            json!({"session": id, "project": "harbor", "event": "start", "kind": "research", "title": "Real report"}),
        );
        assert!(!sessions(&db)[0]["lastAgentAt"].is_null());
        observe(
            &db,
            client,
            "PostToolUse",
            json!({
                "session_id": "client-session-01", "tool_name": "Read", "cwd": cwd
            }),
            None,
        );
        let after_report = sessions(&db);
        assert_eq!(after_report.len(), 1);
        assert_eq!(after_report[0]["title"], "Real report");
        assert_eq!(after_report[0]["kind"], "research");
    }
}

#[test]
fn concurrent_first_hooks_create_one_session_and_providers_do_not_collide() {
    let dir = TempDir::new("concurrent-observers");
    let db = dir.join("ledger.sqlite3");
    let cwd = dir.join("harbor");
    std::fs::create_dir_all(&cwd).unwrap();
    app(&db, "info", json!({}));
    let workers: Vec<_> = (0..6)
        .map(|_| {
            let db = db.clone();
            let cwd = cwd.clone();
            std::thread::spawn(move || {
                observe(
                    &db,
                    "claude",
                    "SessionStart",
                    json!({"session_id": "same-id", "cwd": cwd}),
                    None,
                )
            })
        })
        .collect();
    for worker in workers {
        assert!(worker.join().unwrap().status.success());
    }
    assert_eq!(sessions(&db).len(), 1);
    observe(
        &db,
        "codex",
        "SessionStart",
        json!({"session_id": "same-id", "cwd": cwd}),
        None,
    );
    assert_eq!(sessions(&db).len(), 2);
}

#[test]
fn app_tracked_row_keeps_its_kind_policy_and_report_state() {
    let dir = TempDir::new("reuse-launch");
    let db = dir.join("ledger.sqlite3");
    let cwd = dir.join("harbor");
    std::fs::create_dir_all(&cwd).unwrap();
    let tracked = app(
        &db,
        "track",
        json!({
            "project": "harbor", "cwd": cwd, "kind": "implementation",
            "autoContinue": {"enabled": true, "delaySec": 90}
        }),
    );
    let id = tracked["session"]["id"].as_str().unwrap();
    observe(
        &db,
        "claude",
        "SessionStart",
        json!({"session_id": "real-claude-id", "cwd": cwd}),
        Some(id),
    );
    let rows = sessions(&db);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"], id);
    assert_eq!(rows[0]["kind"], "implementation");
    assert_eq!(rows[0]["autoContinue"]["enabled"], true);
    assert_eq!(rows[0]["autoContinue"]["delaySec"], 90);
    assert!(rows[0]["lastAgentAt"].is_null());
    observe(
        &db,
        "claude",
        "PostToolUse",
        json!({"session_id": "real-claude-id", "tool_name": "Read"}),
        None,
    );
    assert_eq!(sessions(&db).len(), 1);
}

#[test]
fn bad_missing_disabled_and_nonpassive_hooks_never_block_or_create_data() {
    let dir = TempDir::new("observer-fail-open");
    let db = dir.join("missing.sqlite3");
    for (client, event, input) in [
        ("claude", "SessionStart", json!({})),
        ("codex", "Stop", json!({"session_id": "safe"})),
        ("unknown", "SessionStart", json!({})),
        ("claude", "PermissionRequest", json!({"session_id": "safe"})),
    ] {
        let output = observe(&db, client, event, input, None);
        assert!(output.status.success());
        assert!(stdout(&output).is_empty());
    }
    assert!(!db.exists());
    let result = gitrochi_ledger::external::run(
        gitrochi_ledger::external::Client::Claude,
        "SessionStart",
        "invalid",
        &gitrochi_ledger::external::ObserverEnv {
            db,
            session: None,
            enabled: false,
        },
    );
    assert_eq!(result.code, 0);
    assert!(result.stdout.is_empty() && result.stderr.is_empty());
}
