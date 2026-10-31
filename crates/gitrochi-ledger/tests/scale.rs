//! Timings on the large demo (1,000 sessions, 50,000 events). The bounds only catch
//! accidents such as a quadratic loop; the measurements are printed
//! (`cargo test --release -p gitrochi-ledger --test scale -- --nocapture`).

mod common;

use common::{app, TempDir};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

fn timed(label: &str, limit: Duration, work: impl Fn() -> Value) -> Value {
    // The first run warms the connection and the page cache; the median of five is reported.
    let mut result = work();
    let mut runs = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        result = work();
        runs.push(start.elapsed());
    }
    runs.sort();
    let median = runs[2];
    let bytes = serde_json::to_vec(&result).map(|v| v.len()).unwrap_or(0);
    eprintln!(
        "{label:<34} {:>9.1} ms  {:>9} bytes",
        median.as_secs_f64() * 1000.0,
        bytes
    );
    let limit = if cfg!(debug_assertions) {
        limit * 10
    } else {
        limit
    };
    assert!(median < limit, "{label} took {median:?} (limit {limit:?})");
    result
}

#[test]
fn state_and_graph_on_a_thousand_sessions_and_fifty_thousand_events() {
    let dir = TempDir::new("scale");
    let db = dir.join("large.sqlite3");
    let started = Instant::now();
    let opened = gitrochi_ledger::Db::open(&db).unwrap();
    let summary =
        gitrochi_ledger::demo::seed(&opened, gitrochi_ledger::util::now_ms(), true).unwrap();
    eprintln!(
        "large demo: {} sessions, {} events, written in {:.1} s",
        summary.sessions,
        summary.events,
        started.elapsed().as_secs_f64()
    );
    assert!(
        summary.sessions >= 1_000 && summary.events >= 50_000,
        "{summary:?}"
    );
    let project = json!("Large Demo");
    let second = Duration::from_secs(1);

    timed("rev", second / 10, || app(&db, "rev", json!({})));
    let state = timed("state (one project, all)", 3 * second, || {
        app(&db, "state", json!({"project": project, "range": "all"}))
    });
    assert!(state["sessions"].as_array().unwrap().len() >= 1_000);
    timed("state (one project, 7d)", 3 * second, || {
        app(&db, "state", json!({"project": project, "range": "7d"}))
    });
    timed("state (every project, all)", 3 * second, || {
        app(&db, "state", json!({"range": "all"}))
    });
    timed("attention", 2 * second, || {
        app(&db, "attention", json!({"project": project}))
    });
    let week = timed("graph (7d)", 3 * second, || {
        app(&db, "graph", json!({"project": project, "range": "7d"}))
    });
    timed("graph (30d)", 3 * second, || {
        app(&db, "graph", json!({"project": project, "range": "30d"}))
    });
    // Archived sessions too: every one of the 50,000 events becomes a node.
    let all = timed("graph (all, archived too)", 6 * second, || {
        app(
            &db,
            "graph",
            json!({"project": project, "range": "all", "includeArchived": true}),
        )
    });
    timed("graph (all, key events)", 6 * second, || {
        app(
            &db,
            "graph",
            json!({"project": project, "range": "all", "keyOnly": true}),
        )
    });
    timed("session detail", second / 2, || {
        app(&db, "session", json!({"id": "L0500"}))
    });
    timed("search (two words)", 2 * second, || {
        app(
            &db,
            "search",
            json!({"project": project, "query": "step session"}),
        )
    });
    timed("overview", 3 * second, || {
        app(&db, "overview", json!({"project": project}))
    });

    // The same database lays out the same graph (`from` and `to` follow the clock).
    let layout = |mut graph: Value| {
        graph["from"] = Value::Null;
        graph["to"] = Value::Null;
        serde_json::to_string(&graph).unwrap()
    };
    let again = app(
        &db,
        "graph",
        json!({"project": project, "range": "all", "includeArchived": true}),
    );
    assert!(
        layout(all.clone()) == layout(again),
        "the graph changed between two calls"
    );
    let again = app(&db, "graph", json!({"project": project, "range": "7d"}));
    assert!(
        layout(week.clone()) == layout(again),
        "the 7-day graph changed between two calls"
    );
    assert!(all["nodes"].as_array().unwrap().len() >= 50_000);
    assert!(all["lanes"].as_u64().unwrap() > 1);
    common::Schemas::load().check("graph.schema.json", &week);
    common::Schemas::load().check("state.schema.json", &state);
}
