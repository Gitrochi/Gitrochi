//! `mock.http` 서비스: 경로 · 응답 표로 도는 결정적 가짜 HTTP 서버. 엔진 안의 스레드로 돌아 따로 설치할 것이 없다.
//! 이름 붙은 장애 스위치(지연 · 상태 코드 · 응답 없이 끊기)를 흐름 안에서 켜고 끌 수 있고(`mock.fault`),
//! 받은 요청을 기록해 기대한 호출이 왔는지 판정한다(`check.mock`).
//!
//! 표는 `with.routes` · `with.faults` 또는 `with.dir`(기본 `.gitch/mocks/<서비스>`)의 `routes.yml`:
//! ```yaml
//! routes:
//!   - { method: GET, path: /health, status: 200, body: ok }
//!   - { method: POST, path: /charge, status: 201, json: { id: ch_1 } }
//! faults:
//!   slow: [{ path: /charge, delay: 3s }]
//!   down: [{ path: "*", status: 503 }]
//!   drop: [{ path: /charge, drop: true }]
//! ```
//! 제어 주소(`/__gitch/…`): `GET requests` · `POST faults {"on":[…],"off":[…]}` · `POST reset` · `GET health`.

use crate::util::{self, tr};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct Rule {
    pub method: Option<String>,
    pub path: String,
    pub status: Option<u16>,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
    pub delay_ms: u64,
    pub drop: bool,
}

#[derive(Debug, Clone, Default)]
pub struct Table {
    pub routes: Vec<Rule>,
    pub faults: Vec<(String, Vec<Rule>)>,
}

fn rule_of(v: &Value, base: &Path) -> Result<Rule, String> {
    let o = v
        .as_object()
        .ok_or_else(|| tr("경로 항목은 맵이어야 합니다.", "a route must be a map."))?;
    let path = o
        .get("path")
        .and_then(|p| p.as_str())
        .unwrap_or("*")
        .to_string();
    let body = if let Some(j) = o.get("json") {
        Some(j.to_string())
    } else if let Some(f) = o.get("file").and_then(|f| f.as_str()) {
        let p = base.join(f);
        if !p.starts_with(base) || f.contains("..") {
            return Err(tr(
                &format!("file '{f}' 은(는) 모의 폴더 밖입니다."),
                &format!("file '{f}' is outside the mock folder."),
            ));
        }
        Some(std::fs::read_to_string(&p).map_err(|e| format!("{f}: {e}"))?)
    } else {
        o.get("body").map(crate::expr::to_text)
    };
    let mut headers: Vec<(String, String)> = o
        .get("headers")
        .and_then(|h| h.as_object())
        .map(|h| {
            h.iter()
                .map(|(k, v)| (k.clone(), crate::expr::to_text(v)))
                .collect()
        })
        .unwrap_or_default();
    if o.contains_key("json")
        && !headers
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("content-type"))
    {
        headers.push(("Content-Type".into(), "application/json".into()));
    }
    Ok(Rule {
        method: o
            .get("method")
            .and_then(|m| m.as_str())
            .map(|m| m.to_ascii_uppercase()),
        path,
        status: o.get("status").and_then(|s| s.as_u64()).map(|s| s as u16),
        headers,
        body,
        delay_ms: o
            .get("delay")
            .map(|d| match d {
                Value::String(s) => util::parse_duration(s).unwrap_or(0),
                Value::Number(n) => n.as_u64().unwrap_or(0),
                _ => 0,
            })
            .unwrap_or(0),
        drop: o.get("drop").and_then(|d| d.as_bool()).unwrap_or(false),
    })
}

/// 서비스 입력과 모의 폴더에서 표를 만든다(입력에 적은 것이 폴더 것보다 앞선다).
pub fn load(with: &Value, root: &Path, name: &str) -> Result<Table, String> {
    let dir = root.join(
        with.get("dir")
            .and_then(|d| d.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!(".gitch/mocks/{name}")),
    );
    let mut sources: Vec<(Value, PathBuf)> = vec![(with.clone(), dir.clone())];
    for f in ["routes.yml", "routes.yaml", "routes.json"] {
        let p = dir.join(f);
        if let Ok(text) = std::fs::read_to_string(&p) {
            let v = if f.ends_with(".json") {
                serde_json::from_str(&text).map_err(|e| format!("{}: {e}", p.display()))?
            } else {
                crate::yaml::parse(&text)
                    .map_err(|e| format!("{}:{}: {}", p.display(), e.line, e.message))?
                    .value
            };
            sources.push((v, dir.clone()));
            break;
        }
    }
    let mut t = Table::default();
    for (v, base) in &sources {
        for r in v["routes"].as_array().cloned().unwrap_or_default() {
            t.routes.push(rule_of(&r, base)?);
        }
        if let Some(fs) = v["faults"].as_object() {
            for (fname, rules) in fs {
                if t.faults.iter().any(|(n, _)| n == fname) {
                    continue;
                }
                let list = match rules {
                    Value::Array(a) => a
                        .iter()
                        .map(|r| rule_of(r, base))
                        .collect::<Result<Vec<_>, _>>()?,
                    other => vec![rule_of(other, base)?],
                };
                t.faults.push((fname.clone(), list));
            }
        }
    }
    if t.routes.is_empty() && t.faults.is_empty() {
        return Err(tr(
            &format!(
                "모의 서버 '{name}' 에 경로가 없습니다(with.routes 또는 {}/routes.yml).",
                dir.display()
            ),
            &format!(
                "mock '{name}' has no routes (with.routes or {}/routes.yml).",
                dir.display()
            ),
        ));
    }
    Ok(t)
}

/// `*` 는 아무 글자열, 나머지는 그대로(질의 문자열은 보지 않는다).
pub fn path_matches(pattern: &str, path: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == path;
    }
    let mut rest = path;
    for (i, part) in parts.iter().enumerate() {
        if i == 0 {
            match rest.strip_prefix(part) {
                Some(r) => rest = r,
                None => return false,
            }
        } else if i == parts.len() - 1 {
            return rest.ends_with(part);
        } else {
            match rest.find(part) {
                Some(j) => rest = &rest[j + part.len()..],
                None => return false,
            }
        }
    }
    true
}

fn hits(r: &Rule, method: &str, path: &str) -> bool {
    r.method.as_deref().map(|m| m == method).unwrap_or(true) && path_matches(&r.path, path)
}

struct State {
    table: Table,
    initial_faults: Vec<String>,
    active: Vec<String>,
    requests: Vec<Value>,
}

pub struct Mock {
    pub port: u16,
    stop: Arc<AtomicBool>,
    state: Arc<Mutex<State>>,
    log: PathBuf,
}

impl Mock {
    /// 127.0.0.1(또는 `bind`)의 `port` 에서 듣기 시작한다.
    pub fn start(
        table: Table,
        faults: Vec<String>,
        bind: &str,
        port: u16,
        log: PathBuf,
    ) -> Result<Mock, String> {
        for f in &faults {
            if !table.faults.iter().any(|(n, _)| n == f) {
                return Err(tr(
                    &format!("모르는 장애 스위치: {f}"),
                    &format!("unknown fault switch: {f}"),
                ));
            }
        }
        let l = TcpListener::bind((bind, port)).map_err(|e| format!("{bind}:{port}: {e}"))?;
        let port = l.local_addr().map_err(|e| e.to_string())?.port();
        l.set_nonblocking(true).map_err(|e| e.to_string())?;
        let stop = Arc::new(AtomicBool::new(false));
        let state = Arc::new(Mutex::new(State {
            table,
            initial_faults: faults.clone(),
            active: faults,
            requests: Vec::new(),
        }));
        let (s2, st2, log2) = (stop.clone(), state.clone(), log.clone());
        std::thread::spawn(move || {
            while !s2.load(Ordering::SeqCst) {
                match l.accept() {
                    Ok((conn, _)) => {
                        let (st, lg) = (st2.clone(), log2.clone());
                        std::thread::spawn(move || serve(conn, &st, &lg));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(50)),
                }
            }
        });
        Ok(Mock {
            port,
            stop,
            state,
            log,
        })
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }

    pub fn requests(&self) -> Vec<Value> {
        self.state
            .lock()
            .map(|s| s.requests.clone())
            .unwrap_or_default()
    }

    pub fn log_path(&self) -> &Path {
        &self.log
    }
}

impl Drop for Mock {
    fn drop(&mut self) {
        self.stop();
    }
}

const MAX_HEAD: usize = 64 * 1024;
const MAX_BODY: usize = 10 * 1024 * 1024;

fn serve(conn: TcpStream, st: &Mutex<State>, log: &Path) {
    let _ = conn.set_read_timeout(Some(Duration::from_secs(15)));
    let _ = conn.set_nonblocking(false);
    let Ok(read_half) = conn.try_clone() else {
        return;
    };
    let mut r = BufReader::new(read_half);
    let mut first = String::new();
    if r.read_line(&mut first).unwrap_or(0) == 0 {
        return;
    }
    let mut it = first.split_whitespace();
    let method = it.next().unwrap_or("").to_ascii_uppercase();
    let target = it.next().unwrap_or("/").to_string();
    let (path, query) = target
        .split_once('?')
        .map(|(p, q)| (p.to_string(), q.to_string()))
        .unwrap_or((target.clone(), String::new()));
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut head = first.len();
    loop {
        let mut line = String::new();
        let n = r.read_line(&mut line).unwrap_or(0);
        head += n;
        if n == 0 || head > MAX_HEAD {
            break;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    let len = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok())
        .unwrap_or(0)
        .min(MAX_BODY);
    let mut body = vec![0u8; len];
    let _ = r.read_exact(&mut body);
    let body = String::from_utf8_lossy(&body).into_owned();
    let mut conn = conn;
    // 제어 주소.
    if let Some(cmd) = path.strip_prefix("/__gitch/") {
        let resp = control(cmd, &method, &body, st);
        write_resp(
            &mut conn,
            resp.0,
            &[("Content-Type".into(), "application/json".into())],
            &resp.1.to_string(),
        );
        return;
    }
    let (rule, fault) = {
        let s = st.lock().unwrap_or_else(|e| e.into_inner());
        let fault = s.active.iter().find_map(|name| {
            s.table
                .faults
                .iter()
                .find(|(n, _)| n == name)
                .and_then(|(n, rules)| {
                    rules
                        .iter()
                        .find(|r| hits(r, &method, &path))
                        .map(|r| (n.clone(), r.clone()))
                })
        });
        let route = s
            .table
            .routes
            .iter()
            .find(|r| hits(r, &method, &path))
            .cloned();
        (route, fault)
    };
    let mut status = rule
        .as_ref()
        .and_then(|r| r.status)
        .unwrap_or(if rule.is_some() { 200 } else { 404 });
    let mut headers_out = rule.as_ref().map(|r| r.headers.clone()).unwrap_or_default();
    let mut body_out = rule
        .as_ref()
        .and_then(|r| r.body.clone())
        .unwrap_or_else(|| {
            if rule.is_none() {
                json!({"error": "no mock route", "method": method, "path": path}).to_string()
            } else {
                String::new()
            }
        });
    if rule.is_none() {
        headers_out.push(("Content-Type".into(), "application/json".into()));
    }
    let mut delay = rule.as_ref().map(|r| r.delay_ms).unwrap_or(0);
    let mut dropped = false;
    if let Some((_, f)) = &fault {
        delay = delay.max(f.delay_ms);
        if let Some(s) = f.status {
            status = s;
        }
        if let Some(b) = &f.body {
            body_out = b.clone();
            headers_out = f.headers.clone();
        }
        dropped = f.drop;
    }
    let rec = json!({"at": util::rfc3339(util::now_ms()), "method": method, "path": path, "query": query,
                     "status": if dropped { Value::Null } else { json!(status) }, "fault": fault.as_ref().map(|f| f.0.clone()),
                     "matched": rule.is_some(), "body": body.chars().take(4096).collect::<String>()});
    if let Ok(mut s) = st.lock() {
        if s.requests.len() < 10_000 {
            s.requests.push(rec.clone());
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
    {
        let _ = writeln!(f, "{rec}");
    }
    if delay > 0 {
        std::thread::sleep(Duration::from_millis(delay.min(600_000)));
    }
    if dropped {
        let _ = conn.shutdown(std::net::Shutdown::Both);
        return;
    }
    write_resp(&mut conn, status, &headers_out, &body_out);
}

fn control(cmd: &str, method: &str, body: &str, st: &Mutex<State>) -> (u16, Value) {
    let mut s = st.lock().unwrap_or_else(|e| e.into_inner());
    match (method, cmd) {
        (_, "health") => (200, json!({"ok": true})),
        ("GET", "requests") => (200, Value::Array(s.requests.clone())),
        ("POST", "reset") => {
            s.requests.clear();
            s.active = s.initial_faults.clone();
            (200, json!({"active": s.active}))
        }
        ("POST", "faults") => {
            let v: Value = serde_json::from_str(body).unwrap_or(Value::Null);
            let names = |k: &str| -> Vec<String> {
                v[k].as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|x| x.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default()
            };
            let (set, on, off) = (
                v.get("set").map(|_| names("set")),
                names("on"),
                names("off"),
            );
            let unknown: Vec<String> = set
                .iter()
                .flatten()
                .chain(on.iter())
                .filter(|n| !s.table.faults.iter().any(|(f, _)| f == *n))
                .cloned()
                .collect();
            if !unknown.is_empty() {
                return (400, json!({"error": "unknown fault", "faults": unknown}));
            }
            if let Some(set) = set {
                s.active = set;
            }
            for n in on {
                if !s.active.contains(&n) {
                    s.active.push(n);
                }
            }
            s.active.retain(|n| !off.contains(n));
            (200, json!({"active": s.active}))
        }
        ("GET", "faults") => (
            200,
            json!({"active": s.active, "known": s.table.faults.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>()}),
        ),
        _ => (404, json!({"error": "unknown control"})),
    }
}

fn write_resp(conn: &mut TcpStream, status: u16, headers: &[(String, String)], body: &str) {
    let reason = match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Status",
    };
    let mut out = format!("HTTP/1.1 {status} {reason}\r\n");
    for (k, v) in headers {
        if k.eq_ignore_ascii_case("content-length") || k.eq_ignore_ascii_case("connection") {
            continue;
        }
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str(&format!(
        "Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    ));
    let _ = conn.write_all(out.as_bytes());
    let _ = conn.write_all(body.as_bytes());
    let _ = conn.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_globs() {
        assert!(path_matches("*", "/x"));
        assert!(path_matches("/api/*", "/api/users/1"));
        assert!(path_matches("/api/*/items", "/api/7/items"));
        assert!(!path_matches("/api/*/items", "/api/7/other"));
        assert!(path_matches("/health", "/health"));
        assert!(!path_matches("/health", "/healthz"));
    }

    #[test]
    fn serves_routes_faults_and_control() {
        let with = json!({"routes": [{"method": "GET", "path": "/health", "body": "ok"}, {"method": "POST", "path": "/charge", "status": 201, "json": {"id": "ch_1"}}],
                          "faults": {"down": [{"path": "*", "status": 503}]}});
        let t = load(&with, Path::new("/nonexistent"), "pay").unwrap();
        let log = std::env::temp_dir().join(format!("gf-mock-{}.ndjson", util::random_hex(4)));
        let m = Mock::start(t, vec![], "127.0.0.1", 0, log.clone()).unwrap();
        let base = format!("http://127.0.0.1:{}", m.port);
        let get =
            |p: &str| crate::http::send(&crate::http::Req::get(&format!("{base}{p}"))).unwrap();
        assert_eq!(get("/health").body, "ok");
        assert_eq!(get("/nope").status, 404);
        let post = |p: &str, b: &str| {
            let url = format!("{base}{p}");
            crate::http::send(&crate::http::Req {
                method: "POST",
                body: Some(b.into()),
                ..crate::http::Req::get(&url)
            })
            .unwrap()
        };
        let r = post("/charge", "{}");
        assert_eq!(r.status, 201);
        assert_eq!(r.json().unwrap()["id"], "ch_1");
        assert_eq!(post("/__gitch/faults", "{\"on\": [\"down\"]}").status, 200);
        assert_eq!(get("/health").status, 503);
        assert_eq!(post("/__gitch/faults", "{\"on\": [\"nope\"]}").status, 400);
        assert_eq!(post("/__gitch/faults", "{\"off\": [\"down\"]}").status, 200);
        assert_eq!(get("/health").status, 200);
        let reqs = get("/__gitch/requests").json().unwrap();
        assert!(reqs.as_array().unwrap().len() >= 5);
        assert_eq!(
            m.requests()
                .iter()
                .filter(|r| r["path"] == "/charge")
                .count(),
            1
        );
        m.stop();
        let _ = std::fs::remove_file(log);
    }
}
