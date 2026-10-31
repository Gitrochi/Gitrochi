//! The contract: the C ABI round trip, the header, and every shape in `schema/*.json`
//! checked against real results from the demo data.

mod common;

use common::{app, Schemas, TempDir};
use gitrochi_ledger::ffi::{gitrochi_ledger_call, gitrochi_ledger_free};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::path::Path;

fn ffi(method: &[u8], args: Option<&[u8]>) -> Value {
    let method = CString::new(method).unwrap();
    let args = args.map(|a| CString::new(a).unwrap());
    // SAFETY: both strings are NUL-terminated and outlive the call; the result is freed once.
    let text = unsafe {
        let result = gitrochi_ledger_call(
            method.as_ptr(),
            args.as_ref().map_or(std::ptr::null(), |a| a.as_ptr()),
        );
        assert!(!result.is_null());
        let text = CStr::from_ptr(result).to_str().unwrap().to_string();
        gitrochi_ledger_free(result);
        text
    };
    serde_json::from_str(&text).unwrap()
}

fn ffi_json(method: &str, args: &Value) -> Value {
    ffi(method.as_bytes(), Some(args.to_string().as_bytes()))
}

#[test]
fn the_c_abi_round_trip() {
    let dir = TempDir::new("ffi");
    let db = dir.join("ledger.sqlite3");
    let db_text = db.to_string_lossy().to_string();
    let info = ffi_json("info", &json!({"db": db_text}));
    assert_eq!(
        (
            info["schemaVersion"].clone(),
            info["enabled"].clone(),
            info["rev"].clone()
        ),
        (json!(1), json!(true), json!(0))
    );
    assert_eq!(info["dbPath"], db_text);
    let reply = ffi_json(
        "report",
        &json!({"db": db_text, "project": "Example App", "event": "start", "title": "via the C ABI", "base": "1.0.0",
                "summary": "s", "touches": ["src/app.rs"]}),
    );
    let id = reply["sessionId"].as_str().unwrap().to_string();
    assert_eq!(reply["created"], true);
    assert!(reply["text"].as_str().unwrap().starts_with("Recorded ✓"));
    // The app may do what a person does.
    let ack = ffi_json(
        "human",
        &json!({"db": db_text, "action": "message", "sessionId": id, "text": "hi"}),
    );
    assert_eq!(ack["ok"], true);
    assert_eq!(ffi_json("rev", &json!({"db": db_text}))["rev"], ack["rev"]);
    let detail = ffi_json("session", &json!({"db": db_text, "id": id}));
    assert_eq!(detail["session"]["id"], id.as_str());
    assert_eq!(detail["waitingMessages"], 1, "reading never delivers");
    let state = ffi_json("state", &json!({"db": db_text, "range": "all"}));
    assert_eq!(state["sessions"].as_array().unwrap().len(), 1);
    // Errors come back as JSON, never as NULL.
    let missing = ffi(
        b"session",
        Some(format!("{{\"db\": {:?}, \"id\": \"S0000-00\"}}", db_text).as_bytes()),
    );
    assert_eq!(missing["error"]["code"], "NOT_FOUND");
    assert_eq!(ffi(b"nope", None)["error"]["code"], "INVALID_ARGUMENT");
    assert_eq!(
        ffi(b"state", Some(b"{not json"))["error"]["code"],
        "INVALID_ARGUMENT"
    );
    assert_eq!(
        ffi(b"state", Some(b"[1, 2]"))["error"]["code"],
        "INVALID_ARGUMENT"
    );
    assert_eq!(
        ffi(&[0xff, 0xfe], None)["error"]["code"],
        "INVALID_ARGUMENT"
    );
    // SAFETY: NULL arguments are documented as allowed.
    unsafe {
        let result = gitrochi_ledger_call(std::ptr::null(), std::ptr::null());
        let text = CStr::from_ptr(result).to_str().unwrap().to_string();
        gitrochi_ledger_free(result);
        assert!(text.contains("Missing method"));
        gitrochi_ledger_free(std::ptr::null_mut());
    }
    // Several threads at once.
    let handles: Vec<_> = (0..8)
        .map(|i| {
            let db_text = db_text.clone();
            std::thread::spawn(move || {
                ffi_json(
                    "report",
                    &json!({"db": db_text, "project": "Example App", "event": "start", "title": format!("thread {i}")}),
                )["sessionId"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
        })
        .collect();
    let ids: HashSet<String> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    assert_eq!(ids.len(), 8);
}

#[test]
fn the_header_declares_the_exported_functions() {
    let header = Path::new(env!("CARGO_MANIFEST_DIR")).join("include/gitrochi_ledger.h");
    let text = std::fs::read_to_string(&header).unwrap();
    assert!(text.contains("char *gitrochi_ledger_call(const char *method, const char *json);"));
    assert!(text.contains("void gitrochi_ledger_free(char *result);"));
    // The exported Rust signatures match the declarations.
    let _: unsafe extern "C" fn(
        *const std::ffi::c_char,
        *const std::ffi::c_char,
    ) -> *mut std::ffi::c_char = gitrochi_ledger_call;
    let _: unsafe extern "C" fn(*mut std::ffi::c_char) = gitrochi_ledger_free;
    // A C and a C++ compiler accept it, when one is installed.
    for (compiler, language) in [("cc", "c"), ("c++", "c++")] {
        match std::process::Command::new(compiler)
            .args(["-fsyntax-only", "-Wall", "-Werror", "-x", language])
            .arg(&header)
            .output()
        {
            Ok(output) => assert!(
                output.status.success(),
                "{compiler}: {}",
                String::from_utf8_lossy(&output.stderr)
            ),
            Err(_) => eprintln!("{compiler} is not installed; header compile check skipped"),
        }
    }
}

fn demo_db(dir: &TempDir) -> std::path::PathBuf {
    let db = dir.join("demo.sqlite3");
    let opened = gitrochi_ledger::Db::open(&db).unwrap();
    gitrochi_ledger::demo::seed(&opened, gitrochi_ledger::util::now_ms(), false).unwrap();
    db
}

#[test]
fn the_demo_covers_every_verdict_stream_cycles_questions_prompts_and_overlaps() {
    let dir = TempDir::new("demo");
    let db = demo_db(&dir);
    let state = app(&db, "state", json!({"range": "all"}));
    let verdicts: HashSet<&str> = state["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["verdict"].as_str().unwrap())
        .collect();
    for verdict in [
        "archived",
        "needs_human",
        "expirable",
        "confirm",
        "shelved",
        "pending_merge",
        "stale",
        "active",
    ] {
        assert!(
            verdicts.contains(verdict),
            "no {verdict} session in the demo: {verdicts:?}"
        );
    }
    let projects: Vec<&str> = state["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["key"].as_str().unwrap())
        .collect();
    assert_eq!(projects.len(), 2);
    let cycles: Vec<&str> = state["streams"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["state"].as_str().unwrap())
        .collect();
    assert!(
        cycles.len() >= 3 && cycles.contains(&"applied") && cycles.contains(&"active"),
        "{cycles:?}"
    );
    assert!(!state["questions"].as_array().unwrap().is_empty());
    assert_eq!(state["pendingPrompts"].as_array().unwrap().len(), 1);
    assert_eq!(state["attention"]["autoReview"], 1);
    assert!(!state["overlaps"].as_array().unwrap().is_empty());
    // Demo links point at example.com only.
    let text = serde_json::to_string(&state).unwrap();
    for (at, _) in text.match_indices("http") {
        assert!(
            text[at..].starts_with("https://example.com/"),
            "{}",
            &text[at..at + 40]
        );
    }
}

#[test]
fn every_result_matches_its_schema() {
    let schemas = Schemas::load();
    for name in schemas.names() {
        let schema = schemas.file(&name);
        assert_eq!(
            schema["$schema"], "https://json-schema.org/draft/2020-12/schema",
            "{name}"
        );
        // Every required key is a declared property.
        fn consistent(schema: &Value, at: &str) {
            if let (Some(required), Some(properties)) = (
                schema["required"].as_array(),
                schema["properties"].as_object(),
            ) {
                for key in required {
                    assert!(
                        properties.contains_key(key.as_str().unwrap()),
                        "{at}: {key}"
                    );
                }
            }
            for (key, value) in schema.as_object().into_iter().flatten() {
                if value.is_object() {
                    consistent(value, &format!("{at}/{key}"));
                }
            }
        }
        consistent(schema, &name);
    }
    for required in [
        "state",
        "session",
        "ledger-event",
        "question",
        "graph",
        "pending-prompt",
    ] {
        assert!(schemas.names().contains(&format!("{required}.schema.json")));
    }

    let dir = TempDir::new("schema");
    let db = demo_db(&dir);
    for range in ["7d", "30d", "all"] {
        let state = app(&db, "state", json!({"range": range}));
        schemas.check("state.schema.json", &state);
    }
    let state = app(&db, "state", json!({"range": "all"}));
    let mut seen_fields = HashSet::new();
    for session in state["sessions"].as_array().unwrap() {
        seen_fields.extend(session.as_object().unwrap().keys().cloned());
        let detail = app(&db, "session", json!({"id": session["id"]}));
        schemas.check("session-detail.schema.json", &detail);
        for event in detail["events"].as_array().unwrap() {
            schemas.check("ledger-event.schema.json", event);
        }
        for question in detail["questions"].as_array().unwrap() {
            schemas.check("question.schema.json", question);
        }
    }
    // The demo exercises the optional session fields the screens draw.
    for field in [
        "baseVersion",
        "baseCurrent",
        "behind",
        "mergedInto",
        "chatUrl",
        "ackAt",
        "archivedAt",
        "stream",
        "lastAgentAt",
    ] {
        assert!(seen_fields.contains(field), "no demo session has {field}");
    }
    for project in ["Example App", "Docs Site"] {
        for range in ["7d", "all"] {
            for key_only in [false, true] {
                let graph = app(
                    &db,
                    "graph",
                    json!({"project": project, "range": range, "keyOnly": key_only}),
                );
                schemas.check("graph.schema.json", &graph);
            }
        }
    }
    let prompts = state["pendingPrompts"]
        .as_array()
        .unwrap()
        .iter()
        .chain(state["autoReview"].as_array().unwrap());
    for prompt in prompts {
        schemas.check("pending-prompt.schema.json", prompt);
        let fetched = app(&db, "prompt_get", json!({"id": prompt["id"]}));
        schemas.check("pending-prompt.schema.json", &fetched);
    }
    // The method results the screens use beyond the schemas keep their documented keys.
    let info = app(&db, "info", json!({}));
    for key in ["schemaVersion", "dbPath", "rev", "enabled"] {
        assert!(info.get(key).is_some(), "info.{key}");
    }
    let search = app(&db, "search", json!({"query": "retry"}));
    for hit in search["hits"].as_array().unwrap() {
        for key in ["kind", "id", "title", "snippet"] {
            assert!(hit.get(key).is_some(), "hit.{key}");
        }
        assert!(hit["id"].is_string());
    }
    let overview = app(&db, "overview", json!({"project": "Example App"}));
    assert!(overview["text"]
        .as_str()
        .unwrap()
        .starts_with("[Example App] HEAD 1.4.2"));
    assert!(overview["data"]["open"].is_array());
}
