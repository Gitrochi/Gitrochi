//! Mock server blocks: `mock.fault` (turn fault switches on and off) and `check.mock` (did the expected calls arrive).
//! Both use only the `mock.http` service's control endpoints (`/__gitch/…`).

use super::{schema, Block, Meta, NodeCx, NodeResult};
use crate::http::{self, Req};
use crate::util::tr;
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};

pub struct Fault;
pub struct Check;

/// The control address of the mock service the node uses. A service named here must also be in the node's `services:` to be running.
fn control(cx: &NodeCx) -> Result<String, String> {
    if let Some(u) = cx.input_str("url") {
        return Ok(format!("{}/__gitch", u.trim_end_matches('/')));
    }
    let name = cx.input_str("service").ok_or_else(|| {
        tr(
            "service(모의 서비스 이름) 가 필요합니다.",
            "service (the mock service name) is required.",
        )
    })?;
    cx.services[&name]["control"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| {
            tr(
                &format!("모의 서비스 '{name}' 이(가) 떠 있지 않습니다. 노드의 services: 에 {name} 을(를) 넣으세요."),
                &format!("mock service '{name}' is not up; add {name} to the node's services:."),
            )
        })
}

fn missing(msg: String) -> Verdict {
    Verdict::new(
        "M0",
        tr("모의 서버", "mock server"),
        msg,
        tr("떠 있음", "running"),
        Outcome::Indeterminate,
        Some("VERIFY-03"),
    )
}

fn names(v: Option<&Value>) -> Vec<String> {
    v.and_then(|x| x.as_array())
        .map(|a| a.iter().map(crate::expr::to_text).collect())
        .unwrap_or_default()
}

const META_CODES: &[&str] = &["VERIFY-01", "VERIFY-03", "SERVICE-02"];

fn fault_inputs() -> Value {
    schema(
        json!({"service": {"type": "string"}, "url": {"type": "string"}, "on": {"type": "array", "items": {"type": "string"}},
               "off": {"type": "array", "items": {"type": "string"}}, "set": {"type": "array", "items": {"type": "string"}}, "reset": {"type": "boolean"}}),
        &[],
    )
}

fn check_inputs() -> Value {
    schema(
        json!({"service": {"type": "string"}, "url": {"type": "string"},
               "calls": {"type": "array", "items": {"type": "object", "properties": {"method": {"type": "string"}, "path": {"type": "string"}, "count": {"type": "integer"}, "min": {"type": "integer"}, "max": {"type": "integer"}, "contains": {"type": "string"}}}},
               "unmatched": {"type": "integer", "description": "How many requests may miss every route (default 0)."}}),
        &["calls"],
    )
}

static FAULT_META: Meta = Meta {
    id: "mock.fault",
    version: "1.0.0",
    title: ("모의 서버 장애 스위치", "Mock fault switch"),
    category: "fixture",
    capabilities: &["network"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: META_CODES,
    inputs: fault_inputs,
    selects_files: false,
    estimate_ms: 500,
};

static CHECK_META: Meta = Meta {
    id: "check.mock",
    version: "1.0.0",
    title: ("모의 서버 호출 확인", "Mock call check"),
    category: "check",
    capabilities: &["network"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: META_CODES,
    inputs: check_inputs,
    selects_files: false,
    estimate_ms: 500,
};

impl Block for Fault {
    fn meta(&self) -> &Meta {
        &FAULT_META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let base = match control(cx) {
            Ok(b) => b,
            Err(e) => {
                r.verdicts.push(missing(e));
                return r;
            }
        };
        let post = |path: &str, body: Value| {
            let url = format!("{base}/{path}");
            http::send(&Req {
                method: "POST",
                body: Some(body.to_string()),
                ..Req::get(&url).header("Content-Type", "application/json")
            })
        };
        if cx
            .with
            .get("reset")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            let _ = post("reset", json!({}));
        }
        let mut body = json!({"on": names(cx.with.get("on")), "off": names(cx.with.get("off"))});
        if cx.with.get("set").is_some() {
            body["set"] = json!(names(cx.with.get("set")));
        }
        let res = post("faults", body);
        let (status, active) = match &res {
            Ok(resp) => (
                Some(resp.status),
                resp.json()
                    .map(|v| v["active"].clone())
                    .unwrap_or(Value::Null),
            ),
            Err(_) => (None, Value::Null),
        };
        cx.note(&format!("faults → {active}"));
        r.observe("active", active.clone());
        r.outputs.insert("active".into(), active);
        r.verdicts.push(Verdict::new(
            "M1",
            tr("장애 스위치", "fault switch"),
            status
                .map(|s| format!("HTTP {s}"))
                .unwrap_or_else(|| res.err().unwrap_or_default()),
            "HTTP 200".into(),
            if status == Some(200) {
                Outcome::Pass
            } else {
                Outcome::Fail
            },
            Some("VERIFY-01"),
        ));
        r
    }
}

impl Block for Check {
    fn meta(&self) -> &Meta {
        &CHECK_META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        match with.get("calls") {
            Some(Value::Array(a)) if !a.is_empty() => Vec::new(),
            _ => vec![tr(
                "calls 에 기대한 호출이 필요합니다.",
                "calls needs the expected calls.",
            )],
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let base = match control(cx) {
            Ok(b) => b,
            Err(e) => {
                r.verdicts.push(missing(e));
                return r;
            }
        };
        let url = format!("{base}/requests");
        let reqs: Vec<Value> = match http::send(&Req::get(&url)) {
            Ok(resp) if resp.status == 200 => resp
                .json()
                .and_then(|v| v.as_array().cloned())
                .unwrap_or_default(),
            Ok(resp) => {
                r.verdicts.push(missing(format!("HTTP {}", resp.status)));
                return r;
            }
            Err(e) => {
                r.verdicts.push(missing(e));
                return r;
            }
        };
        r.observe("requests", json!(reqs.len()));
        for c in cx
            .with
            .get("calls")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default()
        {
            let method = c
                .get("method")
                .and_then(|m| m.as_str())
                .map(|m| m.to_ascii_uppercase());
            let path = c
                .get("path")
                .and_then(|p| p.as_str())
                .unwrap_or("*")
                .to_string();
            let needle = c
                .get("contains")
                .and_then(|n| n.as_str())
                .map(|s| s.to_string());
            let n = reqs
                .iter()
                .filter(|q| method.as_deref().map(|m| q["method"] == m).unwrap_or(true))
                .filter(|q| crate::mock::path_matches(&path, q["path"].as_str().unwrap_or("")))
                .filter(|q| {
                    needle
                        .as_deref()
                        .map(|nd| q["body"].as_str().unwrap_or("").contains(nd))
                        .unwrap_or(true)
                })
                .count() as u64;
            let (min, max) = match c.get("count").and_then(|x| x.as_u64()) {
                Some(k) => (k, Some(k)),
                None => (
                    c.get("min").and_then(|x| x.as_u64()).unwrap_or(1),
                    c.get("max").and_then(|x| x.as_u64()),
                ),
            };
            let ok = n >= min && max.map(|m| n <= m).unwrap_or(true);
            let want = match max {
                Some(m) if m == min => format!("{min}"),
                Some(m) => format!("{min}..{m}"),
                None => format!("≥{min}"),
            };
            r.verdicts.push(Verdict::new(
                "M2",
                format!("{} {path}", method.as_deref().unwrap_or("*")),
                format!("{n}"),
                want,
                if ok { Outcome::Pass } else { Outcome::Fail },
                Some("VERIFY-01"),
            ));
        }
        let allowed = cx
            .with
            .get("unmatched")
            .and_then(|u| u.as_u64())
            .unwrap_or(0);
        let unmatched = reqs.iter().filter(|q| q["matched"] == false).count() as u64;
        r.verdicts.push(Verdict::new(
            "M3",
            tr("표에 없는 요청", "requests that hit no route"),
            format!("{unmatched}"),
            format!("≤{allowed}"),
            if unmatched <= allowed {
                Outcome::Pass
            } else {
                Outcome::Fail
            },
            Some("VERIFY-01"),
        ));
        r
    }
}
