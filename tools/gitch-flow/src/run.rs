//! 실행기: 계획대로 노드를 병렬로 돌리고(needs · 잠금 · 슬롯), 판정을 모아 실행 상태를 정한다.
//! 상태 전이는 한 표에서만 허용하고, 표에 없는 전이는 엔진 버그(ENGINE-01)로 기록한다.

use crate::blocks::{self, NodeCx, NodeResult};
use crate::expr::{self, Ctx, StatusCtx};
use crate::mask::Masker;
use crate::plan::{Decision, PNode, Plan};
use crate::process::Cancel;
use crate::report::CaseStatus;
use crate::services::{self, Running, SvcCx};
use crate::spec::{EnvPolicy, Spec};
use crate::store::{self, Events, Lock, Store};
use crate::util::{self, tr};
use crate::verify::{self, Outcome};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NState {
    Pending,
    Running,
    Passed,
    Failed,
    Indeterminate,
    Skipped,
    Cached,
    Rejected,
    Cancelled,
}

impl NState {
    pub fn as_str(&self) -> &'static str {
        match self {
            NState::Pending => "PENDING",
            NState::Running => "RUNNING",
            NState::Passed => "PASSED",
            NState::Failed => "FAILED",
            NState::Indeterminate => "INDETERMINATE",
            NState::Skipped => "SKIPPED",
            NState::Cached => "CACHED",
            NState::Rejected => "REJECTED",
            NState::Cancelled => "CANCELLED",
        }
    }
    pub fn terminal(&self) -> bool {
        !matches!(self, NState::Pending | NState::Running)
    }
    pub fn bad(&self) -> bool {
        matches!(
            self,
            NState::Failed | NState::Indeterminate | NState::Rejected | NState::Cancelled
        )
    }
}

/// 노드 상태 전이 표.
pub fn node_transition_ok(from: NState, to: NState) -> bool {
    use NState::*;
    matches!(
        (from, to),
        (Pending, Running)
            | (Pending, Skipped)
            | (Pending, Cancelled)
            | (Pending, Rejected)
            | (Pending, Cached)
            | (Running, Passed)
            | (Running, Failed)
            | (Running, Indeterminate)
            | (Running, Cancelled)
            | (Running, Rejected)
    )
}

/// 실행 상태 전이 표.
pub fn run_transition_ok(from: &str, to: &str) -> bool {
    matches!(
        (from, to),
        ("PENDING", "PREFLIGHT")
            | ("PENDING", "REJECTED")
            | ("PREFLIGHT", "RUNNING")
            | ("PREFLIGHT", "REJECTED")
            | ("RUNNING", "SUCCEEDED")
            | ("RUNNING", "FAILED")
            | ("RUNNING", "CANCELLED")
            | ("RUNNING", "REJECTED")
            | ("FAILED", "ROLLING_BACK")
            | ("CANCELLED", "ROLLING_BACK")
            | ("ROLLING_BACK", "ROLLED_BACK")
            | ("ROLLING_BACK", "ROLLBACK_FAILED")
    )
}

#[derive(Debug, Clone, Default)]
pub struct RunOptions {
    pub jobs: usize,
    pub fail_fast: Option<bool>,
    pub yes: bool,
    pub interactive: bool,
    pub ci: bool,
    pub events_stdout: bool,
    pub human: bool,
    pub idempotency_key: Option<String>,
    pub run_id: Option<String>,
    pub keep_services: bool,
    pub trigger: String,
    pub actor: String,
}

pub struct RunResult {
    pub summary: Value,
    pub exit_code: i32,
}

static INTERRUPTED: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn on_signal(_: libc::c_int) {
    INTERRUPTED.store(true, Ordering::SeqCst);
}

fn install_signals() {
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
    }
    #[cfg(windows)]
    unsafe {
        unsafe extern "system" fn handler(_: u32) -> i32 {
            INTERRUPTED.store(true, Ordering::SeqCst);
            1
        }
        windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(handler), 1);
    }
}

/// 표현식 맥락.
struct Xc<'a> {
    roots: Map<String, Value>,
    root: &'a Path,
}

impl Ctx for Xc<'_> {
    fn lookup(&self, path: &[String]) -> Option<Value> {
        let mut v = self.roots.get(&path[0])?;
        for p in &path[1..] {
            v = match v {
                Value::Object(o) => o.get(p)?,
                Value::Array(a) => a.get(p.parse::<usize>().ok()?)?,
                _ => return None,
            };
        }
        Some(v.clone())
    }
    fn hash_files(&self, globs: &[String]) -> Option<String> {
        let files = crate::git::ls_files(self.root);
        let mut s = String::new();
        for f in files
            .iter()
            .filter(|f| globs.iter().any(|g| util::glob_match(g, f)))
        {
            let data = std::fs::read(self.root.join(f)).ok()?;
            s.push_str(&format!("{f}\0{}\n", util::sha256_hex(&data)));
        }
        Some(util::sha256_hex(s.as_bytes()))
    }
}

/// 조건 평가용 상태: 직접 needs 의 결과.
struct St {
    needs_bad: bool,
    cancelled: bool,
    parent_failed: Option<bool>,
    changed: Option<Vec<String>>,
}

impl StatusCtx for St {
    fn status(&self, f: &str, args: &[String]) -> Option<bool> {
        Some(match f {
            "success" => {
                !self.needs_bad && !self.cancelled && self.parent_failed.map(|p| !p).unwrap_or(true)
            }
            "failure" => self.needs_bad || self.parent_failed.unwrap_or(false),
            "always" => true,
            "cancelled" => self.cancelled,
            "changed" => match &self.changed {
                // 바뀐 파일을 모르면 바뀐 것으로 본다(보수적으로 실행).
                None => true,
                Some(files) => files
                    .iter()
                    .any(|x| args.iter().any(|g| util::glob_match(g, x))),
            },
            _ => return None,
        })
    }
}

const CORE_ENV: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "TERM",
    "TMPDIR",
    "TMP",
    "TEMP",
    "TZ",
    "SYSTEMROOT",
    "SystemRoot",
    "WINDIR",
    "windir",
    "COMSPEC",
    "ComSpec",
    "PATHEXT",
    "APPDATA",
    "LOCALAPPDATA",
    "USERPROFILE",
    "PROGRAMDATA",
    "ProgramData",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "ProgramW6432",
    "SystemDrive",
    "HOMEDRIVE",
    "HOMEPATH",
    "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE",
    "OS",
    "CI",
    "JAVA_HOME",
    "GOPATH",
    "GOROOT",
    "GOCACHE",
    "CARGO_HOME",
    "RUSTUP_HOME",
    "NVM_DIR",
    "PYENV_ROOT",
    "VIRTUAL_ENV",
    "DOCKER_HOST",
    "DOCKER_CONTEXT",
    "SSH_AUTH_SOCK",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "MSYSTEM",
    "EXEPATH",
    "ANDROID_HOME",
    "ANDROID_SDK_ROOT",
    "DEVELOPER_DIR",
    "SDKROOT",
];

/// 하위 프로세스에 물려줄 호스트 환경.
fn base_env(spec: &Spec, ci: bool) -> Vec<(String, String)> {
    let allow: HashSet<&str> = spec.defaults.env.iter().map(|s| s.as_str()).collect();
    let mut out = Vec::new();
    for (k, v) in std::env::vars() {
        let keep = match spec.defaults.env_policy {
            EnvPolicy::Inherit => {
                allow.contains(k.as_str())
                    || (!crate::secret::looks_secret(&k)
                        && !k.starts_with("GITSW_")
                        && !k.starts_with("GITCH_FLOW_INTERNAL"))
            }
            EnvPolicy::Allowlist => {
                allow.contains(k.as_str()) || CORE_ENV.contains(&k.as_str()) || k.starts_with("LC_")
            }
        };
        if keep {
            out.push((k, v));
        }
    }
    if ci && !out.iter().any(|(k, _)| k == "CI") {
        out.push(("CI".into(), "true".into()));
    }
    out
}

fn set_env(env: &mut Vec<(String, String)>, k: &str, v: &str) {
    env.retain(|(x, _)| x != k);
    env.push((k.to_string(), v.to_string()));
}

#[derive(Clone)]
struct NodeOut {
    state: NState,
    code: Option<String>,
    started_ms: u64,
    duration_ms: u64,
    attempts: u32,
    verdicts: Vec<Value>,
    observations: Map<String, Value>,
    tests: Option<Value>,
    failures: Vec<Value>,
    detail: Option<String>,
    reason: Option<Value>,
    outputs: Map<String, Value>,
    needs_confirmation: bool,
    mutated: bool,
    /// 이 노드가 등록한 되돌림 단계와 그때의 환경(메모리에만 — 비밀값이 들어 있다).
    undo: Vec<blocks::UndoStep>,
    undo_ctx: crate::rollback::UndoCtx,
}

impl NodeOut {
    fn simple(state: NState, code: Option<&str>, reason: Option<Value>) -> NodeOut {
        NodeOut {
            state,
            code: code.map(|c| c.to_string()),
            started_ms: 0,
            duration_ms: 0,
            attempts: 0,
            verdicts: Vec::new(),
            observations: Map::new(),
            tests: None,
            failures: Vec::new(),
            detail: None,
            reason,
            outputs: Map::new(),
            needs_confirmation: false,
            mutated: false,
            undo: Vec::new(),
            undo_ctx: Default::default(),
        }
    }
}

struct Shared<'a> {
    spec: &'a Spec,
    plan: &'a Plan,
    run_id: String,
    run_dir: PathBuf,
    events: Arc<Events>,
    masker: Arc<Masker>,
    opts: &'a RunOptions,
    base_env: Vec<(String, String)>,
    changed: Option<Vec<String>>,
    today: String,
    /// Docker 데몬에 닿는지(처음 물을 때 한 번만 본다).
    docker_ok: std::sync::OnceLock<Result<String, String>>,
}

fn roots(
    sh: &Shared,
    n: &PNode,
    services: &Value,
    outs: &BTreeMap<String, NodeOut>,
    out_dir: &Path,
    with_secrets: Option<&Map<String, Value>>,
) -> Map<String, Value> {
    let mut r = Map::new();
    r.insert("git".into(), json!({"sha": sh.plan.git.sha, "branch": sh.plan.git.branch, "clean": sh.plan.git.clean, "short": sh.plan.git.sha.chars().take(7).collect::<String>()}));
    r.insert("run".into(), json!({"id": sh.run_id, "dir": sh.run_dir.to_string_lossy(), "flow": sh.plan.flow, "env": sh.plan.env}));
    r.insert(
        "node".into(),
        json!({"id": n.id, "out": out_dir.to_string_lossy()}),
    );
    r.insert("inputs".into(), n.scope_inputs.clone());
    r.insert("services".into(), services.clone());
    let allowed: Map<String, Value> = sh
        .base_env
        .iter()
        .filter(|(k, _)| sh.spec.defaults.env.contains(k) || k == "CI")
        .map(|(k, v)| (k.clone(), json!(v)))
        .collect();
    r.insert("env".into(), Value::Object(allowed));
    let nodes: Map<String, Value> = outs
        .iter()
        .map(|(k, o)| {
            (
                k.clone(),
                json!({"state": o.state.as_str(), "outputs": o.outputs}),
            )
        })
        .collect();
    r.insert("nodes".into(), Value::Object(nodes));
    r.insert("flow".into(), json!({"name": sh.plan.flow}));
    r.insert("project".into(), json!({"name": sh.spec.project_name}));
    r.insert("matrix".into(), json!({}));
    if let Some(s) = with_secrets {
        r.insert("secrets".into(), Value::Object(s.clone()));
    }
    r
}

/// 노드 입력 하나를 푼다. 셸 스크립트 자리(`run` · `undo` · `undo.run` · `undo.check`)는 셸 인용으로 넣어
/// 값이 명령으로 해석되지 않게 한다.
fn render_input(
    k: &str,
    v: &Value,
    ctx: &Xc,
    quote: expr::Quote,
) -> Result<Value, expr::ExprError> {
    match (k, v) {
        ("run" | "undo", Value::String(s)) => expr::render(s, ctx, quote).map(Value::String),
        ("run", other) => Ok(other.clone()),
        ("undo", Value::Object(o)) => {
            let mut m = Map::new();
            for (kk, vv) in o {
                let r = match (kk.as_str(), vv) {
                    ("run" | "check", Value::String(s)) => {
                        expr::render(s, ctx, quote).map(Value::String)?
                    }
                    _ => expr::render_value(vv, ctx)?,
                };
                m.insert(kk.clone(), r);
            }
            Ok(Value::Object(m))
        }
        _ => expr::render_value(v, ctx),
    }
}

/// 노드 하나 실행(작업 스레드에서).
fn run_node(
    sh: &Shared,
    n: &PNode,
    services: &Value,
    outs: &BTreeMap<String, NodeOut>,
    cancel: Cancel,
) -> NodeOut {
    let started = Instant::now();
    let started_ms = util::now_ms();
    let safe_id = store::safe(&n.id);
    let out_dir = sh.run_dir.join("out").join(&safe_id);
    let _ = std::fs::create_dir_all(&out_dir);
    let log_path = sh.run_dir.join("logs").join(format!("{safe_id}.log"));
    let _ = std::fs::create_dir_all(log_path.parent().unwrap_or(&sh.run_dir));
    let log = std::fs::File::create(&log_path).ok();
    let mut out = NodeOut::simple(NState::Running, None, None);
    out.started_ms = started_ms;
    let Some(block) = blocks::get(&n.block) else {
        out.state = NState::Rejected;
        out.code = Some("SPEC-04".into());
        return out;
    };
    // Docker 에서 도는 노드: 데몬이 꺼져 있으면 이 노드만 거부하고 나머지는 계획대로.
    if n.executor.is_docker() {
        if let Err(e) = sh.docker_ok.get_or_init(crate::docker::available) {
            out.state = NState::Rejected;
            out.code = Some("DOCKER-01".into());
            out.detail = Some(e.clone());
            return out;
        }
    }
    // 비밀값: secrets: 와 env 의 ${{ secrets.X }} 를 풀고 마스킹 사전에 넣는다.
    let mut secret_vals = Map::new();
    let mut missing = Vec::new();
    let mut wanted: Vec<String> = n.def.secrets.iter().map(|(_, r)| r.clone()).collect();
    for (_, v) in &n.def.env {
        if let Ok(spans) = expr::find(v) {
            for (_, _, inner) in spans {
                if let Some(rest) = inner.trim().strip_prefix("secrets.") {
                    wanted.push(rest.trim().to_string());
                }
            }
        }
    }
    for name in wanted {
        match crate::secret::resolve(&name, sh.opts.ci) {
            Some(v) => {
                sh.masker.add_secret(&name, &v);
                secret_vals.insert(name, json!(v));
            }
            None => missing.push(name),
        }
    }
    if !missing.is_empty() {
        out.state = NState::Rejected;
        out.code = Some("CONN-03".into());
        out.detail = Some(tr(
            &format!("비밀값 없음: {}", missing.join(", ")),
            &format!("missing secrets: {}", missing.join(", ")),
        ));
        return out;
    }
    // 컨테이너 안에서 도는 노드는 서비스를 네트워크 별칭 · host.docker.internal 로 본다.
    let docker_exec = n.executor.is_docker();
    let (svc_view, gateway) = if docker_exec || n.block == "docker.run" {
        crate::executor::services_inside(services)
    } else {
        (services.clone(), false)
    };
    let plain = Xc {
        roots: roots(sh, n, &svc_view, outs, &out_dir, None),
        root: &sh.spec.root,
    };
    let with_secret = Xc {
        roots: roots(sh, n, &svc_view, outs, &out_dir, Some(&secret_vals)),
        root: &sh.spec.root,
    };
    let shell = n
        .def
        .shell
        .clone()
        .or(sh.spec.defaults.shell.clone())
        .unwrap_or_else(|| "bash".into());
    let quote = if shell == "pwsh" || shell == "powershell" {
        expr::Quote::Pwsh
    } else if shell == "cmd" {
        expr::Quote::None
    } else {
        expr::Quote::Shell
    };
    // with: 셸로 들어가는 입력(run · undo)은 셸 인용, 나머지는 값 그대로.
    let mut with = Map::new();
    if let Some(o) = n.with.as_object() {
        for (k, v) in o {
            let r = render_input(k, v, &plain, quote);
            match r {
                Ok(x) => {
                    with.insert(k.clone(), x);
                }
                Err(e) => {
                    out.state = NState::Rejected;
                    out.code = Some("SPEC-06".into());
                    out.detail = Some(format!("with.{k}: {}", e.0));
                    return out;
                }
            }
        }
    }
    let mut env = sh.base_env.clone();
    // 흐름이 정한 환경 이름(컨테이너로 넘기는 것).
    let mut flow_keys: Vec<String> = sh.spec.defaults.env.clone();
    flow_keys.extend(["CI", "LANG", "LC_ALL", "TZ"].iter().map(|s| s.to_string()));
    if let Some(e) = sh.spec.environment(&sh.plan.env) {
        for (k, v) in &e.vars {
            set_env(&mut env, k, v);
            flow_keys.push(k.clone());
        }
    }
    flow_keys.extend(n.def.env.iter().map(|(k, _)| k.clone()));
    flow_keys.extend(n.def.secrets.iter().map(|(k, _)| k.clone()));
    for (k, v) in &n.def.env {
        match expr::render(v, &with_secret, expr::Quote::None) {
            Ok(x) => set_env(&mut env, k, &x),
            Err(e) => {
                out.state = NState::Rejected;
                out.code = Some("SPEC-06".into());
                out.detail = Some(format!("env.{k}: {}", e.0));
                return out;
            }
        }
    }
    for (envk, sref) in &n.def.secrets {
        if let Some(v) = secret_vals.get(sref).and_then(|v| v.as_str()) {
            set_env(&mut env, envk, v);
        }
    }
    for (k, v) in [
        ("GITCH_FLOW", "1".to_string()),
        ("GITCH_FLOW_RUN_ID", sh.run_id.clone()),
        ("GITCH_FLOW_NODE", n.id.clone()),
        ("GITCH_FLOW_FLOW", sh.plan.flow.clone()),
        ("GITCH_FLOW_ENV", sh.plan.env.clone()),
        ("GITCH_FLOW_SHA", sh.plan.git.sha.clone()),
        ("GITCH_FLOW_BRANCH", sh.plan.git.branch.clone()),
        ("GITCH_FLOW_OUT", out_dir.to_string_lossy().to_string()),
    ] {
        set_env(&mut env, k, &v);
        flow_keys.push(k.to_string());
    }
    let present: HashSet<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
    flow_keys.retain(|k| present.contains(k.as_str()));
    let cwd = n
        .def
        .cwd
        .clone()
        .or_else(|| {
            with.get("cwd")
                .and_then(|c| c.as_str())
                .map(|s| s.to_string())
        })
        .map(|c| sh.spec.root.join(c))
        .unwrap_or_else(|| sh.spec.root.clone());
    let timeout = n
        .timeout_ms
        .or(sh.spec.defaults.timeout_ms)
        .or(Some(30 * 60_000));
    let mut cx = NodeCx {
        id: n.id.clone(),
        block: n.block.clone(),
        with: Value::Object(with),
        expect: n.expect.clone(),
        retry: n.retry.clone(),
        root: sh.spec.root.clone(),
        cwd,
        out_dir: out_dir.clone(),
        env,
        shell,
        timeout_ms: timeout,
        cancel,
        events: &sh.events,
        masker: &sh.masker,
        log,
        selection: n.selection.clone(),
        interactive: sh.opts.interactive,
        yes: sh.opts.yes,
        ci: sh.opts.ci,
        git_sha: sh.plan.git.sha.clone(),
        quarantine: sh.spec.flaky.clone(),
        today: util::rfc3339(util::now_ms())[..10].to_string(),
        started_ms,
        services: services.clone(),
        run_id: sh.run_id.clone(),
        log_file: log_path.clone(),
        undo: Vec::new(),
        undo_log: sh.run_dir.join("undo.ndjson"),
        exec: if docker_exec {
            let common = crate::git::common_dir(&sh.spec.root).unwrap_or_default();
            blocks::ExecCx {
                executor: n.executor.clone(),
                mounts: crate::executor::mounts(&[
                    sh.spec.root.clone(),
                    sh.run_dir.clone(),
                    common,
                ]),
                repo_id: crate::trust::repo_id(&sh.spec.root),
                network: services.as_object().and_then(|o| {
                    o.values()
                        .find_map(|v| v["network"].as_str().map(|x| x.to_string()))
                }),
                host_gateway: gateway,
                forward: flow_keys,
                explicit_shell: n.def.shell.is_some() || sh.spec.defaults.shell.is_some(),
                seq: 0,
            }
        } else {
            blocks::ExecCx::default()
        },
        project: sh.spec.project_name.clone(),
        run_dir: sh.run_dir.clone(),
    };
    let result: NodeResult = block.run(&mut cx);
    out.undo = std::mem::take(&mut cx.undo);
    if !out.undo.is_empty() {
        out.undo_ctx = crate::rollback::UndoCtx {
            env: cx.env.clone(),
            cwd: cx.cwd.clone(),
            shell: cx.shell.clone(),
        };
    }
    let (outcome, code) = verify::combine(&result.verdicts);
    out.duration_ms = started.elapsed().as_millis() as u64;
    out.attempts = result.attempts.max(1);
    out.verdicts = result.verdicts.iter().map(|v| v.to_json()).collect();
    out.observations = sh
        .masker
        .mask_value(&Value::Object(result.observations.clone()))
        .as_object()
        .cloned()
        .unwrap_or_default();
    out.outputs = result.outputs.clone();
    out.mutated = result.mutated || !out.undo.is_empty();
    out.needs_confirmation = result.needs_confirmation;
    out.detail = result.detail.clone();
    out.state = if cx.cancel.is_cancelled() && outcome != Outcome::Pass {
        NState::Cancelled
    } else if result.needs_confirmation {
        NState::Rejected
    } else {
        match outcome {
            Outcome::Pass => NState::Passed,
            Outcome::Fail => NState::Failed,
            Outcome::Indeterminate => NState::Indeterminate,
        }
    };
    out.code = code.map(|c| c.to_string());
    if out.state == NState::Cancelled {
        out.code = Some("EXEC-05".into());
    }
    if let Some(rep) = &result.report {
        let rj = sh
            .masker
            .mask_value(&rep.to_json(n.suite.as_deref().unwrap_or(&n.id), 50));
        out.tests = Some(
            json!({"executed": rep.executed(), "passed": rep.passed(), "failed": rep.failed(), "skipped": rep.skipped(), "flaky": rep.flaky(), "durationMs": rep.duration_ms}),
        );
        out.failures = rep
            .cases
            .iter()
            .filter(|c| matches!(c.status, CaseStatus::Failed | CaseStatus::Flaky))
            .take(10)
            .map(|c| sh.masker.mask_value(&json!({"name": c.name, "file": c.file, "line": c.line, "status": c.status.as_str(), "message": c.message.as_ref().map(|m| m.lines().next().unwrap_or("").to_string())})))
            .collect();
        let _ = util::write_atomic(
            &sh.run_dir.join("reports").join(format!("{safe_id}.json")),
            rj.to_string().as_bytes(),
        );
    }
    out
}

fn node_summary(n: &PNode, o: &NodeOut) -> Value {
    let safe_id = store::safe(&n.id);
    let failure = o
        .code
        .as_ref()
        .filter(|_| o.state.bad())
        .map(|c| crate::codes::failure(c, o.detail.as_deref().unwrap_or("")));
    json!({
        "id": n.id,
        "title": n.title,
        "block": n.block,
        "suite": n.suite,
        "group": n.group,
        "branchOf": n.branch_of,
        "optional": n.def.optional,
        "state": o.state.as_str(),
        "code": o.code,
        "failure": failure,
        "reason": o.reason,
        "startedAt": if o.started_ms > 0 { json!(util::rfc3339(o.started_ms)) } else { Value::Null },
        "durationMs": o.duration_ms,
        "attempts": o.attempts,
        "tests": o.tests,
        "failures": o.failures,
        "verdicts": o.verdicts,
        "undo": o.undo.iter().map(|u| json!({"title": u.title, "always": u.always})).collect::<Vec<_>>(),
        "observations": o.observations,
        "selection": n.selection.as_ref().map(|s| s.len()),
        "selectionReason": n.selection_reason,
        "cacheKey": n.cache_key,
        "log": if o.started_ms > 0 { json!(format!("logs/{safe_id}.log")) } else { Value::Null },
        "report": if o.tests.is_some() { json!(format!("reports/{safe_id}.json")) } else { Value::Null },
    })
}

fn print_line(opts: &RunOptions, s: &str) {
    if opts.human {
        println!("{s}");
    }
}

fn mark(state: NState) -> &'static str {
    match state {
        NState::Passed => "✔",
        NState::Cached => "↺",
        NState::Skipped => "−",
        NState::Cancelled => "◌",
        _ => "✘",
    }
}

/// 실행. 계획을 받아 끝까지 돌리고 서명한 요약을 돌려준다.
pub fn execute(spec: &Spec, plan: &Plan, st: &Store, opts: &RunOptions) -> RunResult {
    install_signals();
    let run_id = opts.run_id.clone().unwrap_or_else(Store::new_run_id);
    let run_dir = st.run_dir(&run_id);
    let _ = std::fs::create_dir_all(run_dir.join("logs"));
    let _ = std::fs::write(run_dir.join("pid"), std::process::id().to_string());
    // 엔진이 사라진 채 남은 실행을 먼저 닫는다(바꾼 흔적이 있으면 그 환경을 잠근다).
    let orphans = crate::rollback::sweep_orphans(st, &run_id);
    let masker = Arc::new(Masker::new());
    let events = Arc::new(
        match Events::create(
            &run_dir.join("events.ndjson"),
            &run_id,
            opts.events_stdout,
            masker.clone(),
        ) {
            Ok(e) => e,
            Err(e) => {
                return RunResult {
                    summary: json!({"schemaVersion": 1, "error": {"code": "ENGINE-02", "message": e.to_string()}}),
                    exit_code: 1,
                };
            }
        },
    );
    if !orphans.is_empty() {
        events.emit("engine.orphans", None, json!({"closed": orphans}));
        print_line(
            opts,
            &tr(
                &format!(
                    "⚠ 엔진이 멈춘 채 남은 실행을 닫았습니다: {}",
                    orphans.join(", ")
                ),
                &format!(
                    "⚠ closed runs left behind by a stopped engine: {}",
                    orphans.join(", ")
                ),
            ),
        );
    }
    let started_ms = util::now_ms();
    let _ = util::write_atomic(
        &run_dir.join("plan.json"),
        serde_json::to_string_pretty(&plan.to_json())
            .unwrap_or_default()
            .as_bytes(),
    );
    let mut run_state = "PENDING".to_string();
    let mut violations: Vec<String> = Vec::new();
    let mut set_run = |to: &str, ev: &Events, v: &mut Vec<String>| {
        if !run_transition_ok(&run_state, to) {
            v.push(format!("run {run_state}→{to}"));
        }
        run_state = to.to_string();
        ev.emit("run.state", None, json!({"state": to}));
    };
    let base = json!({"schemaVersion": 1, "runId": run_id, "flow": plan.flow, "env": plan.env, "envClass": plan.env_class.as_str(), "state": "RUNNING",
                      "startedAt": util::rfc3339(started_ms), "actor": opts.actor, "trigger": opts.trigger, "planHash": plan.hash, "filesHash": plan.files_hash,
                      "git": {"sha": plan.git.sha, "branch": plan.git.branch, "clean": plan.git.clean}, "eventsPath": run_dir.join("events.ndjson").to_string_lossy()});
    let _ = st.write_run(&run_id, &base);
    events.emit("run.planned", None, json!({"flow": plan.flow, "env": plan.env, "hash": plan.hash, "nodes": plan.nodes.iter().map(|n| json!({"id": n.id, "title": n.title, "block": n.block, "needs": n.needs, "decision": n.decision.as_str(), "branchOf": n.branch_of, "group": n.group})).collect::<Vec<_>>(), "estimateMs": plan.estimate_ms()}));
    let changed = Some(crate::git::changed_files(&spec.root, None, false));
    let sh = Shared {
        spec,
        plan,
        run_id: run_id.clone(),
        run_dir: run_dir.clone(),
        events: events.clone(),
        masker: masker.clone(),
        opts,
        base_env: base_env(spec, opts.ci),
        changed,
        today: util::rfc3339(util::now_ms())[..10].to_string(),
        docker_ok: std::sync::OnceLock::new(),
    };
    let _ = &sh.today;
    let mut outs: BTreeMap<String, NodeOut> = BTreeMap::new();
    let mut states: HashMap<String, NState> = plan
        .nodes
        .iter()
        .map(|n| (n.id.clone(), NState::Pending))
        .collect();
    let transition =
        |states: &mut HashMap<String, NState>, id: &str, to: NState, v: &mut Vec<String>| {
            let from = *states.get(id).unwrap_or(&NState::Pending);
            if !node_transition_ok(from, to) {
                v.push(format!("{id} {}→{}", from.as_str(), to.as_str()));
            }
            states.insert(id.to_string(), to);
        };
    set_run("PREFLIGHT", &events, &mut violations);
    // 흐름 사전 점검: 바꾸기 전에 거부할 것은 먼저 거부한다.
    let mut rejected_pre: Vec<(String, String, String)> = Vec::new();
    let mut planned_start = started_ms;
    for n in &plan.nodes {
        if let Decision::Rejected(code, msg) = &n.decision {
            rejected_pre.push((n.id.clone(), code.to_string(), msg.clone()));
            continue;
        }
        if n.decision != Decision::Run {
            continue;
        }
        if let Some(b) = blocks::get(&n.block) {
            let pre = blocks::PreCx {
                root: &spec.root,
                with: &n.with,
                planned_start_ms: planned_start,
            };
            for issue in b.preflight(&pre) {
                rejected_pre.push((n.id.clone(), issue.code.to_string(), issue.message));
            }
        }
        if n.branch_of.is_none() {
            planned_start += n.estimate_ms;
        }
        if n.block == "gate.manual" && !opts.interactive && !opts.yes {
            rejected_pre.push((
                n.id.clone(),
                "CONFIRM-01".into(),
                tr(
                    "비대화형 실행에서는 사람 확인 노드를 지날 수 없습니다.",
                    "a manual approval cannot pass in a non-interactive run.",
                ),
            ));
        }
    }
    let hold = st.hold_path(&plan.env);
    if hold.is_file() {
        rejected_pre.push((
            String::new(),
            "GUARD-02".into(),
            crate::rollback::hold_message(&std::fs::read_to_string(&hold).unwrap_or_default()),
        ));
    }
    let mut exit_code = 0;
    let mut run_code: Option<String> = None;
    let mut rolled = Value::Null;
    let mut cleanup_steps = Value::Null;
    if !rejected_pre.is_empty() {
        for (id, code, msg) in &rejected_pre {
            if !id.is_empty() {
                transition(&mut states, id, NState::Rejected, &mut violations);
                let mut o = NodeOut::simple(
                    NState::Rejected,
                    Some(code),
                    Some(json!({"code": code, "message": msg})),
                );
                o.detail = Some(msg.clone());
                events.emit(
                    "node.state",
                    Some(id),
                    json!({"state": "REJECTED", "code": code, "detail": msg}),
                );
                outs.insert(id.clone(), o);
            }
            print_line(
                opts,
                &format!(
                    "✘ {} [{code}] {msg}",
                    if id.is_empty() {
                        plan.env.as_str()
                    } else {
                        id.as_str()
                    }
                ),
            );
        }
        for n in &plan.nodes {
            if !outs.contains_key(&n.id) {
                let reason = match &n.decision {
                    Decision::Skip(c, m) => json!({"code": c, "message": m}),
                    _ => {
                        json!({"code": "rejected-run", "message": tr("실행 전에 거부됨", "rejected before running")})
                    }
                };
                transition(&mut states, &n.id, NState::Skipped, &mut violations);
                outs.insert(
                    n.id.clone(),
                    NodeOut::simple(NState::Skipped, None, Some(reason)),
                );
            }
        }
        set_run("REJECTED", &events, &mut violations);
        let first = &rejected_pre[0];
        run_code = Some(first.1.clone());
        exit_code = if rejected_pre.iter().all(|r| r.1 == "CONFIRM-01") {
            2
        } else {
            1
        };
    } else {
        set_run("RUNNING", &events, &mut violations);
        let jobs = opts.jobs.max(1);
        let fail_fast = opts.fail_fast.unwrap_or(plan.fail_fast);
        let mut services_up: Vec<Running> = Vec::new();
        let mut services_info = Map::new();
        let mut service_failed: HashMap<String, (String, String)> = HashMap::new();
        let mut cancels: HashMap<String, Cancel> = HashMap::new();
        // 노드가 끝난 순서(되돌림은 이 반대로).
        let mut completed: Vec<String> = Vec::new();
        let mut held_locks: HashSet<String> = HashSet::new();
        let mut running: HashSet<String> = HashSet::new();
        let mut used_weight = 0usize;
        let mut weights: HashMap<String, usize> = HashMap::new();
        let mut cancelled_all = false;
        let mut stopped_by_fail_fast = false;
        let deadline = plan
            .timeout_ms
            .map(|ms| Instant::now() + Duration::from_millis(ms));
        let cancel_file = run_dir.join("cancel.request");
        // 계획에서 이미 건너뛰기로 정한 노드.
        for n in &plan.nodes {
            if let Decision::Skip(code, msg) = &n.decision {
                let st_ = if *code == "cached" {
                    NState::Cached
                } else {
                    NState::Skipped
                };
                transition(&mut states, &n.id, st_, &mut violations);
                let mut o = NodeOut::simple(st_, None, Some(json!({"code": code, "message": msg})));
                if st_ == NState::Cached {
                    if let Some(prev) = n.cache_key.as_deref().and_then(crate::cache::load) {
                        o.verdicts = prev["verdicts"].as_array().cloned().unwrap_or_default();
                        o.tests = prev.get("tests").cloned().filter(|t| !t.is_null());
                        o.duration_ms = 0;
                    }
                }
                events.emit(
                    "node.state",
                    Some(&n.id),
                    json!({"state": st_.as_str(), "reason": {"code": code, "message": msg}}),
                );
                print_line(opts, &format!("{} {} ({msg})", mark(st_), n.id));
                outs.insert(n.id.clone(), o);
            }
        }
        std::thread::scope(|scope| {
            let (tx, rx) = mpsc::channel::<(String, NodeOut)>();
            loop {
                if !cancelled_all
                    && (INTERRUPTED.load(Ordering::SeqCst)
                        || cancel_file.exists()
                        || deadline.map(|d| Instant::now() >= d).unwrap_or(false))
                {
                    cancelled_all = true;
                    if deadline.map(|d| Instant::now() >= d).unwrap_or(false) {
                        run_code = Some("EXEC-02".into());
                    }
                    for c in cancels.values() {
                        c.cancel();
                    }
                    events.emit("run.cancelling", None, json!({}));
                    print_line(opts, &tr("◌ 취소하는 중…", "◌ cancelling…"));
                }
                // 시작할 수 있는 노드 고르기.
                let mut progressed = false;
                for n in &plan.nodes {
                    if states[&n.id] != NState::Pending {
                        continue;
                    }
                    let needs_done = n
                        .needs
                        .iter()
                        .all(|x| states.get(x).map(|s| s.terminal()).unwrap_or(true));
                    if !needs_done {
                        continue;
                    }
                    let needs_bad = n
                        .needs
                        .iter()
                        .any(|x| states.get(x).map(|s| s.bad()).unwrap_or(false));
                    let parent_failed = n
                        .branch_of
                        .as_ref()
                        .map(|p| states.get(p).map(|s| s.bad()).unwrap_or(false));
                    if cancelled_all || (stopped_by_fail_fast && n.branch_of.is_none()) {
                        let to = if cancelled_all {
                            NState::Cancelled
                        } else {
                            NState::Skipped
                        };
                        transition(&mut states, &n.id, to, &mut violations);
                        let reason = if cancelled_all {
                            json!({"code": "EXEC-05", "message": tr("실행 취소", "run cancelled")})
                        } else {
                            json!({"code": "failFast", "message": tr("앞선 실패로 멈춤(failFast)", "stopped after an earlier failure (failFast)")})
                        };
                        events.emit(
                            "node.state",
                            Some(&n.id),
                            json!({"state": to.as_str(), "reason": reason}),
                        );
                        outs.insert(n.id.clone(), NodeOut::simple(to, None, Some(reason)));
                        progressed = true;
                        continue;
                    }
                    // 실패 갈래: 부모가 실패했을 때만, 그 밖의 조건은 if: 로.
                    let status = St {
                        needs_bad,
                        cancelled: cancelled_all,
                        parent_failed,
                        changed: sh.changed.clone(),
                    };
                    let go = match (&n.cond, &n.branch_of) {
                        (Some(c), _) => match expr::parse_cond(c) {
                            Ok(cond) => {
                                let ctx = Xc {
                                    roots: roots(
                                        &sh,
                                        n,
                                        &Value::Object(services_info.clone()),
                                        &outs,
                                        &run_dir,
                                        None,
                                    ),
                                    root: &spec.root,
                                };
                                expr::eval_cond(&cond, &ctx, &status).unwrap_or(false)
                            }
                            Err(_) => false,
                        },
                        (None, Some(_)) => parent_failed.unwrap_or(false),
                        (None, None) => !needs_bad,
                    };
                    if !go {
                        transition(&mut states, &n.id, NState::Skipped, &mut violations);
                        let reason = if needs_bad {
                            json!({"code": "needs-failed", "message": tr("앞 노드가 실패해 건너뜀", "skipped because a needed node failed")})
                        } else {
                            json!({"code": "condition", "message": tr("조건이 거짓", "condition is false")})
                        };
                        events.emit(
                            "node.state",
                            Some(&n.id),
                            json!({"state": "SKIPPED", "reason": reason}),
                        );
                        print_line(
                            opts,
                            &format!("− {} ({})", n.id, reason["message"].as_str().unwrap_or("")),
                        );
                        outs.insert(
                            n.id.clone(),
                            NodeOut::simple(NState::Skipped, None, Some(reason)),
                        );
                        progressed = true;
                        continue;
                    }
                    let w = (n.def.weight.unwrap_or(1) as usize).min(jobs);
                    if used_weight + w > jobs && !running.is_empty() {
                        continue;
                    }
                    if n.def.locks.iter().any(|l| held_locks.contains(l)) {
                        continue;
                    }
                    // 서비스 준비(처음 필요할 때).
                    let mut svc_error: Option<(String, String)> = None;
                    for s in &n.services {
                        let mut order = Vec::new();
                        let mut stack = vec![(s.clone(), false)];
                        while let Some((x, expanded)) = stack.pop() {
                            if expanded {
                                if !order.contains(&x) {
                                    order.push(x);
                                }
                                continue;
                            }
                            stack.push((x.clone(), true));
                            if let Some(sd) = spec.service(&x) {
                                for d in &sd.needs {
                                    stack.push((d.clone(), false));
                                }
                            }
                        }
                        for name in order {
                            if services_info.contains_key(&name) {
                                continue;
                            }
                            if let Some(e) = service_failed.get(&name) {
                                svc_error = Some(e.clone());
                                break;
                            }
                            let Some(def) = spec.service(&name) else {
                                continue;
                            };
                            let port = def
                                .with
                                .get("port")
                                .and_then(|p| p.as_u64())
                                .map(|p| p as u16)
                                .unwrap_or_else(services::free_port);
                            let mut svc_roots = roots(
                                &sh,
                                n,
                                &Value::Object(services_info.clone()),
                                &outs,
                                &run_dir,
                                None,
                            );
                            let mut me = services_info.clone();
                            me.insert(name.clone(), json!({"host": "127.0.0.1", "port": port, "url": format!("http://127.0.0.1:{port}")}));
                            svc_roots.insert("services".into(), Value::Object(me));
                            let ctx = Xc {
                                roots: svc_roots,
                                root: &spec.root,
                            };
                            let with =
                                expr::render_value(&def.with, &ctx).unwrap_or(def.with.clone());
                            events.emit(
                                "service.state",
                                None,
                                json!({"service": name, "state": "STARTING"}),
                            );
                            print_line(opts, &format!("▶ service {name}"));
                            // 준비를 기다리는 동안에도 취소 요청 · Ctrl-C · 흐름 마감을 본다.
                            let cancel_svc = Cancel::new();
                            let started = Cancel::new();
                            {
                                let (c, done, file) =
                                    (cancel_svc.clone(), started.clone(), cancel_file.clone());
                                scope.spawn(move || {
                                    while !done.is_cancelled() {
                                        if INTERRUPTED.load(Ordering::SeqCst)
                                            || file.exists()
                                            || deadline
                                                .map(|d| Instant::now() >= d)
                                                .unwrap_or(false)
                                        {
                                            c.cancel();
                                            break;
                                        }
                                        std::thread::sleep(Duration::from_millis(100));
                                    }
                                });
                            }
                            let cx = SvcCx {
                                root: &spec.root,
                                run_dir: &run_dir,
                                run_id: &run_id,
                                env: &sh.base_env,
                                masker: &masker,
                                cancel: &cancel_svc,
                            };
                            let res = services::start(def, &with, port, &cx);
                            started.cancel();
                            if cancel_svc.is_cancelled() {
                                if let Ok(r) = res {
                                    services_up.push(r);
                                }
                                events.emit(
                                    "service.state",
                                    None,
                                    json!({"service": name, "state": "CANCELLED"}),
                                );
                                svc_error =
                                    Some(("EXEC-05".into(), tr("실행 취소", "run cancelled")));
                                break;
                            }
                            match res {
                                Ok(r) => {
                                    events.emit(
                                        "service.state",
                                        None,
                                        json!({"service": name, "state": "READY", "info": r.info}),
                                    );
                                    services_info.insert(name.clone(), r.info.clone());
                                    services_up.push(r);
                                }
                                Err((code, msg)) => {
                                    events.emit("service.state", None, json!({"service": name, "state": "FAILED", "code": code, "detail": msg}));
                                    service_failed
                                        .insert(name.clone(), (code.to_string(), msg.clone()));
                                    svc_error = Some((code.to_string(), msg));
                                    break;
                                }
                            }
                        }
                        if svc_error.is_some() {
                            break;
                        }
                    }
                    if svc_error
                        .as_ref()
                        .map(|(c, _)| c == "EXEC-05")
                        .unwrap_or(false)
                    {
                        // 서비스를 띄우는 중에 취소됨: 다음 바퀴에서 나머지 노드와 함께 취소로 정리한다.
                        progressed = true;
                        continue;
                    }
                    if let Some((code, msg)) = svc_error {
                        transition(&mut states, &n.id, NState::Rejected, &mut violations);
                        let mut o = NodeOut::simple(NState::Rejected, Some(&code), None);
                        o.detail = Some(msg.clone());
                        events.emit(
                            "node.state",
                            Some(&n.id),
                            json!({"state": "REJECTED", "code": code, "detail": msg}),
                        );
                        print_line(
                            opts,
                            &format!("✘ {} [{code}] {}", n.id, crate::codes::describe(&code)),
                        );
                        outs.insert(n.id.clone(), o);
                        if fail_fast && !n.def.optional && n.branch_of.is_none() {
                            stopped_by_fail_fast = true;
                        }
                        progressed = true;
                        continue;
                    }
                    transition(&mut states, &n.id, NState::Running, &mut violations);
                    running.insert(n.id.clone());
                    used_weight += w;
                    weights.insert(n.id.clone(), w);
                    for l in &n.def.locks {
                        held_locks.insert(l.clone());
                    }
                    let cancel = Cancel::new();
                    cancels.insert(n.id.clone(), cancel.clone());
                    events.emit("node.state", Some(&n.id), json!({"state": "RUNNING", "block": n.block, "selection": n.selection.as_ref().map(|s| s.len())}));
                    print_line(opts, &format!("▶ {} ({})", n.id, n.block));
                    let tx = tx.clone();
                    let svc = Value::Object(services_info.clone());
                    let snapshot = outs.clone();
                    let shr = &sh;
                    scope.spawn(move || {
                        let o = run_node(shr, n, &svc, &snapshot, cancel);
                        let _ = tx.send((n.id.clone(), o));
                    });
                    progressed = true;
                }
                if running.is_empty() && plan.nodes.iter().all(|n| states[&n.id].terminal()) {
                    break;
                }
                if running.is_empty() && !progressed {
                    // 시작할 수 없는 노드만 남음(needs 가 없는 노드를 가리키는 등) — 엔진 버그로 기록하고 끝낸다.
                    for n in &plan.nodes {
                        if states[&n.id] == NState::Pending {
                            transition(&mut states, &n.id, NState::Skipped, &mut violations);
                            outs.insert(
                                n.id.clone(),
                                NodeOut::simple(
                                    NState::Skipped,
                                    Some("ENGINE-01"),
                                    Some(json!({"code": "ENGINE-01", "message": "stuck"})),
                                ),
                            );
                            violations.push(format!("{} stuck", n.id));
                        }
                    }
                    break;
                }
                match rx.recv_timeout(Duration::from_millis(150)) {
                    Ok((id, o)) => {
                        completed.push(id.clone());
                        running.remove(&id);
                        used_weight = used_weight.saturating_sub(weights.remove(&id).unwrap_or(1));
                        cancels.remove(&id);
                        let n = plan.node(&id).expect("node");
                        for l in &n.def.locks {
                            held_locks.remove(l);
                        }
                        transition(&mut states, &id, o.state, &mut violations);
                        let summary = node_summary(n, &o);
                        events.emit(
                            "node.verdict",
                            Some(&id),
                            json!({"verdicts": o.verdicts, "tests": o.tests}),
                        );
                        events.emit("node.state", Some(&id), json!({"state": o.state.as_str(), "code": o.code, "durationMs": o.duration_ms, "tests": o.tests}));
                        let extra = match &o.tests {
                            Some(t) => format!("  {}/{}", t["passed"], t["executed"]),
                            None => String::new(),
                        };
                        let code_txt = o
                            .code
                            .as_ref()
                            .filter(|_| o.state.bad())
                            .map(|c| format!(" [{c}] {}", crate::codes::describe(c)))
                            .unwrap_or_default();
                        print_line(
                            opts,
                            &format!(
                                "{} {}  {}{extra}{code_txt}",
                                mark(o.state),
                                id,
                                util::human_duration(o.duration_ms)
                            ),
                        );
                        if o.state == NState::Passed {
                            if let Some(k) = &n.cache_key {
                                crate::cache::store(k, &summary);
                            }
                        }
                        if o.state.bad()
                            && !n.def.optional
                            && n.branch_of.is_none()
                            && fail_fast
                            && !stopped_by_fail_fast
                        {
                            stopped_by_fail_fast = true;
                            for (rid, c) in &cancels {
                                if plan
                                    .node(rid)
                                    .map(|x| x.branch_of.is_none())
                                    .unwrap_or(true)
                                {
                                    c.cancel();
                                }
                            }
                        }
                        outs.insert(id, o);
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
        });
        let main_bad = plan.nodes.iter().any(|n| {
            n.branch_of.is_none()
                && !n.def.optional
                && outs
                    .get(&n.id)
                    .map(|o| o.state.bad() && o.state != NState::Cancelled)
                    .unwrap_or(false)
        });
        let any_cancel = cancelled_all;
        let needs_conf = outs.values().any(|o| o.needs_confirmation);
        if any_cancel {
            set_run("CANCELLED", &events, &mut violations);
            run_code = run_code.or(Some("EXEC-05".into()));
            exit_code = 1;
        } else if main_bad {
            set_run("FAILED", &events, &mut violations);
            let first_bad = plan
                .nodes
                .iter()
                .filter(|n| n.branch_of.is_none() && !n.def.optional)
                .find_map(|n| {
                    outs.get(&n.id)
                        .filter(|o| o.state.bad())
                        .and_then(|o| o.code.clone())
                });
            run_code = first_bad;
            exit_code = if needs_conf { 2 } else { 1 };
        } else {
            set_run("SUCCEEDED", &events, &mut violations);
        }
        // 되돌림 · 정리: 서비스를 끄기 전에(되돌림이 서비스에 기대는 경우 — 시드 지우기 등).
        let changed: Vec<crate::rollback::Changed> = completed
            .iter()
            .filter_map(|id| outs.get(id).map(|o| (id, o)))
            .filter(|(_, o)| !o.undo.is_empty())
            .map(|(id, o)| crate::rollback::Changed {
                node: id.as_str(),
                bad: o.state.bad(),
                steps: &o.undo,
                ctx: &o.undo_ctx,
            })
            .collect();
        let check_failed = plan.nodes.iter().any(|n| {
            n.branch_of.is_none()
                && !n.def.optional
                && outs
                    .get(&n.id)
                    .map(|o| o.state.bad() && o.state != NState::Cancelled && o.undo.is_empty())
                    .unwrap_or(false)
        });
        let choice = crate::rollback::decide(
            plan.rollback_scope,
            plan.on_check_failure,
            any_cancel,
            main_bad,
            &changed,
            check_failed,
        );
        if !choice.nodes.is_empty() {
            set_run("ROLLING_BACK", &events, &mut violations);
            print_line(
                opts,
                &tr(
                    &format!(
                        "↺ 되돌리는 중: {}",
                        choice
                            .nodes
                            .iter()
                            .rev()
                            .cloned()
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                    &format!(
                        "↺ rolling back: {}",
                        choice
                            .nodes
                            .iter()
                            .rev()
                            .cloned()
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                ),
            );
            let done = crate::rollback::execute(
                &choice,
                &changed,
                plan.rollback_timeout_ms,
                &run_dir,
                &masker,
                &events,
            );
            let mut hold_path = Value::Null;
            if done.ok {
                set_run("ROLLED_BACK", &events, &mut violations);
            } else {
                set_run("ROLLBACK_FAILED", &events, &mut violations);
                run_code = Some("ROLLBACK-01".into());
                exit_code = 1;
                if let Some(at) = &done.failed_at {
                    let p = crate::rollback::hold(st, &plan.env, &run_id, &plan.flow, at);
                    hold_path = json!(p.to_string_lossy());
                    print_line(
                        opts,
                        &format!("✘ [ROLLBACK-01] {}", crate::codes::describe("ROLLBACK-01")),
                    );
                }
            }
            rolled = json!({"needed": true, "state": if done.ok { "ROLLED_BACK" } else { "ROLLBACK_FAILED" },
                            "scope": match plan.rollback_scope { crate::spec::RollbackScope::Node => "node", crate::spec::RollbackScope::Flow => "flow" },
                            "why": choice.why, "nodes": choice.nodes, "kept": choice.kept, "steps": done.steps, "hold": hold_path});
        } else if !choice.kept.is_empty() {
            rolled = json!({"needed": false, "why": choice.why, "kept": choice.kept});
            print_line(
                opts,
                &format!("⚠ {}: {}", choice.why, choice.kept.join(", ")),
            );
        }
        let cleaned = crate::rollback::cleanup(&changed, &run_dir, &masker, &events);
        if !cleaned.is_empty() {
            cleanup_steps = Value::Array(cleaned);
        }
        // 서비스 정리(언제나).
        for r in services_up.drain(..) {
            if opts.keep_services {
                services::keep_note(&run_dir, &r);
                std::mem::forget(r);
                continue;
            }
            events.emit(
                "service.state",
                None,
                json!({"service": r.name, "state": "STOPPED"}),
            );
            services::stop(r, &run_dir);
        }
        let used_docker = plan.nodes.iter().any(|n| {
            n.executor.is_docker()
                || n.block.starts_with("docker.")
                    && outs.get(&n.id).map(|o| o.started_ms > 0).unwrap_or(false)
        });
        if !opts.keep_services
            && (used_docker
                || plan.services.iter().any(|s| {
                    spec.service(s)
                        .map(|d| d.uses != "process.service")
                        .unwrap_or(false)
                }))
        {
            crate::docker::cleanup_run(&run_id);
        }
    }
    if !violations.is_empty() {
        events.emit("engine.violation", None, json!({"violations": violations}));
    }
    // 노드 요약 + 서명.
    let finished_ms = util::now_ms();
    let nodes: Vec<Value> = plan
        .nodes
        .iter()
        .map(|n| {
            node_summary(
                n,
                outs.get(&n.id)
                    .unwrap_or(&NodeOut::simple(NState::Skipped, None, None)),
            )
        })
        .collect();
    let count = |s: NState| outs.values().filter(|o| o.state == s).count();
    let mut summary = base.clone();
    summary["state"] = json!(run_state);
    summary["code"] = json!(run_code);
    summary["failure"] = run_code
        .as_ref()
        .map(|c| crate::codes::failure(c, ""))
        .unwrap_or(Value::Null);
    summary["finishedAt"] = json!(util::rfc3339(finished_ms));
    summary["finishedAtMs"] = json!(finished_ms);
    summary["durationMs"] = json!(finished_ms - started_ms);
    summary["counts"] = json!({"passed": count(NState::Passed), "failed": count(NState::Failed), "indeterminate": count(NState::Indeterminate), "rejected": count(NState::Rejected),
                               "skipped": count(NState::Skipped), "cached": count(NState::Cached), "cancelled": count(NState::Cancelled), "total": plan.nodes.len()});
    summary["nodes"] = Value::Array(nodes);
    summary["rollback"] = rolled;
    summary["cleanup"] = cleanup_steps;
    summary["violations"] = json!(violations);
    summary["affected"] = plan.affected.clone().unwrap_or(Value::Null);
    summary["exitCode"] = json!(exit_code);
    summary["runDir"] = json!(run_dir.to_string_lossy());
    summary = masker.mask_value(&summary);
    summary["signature"] = store::sign(&summary)
        .map(Value::String)
        .unwrap_or(Value::Null);
    let _ = st.write_run(&run_id, &summary);
    events.emit("run.done", None, json!({"state": run_state, "code": run_code, "exitCode": exit_code, "durationMs": finished_ms - started_ms}));
    let _ = std::fs::remove_file(run_dir.join("pid"));
    let _ = std::fs::remove_file(run_dir.join("cancel.request"));
    if let Some(k) = &opts.idempotency_key {
        let _ = util::write_atomic(&st.idem_path(k), run_id.as_bytes());
    }
    record_action(spec, plan, opts, &summary);
    RunResult { summary, exit_code }
}

/// gitch 행동 기록(actions.jsonl)에 남겨 `gitch report` 가 보이게 한다.
fn record_action(spec: &Spec, plan: &Plan, opts: &RunOptions, summary: &Value) {
    let path = util::gitsw_state_dir().join("actions.jsonl");
    if !path.parent().map(|p| p.is_dir()).unwrap_or(false) {
        return;
    }
    let line = json!({"ts": util::rfc3339(util::now_ms()), "actor": opts.actor, "action": "flow", "repo": spec.root.file_name().map(|s| s.to_string_lossy().to_string()),
                      "branch": plan.git.branch, "flow": plan.flow, "env": plan.env, "state": summary["state"], "runId": summary["runId"]});
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{line}");
    }
}

/// 같은 흐름 · 환경을 동시에 돌리지 않게 잠근다. 잠금을 가진 실행 ID 를 돌려준다(오류).
pub fn lock(st: &Store, plan: &Plan, run_id: &str) -> Result<Option<Lock>, String> {
    if plan.concurrency == crate::spec::Concurrency::Parallel {
        return Ok(None);
    }
    let path = st.lock_path(&plan.flow, &plan.env);
    match plan.concurrency {
        crate::spec::Concurrency::Queue => {
            let until = Instant::now() + Duration::from_secs(3600);
            loop {
                match Lock::acquire(&path, run_id) {
                    Ok(l) => return Ok(Some(l)),
                    Err(holder) if Instant::now() < until => {
                        let _ = holder;
                        std::thread::sleep(Duration::from_millis(500));
                    }
                    Err(holder) => return Err(holder),
                }
            }
        }
        crate::spec::Concurrency::CancelPrevious => match Lock::acquire(&path, run_id) {
            Ok(l) => Ok(Some(l)),
            Err(holder) => {
                let _ = std::fs::write(
                    st.run_dir(&holder).join("cancel.request"),
                    "cancel-previous",
                );
                let until = Instant::now() + Duration::from_secs(120);
                while Instant::now() < until {
                    if let Ok(l) = Lock::acquire(&path, run_id) {
                        return Ok(Some(l));
                    }
                    std::thread::sleep(Duration::from_millis(300));
                }
                Err(holder)
            }
        },
        _ => Lock::acquire(&path, run_id).map(Some),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transition_tables() {
        assert!(node_transition_ok(NState::Pending, NState::Running));
        assert!(node_transition_ok(NState::Running, NState::Passed));
        assert!(!node_transition_ok(NState::Passed, NState::Running));
        assert!(!node_transition_ok(NState::Skipped, NState::Failed));
        assert!(!node_transition_ok(NState::Running, NState::Skipped));
        assert!(run_transition_ok("PENDING", "PREFLIGHT"));
        assert!(run_transition_ok("PREFLIGHT", "REJECTED"));
        assert!(run_transition_ok("FAILED", "ROLLING_BACK"));
        assert!(!run_transition_ok("SUCCEEDED", "FAILED"));
        assert!(!run_transition_ok("REJECTED", "RUNNING"));
    }
}
