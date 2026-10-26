//! Plain HTTP CI (webhook or polling): a trigger URL, a status URL and JSON pointers connect many CI systems loosely.
//! For example Buildkite, TeamCity or an in-house deployment console. Where a correlation ID is accepted, it goes in through the `{corr}` placeholder.

use super::{CiErr, Provider, RState, RStatus, RemoteRun, Triggered};
use crate::http::{self, Req};
use serde_json::{json, Value};

pub struct Http {
    pub with: Value,
    pub auth: Option<String>,
}

fn fill(s: &str, id: &str, corr: &str) -> String {
    s.replace("{id}", id).replace("{corr}", corr)
}

/// Values put into URLs are encoded, so an ID from the remote with `/` or `?` cannot turn into another path.
fn fill_url(s: &str, id: &str, corr: &str) -> String {
    fill(s, &super::gitlab::enc(id), &super::gitlab::enc(corr))
}

impl Http {
    fn headers(&self, extra: &Value) -> Vec<(String, String)> {
        let mut h: Vec<(String, String)> = extra
            .as_object()
            .map(|o| {
                o.iter()
                    .map(|(k, v)| (k.clone(), crate::expr::to_text(v)))
                    .collect()
            })
            .unwrap_or_default();
        if let Some(a) = &self.auth {
            h.push(("Authorization".into(), a.clone()));
        }
        h
    }
    fn call(&self, part: &Value, id: &str, corr: &str) -> Result<http::Resp, CiErr> {
        let url = fill_url(part["url"].as_str().unwrap_or(""), id, corr);
        let method = part["method"]
            .as_str()
            .unwrap_or("GET")
            .to_ascii_uppercase();
        let body = part.get("body").map(|b| {
            fill(
                &if b.is_string() {
                    crate::expr::to_text(b)
                } else {
                    b.to_string()
                },
                id,
                corr,
            )
        });
        let mut headers = self.headers(&part["headers"]);
        if body.is_some()
            && !headers
                .iter()
                .any(|(k, _)| k.eq_ignore_ascii_case("content-type"))
        {
            headers.push(("Content-Type".into(), "application/json".into()));
        }
        let r = http::send(&Req {
            method: &method,
            url: &url,
            headers,
            body,
            timeout_ms: 20_000,
            follow_redirects: true,
        })
        .map_err(CiErr::transport)?;
        if r.status >= 300 {
            return Err(CiErr::from_resp(&r));
        }
        Ok(r)
    }
}

impl Provider for Http {
    fn label(&self) -> String {
        format!(
            "HTTP CI {}",
            self.with["trigger"]["url"].as_str().unwrap_or("")
        )
    }

    fn find(&self, corr: &str, _since: u64) -> Result<Option<RemoteRun>, CiErr> {
        let Some(f) = self.with.get("find").filter(|f| f.is_object()) else {
            return Ok(None);
        };
        let r = self.call(f, "", corr)?;
        let v: Value = serde_json::from_str(&r.body).unwrap_or(Value::Null);
        let id = v
            .pointer(f["id"].as_str().unwrap_or("/id"))
            .map(crate::expr::to_text)
            .filter(|s| !s.is_empty());
        Ok(id.map(|id| RemoteRun {
            url: fill_url(self.with["status"]["url"].as_str().unwrap_or(""), &id, corr),
            id,
            extra: Value::Null,
        }))
    }

    fn trigger(&self, corr: &str) -> Result<Triggered, CiErr> {
        let t = &self.with["trigger"];
        let r = self.call(t, "", corr)?;
        let v: Value = serde_json::from_str(&r.body).unwrap_or(Value::Null);
        let ptr = self.with["id"].as_str().unwrap_or("/id");
        match v
            .pointer(ptr)
            .map(crate::expr::to_text)
            .filter(|s| !s.is_empty())
        {
            Some(id) => Ok(Triggered::Created(RemoteRun {
                url: fill_url(self.with["status"]["url"].as_str().unwrap_or(""), &id, corr),
                id,
                extra: json!({"corr": corr}),
            })),
            None => Ok(Triggered::Accepted(None)),
        }
    }

    fn status(&self, run: &RemoteRun) -> Result<RStatus, CiErr> {
        let s = &self.with["status"];
        let corr = run.extra["corr"].as_str().unwrap_or("");
        let r = self.call(s, &run.id, corr)?;
        let v: Value = serde_json::from_str(&r.body).unwrap_or(Value::Null);
        let val = v
            .pointer(s["pointer"].as_str().unwrap_or("/status"))
            .map(crate::expr::to_text)
            .unwrap_or_default();
        let has = |k: &str, default: &[&str]| -> bool {
            match s.get(k).and_then(|x| x.as_array()) {
                Some(a) => a
                    .iter()
                    .any(|x| crate::expr::to_text(x).eq_ignore_ascii_case(&val)),
                None => default.iter().any(|d| d.eq_ignore_ascii_case(&val)),
            }
        };
        let state = if has("success", &["success", "succeeded", "passed", "ok"]) {
            RState::Succeeded
        } else if has("failure", &["failed", "failure", "error", "errored"]) {
            RState::Failed
        } else if has("cancelled", &["cancelled", "canceled", "aborted"]) {
            RState::Cancelled
        } else if has("queued", &["queued", "pending", "scheduled", "created"]) {
            RState::Queued
        } else {
            RState::Running
        };
        Ok(RStatus {
            state,
            conclusion: val,
        })
    }

    fn logs(&self, run: &RemoteRun, cursor: &mut Value) -> Result<Vec<String>, CiErr> {
        let Some(l) = self.with.get("logs").filter(|l| l.is_object()) else {
            return Ok(Vec::new());
        };
        let corr = run.extra["corr"].as_str().unwrap_or("");
        let r = self.call(l, &run.id, corr)?;
        let from = cursor.as_u64().unwrap_or(0) as usize;
        let body = r.body;
        let out = if body.len() > from && body.is_char_boundary(from) {
            body[from..].lines().map(|s| s.to_string()).collect()
        } else {
            Vec::new()
        };
        *cursor = json!(body.len());
        Ok(out)
    }

    fn cancel(&self, run: &RemoteRun) -> Result<(), CiErr> {
        match self.with.get("cancel").filter(|c| c.is_object()) {
            Some(c) => self
                .call(c, &run.id, run.extra["corr"].as_str().unwrap_or(""))
                .map(|_| ()),
            None => Ok(()),
        }
    }
}
