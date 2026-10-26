//! GitLab CI(자체 호스팅 포함). 파이프라인 생성 · 수동 작업 실행 · 작업 로그 · 파이프라인 테스트 보고서 · 산출물 결과 계약.

use super::{CiErr, Provider, RState, RStatus, RemoteRun, Triggered};
use crate::connect::Connection;
use crate::http::{self, Req};
use crate::report::{Case, CaseStatus, TestReport};
use crate::util::tr;
use serde_json::{json, Value};

/// 경로 조각 하나를 URL 에 넣을 수 있게(`group/repo` → `group%2Frepo`).
pub fn enc(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub struct Api {
    pub base: String,
    pub token: Option<String>,
}

impl Api {
    pub fn new(c: &Connection, token: Option<String>) -> Api {
        let base = if c.url.ends_with("/api/v4") {
            c.url.clone()
        } else {
            format!("{}/api/v4", c.url.trim_end_matches('/'))
        };
        Api { base, token }
    }
    fn headers(&self) -> Vec<(String, String)> {
        let mut h = vec![("Accept".to_string(), "application/json".to_string())];
        if let Some(t) = &self.token {
            h.push(("PRIVATE-TOKEN".into(), t.clone()));
        }
        h
    }
    pub fn get(&self, path: &str) -> Result<http::Resp, CiErr> {
        let url = format!("{}{path}", self.base);
        let r = http::send(&Req {
            method: "GET",
            url: &url,
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
    pub fn get_json(&self, path: &str) -> Result<Value, CiErr> {
        let r = self.get(path)?;
        serde_json::from_str(&r.body).map_err(|e| CiErr {
            code: "CONN-05",
            http: Some(r.status),
            message: e.to_string(),
            unknown_outcome: false,
            transient: false,
            retry_after_ms: None,
        })
    }
    pub fn post(&self, path: &str, body: &Value) -> Result<Value, CiErr> {
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
        if r.status >= 300 {
            return Err(CiErr::from_resp(&r));
        }
        Ok(serde_json::from_str(&r.body).unwrap_or(Value::Null))
    }
}

fn state_of(s: &str) -> RState {
    match s {
        "running" => RState::Running,
        "success" => RState::Succeeded,
        "failed" => RState::Failed,
        "canceled" | "canceling" | "skipped" => RState::Cancelled,
        "manual" => RState::Waiting,
        _ => RState::Queued,
    }
}

/// 작업 로그 상한(작업당 끝부분).
const TRACE_TAIL: usize = 1024 * 1024;

/// 작업 로그를 이어 읽는다. cursor = {"<job id>": 읽은 바이트, "done": [끝난 작업]}.
/// 아직 도는 작업은 마지막 줄바꿈까지만 읽어 줄이 반으로 잘리지 않게 한다.
fn job_logs(api: &Api, project: &str, jobs: &[Value], cursor: &mut Value) -> Vec<String> {
    if !cursor.is_object() {
        *cursor = json!({"done": []});
    }
    let mut out = Vec::new();
    for j in jobs {
        let id = j["id"].as_u64().unwrap_or(0).to_string();
        let status = j["status"].as_str().unwrap_or("");
        if matches!(
            status,
            "created" | "pending" | "manual" | "skipped" | "scheduled" | "waiting_for_resource"
        ) {
            continue;
        }
        let done = cursor["done"]
            .as_array()
            .map(|a| a.iter().any(|x| x == id.as_str()))
            .unwrap_or(false);
        if done {
            continue;
        }
        let Ok(r) = api.get(&format!("/projects/{project}/jobs/{id}/trace")) else {
            continue;
        };
        let finished = matches!(status, "success" | "failed" | "canceled");
        let body = r.body;
        let mut from = cursor[&id].as_u64().unwrap_or(0) as usize;
        let name = j["name"].as_str().unwrap_or("job");
        if from == 0 && body.len() > TRACE_TAIL {
            from = body.len() - TRACE_TAIL;
            out.push(format!("[{name}] … ({} bytes skipped)", from));
        }
        let end = if finished {
            body.len()
        } else {
            body.rfind('\n').map(|i| i + 1).unwrap_or(0)
        };
        if end > from {
            let mut start = from;
            while start < end && !body.is_char_boundary(start) {
                start += 1;
            }
            for l in body[start..end].lines() {
                // GitLab 의 접기 표식(section_start …) 같은 제어 글자를 걷어 낸다.
                let clean: String = l
                    .chars()
                    .filter(|c| !c.is_control() || *c == '\t')
                    .collect();
                out.push(format!("[{name}] {clean}"));
            }
            cursor[&id] = json!(end);
        }
        if finished {
            if let Some(a) = cursor["done"].as_array_mut() {
                a.push(json!(id));
            }
        }
    }
    out
}

fn artifact_contract(api: &Api, project: &str, jobs: &[Value]) -> Option<Value> {
    for j in jobs.iter().take(12) {
        let id = j["id"].as_u64().unwrap_or(0);
        if let Ok(v) = api.get_json(&format!(
            "/projects/{project}/jobs/{id}/artifacts/gitch-flow-out/gitch-flow-result.json"
        )) {
            if v["runId"].is_string() {
                return Some(super::contract::small(&v));
            }
        }
    }
    None
}

pub struct Pipeline {
    pub api: Api,
    pub project: String,
    pub git_ref: String,
    pub variables: Vec<(String, String)>,
}

impl Provider for Pipeline {
    fn label(&self) -> String {
        format!(
            "GitLab pipeline {}@{}",
            self.project.replace("%2F", "/"),
            self.git_ref
        )
    }

    fn find(&self, corr: &str, since_ms: u64) -> Result<Option<RemoteRun>, CiErr> {
        let since = crate::util::rfc3339(since_ms);
        let list = self.api.get_json(&format!(
            "/projects/{}/pipelines?ref={}&updated_after={}&order_by=id&sort=desc&per_page=10",
            self.project,
            enc(&self.git_ref),
            enc(&since)
        ))?;
        for p in list.as_array().cloned().unwrap_or_default().iter().take(10) {
            let id = p["id"].as_u64().unwrap_or(0);
            let vars = self
                .api
                .get_json(&format!(
                    "/projects/{}/pipelines/{id}/variables",
                    self.project
                ))
                .unwrap_or(Value::Null);
            if vars
                .as_array()
                .map(|a| {
                    a.iter()
                        .any(|v| v["key"] == "GITCH_FLOW_CORR" && v["value"] == corr)
                })
                .unwrap_or(false)
            {
                return Ok(Some(RemoteRun {
                    id: id.to_string(),
                    url: p["web_url"].as_str().unwrap_or("").into(),
                    extra: Value::Null,
                }));
            }
        }
        Ok(None)
    }

    fn trigger(&self, corr: &str) -> Result<Triggered, CiErr> {
        let mut vars = vec![json!({"key": "GITCH_FLOW_CORR", "value": corr})];
        for (k, v) in &self.variables {
            vars.push(json!({"key": k, "value": v}));
        }
        let p = self.api.post(
            &format!("/projects/{}/pipeline", self.project),
            &json!({"ref": self.git_ref, "variables": vars}),
        )?;
        match p["id"].as_u64() {
            Some(id) => Ok(Triggered::Created(RemoteRun {
                id: id.to_string(),
                url: p["web_url"].as_str().unwrap_or("").into(),
                extra: Value::Null,
            })),
            None => Ok(Triggered::Accepted(None)),
        }
    }

    fn status(&self, run: &RemoteRun) -> Result<RStatus, CiErr> {
        let p = self
            .api
            .get_json(&format!("/projects/{}/pipelines/{}", self.project, run.id))?;
        let s = p["status"].as_str().unwrap_or("").to_string();
        Ok(RStatus {
            state: state_of(&s),
            conclusion: s,
        })
    }

    fn logs(&self, run: &RemoteRun, cursor: &mut Value) -> Result<Vec<String>, CiErr> {
        let jobs = self.api.get_json(&format!(
            "/projects/{}/pipelines/{}/jobs?per_page=100",
            self.project, run.id
        ))?;
        Ok(job_logs(
            &self.api,
            &self.project,
            jobs.as_array().map(|a| a.as_slice()).unwrap_or(&[]),
            cursor,
        ))
    }

    fn report(&self, run: &RemoteRun) -> Result<Option<TestReport>, CiErr> {
        let r = self.api.get_json(&format!(
            "/projects/{}/pipelines/{}/test_report",
            self.project, run.id
        ))?;
        if r["total_count"].as_u64().unwrap_or(0) == 0 {
            return Ok(None);
        }
        let mut rep = TestReport {
            format: "gitlab-test-report".into(),
            sources: vec![format!("pipeline {}", run.id)],
            ..Default::default()
        };
        for s in r["test_suites"].as_array().cloned().unwrap_or_default() {
            for c in s["test_cases"].as_array().cloned().unwrap_or_default() {
                let status = match c["status"].as_str().unwrap_or("") {
                    "success" => CaseStatus::Passed,
                    "skipped" => CaseStatus::Skipped,
                    _ => CaseStatus::Failed,
                };
                let name = c["name"].as_str().unwrap_or("").to_string();
                let class = c["classname"].as_str().unwrap_or("").to_string();
                rep.cases.push(Case {
                    id: format!("{class}::{name}"),
                    name,
                    file: c["file"].as_str().map(|s| s.to_string()),
                    line: None,
                    status,
                    duration_ms: c["execution_time"]
                        .as_f64()
                        .map(|f| (f * 1000.0) as u64)
                        .unwrap_or(0),
                    message: c["system_output"]
                        .as_str()
                        .map(|m| m.lines().take(4).collect::<Vec<_>>().join("\n")),
                });
            }
        }
        Ok(Some(rep))
    }

    fn contract(&self, run: &RemoteRun) -> Result<Option<Value>, CiErr> {
        let jobs = self.api.get_json(&format!(
            "/projects/{}/pipelines/{}/jobs?per_page=100",
            self.project, run.id
        ))?;
        Ok(artifact_contract(
            &self.api,
            &self.project,
            jobs.as_array().map(|a| a.as_slice()).unwrap_or(&[]),
        ))
    }

    fn cancel(&self, run: &RemoteRun) -> Result<(), CiErr> {
        self.api
            .post(
                &format!("/projects/{}/pipelines/{}/cancel", self.project, run.id),
                &json!({}),
            )
            .map(|_| ())
    }
}

/// 수동 작업 하나를 실행(▶)하고 그 작업만 기다린다.
pub struct ManualJob {
    pub api: Api,
    pub project: String,
    pub git_ref: String,
    pub job: String,
    pub pipeline: Option<String>,
    pub variables: Vec<(String, String)>,
}

impl Provider for ManualJob {
    fn label(&self) -> String {
        format!("GitLab job {} ({})", self.job, self.git_ref)
    }

    fn searchable(&self) -> bool {
        false
    }

    fn find(&self, _corr: &str, _since: u64) -> Result<Option<RemoteRun>, CiErr> {
        // 수동 작업은 이미 돌고 있으면 다시 누를 수 없으니 찾기 대신 상태로 판단한다.
        Ok(None)
    }

    fn trigger(&self, corr: &str) -> Result<Triggered, CiErr> {
        let pid = match &self.pipeline {
            Some(p) => p.clone(),
            None => {
                let list = self.api.get_json(&format!(
                    "/projects/{}/pipelines?ref={}&per_page=1&order_by=id&sort=desc",
                    self.project,
                    enc(&self.git_ref)
                ))?;
                list[0]["id"].as_u64().map(|x| x.to_string()).ok_or(CiErr {
                    code: "CONN-04",
                    http: None,
                    message: tr(
                        "이 브랜치의 파이프라인이 없습니다.",
                        "this branch has no pipeline.",
                    ),
                    unknown_outcome: false,
                    transient: false,
                    retry_after_ms: None,
                })?
            }
        };
        let jobs = self.api.get_json(&format!(
            "/projects/{}/pipelines/{pid}/jobs?per_page=100&include_retried=false",
            self.project
        ))?;
        let job = jobs
            .as_array()
            .and_then(|a| a.iter().find(|j| j["name"] == self.job.as_str()))
            .cloned()
            .ok_or(CiErr {
                code: "CONN-04",
                http: None,
                message: tr(
                    &format!("작업 '{}' 이(가) 파이프라인 {pid} 에 없습니다.", self.job),
                    &format!("job '{}' is not in pipeline {pid}.", self.job),
                ),
                unknown_outcome: false,
                transient: false,
                retry_after_ms: None,
            })?;
        let jid = job["id"].as_u64().unwrap_or(0);
        if job["status"] != "manual" {
            return Err(CiErr {
                code: "CI-06",
                http: None,
                message: tr(
                    &format!(
                        "작업 '{}' 은(는) 수동 대기 상태가 아닙니다({}).",
                        self.job,
                        job["status"].as_str().unwrap_or("")
                    ),
                    &format!(
                        "job '{}' is not waiting for a manual start ({}).",
                        self.job,
                        job["status"].as_str().unwrap_or("")
                    ),
                ),
                unknown_outcome: false,
                transient: false,
                retry_after_ms: None,
            });
        }
        let mut vars = vec![json!({"key": "GITCH_FLOW_CORR", "value": corr})];
        for (k, v) in &self.variables {
            vars.push(json!({"key": k, "value": v}));
        }
        let r = self.api.post(
            &format!("/projects/{}/jobs/{jid}/play", self.project),
            &json!({"job_variables_attributes": vars}),
        )?;
        Ok(Triggered::Created(RemoteRun {
            id: r["id"].as_u64().unwrap_or(jid).to_string(),
            url: r["web_url"].as_str().unwrap_or("").into(),
            extra: json!({"pipeline": pid}),
        }))
    }

    fn status(&self, run: &RemoteRun) -> Result<RStatus, CiErr> {
        let j = self
            .api
            .get_json(&format!("/projects/{}/jobs/{}", self.project, run.id))?;
        let s = j["status"].as_str().unwrap_or("").to_string();
        Ok(RStatus {
            state: state_of(&s),
            conclusion: s,
        })
    }

    fn logs(&self, run: &RemoteRun, cursor: &mut Value) -> Result<Vec<String>, CiErr> {
        let j = self
            .api
            .get_json(&format!("/projects/{}/jobs/{}", self.project, run.id))?;
        Ok(job_logs(&self.api, &self.project, &[j], cursor))
    }

    fn contract(&self, run: &RemoteRun) -> Result<Option<Value>, CiErr> {
        let j = json!({"id": run.id.parse::<u64>().unwrap_or(0)});
        Ok(artifact_contract(&self.api, &self.project, &[j]))
    }

    fn cancel(&self, run: &RemoteRun) -> Result<(), CiErr> {
        self.api
            .post(
                &format!("/projects/{}/jobs/{}/cancel", self.project, run.id),
                &json!({}),
            )
            .map(|_| ())
    }
}

// ---------- CLI ----------

fn api_for(c: &Connection) -> Api {
    Api::new(c, crate::connect::secret(c, false))
}

pub fn cli_status(out: &crate::cli::Out, c: &Connection, project: &str, branch: &str) -> i32 {
    let api = api_for(c);
    let p = enc(project);
    match api.get_json(&format!(
        "/projects/{p}/pipelines?ref={}&per_page=5&order_by=id&sort=desc",
        enc(branch)
    )) {
        Ok(list) => {
            if out.json {
                println!("{}", serde_json::to_string_pretty(&json!({"schemaVersion": 1, "provider": "gitlab", "project": project, "ref": branch, "pipelines": list})).unwrap_or_default());
            } else {
                for pl in list.as_array().cloned().unwrap_or_default() {
                    println!(
                        "#{:<8} {:<10} {}  {}",
                        pl["id"],
                        pl["status"].as_str().unwrap_or(""),
                        pl["updated_at"].as_str().unwrap_or(""),
                        pl["web_url"].as_str().unwrap_or("")
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

pub fn cli_report(
    out: &crate::cli::Out,
    c: &Connection,
    project: &str,
    pipeline: Option<&str>,
) -> i32 {
    let api = api_for(c);
    let p = enc(project);
    let pid = match pipeline {
        Some(x) => x.to_string(),
        None => match api.get_json(&format!(
            "/projects/{p}/pipelines?per_page=1&order_by=id&sort=desc"
        )) {
            Ok(l) => l[0]["id"]
                .as_u64()
                .map(|x| x.to_string())
                .unwrap_or_default(),
            Err(e) => {
                eprintln!("{}", e.message);
                return 1;
            }
        },
    };
    match api.get_json(&format!(
        "/projects/{p}/pipelines/{pid}/test_report_summary"
    )) {
        Ok(s) => {
            if out.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(
                        &json!({"schemaVersion": 1, "pipeline": pid, "summary": s})
                    )
                    .unwrap_or_default()
                );
            } else {
                let t = &s["total"];
                println!(
                    "{} {pid}: {} {} · {} {} · {} {}",
                    tr("파이프라인", "pipeline"),
                    t["count"],
                    tr("개", "tests"),
                    t["success"],
                    tr("통과", "passed"),
                    t["failed"],
                    tr("실패", "failed")
                );
            }
            0
        }
        Err(e) => {
            eprintln!("{}", e.message);
            1
        }
    }
}

pub fn cli_logs(_out: &crate::cli::Out, c: &Connection, project: &str, job: &str) -> i32 {
    let api = api_for(c);
    let masker = crate::mask::Masker::new();
    if let Some(t) = &api.token {
        masker.add_secret("TOKEN", t);
    }
    match api.get(&format!(
        "/projects/{}/jobs/{}/trace",
        enc(project),
        enc(job)
    )) {
        Ok(r) => {
            print!("{}", masker.mask(&r.body));
            0
        }
        Err(e) => {
            eprintln!("{}", e.message);
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_paths() {
        assert_eq!(enc("group/sub/repo"), "group%2Fsub%2Frepo");
        assert_eq!(enc("feature/x y"), "feature%2Fx%20y");
        assert_eq!(enc("a-b_c.d~"), "a-b_c.d~");
    }

    #[test]
    fn states() {
        assert_eq!(state_of("success"), RState::Succeeded);
        assert_eq!(state_of("manual"), RState::Waiting);
        assert_eq!(state_of("canceled"), RState::Cancelled);
        assert_eq!(state_of("pending"), RState::Queued);
    }
}
