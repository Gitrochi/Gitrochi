//! Services: processes and containers that stay up during a flow. They start right before the first node that needs them,
//! nodes start only after their health checks pass, and services are always stopped when the run ends.

use crate::http::{self, Req};
use crate::mask::Masker;
use crate::process::{self, Group, ProcSpec};
use crate::spec::ServiceDef;
use crate::util::tr;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

pub const KINDS: &[&str] = &[
    "process.service",
    "docker.service",
    "compose.up",
    "mock.http",
];

pub fn known(uses: &str) -> bool {
    KINDS.contains(&uses)
}

pub struct Running {
    pub name: String,
    pub info: Value,
    kind: Kind,
}

enum Kind {
    Process {
        child: std::process::Child,
        group: Group,
    },
    Docker {
        container: String,
    },
    Compose {
        file: String,
        project: String,
    },
    Mock(crate::mock::Mock),
}

pub struct SvcCx<'a> {
    pub root: &'a Path,
    pub run_dir: &'a Path,
    pub run_id: &'a str,
    pub env: &'a [(String, String)],
    pub masker: &'a Masker,
    pub cancel: &'a process::Cancel,
}

/// A free local port.
pub fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .unwrap_or(0)
}

fn ready_wait(
    r: &Value,
    port: u16,
    log_path: &Path,
    deadline_ms: u64,
    alive: &mut dyn FnMut() -> bool,
    cancel: &process::Cancel,
) -> Result<u64, String> {
    let started = Instant::now();
    let http_url = r
        .get("http")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let want_port = r.get("port").and_then(|v| v.as_u64()).map(|p| p as u16).or(
        if http_url.is_none() && r.get("log").is_none() && port > 0 {
            Some(port)
        } else {
            None
        },
    );
    let log_re = r
        .get("log")
        .and_then(|v| v.as_str())
        .and_then(|p| regex::Regex::new(p).ok());
    loop {
        if cancel.is_cancelled() {
            return Err(tr("취소됨", "cancelled"));
        }
        if !alive() {
            return Err(tr(
                "서비스 프로세스가 준비 전에 끝났습니다",
                "the service exited before it was ready",
            ));
        }
        let mut ok = true;
        if let Some(u) = &http_url {
            ok &= matches!(http::send(&Req { timeout_ms: 2000, ..Req::get(u) }), Ok(resp) if resp.status < 500);
        }
        if let Some(p) = want_port {
            ok &= std::net::TcpStream::connect_timeout(
                &std::net::SocketAddr::from(([127, 0, 0, 1], p)),
                Duration::from_millis(500),
            )
            .is_ok();
        }
        if let Some(re) = &log_re {
            ok &= std::fs::read_to_string(log_path)
                .map(|t| re.is_match(&t))
                .unwrap_or(false);
        }
        if ok {
            return Ok(started.elapsed().as_millis() as u64);
        }
        if started.elapsed().as_millis() as u64 >= deadline_ms {
            return Err(tr("준비 시간 초과", "readiness timed out"));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

fn log_tail(path: &Path, n: usize) -> String {
    let t = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = t.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

/// Starts a service. `with` has its expressions resolved already, and `port` is chosen in advance.
pub fn start(
    def: &ServiceDef,
    with: &Value,
    port: u16,
    cx: &SvcCx,
) -> Result<Running, (&'static str, String)> {
    let log_path = cx
        .run_dir
        .join("logs")
        .join(format!("service-{}.log", crate::store::safe(&def.name)));
    let _ = std::fs::create_dir_all(log_path.parent().unwrap_or(cx.run_dir));
    let timeout = with
        .get("ready")
        .and_then(|r| r.get("timeout"))
        .and_then(|t| t.as_str())
        .and_then(crate::util::parse_duration)
        .unwrap_or(60_000);
    match def.uses.as_str() {
        "process.service" => {
            let script = with.get("run").and_then(|r| r.as_str()).ok_or((
                "SERVICE-02",
                tr(
                    "process.service 에 run 이 필요합니다.",
                    "process.service needs run.",
                ),
            ))?;
            let cwd = with
                .get("cwd")
                .and_then(|c| c.as_str())
                .map(|c| cx.root.join(c))
                .unwrap_or_else(|| cx.root.to_path_buf());
            let mut env: Vec<(String, String)> = cx.env.to_vec();
            env.push(("PORT".into(), port.to_string()));
            if let Some(o) = with.get("env").and_then(|e| e.as_object()) {
                for (k, v) in o {
                    env.push((k.clone(), crate::expr::to_text(v)));
                }
            }
            let shell = with.get("shell").and_then(|s| s.as_str()).unwrap_or("bash");
            let (program, args) = process::shell_command(shell, script);
            let spec = ProcSpec {
                program,
                args,
                cwd,
                env,
                clear_env: true,
                timeout_ms: None,
                settle_ms: 3000,
            };
            let log_file =
                std::fs::File::create(&log_path).map_err(|e| ("SERVICE-02", e.to_string()))?;
            let err_file = log_file
                .try_clone()
                .map_err(|e| ("SERVICE-02", e.to_string()))?;
            let (mut child, group) =
                process::spawn(&spec, Stdio::from(log_file), Stdio::from(err_file))
                    .map_err(|e| ("SERVICE-02", format!("{}: {e}", spec.program)))?;
            let ready = with.get("ready").cloned().unwrap_or(Value::Null);
            let mut alive = || matches!(child.try_wait(), Ok(None));
            match ready_wait(&ready, port, &log_path, timeout, &mut alive, cx.cancel) {
                Ok(ms) => Ok(Running {
                    name: def.name.clone(),
                    info: json!({"host": "127.0.0.1", "port": port, "url": format!("http://127.0.0.1:{port}"), "readyMs": ms, "log": crate::util::rel_slash(cx.run_dir, &log_path)}),
                    kind: Kind::Process { child, group },
                }),
                Err(e) => {
                    group.terminate();
                    std::thread::sleep(Duration::from_millis(300));
                    group.kill();
                    let _ = child.kill();
                    let _ = child.wait();
                    let tail = cx.masker.mask(&log_tail(&log_path, 15));
                    let code = if e.contains("timed out") || e.contains("시간 초과") {
                        "SERVICE-01"
                    } else {
                        "SERVICE-02"
                    };
                    Err((code, format!("{e}\n{tail}")))
                }
            }
        }
        "mock.http" => {
            let table =
                crate::mock::load(with, cx.root, &def.name).map_err(|e| ("SERVICE-02", e))?;
            let faults: Vec<String> = with
                .get("faults")
                .and_then(|f| f.as_array())
                .map(|a| a.iter().map(crate::expr::to_text).collect())
                .unwrap_or_default();
            let bind = with
                .get("bind")
                .and_then(|b| b.as_str())
                .unwrap_or("127.0.0.1");
            let m = crate::mock::Mock::start(table, faults, bind, port, log_path.clone())
                .map_err(|e| ("SERVICE-02", e))?;
            let p = m.port;
            Ok(Running {
                name: def.name.clone(),
                info: json!({"host": "127.0.0.1", "port": p, "url": format!("http://127.0.0.1:{p}"), "kind": "mock",
                             "control": format!("http://127.0.0.1:{p}/__gitch"), "readyMs": 0, "log": crate::util::rel_slash(cx.run_dir, &log_path)}),
                kind: Kind::Mock(m),
            })
        }
        "docker.service" => crate::docker::start_service(def, with, port, cx, &log_path, timeout)
            .map(|(container, info)| Running {
                name: def.name.clone(),
                info,
                kind: Kind::Docker { container },
            }),
        "compose.up" => crate::docker::compose_up(def, with, cx, &log_path, timeout).map(
            |(file, project, info)| Running {
                name: def.name.clone(),
                info,
                kind: Kind::Compose { file, project },
            },
        ),
        other => Err((
            "SERVICE-02",
            tr(
                &format!("서비스 종류 '{other}' 은(는) 지원하지 않습니다."),
                &format!("service kind '{other}' is not supported."),
            ),
        )),
    }
}

/// Stops a service (also called after a failure or cancel).
pub fn stop(r: Running, run_dir: &Path) {
    match r.kind {
        Kind::Process { mut child, group } => {
            group.terminate();
            let until = Instant::now() + Duration::from_millis(3000);
            while Instant::now() < until {
                if let Ok(Some(_)) = child.try_wait() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            group.kill();
            let _ = child.kill();
            let _ = child.wait();
        }
        Kind::Docker { container } => crate::docker::remove_container(&container),
        Kind::Compose { file, project } => crate::docker::compose_down(&file, &project, run_dir),
        Kind::Mock(m) => m.stop(),
    }
}

/// The service's log path (for the apps and reports).
pub fn log_path(run_dir: &Path, name: &str) -> PathBuf {
    run_dir
        .join("logs")
        .join(format!("service-{}.log", crate::store::safe(name)))
}

/// Records the services left running (--keep-services).
pub fn keep_note(run_dir: &Path, r: &Running) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(run_dir.join("kept-services.ndjson"))
    {
        let _ = writeln!(f, "{}", json!({"name": r.name, "info": r.info}));
    }
}
