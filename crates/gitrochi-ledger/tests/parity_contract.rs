//! The added surfaces cooperate without leaking private records or partial session reports.
mod common;
use common::{app, TempDir};
use gitrochi_ledger::{call_as, Caller};
use serde_json::json;

#[test]
fn mixed_pastes_import_work_once_and_link_session_reports_atomically() {
    let temp = TempDir::new("mixed-work");
    let db = temp.join("ledger.sqlite3");
    let paste = "```work\n{\"ev\":\"등록\",\"w\":\"W-app-01\",\"b\":\"Release\",\"t\":\"Cache review\",\"d\":\"2026-11-02\"}\n```\n```ledger\n{\"event\":\"start\",\"session\":\"chat-demo\",\"title\":\"Cache study\"}\n```";
    let result = app(&db, "import", json!({"project":"Example App","text":paste}));
    assert_eq!(result["results"].as_array().unwrap().len(), 2);
    assert!(
        result["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["ok"] == true),
        "{result}"
    );
    let linked = app(
        &db,
        "report",
        json!({"session":"chat-demo","event":"artifact","summary":"Measured cache behavior","work":["W-app-01"]}),
    );
    assert_eq!(linked["sessionId"], "chat-demo");
    let unassigned = app(
        &db,
        "work",
        json!({"action":"unassigned","project":"Example App"}),
    );
    assert!(!unassigned["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|e| e["summary"] == "Measured cache behavior"));
    let before = app(&db, "rev", json!({}));
    let invalid = gitrochi_ledger::call(
        "report",
        &json!({"db":db,"project":"Example App","session":"invalid-work","event":"start","title":"Must roll back","work":["W-missing-99"]}),
    );
    assert!(invalid.get("error").is_some());
    assert_eq!(app(&db, "rev", json!({})), before);
    assert!(
        gitrochi_ledger::call("session", &json!({"db":db,"id":"invalid-work"}))
            .get("error")
            .is_some()
    );
    let again = app(&db, "import", json!({"project":"Example App","text":paste}));
    assert!(again["results"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["duplicate"] == true));
}

#[test]
fn a_work_only_paste_and_person_only_methods_keep_their_boundaries() {
    let temp = TempDir::new("work-only");
    let db = temp.join("ledger.sqlite3");
    let result = app(
        &db,
        "import",
        json!({"project":"Example App","text":"```work\n{\"event\":\"registered\",\"item\":\"W-app-01\",\"bundle\":\"Release\",\"title\":\"Cache review\",\"date\":\"2026-11-02\"}\n```"}),
    );
    assert_eq!(result["results"][0]["ok"], true, "{result}");
    for method in ["notebook", "records"] {
        let failure = call_as(Caller::Agent, method, &json!({"db":db})).unwrap_err();
        assert_eq!(failure.code, "NOT_ALLOWED");
    }
}

#[test]
fn added_result_shapes_match_the_published_schemas() {
    let temp = TempDir::new("extra-schemas");
    let db = temp.join("ledger.sqlite3");
    let schemas = common::Schemas::load();
    schemas.check(
        "notebook.schema.json",
        &app(&db, "notebook", json!({"action":"list"})),
    );
    schemas.check(
        "work-state.schema.json",
        &app(
            &db,
            "work",
            json!({"project":"Example App","action":"list"}),
        ),
    );
    schemas.check(
        "documents.schema.json",
        &app(
            &db,
            "documents",
            json!({"project":"Example App","action":"list"}),
        ),
    );
}

#[test]
fn mixed_pastes_take_the_session_project_instead_of_unrelated_recent_work() {
    let temp = TempDir::new("mixed-project");
    let db = temp.join("ledger.sqlite3");
    app(
        &db,
        "work",
        json!({"action":"add_item","project":"Newer","item":"W-new-01","bundle":"Release","title":"Existing work","date":"2026-11-02"}),
    );
    let paste="```ledger\n{\"event\":\"start\",\"session\":\"older-chat\",\"project\":\"Older\",\"title\":\"Older project work\"}\n```\n```work\n{\"ev\":\"등록\",\"w\":\"W-old-01\",\"b\":\"Release\",\"t\":\"Older work\",\"d\":\"2026-11-02\"}\n```";
    let result = app(&db, "import", json!({"text":paste}));
    assert!(
        result["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["ok"] == true),
        "{result}"
    );
    let older = app(&db, "work", json!({"action":"list","project":"Older"}));
    assert_eq!(older["items"][0]["id"], "W-old-01");
    let ambiguous = app(
        &db,
        "import",
        json!({"text":"```work\n{\"ev\":\"등록\",\"w\":\"W-bad-01\",\"b\":\"Release\",\"t\":\"Needs project\",\"d\":\"2026-11-02\"}\n```"}),
    );
    assert_eq!(ambiguous["results"][0]["ok"], false);
}
