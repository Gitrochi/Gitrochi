//! Driving remote CI. Every adapter follows the same rules:
//! put in a correlation ID, look before sending, never resend a trigger whose response was lost, wait within the deadline,
//! cancel remotely on abort or deadline, treat a cancel we did not ask for as external, and take CI's conclusion only as a hint (the verdict comes from the result contract and reports).

pub mod contract;
pub mod export;
pub mod github;
pub mod gitlab;
pub mod httpci;
pub mod import;
pub mod jenkins;

use crate::blocks::NodeCx;
use crate::report::TestReport;
use crate::util::tr;
use serde_json::Value;
use std::time::{Duration, Instant};

/// base64 (for Basic auth; a tiny implementation rather than another crate).
pub fn b64(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = s.as_bytes();
    let mut out = String::new();
    for chunk in b.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[derive(Debug, Clone)]
pub struct CiErr {
    pub code: &'static str,
    pub http: Option<u16>,
    pub message: String,
    /// Outcome unknown (whether the request arrived cannot be told): never resend.
    pub unknown_outcome: bool,
    /// An error that may be read again shortly (GET only).
    pub transient: bool,
    /// How long the server said to wait (`Retry-After`, `x-ratelimit-reset`).
    pub retry_after_ms: Option<u64>,
}

impl CiErr {
    pub fn from_status(status: u16, body: &str) -> CiErr {
        let code = match status {
            401 | 403 if body.to_ascii_lowercase().contains("rate limit") => "CONN-06",
            401 | 403 => "CONN-02",
            404 => "CONN-04",
            422 | 400 => "CI-06",
            429 => "CONN-06",
            _ => "CONN-05",
        };
        let snippet: String = body.chars().take(300).collect();
        CiErr {
            code,
            http: Some(status),
            message: format!("HTTP {status}: {snippet}"),
            unknown_outcome: status >= 500,
            transient: status >= 500 || status == 429 || status == 408,
            retry_after_ms: None,
        }
    }
    /// From a response: the status code and rate-limit headers.
    pub fn from_resp(r: &crate::http::Resp) -> CiErr {
        let mut e = CiErr::from_status(r.status, &r.body);
        if r.header("x-ratelimit-remaining") == Some("0") && matches!(r.status, 403 | 429) {
            e.code = "CONN-06";
            e.transient = true;
        }
        if e.code == "CONN-06" || r.status == 503 {
            e.retry_after_ms = r.retry_after_ms();
        }
        e
    }
    pub fn transport(e: String) -> CiErr {
        CiErr {
            code: "CONN-05",
            http: None,
            message: e,
            unknown_outcome: true,
            transient: true,
            retry_after_ms: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RemoteRun {
    pub id: String,
    pub url: String,
    /// Extra information for the adapter (the queue URL and so on).
    pub extra: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    /// Waiting for a person (a manual job or an approval).
    Waiting,
}

#[derive(Debug, Clone)]
pub struct RStatus {
    pub state: RState,
    pub conclusion: String,
}

pub enum Triggered {
    Created(RemoteRun),
    /// Accepted but no ID given (GitHub dispatch 204, the Jenkins queue): find it by correlation ID.
    Accepted(Option<Value>),
}

pub trait Provider {
    fn label(&self) -> String;
    /// Whether runs can be found by correlation ID. Where they cannot (manual jobs, say), a lost response ends right away as "outcome unknown".
    fn searchable(&self) -> bool {
        true
    }
    fn find(&self, corr: &str, since_ms: u64) -> Result<Option<RemoteRun>, CiErr>;
    fn trigger(&self, corr: &str) -> Result<Triggered, CiErr>;
    /// Finds the run from the Accepted handle (a queue URL, say). None when unknown.
    fn resolve_accepted(&self, _handle: &Value) -> Result<Option<RemoteRun>, CiErr> {
        Ok(None)
    }
    fn status(&self, run: &RemoteRun) -> Result<RStatus, CiErr>;
    /// New log lines. `cursor` is the adapter's own slot (per-job offsets and so on).
    fn logs(&self, run: &RemoteRun, cursor: &mut Value) -> Result<Vec<String>, CiErr>;
    fn report(&self, _run: &RemoteRun) -> Result<Option<TestReport>, CiErr> {
        Ok(None)
    }
    /// The result contract (gitch-flow-result.json in the artifacts). None when missing; the driver checks the log marker separately.
    fn contract(&self, _run: &RemoteRun) -> Result<Option<Value>, CiErr> {
        Ok(None)
    }
    fn cancel(&self, run: &RemoteRun) -> Result<(), CiErr>;
}

pub struct DriveOpts {
    pub timeout_ms: u64,
    pub find_ms: u64,
    pub poll_ms: u64,
    pub require_contract: bool,
}

pub struct Driven {
    pub run: Option<RemoteRun>,
    pub status: Option<RStatus>,
    pub contract: Option<Value>,
    pub report: Option<TestReport>,
    pub reused: bool,
    pub error: Option<CiErr>,
    pub we_cancelled: bool,
    pub timed_out: bool,
    pub log_lines: usize,
}

fn nap(cx: &NodeCx, ms: u64) -> bool {
    let until = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < until {
        if cx.cancel.is_cancelled() {
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    true
}

/// The correlation ID (one per run and node), with only letters, digits and - to fit CI naming rules.
pub fn correlation(run_id: &str, node: &str) -> String {
    let raw = format!("gitch-{run_id}-{node}");
    raw.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .take(90)
        .collect()
}

/// Retries a GET a few times, only on transient errors (never for the trigger POST).
pub fn with_retry<T>(cx: &NodeCx, mut f: impl FnMut() -> Result<T, CiErr>) -> Result<T, CiErr> {
    let mut wait = 1000;
    for i in 0..5 {
        match f() {
            Ok(v) => return Ok(v),
            Err(e) if e.transient && i < 4 => {
                // When the server says how long to wait, wait that long (at most 5 minutes).
                let ms = e
                    .retry_after_ms
                    .map(|r| r.clamp(1000, 300_000))
                    .unwrap_or(wait);
                if !nap(cx, ms) {
                    return Err(e);
                }
                wait = (wait * 2).min(15_000);
            }
            Err(e) => return Err(e),
        }
    }
    f()
}

/// A trigger whose response was lost or that was accepted without an ID: never resend, only search by correlation ID.
fn search_after_trigger(
    p: &dyn Provider,
    cx: &NodeCx,
    corr: &str,
    sent_at: u64,
    handle: Option<&Value>,
    find_ms: u64,
    poll_ms: u64,
) -> Result<Option<RemoteRun>, CiErr> {
    let until = Instant::now() + Duration::from_millis(find_ms);
    loop {
        if let Some(h) = handle {
            match p.resolve_accepted(h) {
                Ok(Some(r)) => return Ok(Some(r)),
                Err(e) if !e.transient => return Err(e),
                _ => {}
            }
        }
        if p.searchable() {
            if let Ok(Some(r)) = p.find(corr, sent_at.saturating_sub(10_000)) {
                return Ok(Some(r));
            }
        } else if handle.is_none() {
            return Ok(None);
        }
        if Instant::now() >= until || !nap(cx, poll_ms.clamp(200, 3000)) {
            return Ok(None);
        }
    }
}

pub fn drive(p: &dyn Provider, cx: &mut NodeCx, opts: &DriveOpts) -> Driven {
    let corr = correlation(cx.events_run_id(), &cx.id);
    let mut d = Driven {
        run: None,
        status: None,
        contract: None,
        report: None,
        reused: false,
        error: None,
        we_cancelled: false,
        timed_out: false,
        log_lines: 0,
    };
    let since = crate::util::now_ms().saturating_sub(15 * 60_000);
    cx.note(&format!(
        "{} · {} {corr}",
        p.label(),
        tr("상관 ID", "correlation id")
    ));
    // 1) Look first (if this run and node already sent one, follow it).
    match with_retry(cx, || p.find(&corr, since)) {
        Ok(Some(r)) => {
            cx.note(&tr(
                &format!("이미 있는 원격 실행을 이어서 봅니다: {}", r.url),
                &format!("following an existing remote run: {}", r.url),
            ));
            d.run = Some(r);
            d.reused = true;
        }
        Ok(None) => {}
        Err(e) if !e.transient => {
            d.error = Some(e);
            return d;
        }
        Err(_) => {}
    }
    // 2) Send. With the response lost, never resend; only search.
    if d.run.is_none() {
        let sent_at = crate::util::now_ms();
        let mut attempt = 0;
        let outcome = loop {
            attempt += 1;
            match p.trigger(&corr) {
                Err(e) if e.code == "CONN-06" && e.http == Some(429) && attempt < 3 => {
                    // A rate-limited request was not processed, so it may be sent again after waiting.
                    let ms = e
                        .retry_after_ms
                        .map(|r| r.clamp(1000, 120_000))
                        .unwrap_or(10_000);
                    cx.note(&tr(
                        &format!("속도 제한 — {}초 뒤 다시 보냅니다.", ms / 1000),
                        &format!("rate limited — sending again in {}s.", ms / 1000),
                    ));
                    if !nap(cx, ms) {
                        break Err(e);
                    }
                }
                other => break other,
            }
        };
        match outcome {
            Ok(Triggered::Created(r)) => d.run = Some(r),
            Ok(Triggered::Accepted(handle)) => {
                match search_after_trigger(
                    p,
                    cx,
                    &corr,
                    sent_at,
                    handle.as_ref(),
                    opts.find_ms,
                    opts.poll_ms,
                ) {
                    Ok(r) => d.run = r,
                    Err(e) => {
                        d.error = Some(e);
                        return d;
                    }
                }
                if d.run.is_none() {
                    d.error = Some(CiErr {
                        code: "CI-01",
                        http: None,
                        message: tr(
                            "트리거는 받아들여졌지만 실행을 찾지 못했습니다.",
                            "the trigger was accepted but the run was not found.",
                        ),
                        unknown_outcome: true,
                        transient: false,
                        retry_after_ms: None,
                    });
                    return d;
                }
            }
            Err(e) if e.unknown_outcome => {
                cx.note(&tr(
                    "트리거 응답을 받지 못했습니다 — 다시 보내지 않고 상관 ID 로 찾습니다.",
                    "no answer to the trigger — searching by correlation id instead of re-sending.",
                ));
                d.run =
                    search_after_trigger(p, cx, &corr, sent_at, None, opts.find_ms, opts.poll_ms)
                        .unwrap_or(None);
                if d.run.is_none() {
                    d.error = Some(CiErr {
                        code: "CI-01",
                        http: e.http,
                        message: e.message,
                        unknown_outcome: true,
                        transient: false,
                        retry_after_ms: None,
                    });
                    return d;
                }
            }
            Err(e) => {
                d.error = Some(e);
                return d;
            }
        }
    }
    let run = d.run.clone().expect("run");
    cx.note(&format!("{}: {}", tr("원격 실행", "remote run"), run.url));
    // 3) Wait (deadline, cancel, external cancel).
    let deadline = Instant::now() + Duration::from_millis(opts.timeout_ms);
    let mut cursor = Value::Null;
    let base_poll = opts.poll_ms.max(200);
    let mut poll = base_poll;
    let mut told_waiting = false;
    loop {
        if cx.cancel.is_cancelled() || Instant::now() >= deadline {
            d.timed_out = !cx.cancel.is_cancelled();
            d.we_cancelled = true;
            let _ = p.cancel(&run);
            cx.note(&tr(
                "원격 실행에 취소를 요청했습니다.",
                "asked the remote CI to cancel the run.",
            ));
            break;
        }
        match with_retry(cx, || p.status(&run)) {
            Ok(s) => {
                let finished = matches!(
                    s.state,
                    RState::Succeeded | RState::Failed | RState::Cancelled
                );
                if let Ok(lines) = p.logs(&run, &mut cursor) {
                    d.log_lines += lines.len();
                    for l in lines {
                        cx.log_line(&l);
                    }
                }
                if s.state == RState::Waiting && !told_waiting {
                    told_waiting = true;
                    cx.note(&tr(
                        "원격 CI 가 사람의 동작(수동 작업 · 승인)을 기다립니다.",
                        "the remote CI is waiting for a person (manual job or approval).",
                    ));
                }
                d.status = Some(s);
                if finished {
                    break;
                }
            }
            Err(e) => {
                d.error = Some(e);
                break;
            }
        }
        if !nap(cx, poll) {
            continue;
        }
        poll = (poll + base_poll / 5 + 200).min(15_000.max(base_poll));
    }
    // 4) The result contract and reports. The last log marker wins.
    if let Ok(Some(c)) = p.contract(&run) {
        d.contract = Some(c);
    }
    if d.contract.is_none() {
        let log_text = cx
            .log_path()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        d.contract = contract::parse_marker(&log_text);
    }
    if let Ok(Some(r)) = p.report(&run) {
        d.report = Some(r);
    }
    let _ = opts.require_contract;
    d
}

/// `gitch flow ci status|logs|report|trigger`: this repository's remote CI from the command line (what the apps' CI/CD tab does).
pub fn cmd_ci(out: &crate::cli::Out, args: &crate::cli::Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return 1;
    };
    let remote = crate::git::remote_url(&root).unwrap_or_default();
    let conn = args
        .val("--connection")
        .and_then(|n| crate::connect::find(&n))
        .or_else(|| guess_connection(&remote));
    let Some(conn) = conn else {
        let msg = tr("이 저장소의 원격 CI 연결을 찾지 못했습니다. gitch flow connect add github|gitlab … 로 만드세요.", "no remote CI connection for this repository; create one with gitch flow connect add github|gitlab ….");
        if out.json {
            eprintln!(
                "{}",
                serde_json::json!({"schemaVersion": 1, "error": {"code": "GITCH_ERROR", "flowCode": "CONN-01", "message": msg, "exitCode": 1}})
            );
        } else {
            eprintln!("{msg}");
        }
        return 1;
    };
    let sub = args.pos.first().map(|s| s.as_str()).unwrap_or("status");
    let branch = args
        .val("--ref")
        .or_else(|| crate::git::branch(&root))
        .unwrap_or_else(|| "main".into());
    let project = conn.project.clone().unwrap_or_else(|| repo_path(&remote));
    match (conn.kind.as_str(), sub) {
        ("gitlab", "status") => gitlab::cli_status(out, &conn, &project, &branch),
        ("github", "status") => github::cli_status(out, &conn, &project, &branch),
        ("gitlab", "report") => {
            gitlab::cli_report(out, &conn, &project, args.pos.get(1).map(|s| s.as_str()))
        }
        ("gitlab", "logs") | ("github", "logs") => {
            let Some(job) = args.pos.get(1) else {
                eprintln!("{}", tr("작업 ID 가 필요합니다.", "a job id is required."));
                return 1;
            };
            if conn.kind == "gitlab" {
                gitlab::cli_logs(out, &conn, &project, job)
            } else {
                github::cli_logs(out, &conn, &project, job)
            }
        }
        (_, other) => {
            eprintln!("{}", tr(&format!("{} 연결은 '{other}' 을(를) 아직 지원하지 않습니다(흐름 노드 ci.* 를 쓰세요).", conn.kind), &format!("'{other}' is not supported for {} connections yet (use a ci.* flow node).", conn.kind)));
            1
        }
    }
}

/// The repository path in a remote URL (owner/name, group/sub/name).
pub fn repo_path(remote: &str) -> String {
    let s = remote.trim().trim_end_matches(".git");
    let after = if let Some(i) = s.find("://") {
        let rest = &s[i + 3..];
        rest.split_once('/').map(|x| x.1).unwrap_or("")
    } else if let Some(i) = s.find(':') {
        &s[i + 1..]
    } else {
        s
    };
    after.trim_start_matches('/').to_string()
}

fn host_of(remote: &str) -> String {
    let s = remote.trim();
    let rest = s.split("://").nth(1).unwrap_or(s);
    let rest = rest.split('@').next_back().unwrap_or(rest);
    rest.split(['/', ':']).next().unwrap_or("").to_string()
}

/// Picks the connection that matches the remote host (github.com → github; otherwise a gitlab connection with the same host).
fn guess_connection(remote: &str) -> Option<crate::connect::Connection> {
    let host = host_of(remote);
    let all = crate::connect::list();
    all.iter()
        .find(|c| {
            c.kind == "github"
                && (host == "github.com" || host.starts_with("github-"))
                && (c.url.is_empty() || c.url.contains("github.com"))
        })
        .or_else(|| {
            all.iter()
                .find(|c| c.kind == "gitlab" && !host.is_empty() && c.url.contains(&host))
        })
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc4648() {
        assert_eq!(b64(""), "");
        assert_eq!(b64("f"), "Zg==");
        assert_eq!(b64("fo"), "Zm8=");
        assert_eq!(b64("foo"), "Zm9v");
        assert_eq!(b64("user:token"), "dXNlcjp0b2tlbg==");
    }

    #[test]
    fn repo_paths() {
        assert_eq!(repo_path("git@github.com:owner/repo.git"), "owner/repo");
        assert_eq!(
            repo_path("https://gitlab.example.com/group/sub/repo.git"),
            "group/sub/repo"
        );
        assert_eq!(
            repo_path("ssh://git@gitlab.example.com:2222/group/repo.git"),
            "group/repo"
        );
        assert_eq!(
            host_of("ssh://git@gitlab.example.com:2222/group/repo.git"),
            "gitlab.example.com"
        );
        assert_eq!(host_of("git@github.com:owner/repo.git"), "github.com");
    }

    #[test]
    fn correlation_ids_are_safe() {
        let c = correlation("20261026-123456-abcdef", "e2e/remote");
        assert!(c.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-'));
        assert!(c.starts_with("gitch-20261026"));
    }
}
