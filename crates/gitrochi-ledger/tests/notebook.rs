//! Notes remain personal and use optimistic updates, including deletes.
mod common;

use common::{app, TempDir};
use gitrochi_ledger::api::{call_as, Caller};
use serde_json::{json, Value};
use std::path::Path;

fn fail(db: &Path, args: Value, code: &str) {
    let mut args = args;
    args["db"] = json!(db);
    let result = gitrochi_ledger::call("notebook", &args);
    assert_eq!(result["error"]["code"], code, "{result}");
}

#[test]
fn optimistic_save_and_delete_preserve_a_concurrent_edit() {
    let temp = TempDir::new("notebook-conflicts");
    let db = temp.join("ledger.db");
    let note = app(
        &db,
        "notebook",
        json!({"action":"save","title":"Outline","body":"First draft","pinned":false}),
    )["note"]
        .clone();
    let updated = app(&db,"notebook",json!({"action":"save","id":note["id"],"title":"Outline","body":"Reviewed draft","pinned":true,"expectedUpdatedAt":note["updatedAt"]}))["note"].clone();
    assert!(updated["updatedAt"].as_i64().unwrap() > note["updatedAt"].as_i64().unwrap());
    let before = app(&db, "rev", json!({}))["rev"].clone();
    fail(
        &db,
        json!({"action":"save","id":note["id"],"title":"Old draft","body":"Would overwrite","expectedUpdatedAt":note["updatedAt"]}),
        "CONFLICT",
    );
    fail(
        &db,
        json!({"action":"delete","id":note["id"],"expectedUpdatedAt":note["updatedAt"]}),
        "CONFLICT",
    );
    assert_eq!(app(&db, "rev", json!({}))["rev"], before);
    assert_eq!(
        app(&db, "notebook", json!({"action":"get","id":note["id"]}))["note"]["body"],
        "Reviewed draft"
    );
    app(
        &db,
        "notebook",
        json!({"action":"delete","id":updated["id"],"expectedUpdatedAt":updated["updatedAt"]}),
    );
    assert_eq!(app(&db, "notebook", json!({}))["notes"], json!([]));
}

#[test]
fn notebook_is_private_searchable_and_orders_pinned_first() {
    let temp = TempDir::new("notebook-private");
    let db = temp.join("ledger.db");
    let a = app(
        &db,
        "notebook",
        json!({"action":"save","title":"Café","body":"Résumé outline","pinned":true}),
    )["note"]
        .clone();
    app(
        &db,
        "notebook",
        json!({"action":"save","title":"Later","body":"Unpinned"}),
    );
    let list = app(&db, "notebook", json!({"query":"re\u{301}sume\u{301}"}));
    assert_eq!(list["notes"].as_array().unwrap().len(), 1);
    assert_eq!(list["notes"][0]["id"], a["id"]);
    assert_eq!(app(&db, "notebook", json!({}))["notes"][0]["id"], a["id"]);
    assert_eq!(
        app(&db, "search", json!({"query":"Résumé"}))["hits"],
        json!([])
    );
    let denied = call_as(Caller::Agent, "notebook", &json!({"db":db,"action":"list"})).unwrap_err();
    assert_eq!(denied.code, "NOT_ALLOWED");
    fail(
        &db,
        json!({"action":"save","title":" ","body":"Body"}),
        "INVALID_ARGUMENT",
    );
    fail(
        &db,
        json!({"action":"save","title":"Title","body":"Body","pinned":"yes"}),
        "INVALID_ARGUMENT",
    );
    fail(
        &db,
        json!({"action":"save","id":a["id"],"title":"Title","body":"Body"}),
        "INVALID_ARGUMENT",
    );
}

#[test]
fn imported_notes_without_a_timestamp_remain_editable() {
    let temp = TempDir::new("notebook-zero-time");
    let db = temp.join("ledger.db");
    app(&db, "notebook", json!({}));
    rusqlite::Connection::open(&db).unwrap().execute(
        "INSERT INTO notebook_notes(id,title,body,pinned,created_at,updated_at) VALUES (1,'Old note','Original',0,0,0)",
        [],
    ).unwrap();
    let updated = app(
        &db,
        "notebook",
        json!({"action":"save","id":1,"title":"Old note","body":"Updated","expectedUpdatedAt":0}),
    );
    assert_eq!(updated["note"]["body"], "Updated");
    assert!(updated["note"]["updatedAt"].as_i64().unwrap() > 0);
}

#[test]
fn a_large_imported_note_can_be_edited_without_truncating_it() {
    let temp = TempDir::new("notebook-large");
    let db = temp.join("ledger.sqlite3");
    let body = "Original evidence. ".repeat(6000);
    let saved = app(
        &db,
        "notebook",
        json!({"action":"save","title":"Imported study","body":body}),
    );
    let edited = app(
        &db,
        "notebook",
        json!({"action":"save","id":saved["note"]["id"],"expectedUpdatedAt":saved["note"]["updatedAt"],"title":"Reviewed study","body":body}),
    );
    assert_eq!(edited["note"]["body"], body);
}
