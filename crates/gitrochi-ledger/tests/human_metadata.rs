//! Metadata and destructive record management remain available only to a person.
mod common;

use common::{app, TempDir};
use gitrochi_ledger::{call_as, Caller};
use serde_json::json;

#[test]
fn metadata_is_validated_and_never_claims_a_new_agent_report() {
    let temp = TempDir::new("record-metadata");
    let db = temp.join("ledger.db");
    app(
        &db,
        "report",
        json!({"project":"Example App","session":"record-1","event":"start","title":"Old title","kind":"research","summary":"Started","base":"1.0.0"}),
    );
    let before = app(&db, "session", json!({"id":"record-1"}));
    app(
        &db,
        "records",
        json!({"action":"update","sessionId":"record-1","title":"New title","kind":"문서","touches":["docs/spec.md","docs/spec.md"],"related":["record-2"],"chatUrl":"https://example.com/chat/1"}),
    );
    let after = app(&db, "session", json!({"id":"record-1"}));
    assert_eq!(after["session"]["title"], "New title");
    assert_eq!(after["session"]["kind"], "document");
    assert_eq!(after["session"]["touches"], json!(["docs/spec.md"]));
    assert_eq!(
        after["session"]["lastAgentAt"],
        before["session"]["lastAgentAt"]
    );
    assert_eq!(after["session"]["lastAt"], before["session"]["lastAt"]);
    assert_eq!(
        after["events"].as_array().unwrap().last().unwrap()["actor"],
        "human"
    );
    let rev = app(&db, "rev", json!({}))["rev"].clone();
    let result = gitrochi_ledger::call(
        "records",
        &json!({"db":db,"action":"update","sessionId":"record-1","title":"Would change","touches":[5]}),
    );
    assert_eq!(result["error"]["code"], "INVALID_ARGUMENT");
    assert_eq!(app(&db, "rev", json!({}))["rev"], rev);
    assert_eq!(
        app(&db, "session", json!({"id":"record-1"}))["session"]["title"],
        "New title"
    );
    assert_eq!(
        call_as(
            Caller::Agent,
            "records",
            &json!({"db":db,"action":"update","sessionId":"record-1","title":"Agent edit"})
        )
        .unwrap_err()
        .code,
        "NOT_ALLOWED"
    );
}

#[test]
fn deletion_removes_owned_history_and_prompts_but_keeps_baselines_and_work() {
    let temp = TempDir::new("record-deletion");
    let db = temp.join("ledger.db");
    app(
        &db,
        "report",
        json!({"project":"Example App","session":"record-delete","event":"start","title":"Study","kind":"decision","summary":"Started","base":"1.0.0"}),
    );
    app(
        &db,
        "report",
        json!({"session":"record-delete","event":"release","version":"1.1.0","summary":"Released"}),
    );
    app(
        &db,
        "report",
        json!({"session":"record-delete","event":"question","summary":"One question?","question":"One question?"}),
    );
    app(
        &db,
        "prompt_create",
        json!({"sessionId":"record-delete","kind":"stop_question","payload":{},"deadline":0}),
    );
    app(
        &db,
        "work",
        json!({"action":"add_item","project":"Example App","item":"W-app-01","bundle":"Milestone","title":"Retained work","date":"2026-11-02"}),
    );
    let refused = gitrochi_ledger::call(
        "records",
        &json!({"db":db,"action":"delete","sessionId":"record-delete"}),
    );
    assert_eq!(refused["error"]["code"], "INVALID_ARGUMENT");
    app(
        &db,
        "records",
        json!({"action":"delete","sessionId":"record-delete","confirmed":true}),
    );
    let state = app(&db, "state", json!({}));
    assert_eq!(state["sessions"], json!([]));
    assert_eq!(state["questions"], json!([]));
    assert_eq!(state["pendingPrompts"], json!([]));
    assert!(state["baselines"]
        .as_array()
        .unwrap()
        .iter()
        .any(|b| b["version"] == "1.1.0" && b["bySession"].is_null()));
    assert_eq!(
        app(
            &db,
            "work",
            json!({"action":"list","project":"Example App"})
        )["items"][0]["title"],
        "Retained work"
    );
}

#[test]
fn baseline_note_edits_require_an_existing_version_and_no_session() {
    let temp = TempDir::new("baseline-notes");
    let db = temp.join("ledger.db");
    app(
        &db,
        "register_baseline",
        json!({"project":"Example App","version":"1.0.0","note":"Before"}),
    );
    app(
        &db,
        "records",
        json!({"action":"version_note","project":"Example App","version":"v1.0.0","note":"Reviewed baseline"}),
    );
    assert_eq!(
        app(&db, "state", json!({}))["baselines"][0]["note"],
        "Reviewed baseline"
    );
    app(
        &db,
        "records",
        json!({"action":"version_note","project":"Example App","version":"1.0.0","note":""}),
    );
    assert!(app(&db, "state", json!({}))["baselines"][0]["note"].is_null());
    let missing = gitrochi_ledger::call(
        "records",
        &json!({"db":db,"action":"version_note","project":"Example App","version":"9.0.0","note":"Not created"}),
    );
    assert_eq!(missing["error"]["code"], "NOT_FOUND");
}
