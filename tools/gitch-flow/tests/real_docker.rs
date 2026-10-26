//! 실제 Docker 시험. 데몬이 있는 곳에서만 돈다:
//!   GITCH_FLOW_REAL_DOCKER=1 cargo test --test real_docker -- --ignored --test-threads 1
//! executor(컨테이너 안 실행 · 같은 경로 마운트 · 파일 소유자) · docker.service(건강 확인 · 포트) ·
//! 서비스 별칭으로 컨테이너끼리 닿기 · 끝난 뒤 라벨로 남은 것 없음을 본다.

#![cfg(unix)]

mod common;

use common::Fx;
use serde_json::Value;

fn enabled() -> bool {
    std::env::var("GITCH_FLOW_REAL_DOCKER")
        .map(|v| v == "1")
        .unwrap_or(false)
}

fn docker(args: &[&str]) -> String {
    let o = std::process::Command::new("docker")
        .args(args)
        .output()
        .unwrap();
    String::from_utf8_lossy(&o.stdout).to_string()
}

fn node<'a>(run: &'a Value, id: &str) -> &'a Value {
    run["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("no node {id} in {run}"))
}

const FLOW: &str = r#"version: 1
services:
  web:
    use: docker.service
    with:
      image: "nginx:1.27-alpine"
      ports: ["80"]
      health: { cmd: "wget -q -O /dev/null http://127.0.0.1/", timeout: 90s }
flows:
  inside:
    nodes:
      write:
        run: "echo from-container > made-in-container.txt; cat /etc/alpine-release"
        executor: "docker:alpine:3.20"
        expect: { output: "3.20" }
  smoke:
    nodes:
      page: { use: check.http, services: [web], with: { url: "${{ services.web.url }}/", expect: { status: 200, contains: nginx } } }
      inside: { needs: [page], services: [web], executor: "docker:alpine:3.20", run: "wget -q -O - http://${{ services.web.host }}:${{ services.web.port }}/ | grep -q nginx" }
"#;

fn run(fx: &Fx, flow: &str) -> (i32, Value) {
    let mut c = fx.cmd("script", &["run", flow, "--json"]);
    // 이 시험만은 진짜 docker 를 쓴다(가짜 CLI 를 고르지 않게).
    c.env_remove("GITCH_DOCKER");
    if let Ok(h) = std::env::var("DOCKER_HOST") {
        c.env("DOCKER_HOST", h);
    }
    let o = c.output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    (
        o.status.code().unwrap_or(-1),
        serde_json::from_str(&out)
            .unwrap_or_else(|_| panic!("{out}\n{}", String::from_utf8_lossy(&o.stderr))),
    )
}

#[test]
#[ignore]
fn executor_runs_in_a_real_container_with_the_repo_mounted() {
    if !enabled() {
        return;
    }
    let fx = Fx::new(&[(".gitch/flow.yml", FLOW)]);
    fx.trust();
    let (code, r) = run(&fx, "inside");
    assert_eq!(code, 0, "{r}");
    assert_eq!(node(&r, "write")["state"], "PASSED");
    let made = fx.repo().join("made-in-container.txt");
    assert_eq!(std::fs::read_to_string(&made).unwrap(), "from-container\n");
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        let uid = unsafe { libc::getuid() };
        assert_eq!(
            std::fs::metadata(&made).unwrap().uid(),
            uid,
            "files written in the container belong to the user"
        );
    }
    let id = r["runId"].as_str().unwrap();
    assert!(docker(&[
        "ps",
        "-aq",
        "--filter",
        &format!("label=gitch.flow.run={id}")
    ])
    .trim()
    .is_empty());
}

#[test]
#[ignore]
fn a_real_service_is_reachable_from_host_and_containers_and_then_removed() {
    if !enabled() {
        return;
    }
    let fx = Fx::new(&[(".gitch/flow.yml", FLOW)]);
    fx.trust();
    let (code, r) = run(&fx, "smoke");
    assert_eq!(code, 0, "{r}");
    assert_eq!(node(&r, "page")["state"], "PASSED");
    assert_eq!(
        node(&r, "inside")["state"],
        "PASSED",
        "a container reaches the service by its alias"
    );
    let id = r["runId"].as_str().unwrap();
    assert!(
        docker(&[
            "ps",
            "-aq",
            "--filter",
            &format!("label=gitch.flow.run={id}")
        ])
        .trim()
        .is_empty(),
        "containers left behind"
    );
    assert!(
        docker(&[
            "network",
            "ls",
            "-q",
            "--filter",
            &format!("name=gitch-flow-{id}")
        ])
        .trim()
        .is_empty(),
        "network left behind"
    );
}
