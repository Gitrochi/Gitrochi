//! Docker 실행 위치(`executor: docker:<이미지>`)와 docker.run · docker.build · docker.push 블록 시험.
//! 가짜 docker CLI 가 `run` 의 명령을 호스트에서 그대로 돌려(작업 폴더 · 환경은 그대로) 컨테이너를 흉내 낸다.
//! 엔진이 docker 에 넘기는 인자(라벨 · 마운트 · 이름만 넘기는 환경 · 정리)를 확인한다.

#![cfg(unix)]

mod common;

use common::Fx;
use serde_json::Value;
use std::path::{Path, PathBuf};

const FAKE_DOCKER: &str = r##"#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  version)
    if [ -n "$FAKE_DOCKER_DOWN" ]; then
      echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
      exit 1
    fi
    echo "27.3.1" ;;
  run)
    shift
    detach=0; wd=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -d) detach=1; shift ;;
        --rm|-i) shift ;;
        --pull=*) shift ;;
        --name|--label|-v|-e|--network|--network-alias|--add-host|--user|--entrypoint|-p) shift 2 ;;
        -w) wd="$2"; shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    image="$1"; shift
    if [ "$detach" = 1 ]; then echo c0ffee; exit 0; fi
    if [ -n "$FAKE_DOCKER_RUN_125" ]; then echo "docker: Error response from daemon: invalid mount config" >&2; exit 125; fi
    printf 'IMAGE %s\n' "$image" >> "$FAKE_DOCKER_LOG"
    [ -n "$wd" ] && cd "$wd"
    exec "$@" ;;
  build)
    printf 'BUILDARG_TOKEN=%s\n' "${NPM_TOKEN:-unset}" >> "$FAKE_DOCKER_LOG.env"
    echo "#1 building"; echo "#2 DONE" ;;
  image)
    case "$4" in
      *RepoDigests*) echo "registry.example.invalid/demo@sha256:abc123" ;;
      *) echo "sha256:feedface" ;;
    esac ;;
  push) echo "pushed" ;;
  *) : ;;
esac
exit 0
"##;

struct D {
    fx: Fx,
    shim: PathBuf,
    log: PathBuf,
}

impl D {
    fn new(flow: &str) -> D {
        let fx = Fx::new(&[(".gitch/flow.yml", flow)]);
        fx.commit("init");
        let shim = fx.dir.join("bin").join("docker");
        std::fs::create_dir_all(shim.parent().unwrap()).unwrap();
        std::fs::write(&shim, FAKE_DOCKER).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
        let log = fx.dir.join("docker.log");
        fx.trust();
        D { fx, shim, log }
    }
    fn run(&self, args: &[&str], env: &[(&str, &str)]) -> (i32, Value) {
        let mut c = self.fx.cmd("script", args);
        c.env("GITCH_DOCKER", &self.shim)
            .env("FAKE_DOCKER_LOG", &self.log);
        for (k, v) in env {
            c.env(k, v);
        }
        let o = c.output().unwrap();
        let out = String::from_utf8_lossy(&o.stdout).to_string();
        (
            o.status.code().unwrap_or(-1),
            serde_json::from_str(&out)
                .unwrap_or_else(|_| panic!("{out}\n{}", String::from_utf8_lossy(&o.stderr))),
        )
    }
    fn calls(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

fn node<'a>(run: &'a Value, id: &str) -> &'a Value {
    run["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("no node {id} in {run}"))
}

fn real(p: &Path) -> String {
    p.canonicalize().unwrap().to_string_lossy().to_string()
}

const EXEC_FLOW: &str = r#"version: 1
project: { name: demo }
environments:
  sandbox: { class: sandbox, executor: "docker:node:22-bookworm" }
flows:
  inside:
    nodes:
      unit:
        run: "echo in-container > ../marker.txt; echo foo=$FOO"
        executor: "docker:alpine:3.20"
        env: { FOO: bar }
        expect: { output: "foo=bar" }
  sandboxed:
    env: sandbox
    nodes:
      build: { run: "echo build" }
      port: { use: check.port, with: { port: 1 }, optional: true }
"#;

#[test]
fn a_docker_executor_runs_the_script_in_a_labelled_container() {
    let d = D::new(EXEC_FLOW);
    let (code, run) = d.run(&["run", "inside", "--json"], &[]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "unit")["state"], "PASSED", "{run}");
    assert_eq!(
        std::fs::read_to_string(d.fx.dir.join("marker.txt")).unwrap(),
        "in-container\n"
    );
    let id = run["runId"].as_str().unwrap();
    let calls = d.calls();
    let line = calls
        .lines()
        .find(|l| l.starts_with("run --rm -i"))
        .expect("docker run");
    assert!(
        line.contains(&format!(
            "--name gitch-flow-{}-unit-1",
            id.to_ascii_lowercase()
        )),
        "{line}"
    );
    assert!(line.contains(&format!("--label gitch.flow.run={id}")));
    assert!(line.contains("--label gitch.flow.node=unit"));
    let root = real(&d.fx.repo());
    assert!(
        line.contains(&format!("-v {root}:{root}"))
            || line.contains(&format!("-v {}:", d.fx.repo().display())),
        "{line}"
    );
    assert!(line.contains(" -e FOO "), "{line}");
    assert!(line.contains(" -e GITCH_FLOW_SCRIPT "));
    assert!(
        !line.contains(" -e PATH "),
        "host PATH must not enter the container: {line}"
    );
    assert!(
        !line.contains("echo in-container"),
        "the script must not be on the command line"
    );
    assert!(line.contains(" alpine:3.20 sh -c "));
    assert!(calls.contains("IMAGE alpine:3.20"));
}

#[test]
fn an_environment_executor_applies_to_shell_blocks_only() {
    let d = D::new(EXEC_FLOW);
    let (code, plan) = d.run(&["plan", "sandboxed", "--json"], &[]);
    assert_eq!(code, 0, "{plan}");
    assert_eq!(node(&plan, "build")["executor"], "docker:node:22-bookworm");
    assert_eq!(node(&plan, "port")["executor"], "local");
}

#[test]
fn docker_down_rejects_only_the_container_nodes() {
    let d = D::new(&format!(
        "{EXEC_FLOW}  mixed:\n    nodes:\n      inside: {{ run: \"echo hi\", executor: \"docker:alpine:3.20\" }}\n      host: {{ run: \"echo host\" }}\n"
    ));
    let (code, run) = d.run(&["run", "mixed", "--json"], &[("FAKE_DOCKER_DOWN", "1")]);
    assert_eq!(code, 1, "{run}");
    let n = node(&run, "inside");
    assert_eq!(n["state"], "REJECTED", "{n}");
    assert_eq!(n["code"], "DOCKER-01");
    assert_eq!(node(&run, "host")["state"], "PASSED");
}

#[test]
fn a_bad_executor_is_a_spec_error() {
    let fx = Fx::new(&[(
        ".gitch/flow.yml",
        "version: 1\nflows:\n  x:\n    nodes:\n      a: { run: \"echo\", executor: \"ssh:box\" }\n",
    )]);
    let (code, v) = fx.json("script", &["validate", "--json"]);
    assert_ne!(code, 0);
    assert!(v.to_string().contains("SPEC-03"), "{v}");
}

const BLOCK_FLOW: &str = r#"version: 1
project: { name: Demo Shop }
flows:
  image:
    nodes:
      build:
        use: docker.build
        secrets: { NPM_TOKEN: npm-token }
        with: { args: { NPM_TOKEN: null, MODE: release } }
      push: { needs: [build], use: docker.push, with: { image: "${{ nodes.build.outputs.image }}" } }
  migrate:
    nodes:
      run:
        use: docker.run
        with: { image: "flyway/flyway:10", command: ["echo", "migrated"], env: { DB_PASSWORD: "pw-Very-Secret-1" } }
        expect: { output: "migrated" }
"#;

#[test]
fn docker_build_tags_the_commit_and_passes_build_args_by_name() {
    let d = D::new(BLOCK_FLOW);
    let sha = d.fx.git(&["rev-parse", "HEAD"]).trim().to_string();
    let (code, run) = d.run(
        &["run", "image", "--json"],
        &[("GITCH_SECRET_NPM_TOKEN", "npm-Tok3n-value-xyz")],
    );
    assert_eq!(code, 0, "{run}");
    let calls = d.calls();
    let build = calls
        .lines()
        .find(|l| l.starts_with("build "))
        .expect("docker build");
    assert!(
        build.contains(&format!("--label org.opencontainers.image.revision={sha}")),
        "{build}"
    );
    assert!(
        build.contains(&format!("-t demo-shop:{}", &sha[..12])),
        "{build}"
    );
    assert!(
        build.contains("--build-arg NPM_TOKEN --build-arg MODE"),
        "{build}"
    );
    assert!(
        !calls.contains("npm-Tok3n-value-xyz"),
        "secret on the command line"
    );
    // 비밀값은 docker CLI 의 환경으로만 간다.
    let env = std::fs::read_to_string(d.log.with_extension("log.env")).unwrap();
    assert!(env.contains("BUILDARG_TOKEN=npm-Tok3n-value-xyz"), "{env}");
    // 앞 노드의 출력(이미지 태그)이 다음 노드로 이어진다.
    assert!(
        calls.contains(&format!("push demo-shop:{}", &sha[..12])),
        "{calls}"
    );
    let push = node(&run, "push");
    assert_eq!(push["state"], "PASSED", "{push}");
}

#[test]
fn docker_run_passes_env_by_name_and_checks_output() {
    let d = D::new(BLOCK_FLOW);
    let (code, run) = d.run(&["run", "migrate", "--json"], &[]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "run")["state"], "PASSED");
    let calls = d.calls();
    assert!(calls.contains(" -e DB_PASSWORD "), "{calls}");
    assert!(!calls.contains("pw-Very-Secret-1"));
    assert!(calls.contains("IMAGE flyway/flyway:10"));
    // docker 자체의 실패(125)는 명령 실패와 구분한다.
    let (code, bad) = d.run(
        &["run", "migrate", "--json"],
        &[("FAKE_DOCKER_RUN_125", "1")],
    );
    assert_eq!(code, 1);
    assert_eq!(node(&bad, "run")["code"], "DOCKER-03", "{bad}");
}
