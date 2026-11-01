//! Importing a claude-ledger database (D5) from a generated file shaped like the original
//! tool's: kinds and words mapped, history and waiting messages carried over, existing
//! sessions skipped, nothing changed by a second import, and the file never written.

mod common;

use common::{app, cli, json_of, stderr, stdout, Schemas, TempDir};
use gitrochi_ledger::util::{now_ms, Ms, DAY, HOUR};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

// The original's tables, written for these tests: only the names have to match.
const DDL: &str = "
CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE versions (project TEXT, version TEXT, ts INTEGER, source TEXT, note TEXT DEFAULT '',
    by_session TEXT, PRIMARY KEY (project, version));
CREATE TABLE sessions (id TEXT PRIMARY KEY, project TEXT, kind TEXT DEFAULT '', title TEXT DEFAULT '',
    base_version TEXT, base_current TEXT, base_was_latest INTEGER DEFAULT 0, status TEXT DEFAULT 'active',
    merged_into TEXT, touches TEXT DEFAULT '[]', related TEXT DEFAULT '[]', chat_url TEXT DEFAULT '',
    channel TEXT DEFAULT '', color INTEGER DEFAULT 0, created_ts INTEGER, last_ts INTEGER, ack_ts INTEGER,
    snooze_ts INTEGER, archived_ts INTEGER);
CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, project TEXT, ts INTEGER,
    type TEXT, actor TEXT, summary TEXT DEFAULT '', ssot TEXT, artifacts TEXT DEFAULT '[]',
    data TEXT DEFAULT '{}', channel TEXT DEFAULT '', delivered_ts INTEGER);
CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, ts INTEGER, text TEXT,
    state TEXT DEFAULT 'open', answer TEXT, answered_by TEXT, answered_ts INTEGER, delivered_ts INTEGER);
CREATE TABLE imports (hash TEXT PRIMARY KEY, ts INTEGER);
CREATE TABLE work_items (id TEXT PRIMARY KEY, project TEXT, title TEXT);
CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT, body TEXT);
INSERT INTO meta VALUES ('rev', '42');
PRAGMA user_version = 7;
";

/// SHA-1 of the block below as the original's language writes canonical JSON (sorted keys,
/// `", "` and `": "`, non-ASCII kept), computed outside this code base.
const PASTED_HASH: &str = "56deda7cfc18f44ad11079f25b99b0d0e8d6f582";
const PASTED: &str = "Answer text\n```ledger\n{\"session\":\"web-chat-17\",\"touches\":[\"src/a\",\"src/b\"],\"project\":\"Example App\",\"n\":2.5,\"event\":\"note\",\"summary\":\"Price check — “two caches” and a \\\"quote\\\"\"}\n```\n";

const SESSIONS: [&str; 6] = [
    "S1027-01",
    "S1027-02",
    "S1027-03",
    "web-chat-17",
    "S1027-05",
    "doc-session-1",
];

struct Fixture {
    path: PathBuf,
    t0: Ms,
    now: Ms,
}

impl Fixture {
    fn t(&self, minutes: i64) -> Ms {
        self.t0 + minutes * 60_000
    }
}

/// Inserts rows given as JSON objects; nested arrays and objects are stored as JSON text,
/// the way the original keeps them.
fn insert(c: &rusqlite::Connection, table: &str, rows: Value) {
    use rusqlite::types::Value as Sql;
    for row in rows.as_array().unwrap() {
        let row = row.as_object().unwrap();
        let columns: Vec<&str> = row.keys().map(String::as_str).collect();
        let values = row.values().map(|v| match v {
            Value::Null => Sql::Null,
            Value::Number(n) => Sql::Integer(n.as_i64().unwrap()),
            Value::String(s) => Sql::Text(s.clone()),
            other => Sql::Text(other.to_string()),
        });
        let sql = format!(
            "INSERT INTO {table} ({}) VALUES ({})",
            columns.join(", "),
            vec!["?"; columns.len()].join(", ")
        );
        c.execute(&sql, rusqlite::params_from_iter(values)).unwrap();
    }
}

/// A claude-ledger file in WAL mode, as the original keeps it, closed afterwards (which
/// checkpoints it and removes its `-wal` and `-shm`).
fn fixture(dir: &TempDir) -> Fixture {
    let folder = dir.join("claude-ledger");
    std::fs::create_dir_all(&folder).unwrap();
    let now = now_ms();
    let f = Fixture {
        path: folder.join("ledger.db"),
        t0: now - 10 * DAY,
        now,
    };
    let t = |minutes: i64| f.t(minutes);
    let c = rusqlite::Connection::open(&f.path).unwrap();
    let _: String = c
        .query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))
        .unwrap();
    c.execute_batch(DDL).unwrap();

    let versions = json!([
        {"project": "Example App", "version": "1.0.0", "ts": t(-100), "source": "scan"},
        {"project": "Example App", "version": "1.1.0", "ts": t(20), "source": "release",
         "note": "Cache policy", "by_session": "S1027-01"},
        {"project": "Example App", "version": "1.2.0", "ts": t(150), "source": "inferred"},
        {"project": "Docs Site", "version": "2.0", "ts": t(-50), "source": "registered",
         "note": "First outline"},
        // Released by a session the file does not have.
        {"project": "Docs Site", "version": "2.1", "ts": t(160), "source": "release",
         "by_session": "S0000-77"}
    ]);
    insert(&c, "versions", versions);

    let sessions = json!([
        // A decision session, merged and confirmed.
        {"id": "S1027-01", "project": "Example App", "kind": "판정", "title": "Cache policy",
         "base_version": "1.0.0", "base_current": "1.1.0", "status": "merged", "merged_into": "1.1.0",
         "touches": ["src/cache"], "chat_url": "https://example.com/chat/1", "channel": "mcp",
         "created_ts": t(0), "last_ts": t(50), "ack_ts": t(60)},
        // The implementation channel.
        {"id": "S1027-02", "project": "Example App", "kind": "구현", "title": "Implementation channel",
         "base_version": "1.0.0", "base_current": "1.1.0", "color": 1,
         "created_ts": t(5), "last_ts": t(45)},
        // Research with every kind of question and a person's waiting messages.
        {"id": "S1027-03", "project": "Example App", "kind": "연구", "title": "Two caches compared",
         "base_version": "1.1.0", "base_current": "1.1.0", "status": "done", "color": 2,
         "touches": ["src/cache", "docs/cache.md"], "created_ts": t(70), "last_ts": t(100)},
        // A kind no role knows, snoozed an hour ago, reported from a pasted block.
        {"id": "web-chat-17", "project": "Example App", "kind": "spike", "title": "Price check",
         "touches": ["src/a", "src/b"], "channel": "import", "created_ts": t(110), "last_ts": t(115),
         "snooze_ts": now - HOUR},
        // The second implementation line.
        {"id": "S1027-05", "project": "Example App", "kind": "LLM 구현", "title": "Local model channel",
         "base_version": "1.1.0", "base_current": "1.1.0", "color": 4,
         "created_ts": t(120), "last_ts": t(125)},
        // Another project: a document, closed, confirmed and archived; its link is not http(s).
        {"id": "doc-session-1", "project": "Docs Site", "kind": "문서", "title": "Docs outline",
         "base_version": "2.0", "base_current": "2.0", "status": "closed",
         "chat_url": "javascript:alert(1)", "created_ts": t(130), "last_ts": t(135),
         "ack_ts": t(139), "archived_ts": t(140)},
        // Rows the import cannot take.
        {"id": "a b", "project": "Example App", "kind": "연구", "created_ts": t(200), "last_ts": t(200)},
        {"id": "S1027-09", "project": "Example App", "status": "paused",
         "created_ts": t(210), "last_ts": t(210)}
    ]);
    insert(&c, "sessions", sessions);

    let events = json!([
        {"session_id": "S1027-01", "ts": t(0), "type": "start", "actor": "claude",
         "summary": "Cache policy", "ssot": "1.0.0"},
        {"session_id": "S1027-01", "ts": t(20), "type": "release", "actor": "claude",
         "summary": "Released 1.1.0", "ssot": "1.1.0", "data": {"version": "1.1.0", "absorbs": []}},
        // The record S1027-02's sync left on the decision session.
        {"session_id": "S1027-01", "ts": t(40), "type": "merged", "actor": "claude",
         "summary": "S1027-02 synced v1.1.0", "ssot": "1.1.0",
         "data": {"into": "1.1.0", "by": "S1027-02", "via": "sync", "from_status": "active"}},
        {"session_id": "S1027-01", "ts": t(60), "type": "ack", "actor": "human",
         "summary": "Confirmed", "delivered_ts": t(60)},
        {"session_id": "S1027-02", "ts": t(5), "type": "start", "actor": "claude",
         "summary": "Channel open", "ssot": "1.0.0"},
        {"session_id": "S1027-02", "ts": t(40), "type": "sync", "actor": "claude",
         "summary": "Took 1.1.0", "ssot": "1.1.0",
         "data": {"from": "1.0.0", "to": "1.1.0", "handoff": ["S1027-01"]}},
        {"session_id": "S1027-02", "ts": t(45), "type": "applied", "actor": "claude",
         "summary": "Applied 1.1.0", "ssot": "1.1.0",
         "data": {"version": "1.1.0", "from": "1.0.0", "targets": []}},
        {"session_id": "S1027-03", "ts": t(70), "type": "start", "actor": "claude",
         "summary": "Comparing", "ssot": "1.1.0"},
        {"session_id": "S1027-03", "ts": t(80), "type": "question", "actor": "claude",
         "summary": "Which cache?", "data": {"item": 1}},
        {"session_id": "S1027-03", "ts": t(85), "type": "progress", "actor": "claude",
         "summary": "Two more questions", "ssot": "1.1.0",
         "data": {"items": [2, 3], "body": "## Table\r\n| a | b |\r\n"},
         "artifacts": [
             {"name": "comparison", "ssot": "1.1.0", "ver": "r1", "path": "", "note": "",
              "ssot_inferred": false},
             {"name": "notes", "ssot": "1.1.0", "ver": "", "path": "docs/notes.md", "note": "",
              "ssot_inferred": true}
         ]},
        {"session_id": "S1027-03", "ts": t(90), "type": "answer", "actor": "human",
         "summary": "Answered #2", "data": {"item": 2}, "delivered_ts": t(90)},
        {"session_id": "S1027-03", "ts": t(95), "type": "progress", "actor": "claude",
         "summary": "Settled #3 here"},
        // A person's status change and note, not delivered to the agent yet.
        {"session_id": "S1027-03", "ts": t(97), "type": "status", "actor": "human",
         "summary": "Status: done", "data": {"status": "done", "into": null}},
        {"session_id": "S1027-03", "ts": t(99), "type": "note", "actor": "human",
         "summary": "Please add the numbers"},
        {"session_id": "S1027-03", "ts": t(100), "type": "note", "actor": "claude",
         "summary": "For the record"},
        {"session_id": "web-chat-17", "ts": t(110), "type": "start", "actor": "claude",
         "summary": "Price check"},
        {"session_id": "web-chat-17", "ts": t(115), "type": "note", "actor": "claude",
         "summary": "Price check — “two caches” and a \"quote\""},
        {"session_id": "S1027-05", "ts": t(120), "type": "start", "actor": "claude",
         "summary": "Local channel", "ssot": "1.1.0"},
        {"session_id": "S1027-05", "ts": t(125), "type": "progress", "actor": "claude",
         "summary": "Back at it", "data": {"reopened_from": "closed"}},
        {"session_id": "doc-session-1", "ts": t(130), "type": "start", "actor": "claude",
         "summary": "Outline", "ssot": "2.0", "data": {"body": "Outline body"}},
        {"session_id": "doc-session-1", "ts": t(135), "type": "closed", "actor": "claude",
         "summary": "Outline done"},
        {"session_id": "a b", "ts": t(200), "type": "start", "actor": "claude"},
        // No such session in the file.
        {"session_id": "S0000-99", "ts": t(220), "type": "progress", "actor": "claude"}
    ]);
    insert(&c, "events", events);

    let items = json!([
        {"id": 1, "session_id": "S1027-03", "ts": t(80), "text": "Which cache?"},
        {"id": 2, "session_id": "S1027-03", "ts": t(85), "text": "Keep the old one?",
         "state": "answered", "answer": "No", "answered_by": "human", "answered_ts": t(90)},
        {"id": 3, "session_id": "S1027-03", "ts": t(85), "text": "Benchmark again?",
         "state": "answered", "answer": "Settled #3 here", "answered_by": "claude",
         "answered_ts": t(95), "delivered_ts": t(95)},
        {"id": 4, "session_id": "S1027-03", "ts": t(86), "text": "Drop the CDN?",
         "state": "dismissed", "answered_by": "human", "answered_ts": t(96), "delivered_ts": t(98)},
        {"id": 5, "session_id": "S1027-01", "ts": t(10), "text": "Keep the TTL?",
         "state": "answered", "answer": "Yes", "answered_by": "human", "answered_ts": t(30),
         "delivered_ts": t(35)},
        {"id": 9, "session_id": "S1027-09", "ts": t(210), "text": "Lost?"}
    ]);
    insert(&c, "items", items);
    let imports = json!([
        {"hash": PASTED_HASH, "ts": t(115)},
        {"hash": "0123456789abcdef0123456789abcdef01234567", "ts": t(10)}
    ]);
    insert(&c, "imports", imports);
    // Tables the import never reads (D3).
    let work = json!([{"id": "W-EX-01", "project": "Example App", "title": "Work item zebra"}]);
    insert(&c, "work_items", work);
    let notes = json!([{"id": 1, "title": "Private note", "body": "Never imported zebra"}]);
    insert(&c, "notes", notes);
    drop(c);
    f
}

fn files_in(folder: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(folder)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// Every row of the ledger's tables, to compare before and after.
fn dump(db: &Path) -> BTreeMap<String, Vec<String>> {
    let c = rusqlite::Connection::open(db).unwrap();
    let mut out = BTreeMap::new();
    for table in [
        "meta",
        "projects",
        "baselines",
        "sessions",
        "events",
        "questions",
        "imports",
    ] {
        let mut statement = c
            .prepare(&format!("SELECT * FROM {table} ORDER BY 1, 2"))
            .unwrap();
        let width = statement.column_count();
        let rows = statement
            .query_map([], |r| {
                let values: Vec<String> = (0..width)
                    .map(|i| format!("{:?}", r.get_ref(i).unwrap()))
                    .collect();
                Ok(values.join(" | "))
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        out.insert(table.to_string(), rows);
    }
    out
}

fn by_id(state: &Value) -> BTreeMap<String, Value> {
    state["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| (s["id"].as_str().unwrap().to_string(), s.clone()))
        .collect()
}

fn path_arg(path: &Path) -> Value {
    json!(path.to_string_lossy())
}

const ERRORS: [&str; 3] = [
    "Session a b: the ledger does not accept this ID shape; not imported.",
    "Session S1027-09: unknown status 'paused'; not imported.",
    "1 event(s) belong to no session in the file and were not imported.",
];

#[test]
fn imports_a_claude_ledger_database_without_touching_it() {
    let dir = TempDir::new("legacy");
    let f = fixture(&dir);
    let db = dir.join("ledger.sqlite3");
    let folder = f.path.parent().unwrap().to_path_buf();
    let bytes = std::fs::read(&f.path).unwrap();
    assert_eq!(files_in(&folder), ["ledger.db"]);
    let schemas = Schemas::load();

    // The preview counts exactly what the import does and writes nothing.
    let preview = app(
        &db,
        "import_legacy",
        json!({"path": path_arg(&f.path), "dryRun": true}),
    );
    schemas.check("legacy-import.schema.json", &preview);
    assert_eq!(preview["dryRun"], true);
    assert_eq!(preview["rev"], 0);
    assert_eq!(app(&db, "rev", json!({}))["rev"], 0);
    let counts = json!({"projects": 2, "baselines": 5, "baselinesUpdated": 0, "sessions": 6,
                        "events": 21, "questions": 5, "imports": 2});
    assert_eq!(preview["counts"], counts);

    let result = app(&db, "import_legacy", json!({"path": path_arg(&f.path)}));
    schemas.check("legacy-import.schema.json", &result);
    assert_eq!(result["dryRun"], false);
    assert_eq!(result["rev"], 1, "one write transaction");
    assert_eq!(result["counts"], counts);
    assert_eq!(result["skipped"], json!([]));
    assert_eq!(result["errors"], json!(ERRORS));

    // Kinds through the alias table, unknown kinds kept; roles, streams and verdicts follow.
    let state = app(&db, "state", json!({"range": "all"}));
    schemas.check("state.schema.json", &state);
    let sessions = by_id(&state);
    assert_eq!(sessions.keys().collect::<Vec<_>>().len(), 6);
    let expected = [
        ("S1027-01", "decision", "decision", "expirable"),
        ("S1027-02", "implementation", "implementation", "stale"),
        ("S1027-03", "research", "research", "needs_human"),
        ("web-chat-17", "spike", "other", "active"),
        ("S1027-05", "llm-implementation", "implementation", "stale"),
        ("doc-session-1", "document", "document", "archived"),
    ];
    for (id, kind, role, verdict) in expected {
        let s = &sessions[id];
        assert_eq!(
            (
                s["kind"].as_str(),
                s["role"].as_str(),
                s["verdict"].as_str()
            ),
            (Some(kind), Some(role), Some(verdict)),
            "{id}"
        );
    }
    assert_eq!(sessions["S1027-02"]["stream"], json!({"line": "core"}));
    assert_eq!(sessions["S1027-05"]["stream"], json!({"line": "llm"}));
    let decision = &sessions["S1027-01"];
    assert_eq!(decision["mergedInto"], "1.1.0");
    assert_eq!(decision["ackAt"], f.t(60));
    assert_eq!(decision["chatUrl"], "https://example.com/chat/1");
    assert_eq!(decision["touches"], json!(["src/cache"]));
    assert_eq!(decision["lastAt"], f.t(50));
    assert_eq!(
        decision["lastAgentAt"],
        f.t(20),
        "the hand-off record is not its own report"
    );
    assert_eq!(sessions["S1027-02"]["color"], 1);
    assert_eq!(
        sessions["web-chat-17"]["snoozeUntil"],
        f.now - HOUR + 72 * HOUR
    );
    assert!(sessions["doc-session-1"].get("chatUrl").is_none());
    assert_eq!(sessions["doc-session-1"]["archivedAt"], f.t(140));
    let streams = state["streams"].as_array().unwrap();
    let cycle = streams
        .iter()
        .find(|c| c["sessionId"] == "S1027-02" && c["version"] == "1.1.0")
        .unwrap();
    assert_eq!(cycle["state"], "applied");
    assert_eq!(cycle["releasedBy"], "S1027-01");

    // Baselines with their sources; a releaser outside the file is dropped.
    let baselines: Vec<(String, String, String, String)> = state["baselines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| {
            (
                b["project"].as_str().unwrap().to_string(),
                b["version"].as_str().unwrap().to_string(),
                b["source"].as_str().unwrap().to_string(),
                b["bySession"].as_str().unwrap_or("-").to_string(),
            )
        })
        .collect();
    let owned = |p: &str, v: &str, s: &str, b: &str| {
        (p.to_string(), v.to_string(), s.to_string(), b.to_string())
    };
    for row in [
        owned("Example App", "1.0.0", "folder", "-"),
        owned("Example App", "1.1.0", "release", "S1027-01"),
        owned("Example App", "1.2.0", "inferred", "-"),
        owned("Docs Site", "2.0", "registered", "-"),
        owned("Docs Site", "2.1", "release", "-"),
    ] {
        assert!(baselines.contains(&row), "{row:?} in {baselines:?}");
    }

    // History: actors, a person's words, renamed data keys, bodies in their column.
    let detail = app(&db, "session", json!({"id": "S1027-03"}));
    schemas.check("session-detail.schema.json", &detail);
    let events = detail["events"].as_array().unwrap();
    let kinds: Vec<(&str, &str)> = events
        .iter()
        .map(|e| (e["type"].as_str().unwrap(), e["actor"].as_str().unwrap()))
        .collect();
    assert_eq!(
        kinds,
        [
            ("start", "agent"),
            ("question", "agent"),
            ("progress", "agent"),
            ("answer", "human"),
            ("progress", "agent"),
            ("set_status", "human"),
            ("message", "human"),
            ("note", "agent"),
        ]
    );
    assert_eq!(events[1]["data"], json!({"questionId": 1}));
    assert_eq!(events[2]["data"], json!({"questionIds": [2, 3]}));
    assert_eq!(events[2]["body"], "## Table\n| a | b |");
    assert_eq!(
        events[2]["artifacts"],
        json!([
            {"name": "comparison", "ssot": "1.1.0", "ver": "r1"},
            {"name": "notes", "ssot": "1.1.0", "path": "docs/notes.md", "ssotInferred": true}
        ])
    );
    assert_eq!(events[3]["data"], json!({"questionId": 2}));
    assert_eq!(events[3]["deliveredAt"], f.t(90));
    let questions: Vec<(i64, &str, Option<&str>, Option<&str>)> = detail["questions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| {
            (
                q["id"].as_i64().unwrap(),
                q["state"].as_str().unwrap(),
                q["answeredBy"].as_str(),
                q["resolvedBy"].as_str(),
            )
        })
        .collect();
    assert_eq!(
        questions,
        [
            (1, "open", None, None),
            (2, "answered", Some("human"), None),
            (3, "answered", None, Some("agent")),
            (4, "dismissed", Some("human"), None),
        ]
    );
    assert_eq!(
        detail["waitingMessages"], 3,
        "an answer, a status and a note wait"
    );
    let handoff = app(&db, "session", json!({"id": "S1027-01"}));
    assert_eq!(
        handoff["events"][2]["data"],
        json!({"into": "1.1.0", "by": "S1027-02", "via": "sync", "fromStatus": "active"})
    );
    assert_eq!(handoff["questions"][0]["id"], 5);
    let reopened = app(&db, "session", json!({"id": "S1027-05"}));
    assert_eq!(
        reopened["events"][1]["data"],
        json!({"reopenedFrom": "closed"})
    );
    for id in SESSIONS {
        let detail = app(&db, "session", json!({"id": id}));
        schemas.check("session-detail.schema.json", &detail);
    }
    for project in ["Example App", "Docs Site"] {
        let graph = app(&db, "graph", json!({"project": project, "range": "all"}));
        schemas.check("graph.schema.json", &graph);
    }
    // Work-ledger and note tables are never read.
    assert_eq!(
        app(&db, "search", json!({"query": "zebra"}))["hits"],
        json!([])
    );

    // The file is untouched: same bytes, no files next to it.
    assert_eq!(std::fs::read(&f.path).unwrap(), bytes);
    assert_eq!(files_in(&folder), ["ledger.db"]);

    // A second import changes nothing, not even rev.
    let before = dump(&db);
    let again = app(&db, "import_legacy", json!({"path": path_arg(&f.path)}));
    schemas.check("legacy-import.schema.json", &again);
    assert_eq!(
        again["counts"],
        json!({"projects": 0, "baselines": 0, "baselinesUpdated": 0, "sessions": 0, "events": 0,
               "questions": 0, "imports": 0})
    );
    assert_eq!(again["skipped"], json!(SESSIONS));
    assert_eq!(again["errors"], json!(ERRORS));
    assert_eq!(again["rev"], 1);
    assert_eq!(dump(&db), before);
    assert_eq!(std::fs::read(&f.path).unwrap(), bytes);

    // A block the original already imported is a duplicate here; a new one is recorded.
    let pasted = app(&db, "import", json!({"text": PASTED}));
    assert_eq!(
        pasted["results"][0]["duplicate"], true,
        "{}",
        pasted["results"]
    );
    let fresh = app(
        &db,
        "import",
        json!({"text": "{\"session\": \"web-chat-17\", \"event\": \"note\", \"summary\": \"New here\"}"}),
    );
    assert_eq!(fresh["results"][0]["ok"], true);
    assert_eq!(fresh["results"][0]["duplicate"], false);

    // The person's waiting messages reach the agent once, on its next report.
    let reply = app(
        &db,
        "report",
        json!({"session": "S1027-03", "summary": "Back"}),
    );
    let messages: Vec<&str> = reply["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["kind"].as_str().unwrap())
        .collect();
    assert_eq!(messages, ["answer", "status", "message"]);
    assert!(reply["messages"][0]["text"]
        .as_str()
        .unwrap()
        .contains("question #2"));
    let reply = app(
        &db,
        "report",
        json!({"session": "S1027-03", "summary": "Again"}),
    );
    assert_eq!(reply["messages"], json!([]));
}

#[test]
fn existing_sessions_are_skipped_and_question_numbers_kept_where_free() {
    let dir = TempDir::new("legacy-existing");
    let f = fixture(&dir);
    let db = dir.join("ledger.sqlite3");
    // Another conversation already has S1027-01 here, with two questions (numbers 1 and 2),
    // and its base made 1.0.0 an inferred version.
    let reply = app(
        &db,
        "report",
        json!({"project": "Example App", "session": "S1027-01", "event": "start", "kind": "research",
               "title": "Another conversation", "base": "1.0.0", "questions": ["One?", "Two?"]}),
    );
    assert_eq!(reply["questionIds"], json!([1, 2]));
    let rev = app(&db, "rev", json!({}))["rev"].as_i64().unwrap();

    let result = app(&db, "import_legacy", json!({"path": path_arg(&f.path)}));
    Schemas::load().check("legacy-import.schema.json", &result);
    assert_eq!(result["skipped"], json!(["S1027-01"]));
    assert_eq!(
        result["counts"],
        json!({"projects": 1, "baselines": 4, "baselinesUpdated": 1, "sessions": 5,
               "events": 17, "questions": 4, "imports": 2})
    );
    assert_eq!(result["rev"], rev + 1);

    let state = app(
        &db,
        "state",
        json!({"range": "all", "project": "Example App"}),
    );
    let sessions = by_id(&state);
    assert_eq!(sessions["S1027-01"]["title"], "Another conversation");
    assert_eq!(sessions["S1027-01"]["kind"], "research");
    let baselines = state["baselines"].as_array().unwrap();
    let find = |v: &str| baselines.iter().find(|b| b["version"] == v).unwrap();
    assert_eq!(
        find("1.0.0")["source"],
        "folder",
        "an inferred version is promoted"
    );
    assert!(
        find("1.1.0").get("bySession").is_none(),
        "the skipped session is not taken for its releaser"
    );

    // Questions 3 and 4 keep their numbers; 1 and 2 move after them, and the events follow.
    let detail = app(&db, "session", json!({"id": "S1027-03"}));
    let ids: Vec<i64> = detail["questions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| q["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, [3, 4, 5, 6]);
    let texts: BTreeMap<i64, &str> = detail["questions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| (q["id"].as_i64().unwrap(), q["text"].as_str().unwrap()))
        .collect();
    assert_eq!(texts[&5], "Which cache?");
    assert_eq!(texts[&6], "Keep the old one?");
    let events = detail["events"].as_array().unwrap();
    assert_eq!(events[1]["data"], json!({"questionId": 5}));
    assert_eq!(events[2]["data"], json!({"questionIds": [6, 3]}));
    assert_eq!(events[3]["data"], json!({"questionId": 6}));
    let other = app(&db, "session", json!({"id": "S1027-01"}));
    assert_eq!(
        other["events"].as_array().unwrap().len(),
        1,
        "the skipped session gets none of the file's history"
    );
    assert_eq!(other["questions"].as_array().unwrap().len(), 2);
}

#[test]
fn a_file_still_open_in_the_original_is_read_through_its_log() {
    let dir = TempDir::new("legacy-wal");
    let f = fixture(&dir);
    let db = dir.join("ledger.sqlite3");
    // The original keeps the file open; its newest session is only in the write-ahead log.
    let writer = rusqlite::Connection::open(&f.path).unwrap();
    writer
        .execute_batch(
            "PRAGMA wal_autocheckpoint = 0;
             INSERT INTO sessions (id, project, kind, title, created_ts, last_ts)
                 VALUES ('late-1', 'Example App', '연구', 'Late session', 1000, 2000);
             INSERT INTO events (session_id, project, ts, type, actor, summary)
                 VALUES ('late-1', 'Example App', 1000, 'start', 'claude', 'Late');",
        )
        .unwrap();
    let wal = PathBuf::from(format!("{}-wal", f.path.display()));
    assert!(wal.exists());
    let (main_bytes, wal_bytes) = (
        std::fs::read(&f.path).unwrap(),
        std::fs::read(&wal).unwrap(),
    );

    let result = app(&db, "import_legacy", json!({"path": path_arg(&f.path)}));
    assert_eq!(result["counts"]["sessions"], 7);
    let late = app(&db, "session", json!({"id": "late-1"}));
    assert_eq!(late["session"]["kind"], "research");
    assert_eq!(late["events"][0]["actor"], "agent");
    assert_eq!(std::fs::read(&f.path).unwrap(), main_bytes);
    assert_eq!(std::fs::read(&wal).unwrap(), wal_bytes);
    drop(writer);
}

#[test]
fn the_command_line_previews_imports_and_reports_json() {
    let dir = TempDir::new("legacy-cli");
    let f = fixture(&dir);
    let db = dir.join("ledger.sqlite3");
    let file = f.path.to_str().unwrap();

    let output = cli(&db, &["import-legacy", file, "--dry-run"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    assert!(
        text.starts_with("Would import from claude-ledger: 6 session(s) · 21 event(s) · 5 question(s) · 5 baseline(s), 0 completed · 2 project(s) · 2 pasted-block hash(es)"),
        "{text}"
    );
    assert!(text.contains("  - Session S1027-09: unknown status 'paused'; not imported."));
    assert_eq!(app(&db, "rev", json!({}))["rev"], 0);

    let output = cli(&db, &["import-legacy", file]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).starts_with("Imported from claude-ledger: 6 session(s)"));

    let output = cli(&db, &["--json", "import-legacy", file]);
    assert!(output.status.success(), "{}", stderr(&output));
    let result = json_of(&output);
    Schemas::load().check("legacy-import.schema.json", &result);
    assert_eq!(result["skipped"].as_array().unwrap().len(), 6);
    let output = cli(&db, &["import-legacy", file]);
    let text = stdout(&output);
    assert!(
        text.starts_with("Nothing new to import from claude-ledger."),
        "{text}"
    );
    assert!(text.contains("Skipped 6 session(s) the ledger already has: S1027-01, S1027-02"));

    // Agents may run it like the paste import, through `call` too.
    let output = cli(
        &db,
        &[
            "call",
            "import_legacy",
            &json!({"path": file, "dryRun": true}).to_string(),
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(json_of(&output)["counts"]["sessions"], 0);
    let output = cli(&db, &["import-legacy"]);
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn files_that_are_not_claude_ledger_databases_are_refused() {
    let dir = TempDir::new("legacy-refused");
    let db = dir.join("ledger.sqlite3");
    let call = |path: &Path| {
        gitrochi_ledger::call(
            "import_legacy",
            &json!({"db": db.to_string_lossy(), "path": path.to_string_lossy()}),
        )
    };
    let missing = call(&dir.join("missing.db"));
    assert_eq!(missing["error"]["code"], "INVALID_ARGUMENT");
    let text = dir.join("notes.txt");
    std::fs::write(&text, "not a database at all, just words").unwrap();
    assert!(call(&text)["error"]["message"]
        .as_str()
        .unwrap()
        .contains("is not a claude-ledger database"));
    app(&db, "rev", json!({}));
    assert!(call(&db)["error"]["message"]
        .as_str()
        .unwrap()
        .contains("it looks like a Gitrochi ledger"));
    let partial = dir.join("partial.db");
    rusqlite::Connection::open(&partial)
        .unwrap()
        .execute_batch(
            "CREATE TABLE sessions (id TEXT); CREATE TABLE events (session_id TEXT, ts INTEGER, type TEXT);
             CREATE TABLE items (id INTEGER, session_id TEXT, text TEXT);
             CREATE TABLE versions (project TEXT, version TEXT);",
        )
        .unwrap();
    assert!(call(&partial)["error"]["message"]
        .as_str()
        .unwrap()
        .contains("its sessions table has no project column"));

    // An older file with only the essential columns and no import hashes still reads.
    let old = dir.join("old.db");
    rusqlite::Connection::open(&old)
        .unwrap()
        .execute_batch(
            "CREATE TABLE sessions (id TEXT, project TEXT, created_ts INTEGER);
             CREATE TABLE events (session_id TEXT, ts INTEGER, type TEXT, actor TEXT);
             CREATE TABLE items (id INTEGER, session_id TEXT, text TEXT);
             CREATE TABLE versions (project TEXT, version TEXT);
             INSERT INTO sessions VALUES ('old-session', 'Example App', 5000);
             INSERT INTO events VALUES ('old-session', 5000, 'start', 'claude');
             INSERT INTO items VALUES (1, 'old-session', 'Still open?');
             INSERT INTO versions VALUES ('Example App', '0.9');",
        )
        .unwrap();
    let result = app(&db, "import_legacy", json!({"path": path_arg(&old)}));
    assert_eq!(
        result["counts"],
        json!({"projects": 1, "baselines": 1, "baselinesUpdated": 0, "sessions": 1, "events": 1,
               "questions": 1, "imports": 0})
    );
    let detail = app(&db, "session", json!({"id": "old-session"}));
    assert_eq!(detail["session"]["verdict"], "needs_human");
    assert_eq!(detail["session"]["status"], "active");
}
