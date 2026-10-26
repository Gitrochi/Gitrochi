//! 흐름 시험: 영향 선택 · 결과 캐시 · 프로세스 서비스 + HTTP 스모크 · 가짜 docker CLI 로 본 Docker 서비스.
//! Docker 데몬 없이도 엔진이 docker 에 무엇을 시키는지(라벨 · 네트워크 · 정리 · 마스킹)를 확인한다.

mod common;

use common::Fx;
use serde_json::Value;

fn node<'a>(run: &'a Value, id: &str) -> &'a Value {
    run["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("no node {id} in {run}"))
}

// ---------- 영향 선택 ----------

/// 고른 파일마다 테스트 하나를 JUnit 으로 남긴다(고른 것이 없으면 전부 = 두 개).
const SELECTED_RUNNER: &str = r#"#!/bin/sh
out="$GITCH_FLOW_OUT/junit.xml"
printf '%s\n' "${GITCH_FLOW_SELECTED:-ALL}" > "$GITCH_FLOW_OUT/selected.txt"
{
  printf '<testsuite name="s">'
  if [ -n "$GITCH_FLOW_SELECTED" ]; then
    printf '%s\n' "$GITCH_FLOW_SELECTED" | while read -r f; do printf '<testcase classname="sel" name="%s"/>' "$f"; done
  else
    printf '<testcase classname="all" name="math"/><testcase classname="all" name="text"/>'
  fi
  printf '</testsuite>'
} > "$out"
"#;

const AFFECTED_FLOW: &str = r#"version: 1
suites:
  unit:
    use: test.vitest
    with: { run: "sh tools/sel.sh", report: "${{ node.out }}/junit.xml" }
    select: { affected: true }
  smoke:
    use: test.junit
    with: { run: "sh tools/sel.sh", report: "${{ node.out }}/junit.xml" }
    select: { affected: true }
    tags: [smoke]
flows:
  ci:
    nodes:
      unit: { suite: unit }
"#;

fn affected_fixture() -> Fx {
    let fx = Fx::new(&[
        (".gitch/flow.yml", AFFECTED_FLOW),
        ("tools/sel.sh", SELECTED_RUNNER),
        ("src/math.ts", "export const add = (a, b) => a + b\n"),
        ("src/math.test.ts", "test('add', () => {})\n"),
        ("src/text.ts", "export const up = (s) => s.toUpperCase()\n"),
        ("src/text.test.ts", "test('up', () => {})\n"),
        ("package.json", "{\"name\":\"demo\"}\n"),
    ]);
    fx.commit("init");
    fx
}

fn plan_node(fx: &Fx, extra: &[&str]) -> Value {
    let mut args = vec!["plan", "ci", "--json"];
    args.extend_from_slice(extra);
    let (code, plan) = fx.json("script", &args);
    assert_eq!(code, 0, "{plan}");
    node(&plan, "unit").clone()
}

#[test]
fn affected_picks_tests_by_name_and_widens_on_config_changes() {
    let fx = affected_fixture();
    fx.trust();
    // 바뀐 것이 없으면 건너뛰고 이유를 남긴다.
    let n = plan_node(&fx, &["--affected=worktree"]);
    assert_eq!(n["decision"], "skip", "{n}");
    // 소스 하나를 고치면 이름이 같은 테스트만.
    fx.write("src/math.ts", "export const add = (a, b) => b + a\n");
    let n = plan_node(&fx, &["--affected=worktree"]);
    assert_eq!(n["decision"], "run", "{n}");
    assert_eq!(
        n["selection"],
        serde_json::json!(["src/math.test.ts"]),
        "{n}"
    );
    assert!(n["selectionReason"].as_str().unwrap().contains('1'), "{n}");
    // 실제로 돌리면 실행기는 고른 파일만 받는다.
    let (code, run) = fx.json("script", &["run", "ci", "--affected=worktree", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "unit")["tests"]["executed"], 1);
    // 의존 · 설정 파일이 바뀌면 전부(고르지 않음) + 이유.
    fx.write("package.json", "{\"name\":\"demo\",\"version\":\"2\"}\n");
    let n = plan_node(&fx, &["--affected=worktree"]);
    assert_eq!(n["decision"], "run");
    assert!(n["selection"].is_null(), "{n}");
    assert!(n["selectionReason"]
        .as_str()
        .unwrap()
        .contains("package.json"));
    // 새 테스트 파일(추적 전)도 바뀐 것으로 본다.
    fx.git(&["checkout", "-q", "--", "package.json", "src/math.ts"]);
    fx.write("src/extra.test.ts", "test('x', () => {})\n");
    let n = plan_node(&fx, &["--affected=worktree"]);
    assert_eq!(
        n["selection"],
        serde_json::json!(["src/extra.test.ts"]),
        "{n}"
    );
}

#[test]
fn affected_against_the_base_branch_and_smoke_always_runs() {
    let fx = affected_fixture();
    fx.write(
        ".gitch/flow.yml",
        &format!("{AFFECTED_FLOW}  smoke-only:\n    nodes:\n      smoke: {{ suite: smoke }}\n"),
    );
    fx.commit("smoke flow");
    fx.trust();
    fx.git(&["checkout", "-q", "-b", "feature"]);
    fx.write("src/text.ts", "export const up = (s) => s.toLowerCase()\n");
    fx.commit("change text");
    // 기본 브랜치(main)와 갈라진 곳부터: 커밋한 변경도 본다.
    let n = plan_node(&fx, &["--affected=base"]);
    assert_eq!(
        n["selection"],
        serde_json::json!(["src/text.test.ts"]),
        "{n}"
    );
    // 스모크 태그는 범위에 바뀐 파일이 없어도 돈다.
    fx.git(&["checkout", "-q", "main"]);
    let (code, plan) = fx.json(
        "script",
        &["plan", "smoke-only", "--affected=worktree", "--json"],
    );
    assert_eq!(code, 0);
    assert_eq!(node(&plan, "smoke")["decision"], "run", "{plan}");
}

// ---------- 결과 캐시 ----------

const CACHE_FLOW: &str = r#"version: 1
flows:
  build:
    nodes:
      gen: { run: "echo built >> ../count.txt", cache: { inputs: ["src/**"] } }
      net: { use: check.port, with: { port: 1 }, cache: true, optional: true }
"#;

#[test]
fn cache_replays_passes_and_misses_when_inputs_change() {
    let fx = Fx::new(&[(".gitch/flow.yml", CACHE_FLOW), ("src/a.txt", "one\n")]);
    fx.trust();
    let count = || {
        std::fs::read_to_string(fx.dir.join("count.txt"))
            .unwrap_or_default()
            .lines()
            .count()
    };
    let (code, first) = fx.json("script", &["run", "build", "--json"]);
    assert_eq!(code, 0, "{first}");
    assert_eq!(node(&first, "gen")["state"], "PASSED");
    assert!(node(&first, "gen")["cacheKey"].is_string());
    // 네트워크 블록은 cache 를 적어도 캐시하지 않는다.
    assert!(node(&first, "net")["cacheKey"].is_null(), "{first}");
    assert_eq!(count(), 1);
    let (_, second) = fx.json("script", &["run", "build", "--json"]);
    assert_eq!(node(&second, "gen")["state"], "CACHED", "{second}");
    assert_eq!(second["counts"]["cached"], 1);
    assert_eq!(count(), 1, "a cached node must not run again");
    // 입력 파일이 바뀌면 다시 돈다.
    fx.write("src/a.txt", "two\n");
    let (_, third) = fx.json("script", &["run", "build", "--json"]);
    assert_eq!(node(&third, "gen")["state"], "PASSED", "{third}");
    assert_eq!(count(), 2);
    // --no-cache 는 언제나 돈다.
    let (_, fourth) = fx.json("script", &["run", "build", "--no-cache", "--json"]);
    assert_eq!(node(&fourth, "gen")["state"], "PASSED");
    assert_eq!(count(), 3);
}

// ---------- 프로세스 서비스 + HTTP 스모크 ----------

const SERVICE_FLOW: &str = r#"version: 1
services:
  web:
    use: process.service
    with:
      run: "exec python3 -m http.server $PORT --bind 127.0.0.1 --directory site"
      ready: { http: "${{ services.web.url }}/", timeout: 20s }
  dead:
    use: process.service
    with:
      run: "echo starting; sleep 30"
      ready: { port: 1, timeout: 2s }
flows:
  smoke:
    nodes:
      page:
        use: check.http
        services: [web]
        with:
          url: "${{ services.web.url }}/hello.txt"
          expect: { status: 200, contains: "hello flow" }
      missing:
        needs: [page]
        use: check.http
        services: [web]
        with: { url: "${{ services.web.url }}/nope.txt", expect: { status: 200 } }
  broken:
    nodes:
      page: { use: check.http, services: [dead], with: { url: "http://127.0.0.1:1/" } }
      alone: { run: "echo independent" }
"#;

#[test]
fn process_service_backs_http_smoke_checks_and_is_cleaned_up() {
    let fx = Fx::new(&[
        (".gitch/flow.yml", SERVICE_FLOW),
        ("site/hello.txt", "hello flow\n"),
    ]);
    fx.trust();
    let (code, run) = fx.json("script", &["run", "smoke", "--json"]);
    assert_eq!(code, 1, "{run}");
    assert_eq!(node(&run, "page")["state"], "PASSED", "{run}");
    let missing = node(&run, "missing");
    assert_eq!(missing["state"], "FAILED");
    assert_eq!(missing["code"], "VERIFY-01", "{missing}");
    // 서비스 주소는 실행 기록에 남고, 끝나면 그 포트는 닫혀 있어야 한다.
    let id = run["runId"].as_str().unwrap();
    let (_, evs, _) = fx.run("script", &["events", id]);
    let ready: Value = evs
        .lines()
        .map(|l| serde_json::from_str::<Value>(l).unwrap())
        .find(|e| e["type"] == "service.state" && e["data"]["state"] == "READY")
        .expect("service READY event");
    let port = ready["data"]["info"]["port"].as_u64().unwrap() as u16;
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert!(
        std::net::TcpStream::connect(("127.0.0.1", port)).is_err(),
        "service on port {port} survived the run"
    );
}

#[test]
fn a_service_that_never_gets_ready_rejects_only_its_nodes() {
    let fx = Fx::new(&[(".gitch/flow.yml", SERVICE_FLOW)]);
    fx.trust();
    let (code, run) = fx.json("script", &["run", "broken", "--json"]);
    assert_eq!(code, 1, "{run}");
    let page = node(&run, "page");
    assert_eq!(page["state"], "REJECTED", "{page}");
    assert_eq!(page["code"], "SERVICE-01");
    assert!(
        page["failure"]["detail"]
            .as_str()
            .unwrap_or("")
            .contains("starting"),
        "{page}"
    );
    assert_eq!(node(&run, "alone")["state"], "PASSED");
}

// ---------- Docker (가짜 CLI) ----------

const FAKE_DOCKER: &str = r#"#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  version)
    if [ -n "$FAKE_DOCKER_DOWN" ]; then
      echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
      exit 1
    fi
    echo "27.3.1" ;;
  network)
    case "$2" in inspect) exit 1 ;; create) echo net1 ;; *) : ;; esac ;;
  run) echo c0ffee ;;
  inspect) echo true ;;
  exec) if [ -n "$FAKE_DOCKER_UNHEALTHY" ]; then exit 1; fi ;;
  logs) echo "init: password pw-Sekr3t-value accepted" ;;
  *) : ;;
esac
exit 0
"#;

const DOCKER_FLOW: &str = r#"version: 1
services:
  db:
    use: docker.service
    with:
      image: "postgres:16-alpine"
      ports: ["5432"]
      env: { POSTGRES_PASSWORD: "pw-Sekr3t-value" }
      health: { cmd: "pg_isready -U postgres", timeout: 2s }
flows:
  it:
    nodes:
      migrate: { run: "echo db at ${{ services.db.port }}", services: [db] }
      alone: { run: "echo independent" }
"#;

fn docker_fixture() -> (Fx, std::path::PathBuf, std::path::PathBuf) {
    let fx = Fx::new(&[(".gitch/flow.yml", DOCKER_FLOW)]);
    let shim = fx.dir.join("bin").join("docker");
    std::fs::create_dir_all(shim.parent().unwrap()).unwrap();
    std::fs::write(&shim, FAKE_DOCKER).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let log = fx.dir.join("docker.log");
    fx.trust();
    (fx, shim, log)
}

fn run_docker(
    fx: &Fx,
    shim: &std::path::Path,
    log: &std::path::Path,
    env: &[(&str, &str)],
) -> (i32, Value) {
    let mut c = fx.cmd("script", &["run", "it", "--json"]);
    c.env("GITCH_DOCKER", shim).env("FAKE_DOCKER_LOG", log);
    for (k, v) in env {
        c.env(k, v);
    }
    let o = c.output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    (
        o.status.code().unwrap_or(-1),
        serde_json::from_str(&out)
            .unwrap_or_else(|_| panic!("{out}\n{}", String::from_utf8_lossy(&o.stderr))),
    )
}

#[test]
fn docker_service_is_labelled_networked_and_removed() {
    let (fx, shim, log) = docker_fixture();
    let (code, run) = run_docker(&fx, &shim, &log, &[]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "migrate")["state"], "PASSED");
    let id = run["runId"].as_str().unwrap();
    let calls = std::fs::read_to_string(&log).unwrap();
    let run_line = calls
        .lines()
        .find(|l| l.starts_with("run -d"))
        .expect("docker run");
    assert!(
        run_line.contains(&format!("--label gitch.flow.run={id}")),
        "{run_line}"
    );
    assert!(run_line.contains("--label gitch.flow.service=db"));
    assert!(run_line.contains(&format!("--network gitch-flow-{id}")));
    assert!(run_line.contains("--network-alias db"));
    assert!(run_line.contains("--pull=missing"));
    assert!(run_line.contains("-p 127.0.0.1:"));
    assert!(run_line.contains(":5432 "));
    assert!(run_line.ends_with("postgres:16-alpine"));
    assert!(calls.contains(&format!("network create --label gitch.flow.run={id}")));
    assert!(calls.contains("exec gitch-flow-"), "{calls}");
    // 실행이 끝나면 컨테이너와 네트워크를 지운다.
    assert!(
        calls.contains(&format!("rm -f -v gitch-flow-{id}-db")),
        "{calls}"
    );
    assert!(
        calls.contains(&format!("network rm gitch-flow-{id}")),
        "{calls}"
    );
}

#[test]
fn docker_down_rejects_its_nodes_with_docker01() {
    let (fx, shim, log) = docker_fixture();
    let (code, run) = run_docker(&fx, &shim, &log, &[("FAKE_DOCKER_DOWN", "1")]);
    assert_eq!(code, 1, "{run}");
    let m = node(&run, "migrate");
    assert_eq!(m["state"], "REJECTED");
    assert_eq!(m["code"], "DOCKER-01");
    assert_eq!(node(&run, "alone")["state"], "PASSED");
}

#[test]
fn unhealthy_container_logs_are_saved_masked() {
    let (fx, shim, log) = docker_fixture();
    let (code, run) = run_docker(&fx, &shim, &log, &[("FAKE_DOCKER_UNHEALTHY", "1")]);
    assert_eq!(code, 1, "{run}");
    let m = node(&run, "migrate");
    assert_eq!(m["state"], "REJECTED", "{m}");
    assert_eq!(m["code"], "SERVICE-01");
    let svc_log = std::path::Path::new(run["runDir"].as_str().unwrap()).join("logs/service-db.log");
    let text = std::fs::read_to_string(&svc_log).unwrap();
    assert!(text.contains("accepted"), "{text}");
    assert!(
        !text.contains("pw-Sekr3t-value"),
        "password leaked into {svc_log:?}"
    );
    let calls = std::fs::read_to_string(&log).unwrap();
    assert!(calls.lines().any(|l| l.starts_with("rm -f -v gitch-flow-")));
}

// ---------- 조합(matrix) ----------

const MATRIX_FLOW: &str = r#"version: 1
flows:
  versions:
    nodes:
      unit:
        run: "echo v=${{ matrix.v }} os=${{ matrix.os }} >> ../matrix.txt"
        matrix: { v: [1, 2], os: [a, b] }
      after: { needs: [unit], run: "echo done >> ../matrix.txt" }
  boxed:
    nodes:
      t: { run: "echo hi", executor: "docker:node:${{ matrix.node }}", matrix: { node: [20, 22] } }
"#;

#[test]
fn a_matrix_node_runs_once_per_combination() {
    let fx = Fx::new(&[(".gitch/flow.yml", MATRIX_FLOW)]);
    fx.trust();
    let (code, plan) = fx.json("script", &["plan", "versions", "--json"]);
    assert_eq!(code, 0, "{plan}");
    let ids: Vec<&str> = plan["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["id"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        [
            "unit/v-1-os-a",
            "unit/v-1-os-b",
            "unit/v-2-os-a",
            "unit/v-2-os-b",
            "after"
        ]
    );
    assert_eq!(node(&plan, "after")["needs"].as_array().unwrap().len(), 4);
    assert_eq!(node(&plan, "unit/v-2-os-a")["matrix"]["v"], 2);
    let (code, run) = fx.json("script", &["run", "versions", "--json", "--jobs", "4"]);
    assert_eq!(code, 0, "{run}");
    let text = std::fs::read_to_string(fx.dir.join("matrix.txt")).unwrap();
    let mut lines: Vec<&str> = text.lines().collect();
    assert_eq!(
        lines.pop(),
        Some("done"),
        "the dependant waits for every combination"
    );
    lines.sort();
    assert_eq!(lines, ["v=1 os=a", "v=1 os=b", "v=2 os=a", "v=2 os=b"]);
    let (_, boxed) = fx.json("script", &["plan", "boxed", "--json"]);
    assert_eq!(
        node(&boxed, "t/node-20")["executor"],
        "docker:node:20",
        "{boxed}"
    );
    assert_eq!(node(&boxed, "t/node-22")["executor"], "docker:node:22");
}
