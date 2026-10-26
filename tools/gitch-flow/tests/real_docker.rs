//! Real Docker tests. They run only where a daemon is available:
//!   GITCH_FLOW_REAL_DOCKER=1 cargo test --test real_docker -- --ignored --test-threads 1
//! the executor (running inside a container, same-path mounts, file owner), docker.service (health check, port),
//! containers reaching each other by service alias, and nothing left behind by label afterwards.

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
    // Only this test uses the real docker (so the fake CLI is not picked).
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
