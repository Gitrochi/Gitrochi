mod common;

use common::{app, TempDir};
use gitrochi_ledger::{call_as, Caller};
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

fn call(db: &Path, action: &str, mut args: Value) -> Value {
    args["project"] = json!("Example App");
    args["action"] = json!(action);
    app(db, "documents", args)
}

#[test]
fn document_evidence_tasks_lookup_and_changes_keep_their_sources() {
    let dir = TempDir::new("documents");
    let docs = dir.join("docs");
    fs::create_dir(&docs).unwrap();
    let file = docs.join("plan.md");
    fs::write(&file,"# Directive\n## DOC-12 Cache layout\n- [ ] Verify DOC-12\n- [x] Finish DOC-14\n## Backflow\n- [ ] Resolve BUG-3 from DOC-12\n```\n- [ ] SECRET-1 must not be indexed\n```\n").unwrap();
    let db = dir.join("ledger.sqlite3");
    call(&db, "set_roots", json!({"roots":[docs]}));
    let scan = call(&db, "scan", json!({}));
    assert_eq!(scan["files"], 1);
    let lookup = call(&db, "lookup", json!({"id":"DOC-12"}));
    assert_eq!(lookup["summary"]["line"], 2);
    assert_eq!(lookup["summary"]["path"], "plan.md");
    assert_eq!(lookup["summary"]["source"], "excerpt");
    assert_eq!(lookup["entries"][0]["kind"], "directive");
    assert!(!lookup["ids"]
        .as_array()
        .unwrap()
        .contains(&json!("SECRET-1")));
    let tasks = call(&db, "worklist", json!({}));
    assert!(tasks["entries"]
        .as_array()
        .unwrap()
        .iter()
        .all(|e| e["status"] != "done"));
    let backflow = call(&db, "backflow", json!({}));
    assert_eq!(backflow["entries"][0]["id"], "BUG-3");
    let root = lookup["files"][0]["root"].clone();
    call(&db, "hold", json!({"root":root,"path":"plan.md"}));
    fs::write(&file, "## DOC-12 Updated definition\n").unwrap();
    call(&db, "scan", json!({}));
    assert_eq!(call(&db, "list", json!({}))["files"][0]["changed"], true);
    fs::remove_file(&file).unwrap();
    call(&db, "scan", json!({}));
    assert!(call(&db, "list", json!({}))["entries"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[cfg(unix)]
#[test]
fn document_folder_names_keep_their_literal_spaces() {
    let dir = TempDir::new("document-literal");
    let db = dir.join("ledger.sqlite3");
    let docs = dir.join("documents ");
    fs::create_dir(&docs).unwrap();
    fs::write(docs.join("tasks.md"), "## C50 Queue entry\n").unwrap();
    call(&db, "set_roots", json!({"roots":[docs]}));
    call(&db, "scan", json!({}));
    let evidence = call(&db, "lookup", json!({"id":"C50"}));
    assert_eq!(evidence["entries"][0]["id"], "C50");
    assert!(evidence["roots"][0].as_str().unwrap().ends_with(' '));
}

#[test]
fn only_a_person_selects_roots_and_scans_cannot_read_an_arbitrary_path() {
    let dir = TempDir::new("document-boundary");
    let db = dir.join("ledger.sqlite3");
    let args = json!({"db":db,"project":"Example App","action":"set_roots","roots":[dir.0]});
    assert_eq!(
        call_as(Caller::Agent, "documents", &args).unwrap_err().code,
        "NOT_ALLOWED"
    );
    let result = gitrochi_ledger::call(
        "documents",
        &json!({"db":db,"project":"Example App","action":"scan","path":dir.0}),
    );
    assert_eq!(result["error"]["code"], "INVALID_ARGUMENT");
    assert!(call(&db, "roots", json!({}))["roots"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn omitted_project_reads_follow_the_latest_active_configured_project() {
    let dir = TempDir::new("document-default-project");
    let db = dir.join("ledger.sqlite3");
    let initial = gitrochi_ledger::call("documents", &json!({"db":db,"action":"list"}));
    assert_eq!(
        initial["error"]["message"],
        "Choose a project for document tracking"
    );
    for project in ["Alpha", "Beta"] {
        let docs = dir.join(project);
        fs::create_dir(&docs).unwrap();
        fs::write(docs.join("tasks.md"), "## TASK-1 A definition\n").unwrap();
        app(
            &db,
            "documents",
            json!({"project":project,"action":"set_roots","roots":[docs]}),
        );
        app(&db, "documents", json!({"project":project,"action":"scan"}));
    }
    assert_eq!(
        app(&db, "documents", json!({"action":"list"}))["project"],
        "Alpha"
    );
    app(
        &db,
        "report",
        json!({"project":"Beta","session":"beta-session","event":"start","title":"Latest activity"}),
    );
    assert_eq!(
        app(&db, "documents", json!({"action":"lookup","id":"TASK-1"}))["project"],
        "Beta"
    );
    assert_eq!(app(&db, "documents", json!({"action":"scan"}))["files"], 1);
    let write = gitrochi_ledger::call(
        "documents",
        &json!({"db":db,"action":"set_roots","roots":[]}),
    );
    assert_eq!(write["error"]["code"], "INVALID_ARGUMENT");
}

#[test]
fn removing_a_root_removes_its_evidence_and_overlarge_files_are_skipped() {
    let dir = TempDir::new("document-revoke");
    let db = dir.join("ledger.sqlite3");
    let docs = dir.join("docs");
    fs::create_dir(&docs).unwrap();
    fs::write(docs.join("small.md"), "## ITEM-1 Definition").unwrap();
    fs::write(docs.join("large.md"), vec![b'x'; 1024 * 1024 + 1]).unwrap();
    call(&db, "set_roots", json!({"roots":[docs]}));
    let scan = call(&db, "scan", json!({}));
    assert_eq!(scan["files"], 1);
    assert_eq!(scan["warnings"].as_array().unwrap().len(), 1);
    call(&db, "set_roots", json!({"roots":[]}));
    assert!(call(&db, "list", json!({}))["files"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[cfg(unix)]
#[test]
fn a_symlink_cannot_escape_the_selected_document_folder() {
    let dir = TempDir::new("document-link");
    let db = dir.join("ledger.sqlite3");
    let docs = dir.join("docs");
    fs::create_dir(&docs).unwrap();
    let outside = dir.join("outside.md");
    fs::write(&outside, "## PRIVATE-1 Outside").unwrap();
    std::os::unix::fs::symlink(outside, docs.join("link.md")).unwrap();
    call(&db, "set_roots", json!({"roots":[docs]}));
    let scan = call(&db, "scan", json!({}));
    assert_eq!(scan["files"], 0);
    assert!(call(&db, "list", json!({}))["ids"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn lookup_scopes_session_links_and_never_consumes_waiting_messages() {
    let dir = TempDir::new("document-related");
    let db = dir.join("ledger.sqlite3");
    app(
        &db,
        "report",
        json!({"project":"Example App","session":"example-session","event":"start","title":"Read directive","touches":["TASK-1"]}),
    );
    app(
        &db,
        "human",
        json!({"sessionId":"example-session","action":"message","text":"Keep this waiting"}),
    );
    let lookup = call(&db, "lookup", json!({"id":"TASK-1"}));
    assert_eq!(lookup["relatedSessions"][0]["id"], "example-session");
    let detail = app(&db, "session", json!({"id":"example-session"}));
    assert_eq!(detail["waitingMessages"], 1);
}

#[test]
fn persisted_summaries_bind_to_sources_and_account_for_saved_requests_once() {
    let dir = TempDir::new("document-summary-cache");
    let db = dir.join("ledger.sqlite3");
    let docs = dir.join("docs");
    fs::create_dir(&docs).unwrap();
    let file = docs.join("plan.md");
    fs::write(&file, "## DOC-1 Current definition\n").unwrap();
    call(&db, "set_roots", json!({"roots":[docs]}));
    call(&db, "scan", json!({}));
    let cache = call(&db, "summary_get", json!({"id":"DOC-1"}));
    assert!(cache["summary"].is_null());
    let evidence = call(&db, "lookup", json!({"id":"DOC-1"}));
    let row = &evidence["entries"][0];
    assert_eq!(
        cache["key"],
        json!([
            "Example App",
            "DOC-1",
            [format!(
                "{}/{}:{}",
                row["root"].as_str().unwrap(),
                row["path"].as_str().unwrap(),
                row["hash"].as_str().unwrap()
            )]
        ])
        .to_string()
    );
    let now = gitrochi_ledger::util::now_ms();
    let mut save = json!({"id":"DOC-1","key":cache["key"],"text":"🧠e\u{301}","provider":"example","model":"default","requestId":"request-1","requestedAt":now-1000,"requestChars":11,"responseChars":3});
    let saved = call(&db, "summary_save", save.clone());
    assert_eq!(saved["usage"]["requests"], 1);
    assert_eq!(saved["usage"]["requestChars"], 11);
    assert_eq!(saved["usage"]["responseChars"], 3);
    assert_eq!(
        call(&db, "summary_get", json!({"id":"DOC-1"}))["summary"]["text"],
        "🧠e\u{301}"
    );
    assert_eq!(
        call(&db, "summary_save", save.clone())["usage"]["requests"],
        1
    );
    save["requestId"] = json!("old-request");
    save["requestedAt"] = json!(now - 2000);
    let old = gitrochi_ledger::call(
        "documents",
        &json!({"db":db,"project":"Example App","action":"summary_save", "id":"DOC-1","key":cache["key"],"text":"older","provider":"example","model":"default","requestId":"request-0","requestedAt":now-2000,"requestChars":5}),
    );
    assert_eq!(old["error"]["code"], "CONFLICT");
    fs::write(&file, "## DOC-1 Changed definition\n").unwrap();
    call(&db, "scan", json!({}));
    assert!(call(&db, "summary_get", json!({"id":"DOC-1"}))["summary"].is_null());
    let stale = gitrochi_ledger::call(
        "documents",
        &json!({"db":db,"project":"Example App","action":"summary_save","id":"DOC-1","key":cache["key"]}),
    );
    assert_eq!(stale["error"]["code"], "CONFLICT");
    assert_eq!(call(&db, "usage", json!({}))["usage"]["requests"], 1);
    call(&db, "set_roots", json!({"roots":[]}));
    let revoked = gitrochi_ledger::call(
        "documents",
        &json!({"db":db,"project":"Example App","action":"summary_get","id":"DOC-1"}),
    );
    assert_eq!(revoked["error"]["code"], "NOT_FOUND");
}

#[test]
fn summary_writes_are_app_only_and_plain_tasks_have_source_bound_cache_keys() {
    let dir = TempDir::new("document-summary-permissions");
    let db = dir.join("ledger.sqlite3");
    let docs = dir.join("docs");
    fs::create_dir(&docs).unwrap();
    fs::write(docs.join("tasks.md"), "- [ ] Check the cache\n").unwrap();
    call(&db, "set_roots", json!({"roots":[docs]}));
    call(&db, "scan", json!({}));
    let rows = call(&db, "list", json!({}));
    let row = &rows["entries"][0];
    let selector = json!({"root":row["root"],"path":row["path"],"line":row["line"]});
    let cache = call(&db, "summary_get", selector.clone());
    assert!(cache["key"].as_str().unwrap().contains("tasks.md:1"));
    let rejected = call_as(
        Caller::Agent,
        "documents",
        &json!({"db":db,"project":"Example App","action":"summary_save"}),
    )
    .unwrap_err();
    assert_eq!(rejected.code, "NOT_ALLOWED");
    let stored = rusqlite::Connection::open(&db).unwrap();
    let count: i64 = stored
        .query_row("SELECT count(*) FROM document_summary_usage", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(count, 0);
}
