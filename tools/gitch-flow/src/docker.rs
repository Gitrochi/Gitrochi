//! Docker 연결. SDK 대신 docker(또는 podman) CLI 를 셸 없이 인자 배열로 부르고,
//! 만든 것에는 모두 라벨(gitch.flow.run …)을 붙여 정리 · gc 가 라벨로만 찾게 한다.

use crate::process::{self, Cancel, ProcSpec};
use crate::services::SvcCx;
use crate::spec::ServiceDef;
use crate::util::tr;
use serde_json::{json, Value};
use std::path::Path;
use std::time::{Duration, Instant};

pub fn bin() -> String {
    if let Ok(b) = std::env::var("GITCH_DOCKER") {
        if !b.is_empty() {
            return b;
        }
    }
    "docker".into()
}

pub struct Out {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// docker 명령 하나(시간 제한 있음).
pub fn run(args: &[&str], timeout_ms: u64) -> Out {
    let spec = ProcSpec {
        program: bin(),
        args: args.iter().map(|s| s.to_string()).collect(),
        cwd: std::env::temp_dir(),
        env: vec![],
        clear_env: false,
        timeout_ms: Some(timeout_ms),
        settle_ms: 2000,
    };
    let mut out = String::new();
    let mut err = String::new();
    let o = process::run(&spec, &Cancel::new(), &mut |s, l| {
        let buf = if s == process::Stream::Out {
            &mut out
        } else {
            &mut err
        };
        if buf.len() < 1_000_000 {
            buf.push_str(l);
            buf.push('\n');
        }
    });
    if let Some(e) = o.spawn_error {
        err = e;
    }
    Out {
        code: o.exit_code,
        stdout: out,
        stderr: err,
    }
}

/// 데몬에 닿는지. 닿지 않으면 이유.
pub fn available() -> Result<String, String> {
    let o = run(&["version", "--format", "{{.Server.Version}}"], 8000);
    match o.code {
        Some(0) if !o.stdout.trim().is_empty() => Ok(o.stdout.trim().to_string()),
        _ => Err(if o.stderr.trim().is_empty() {
            tr("Docker 에 닿지 못했습니다", "Docker is not reachable")
        } else {
            o.stderr.trim().lines().last().unwrap_or("").to_string()
        }),
    }
}

pub fn network_name(run_id: &str) -> String {
    format!("gitch-flow-{}", crate::store::safe(run_id))
}

fn ensure_network(run_id: &str, repo: &str) -> Result<String, String> {
    let name = network_name(run_id);
    let o = run(&["network", "inspect", &name], 8000);
    if o.code == Some(0) {
        return Ok(name);
    }
    let label_run = format!("gitch.flow.run={run_id}");
    let label_repo = format!("gitch.repo={repo}");
    let c = run(
        &[
            "network",
            "create",
            "--label",
            &label_run,
            "--label",
            &label_repo,
            &name,
        ],
        15_000,
    );
    if c.code == Some(0) {
        Ok(name)
    } else {
        Err(c.stderr.trim().to_string())
    }
}

fn container_running(name: &str) -> bool {
    let o = run(&["inspect", "-f", "{{.State.Running}}", name], 8000);
    o.code == Some(0) && o.stdout.trim() == "true"
}

/// `docker.service`: 이미지 하나를 띄우고 건강 확인을 기다린다.
pub fn start_service(
    def: &ServiceDef,
    with: &Value,
    port: u16,
    cx: &SvcCx,
    log_path: &Path,
    timeout_ms: u64,
) -> Result<(String, Value), (&'static str, String)> {
    available().map_err(|e| ("DOCKER-01", e))?;
    let image = with.get("image").and_then(|i| i.as_str()).ok_or((
        "SERVICE-02",
        tr(
            "docker.service 에 image 가 필요합니다.",
            "docker.service needs image.",
        ),
    ))?;
    let repo = crate::trust::repo_id(cx.root);
    let net = ensure_network(cx.run_id, &repo).map_err(|e| ("DOCKER-03", e))?;
    let name = format!(
        "gitch-flow-{}-{}",
        crate::store::safe(cx.run_id),
        crate::store::safe(&def.name)
    );
    let mut args: Vec<String> = vec!["run".into(), "-d".into(), "--name".into(), name.clone()];
    for l in [
        format!("gitch.flow.run={}", cx.run_id),
        format!("gitch.flow.service={}", def.name),
        format!("gitch.repo={repo}"),
    ] {
        args.push("--label".into());
        args.push(l);
    }
    args.extend([
        "--network".into(),
        net.clone(),
        "--network-alias".into(),
        def.name.clone(),
    ]);
    let pull = with
        .get("pull")
        .and_then(|p| p.as_str())
        .unwrap_or("missing");
    args.push(format!("--pull={pull}"));
    let ports: Vec<String> = match with.get("ports") {
        Some(Value::Array(a)) => a.iter().map(crate::expr::to_text).collect(),
        Some(v) if !v.is_null() => vec![crate::expr::to_text(v)],
        _ => Vec::new(),
    };
    let mut mapped = serde_json::Map::new();
    for (i, p) in ports.iter().enumerate() {
        let host = if i == 0 {
            port
        } else {
            crate::services::free_port()
        };
        args.push("-p".into());
        args.push(format!("127.0.0.1:{host}:{p}"));
        mapped.insert(p.clone(), json!(host));
    }
    if let Some(o) = with.get("env").and_then(|e| e.as_object()) {
        for (k, v) in o {
            args.push("-e".into());
            args.push(format!("{k}={}", crate::expr::to_text(v)));
            if k.to_ascii_uppercase().contains("PASSWORD")
                || k.to_ascii_uppercase().contains("TOKEN")
            {
                cx.masker.add_secret(k, &crate::expr::to_text(v));
            }
        }
    }
    args.push(image.to_string());
    match with.get("command") {
        Some(Value::Array(a)) => args.extend(a.iter().map(crate::expr::to_text)),
        Some(Value::String(s)) => args.extend(s.split_whitespace().map(|x| x.to_string())),
        _ => {}
    }
    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    let started = run(&arg_refs, 600_000);
    if started.code != Some(0) {
        let e = started.stderr.trim().to_string();
        let code = if e.contains("pull") || e.contains("manifest") || e.contains("not found") {
            "DOCKER-02"
        } else {
            "DOCKER-03"
        };
        remove_container(&name);
        return Err((code, cx.masker.mask(&e)));
    }
    let t0 = Instant::now();
    let health = with.get("health").cloned().unwrap_or(Value::Null);
    let ready = with.get("ready").cloned().unwrap_or(Value::Null);
    let health_timeout = health
        .get("timeout")
        .and_then(|t| t.as_str())
        .and_then(crate::util::parse_duration)
        .unwrap_or(timeout_ms);
    loop {
        if cx.cancel.is_cancelled() {
            save_logs(&name, log_path, cx);
            remove_container(&name);
            return Err(("SERVICE-02", tr("취소됨", "cancelled")));
        }
        if !container_running(&name) {
            save_logs(&name, log_path, cx);
            remove_container(&name);
            return Err((
                "SERVICE-02",
                tr(
                    "컨테이너가 준비 전에 멈췄습니다",
                    "the container stopped before it was ready",
                ),
            ));
        }
        let mut ok = true;
        if let Some(cmd) = health.get("cmd").and_then(|c| c.as_str()) {
            ok &= run(&["exec", &name, "sh", "-c", cmd], 15_000).code == Some(0);
        } else if ready.is_null() && port > 0 && !ports.is_empty() {
            ok &= std::net::TcpStream::connect_timeout(
                &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
                Duration::from_millis(500),
            )
            .is_ok();
        }
        if let Some(u) = ready.get("http").and_then(|h| h.as_str()) {
            ok &= matches!(crate::http::send(&crate::http::Req { timeout_ms: 2000, ..crate::http::Req::get(u) }), Ok(r) if r.status < 500);
        }
        if ok {
            break;
        }
        if t0.elapsed().as_millis() as u64 >= health_timeout {
            save_logs(&name, log_path, cx);
            remove_container(&name);
            return Err((
                "SERVICE-01",
                tr(
                    "컨테이너 건강 확인 시간 초과",
                    "container health check timed out",
                ),
            ));
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let info = json!({"host": "127.0.0.1", "port": port, "ports": mapped, "container": name, "network": net, "alias": def.name,
                      "url": format!("http://127.0.0.1:{port}"), "readyMs": t0.elapsed().as_millis() as u64});
    Ok((name, info))
}

fn save_logs(name: &str, log_path: &Path, cx: &SvcCx) {
    let o = run(&["logs", "--tail", "2000", name], 15_000);
    let text = cx.masker.mask(&format!("{}{}", o.stdout, o.stderr));
    let _ = std::fs::write(log_path, text);
}

pub fn remove_container(name: &str) {
    let _ = run(&["rm", "-f", "-v", name], 30_000);
}

/// `compose.up`: compose 파일로 여러 서비스를 띄우고 `--wait` 로 건강 확인을 기다린다.
pub fn compose_up(
    def: &ServiceDef,
    with: &Value,
    cx: &SvcCx,
    log_path: &Path,
    timeout_ms: u64,
) -> Result<(String, String, Value), (&'static str, String)> {
    available().map_err(|e| ("DOCKER-01", e))?;
    let file = with
        .get("file")
        .and_then(|f| f.as_str())
        .unwrap_or("compose.yml")
        .to_string();
    let path = cx.root.join(&file);
    if !path.is_file() {
        return Err((
            "SERVICE-02",
            tr(
                &format!("{file} 이(가) 없습니다."),
                &format!("{file} does not exist."),
            ),
        ));
    }
    let project = format!(
        "gitch-flow-{}-{}",
        crate::store::safe(cx.run_id).to_ascii_lowercase(),
        crate::store::safe(&def.name).to_ascii_lowercase()
    );
    let p = path.to_string_lossy().to_string();
    let secs = (timeout_ms / 1000).max(10).to_string();
    let mut args = vec![
        "compose",
        "-f",
        &p,
        "-p",
        &project,
        "up",
        "-d",
        "--wait",
        "--wait-timeout",
        &secs,
    ];
    let services: Vec<String> = with
        .get("services")
        .and_then(|s| s.as_array())
        .map(|a| a.iter().map(crate::expr::to_text).collect())
        .unwrap_or_default();
    for s in &services {
        args.push(s);
    }
    let o = run(&args, timeout_ms + 60_000);
    let _ = std::fs::write(
        log_path,
        cx.masker.mask(&format!("{}{}", o.stdout, o.stderr)),
    );
    if o.code != Some(0) {
        let logs = run(
            &[
                "compose",
                "-f",
                &p,
                "-p",
                &project,
                "logs",
                "--no-color",
                "--tail",
                "200",
            ],
            30_000,
        );
        let _ = std::fs::write(
            log_path,
            cx.masker
                .mask(&format!("{}{}{}", o.stderr, logs.stdout, logs.stderr)),
        );
        compose_down(&p, &project, cx.run_dir);
        return Err(("SERVICE-01", cx.masker.mask(o.stderr.trim())));
    }
    Ok((
        p,
        project.clone(),
        json!({"project": project, "file": file}),
    ))
}

pub fn compose_down(file: &str, project: &str, _run_dir: &Path) {
    let _ = run(
        &[
            "compose",
            "-f",
            file,
            "-p",
            project,
            "down",
            "-v",
            "--remove-orphans",
            "--timeout",
            "10",
        ],
        120_000,
    );
}

/// 이 실행이 만든 컨테이너 · 네트워크를 라벨로 찾아 지운다.
pub fn cleanup_run(run_id: &str) {
    let filter = format!("label=gitch.flow.run={run_id}");
    let o = run(&["ps", "-aq", "--filter", &filter], 15_000);
    for id in o.stdout.split_whitespace() {
        remove_container(id);
    }
    let _ = run(&["network", "rm", &network_name(run_id)], 15_000);
}

/// 끝난 실행의 남은 컨테이너(라벨 기준).
pub fn leftovers() -> Vec<(String, String)> {
    let o = run(
        &[
            "ps",
            "-a",
            "--filter",
            "label=gitch.flow.run",
            "--format",
            "{{.Names}}\t{{.Label \"gitch.flow.run\"}}",
        ],
        15_000,
    );
    if o.code != Some(0) {
        return Vec::new();
    }
    o.stdout
        .lines()
        .filter_map(|l| {
            l.split_once('\t')
                .map(|(a, b)| (a.to_string(), b.to_string()))
        })
        .collect()
}
