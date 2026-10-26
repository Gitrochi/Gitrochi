//! 가짜 GitLab · GitHub · Jenkins · HTTP CI 서버로 보는 원격 CI 운전 규칙:
//! 상관 ID · 보내기 전에 찾기 · 응답을 잃은 트리거는 다시 보내지 않기(CI-01) · 외부 취소(CI-04) ·
//! 결과 계약(CI-02 · CI-03) · 인증(CONN-02) · 속도 제한 · 마감 뒤 원격 취소(CI-05) · 허용 목록(CI-07) ·
//! 다른 출처로 가는 리다이렉트에 토큰을 싣지 않기.

mod common;

use common::fake::{Req, Resp, Server};
use common::Fx;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

/// 시험용 토큰(알려진 토큰 접두를 쓰지 않는다).
fn token() -> String {
    format!("ci-token-{}-Zq9xK", std::process::id())
}

fn node<'a>(run: &'a Value, id: &str) -> &'a Value {
    run["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("no node {id} in {run}"))
}

fn fixture(flow: &str) -> Fx {
    let fx = Fx::new(&[(".gitch/flow.yml", flow)]);
    fx.trust();
    fx
}

fn add_conn(fx: &Fx, kind: &str, name: &str, url: &str, extra: &[&str]) {
    let mut args = vec![
        "connect",
        "add",
        kind,
        "--name",
        name,
        "--url",
        url,
        "--secret-from",
        "env:FAKE_CI_TOKEN",
    ];
    args.extend_from_slice(extra);
    let (code, out, err) = fx.run("script", &args);
    assert_eq!(code, 0, "{out}{err}");
    let (_, list) = fx.json("script", &["connect", "list", "--json"]);
    assert!(
        list["connections"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["name"] == name && c["url"] == url),
        "{list}"
    );
}

fn run_flow(fx: &Fx, flow: &str) -> (i32, Value) {
    let mut c = fx.cmd("script", &["run", flow, "--json"]);
    c.env("FAKE_CI_TOKEN", token());
    let o = c.output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    let v = serde_json::from_str(&out)
        .unwrap_or_else(|_| panic!("not json: {out}\n{}", String::from_utf8_lossy(&o.stderr)));
    (o.status.code().unwrap_or(-1), v)
}

fn node_log(run: &Value, id: &str) -> String {
    let dir = std::path::Path::new(run["runDir"].as_str().unwrap());
    std::fs::read_to_string(dir.join("logs").join(format!("{id}.log"))).unwrap_or_default()
}

fn contract(state: &str) -> Value {
    json!({"schemaVersion": 1, "runId": "20261026-000000-abc123", "flow": "ci", "env": "ci", "state": state,
           "git": {"sha": "abc"}, "counts": {"passed": 3, "failed": if state == "SUCCEEDED" { 0 } else { 1 }}, "nodes": []})
}

fn marker(state: &str) -> String {
    format!(
        "GITCH-FLOW-RESULT {}",
        json!({"v": 1, "runId": "r", "state": state, "counts": {}})
    )
}

// ---------- GitLab ----------

#[derive(Clone, Copy, PartialEq)]
enum Post {
    Normal,
    /// 만들고 응답은 잃음.
    DropAfterCreate,
    /// 만들지도 않고 응답도 없음.
    DropWithoutCreate,
}

struct Gl {
    post: Post,
    statuses: Vec<&'static str>,
    contract: Option<&'static str>,
    marker: Option<&'static str>,
    trace_redirect: Option<String>,
    rate_limit_once: bool,
    pipelines: Vec<Pl>,
}

/// 가짜 파이프라인: 변수 · 상태를 몇 번 물었는지 · 우리가 취소했는지.
struct Pl {
    id: u64,
    vars: Vec<(String, String)>,
    polls: usize,
    cancelled: bool,
}

impl Gl {
    fn new(statuses: &[&'static str]) -> Gl {
        Gl {
            post: Post::Normal,
            statuses: statuses.to_vec(),
            contract: Some("SUCCEEDED"),
            marker: None,
            trace_redirect: None,
            rate_limit_once: false,
            pipelines: Vec::new(),
        }
    }
}

const P: &str = "/api/v4/projects/grp%2Fapp";

fn gitlab(state: Gl) -> (Server, Arc<Mutex<Gl>>) {
    let st = Arc::new(Mutex::new(state));
    let s2 = st.clone();
    let tok = token();
    let srv = Server::start(move |r: &Req| {
        if r.header("PRIVATE-TOKEN") != Some(tok.as_str()) {
            return Some(Resp::json(json!({"message": "401 Unauthorized"})).code(401));
        }
        let mut g = s2.lock().unwrap();
        let path = r.path.strip_prefix(P)?.to_string();
        if r.method == "POST" && path == "/pipeline" {
            let body: Value = serde_json::from_str(&r.body).unwrap_or(Value::Null);
            let vars: Vec<(String, String)> = body["variables"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| {
                    (
                        v["key"].as_str().unwrap().to_string(),
                        v["value"].as_str().unwrap().to_string(),
                    )
                })
                .collect();
            let id = 500 + g.pipelines.len() as u64;
            if g.post != Post::DropWithoutCreate {
                g.pipelines.push(Pl {
                    id,
                    vars,
                    polls: 0,
                    cancelled: false,
                });
            }
            return match g.post {
                Post::Normal => Some(Resp::json(
                    json!({"id": id, "web_url": format!("http://gl/p/{id}"), "status": "created"}),
                ).code(201)),
                _ => None,
            };
        }
        if r.method == "GET" && path == "/pipelines" {
            let list: Vec<Value> = g
                .pipelines
                .iter()
                .rev()
                .map(|p| json!({"id": p.id, "web_url": format!("http://gl/p/{}", p.id), "status": "running"}))
                .collect();
            return Some(Resp::json(Value::Array(list)));
        }
        let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
        match (r.method.as_str(), parts.as_slice()) {
            ("GET", ["pipelines", id, "variables"]) => {
                let id: u64 = id.parse().ok()?;
                let p = g.pipelines.iter().find(|p| p.id == id)?;
                let v: Vec<Value> = p
                    .vars
                    .iter()
                    .map(|(k, v)| json!({"key": k, "value": v}))
                    .collect();
                Some(Resp::json(Value::Array(v)))
            }
            ("GET", ["pipelines", id]) => {
                if g.rate_limit_once {
                    g.rate_limit_once = false;
                    return Some(
                        Resp::json(json!({"message": "slow down"}))
                            .code(429)
                            .header("Retry-After", "1"),
                    );
                }
                let id: u64 = id.parse().ok()?;
                let statuses = g.statuses.clone();
                let p = g.pipelines.iter_mut().find(|p| p.id == id)?;
                let s = if p.cancelled {
                    "canceled"
                } else {
                    statuses[p.polls.min(statuses.len() - 1)]
                };
                p.polls += 1;
                Some(Resp::json(
                    json!({"id": id, "status": s, "web_url": format!("http://gl/p/{id}")}),
                ))
            }
            ("GET", ["pipelines", id, "jobs"]) => {
                let id: u64 = id.parse().ok()?;
                let statuses = g.statuses.clone();
                let p = g.pipelines.iter().find(|p| p.id == id)?;
                let s = if p.cancelled {
                    "canceled"
                } else {
                    statuses[p.polls.saturating_sub(1).min(statuses.len() - 1)]
                };
                let job = match s {
                    "created" | "pending" => "pending",
                    other => other,
                };
                Some(Resp::json(
                    json!([{"id": id + 1000, "name": "flow", "status": job}]),
                ))
            }
            ("GET", ["pipelines", _, "test_report"]) => {
                Some(Resp::json(json!({"total_count": 0, "test_suites": []})))
            }
            ("POST", ["pipelines", id, "cancel"]) => {
                let id: u64 = id.parse().ok()?;
                if let Some(p) = g.pipelines.iter_mut().find(|p| p.id == id) {
                    p.cancelled = true;
                }
                Some(Resp::json(json!({"id": id, "status": "canceling"})))
            }
            ("GET", ["jobs", jid, "trace"]) => {
                if let Some(other) = &g.trace_redirect {
                    return Some(
                        Resp::status(302).header("Location", &format!("{other}/trace/{jid}")),
                    );
                }
                let mut t = format!("$ gitch flow run ci --ci\nusing {} for clone\n", token());
                if let Some(m) = g.marker {
                    t.push_str(&marker(m));
                    t.push('\n');
                }
                Some(Resp::text(200, &t))
            }
            ("GET", ["jobs", _, "artifacts", "gitch-flow-out", "gitch-flow-result.json"]) => {
                match g.contract {
                    Some(s) => Some(Resp::json(contract(s))),
                    None => Some(Resp::json(json!({"message": "404 Not Found"})).code(404)),
                }
            }
            _ => Some(Resp::json(json!({"message": "404 Not Found"})).code(404)),
        }
    });
    (srv, st)
}

fn gl_flow(extra: &str) -> String {
    let timeout = if extra.contains("timeout:") {
        ""
    } else {
        ", timeout: 20s"
    };
    format!(
        "version: 1\nflows:\n  remote:\n    nodes:\n      ci:\n        use: ci.gitlab.pipeline\n        with: {{ connection: gl, project: grp/app, ref: main, poll: 200ms, findTimeout: 1500ms{timeout}{extra} }}\n"
    )
}

fn gl_setup(state: Gl, extra: &str) -> (Fx, Server, Arc<Mutex<Gl>>) {
    let (srv, st) = gitlab(state);
    let fx = fixture(&gl_flow(extra));
    add_conn(&fx, "gitlab", "gl", &srv.base, &["--allow", "pipeline:*"]);
    (fx, srv, st)
}

#[test]
fn gitlab_pipeline_passes_on_the_result_contract() {
    let (fx, srv, st) = gl_setup(Gl::new(&["created", "running", "running", "success"]), "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "PASSED", "{ci}");
    assert_eq!(srv.count("POST", "/pipeline"), 1);
    // 상관 ID 는 실행 · 노드에서 만들고 파이프라인 변수로 보낸다.
    let corr = ci["observations"]["correlation"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(corr.starts_with(&format!("gitch-{}", run["runId"].as_str().unwrap())));
    let g = st.lock().unwrap();
    assert!(g.pipelines[0]
        .vars
        .contains(&("GITCH_FLOW_CORR".into(), corr)));
    // 원격 로그에 섞여 온 토큰은 가린다.
    let log = node_log(&run, "ci");
    assert!(log.contains("[flow] $ gitch flow run ci --ci"), "{log}");
    assert!(!log.contains(&token()), "token leaked into the node log");
}

#[test]
fn gitlab_lost_trigger_response_is_found_not_resent() {
    let mut g = Gl::new(&["running", "success"]);
    g.post = Post::DropAfterCreate;
    let (fx, srv, _st) = gl_setup(g, "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "ci")["state"], "PASSED");
    assert_eq!(
        srv.count("POST", "/pipeline"),
        1,
        "the trigger must not be re-sent"
    );
}

#[test]
fn gitlab_lost_trigger_that_never_ran_is_unknown_ci01() {
    let mut g = Gl::new(&["success"]);
    g.post = Post::DropWithoutCreate;
    let (fx, srv, _st) = gl_setup(g, "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1, "{run}");
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "INDETERMINATE", "{ci}");
    assert_eq!(ci["code"], "CI-01");
    assert_eq!(srv.count("POST", "/pipeline"), 1);
}

#[test]
fn gitlab_cancel_by_someone_else_is_ci04() {
    let (fx, srv, _st) = gl_setup(Gl::new(&["running", "canceled"]), "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1);
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "FAILED", "{ci}");
    assert_eq!(ci["code"], "CI-04");
    assert_eq!(srv.count("POST", "/cancel"), 0);
}

#[test]
fn gitlab_success_without_contract_is_indeterminate_ci03() {
    let mut g = Gl::new(&["running", "success"]);
    g.contract = None;
    let (fx, _srv, _st) = gl_setup(g, "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1);
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "INDETERMINATE", "{ci}");
    assert_eq!(ci["code"], "CI-03");
}

#[test]
fn gitlab_contract_failure_beats_a_green_pipeline_ci02() {
    let mut g = Gl::new(&["running", "success"]);
    g.contract = Some("FAILED");
    let (fx, _srv, _st) = gl_setup(g, "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1);
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "FAILED", "{ci}");
    assert_eq!(ci["code"], "CI-02");
}

#[test]
fn gitlab_log_marker_is_used_when_there_is_no_artifact() {
    let mut g = Gl::new(&["running", "success"]);
    g.contract = None;
    g.marker = Some("SUCCEEDED");
    let (fx, _srv, _st) = gl_setup(g, "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "ci")["state"], "PASSED");
}

#[test]
fn gitlab_rate_limit_waits_and_continues() {
    let mut g = Gl::new(&["running", "success"]);
    g.rate_limit_once = true;
    let (fx, srv, _st) = gl_setup(g, "");
    let t0 = std::time::Instant::now();
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert!(
        t0.elapsed() >= std::time::Duration::from_millis(900),
        "Retry-After was not honoured"
    );
    assert!(srv.count("GET", "/pipelines/500") >= 3);
}

#[test]
fn gitlab_deadline_cancels_the_remote_pipeline_ci05() {
    let (fx, srv, _st) = gl_setup(Gl::new(&["running"]), ", timeout: 2s");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1);
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "FAILED", "{ci}");
    assert_eq!(ci["code"], "CI-05");
    assert_eq!(srv.count("POST", "/cancel"), 1);
}

#[test]
fn gitlab_bad_token_is_conn02_and_nothing_is_sent() {
    let (srv, _st) = gitlab(Gl::new(&["success"]));
    let fx = fixture(&gl_flow(""));
    add_conn(&fx, "gitlab", "gl", &srv.base, &[]);
    let mut c = fx.cmd("script", &["run", "remote", "--json"]);
    c.env("FAKE_CI_TOKEN", "wrong-token-value");
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(1));
    let run: Value = serde_json::from_slice(&o.stdout).unwrap();
    let ci = node(&run, "ci");
    assert_eq!(ci["code"], "CONN-02", "{ci}");
    assert_eq!(srv.count("POST", "/pipeline"), 0);
}

#[test]
fn allow_list_rejects_before_anything_is_sent_ci07() {
    let (srv, _st) = gitlab(Gl::new(&["success"]));
    let fx = fixture(&gl_flow(""));
    add_conn(
        &fx,
        "gitlab",
        "gl",
        &srv.base,
        &["--allow", "pipeline:release"],
    );
    let (code, run) = run_flow(&fx, "remote");
    assert_ne!(code, 0, "{run}");
    let ci = node(&run, "ci");
    assert_eq!(ci["state"], "REJECTED", "{ci}");
    assert_eq!(ci["code"], "CI-07");
    assert!(
        srv.requests().is_empty(),
        "nothing may be sent for a rejected node"
    );
}

#[test]
fn redirects_to_another_host_never_carry_the_token() {
    let storage = Server::start(|r: &Req| {
        Some(Resp::text(
            200,
            &format!("from storage {}\n{}\n", r.path, marker("SUCCEEDED")),
        ))
    });
    let mut g = Gl::new(&["running", "success"]);
    g.contract = None;
    g.trace_redirect = Some(storage.base.clone());
    let (fx, _srv, _st) = gl_setup(g, "");
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    let reqs = storage.requests();
    assert!(!reqs.is_empty());
    for r in reqs {
        assert!(
            r.header("PRIVATE-TOKEN").is_none(),
            "token sent to {}",
            r.path
        );
    }
    assert!(node_log(&run, "ci").contains("from storage /trace/"));
}

// ---------- GitHub ----------

struct Gh {
    dispatched: Vec<Value>,
    polls: usize,
    old_run: bool,
    rate_limit_once: bool,
}

fn github(old_run: bool) -> (Server, Arc<Mutex<Gh>>) {
    let st = Arc::new(Mutex::new(Gh {
        dispatched: Vec::new(),
        polls: 0,
        old_run,
        rate_limit_once: false,
    }));
    let s2 = st.clone();
    let tok = token();
    let srv: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let base_cell = srv.clone();
    let server = Server::start(move |r: &Req| {
        if r.path.starts_with("/logstore/") {
            // 로그 저장소 — 인증 없이 와야 한다(인증이 오면 표식 없는 로그를 줘서 시험이 실패하게).
            if r.header("Authorization").is_some() {
                return Some(Resp::text(400, "credentials must not be sent here"));
            }
            return Some(Resp::text(
                200,
                &format!(
                    "2026-10-26T00:00:00.0000000Z step ok\n2026-10-26T00:00:01.0000000Z {}\n",
                    marker("SUCCEEDED")
                ),
            ));
        }
        if r.header("Authorization") != Some(format!("Bearer {tok}").as_str()) {
            return Some(Resp::json(json!({"message": "Bad credentials"})).code(401));
        }
        let mut g = s2.lock().unwrap();
        let wf = "/repos/own/app/actions/workflows/flow.yml";
        if r.is("POST", &format!("{wf}/dispatches")) {
            g.dispatched.push(serde_json::from_str(&r.body).unwrap());
            return Some(Resp::status(204));
        }
        if r.is("GET", &format!("{wf}/runs")) {
            if g.rate_limit_once {
                g.rate_limit_once = false;
                let reset = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs()
                    + 1;
                return Some(
                    Resp::json(json!({"message": "API rate limit exceeded"}))
                        .code(403)
                        .header("x-ratelimit-remaining", "0")
                        .header("x-ratelimit-reset", &reset.to_string()),
                );
            }
            let mut runs = Vec::new();
            if g.old_run {
                runs.push(
                    json!({"id": 1, "display_title": "older run", "html_url": "http://gh/r/1"}),
                );
            }
            for (i, d) in g.dispatched.iter().enumerate() {
                let corr = d["inputs"]["gitch_flow_corr"].as_str().unwrap_or("");
                runs.push(json!({"id": 10 + i, "display_title": format!("flow [{corr}]"), "html_url": format!("http://gh/r/{}", 10 + i)}));
            }
            return Some(Resp::json(json!({"workflow_runs": runs})));
        }
        if r.method == "GET" && r.path.starts_with("/repos/own/app/actions/runs/") {
            let rest = r.path.trim_start_matches("/repos/own/app/actions/runs/");
            if rest.ends_with("/jobs") {
                return Some(Resp::json(
                    json!({"jobs": [{"id": 77, "name": "flow", "status": if g.polls >= 2 { "completed" } else { "in_progress" }}]}),
                ));
            }
            g.polls += 1;
            let (status, conclusion) = if g.polls >= 2 {
                ("completed", "success")
            } else {
                ("in_progress", "")
            };
            return Some(Resp::json(
                json!({"status": status, "conclusion": if conclusion.is_empty() { Value::Null } else { json!(conclusion) }}),
            ));
        }
        if r.is("GET", "/repos/own/app/actions/jobs/77/logs") {
            let base = base_cell.lock().unwrap().clone().unwrap();
            return Some(Resp::status(302).header("Location", &format!("{base}/logstore/77.txt")));
        }
        Some(Resp::json(json!({"message": "Not Found"})).code(404))
    });
    *srv.lock().unwrap() = Some(server.base.clone());
    (server, st)
}

fn gh_flow(extra: &str) -> String {
    format!("version: 1\nflows:\n  remote:\n    nodes:\n      gha:\n        use: ci.github.workflow\n        with: {{ connection: gh, repo: own/app, workflow: flow.yml, ref: main, poll: 200ms, findTimeout: 3s{extra} }}\n")
}

#[test]
fn github_dispatch_is_found_by_run_name_and_judged_by_the_log_marker() {
    let (srv, st) = github(true);
    let fx = fixture(&gh_flow(""));
    add_conn(&fx, "github", "gh", &srv.base, &[]);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    let n = node(&run, "gha");
    assert_eq!(n["state"], "PASSED", "{n}");
    assert_eq!(n["observations"]["remote"], "http://gh/r/10");
    let g = st.lock().unwrap();
    assert_eq!(g.dispatched.len(), 1);
    assert_eq!(g.dispatched[0]["ref"], "main");
    assert!(g.dispatched[0]["inputs"]["gitch_flow_corr"]
        .as_str()
        .unwrap()
        .starts_with("gitch-"));
}

#[test]
fn github_without_a_correlation_input_picks_the_new_run() {
    let (srv, st) = github(true);
    let fx = fixture(&gh_flow(", correlate: false"));
    add_conn(&fx, "github", "gh", &srv.base, &[]);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert_eq!(
        node(&run, "gha")["observations"]["remote"],
        "http://gh/r/10"
    );
    assert!(st.lock().unwrap().dispatched[0]["inputs"]["gitch_flow_corr"].is_null());
}

#[test]
fn github_rate_limit_is_waited_out() {
    let (srv, st) = github(false);
    st.lock().unwrap().rate_limit_once = true;
    let fx = fixture(&gh_flow(""));
    add_conn(&fx, "github", "gh", &srv.base, &[]);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert_eq!(st.lock().unwrap().dispatched.len(), 1);
}

// ---------- Jenkins ----------

struct Jk {
    queued_polls: usize,
    build_polls: usize,
    result: &'static str,
    queue_cancelled: bool,
    posts: Vec<(String, Option<String>)>,
}

fn jenkins(result: &'static str, queue_cancelled: bool) -> (Server, Arc<Mutex<Jk>>) {
    let st = Arc::new(Mutex::new(Jk {
        queued_polls: 0,
        build_polls: 0,
        result,
        queue_cancelled,
        posts: Vec::new(),
    }));
    let s2 = st.clone();
    let basic = format!("Basic {}", b64(&format!("bot:{}", token())));
    let base_cell: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let bc = base_cell.clone();
    let server = Server::start(move |r: &Req| {
        if r.header("Authorization") != Some(basic.as_str()) {
            return Some(Resp::text(401, "unauthorized"));
        }
        let mut j = s2.lock().unwrap();
        let base = bc.lock().unwrap().clone().unwrap();
        let job = "/job/team/job/app";
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/crumbIssuer/api/json") => Some(Resp::json(
                json!({"crumbRequestField": "Jenkins-Crumb", "crumb": "c-123"}),
            )),
            ("GET", p) if p == format!("{job}/api/json") => Some(Resp::json(json!({"builds": []}))),
            ("POST", p) if p == format!("{job}/buildWithParameters") => {
                j.posts.push((
                    r.query.clone(),
                    r.header("Jenkins-Crumb").map(|s| s.to_string()),
                ));
                Some(Resp::status(201).header("Location", &format!("{base}/queue/item/9/")))
            }
            ("GET", "/queue/item/9/api/json") => {
                j.queued_polls += 1;
                if j.queue_cancelled {
                    return Some(Resp::json(json!({"cancelled": true})));
                }
                if j.queued_polls < 2 {
                    Some(Resp::json(json!({"why": "waiting for executor"})))
                } else {
                    // Jenkins 의 루트 주소가 내부 이름으로 잡혀 있어도 엔진은 연결 주소로만 묻는다.
                    Some(Resp::json(
                        json!({"executable": {"number": 42, "url": "http://jenkins.internal.invalid:8080/job/team/job/app/42/"}}),
                    ))
                }
            }
            ("GET", p) if p == format!("{job}/42/api/json") => {
                j.build_polls += 1;
                if j.build_polls < 2 {
                    Some(Resp::json(json!({"building": true, "result": null})))
                } else {
                    Some(Resp::json(json!({"building": false, "result": j.result})))
                }
            }
            ("GET", p) if p == format!("{job}/42/logText/progressiveText") => {
                let text = "Started by gitch-flow\nall good\n";
                let start: usize = r.param("start").and_then(|s| s.parse().ok()).unwrap_or(0);
                Some(
                    Resp::text(200, text.get(start..).unwrap_or(""))
                        .header("X-Text-Size", &text.len().to_string()),
                )
            }
            ("GET", p)
                if p == format!("{job}/42/artifact/gitch-flow-out/gitch-flow-result.json") =>
            {
                Some(Resp::json(contract("SUCCEEDED")))
            }
            ("GET", p) if p == format!("{job}/42/testReport/api/json") => Some(Resp::status(404)),
            ("POST", p) if p == format!("{job}/42/stop") => Some(Resp::status(302)),
            _ => Some(Resp::status(404)),
        }
    });
    *base_cell.lock().unwrap() = Some(server.base.clone());
    (server, st)
}

fn b64(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in s.as_bytes().chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

const JK_FLOW: &str = "version: 1\nflows:\n  remote:\n    nodes:\n      build:\n        use: ci.jenkins.job\n        with: { connection: jk, job: team/app, parameters: { TARGET: \"a b\" }, poll: 200ms, findTimeout: 3s }\n";

#[test]
fn jenkins_queue_to_build_with_crumb_and_rebased_urls() {
    let (srv, st) = jenkins("SUCCESS", false);
    let fx = fixture(JK_FLOW);
    add_conn(&fx, "jenkins", "jk", &srv.base, &["--user", "bot"]);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "build")["state"], "PASSED");
    let j = st.lock().unwrap();
    assert_eq!(j.posts.len(), 1);
    let (query, crumb) = &j.posts[0];
    assert_eq!(crumb.as_deref(), Some("c-123"));
    assert!(query.contains("GITCH_FLOW_CORR=gitch-"), "{query}");
    assert!(query.contains("TARGET=a%20b"), "{query}");
    assert!(node_log(&run, "build").contains("all good"));
}

#[test]
fn jenkins_abort_by_someone_else_is_ci04() {
    let (srv, _st) = jenkins("ABORTED", false);
    let fx = fixture(JK_FLOW);
    add_conn(&fx, "jenkins", "jk", &srv.base, &["--user", "bot"]);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1);
    assert_eq!(node(&run, "build")["code"], "CI-04");
    assert_eq!(srv.count("POST", "/stop"), 0);
}

#[test]
fn jenkins_cancelled_queue_item_is_ci04() {
    let (srv, _st) = jenkins("SUCCESS", true);
    let fx = fixture(JK_FLOW);
    add_conn(&fx, "jenkins", "jk", &srv.base, &["--user", "bot"]);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 1);
    assert_eq!(node(&run, "build")["code"], "CI-04", "{run}");
}

// ---------- 일반 HTTP CI ----------

#[test]
fn http_ci_drives_trigger_status_and_logs_with_encoded_ids() {
    let polls = Arc::new(Mutex::new(0usize));
    let p2 = polls.clone();
    let srv = Server::start(move |r: &Req| match (r.method.as_str(), r.path.as_str()) {
        ("POST", "/builds") => Some(Resp::json(json!({"build": {"id": "team/42"}})).code(201)),
        ("GET", "/builds/team%2F42") => {
            let mut n = p2.lock().unwrap();
            *n += 1;
            Some(Resp::json(
                json!({"state": if *n >= 2 { "passed" } else { "running" }}),
            ))
        }
        ("GET", "/builds/team%2F42/log") => Some(Resp::text(
            200,
            &format!("hello\n{}\n", marker("SUCCEEDED")),
        )),
        _ => Some(Resp::status(404)),
    });
    let flow = format!(
        "version: 1\nflows:\n  remote:\n    nodes:\n      deploy:\n        use: ci.http\n        with:\n          trigger: {{ url: \"{b}/builds\", method: POST, body: {{ corr: \"{{corr}}\" }} }}\n          id: /build/id\n          status: {{ url: \"{b}/builds/{{id}}\", pointer: /state }}\n          logs: {{ url: \"{b}/builds/{{id}}/log\" }}\n          poll: 200ms\n",
        b = srv.base
    );
    let fx = fixture(&flow);
    let (code, run) = run_flow(&fx, "remote");
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "deploy")["state"], "PASSED");
    let posted = srv
        .requests()
        .into_iter()
        .find(|r| r.method == "POST")
        .unwrap();
    assert!(posted.body.contains("\"corr\":\"gitch-"), "{}", posted.body);
}
