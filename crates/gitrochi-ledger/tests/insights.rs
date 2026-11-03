//! Insights: question waits, automatic answers, sessions and reports over a period, as
//! counts and durations only.
mod common;

use common::{app, cli, json_of, stderr, stdout, Schemas, TempDir};
use gitrochi_ledger::{call_as, util::now_ms, Caller};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const HOUR: i64 = 3_600_000;
const DAY: i64 = 24 * HOUR;

fn report(db: &Path, project: &str, fields: Value) -> Value {
    let mut fields = fields;
    fields["project"] = json!(project);
    app(db, "report", fields)
}

fn question_ids(db: &Path, session: &str) -> Vec<i64> {
    app(db, "session", json!({"id": session}))["questions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| q["id"].as_i64().unwrap())
        .collect()
}

/// Two projects; in Example App questions settled after one and four hours, one settled
/// ten days ago, one closed by its agent and one open for three hours; three automatic
/// answers (reviewed, corrected, waiting); a stale session nobody reported on.
fn ledger(temp: &TempDir) -> PathBuf {
    let db = temp.join("ledger.sqlite3");
    let now = now_ms();
    for (id, kind) in [
        ("impl-a", "implementation"),
        ("research-b", "research"),
        ("decide-c", "decision"),
    ] {
        report(
            &db,
            "Example App",
            json!({"session": id, "event": "start", "kind": kind, "title": id, "summary": "Started"}),
        );
    }
    report(
        &db,
        "Docs Site",
        json!({"session": "docs-d", "event": "start", "kind": "document", "title": "Guide", "summary": "Started"}),
    );
    report(
        &db,
        "Example App",
        json!({"session": "research-b", "event": "question", "summary": "Asked", "questions": ["One?", "Two?", "Three?", "Four?", "Five?"]}),
    );
    let q = question_ids(&db, "research-b");
    app(
        &db,
        "human",
        json!({"action": "answer", "sessionId": "research-b", "questionId": q[0], "answer": "PRIVATE ANSWER"}),
    );
    app(
        &db,
        "human",
        json!({"action": "dismiss", "sessionId": "research-b", "questionId": q[1]}),
    );
    app(
        &db,
        "human",
        json!({"action": "answer", "sessionId": "research-b", "questionId": q[2], "answer": "Old"}),
    );
    report(
        &db,
        "Example App",
        json!({"session": "research-b", "event": "progress", "summary": "Settled it myself", "resolves": [q[3]]}),
    );
    let c = Connection::open(&db).unwrap();
    let set = |id: i64, created: i64, answered: Option<i64>| {
        c.execute(
            "UPDATE questions SET created_at = ?2, answered_at = COALESCE(?3, answered_at) WHERE id = ?1",
            params![id, created, answered],
        )
        .unwrap();
    };
    set(q[0], now - 2 * HOUR, Some(now - HOUR));
    set(q[1], now - 5 * HOUR, Some(now - HOUR));
    set(q[2], now - 11 * DAY, Some(now - 10 * DAY));
    set(q[4], now - 3 * HOUR, None);
    // automatic answers: reviewed, corrected (a person's message before the review), waiting
    let message_at = now_ms();
    app(
        &db,
        "human",
        json!({"action": "message", "sessionId": "impl-a", "text": "PRIVATE CORRECTION"}),
    );
    for (kind, reviewed) in [
        ("permission", Some(now - 30 * 60_000)),
        ("permission", Some(message_at + 60_000)),
        ("stop_question", None),
    ] {
        c.execute(
            "INSERT INTO pending_prompts (session_id, kind, payload, created_at, deadline, state,
                 answered_by, answered_at, reviewed_at)
             VALUES ('impl-a', ?1, '{}', ?2, ?2, 'auto', 'auto', ?3, ?4)",
            params![kind, now - 2 * HOUR, now - HOUR, reviewed],
        )
        .unwrap();
    }
    // a session quiet for a week whose agent never reported, and an old report
    c.execute(
        "UPDATE sessions SET last_at = ?1, last_agent_at = NULL, created_at = ?1 WHERE id = 'decide-c'",
        [now - 7 * DAY],
    )
    .unwrap();
    c.execute(
        "INSERT INTO events (session_id, project, ts, type, actor, summary)
         VALUES ('impl-a', 'Example App', ?1, 'progress', 'agent', 'Long ago')",
        [now - 40 * DAY],
    )
    .unwrap();
    db
}

#[test]
fn waits_answers_sessions_and_reports_for_a_project() {
    let temp = TempDir::new("insights");
    let db = ledger(&temp);
    let insights = app(
        &db,
        "insights",
        json!({"project": "Example App", "range": "7d"}),
    );
    Schemas::load().check("insights.schema.json", &insights);
    assert_eq!(insights["range"], "7d");
    let q = &insights["questions"];
    assert_eq!(
        (q["answered"].as_i64(), q["dismissed"].as_i64()),
        (Some(1), Some(1))
    );
    assert_eq!(q["resolvedByAgent"], 1);
    assert_eq!(q["wait"]["count"], 2);
    let near = |value: &Value, expected: i64| {
        let value = value.as_i64().unwrap();
        assert!((value - expected).abs() < 60_000, "{value} vs {expected}");
    };
    near(&q["wait"]["medianMs"], HOUR);
    near(&q["wait"]["p90Ms"], 4 * HOUR);
    assert_eq!(q["open"]["count"], 1);
    near(&q["open"]["maxMs"], 3 * HOUR);

    let auto = &insights["autoAnswers"];
    assert_eq!(
        (
            auto["total"].as_i64(),
            auto["reviewed"].as_i64(),
            auto["corrected"].as_i64(),
            auto["unreviewed"].as_i64()
        ),
        (Some(3), Some(2), Some(1), Some(1))
    );
    let kinds: Vec<&str> = auto["byKind"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| k["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["permission", "stop_question"]);
    assert_eq!(auto["byKind"][0]["corrected"], 1);

    let sessions = &insights["sessions"];
    assert_eq!(sessions["total"], 3);
    let by_verdict: i64 = sessions["byVerdict"]
        .as_object()
        .unwrap()
        .values()
        .map(|v| v.as_i64().unwrap())
        .sum();
    assert_eq!(by_verdict, 3);
    assert_eq!(sessions["byVerdict"]["needs_human"], 1);
    assert_eq!(sessions["byRole"]["implementation"], 1);
    assert_eq!(sessions["byRole"]["document"], 0);
    assert_eq!(
        (
            sessions["stale"].as_i64(),
            sessions["staleUnreported"].as_i64()
        ),
        (Some(1), Some(1))
    );

    let days = insights["reportsPerDay"].as_array().unwrap();
    assert_eq!(days.len(), 7);
    let today: i64 = days.last().unwrap()["reports"].as_i64().unwrap();
    assert!(today >= 5, "{insights}");
    assert_eq!(
        days.iter()
            .map(|d| d["reports"].as_i64().unwrap())
            .sum::<i64>(),
        insights["reports"].as_i64().unwrap()
    );
    for private in [
        "PRIVATE ANSWER",
        "PRIVATE CORRECTION",
        "One?",
        "Settled it myself",
    ] {
        assert!(!insights.to_string().contains(private), "{private} leaked");
    }
}

#[test]
fn the_period_and_project_choose_what_counts() {
    let temp = TempDir::new("insights-range");
    let db = ledger(&temp);
    let month = app(
        &db,
        "insights",
        json!({"project": "Example App", "range": "30d"}),
    );
    assert_eq!(month["questions"]["answered"], 2);
    assert_eq!(month["reportsPerDay"].as_array().unwrap().len(), 30);
    let all = app(
        &db,
        "insights",
        json!({"project": "Example App", "range": "all"}),
    );
    Schemas::load().check("insights.schema.json", &all);
    assert!(all.get("from").is_none());
    assert_eq!(all["reportsPerDay"].as_array().unwrap().len(), 90);
    assert_eq!(
        all["reports"].as_i64().unwrap(),
        month["reports"].as_i64().unwrap() + 1
    );
    let docs = app(
        &db,
        "insights",
        json!({"project": "Docs Site", "range": "7d"}),
    );
    assert_eq!(docs["sessions"]["total"], 1);
    assert_eq!(docs["questions"]["asked"], 0);
    assert_eq!(docs["autoAnswers"]["total"], 0);
    let everything = app(&db, "insights", json!({}));
    assert_eq!(everything["range"], "7d");
    assert!(everything.get("project").is_none());
    assert_eq!(everything["sessions"]["total"], 4);

    let empty = temp.join("empty.sqlite3");
    let nothing = app(&empty, "insights", json!({"range": "30d"}));
    Schemas::load().check("insights.schema.json", &nothing);
    assert_eq!(nothing["sessions"]["total"], 0);
    assert!(nothing["questions"]["wait"].get("medianMs").is_none());

    let mut args = json!({"range": "1y"});
    args["db"] = json!(db);
    assert_eq!(
        call_as(Caller::App, "insights", &args).unwrap_err().code,
        "INVALID_ARGUMENT"
    );
    let mut args = json!({"project": "Example App"});
    args["db"] = json!(db);
    assert!(call_as(Caller::Agent, "insights", &args).is_ok());
}

#[test]
fn the_command_line_summarises_them() {
    let temp = TempDir::new("insights-cli");
    let db = ledger(&temp);
    let output = cli(&db, &["insights", "-p", "Example App", "--range", "30d"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    assert!(
        text.contains("Questions:") && text.contains("Automatic answers:"),
        "{text}"
    );
    let output = cli(&db, &["--json", "insights"]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(json_of(&output)["range"], "7d");
}
