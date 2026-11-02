mod common;

use common::TempDir;
use gitrochi_ledger::{work, Db};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};

const NOW: i64 = 1_793_577_600_000;

fn run(db: &Db, mut args: Value) -> Value {
    if args["project"].is_null() {
        args["project"] = json!("Example");
    }
    work::call(db, &args, NOW, false).unwrap_or_else(|error| panic!("{args}: {error}"))
}

fn add(db: &Db, id: &str) {
    run(
        db,
        json!({"action":"add_item","item":id,"bundle":"Release","title":format!("Work {id}"),"date":"2026-10-20","text":"Added the work item"}),
    );
}

#[test]
fn dates_plans_and_failed_events_rollback_without_session_noise() {
    let dir = TempDir::new("work-dates");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    add(&db, "W-app-01");
    let rev = db.rev().unwrap();
    for args in [
        json!({"action":"event","event":"started","item":"W-app-01","date":"2026-02-29","text":"Invalid date"}),
        json!({"action":"event","event":"plan","item":"W-app-01","date":"2026-10-21","plan":{"conservative":"2026-10-30","slack":"2026-10-29"}}),
        json!({"action":"event","event":"started","item":"W-other-01","date":"2026-10-21","text":"Wrong item"}),
    ] {
        let mut args = args;
        args["project"] = json!("Example");
        assert!(work::call(&db, &args, NOW, false).is_err());
        assert_eq!(db.rev().unwrap(), rev);
    }
    run(
        &db,
        json!({"action":"event","event":"started","item":"W-app-01","date":"2026-10-21","text":"Implemented the reader"}),
    );
    run(
        &db,
        json!({"action":"event","event":"plan","item":"W-app-01","date":"2026-10-21","plan":{"conservative":"2026-10-25","slack":"2026-10-30"}}),
    );
    let list = run(&db, json!({"action":"list"}));
    assert_eq!(list["items"][0]["status"], "active");
    assert_eq!(list["items"][0]["plan"]["slack"], "2026-10-30");
    assert!(!list["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|w| w["code"] == "missing_plan"));
    let sessions = db
        .read(|c| Ok(c.query_row("SELECT count(*) FROM sessions", [], |r| r.get::<_, i64>(0))?))
        .unwrap();
    assert_eq!(sessions, 0);
}

#[test]
fn estimated_dates_and_sentences_keep_original_history_and_filtered_reports() {
    let dir = TempDir::new("work-fixes");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    add(&db, "W-app-01");
    run(
        &db,
        json!({"action":"event","w":"W-app-01","ev":"경과","d":"~2026-10-21","txt":"Draft result","ref":["abc123"]}),
    );
    run(
        &db,
        json!({"action":"event","w":"W-app-01","ev":"date_fix","was":"2026-10-21","d":"2026-10-22","of":"경과","ref":["evidence.md"]}),
    );
    run(
        &db,
        json!({"action":"event","w":"W-app-01","ev":"txt_fix","d":"2026-10-22","of":"경과","txt":"Added validated work reports"}),
    );
    let detail = run(&db, json!({"action":"detail","item":"W-app-01"}));
    assert_eq!(detail["item"]["estimatedCount"], 0);
    assert_eq!(detail["history"].as_array().unwrap().len(), 2);
    assert_eq!(detail["history"][0]["before"]["date"], "2026-10-21");
    assert_eq!(detail["history"][1]["before"]["text"], "Draft result");
    let report = run(
        &db,
        json!({"action":"report","from":"2026-10-22","to":"2026-10-22"}),
    );
    let md = report["markdown"].as_str().unwrap();
    assert!(md.contains("Added validated work reports"));
    assert!(!md.contains("Draft result"));
    assert!(!md.contains("abc123"));
    assert!(!md.contains("2026-10-20"));
    let report = run(&db, json!({"action":"report","refs":true}));
    assert!(report["markdown"].as_str().unwrap().contains("abc123"));
    assert_eq!(
        run(&db, json!({"action":"report","includeRefs":true}))["markdown"],
        report["markdown"]
    );
}

#[test]
fn fenced_import_isolated_errors_and_duplicate_replay() {
    let dir = TempDir::new("work-import");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    let text="Ignore this prose\n```work\n{\"w\":\"W-app-01\",\"ev\":\"등록\",\"b\":\"Release\",\"t\":\"Reports\",\"d\":\"2026-10-20\"}\n{bad}\n{\"w\":\"W-app-01\",\"ev\":\"경과\",\"d\":\"2026-10-21\",\"txt\":\"Added a preview\"}\n```\n";
    let result = run(&db, json!({"action":"import","text":text}));
    assert_eq!(result["results"][0]["status"], "ok");
    assert_eq!(result["results"][1]["status"], "error");
    assert_eq!(result["results"][2]["status"], "ok");
    let again = run(&db, json!({"action":"import","text":text}));
    assert_eq!(again["results"][0]["status"], "duplicate");
    assert_eq!(again["results"][2]["status"], "duplicate");
    assert_eq!(
        run(&db, json!({"action":"detail","item":"W-app-01"}))["events"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn imported_legacy_work_hashes_skip_replay_without_writing() {
    let dir = TempDir::new("work-old-hash");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    let block =
        json!({"w":"W-old-01","ev":"등록","b":"Release","t":"Existing work","d":"2026-10-20"});
    // This exact digest is Python's SHA-1 of project + newline + sorted JSON with spaces.
    let hash = "work:fd0589ec33a223bfe5ae0b8b86305bf31380a1bc";
    db.write(|c| {
        c.execute(
            "INSERT INTO imports(hash,ts) VALUES(?1,?2)",
            rusqlite::params![hash, NOW],
        )?;
        Ok(())
    })
    .unwrap();
    let rev = db.rev().unwrap();
    let replay = run(&db, json!({"action":"import","text":block.to_string()}));
    assert_eq!(replay["results"][0]["status"], "duplicate");
    assert_eq!(db.rev().unwrap(), rev);
}

#[test]
fn split_move_and_metadata_history_remain_visible_from_both_items() {
    let dir = TempDir::new("work-split");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    add(&db, "W-app-01");
    run(
        &db,
        json!({"action":"event","item":"W-app-01","event":"progress","date":"2026-10-21","text":"Added import validation"}),
    );
    run(
        &db,
        json!({"action":"add_item","item":"W-app-02","bundle":"Release","title":"Import","date":"2026-10-22","from":"W-app-01","stem":"Import"}),
    );
    run(
        &db,
        json!({"action":"event","item":"W-app-01","event":"move","date":"2026-10-21","of":"progress","to":"W-app-02"}),
    );
    run(
        &db,
        json!({"action":"event","item":"W-app-02","event":"item_fix","date":"2026-10-22","title":"Import safely"}),
    );
    let original = run(&db, json!({"action":"detail","item":"W-app-01"}));
    let split = run(&db, json!({"action":"detail","item":"W-app-02"}));
    assert_eq!(original["events"].as_array().unwrap().len(), 1);
    assert_eq!(original["history"][0]["action"], "move");
    assert_eq!(split["item"]["title"], "Import safely");
    assert_eq!(split["item"]["from"], "W-app-01");
    assert!(split["history"]
        .as_array()
        .unwrap()
        .iter()
        .any(|h| h["action"] == "move"));
}

#[test]
fn backfilled_grouping_keeps_the_newest_dated_bundle_and_stem() {
    let dir = TempDir::new("work-grouping");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    add(&db, "W-app-01");
    for (date, bundle, stem) in [
        ("2026-10-30", "Current", "Current work"),
        ("2026-10-25", "Earlier", "Earlier work"),
    ] {
        run(
            &db,
            json!({"action":"event","item":"W-app-01","event":"transfer","date":date,"to":bundle,"text":"Regrouped the work"}),
        );
        run(
            &db,
            json!({"action":"event","item":"W-app-01","event":"stem","date":date,"stem":stem}),
        );
    }
    let detail = run(&db, json!({"action":"detail","item":"W-app-01"}));
    assert_eq!(detail["item"]["bundle"], "Current");
    assert_eq!(detail["item"]["stem"], "Current work");
    let incomplete = work::call(
        &db,
        &json!({"project":"Example","action":"event","event":"complete_bundle","bundle":"Current","date":"2026-11-02"}),
        NOW,
        false,
    );
    assert_eq!(incomplete.unwrap_err().code, "CONFLICT");
    run(
        &db,
        json!({"action":"event","item":"W-app-01","event":"completed","date":"2026-11-02","text":"Completed the work"}),
    );
    run(
        &db,
        json!({"action":"event","event":"complete_bundle","bundle":"Current","date":"2026-11-02"}),
    );
    let list = run(&db, json!({"action":"list","bundle":"Current"}));
    assert_eq!(list["bundles"][0]["status"], "completed");
}

#[test]
fn repeated_issue_carries_preserve_origin_and_need_review() {
    let dir = TempDir::new("work-carry");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    for id in ["W-app-01", "W-app-02", "W-app-03"] {
        add(&db, id);
    }
    run(
        &db,
        json!({"action":"event","item":"W-app-01","event":"issue","date":"2026-10-21","text":"Large input"}),
    );
    run(
        &db,
        json!({"action":"event","item":"W-app-01","event":"carry","date":"2026-10-23","of":"issue","old":"Large input","to":"W-app-02","text":"Reproduce with the larger fixture"}),
    );
    run(
        &db,
        json!({"action":"event","item":"W-app-02","event":"carry","date":"2026-10-30","of":"issue","to":"W-app-03","text":"Continue checking the edge case"}),
    );
    let detail = run(&db, json!({"action":"detail","item":"W-app-03"}));
    assert_eq!(detail["events"][1]["data"]["originDate"], "2026-10-21");
    assert_eq!(detail["events"][1]["data"]["carryCount"], 2);
    let list = run(&db, json!({"action":"list"}));
    assert!(list["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|w| w["code"] == "repeated_carry"));
    assert_eq!(list["items"][0]["status"], "carried");
}

#[test]
fn notes_deliver_once_and_later_assignment_overrides_skip_marks() {
    let dir = TempDir::new("work-human");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    add(&db, "W-app-01");
    let note = json!({"project":"Example","action":"note","target":"W-app-01","text":"Check the exported report"});
    assert!(work::call(&db, &note, NOW, false).is_err());
    work::call(&db, &note, NOW, true).unwrap();
    work::call(&db,&json!({"project":"Example","action":"event","item":"W-app-01","event":"item_fix","date":"2026-11-02","title":"Reviewed in the app"}),NOW,true).unwrap();
    assert!(run(&db, json!({"action":"list"}))["messages"].is_null());
    assert_eq!(
        run(&db, json!({"action":"list","deliver":true}))["messages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        run(&db, json!({"action":"list","deliver":true}))["messages"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    db.write(|c|{c.execute("INSERT INTO events(id,session_id,project,ts,type,actor,summary) VALUES(900,'S-test','Example',?1,'done','agent','Completed a report')",[NOW])?;Ok(())}).unwrap();
    run(
        &db,
        json!({"action":"event","event":"skip","date":"2026-11-02","text":"Documentation only","refs":["E900"]}),
    );
    assert_eq!(
        run(&db, json!({"action":"unassigned"}))["skipped"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    run(
        &db,
        json!({"action":"event","item":"W-app-01","event":"progress","date":"2026-11-02","text":"Connected report evidence","refs":["E900"]}),
    );
    let result = run(&db, json!({"action":"unassigned"}));
    assert_eq!(result["skipped"], json!([]));
    assert_eq!(result["events"], json!([]));
    db.write(|c| {
        c.execute("INSERT INTO events(id,session_id,project,ts,type,actor,summary) VALUES(901,'S-test','Example',?1,'done','agent','Linked report')",[NOW])?;
        work::assign_session_event(c,"Example",901,&["W-app-01".into()],NOW)
    }).unwrap();
    assert_eq!(
        run(&db, json!({"action":"unassigned"}))["events"],
        json!([])
    );
}

#[test]
fn legacy_import_keeps_collision_mapping_refs_history_and_later_edits() {
    let dir = TempDir::new("work-legacy");
    let db = Db::open(&dir.join("ledger.db")).unwrap();
    add(&db, "W-app-01");
    let mut tables = BTreeMap::new();
    tables.insert("work_items".into(),vec![json!({"id":"W-app-01","project":"Example","bundle":"Imported","title":"Original","output":"","scope":"[]","created_date":"2026-10-01","created_ts":1})]);
    tables.insert("work_events".into(),vec![json!({"id":7,"item":"W-app-01","project":"Example","type":"登録","date":"2026-10-01","date_est":0,"text":"Imported text","refs":"[\"E4\"]","ts":2}),json!({"id":8,"item":"W-app-01","project":"Example","type":"経過","date":"2026-10-02","text":"Progress","refs":"[]","ts":3})]);
    // Korean aliases are input data; historical records use their original text.
    tables.get_mut("work_events").unwrap()[0]["type"] = json!("등록");
    tables.get_mut("work_events").unwrap()[1]["type"] = json!("경과");
    tables.insert("work_item_fixes".into(),vec![json!({"id":1,"item":"W-app-01","project":"Example","field":"title","old_value":"Original","new_value":"Imported title","date":"2026-10-03","ts":4})]);
    tables.insert("work_notes".into(),vec![json!({"id":1,"project":"Example","target":"W-app-01","text":"Pending instruction","ts":5,"delivered_ts":null})]);
    let mappings = HashMap::from([(4, 900)]);
    let preview = db
        .read(|c| work::import_legacy(c, &tables, &mappings, "source", false))
        .unwrap();
    assert_eq!(preview["items"], 1);
    assert_eq!(
        run(&db, json!({"action":"list"}))["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    db.write(|c| work::import_legacy(c, &tables, &mappings, "source", true))
        .unwrap();
    let list = run(&db, json!({"action":"list"}));
    let imported = list["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["bundle"] == "Imported")
        .unwrap();
    let id = imported["id"].as_str().unwrap().to_string();
    assert_ne!(id, "W-app-01");
    assert_eq!(imported["title"], "Imported title");
    let detail = run(&db, json!({"action":"detail","item":id}));
    assert_eq!(detail["events"][0]["refs"], json!(["E900"]));
    assert_eq!(detail["history"][0]["action"], "work_item_fixes");
    run(
        &db,
        json!({"action":"event","item":id,"event":"item_fix","date":"2026-11-02","title":"New app edit"}),
    );
    db.write(|c| work::import_legacy(c, &tables, &mappings, "source", true))
        .unwrap();
    assert_eq!(
        run(&db, json!({"action":"detail","item":id}))["item"]["title"],
        "New app edit"
    );
    assert_eq!(
        run(&db, json!({"action":"list"}))["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}
