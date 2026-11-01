//! The MCP server over stdio, as Claude Code runs it: a real process, one JSON-RPC message
//! per line.

mod common;

use common::{app, binary, TempDir};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Stdio};

struct Server {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}

impl Server {
    fn start(db: &std::path::Path) -> Server {
        let mut child = binary()
            .arg("--db")
            .arg(db)
            .arg("mcp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Server {
            child,
            input,
            output,
        }
    }

    fn send(&mut self, message: &Value) {
        writeln!(self.input, "{message}").unwrap();
        self.input.flush().unwrap();
    }

    fn send_raw(&mut self, line: &str) {
        writeln!(self.input, "{line}").unwrap();
        self.input.flush().unwrap();
    }

    fn receive(&mut self) -> Value {
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON-RPC ({e}): {line:?}"))
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        let response = self.receive();
        assert_eq!(response["id"], id, "{response}");
        response
    }

    fn tool(&mut self, id: i64, name: &str, arguments: Value) -> (bool, String) {
        let response = self.request(
            id,
            "tools/call",
            json!({"name": name, "arguments": arguments}),
        );
        let result = &response["result"];
        (
            result["isError"] == json!(true),
            result["content"][0]["text"].as_str().unwrap().to_string(),
        )
    }

    fn finish(mut self) -> Vec<String> {
        drop(self.input);
        let mut rest = Vec::new();
        for line in self.output.lines() {
            rest.push(line.unwrap());
        }
        assert!(self.child.wait().unwrap().success());
        rest
    }
}

#[test]
fn a_full_conversation() {
    let dir = TempDir::new("mcp");
    let db = dir.join("ledger.sqlite3");
    app(
        &db,
        "register_baseline",
        json!({"project": "Example App", "version": "1.0.0"}),
    );
    let mut server = Server::start(&db);

    let early = server.request(1, "tools/list", json!({}));
    assert_eq!(early["error"]["code"], -32002, "tools before initialize");
    let init = server.request(
        2,
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}),
    );
    let result = &init["result"];
    assert_eq!(result["protocolVersion"], "2025-06-18");
    assert_eq!(result["serverInfo"]["name"], "gitrochi-ledger");
    assert_eq!(result["capabilities"]["tools"]["listChanged"], false);
    assert!(result["instructions"]
        .as_str()
        .unwrap()
        .contains("ledger_overview"));
    let twice = server.request(3, "initialize", json!({"protocolVersion": "2025-06-18"}));
    assert_eq!(twice["error"]["code"], -32602);
    server.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
    assert_eq!(server.request(4, "ping", json!({}))["result"], json!({}));

    let tools = server.request(5, "tools/list", json!({}));
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        ["ledger_overview", "ledger_report", "ledger_session"]
    );
    for tool in tools["result"]["tools"].as_array().unwrap() {
        assert_eq!(tool["inputSchema"]["type"], "object");
        assert!(tool["description"].as_str().unwrap().len() > 40);
    }

    let (error, text) = server.tool(
        6,
        "ledger_report",
        json!({"project": "Example App", "event": "start", "kind": "research", "title": "MCP session", "base": "1.0.0", "summary": "s"}),
    );
    assert!(!error, "{text}");
    assert!(text.starts_with("Recorded ✓ S"), "{text}");
    let id = text.split_whitespace().nth(2).unwrap().to_string();
    let (error, text) = server.tool(7, "ledger_overview", json!({"project": "Example App"}));
    assert!(!error);
    assert!(text.starts_with("[Example App] HEAD 1.0.0"), "{text}");
    assert!(text.contains("MCP session"));
    let (error, text) = server.tool(
        8,
        "ledger_report",
        json!({"event": "start", "summary": "no project"}),
    );
    assert!(error);
    assert!(text.contains("needs a project"), "{text}");
    let (error, _) = server.tool(9, "ledger_unknown", json!({}));
    assert!(error);

    // A person writes in the app; the session's own read hands it over once.
    app(
        &db,
        "human",
        json!({"action": "message", "sessionId": id, "text": "Please add tests"}),
    );
    let (_, text) = server.tool(10, "ledger_session", json!({"session": id}));
    assert!(
        text.contains("[Note from a person] Please add tests"),
        "{text}"
    );
    let (_, text) = server.tool(11, "ledger_session", json!({"session": id}));
    assert!(!text.contains("From a person"));
    app(
        &db,
        "human",
        json!({"action": "message", "sessionId": id, "text": "And docs"}),
    );
    let (_, text) = server.tool(12, "ledger_overview", json!({"project": "Example App"}));
    assert!(
        !text.contains("And docs"),
        "without the session nothing is delivered"
    );
    let (_, text) = server.tool(
        13,
        "ledger_report",
        json!({"session": id, "event": "progress", "summary": "going"}),
    );
    assert!(text.contains("[Note from a person] And docs"), "{text}");

    assert_eq!(
        server.request(14, "resources/list", json!({}))["error"]["code"],
        -32601
    );
    server.send_raw("{not json");
    let parse = server.receive();
    assert_eq!(
        (parse["id"].clone(), parse["error"]["code"].clone()),
        (Value::Null, json!(-32700))
    );
    server.send(
        &json!({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1}}),
    );
    server.send(&json!({"jsonrpc": "1.0", "id": 15, "method": "ping"}));
    assert_eq!(server.receive()["error"]["code"], -32600);
    // Nothing else was written to stdout: every line was a response to a request.
    assert!(server.finish().is_empty());
}

#[test]
fn unknown_protocol_versions_get_the_newest_and_the_session_comes_from_the_environment() {
    let dir = TempDir::new("mcp-env");
    let db = dir.join("ledger.sqlite3");
    let reply = app(
        &db,
        "report",
        json!({"project": "Example App", "event": "start", "title": "launched", "session": "launch-1"}),
    );
    assert_eq!(reply["sessionId"], "launch-1");
    let mut child = binary()
        .env("GITROCHI_LEDGER_SESSION", "launch-1")
        .arg("--db")
        .arg(&db)
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "ledger_report",
               "arguments": {"event": "artifact", "summary": "made", "artifacts": [{"name": "report"}]}}}),
    ] {
        writeln!(input, "{message}").unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    let lines: Vec<Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines[0]["result"]["protocolVersion"], "2025-11-25");
    let text = lines[1]["result"]["content"][0]["text"].as_str().unwrap();
    assert!(text.starts_with("Recorded ✓ launch-1 · artifact"), "{text}");
}

#[test]
fn the_ledger_turned_off_answers_with_tool_errors() {
    let dir = TempDir::new("mcp-off");
    let db = dir.join("ledger.sqlite3");
    let mut child = binary()
        .env("GITROCHI_LEDGER", "0")
        .arg("--db")
        .arg(&db)
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "ledger_overview", "arguments": {}}}),
    ] {
        writeln!(input, "{message}").unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    let last: Value = serde_json::from_str(
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(last["result"]["isError"], true);
    assert!(last["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("turned off"));
    assert!(!db.exists());
}
