//! Both published schema 7 and populated browser-preview databases upgrade without losing records.
mod common;

use common::{app, TempDir};
use gitrochi_ledger::{browser::Host, browser_install::HostConfig, db};
use rusqlite::{params, Connection};
use serde_json::json;

const STEPS: [&str; 7] = [
    include_str!("../src/schema.sql"),
    include_str!("../src/schema-v2.sql"),
    include_str!("../src/schema-v3-work.sql"),
    include_str!("../src/schema-v4-notebook.sql"),
    include_str!("../src/schema-v5-documents.sql"),
    include_str!("../src/schema-v6-legacy.sql"),
    include_str!("../src/schema-v7-documents.sql"),
];
const URL: &str = "https://chatgpt.com/uc/abcdef01-2345-6789-abcd-0123456789ab";
const FORM: &str = r#"{"options":[{"label":"Keep (Recommended)","recommended":false}],"multiSelect":true,"suggestedAnswer":"Keep"}"#;

fn seed_session(connection: &Connection) {
    connection.execute_batch(
        "INSERT INTO projects(key,name,created_at) VALUES('Browser fixture','Browser fixture',1);
         INSERT INTO sessions(id,project,title,created_at,last_at) VALUES('preview-session','Browser fixture','Existing session',1,2);
         INSERT INTO questions(id,session_id,text,state,answer,answered_by,created_at,answered_at)
         VALUES(1,'preview-session','An ordinary question?','answered','Original reply','human',2,3);
         INSERT INTO events(session_id,project,ts,type,actor,summary) VALUES('preview-session','Browser fixture',4,'message','human','Queued note');
         INSERT INTO imports(hash,ts) VALUES('existing-import',5);
         UPDATE meta SET value='17' WHERE key='rev';",
    ).unwrap();
}

#[test]
fn published_schema_seven_preserves_work_notebook_documents_and_question_metadata() {
    let dir = TempDir::new("browser-production-migration");
    let path = dir.join("ledger.db");
    let connection = Connection::open(&path).unwrap();
    for sql in STEPS {
        connection.execute_batch(sql).unwrap();
    }
    seed_session(&connection);
    connection
        .execute("UPDATE questions SET metadata=?1 WHERE id=1", [FORM])
        .unwrap();
    connection.execute_batch(
        "PRAGMA user_version=7;
         INSERT INTO ledger_work_bundles(project,name,created_date,created_at) VALUES('Browser fixture','Bundle','2026-11-02',1);
         INSERT INTO ledger_work_items(id,project,bundle,title,created_date,created_at) VALUES('W-01','Browser fixture','Bundle','Keep work','2026-11-02',1);
         INSERT INTO notebook_notes(title,body,created_at,updated_at) VALUES('Note','Keep notebook',1,2);
         INSERT INTO document_roots(project,path) VALUES('Browser fixture','/fixtures/docs');
         INSERT INTO document_summaries(project,source_key,identity,text,provider,model,requested_at,created_at,request_id,request_chars,response_chars)
         VALUES('Browser fixture','source','identity','Keep document summary','fixture','fixture',1,2,'request',3,4);
         INSERT INTO ledger_legacy_rows(source,table_name,row_key,body) VALUES('fixture','notes','1','Keep legacy evidence');",
    ).unwrap();
    drop(connection);
    let database = db::Db::open(&path).unwrap();
    assert_eq!(database.rev().unwrap(), 17);
    for (table, column, expected) in [
        ("ledger_work_items", "title", "Keep work"),
        ("notebook_notes", "body", "Keep notebook"),
        ("document_summaries", "text", "Keep document summary"),
        ("ledger_legacy_rows", "body", "Keep legacy evidence"),
    ] {
        let actual: String = database
            .read(|c| {
                Ok(
                    c.query_row(&format!("SELECT {column} FROM {table}"), [], |row| {
                        row.get(0)
                    })?,
                )
            })
            .unwrap();
        assert_eq!(actual, expected);
    }
    let detail = app(&path, "session", json!({"id":"preview-session"}));
    assert_eq!(detail["questions"][0]["answer"], "Original reply");
    assert_eq!(detail["questions"][0]["options"][0]["recommended"], false);
    assert_eq!(detail["questions"][0]["multiSelect"], true);
    assert_eq!(detail["questions"][0]["suggestedAnswer"], "Keep");
    assert!(detail["questions"][0].get("browserSourceUrl").is_none());
    assert!(detail["questions"][0].get("browserDraft").is_none());
    assert_eq!(detail["waitingMessages"], 2);
    assert_eq!(
        database
            .read(|c| Ok(c.query_row(
                "SELECT COUNT(*) FROM browser_session_generations",
                [],
                |row| row.get::<_, i64>(0)
            )?))
            .unwrap(),
        1
    );
    let mut raw = Connection::open(&path).unwrap();
    assert_eq!(db::migrate(&mut raw).unwrap(), db::DB_SCHEMA);
    assert_eq!(db::migrate(&mut raw).unwrap(), db::DB_SCHEMA);
    assert_eq!(database.rev().unwrap(), 17);
}

#[test]
fn populated_browser_preview_upgrades_and_retains_dedup_drafts_and_local_only_answers() {
    for version in [3, 7] {
        let dir = TempDir::new("browser-preview-migration");
        let path = dir.join("ledger.db");
        let connection = Connection::open(&path).unwrap();
        for sql in &STEPS[..2] {
            connection.execute_batch(sql).unwrap();
        }
        connection
            .execute_batch(include_str!("fixtures/browser-preview-v3.sql"))
            .unwrap();
        seed_session(&connection);
        let draft = "  기존 초안 👋\nKeep its exact spacing.  \n";
        connection.execute("INSERT INTO questions(id,session_id,text,created_at,metadata,browser_source_url,browser_draft) VALUES(2,'preview-session','Existing browser question?',6,?1,?2,?3)",params![FORM,URL,draft]).unwrap();
        connection.execute("INSERT INTO questions(id,session_id,text,state,answer,answered_by,created_at,answered_at,browser_source_url) VALUES(3,'preview-session','Closed browser question?','answered','Local only','human',7,8,?1)",[URL]).unwrap();
        let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/";
        connection.execute("INSERT INTO browser_captures(origin,conversation,session_id,source_key,digest,question_id) VALUES(?1,?2,'preview-session','one','1cea88675341111747102025762baa0bfac019f0',2)",params![origin,URL]).unwrap();
        if version == 7 {
            // A production schema-7 opener skipped work tables on the old preview lineage.
            for sql in &STEPS[3..] {
                connection.execute_batch(sql).unwrap();
            }
            connection.pragma_update(None, "user_version", 7).unwrap();
        }
        drop(connection);
        let database = db::Db::open(&path).unwrap();
        assert_eq!(database.rev().unwrap(), 17);
        assert_eq!(
            database
                .read(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?))
                .unwrap(),
            db::DB_SCHEMA
        );
        let detail = app(&path, "session", json!({"id":"preview-session"}));
        assert_eq!(detail["questions"].as_array().unwrap().len(), 3);
        assert_eq!(detail["questions"][1]["browserDraft"], draft);
        assert_eq!(detail["questions"][1]["browserSourceUrl"], URL);
        assert_eq!(detail["questions"][1]["options"][0]["recommended"], false);
        assert_eq!(detail["questions"][2]["answer"], "Local only");
        assert_eq!(detail["waitingMessages"], 2);
        database.write(|c| { c.execute("INSERT INTO ledger_work_bundles(project,name,created_date,created_at) VALUES('Browser fixture','Restored','2026-11-02',1)",[])?; Ok(()) }).unwrap();
        let config = HostConfig {
            allowed_origin: origin.into(),
            extension_id: "abcdefghijklmnopabcdefghijklmnop".into(),
            db_path: path.clone(),
            host_path: dir.join("gitrochi-ledger-browser"),
        };
        let mut host = Host::default();
        let binding = host.handle(origin,&config,&json!({"version":1,"id":"bind","op":"bind","project":"Browser fixture","sessionId":"preview-session","conversationUrl":URL})).unwrap();
        let revision = database.rev().unwrap();
        let capture = host.handle(origin,&config,&json!({"version":1,"id":"capture","op":"capture","bindingId":binding["bindingId"],"sourceKey":"one","question":{"text":"Existing browser question?","options":[{"label":"Keep (Recommended)","recommended":false}],"multiSelect":true,"suggestedAnswer":"Keep"}})).unwrap();
        assert_eq!(capture["status"], "unchanged");
        assert_eq!(capture["questionId"], 2);
        assert_eq!(database.rev().unwrap(), revision);
        let reply = app(
            &path,
            "report",
            json!({"event":"progress","session":"preview-session","summary":"Continue"}),
        );
        let messages = reply["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["questionId"], 1);
        assert!(messages[0]["text"]
            .as_str()
            .unwrap()
            .contains("Original reply"));
        assert!(messages[1]["text"]
            .as_str()
            .unwrap()
            .contains("Queued note"));
        assert!(messages
            .iter()
            .all(|message| !message["text"].as_str().unwrap().contains("Local only")));
        assert!(app(
            &path,
            "report",
            json!({"event":"progress","session":"preview-session","summary":"Continue"})
        )["messages"]
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(
            database
                .read(|c| Ok(c.query_row("SELECT hash FROM imports", [], |row| row
                    .get::<_, String>(0))?))
                .unwrap(),
            "existing-import"
        );
    }
}
