//! Optional legacy data joins the same safe import transaction as the conversation history.
mod common;

use common::{app, TempDir};
use gitrochi_ledger::{call_as, Caller};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

fn source(path: &Path, schema: i64) {
    let c = Connection::open(path).unwrap();
    c.execute_batch("CREATE TABLE sessions(id TEXT,project TEXT,kind TEXT,title TEXT,created_ts INTEGER,last_ts INTEGER);
        CREATE TABLE events(id INTEGER,session_id TEXT,ts INTEGER,type TEXT,actor TEXT,summary TEXT,data TEXT);
        CREATE TABLE items(id INTEGER,session_id TEXT,text TEXT);
        CREATE TABLE versions(project TEXT,version TEXT);
        CREATE TABLE notes(id INTEGER,title TEXT,body TEXT,pinned INTEGER,created_ts INTEGER,updated_ts INTEGER);
        CREATE TABLE work_bundles(project TEXT,name TEXT,created_date TEXT,created_ts INTEGER);
        CREATE TABLE work_items(id TEXT,project TEXT,bundle TEXT,title TEXT,output TEXT,scope TEXT,created_date TEXT,created_ts INTEGER);
        CREATE TABLE work_events(id INTEGER,item TEXT,project TEXT,type TEXT,date TEXT,date_est INTEGER,text TEXT,refs TEXT,plan TEXT,to_bundle TEXT,ts INTEGER);
        CREATE TABLE work_text_fixes(id INTEGER,project TEXT,target TEXT,event_id INTEGER,old_text TEXT,new_text TEXT,refs TEXT,ts INTEGER);
        CREATE TABLE work_notes(id INTEGER,project TEXT,target TEXT,text TEXT,ts INTEGER,delivered_ts INTEGER);
        INSERT INTO sessions VALUES('legacy-session','Example App','research','Original session',100,300);
        INSERT INTO events VALUES(77,'legacy-session',300,'done','claude','Original report','{}');
        INSERT INTO notes VALUES(8,'Private notebook','Private notebook body',1,100,200);
        INSERT INTO work_bundles VALUES('Example App','Release','2026-10-01',100);
        INSERT INTO work_items VALUES('W-app-01','Example App','Release','Cache work','Cache implementation','[\"CACHE-1\"]','2026-10-01',100);
        INSERT INTO work_events VALUES(9,'W-app-01','Example App','progress','2026-10-05',0,'Implemented the cache safely','[\"E77\"]',NULL,NULL,300);
        INSERT INTO work_text_fixes VALUES(2,'Example App','item',9,'Earlier wording','Implemented the cache safely','[\"CACHE-1\"]',301);
        INSERT INTO work_notes VALUES(1,'Example App','W-app-01','Agent follow-up instruction',302,NULL);") .unwrap();
    c.pragma_update(None, "user_version", schema).unwrap();
}

fn import(db: &Path, path: &Path, dry: bool) -> Value {
    app(db, "import_legacy", json!({"path":path,"dryRun":dry}))
}

#[test]
fn optional_work_and_notebook_data_are_previewed_imported_once_and_source_is_untouched() {
    for version in [0, 7] {
        let dir = TempDir::new("legacy-optional");
        let original = dir.join("original.db");
        let db = dir.join("ledger.sqlite3");
        source(&original, version);
        let bytes = fs::read(&original).unwrap();
        let preview = import(&db, &original, true);
        assert_eq!(preview["counts"]["workItems"], 1);
        assert_eq!(preview["counts"]["notes"], 1);
        assert!(app(&db, "notebook", json!({"action":"list"}))["notes"]
            .as_array()
            .unwrap()
            .is_empty());
        assert!(app(
            &db,
            "work",
            json!({"action":"list","project":"Example App"})
        )["items"]
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(fs::read(&original).unwrap(), bytes);
        let imported = import(&db, &original, false);
        assert_eq!(imported["counts"], preview["counts"]);
        let work = app(
            &db,
            "work",
            json!({"project":"Example App","action":"detail","item":"W-app-01"}),
        );
        assert_eq!(work["events"][0]["text"], "Implemented the cache safely");
        assert_eq!(work["history"][0]["before"]["text"], "Earlier wording");
        assert_eq!(
            work["history"][0]["after"]["text"],
            "Implemented the cache safely"
        );
        let session = app(&db, "session", json!({"id":"legacy-session"}));
        let event = session["events"][0]["id"].as_i64().unwrap();
        assert_eq!(work["events"][0]["refs"][0], format!("E{event}"));
        let notes = app(&db, "notebook", json!({"action":"list"}));
        assert_eq!(notes["notes"][0]["body"], "Private notebook body");
        assert_eq!(notes["notes"][0]["pinned"], true);
        assert_eq!(notes["notes"][0]["createdAt"], 100);
        let rev = app(&db, "rev", json!({}))["rev"].clone();
        let again = import(&db, &original, false);
        assert_eq!(again["counts"]["workItems"], 0);
        assert_eq!(again["counts"]["notes"], 0);
        assert_eq!(again["counts"]["preservedRows"], 0);
        assert_eq!(again["rev"], rev);
        assert_eq!(fs::read(&original).unwrap(), bytes);
        let stored = Connection::open(&db).unwrap();
        let count: i64 = stored
            .query_row("SELECT count(*) FROM ledger_legacy_rows", [], |r| r.get(0))
            .unwrap();
        assert!(count >= 6);
        let delivered: Option<i64> = stored
            .query_row("SELECT delivered_at FROM ledger_work_notes", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(delivered, None);
    }
}

#[test]
fn personal_notes_are_never_exposed_in_agent_queries_or_work_records() {
    let dir = TempDir::new("legacy-private");
    let original = dir.join("original.db");
    let db = dir.join("ledger.sqlite3");
    source(&original, 7);
    import(&db, &original, false);
    for (method, args) in [
        ("overview", json!({"project":"Example App"})),
        ("search", json!({"query":"Private notebook"})),
        ("work", json!({"project":"Example App","action":"list"})),
    ] {
        let mut args = args;
        args["db"] = json!(db);
        let value = call_as(Caller::Agent, method, &args).unwrap();
        assert!(
            !value.to_string().contains("Private notebook"),
            "{method}: {value}"
        );
    }
    assert_eq!(
        call_as(Caller::Agent, "notebook", &json!({"db":db,"action":"list"}))
            .unwrap_err()
            .code,
        "NOT_ALLOWED"
    );
}

#[test]
fn a_skipped_session_never_links_work_to_an_unrelated_destination_event() {
    let dir = TempDir::new("legacy-conflict");
    let original = dir.join("original.db");
    let db = dir.join("ledger.sqlite3");
    source(&original, 7);
    app(
        &db,
        "report",
        json!({"project":"Example App","session":"legacy-session","event":"start","title":"Unrelated local session"}),
    );
    let c = Connection::open(&db).unwrap();
    c.execute("UPDATE events SET id=77", []).unwrap();
    drop(c);
    let result = import(&db, &original, false);
    assert_eq!(result["skipped"][0], "legacy-session");
    let work = app(
        &db,
        "work",
        json!({"project":"Example App","action":"detail","item":"W-app-01"}),
    );
    let reference = work["events"][0]["refs"][0].as_str().unwrap();
    assert_ne!(reference, "E77");
    assert!(reference.contains("77"));
    assert_eq!(
        app(&db, "session", json!({"id":"legacy-session"}))["session"]["title"],
        "Unrelated local session"
    );
}

#[test]
fn old_notes_without_timestamps_still_support_conflict_checked_edits() {
    let dir = TempDir::new("legacy-note-times");
    let original = dir.join("original.db");
    let db = dir.join("ledger.sqlite3");
    source(&original, 0);
    let c = Connection::open(&original).unwrap();
    c.execute("UPDATE notes SET created_ts=NULL,updated_ts=NULL", [])
        .unwrap();
    drop(c);
    import(&db, &original, false);
    let notes = app(&db, "notebook", json!({"action":"list"}));
    let note = &notes["notes"][0];
    app(
        &db,
        "notebook",
        json!({"action":"save","id":note["id"],"expectedUpdatedAt":note["updatedAt"],"title":"Edited","body":"Kept locally","pinned":false}),
    );
    let raw = Connection::open(&db).unwrap();
    let body: String = raw
        .query_row(
            "SELECT body FROM ledger_legacy_rows WHERE table_name='notes'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(body.contains("Private notebook body"));
    assert!(!body.contains("Kept locally"));
    assert_eq!(
        raw.query_row(
            "SELECT title FROM notebook_notes WHERE id=?1",
            params![note["id"].as_i64().unwrap()],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "Edited"
    );
}
