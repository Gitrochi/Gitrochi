//! GitHub Actions. `workflow_dispatch` 는 ID 를 돌려주지 않아(204) 상관 ID(run-name 의 `[gitch-…]`)로 찾고,
//! 워크플로가 상관 입력을 받지 않으면 보내기 전 목록과 비교해 새로 생긴 실행을 고른다.

use super::{CiErr, Provider, RState, RStatus, RemoteRun, Triggered};
use crate::connect::Connection;
use crate::http::{self, Req};
use crate::util::tr;
use serde_json::{json, Value};
use std::cell::RefCell;

pub struct Api {
    pub base: String,
    pub token: Option<String>,
}

impl Api {
    pub fn new(c: &Connection, token: Option<String>) -> Api {
        let base = if c.url.is_empty() || c.url.trim_end_matches('/') == "https://github.com" {
            "https://api.github.com".to_string()
        } else {
            c.url.trim_end_matches('/').to_string()
        };
        Api { base, token }
    }
    fn headers(&self) -> Vec<(String, String)> {
        let mut h = vec![
            (
                "Accept".to_string(),
                "application/vnd.github+json".to_string(),
            ),
            ("X-GitHub-Api-Version".to_string(), "2022-11-28".to_string()),
        ];
        if let Some(t) = &self.token {
            h.push(("Authorization".into(), format!("Bearer {t}")));
        }
        h
    }
    fn check(r: http::Resp) -> Result<http::Resp, CiErr> {
        if r.status >= 300 && r.status != 302 {
            let limited = r.header("x-ratelimit-remaining") == Some("0");
            let mut e = CiErr::from_status(r.status, &r.body);
            if limited {
                e.code = "CONN-06";
                e.transient = true;
            }
            return Err(e);
        }
        Ok(r)
    }
    pub fn get(&self, path: &str) -> Result<http::Resp, CiErr> {
        let url = format!("{}{path}", self.base);
        let r = http::send(&Req {
            method: "GET",
            url: &url,
            headers: self.headers(),
            body: None,
            timeout_ms: 15_000,
            follow_redirects: false,
        })
        .map_err(CiErr::transport)?;
        Self::check(r).map_err(|mut e| {
            e.unknown_outcome = false;
            e
        })
    }
    pub fn get_json(&self, path: &str) -> Result<Value, CiErr> {
        let r = self.get(path)?;
        serde_json::from_str(&r.body).map_err(|e| CiErr {
            code: "CONN-05",
            http: Some(r.status),
            message: e.to_string(),
            unknown_outcome: false,
            transient: false,
        })
    }
    pub fn post(&self, path: &str, body: &Value) -> Result<http::Resp, CiErr> {
        let url = format!("{}{path}", self.base);
        let mut h = self.headers();
        h.push(("Content-Type".into(), "application/json".into()));
        let r = http::send(&Req {
            method: "POST",
            url: &url,
            headers: h,
            body: Some(body.to_string()),
            timeout_ms: 20_000,
            follow_redirects: false,
        })
        .map_err(CiErr::transport)?;
        Self::check(r)
    }
    /// 작업 로그: 302 의 Location 을 인증 없이 받는다(토큰을 저장소 밖 호스트로 보내지 않게).
    pub fn job_log(&self, repo: &str, job: &str) -> Result<String, CiErr> {
        let r = self.get(&format!("/repos/{repo}/actions/jobs/{job}/logs"))?;
        if r.status == 302 {
            let loc = r.header("location").unwrap_or("").to_string();
            let host_ok = loc.starts_with("https://")
                && (loc.contains(".githubusercontent.com/")
                    || loc.contains(".blob.core.windows.net/")
                    || loc.contains("github.com/"));
            if !host_ok {
                return Err(CiErr {
                    code: "CONN-05",
                    http: Some(302),
                    message: "unexpected log redirect host".into(),
                    unknown_outcome: false,
                    transient: false,
                });
            }
            let r2 = http::send(&Req {
                method: "GET",
                url: &loc,
                headers: vec![],
                body: None,
                timeout_ms: 30_000,
                follow_redirects: true,
            })
            .map_err(CiErr::transport)?;
            return Ok(r2.body);
        }
        Ok(r.body)
    }
}

fn state_of(status: &str, conclusion: &str) -> RState {
    match status {
        "completed" => match conclusion {
            "success" | "neutral" => RState::Succeeded,
            "cancelled" | "skipped" => RState::Cancelled,
            "action_required" => RState::Waiting,
            _ => RState::Failed,
        },
        "in_progress" => RState::Running,
        "waiting" | "action_required" => RState::Waiting,
        _ => RState::Queued,
    }
}

pub struct Workflow {
    pub api: Api,
    pub repo: String,
    pub workflow: String,
    pub git_ref: String,
    pub inputs: Value,
    /// 워크플로가 `gitch_flow_corr` 입력을 받는지(gitch flow export 로 만든 워크플로는 받는다).
    pub correlate: bool,
    pub before: RefCell<Vec<u64>>,
    pub sent: RefCell<bool>,
}

impl Workflow {
    fn runs(&self, since_ms: u64) -> Result<Vec<Value>, CiErr> {
        let created = crate::util::rfc3339(since_ms);
        let v = self.api.get_json(&format!("/repos/{}/actions/workflows/{}/runs?event=workflow_dispatch&branch={}&per_page=30&created=%3E%3D{}", self.repo, super::gitlab::enc(&self.workflow), super::gitlab::enc(&self.git_ref), super::gitlab::enc(&created)))?;
        Ok(v["workflow_runs"].as_array().cloned().unwrap_or_default())
    }
}

impl Provider for Workflow {
    fn label(&self) -> String {
        format!(
            "GitHub Actions {}:{}@{}",
            self.repo, self.workflow, self.git_ref
        )
    }

    fn find(&self, corr: &str, since_ms: u64) -> Result<Option<RemoteRun>, CiErr> {
        let runs = self.runs(since_ms)?;
        let pick = if self.correlate {
            runs.iter()
                .find(|r| {
                    r["display_title"]
                        .as_str()
                        .map(|t| t.contains(corr))
                        .unwrap_or(false)
                })
                .cloned()
        } else if *self.sent.borrow() {
            // 시각 기반: 보내기 전에 없던 가장 새 실행.
            let before = self.before.borrow();
            runs.iter()
                .filter(|r| !before.contains(&r["id"].as_u64().unwrap_or(0)))
                .max_by_key(|r| r["id"].as_u64().unwrap_or(0))
                .cloned()
        } else {
            None
        };
        Ok(pick.map(|r| RemoteRun {
            id: r["id"].as_u64().unwrap_or(0).to_string(),
            url: r["html_url"].as_str().unwrap_or("").into(),
            extra: json!({"correlation": if self.correlate { "run-name" } else { "time" }}),
        }))
    }

    fn trigger(&self, corr: &str) -> Result<Triggered, CiErr> {
        if !self.correlate {
            let ids: Vec<u64> = self
                .runs(crate::util::now_ms().saturating_sub(3_600_000))
                .unwrap_or_default()
                .iter()
                .filter_map(|r| r["id"].as_u64())
                .collect();
            *self.before.borrow_mut() = ids;
        }
        let mut inputs = self.inputs.as_object().cloned().unwrap_or_default();
        if self.correlate {
            inputs.insert("gitch_flow_corr".into(), json!(corr));
        }
        self.api.post(
            &format!(
                "/repos/{}/actions/workflows/{}/dispatches",
                self.repo,
                super::gitlab::enc(&self.workflow)
            ),
            &json!({"ref": self.git_ref, "inputs": inputs}),
        )?;
        *self.sent.borrow_mut() = true;
        Ok(Triggered::Accepted(None))
    }

    fn status(&self, run: &RemoteRun) -> Result<RStatus, CiErr> {
        let r = self
            .api
            .get_json(&format!("/repos/{}/actions/runs/{}", self.repo, run.id))?;
        let s = r["status"].as_str().unwrap_or("");
        let c = r["conclusion"].as_str().unwrap_or("");
        Ok(RStatus {
            state: state_of(s, c),
            conclusion: if c.is_empty() {
                s.to_string()
            } else {
                c.to_string()
            },
        })
    }

    fn logs(&self, run: &RemoteRun, cursor: &mut Value) -> Result<Vec<String>, CiErr> {
        if !cursor.is_object() {
            *cursor = json!({"done": []});
        }
        let jobs = self.api.get_json(&format!(
            "/repos/{}/actions/runs/{}/jobs?per_page=50",
            self.repo, run.id
        ))?;
        let mut out = Vec::new();
        for j in jobs["jobs"].as_array().cloned().unwrap_or_default() {
            if j["status"] != "completed" {
                continue;
            }
            let id = j["id"].as_u64().unwrap_or(0).to_string();
            if cursor["done"]
                .as_array()
                .map(|a| a.iter().any(|x| x == id.as_str()))
                .unwrap_or(false)
            {
                continue;
            }
            if let Ok(text) = self.api.job_log(&self.repo, &id) {
                let name = j["name"].as_str().unwrap_or("job");
                let lines: Vec<&str> = text.lines().collect();
                let start = lines.len().saturating_sub(20_000);
                for l in &lines[start..] {
                    out.push(format!("[{name}] {l}"));
                }
            }
            if let Some(a) = cursor["done"].as_array_mut() {
                a.push(json!(id));
            }
        }
        Ok(out)
    }

    fn cancel(&self, run: &RemoteRun) -> Result<(), CiErr> {
        self.api
            .post(
                &format!("/repos/{}/actions/runs/{}/cancel", self.repo, run.id),
                &json!({}),
            )
            .map(|_| ())
    }
}

fn api_for(c: &Connection) -> Api {
    Api::new(c, crate::connect::secret(c, false))
}

pub fn cli_status(out: &crate::cli::Out, c: &Connection, repo: &str, branch: &str) -> i32 {
    let api = api_for(c);
    match api.get_json(&format!(
        "/repos/{repo}/actions/runs?branch={}&per_page=5",
        super::gitlab::enc(branch)
    )) {
        Ok(v) => {
            if out.json {
                println!("{}", serde_json::to_string_pretty(&json!({"schemaVersion": 1, "provider": "github", "repo": repo, "ref": branch, "runs": v["workflow_runs"]})).unwrap_or_default());
            } else {
                for r in v["workflow_runs"].as_array().cloned().unwrap_or_default() {
                    println!(
                        "{:<12} {:<10} {:<10} {}  {}",
                        r["id"],
                        r["status"].as_str().unwrap_or(""),
                        r["conclusion"].as_str().unwrap_or("-"),
                        r["name"].as_str().unwrap_or(""),
                        r["html_url"].as_str().unwrap_or("")
                    );
                }
            }
            0
        }
        Err(e) => {
            eprintln!("{}\n  {}", e.message, crate::codes::line(e.code));
            1
        }
    }
}

pub fn cli_logs(_out: &crate::cli::Out, c: &Connection, repo: &str, job: &str) -> i32 {
    let api = api_for(c);
    let masker = crate::mask::Masker::new();
    if let Some(t) = &api.token {
        masker.add_secret("TOKEN", t);
    }
    match api.job_log(repo, job) {
        Ok(t) => {
            print!("{}", masker.mask(&t));
            0
        }
        Err(e) => {
            eprintln!(
                "{}",
                tr(
                    &format!("로그를 받지 못했습니다: {}", e.message),
                    &format!("could not fetch the log: {}", e.message)
                )
            );
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn states() {
        assert_eq!(state_of("completed", "success"), RState::Succeeded);
        assert_eq!(state_of("completed", "failure"), RState::Failed);
        assert_eq!(state_of("completed", "timed_out"), RState::Failed);
        assert_eq!(state_of("completed", "cancelled"), RState::Cancelled);
        assert_eq!(state_of("in_progress", ""), RState::Running);
        assert_eq!(state_of("waiting", ""), RState::Waiting);
        assert_eq!(state_of("queued", ""), RState::Queued);
    }
}
