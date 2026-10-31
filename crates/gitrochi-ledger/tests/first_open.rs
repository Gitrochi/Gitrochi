//! The first open of a brand-new ledger, from many threads and from separate processes at
//! the same moment — what happens when the app, a hook and an agent's MCP server start
//! together on a new machine. Every opener must succeed. `LEDGER_STRESS_ROUNDS` repeats
//! the rounds (default 20) for a longer run.

mod common;

use common::{binary, TempDir};
use gitrochi_ledger::Db;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::Stdio;
use std::sync::{Arc, Barrier};

const THREADS: usize = 12;
const PROCESSES: usize = 6;

fn rounds() -> usize {
    std::env::var("LEDGER_STRESS_ROUNDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20)
}

/// The schema was created once and completely.
fn check_schema(path: &std::path::Path) {
    let connection = rusqlite::Connection::open(path).unwrap();
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    let mode: String = connection
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    let rows: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM meta WHERE key IN ('rev', 'created')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        (version, mode.as_str(), rows),
        (1, "wal", 2),
        "{}",
        path.display()
    );
}

#[test]
fn threads_open_a_new_ledger_at_the_same_moment() {
    let dir = TempDir::new("first-open-threads");
    let rounds = rounds();
    let mut failures = Vec::new();
    for round in 0..rounds {
        let path = dir.join(&format!("round-{round}.sqlite3"));
        let barrier = Arc::new(Barrier::new(THREADS));
        let handles: Vec<_> = (0..THREADS)
            .map(|_| {
                let (path, barrier) = (path.clone(), barrier.clone());
                std::thread::spawn(move || {
                    barrier.wait();
                    Db::open(&path).and_then(|db| db.rev())
                })
            })
            .collect();
        for handle in handles {
            if let Err(error) = handle.join().unwrap() {
                failures.push(format!("round {round}: {error}"));
            }
        }
        check_schema(&path);
    }
    eprintln!(
        "threads: {} of {} opens failed",
        failures.len(),
        rounds * THREADS
    );
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn processes_open_a_new_ledger_at_the_same_moment() {
    let dir = TempDir::new("first-open-processes");
    let rounds = rounds();
    let mut failures = Vec::new();
    for round in 0..rounds {
        let path = dir.join(&format!("round-{round}.sqlite3"));
        // MCP servers open the database on their first tool call, so every process is
        // started and initialized first, then all of them get the call at once.
        let mut servers: Vec<_> = (0..PROCESSES)
            .map(|_| {
                let mut child = binary()
                    .arg("--db")
                    .arg(&path)
                    .arg("mcp")
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .spawn()
                    .unwrap();
                let mut input = child.stdin.take().unwrap();
                let mut output = BufReader::new(child.stdout.take().unwrap());
                for message in [
                    json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}),
                    json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                ] {
                    writeln!(input, "{message}").unwrap();
                }
                let mut line = String::new();
                output.read_line(&mut line).unwrap();
                (child, input, output)
            })
            .collect();
        let call = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                          "params": {"name": "ledger_overview", "arguments": {"project": "Example App"}}});
        for (_, input, _) in &mut servers {
            writeln!(input, "{call}").unwrap();
        }
        for (mut child, input, mut output) in servers {
            let mut line = String::new();
            output.read_line(&mut line).unwrap();
            drop(input);
            child.wait().unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["result"]["isError"] != json!(false) {
                failures.push(format!(
                    "round {round}: {}",
                    reply["result"]["content"][0]["text"]
                ));
            }
        }
        check_schema(&path);
    }
    eprintln!(
        "processes: {} of {} opens failed",
        failures.len(),
        rounds * PROCESSES
    );
    assert!(failures.is_empty(), "{failures:#?}");
}
