//! The opt-in bridge preserves core legacy reporting and rejects browser/private routes.
mod common;

use common::{app, binary, TempDir};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::path::Path;
use std::process::{Child, Stdio};
use std::time::Duration;

struct Bridge {
    child: Child,
    address: String,
}
impl Bridge {
    fn start(db: &Path) -> Self {
        let mut child = binary()
            .arg("--db")
            .arg(db)
            .args(["serve", "--listen", "127.0.0.1:0"])
            .stderr(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stderr.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let address = line
            .split("http://")
            .nth(1)
            .and_then(|s| s.split(' ').next())
            .unwrap_or_else(|| panic!("bridge did not start: {line}"))
            .to_string();
        Self { child, address }
    }

    fn raw(&self, request: &str) -> (u16, Value) {
        let mut stream = TcpStream::connect(&self.address).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        stream.shutdown(Shutdown::Write).unwrap();
        let mut raw = String::new();
        stream.read_to_string(&mut raw).unwrap();
        let status = raw.split(' ').nth(1).unwrap().parse().unwrap();
        let (_, body) = raw.split_once("\r\n\r\n").unwrap();
        (status, serde_json::from_str(body).unwrap())
    }

    fn get(&self, path: &str, extra: &str) -> (u16, Value) {
        self.raw(&format!(
            "GET {path} HTTP/1.1\r\nHost: {}\r\n{extra}\r\n",
            self.address
        ))
    }

    fn post(&self, path: &str, body: Value) -> (u16, Value) {
        let body = body.to_string();
        self.raw(&format!("POST {path} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nX-Ledger-Client: remote\r\n\r\n{body}",self.address,body.len()))
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn legacy_reports_and_once_only_messages_share_the_apps_database() {
    let temp = TempDir::new("http-reporting");
    let db = temp.join("ledger.db");
    let bridge = Bridge::start(&db);
    assert_eq!(
        bridge.get("/api/health", "").1["compatibility"],
        "experimental"
    );
    let (status,result)=bridge.post("/api/report",json!({"project":"Example App","session":"legacy-client-1","event":"start","kind":"research","title":"Cache study","base":"1.0.0","summary":"Compare cache behavior"}));
    assert_eq!(status, 200, "{result}");
    assert_eq!(result["session"]["base_current"], "1.0.0");
    assert_eq!(result["session"]["status_label"], "active");
    assert!(result["session"]["verdict_label"].is_string());
    let question=bridge.post("/api/report",json!({"session":"legacy-client-1","event":"question","summary":"Choose size","question":"Which cache size?"})).1["item_ids"][0].clone();
    app(
        &db,
        "human",
        json!({"action":"answer","sessionId":"legacy-client-1","questionId":question,"answer":"Keep the small cache"}),
    );
    let ordinary = bridge.get("/api/session/legacy-client-1?deliver=1", "").1;
    assert_eq!(ordinary["messages"], json!([]));
    assert_eq!(ordinary["items"][0]["answer"], "Keep the small cache");
    let delivered = bridge
        .get(
            "/api/session/legacy-client-1?deliver=1",
            "X-Ledger-Client: remote\r\n",
        )
        .1;
    assert_eq!(delivered["messages"].as_array().unwrap().len(), 1);
    assert!(delivered["messages"][0]
        .as_str()
        .unwrap()
        .contains("Keep the small cache"));
    assert_eq!(
        bridge
            .get(
                "/api/session/legacy-client-1?deliver=1",
                "X-Ledger-Client: remote\r\n"
            )
            .1["messages"],
        json!([])
    );
    let overview = bridge.get("/api/overview?project=Example+App", "").1;
    assert_eq!(overview["project"], "Example App");
    assert_eq!(overview["trunk_recent"][0]["version"], "1.0.0");
    assert!(overview["open"][0]["open_items"].is_number());
    assert!(delivered["events"][0]["artifacts"].is_array());
}

#[test]
fn bridge_rejects_cross_site_requests_and_private_operations() {
    let temp = TempDir::new("http-guards");
    let db = temp.join("ledger.db");
    let bridge = Bridge::start(&db);
    app(
        &db,
        "notebook",
        json!({"action":"save","title":"Private note","body":"private-notebook-marker"}),
    );
    assert_eq!(
        bridge
            .raw("GET /api/health HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
            .0,
        403
    );
    assert_eq!(
        bridge
            .get("/api/health", "Origin: https://example.com\r\n")
            .0,
        403
    );
    assert_eq!(bridge.get("/api/health", "Origin: null\r\n").0, 403);
    assert_eq!(
        bridge
            .get("/api/health", "Sec-Fetch-Site: cross-site\r\n")
            .0,
        403
    );
    assert_eq!(
        bridge
            .get("/api/health", "Sec-Fetch-Site: same-origin\r\n")
            .0,
        200
    );
    assert_eq!(bridge.get("/api/notes", "").0, 404);
    assert_eq!(bridge.get("/api/notebook", "").0, 404);
    assert_eq!(
        bridge
            .post("/api/human", json!({"action":"archive","sessionId":"any"}))
            .0,
        404
    );
    assert_eq!(
        bridge
            .post(
                "/api/documents",
                json!({"action":"set_roots","roots":["/"]})
            )
            .0,
        404
    );
    assert_eq!(bridge.get("/api/settings", "").0, 404);
    let state = bridge.get("/api/state", "");
    assert_eq!(state.0, 200);
    assert!(!state.1.to_string().contains("private-notebook-marker"));
    assert_eq!(bridge.get("/api/session/%XX", "").0, 400);
    assert_eq!(bridge.raw(&format!("POST /api/report HTTP/1.1\r\nHost: {}\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{{}}",bridge.address)).0,415);
    assert_eq!(bridge.raw(&format!("POST /api/report HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: 2097153\r\n\r\n",bridge.address)).0,413);
    assert_eq!(bridge.raw(&format!("POST /api/report HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{{}}",bridge.address)).0,400);
    assert_eq!(bridge.raw(&format!("POST /api/report HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n",bridge.address)).0,400);
    assert_eq!(bridge.post("/api/report", json!([])).0, 400);
}

#[test]
fn bridge_refuses_a_lan_bind_without_creating_a_database() {
    let temp = TempDir::new("http-loopback");
    let db = temp.join("not-created.db");
    let output = binary()
        .arg("--db")
        .arg(&db)
        .args(["serve", "--listen", "0.0.0.0:8765"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!db.exists());
    assert!(String::from_utf8_lossy(&output.stderr).contains("loopback"));
}
