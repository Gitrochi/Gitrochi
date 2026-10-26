//! 점검 블록: `check.http` · `check.port` · `check.version`. 스모크의 기본 단위다.
//! 기대한 응답에 닿았는지(S1), 앱이 말하는 빌드가 우리가 기대한 것인지(S2)를 본다.

use super::{schema, Block, Meta, NodeCx, NodeResult};
use crate::http::{self, Req};
use crate::util::tr;
use crate::verify::{self, Outcome, Verdict};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

fn retry_of(v: Option<&Value>) -> (u32, u64) {
    let times = v
        .and_then(|r| r.get("times"))
        .and_then(|t| t.as_u64())
        .unwrap_or(1)
        .clamp(1, 120) as u32;
    let interval = v
        .and_then(|r| r.get("interval"))
        .and_then(|i| match i {
            Value::String(s) => crate::util::parse_duration(s),
            Value::Number(n) => n.as_f64().map(|f| (f * 1000.0) as u64),
            _ => None,
        })
        .unwrap_or(2000);
    (times, interval)
}

/// 취소를 보며 잠깐 쉰다.
fn nap(cx: &NodeCx, ms: u64) -> bool {
    let until = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < until {
        if cx.cancel.is_cancelled() {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

/// 점 경로로 JSON 값 꺼내기(`build.sha`, `items.0.id`).
pub fn dig<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = v;
    for part in path.split('.').filter(|p| !p.is_empty()) {
        cur = match cur {
            Value::Object(o) => o.get(part)?,
            Value::Array(a) => a.get(part.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(cur)
}

fn excerpt(s: &str) -> String {
    let t: String = s.chars().take(200).collect();
    t.replace('\n', " ")
}

// ---------- check.http ----------

pub struct Http;

fn http_inputs() -> Value {
    schema(
        json!({
            "url": {"type": "string", "description": "Address to request. Use base + checks for several paths."},
            "base": {"type": "string"},
            "method": {"type": "string", "default": "GET"},
            "headers": {"type": "object"},
            "body": {"type": "string"},
            "checks": {"type": "array", "items": {"type": "object"}},
            "retry": {"type": "object", "properties": {"times": {"type": "integer"}, "interval": {"type": "string"}}},
            "requestTimeout": {"type": "string", "default": "10s"},
        }),
        &[],
    )
}

static HTTP_META: Meta = Meta {
    id: "check.http",
    version: "1.0.0",
    title: ("HTTP 점검", "HTTP check"),
    category: "check",
    capabilities: &["network"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["VERIFY-01", "VERIFY-02", "VERIFY-03", "VERIFY-04"],
    inputs: http_inputs,
    selects_files: false,
    estimate_ms: 15_000,
};

struct One {
    url: String,
    method: String,
    expect: Value,
    retry: (u32, u64),
}

fn checks_of(with: &Value, node_expect: &Value) -> Result<Vec<One>, String> {
    let method = with
        .get("method")
        .and_then(|m| m.as_str())
        .unwrap_or("GET")
        .to_ascii_uppercase();
    let retry = retry_of(with.get("retry"));
    if let Some(Value::Array(list)) = with.get("checks") {
        let base = with
            .get("base")
            .and_then(|b| b.as_str())
            .unwrap_or("")
            .trim_end_matches('/')
            .to_string();
        let mut out = Vec::new();
        for (i, c) in list.iter().enumerate() {
            let url = match (
                c.get("url").and_then(|u| u.as_str()),
                c.get("path").and_then(|p| p.as_str()),
            ) {
                (Some(u), _) => u.to_string(),
                (None, Some(p)) if !base.is_empty() => {
                    format!("{base}{}{p}", if p.starts_with('/') { "" } else { "/" })
                }
                _ => {
                    return Err(tr(
                        &format!("checks[{i}] 에 url 또는 base + path 가 필요합니다."),
                        &format!("checks[{i}] needs url, or base + path."),
                    ))
                }
            };
            out.push(One {
                url,
                method: c
                    .get("method")
                    .and_then(|m| m.as_str())
                    .map(|m| m.to_ascii_uppercase())
                    .unwrap_or_else(|| method.clone()),
                expect: c.get("expect").cloned().unwrap_or(Value::Null),
                retry: if c.get("retry").is_some() {
                    retry_of(c.get("retry"))
                } else {
                    retry
                },
            });
        }
        return Ok(out);
    }
    match with.get("url").and_then(|u| u.as_str()) {
        Some(u) => Ok(vec![One {
            url: u.to_string(),
            method,
            expect: with
                .get("expect")
                .cloned()
                .unwrap_or_else(|| node_expect.clone()),
            retry,
        }]),
        None => Err(tr("url 또는 checks 가 필요합니다.", "needs url or checks.")),
    }
}

impl Block for Http {
    fn meta(&self) -> &Meta {
        &HTTP_META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        // 표현식이 아직 남아 있을 수 있어 모양만 본다.
        match checks_of(with, &Value::Null) {
            Ok(_) => Vec::new(),
            Err(e) => vec![e],
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 0,
            ..Default::default()
        };
        let checks = match checks_of(&cx.with, &cx.expect.raw) {
            Ok(c) => c,
            Err(e) => {
                r.verdicts.push(Verdict {
                    rule: "S1",
                    title: tr("응답", "response"),
                    observed: e,
                    expected: "-".into(),
                    result: Outcome::Indeterminate,
                    code: Some("VERIFY-03"),
                    phase: "main",
                });
                return r;
            }
        };
        let headers: Vec<(String, String)> = cx
            .with
            .get("headers")
            .and_then(|h| h.as_object())
            .map(|o| {
                o.iter()
                    .map(|(k, v)| (k.clone(), crate::expr::to_text(v)))
                    .collect()
            })
            .unwrap_or_default();
        let body = cx.with.get("body").map(crate::expr::to_text);
        let timeout = cx
            .with
            .get("requestTimeout")
            .and_then(|t| t.as_str())
            .and_then(crate::util::parse_duration)
            .unwrap_or(10_000);
        let mut results = Vec::new();
        for c in checks {
            let mut last_status = None;
            let mut last_err = None;
            let mut last_body = String::new();
            let mut attempts = 0;
            let want_status = c.expect.get("status").cloned().unwrap_or(Value::Null);
            for i in 0..c.retry.0 {
                attempts += 1;
                let req = Req {
                    method: &c.method,
                    url: &c.url,
                    headers: headers.clone(),
                    body: body.clone(),
                    timeout_ms: timeout,
                    follow_redirects: false,
                };
                match http::send(&req) {
                    Ok(resp) => {
                        last_status = Some(resp.status);
                        last_err = None;
                        last_body = resp.body;
                        if verify::status_matches(&want_status, resp.status) {
                            break;
                        }
                    }
                    Err(e) => {
                        last_status = None;
                        last_err = Some(e);
                    }
                }
                if i + 1 < c.retry.0 && !nap(cx, c.retry.1) {
                    break;
                }
            }
            r.attempts += attempts;
            let masked_url = cx.masker.mask(&c.url);
            cx.note(&format!(
                "{} {masked_url} → {}",
                c.method,
                last_status
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| last_err.clone().unwrap_or_default())
            ));
            let mut v = verify::reach(last_status, attempts, &want_status, last_err.as_deref());
            v.title = format!("{} {masked_url}", v.title);
            r.verdicts.push(v);
            if let Some(needle) = c.expect.get("contains").and_then(|n| n.as_str()) {
                let mut o = verify::output(&last_body, &regex::escape(needle));
                o.title = format!("{} {masked_url}", tr("본문", "body"));
                r.verdicts.push(o);
            }
            if let Some(j) = c.expect.get("json") {
                let field = j.get("field").and_then(|f| f.as_str()).unwrap_or("");
                let parsed: Option<Value> = serde_json::from_str(&last_body).ok();
                let observed = parsed
                    .as_ref()
                    .and_then(|p| dig(p, field))
                    .map(crate::expr::to_text);
                if let Some(eq) = j.get("equals") {
                    let mut v = verify::identity(observed.as_deref(), &crate::expr::to_text(eq));
                    v.title = format!("{} {field}", tr("필드", "field"));
                    r.verdicts.push(v);
                }
            }
            results.push(json!({"url": masked_url, "method": c.method, "status": last_status, "attempts": attempts, "error": last_err, "body": excerpt(&cx.masker.mask(&last_body))}));
        }
        r.observe("checks", Value::Array(results));
        r
    }
}

// ---------- check.port ----------

pub struct Port;

fn port_inputs() -> Value {
    schema(
        json!({
            "host": {"type": "string", "default": "127.0.0.1"},
            "port": {"type": "integer"},
            "retry": {"type": "object"},
        }),
        &["port"],
    )
}

static PORT_META: Meta = Meta {
    id: "check.port",
    version: "1.0.0",
    title: ("포트 점검", "Port check"),
    category: "check",
    capabilities: &["network"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["VERIFY-01"],
    inputs: port_inputs,
    selects_files: false,
    estimate_ms: 5_000,
};

impl Block for Port {
    fn meta(&self) -> &Meta {
        &PORT_META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        match with.get("port") {
            Some(Value::Number(_)) | Some(Value::String(_)) => Vec::new(),
            _ => vec![tr("port 가 필요합니다.", "port is required.")],
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult::default();
        let host = cx.input_str("host").unwrap_or_else(|| "127.0.0.1".into());
        let port: u16 = cx
            .input_str("port")
            .and_then(|p| p.parse().ok())
            .unwrap_or(0);
        let (times, interval) = retry_of(cx.with.get("retry"));
        let mut open = false;
        let mut err = String::new();
        for i in 0..times {
            r.attempts += 1;
            let addrs: Vec<std::net::SocketAddr> =
                std::net::ToSocketAddrs::to_socket_addrs(&(host.as_str(), port))
                    .map(|a| a.collect())
                    .unwrap_or_default();
            match addrs.first() {
                Some(a) => {
                    match std::net::TcpStream::connect_timeout(a, Duration::from_millis(3000)) {
                        Ok(_) => {
                            open = true;
                            break;
                        }
                        Err(e) => err = e.to_string(),
                    }
                }
                None => err = tr("주소를 찾지 못함", "could not resolve the host"),
            }
            if i + 1 < times && !nap(cx, interval) {
                break;
            }
        }
        r.observe("host", json!(host));
        r.observe("port", json!(port));
        r.observe("open", json!(open));
        r.verdicts.push(Verdict {
            rule: "S1",
            title: format!("{} {host}:{port}", tr("포트", "port")),
            observed: if open { tr("열림", "open") } else { err },
            expected: tr("열림", "open"),
            result: if open { Outcome::Pass } else { Outcome::Fail },
            code: if open { None } else { Some("VERIFY-01") },
            phase: "main",
        });
        r
    }
}

// ---------- check.version ----------

pub struct Version;

fn version_inputs() -> Value {
    schema(
        json!({
            "url": {"type": "string"},
            "field": {"type": "string", "description": "Dot path in a JSON body. Empty means the whole body."},
            "expect": {"type": "string", "description": "Expected build identifier. Defaults to the current commit."},
            "retry": {"type": "object"},
        }),
        &["url"],
    )
}

static VERSION_META: Meta = Meta {
    id: "check.version",
    version: "1.0.0",
    title: ("빌드 식별자 점검", "Build identity check"),
    category: "check",
    capabilities: &["network"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["VERIFY-01", "VERIFY-02", "VERIFY-03"],
    inputs: version_inputs,
    selects_files: false,
    estimate_ms: 10_000,
};

impl Block for Version {
    fn meta(&self) -> &Meta {
        &VERSION_META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        if with.get("url").and_then(|u| u.as_str()).is_none() {
            return vec![tr("url 이 필요합니다.", "url is required.")];
        }
        Vec::new()
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult::default();
        let url = cx.input_str("url").unwrap_or_default();
        let field = cx.input_str("field").unwrap_or_default();
        let expected = cx.input_str("expect").unwrap_or_else(|| cx.git_sha.clone());
        let (times, interval) = retry_of(cx.with.get("retry"));
        let mut observed: Option<String> = None;
        let mut status = None;
        let mut err = None;
        for i in 0..times {
            r.attempts += 1;
            match http::send(&Req::get(&url)) {
                Ok(resp) => {
                    status = Some(resp.status);
                    if (200..300).contains(&resp.status) {
                        observed = if field.is_empty() {
                            Some(resp.body.trim().to_string())
                        } else {
                            resp.json()
                                .as_ref()
                                .and_then(|j| dig(j, &field))
                                .map(crate::expr::to_text)
                        };
                        if observed.is_some() {
                            break;
                        }
                    }
                }
                Err(e) => err = Some(e),
            }
            if i + 1 < times && !nap(cx, interval) {
                break;
            }
        }
        let masked = cx.masker.mask(&url);
        r.observe("url", json!(masked));
        r.observe("status", json!(status));
        r.observe("observed", json!(observed));
        if observed.is_none() {
            let mut v = verify::reach(status, r.attempts, &json!("2xx"), err.as_deref());
            v.title = format!("{} {masked}", v.title);
            if v.result == Outcome::Pass {
                v.result = Outcome::Indeterminate;
                v.code = Some("VERIFY-03");
            }
            r.verdicts.push(v);
        }
        r.verdicts
            .push(verify::identity(observed.as_deref(), &expected));
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dig_paths() {
        let v = json!({"build": {"sha": "abc"}, "items": [{"id": 7}]});
        assert_eq!(dig(&v, "build.sha"), Some(&json!("abc")));
        assert_eq!(dig(&v, "items.0.id"), Some(&json!(7)));
        assert_eq!(dig(&v, "nope"), None);
    }

    #[test]
    fn check_list_shapes() {
        let w = json!({"base": "http://h:1/", "checks": [{"path": "/health"}, {"path": "v", "expect": {"status": 200}}]});
        let c = checks_of(&w, &Value::Null).unwrap();
        assert_eq!(c[0].url, "http://h:1/health");
        assert_eq!(c[1].url, "http://h:1/v");
        assert!(checks_of(&json!({}), &Value::Null).is_err());
        assert_eq!(
            retry_of(Some(&json!({"times": 12, "interval": "5s"}))),
            (12, 5000)
        );
    }
}
