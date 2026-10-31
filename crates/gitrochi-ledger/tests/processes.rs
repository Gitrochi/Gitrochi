//! Several real processes writing one database at once (the apps, the CLI and the MCP
//! servers of different agents do exactly that).

mod common;

use common::{app, binary, cli, TempDir};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::Write;
use std::process::Stdio;

#[test]
fn mcp_servers_in_several_processes_write_at_once() {
    const PROCESSES: usize = 4;
    const REPORTS: usize = 60;
    let dir = TempDir::new("processes");
    let db = dir.join("ledger.sqlite3");
    app(
        &db,
        "register_baseline",
        json!({"project": "Example App", "version": "1.0.0"}),
    );
    app(
        &db,
        "report",
        json!({"project": "Example App", "event": "start", "title": "shared", "session": "shared-1"}),
    );
    let rev_before = app(&db, "rev", json!({}))["rev"].as_i64().unwrap();

    // Start every server before feeding any of them, so their writes overlap.
    let mut children: Vec<_> = (0..PROCESSES)
        .map(|_| {
            binary()
                .arg("--db")
                .arg(&db)
                .arg("mcp")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    let writers: Vec<_> = children
        .iter_mut()
        .enumerate()
        .map(|(p, child)| {
            let mut input = child.stdin.take().unwrap();
            std::thread::spawn(move || {
                let mut lines = vec![
                    json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}),
                    json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                ];
                for i in 0..REPORTS {
                    lines.push(json!({"jsonrpc": "2.0", "id": 2 * i + 1, "method": "tools/call", "params": {
                        "name": "ledger_report",
                        "arguments": {"project": "Example App", "event": "start", "title": format!("p{p}-{i}"), "base": "1.0.0", "summary": "s"}}}));
                    lines.push(json!({"jsonrpc": "2.0", "id": 2 * i + 2, "method": "tools/call", "params": {
                        "name": "ledger_report",
                        "arguments": {"session": "shared-1", "event": "progress", "summary": format!("p{p}-{i}"), "touches": [format!("file-{p}")]}}}));
                }
                for line in lines {
                    writeln!(input, "{line}").unwrap();
                }
            })
        })
        .collect();
    for writer in writers {
        writer.join().unwrap();
    }
    let mut issued = HashSet::new();
    for child in children {
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let responses: Vec<Value> = String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(responses.len(), 1 + 2 * REPORTS);
        for response in &responses[1..] {
            let result = &response["result"];
            assert_eq!(result["isError"], false, "{response}");
            let text = result["content"][0]["text"].as_str().unwrap();
            if response["id"].as_i64().unwrap() % 2 == 1 {
                assert!(
                    issued.insert(text.split_whitespace().nth(2).unwrap().to_string()),
                    "an ID was issued twice"
                );
            }
        }
    }
    assert_eq!(issued.len(), PROCESSES * REPORTS);
    let detail = app(&db, "session", json!({"id": "shared-1"}));
    let progress = detail["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["type"] == "progress")
        .count();
    assert_eq!(progress, PROCESSES * REPORTS, "no report was lost");
    assert_eq!(
        detail["session"]["touches"].as_array().unwrap().len(),
        PROCESSES,
        "touches merged as a set"
    );
    let state = app(&db, "state", json!({"range": "all"}));
    assert_eq!(
        state["sessions"].as_array().unwrap().len(),
        PROCESSES * REPORTS + 1
    );
    assert_eq!(
        state["rev"].as_i64().unwrap(),
        rev_before + (2 * PROCESSES * REPORTS) as i64,
        "one rev per write"
    );
}

#[test]
fn command_line_reports_from_many_processes() {
    let dir = TempDir::new("processes-cli");
    let db = dir.join("ledger.sqlite3");
    app(
        &db,
        "report",
        json!({"project": "Example App", "event": "start", "title": "target", "session": "target-1"}),
    );
    let children: Vec<_> = (0..12)
        .map(|i| {
            binary()
                .args([
                    "--db",
                    db.to_str().unwrap(),
                    "report",
                    "-s",
                    "target-1",
                    "-e",
                    "artifact",
                    "-m",
                ])
                .arg(format!("artifact {i}"))
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    for child in children {
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let detail = app(&db, "session", json!({"id": "target-1"}));
    assert_eq!(
        detail["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == "artifact")
            .count(),
        12
    );
    let output = cli(&db, &["call", "rev"]);
    assert_eq!(common::json_of(&output)["rev"], 13);
}
