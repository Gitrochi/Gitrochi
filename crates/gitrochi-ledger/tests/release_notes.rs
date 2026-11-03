//! Release notes: a draft for one baseline from the sessions merged into it or absorbed by
//! its release, with nothing a person wrote privately.
mod common;

use common::{app, cli, json_of, stderr, stdout, Schemas, TempDir};
use gitrochi_ledger::{call_as, Caller};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const PROJECT: &str = "Example App";

fn report(db: &Path, fields: Value) -> Value {
    let mut fields = fields;
    fields["project"] = json!(PROJECT);
    app(db, "report", fields)
}

/// A trunk 1.4.1 → 1.4.2 with sessions of every role merged into 1.4.2 in each way, one
/// merged into 1.4.1, and private text that must never reach the draft.
fn ledger(temp: &TempDir) -> PathBuf {
    let db = temp.join("ledger.sqlite3");
    app(
        &db,
        "register_baseline",
        json!({"project": PROJECT, "version": "1.4.1"}),
    );
    let start = |id: &str, kind: &str, title: &str| {
        report(
            &db,
            json!({"session": id, "event": "start", "kind": kind, "title": title, "base": "1.4.1", "summary": "Started"}),
        );
    };
    start("impl-retry", "implementation", "Retry on 503");
    report(
        &db,
        json!({"session": "impl-retry", "event": "artifact", "summary": "Patch", "artifacts": [{"name": "retry.patch", "ver": "1"}]}),
    );
    report(
        &db,
        json!({"session": "impl-retry", "event": "question", "summary": "Asked", "question": "Three or five retries?"}),
    );
    let question = app(&db, "session", json!({"id": "impl-retry"}))["questions"][0]["id"].clone();
    app(
        &db,
        "human",
        json!({"action": "answer", "sessionId": "impl-retry", "questionId": question, "answer": "SECRET ANSWER"}),
    );
    app(
        &db,
        "human",
        json!({"action": "message", "sessionId": "impl-retry", "text": "PRIVATE MESSAGE"}),
    );
    report(
        &db,
        json!({"session": "impl-retry", "event": "done", "summary": "Retries three times with backoff", "body": "BODY TEXT", "artifacts": [{"name": "retry.patch", "ver": "2", "path": "patches/retry.patch"}]}),
    );
    start("research-cache", "research", "Cache study");
    report(
        &db,
        json!({"session": "research-cache", "event": "decision", "summary": "Keep the memory cache"}),
    );
    start("docs-guide", "document", "Retry guide");
    report(
        &db,
        json!({"session": "docs-guide", "event": "done", "summary": "Wrote the retry guide"}),
    );
    start("review-retry", "review", "Code review");
    report(
        &db,
        json!({"session": "review-retry", "event": "merged", "into": "1.4.2", "summary": "Reviewed the retry code"}),
    );
    start("old-fix", "implementation", "Older fix");
    report(
        &db,
        json!({"session": "old-fix", "event": "merged", "into": "1.4.1", "summary": "Fixed before"}),
    );
    start("decide-retry", "decision", "Retry policy");
    report(
        &db,
        json!({"session": "decide-retry", "event": "decision", "summary": "Three retries, then fail"}),
    );
    report(
        &db,
        json!({"session": "decide-retry", "event": "release", "version": "1.4.2", "absorbs": ["impl-retry", "research-cache"], "note": "Retry policy release"}),
    );
    // a person finishes the document session into 1.4.2 with a reason only they wrote
    app(
        &db,
        "human",
        json!({"action": "set_status", "sessionId": "docs-guide", "status": "merged", "into": "1.4.2", "reason": "PRIVATE REASON"}),
    );
    app(
        &db,
        "notebook",
        json!({"action": "save", "title": "NOTEBOOK SECRET", "body": "NOTEBOOK SECRET"}),
    );
    db
}

fn ids(group: &Value) -> Vec<&str> {
    group["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap())
        .collect()
}

#[test]
fn the_draft_groups_merged_and_absorbed_sessions_by_role() {
    let temp = TempDir::new("release-notes");
    let db = ledger(&temp);
    let notes = app(
        &db,
        "release_notes",
        json!({"project": PROJECT, "version": "1.4.2"}),
    );
    Schemas::load().check("release-notes.schema.json", &notes);
    assert_eq!(notes["version"], "1.4.2");
    assert_eq!(notes["previous"], "1.4.1");
    assert_eq!(notes["releasedBy"], "decide-retry");
    assert_eq!(notes["note"], "Retry policy release");
    assert_eq!(notes["versions"], json!(["1.4.2", "1.4.1"]));
    let groups = notes["groups"].as_array().unwrap();
    let roles: Vec<&str> = groups.iter().map(|g| g["role"].as_str().unwrap()).collect();
    assert_eq!(roles, ["implementation", "research", "document", "other"]);
    assert_eq!(ids(&groups[0]), ["impl-retry"]);
    assert_eq!(ids(&groups[3]), ["review-retry"]);
    let retry = &groups[0]["sessions"][0];
    assert_eq!(retry["how"], "absorbed");
    assert_eq!(retry["summary"], "Retries three times with backoff");
    assert_eq!(
        retry["artifacts"],
        json!([{"name": "retry.patch", "ver": "2", "path": "patches/retry.patch"}])
    );
    assert_eq!(groups[1]["sessions"][0]["summary"], "Keep the memory cache");
    assert_eq!(groups[2]["sessions"][0]["how"], "merged");
    assert_eq!(
        groups[3]["sessions"][0]["summary"],
        "Reviewed the retry code"
    );

    let markdown = notes["markdown"].as_str().unwrap();
    assert!(
        markdown.starts_with("# Example App 1.4.2\n\nReleased "),
        "{markdown}"
    );
    assert!(markdown.contains("by decide-retry · changes since 1.4.1."));
    assert!(markdown.contains("> Retry policy release"));
    assert!(markdown.contains("## Implementation\n\n- **Retry on 503** (`impl-retry`) — Retries three times with backoff\n  - Artifacts: `retry.patch@2` (patches/retry.patch)\n"), "{markdown}");
    assert!(
        markdown.contains("- **Code review** (`review-retry` · review) — Reviewed the retry code")
    );
    assert!(!markdown.contains("old-fix"));
    for private in [
        "SECRET ANSWER",
        "PRIVATE MESSAGE",
        "PRIVATE REASON",
        "BODY TEXT",
        "NOTEBOOK SECRET",
        "Three or five",
    ] {
        assert!(
            !notes.to_string().contains(private),
            "{private} leaked: {notes}"
        );
    }
    assert!(!markdown.ends_with("\n\n") && markdown.ends_with('\n'));
}

#[test]
fn head_is_the_default_and_unknown_baselines_are_refused() {
    let temp = TempDir::new("release-notes-head");
    let db = ledger(&temp);
    let head = app(&db, "release_notes", json!({"project": PROJECT}));
    assert_eq!(head["version"], "1.4.2");
    let latest = app(
        &db,
        "release_notes",
        json!({"project": PROJECT, "version": "latest"}),
    );
    assert_eq!(latest["markdown"], head["markdown"]);
    let older = app(
        &db,
        "release_notes",
        json!({"project": PROJECT, "version": "v1.4.1"}),
    );
    assert_eq!(older["version"], "1.4.1");
    assert!(older.get("previous").is_none());
    assert_eq!(ids(&older["groups"][0]), ["old-fix"]);

    let error = |args: Value| {
        let mut args = args;
        args["db"] = json!(db);
        call_as(Caller::App, "release_notes", &args)
            .unwrap_err()
            .code
    };
    assert_eq!(
        error(json!({"project": PROJECT, "version": "9.9"})),
        "NOT_FOUND"
    );
    assert_eq!(error(json!({"project": "No Such App"})), "NOT_FOUND");
    assert_eq!(error(json!({})), "INVALID_ARGUMENT");
    // agents may draft release notes too: nothing in them is private
    let mut args = json!({"project": PROJECT, "db": db});
    args["db"] = json!(db);
    assert!(call_as(Caller::Agent, "release_notes", &args).is_ok());
}

#[test]
fn a_baseline_without_sessions_says_so() {
    let temp = TempDir::new("release-notes-empty");
    let db = temp.join("ledger.sqlite3");
    app(
        &db,
        "register_baseline",
        json!({"project": PROJECT, "version": "2.0.0", "note": "First line\n\nSecond line"}),
    );
    let notes = app(&db, "release_notes", json!({"project": PROJECT}));
    Schemas::load().check("release-notes.schema.json", &notes);
    assert_eq!(notes["groups"], json!([]));
    let markdown = notes["markdown"].as_str().unwrap();
    assert!(
        markdown.contains("> First line\n>\n> Second line\n"),
        "{markdown}"
    );
    assert!(
        markdown.ends_with("No sessions were merged into 2.0.0.\n"),
        "{markdown}"
    );
}

#[test]
fn the_command_line_prints_the_markdown() {
    let temp = TempDir::new("release-notes-cli");
    let db = ledger(&temp);
    let output = cli(&db, &["release-notes", "-p", PROJECT, "1.4.2"]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with("# Example App 1.4.2"),
        "{}",
        stdout(&output)
    );
    let output = cli(&db, &["--json", "release-notes", "-p", PROJECT]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(json_of(&output)["version"], "1.4.2");
    let missing = cli(&db, &["release-notes"]);
    assert_eq!(missing.status.code(), Some(2), "{}", stderr(&missing));
}
