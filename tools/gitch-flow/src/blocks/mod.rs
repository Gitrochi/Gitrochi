//! The block contract and the built-in blocks. A block keeps observe, run, verify and undo apart,
//! and verdicts come only from the pure rules in the verify module.

pub mod check;
pub mod ci;
pub mod cmd;
pub mod container;
pub mod deploy;
pub mod fixture;
pub mod gate;
pub mod gitchb;
pub mod mock;
pub mod notify;
pub mod setup;
pub mod test;
pub mod window;

use crate::mask::Masker;
use crate::process::{self, Cancel, Outcome, ProcSpec, Stream};
use crate::report::TestReport;
use crate::spec::{EnvClass, Expect, Quarantine, Retry};
use crate::store::Events;
use crate::util::tr;
use crate::verify::{self, Verdict};
use serde_json::{json, Map, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// What a block declares about itself.
pub struct Meta {
    pub id: &'static str,
    pub version: &'static str,
    pub title: (&'static str, &'static str),
    pub category: &'static str,
    /// process · docker · network · secrets · ssh · ci-api · outward
    pub capabilities: &'static [&'static str],
    /// Empty means every environment class.
    pub env_classes: &'static [EnvClass],
    pub destructive: bool,
    /// Whether it affects the outside world (remote CI, publishing, deploying). The plan shows it as an outward action.
    pub outward: bool,
    pub codes: &'static [&'static str],
    /// The input JSON Schema (the apps' input forms and validation).
    pub inputs: fn() -> Value,
    /// Whether the block supports affected selection (taking a file list).
    pub selects_files: bool,
    pub estimate_ms: u64,
}

impl Meta {
    pub fn title(&self) -> String {
        tr(self.title.0, self.title.1)
    }
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id, "version": self.version, "title": self.title(), "category": self.category,
            "capabilities": self.capabilities, "envClasses": self.env_classes.iter().map(|c| c.as_str()).collect::<Vec<_>>(),
            "destructive": self.destructive, "outward": self.outward, "failureCodes": self.codes,
            "inputs": (self.inputs)(), "selectsFiles": self.selects_files, "estimateMs": self.estimate_ms,
        })
    }
}

/// A check result at planning time (observation only).
pub struct Issue {
    pub code: &'static str,
    pub message: String,
}

pub trait Block: Send + Sync {
    fn meta(&self) -> &Meta;
    /// Validates the inputs; returns error sentences.
    fn validate(&self, with: &Value) -> Vec<String> {
        let _ = with;
        Vec::new()
    }
    /// Preconditions checked before anything changes (the flow preflight).
    fn preflight(&self, cx: &PreCx) -> Vec<Issue> {
        let _ = cx;
        Vec::new()
    }
    fn run(&self, cx: &mut NodeCx) -> NodeResult;
}

pub struct PreCx<'a> {
    pub root: &'a Path,
    pub with: &'a Value,
    /// The expected start time in milliseconds, adding up the earlier nodes' durations (for blocked time windows, say).
    pub planned_start_ms: u64,
}

/// A declarative undo step. A block registers it **right before** it changes the target (it is also kept in the run folder's `undo.ndjson`),
/// and the engine runs the steps in reverse after a failure or cancel. If the engine stops midway, the remaining steps are noticed and the environment is put on hold.
#[derive(Debug, Clone)]
pub struct UndoStep {
    pub title: String,
    pub action: UndoAction,
    /// A check after undoing (exit code 0 = confirmed).
    pub check: Option<UndoAction>,
    pub timeout_ms: u64,
    /// Always runs at the end, whatever the result (cleaning up temporary seed data, say).
    pub always: bool,
}

#[derive(Debug, Clone)]
pub enum UndoAction {
    /// A script run with the node's shell, working folder and environment.
    Script(String),
    /// A program called without a shell (docker and the like).
    Argv { program: String, args: Vec<String> },
}

impl UndoAction {
    pub fn show(&self) -> String {
        match self {
            UndoAction::Script(s) => s.lines().next().unwrap_or("").to_string(),
            UndoAction::Argv { program, args } => {
                let name = Path::new(program)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| program.clone());
                format!("{name} {}", args.join(" "))
            }
        }
    }
}

#[derive(Default)]
pub struct NodeResult {
    pub verdicts: Vec<Verdict>,
    pub observations: Map<String, Value>,
    pub report: Option<TestReport>,
    pub mutated: bool,
    pub outputs: Map<String, Value>,
    pub attempts: u32,
    /// Stopped because a person must confirm (exit code 2).
    pub needs_confirmation: bool,
    pub detail: Option<String>,
}

impl NodeResult {
    pub fn observe(&mut self, k: &str, v: Value) {
        self.observations.insert(k.into(), v);
    }
}

/// The context while one node runs.
pub struct NodeCx<'a> {
    pub id: String,
    pub block: String,
    pub with: Value,
    pub expect: Expect,
    pub retry: Option<Retry>,
    pub root: PathBuf,
    pub cwd: PathBuf,
    pub out_dir: PathBuf,
    pub env: Vec<(String, String)>,
    pub shell: String,
    pub timeout_ms: Option<u64>,
    pub cancel: Cancel,
    pub events: &'a Events,
    pub masker: &'a Masker,
    pub log: Option<std::fs::File>,
    /// Test files picked by affected selection (None means all).
    pub selection: Option<Vec<String>>,
    pub interactive: bool,
    pub yes: bool,
    pub ci: bool,
    pub git_sha: String,
    pub quarantine: Vec<Quarantine>,
    pub today: String,
    pub started_ms: u64,
    pub services: Value,
    pub run_id: String,
    pub log_file: PathBuf,
    /// The undo steps this node registered, in registration order.
    pub undo: Vec<UndoStep>,
    /// The run folder's `undo.ndjson`, a record that reveals leftover changes if the engine stops.
    pub undo_log: PathBuf,
    /// Where shell commands run (local or docker:<image>).
    pub exec: ExecCx,
    pub project: Option<String>,
    /// The run folder (service logs, outputs).
    pub run_dir: PathBuf,
}

/// What it takes to run shell commands in a container.
#[derive(Debug, Clone)]
pub struct ExecCx {
    pub executor: crate::executor::Executor,
    pub mounts: Vec<PathBuf>,
    pub repo_id: String,
    pub network: Option<String>,
    pub host_gateway: bool,
    /// Environment names to pass into the container (set by the flow, or on the allow list).
    pub forward: Vec<String>,
    pub explicit_shell: bool,
    pub seq: u32,
}

impl Default for ExecCx {
    fn default() -> Self {
        ExecCx {
            executor: crate::executor::Executor::Local,
            mounts: Vec::new(),
            repo_id: String::new(),
            network: None,
            host_gateway: false,
            forward: Vec::new(),
            explicit_shell: false,
            seq: 0,
        }
    }
}

/// A command's result and output.
pub struct Captured {
    pub outcome: Outcome,
    pub stdout: String,
    pub tail: Vec<String>,
}

const STDOUT_CAP: usize = 64 * 1024 * 1024;

impl NodeCx<'_> {
    pub fn events_run_id(&self) -> &str {
        &self.run_id
    }

    pub fn log_path(&self) -> Option<&Path> {
        Some(self.log_file.as_path())
    }

    pub fn log_line(&mut self, line: &str) {
        let masked = self.masker.mask(line);
        if let Some(f) = self.log.as_mut() {
            let _ = writeln!(f, "{masked}");
        }
    }

    /// A progress line for people (log and event).
    pub fn note(&mut self, text: &str) {
        self.log_line(&format!("[gitch-flow] {text}"));
        self.events.emit(
            "log",
            Some(&self.id.clone()),
            json!({"stream": "engine", "lines": [text]}),
        );
    }

    /// Runs a shell script and streams its output into the log and events (inside a container when the executor is docker).
    pub fn run_script(&mut self, script: &str, extra_env: &[(String, String)]) -> Captured {
        let mut env = self.env.clone();
        env.extend(extra_env.iter().cloned());
        if let crate::executor::Executor::Docker { image } = self.exec.executor.clone() {
            return self.run_in_container(&image, script, env, extra_env);
        }
        let (program, args) = process::shell_command(&self.shell, script);
        let spec = ProcSpec {
            program,
            args,
            cwd: self.cwd.clone(),
            env,
            clear_env: true,
            timeout_ms: self.timeout_ms,
            settle_ms: 5000,
        };
        self.run_proc(&spec)
    }

    fn run_in_container(
        &mut self,
        image: &str,
        script: &str,
        mut env: Vec<(String, String)>,
        extra_env: &[(String, String)],
    ) -> Captured {
        use crate::executor;
        self.exec.seq += 1;
        let name = format!(
            "gitch-flow-{}-{}-{}",
            crate::store::safe(&self.run_id),
            crate::store::safe(&self.id),
            self.exec.seq
        )
        .to_ascii_lowercase();
        let mounts = self.exec.mounts.clone();
        for (_, v) in env.iter_mut() {
            *v = executor::rewrite_paths(v, &mounts);
        }
        env.push((
            "GITCH_FLOW_SCRIPT".into(),
            executor::rewrite_paths(script, &mounts),
        ));
        let mut forward = self.exec.forward.clone();
        forward.extend(extra_env.iter().map(|(k, _)| k.clone()));
        forward.push("GITCH_FLOW_SCRIPT".into());
        let args = executor::docker_args(&executor::RunArgs {
            image,
            name: &name,
            run_id: &self.run_id,
            node: &self.id,
            repo_id: &self.exec.repo_id,
            mounts: &mounts,
            workdir: &self.cwd,
            forward,
            network: self.exec.network.clone(),
            host_gateway: self.exec.host_gateway,
            pull: "missing",
            command: executor::shell_command(&self.shell, self.exec.explicit_shell),
        });
        self.note(&format!("docker {image} ({name})"));
        let spec = ProcSpec {
            program: crate::docker::bin(),
            args,
            cwd: self.cwd.clone(),
            env,
            clear_env: true,
            timeout_ms: self.timeout_ms,
            settle_ms: 5000,
        };
        let c = self.run_proc(&spec);
        if c.outcome.cancelled || c.outcome.timed_out || c.outcome.hung {
            // The container can outlive the docker CLI.
            crate::docker::remove_container(&name);
        }
        c
    }

    pub fn run_proc(&mut self, spec: &ProcSpec) -> Captured {
        let id = self.id.clone();
        let events = self.events;
        let masker = self.masker;
        let mut log = self.log.take();
        let mut stdout = String::new();
        let mut tail: std::collections::VecDeque<String> = std::collections::VecDeque::new();
        let mut batch: Vec<Value> = Vec::new();
        let mut last_flush = Instant::now();
        let outcome = {
            let mut on_line = |s: Stream, line: &str| {
                if s == Stream::Out && stdout.len() < STDOUT_CAP {
                    stdout.push_str(line);
                    stdout.push('\n');
                }
                let masked = masker.mask(line);
                if let Some(f) = log.as_mut() {
                    let _ = writeln!(f, "{masked}");
                }
                tail.push_back(masked.clone());
                if tail.len() > 60 {
                    tail.pop_front();
                }
                batch.push(json!({"s": if s == Stream::Out { "out" } else { "err" }, "t": masked}));
                if batch.len() >= 64 || last_flush.elapsed().as_millis() >= 120 {
                    events.emit(
                        "log",
                        Some(&id),
                        json!({"lines": std::mem::take(&mut batch)}),
                    );
                    last_flush = Instant::now();
                }
            };
            process::run(spec, &self.cancel, &mut on_line)
        };
        if !batch.is_empty() {
            events.emit("log", Some(&id), json!({"lines": batch}));
        }
        self.log = log;
        Captured {
            outcome,
            stdout,
            tail: tail.into_iter().collect(),
        }
    }

    /// Registers an undo step right before the target changes. A change that fails midway may still be partial, so the undo step always runs.
    pub fn register_undo(&mut self, step: UndoStep) {
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.undo_log)
        {
            let line = json!({"node": self.id, "seq": self.undo.len() + 1, "title": step.title,
                              "action": self.masker.mask(&step.action.show()), "always": step.always, "at": crate::util::rfc3339(crate::util::now_ms())});
            let _ = writeln!(f, "{line}");
        }
        self.note(&tr(
            &format!("되돌림 등록: {}", step.title),
            &format!("undo registered: {}", step.title),
        ));
        self.undo.push(step);
    }

    pub fn input_str(&self, key: &str) -> Option<String> {
        match self.with.get(key) {
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            Some(Value::Number(n)) => Some(n.to_string()),
            _ => None,
        }
    }
}

/// Observations every run produces.
pub fn observe_outcome(r: &mut NodeResult, c: &Captured) {
    r.observe("exitCode", json!(c.outcome.exit_code));
    r.observe("durationMs", json!(c.outcome.duration_ms));
    if c.outcome.timed_out {
        r.observe("timedOut", json!(true));
    }
    if c.outcome.cancelled {
        r.observe("cancelled", json!(true));
    }
    if c.outcome.hung {
        r.observe("hung", json!(true));
    }
    if let Some(e) = &c.outcome.spawn_error {
        r.observe("spawnError", json!(e));
    }
    let tail: Vec<&String> = c
        .tail
        .iter()
        .rev()
        .take(20)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    r.observe("outputTail", json!(tail));
}

/// Builds E1, telling a hung process apart as EXEC-03.
pub fn exit_verdict(c: &Captured, allowed: &[i64]) -> Verdict {
    let mut v = verify::exit_code(
        c.outcome.exit_code,
        allowed,
        c.outcome.timed_out,
        c.outcome.cancelled,
        c.outcome.spawn_error.as_deref(),
    );
    if c.outcome.hung && v.code.is_some() {
        v.code = Some("EXEC-03");
    }
    v
}

static CMD: cmd::Cmd = cmd::Cmd;
static GATE: gate::Manual = gate::Manual;
static HTTP: check::Http = check::Http;
static PORT: check::Port = check::Port;
static VERSION: check::Version = check::Version;
static DOCKER_RUN: container::Run = container::Run;
static DOCKER_BUILD: container::Build = container::Build;
static DOCKER_PUSH: container::Push = container::Push;
static MOCK_FAULT: mock::Fault = mock::Fault;
static MOCK_CHECK: mock::Check = mock::Check;
static SEED: fixture::Seed = fixture::Seed;
static WINDOW: window::Window = window::Window;
static LOG: check::Log = check::Log;
static GITCH_PREFLIGHT: gitchb::Preflight = gitchb::Preflight;
static GITCH_GRAPH: gitchb::GraphCheck = gitchb::GraphCheck;
static NOTIFY_WEBHOOK: notify::Webhook = notify::Webhook;
static NOTIFY_DESKTOP: notify::Desktop = notify::Desktop;
static DEPLOY_COMPOSE: deploy::Compose = deploy::Compose;

/// All built-in blocks.
pub fn all() -> Vec<&'static dyn Block> {
    let mut v: Vec<&'static dyn Block> = vec![
        &CMD,
        &GATE,
        &HTTP,
        &PORT,
        &VERSION,
        &DOCKER_RUN,
        &DOCKER_BUILD,
        &DOCKER_PUSH,
        &MOCK_FAULT,
        &MOCK_CHECK,
        &SEED,
        &WINDOW,
        &LOG,
        &GITCH_PREFLIGHT,
        &GITCH_GRAPH,
        &NOTIFY_WEBHOOK,
        &NOTIFY_DESKTOP,
        &DEPLOY_COMPOSE,
    ];
    for t in test::RUNNERS {
        v.push(t);
    }
    for s in setup::SETUPS {
        v.push(s);
    }
    for c in ci::CI_BLOCKS {
        v.push(c);
    }
    v
}

pub fn get(id: &str) -> Option<&'static dyn Block> {
    all().into_iter().find(|b| b.meta().id == id)
}

/// Schema pieces common to node inputs.
pub fn schema(props: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": props, "required": required, "additionalProperties": true})
}

/// Files under the repository that match the glob and changed after `since_ms`, so stale reports are never read.
pub fn find_files(root: &Path, globs: &[String], since_ms: u64) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut visited = 0usize;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for e in rd.flatten() {
            visited += 1;
            if visited > 300_000 {
                return out;
            }
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                if name == ".git"
                    || name == "node_modules"
                    || name == ".venv"
                    || name == "__pycache__"
                {
                    continue;
                }
                stack.push(p);
            } else if ft.is_file() {
                let rel = crate::util::rel_slash(root, &p);
                if globs.iter().any(|g| crate::util::glob_match(g, &rel)) {
                    let fresh = e
                        .metadata()
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_millis() as u64 + 1500 >= since_ms)
                        .unwrap_or(true);
                    if fresh {
                        out.push(p);
                    }
                }
            }
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn registry_is_consistent() {
        let mut ids = HashSet::new();
        for b in all() {
            let m = b.meta();
            assert!(ids.insert(m.id), "duplicate block {}", m.id);
            let parts: Vec<&str> = m.version.split('.').collect();
            assert_eq!(parts.len(), 3, "{} needs semver", m.id);
            assert!(parts.iter().all(|p| p.parse::<u32>().is_ok()));
            assert!((m.inputs)().is_object(), "{} needs an input schema", m.id);
            for c in m.codes {
                assert!(crate::codes::known(c), "{} declares unknown code {c}", m.id);
            }
            assert!(!m.title.0.is_empty() && !m.title.1.is_empty());
        }
    }
}
