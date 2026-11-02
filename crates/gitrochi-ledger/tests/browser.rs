mod common;
use common::{app, Schemas, TempDir};
use gitrochi_ledger::{
    browser::{self, Host},
    browser_install::HostConfig,
    db, event,
};
use serde_json::{json, Value};
use std::io::{self, Cursor, Read};

const EXTENSION: &str = "abcdefghijklmnopabcdefghijklmnop";
const URL: &str =
    "https://chatgpt.com/uc/ABCDEF01-2345-6789-abcd-0123456789ab?private=ignored#fragment";
fn config(dir: &TempDir) -> HostConfig {
    HostConfig {
        allowed_origin: format!("chrome-extension://{EXTENSION}/"),
        extension_id: EXTENSION.into(),
        db_path: dir.join("ledger.db"),
        host_path: dir.join("gitrochi-ledger-browser"),
    }
}
fn request(op: &str, extra: Value) -> Value {
    let mut value = json!({"version":1,"id":"request","op":op});
    value
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    value
}
fn handle(host: &mut Host, config: &HostConfig, op: &str, extra: Value) -> Value {
    host.handle(&config.allowed_origin, config, &request(op, extra))
        .unwrap()
}
fn bind(host: &mut Host, config: &HostConfig, session: Option<&str>) -> Value {
    let mut args = json!({"conversationUrl":URL,"project":"Browser fixture"});
    if let Some(id) = session {
        args["sessionId"] = json!(id);
    }
    handle(host, config, "bind", args)
}
fn question() -> Value {
    json!({"text":"Which cache?","options":[{"label":"Memory (Recommended)","recommended":false},{"label":"Disk","description":"Durable","recommended":true}],"multiSelect":true,"suggestedAnswer":"Use the existing cache"})
}

#[test]
fn capture_is_immutable_idempotent_local_only_and_does_not_deliver_agent_messages() {
    let dir = TempDir::new("browser-capture");
    let config = config(&dir);
    let mut host = Host::default();
    let start = app(
        &config.db_path,
        "report",
        json!({"event":"start","project":"Browser fixture","session":"browser-fixture","title":"Existing agent","summary":"Started","questions":["Ordinary agent question"]}),
    );
    let ordinary = start["questionIds"][0].as_i64().unwrap();
    app(
        &config.db_path,
        "human",
        json!({"action":"answer","questionId":ordinary,"answer":"Ordinary reply"}),
    );
    let db = db::shared(&config.db_path).unwrap();
    let before = app(&config.db_path, "session", json!({"id":"browser-fixture"}));
    assert_eq!(
        db.read(|c| event::waiting(c, "browser-fixture")).unwrap(),
        1
    );
    let binding = bind(&mut host, &config, Some("browser-fixture"));
    let args = json!({"bindingId":binding["bindingId"],"sourceKey":"visible-message:question-1","question":question()});
    let first = handle(&mut host, &config, "capture", args.clone());
    let id = first["questionId"].as_i64().unwrap();
    assert_eq!(first["status"], "created");
    let rev = db.rev().unwrap();
    assert_eq!(
        handle(&mut host, &config, "capture", args.clone())["status"],
        "unchanged"
    );
    assert_eq!(db.rev().unwrap(), rev);
    let mut revised = args.clone();
    revised["question"]["text"] = json!("Edited question");
    assert_eq!(
        handle(&mut host, &config, "capture", revised)["status"],
        "changed"
    );
    assert_eq!(db.rev().unwrap(), rev);
    let draft = "  The exact Tab draft.\nKeep its spacing.  \n";
    let draft_args = json!({"bindingId":binding["bindingId"],"sourceKey":"visible-message:question-1","text":draft});
    assert_eq!(
        handle(&mut host, &config, "draft", draft_args.clone())["status"],
        "updated"
    );
    let rev = db.rev().unwrap();
    assert_eq!(
        handle(&mut host, &config, "draft", draft_args)["status"],
        "unchanged"
    );
    assert_eq!(db.rev().unwrap(), rev);
    assert_eq!(
        handle(
            &mut host,
            &config,
            "draft",
            json!({"bindingId":binding["bindingId"],"sourceKey":"missing","text":"Other"})
        )["status"],
        "missing"
    );
    let detail = app(&config.db_path, "session", json!({"id":"browser-fixture"}));
    assert_eq!(detail["events"], before["events"]);
    let captured = detail["questions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|q| q["id"] == id)
        .unwrap();
    Schemas::load().check("question.schema.json", captured);
    assert_eq!(captured["text"], "Which cache?");
    assert_eq!(captured["browserDraft"], draft);
    assert_eq!(
        captured["browserSourceUrl"],
        "https://chatgpt.com/uc/abcdef01-2345-6789-abcd-0123456789ab"
    );
    assert_eq!(captured["suggestedAnswer"], "Use the existing cache");
    assert_eq!(captured["options"][0]["recommended"], false);
    assert!(detail["questions"][0].get("browserSourceUrl").is_none());
    app(
        &config.db_path,
        "human",
        json!({"action":"answer","questionId":id,"answer":"Browser-only answer"}),
    );
    assert_eq!(
        db.read(|c| event::waiting(c, "browser-fixture")).unwrap(),
        1
    );
    assert_eq!(
        handle(&mut host, &config, "capture", args)["status"],
        "answered"
    );
    assert_eq!(
        handle(
            &mut host,
            &config,
            "draft",
            json!({"bindingId":binding["bindingId"],"sourceKey":"visible-message:question-1","text":"Late"})
        )["status"],
        "closed"
    );
    let messages = db
        .write(|c| event::deliver(c, "browser-fixture", 100))
        .unwrap()
        .0;
    assert_eq!(messages.len(), 1);
    assert!(messages[0].text.contains("Ordinary reply"));
    assert_eq!(
        db.read(|c| event::waiting(c, "browser-fixture")).unwrap(),
        0
    );
    assert!(
        app(&config.db_path, "session", json!({"id":"browser-fixture"}))["questions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|q| q["id"] == id)
            .unwrap()
            .get("deliveredAt")
            .is_none()
    );
}

#[test]
fn new_bindings_create_only_explicit_browser_sessions_and_closed_targets_do_not_reopen() {
    let dir = TempDir::new("browser-bind");
    let config = config(&dir);
    let mut host = Host::default();
    assert_eq!(
        handle(&mut host, &config, "hello", json!({}))["composerPredictions"],
        false
    );
    assert!(handle(&mut host, &config, "targets", json!({}))["projects"]
        .as_array()
        .unwrap()
        .is_empty());
    let binding = bind(&mut host, &config, None);
    let session = binding["sessionId"].as_str().unwrap();
    let targets = handle(&mut host, &config, "targets", json!({}));
    assert_eq!(targets["sessions"].as_array().unwrap().len(), 1);
    assert_eq!(targets["projects"][0]["key"], "Browser fixture");
    let args = json!({"bindingId":binding["bindingId"],"sourceKey":"one","question":question()});
    handle(&mut host, &config, "capture", args.clone());
    app(
        &config.db_path,
        "human",
        json!({"action":"set_status","sessionId":session,"status":"done"}),
    );
    assert!(host
        .handle(
            &config.allowed_origin,
            &config,
            &request("capture", args.clone())
        )
        .is_err());
    assert!(handle(&mut host, &config, "targets", json!({}))["sessions"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(host
        .handle(
            &config.allowed_origin,
            &config,
            &request(
                "bind",
                json!({"conversationUrl":URL,"project":"Other","sessionId":session})
            )
        )
        .is_err());
    handle(
        &mut host,
        &config,
        "unbind",
        json!({"bindingId":binding["bindingId"]}),
    );
    assert!(host
        .handle(&config.allowed_origin, &config, &request("capture", args))
        .is_err());
    assert_eq!(
        app(&config.db_path, "session", json!({"id":session}))["session"]["status"],
        "done"
    );
}

#[test]
fn independent_ports_and_concurrent_snapshots_share_one_captured_question() {
    let dir = TempDir::new("browser-concurrent");
    let config = config(&dir);
    let binding = bind(&mut Host::default(), &config, None);
    let session = binding["sessionId"].as_str().unwrap().to_string();
    let before = db::shared(&config.db_path).unwrap().rev().unwrap();
    let threads=(0..8).map(|_| { let config=config.clone(); let session=session.clone(); std::thread::spawn(move|| {
        let mut host=Host::default(); let binding=bind(&mut host,&config,Some(&session));
        handle(&mut host,&config,"capture",json!({"bindingId":binding["bindingId"],"sourceKey":"same","question":question()}))
    }) }).collect::<Vec<_>>();
    let results = threads
        .into_iter()
        .map(|t| t.join().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        results.iter().filter(|v| v["status"] == "created").count(),
        1
    );
    assert!(results
        .iter()
        .all(|v| v["questionId"] == results[0]["questionId"]));
    assert_eq!(
        db::shared(&config.db_path).unwrap().rev().unwrap(),
        before + 1
    );
    assert_eq!(
        app(&config.db_path, "session", json!({"id":session}))["questions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn urls_origins_fields_and_metadata_are_validated_before_capture() {
    for method in ["browser_status", "browser_install", "browser_remove"] {
        assert_eq!(
            gitrochi_ledger::call_as(gitrochi_ledger::Caller::Agent, method, &json!({}))
                .unwrap_err()
                .code,
            "NOT_ALLOWED"
        );
    }
    assert_eq!(
        browser::canonical_conversation(
            "https://chatgpt.com/g/g-example/c/abcdef01-2345-6789-abcd-0123456789ab"
        )
        .unwrap(),
        "https://chatgpt.com/c/abcdef01-2345-6789-abcd-0123456789ab"
    );
    for url in [
        "http://chatgpt.com/c/abcdef01-2345-6789-abcd-0123456789ab",
        "https://chatgpt.com.evil.test/c/abcdef01-2345-6789-abcd-0123456789ab",
        "https://chatgpt.com/",
        "https://chatgpt.com/c/invalid",
        "https://chatgpt.com/c/abcdef01-2345-6789-abcd-0123456789ab/extra",
    ] {
        assert!(browser::canonical_conversation(url).is_err());
    }
    let dir = TempDir::new("browser-validate");
    let config = config(&dir);
    let mut host = Host::default();
    assert!(host
        .handle(
            "chrome-extension://foreign/",
            &config,
            &request("hello", json!({}))
        )
        .is_err());
    assert!(host
        .handle(
            config.allowed_origin.trim_end_matches('/'),
            &config,
            &request("hello", json!({}))
        )
        .is_err());
    let binding = bind(&mut host, &config, None);
    for invalid in [
        json!({"text":"Q","multiSelect":"yes"}),
        json!({"text":"Q","options":[{"label":"A","recommended":1}]}),
        json!({"text":"Q","options":[{"label":"é"},{"label":"e\u{301}"}]}),
        json!({"text":"Q","db":"foreign"}),
    ] {
        assert!(host.handle(&config.allowed_origin,&config,&request("capture",json!({"bindingId":binding["bindingId"],"sourceKey":"invalid","question":invalid}))).is_err());
    }
    assert!(host
        .handle(
            &config.allowed_origin,
            &config,
            &request("targets", json!({"db":"foreign"}))
        )
        .is_err());
    assert!(host
        .handle(
            &config.allowed_origin,
            &config,
            &json!({"version":2,"id":"wrong","op":"hello"})
        )
        .is_err());
    assert!(host
        .handle(
            &config.allowed_origin,
            &config,
            &request("human", json!({}))
        )
        .is_err());
    let mut replacement = config.clone();
    replacement.db_path = dir.join("replacement.db");
    handle(&mut host, &replacement, "hello", json!({}));
    assert!(host.handle(&config.allowed_origin,&config,&request("capture",json!({"bindingId":binding["bindingId"],"sourceKey":"after-change","question":question()}))).is_err());
}

fn frame(value: &Value) -> Vec<u8> {
    let body = serde_json::to_vec(value).unwrap();
    let mut out = (body.len() as u32).to_ne_bytes().to_vec();
    out.extend(body);
    out
}
fn replies(bytes: Vec<u8>) -> Vec<Value> {
    let mut reader = Cursor::new(bytes);
    let mut result = Vec::new();
    loop {
        let mut header = [0; 4];
        if reader.read_exact(&mut header).is_err() {
            return result;
        }
        let mut body = vec![0; u32::from_ne_bytes(header) as usize];
        reader.read_exact(&mut body).unwrap();
        result.push(serde_json::from_slice(&body).unwrap());
    }
}
struct OneByte(Cursor<Vec<u8>>);
impl Read for OneByte {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let len = buffer.len().min(1);
        self.0.read(&mut buffer[..len])
    }
}

#[test]
fn native_frames_handle_partial_unicode_io_and_recheck_revocation_for_every_request() {
    let dir = TempDir::new("browser-frames");
    let config = config(&dir);
    let mut message = request("hello", json!({}));
    message["id"] = json!("연결😀");
    let mut input = frame(&message);
    input.extend(frame(&message));
    let mut output = Vec::new();
    let mut calls = 0;
    browser::serve(
        &config.allowed_origin,
        OneByte(Cursor::new(input)),
        &mut output,
        || {
            calls += 1;
            if calls == 1 {
                Ok(config.clone())
            } else {
                Err(gitrochi_ledger::Error::not_allowed("Connection revoked"))
            }
        },
    )
    .unwrap();
    let result = replies(output);
    assert_eq!(result.len(), 2);
    assert_eq!(result[0]["ok"], true);
    assert_eq!(result[0]["id"], "연결😀");
    assert_eq!(result[1]["error"], "Connection revoked");
    assert_eq!(calls, 2);
    for input in [
        vec![1, 0],
        (browser::MAX_FRAME as u32 + 1).to_ne_bytes().to_vec(),
        vec![2, 0, 0, 0, b'{'],
    ] {
        assert!(browser::serve(
            &config.allowed_origin,
            Cursor::new(input),
            Vec::new(),
            || Ok(config.clone())
        )
        .is_err());
    }
    let mut malformed = 4u32.to_ne_bytes().to_vec();
    malformed.extend([0xff; 4]);
    let mut output = Vec::new();
    browser::serve(
        &config.allowed_origin,
        Cursor::new(malformed),
        &mut output,
        || Ok(config.clone()),
    )
    .unwrap();
    assert_eq!(replies(output)[0]["ok"], false);
}

#[test]
fn schema_two_migrates_without_adding_browser_fields_to_ordinary_questions() {
    let dir = TempDir::new("browser-migration");
    let path = dir.join("old.db");
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch(include_str!("../src/schema.sql")).unwrap();
    c.execute_batch(include_str!("../src/schema-v2.sql"))
        .unwrap();
    c.execute_batch("PRAGMA user_version=2").unwrap();
    drop(c);
    let db = db::shared(&path).unwrap();
    assert_eq!(
        db.read(|c| Ok(c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?))
            .unwrap(),
        3
    );
    assert_eq!(
        db.read(|c| Ok(
            c.query_row("SELECT COUNT(*) FROM browser_captures", [], |r| r
                .get::<_, i64>(0))?
        ))
        .unwrap(),
        0
    );
}
