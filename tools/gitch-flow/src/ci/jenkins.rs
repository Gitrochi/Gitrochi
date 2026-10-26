//! Jenkins. crumb(CSRF) · buildWithParameters(상관 ID 파라미터) · 큐 항목 → 빌드 번호 · 진행형 로그 ·
//! JUnit 플러그인 testReport · 산출물 결과 계약 · 중지. 폴더 · 멀티브랜치 경로를 받는다.

use super::{CiErr, Provider, RState, RStatus, RemoteRun, Triggered};
use crate::connect::Connection;
use crate::http::{self, Req};
use crate::report::{Case, CaseStatus, TestReport};
use serde_json::{json, Value};
use std::cell::RefCell;

/// `folder/sub/job` → `job/folder/job/sub/job/job` (각 조각은 URL 인코딩).
pub fn job_path(path: &str) -> String {
    path.split('/')
        .filter(|s| !s.is_empty())
        .map(|s| format!("job/{}", super::gitlab::enc(s)))
        .collect::<Vec<_>>()
        .join("/")
}

pub struct Job {
    pub base: String,
    pub path: String,
    pub auth: Option<String>,
    pub params: Vec<(String, String)>,
    pub correlate: bool,
    crumb: RefCell<Option<Option<(String, String)>>>,
}

impl Job {
    pub fn new(
        c: &Connection,
        token: Option<String>,
        job: &str,
        params: Vec<(String, String)>,
        correlate: bool,
    ) -> Job {
        let auth = match (&c.user, token) {
            (Some(u), Some(t)) => Some(format!("Basic {}", super::b64(&format!("{u}:{t}")))),
            (None, Some(t)) => Some(format!("Bearer {t}")),
            _ => None,
        };
        Job {
            base: c.url.trim_end_matches('/').to_string(),
            path: job_path(job),
            auth,
            params,
            correlate,
            crumb: RefCell::new(None),
        }
    }

    fn headers(&self) -> Vec<(String, String)> {
        let mut h = Vec::new();
        if let Some(a) = &self.auth {
            h.push(("Authorization".to_string(), a.clone()));
        }
        h
    }

    fn get(&self, url: &str) -> Result<http::Resp, CiErr> {
        let r = http::send(&Req {
            method: "GET",
            url,
            headers: self.headers(),
            body: None,
            timeout_ms: 15_000,
            follow_redirects: true,
        })
        .map_err(CiErr::transport)?;
        if r.status >= 300 {
            let mut e = CiErr::from_resp(&r);
            e.unknown_outcome = false;
            return Err(e);
        }
        Ok(r)
    }

    fn get_json(&self, url: &str) -> Result<Value, CiErr> {
        let r = self.get(url)?;
        serde_json::from_str(&r.body).map_err(|e| CiErr {
            code: "CONN-05",
            http: Some(r.status),
            message: e.to_string(),
            unknown_outcome: false,
            transient: false,
            retry_after_ms: None,
        })
    }

    /// crumb 는 한 번만 받는다(없으면 CSRF 보호가 꺼진 서버).
    fn crumb(&self) -> Option<(String, String)> {
        if let Some(c) = self.crumb.borrow().clone() {
            return c;
        }
        let c = self
            .get_json(&format!("{}/crumbIssuer/api/json", self.base))
            .ok()
            .and_then(|v| {
                Some((
                    v["crumbRequestField"].as_str()?.to_string(),
                    v["crumb"].as_str()?.to_string(),
                ))
            });
        *self.crumb.borrow_mut() = Some(c.clone());
        c
    }

    fn post(&self, url: &str) -> Result<http::Resp, CiErr> {
        let mut h = self.headers();
        if let Some((k, v)) = self.crumb() {
            h.push((k, v));
        }
        let r = http::send(&Req {
            method: "POST",
            url,
            headers: h,
            body: Some(String::new()),
            timeout_ms: 20_000,
            follow_redirects: false,
        })
        .map_err(CiErr::transport)?;
        if r.status >= 400 {
            return Err(CiErr::from_resp(&r));
        }
        Ok(r)
    }

    /// Jenkins 가 돌려준 절대 주소를 연결에 적은 서버로 옮긴다. Jenkins 의 "루트 주소" 설정이 다른 호스트(내부 이름 등)여도
    /// 인증을 그 호스트로 보내지 않는다.
    fn rebase(&self, url: &str) -> String {
        let (Ok(b), Ok(u)) = (url::Url::parse(&self.base), url::Url::parse(url)) else {
            return url.to_string();
        };
        if b.origin() == u.origin() {
            return url.to_string();
        }
        let mut out = b.clone();
        out.set_path(u.path());
        out.set_query(u.query());
        out.to_string()
    }

    fn build_url(&self, run: &RemoteRun) -> String {
        let u = run.url.trim_end_matches('/');
        if u.starts_with("http") {
            format!("{}/", self.rebase(u).trim_end_matches('/'))
        } else {
            format!("{}/{}/{}/", self.base, self.path, run.id)
        }
    }
}

fn state_of(building: bool, result: Option<&str>) -> RState {
    if building {
        return RState::Running;
    }
    match result {
        Some("SUCCESS") => RState::Succeeded,
        Some("FAILURE") | Some("UNSTABLE") => RState::Failed,
        Some("ABORTED") | Some("NOT_BUILT") => RState::Cancelled,
        _ => RState::Queued,
    }
}

impl Provider for Job {
    fn label(&self) -> String {
        format!(
            "Jenkins {}",
            self.path.replace("job/", "").replace('/', " › ")
        )
    }

    fn find(&self, corr: &str, since_ms: u64) -> Result<Option<RemoteRun>, CiErr> {
        if !self.correlate {
            return Ok(None);
        }
        let v = self.get_json(&format!("{}/{}/api/json?tree=builds[number,url,timestamp,actions[parameters[name,value]]]{{0,15}}", self.base, self.path))?;
        for b in v["builds"].as_array().cloned().unwrap_or_default() {
            if b["timestamp"].as_u64().unwrap_or(0) + 60_000 < since_ms {
                continue;
            }
            let hit = b["actions"]
                .as_array()
                .map(|acts| {
                    acts.iter().any(|a| {
                        a["parameters"]
                            .as_array()
                            .map(|ps| {
                                ps.iter()
                                    .any(|p| p["name"] == "GITCH_FLOW_CORR" && p["value"] == corr)
                            })
                            .unwrap_or(false)
                    })
                })
                .unwrap_or(false);
            if hit {
                return Ok(Some(RemoteRun {
                    id: b["number"].to_string(),
                    url: b["url"].as_str().unwrap_or("").into(),
                    extra: Value::Null,
                }));
            }
        }
        Ok(None)
    }

    fn trigger(&self, corr: &str) -> Result<Triggered, CiErr> {
        let mut q: Vec<String> = Vec::new();
        if self.correlate {
            q.push(format!("GITCH_FLOW_CORR={}", super::gitlab::enc(corr)));
        }
        for (k, v) in &self.params {
            q.push(format!(
                "{}={}",
                super::gitlab::enc(k),
                super::gitlab::enc(v)
            ));
        }
        let url = if q.is_empty() {
            format!("{}/{}/build", self.base, self.path)
        } else {
            format!(
                "{}/{}/buildWithParameters?{}",
                self.base,
                self.path,
                q.join("&")
            )
        };
        let r = self.post(&url)?;
        let queue = r.header("location").map(|s| s.to_string());
        Ok(Triggered::Accepted(queue.map(|q| json!({"queue": q}))))
    }

    fn resolve_accepted(&self, handle: &Value) -> Result<Option<RemoteRun>, CiErr> {
        let Some(q) = handle["queue"].as_str() else {
            return Ok(None);
        };
        let q = self.rebase(q);
        let v = self.get_json(&format!("{}/api/json", q.trim_end_matches('/')))?;
        if v["cancelled"] == true {
            return Err(CiErr {
                code: "CI-04",
                http: None,
                message: "the queued build was cancelled".into(),
                unknown_outcome: false,
                transient: false,
                retry_after_ms: None,
            });
        }
        Ok(v["executable"]["number"].as_u64().map(|n| RemoteRun {
            id: n.to_string(),
            url: v["executable"]["url"].as_str().unwrap_or("").into(),
            extra: Value::Null,
        }))
    }

    fn status(&self, run: &RemoteRun) -> Result<RStatus, CiErr> {
        let v = self.get_json(&format!(
            "{}api/json?tree=building,result",
            self.build_url(run)
        ))?;
        let result = v["result"].as_str();
        Ok(RStatus {
            state: state_of(v["building"].as_bool().unwrap_or(false), result),
            conclusion: result
                .unwrap_or(if v["building"] == true {
                    "BUILDING"
                } else {
                    "QUEUED"
                })
                .to_string(),
        })
    }

    fn logs(&self, run: &RemoteRun, cursor: &mut Value) -> Result<Vec<String>, CiErr> {
        let start = cursor.as_u64().unwrap_or(0);
        let r = self.get(&format!(
            "{}logText/progressiveText?start={start}",
            self.build_url(run)
        ))?;
        if let Some(n) = r.header("x-text-size").and_then(|s| s.parse::<u64>().ok()) {
            *cursor = json!(n);
        }
        Ok(r.body.lines().map(|l| l.to_string()).collect())
    }

    fn report(&self, run: &RemoteRun) -> Result<Option<TestReport>, CiErr> {
        let v = match self.get_json(&format!("{}testReport/api/json", self.build_url(run))) {
            Ok(v) => v,
            Err(e) if e.http == Some(404) => return Ok(None),
            Err(e) => return Err(e),
        };
        let mut rep = TestReport {
            format: "jenkins-junit".into(),
            sources: vec![format!("build {}", run.id)],
            ..Default::default()
        };
        for s in v["suites"].as_array().cloned().unwrap_or_default() {
            for c in s["cases"].as_array().cloned().unwrap_or_default() {
                let status = match c["status"].as_str().unwrap_or("") {
                    "PASSED" | "FIXED" => CaseStatus::Passed,
                    "SKIPPED" => CaseStatus::Skipped,
                    _ => CaseStatus::Failed,
                };
                let name = c["name"].as_str().unwrap_or("").to_string();
                let class = c["className"].as_str().unwrap_or("").to_string();
                let msg = c["errorDetails"]
                    .as_str()
                    .or(c["errorStackTrace"].as_str())
                    .map(|m| m.lines().take(4).collect::<Vec<_>>().join("\n"));
                rep.cases.push(Case {
                    id: format!("{class}::{name}"),
                    name,
                    file: None,
                    line: None,
                    status,
                    duration_ms: c["duration"]
                        .as_f64()
                        .map(|f| (f * 1000.0) as u64)
                        .unwrap_or(0),
                    message: msg,
                });
            }
        }
        Ok(Some(rep))
    }

    fn contract(&self, run: &RemoteRun) -> Result<Option<Value>, CiErr> {
        match self.get_json(&format!(
            "{}artifact/gitch-flow-out/gitch-flow-result.json",
            self.build_url(run)
        )) {
            Ok(v) if v["runId"].is_string() => Ok(Some(super::contract::small(&v))),
            _ => Ok(None),
        }
    }

    fn cancel(&self, run: &RemoteRun) -> Result<(), CiErr> {
        self.post(&format!("{}stop", self.build_url(run)))
            .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_and_states() {
        assert_eq!(job_path("folder/sub/build"), "job/folder/job/sub/job/build");
        assert_eq!(job_path("repo/feature%2Fx"), "job/repo/job/feature%252Fx");
        assert_eq!(state_of(true, None), RState::Running);
        assert_eq!(state_of(false, Some("UNSTABLE")), RState::Failed);
        assert_eq!(state_of(false, Some("ABORTED")), RState::Cancelled);
        assert_eq!(state_of(false, None), RState::Queued);
    }
}
