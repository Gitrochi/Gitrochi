//! Sharing with the team hub (`hub_share`, DESIGN.md §14 D4): only live, non-stream sessions
//! with a repository remote are shared, each with the allowed fields only. Everything a
//! person or an agent wrote — questions, answers, report bodies, messages, notes — and
//! every folder path, chat link and credential stays on this computer.

mod common;

use common::{app, Schemas, TempDir};
use gitrochi_ledger::Caller;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;

fn git(dir: &Path, args: &[&str]) {
    let home = dir.join(".home");
    std::fs::create_dir_all(&home).unwrap();
    let output = Command::new("git")
        .current_dir(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", home.join("gitconfig"))
        .env("HOME", &home)
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn keys(value: &Value) -> BTreeSet<String> {
    value.as_object().unwrap().keys().cloned().collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

const CLIENT: &str = "a1b2c3d4e5f6";

#[test]
fn only_live_sessions_with_a_remote_are_shared_and_only_their_allowed_fields() {
    let dir = TempDir::new("hub-share");
    let db = dir.join("ledger.sqlite3");
    let repo = dir.join("harbor");
    std::fs::create_dir_all(repo.join("sub")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    // a remote URL with credentials in it: the key must leave them out
    git(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            "https://fixture:s3cret-token@example.com/team/harbor.git",
        ],
    );
    let repo_path = repo.to_string_lossy().into_owned();
    app(
        &db,
        "project_set",
        json!({"project": "harbor", "repoPath": repo_path}),
    );
    let report = |args: Value| app(&db, "report", args);

    // the shared one, with everything that must not be shared attached to it
    report(
        json!({"event": "start", "project": "harbor", "session": "S1103-01", "kind": "research",
        "title": "Retry\npolicy", "summary": "SECRET-SUMMARY", "body": "SECRET-BODY",
        "chatUrl": "https://chat.example.com/c/SECRET-CHAT",
        "touches": ["src/retry.rs", "/Users/me/notes.md", "REQ-12", "../outside.txt", "C:\\Users\\me\\x", "https://example.com/doc"]}),
    );
    let asked =
        report(json!({"event": "question", "session": "S1103-01", "question": "SECRET-QUESTION?"}));
    let question = asked["questionIds"][0].as_i64().unwrap();
    app(
        &db,
        "human",
        json!({"action": "answer", "sessionId": "S1103-01", "questionId": question, "answer": "SECRET-ANSWER"}),
    );
    report(json!({"event": "question", "session": "S1103-01", "question": "SECRET-OPEN?"}));
    app(
        &db,
        "human",
        json!({"action": "message", "sessionId": "S1103-01", "text": "SECRET-MESSAGE"}),
    );
    app(
        &db,
        "human",
        json!({"action": "link", "sessionId": "S1103-01", "branch": "feature/retry",
            "cwd": repo.join("sub").to_string_lossy(), "agentId": "agent-SECRET"}),
    );
    app(
        &db,
        "notebook",
        json!({"action": "save", "title": "SECRET-NOTE", "body": "SECRET-NOTE-BODY"}),
    );
    // done but not merged: still live, so still shared
    report(
        json!({"event": "start", "project": "harbor", "session": "S1103-06", "kind": "decision", "title": "Cache"}),
    );
    report(json!({"event": "done", "session": "S1103-06"}));
    // a stream, a closed session and an archived one: never shared
    report(
        json!({"event": "start", "project": "harbor", "session": "S1103-02", "kind": "implementation", "title": "Stream", "touches": ["src/retry.rs"]}),
    );
    report(
        json!({"event": "start", "project": "harbor", "session": "S1103-03", "kind": "research", "title": "Closed"}),
    );
    report(json!({"event": "closed", "session": "S1103-03"}));
    report(
        json!({"event": "start", "project": "harbor", "session": "S1103-04", "kind": "research", "title": "Archived"}),
    );
    app(
        &db,
        "human",
        json!({"action": "archive", "sessionId": "S1103-04"}),
    );
    // a project without a repository: live, but there is no remote to share it under
    report(
        json!({"event": "start", "project": "elsewhere", "session": "S1103-05", "kind": "research", "title": "Nowhere"}),
    );

    let result = app(&db, "hub_share", json!({"client": CLIENT}));
    Schemas::load().check("hub-share.schema.json", &result);
    let shared: BTreeSet<String> = result["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["sessionId"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(shared, set(&["S1103-01", "S1103-06"]));
    assert_eq!(
        result["unshared"],
        json!([{"sessionId": "S1103-05", "reason": "no_remote"}])
    );

    let item = result["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == "S1103-01")
        .unwrap();
    assert_eq!(item["repo"], "example.com/team/harbor");
    assert_eq!(item["client"], format!("ledger/{CLIENT}/S1103-01"));
    let presence = &item["presence"];
    assert_eq!(
        keys(presence),
        set(&["repo", "branch", "changed", "related", "client", "ledger"])
    );
    assert_eq!(
        keys(&presence["ledger"]),
        set(&[
            "session",
            "project",
            "title",
            "kind",
            "role",
            "verdict",
            "lastActivity"
        ])
    );
    assert_eq!(presence["repo"], "example.com/team/harbor");
    assert_eq!(presence["client"], item["client"]);
    assert_eq!(presence["branch"], "feature/retry");
    assert_eq!(presence["changed"], json!(["src/retry.rs", "REQ-12"]));
    assert_eq!(presence["related"], json!([]));
    let ledger = &presence["ledger"];
    assert_eq!(ledger["session"], "S1103-01");
    assert_eq!(ledger["project"], "harbor");
    assert_eq!(ledger["title"], "Retry policy", "one line");
    assert_eq!(ledger["kind"], "research");
    assert_eq!(ledger["role"], "research");
    assert_eq!(ledger["verdict"], "needs_human");
    assert!(ledger["lastActivity"].as_str().unwrap().ends_with(":00Z"));
    let done = result["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == "S1103-06")
        .unwrap();
    assert_eq!(done["presence"]["ledger"]["verdict"], "pending_merge");
    assert_eq!(done["presence"]["branch"], "");

    // nothing written by a person or an agent, and no path or credential, is in the result
    let text = result.to_string();
    for secret in [
        "SECRET",
        "s3cret",
        "fixture:",
        "chat.example.com",
        "/Users/me",
        "outside.txt",
        "agent-",
        &repo_path,
    ] {
        assert!(!text.contains(secret), "{secret} leaked: {text}");
    }

    // reading for sharing never changes the ledger
    let rev = app(&db, "rev", json!({}))["rev"].clone();
    app(&db, "hub_share", json!({"client": CLIENT}));
    assert_eq!(app(&db, "rev", json!({}))["rev"], rev);
    assert_eq!(result["rev"], rev);
}

#[test]
fn sharing_is_for_the_apps_only_and_needs_a_client_name() {
    let dir = TempDir::new("hub-share-callers");
    let db = dir.join("ledger.sqlite3");
    let args = json!({"db": db.to_string_lossy(), "client": CLIENT});
    let refused = gitrochi_ledger::call_as(Caller::Agent, "hub_share", &args).unwrap_err();
    assert_eq!(refused.code, "NOT_ALLOWED");
    for client in [
        json!(null),
        json!("abc"),
        json!("has space"),
        json!("a/b/c/d"),
    ] {
        let mut args = json!({"db": db.to_string_lossy()});
        args["client"] = client.clone();
        let answer = gitrochi_ledger::call("hub_share", &args);
        assert_eq!(answer["error"]["code"], "INVALID_ARGUMENT", "{client}");
    }
    let empty = app(&db, "hub_share", json!({"client": CLIENT}));
    assert_eq!(empty["sessions"], json!([]));
    assert_eq!(empty["unshared"], json!([]));
}
