//! 실행 파일을 임시 저장소 · 임시 HOME 에서 돌려 보는 통합 시험. 실제 사용자 설정은 건드리지 않는다.
//! 실행 주체는 시험마다 정한다(사람 · 스크립트 · AI) — gitch 시험 도구(t_setup)와 같은 방식.

mod common;

use common::Fx;
use serde_json::Value;
use std::path::Path;

const RUNNER: &str = r#"#!/bin/sh
mode=${1:-pass}
out="$GITCH_FLOW_OUT/junit.xml"
case "$mode" in
  pass) printf '<testsuite name="s"><testcase classname="m" name="a" time="0.01"/><testcase classname="m" name="b" time="0.02"/></testsuite>' > "$out"; echo "2 passed"; exit 0 ;;
  fail) printf '<testsuite name="s"><testcase classname="m" name="a"/><testcase classname="m" name="b"><failure message="expected 1 to be 2">at src/m.test.ts:14:5</failure></testcase></testsuite>' > "$out"; echo "1 failed"; exit 1 ;;
  zero) printf '<testsuite name="s"></testsuite>' > "$out"; echo "no tests"; exit 0 ;;
  lie) printf '<testsuite name="s"><testcase classname="m" name="a"><failure message="boom"/></testcase></testsuite>' > "$out"; echo "says ok"; exit 0 ;;
  stale) echo "no report this time"; exit 0 ;;
  flaky) if [ -f "$GITCH_FLOW_OUT/.seen" ]; then printf '<testsuite><testcase classname="m" name="f"/></testsuite>' > "$out"; exit 0; else touch "$GITCH_FLOW_OUT/.seen"; printf '<testsuite><testcase classname="m" name="f"><failure message="flake"/></testcase></testsuite>' > "$out"; exit 1; fi ;;
esac
"#;

const FLOW: &str = r#"version: 1
project: { name: demo }
suites:
  unit: { use: test.junit, with: { run: "sh tests/r.sh pass", report: "${{ node.out }}/junit.xml" } }
  broken: { use: test.junit, with: { run: "sh tests/r.sh fail", report: "${{ node.out }}/junit.xml" } }
  empty: { use: test.junit, with: { run: "sh tests/r.sh zero", report: "${{ node.out }}/junit.xml" } }
  liar: { use: test.junit, with: { run: "sh tests/r.sh lie", report: "${{ node.out }}/junit.xml" } }
  stale: { use: test.junit, with: { run: "sh tests/r.sh stale", report: "old/junit.xml" } }
  flaky: { use: test.junit, with: { run: "sh tests/r.sh flaky", report: "${{ node.out }}/junit.xml" }, retry: { max: 1, flaky: warn } }
  flaky-strict: { use: test.junit, with: { run: "sh tests/r.sh flaky", report: "${{ node.out }}/junit.xml" }, retry: { max: 1 } }
flows:
  ok:
    nodes:
      lint: echo lint-ok
      unit: { needs: [lint], suite: unit }
  bad:
    failFast: true
    nodes:
      lint: echo lint
      broken: { needs: [lint], suite: broken, on-failure: { dump: { run: "echo dumping" } } }
      later: { needs: [broken], run: "echo should-skip" }
  traps:
    nodes:
      empty: { suite: empty }
      liar: { suite: liar }
      stale: { suite: stale }
  flake:
    nodes:
      lenient: { suite: flaky }
      strict: { suite: flaky-strict }
  slow:
    nodes:
      sleepy: { run: "(sleep 30; touch survived.txt) & sleep 60" }
  quote:
    nodes:
      show: { run: "printf '%s\n' ${{ project.name }} > quoted.txt", env: { WHO: "${{ git.branch }}" } }
"#;

fn fixture() -> Fx {
    let fx = Fx::new(&[
        (".gitch/flow.yml", FLOW),
        ("tests/r.sh", RUNNER),
        (
            "old/junit.xml",
            "<testsuite><testcase classname='x' name='old'/></testsuite>",
        ),
    ]);
    // 오래된 보고서를 "예전 것"으로 만든다(이번 실행 시작 전).
    let old = fx.repo().join("old/junit.xml");
    let past = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    let f = std::fs::File::options().write(true).open(&old).unwrap();
    f.set_modified(past).unwrap();
    fx
}

fn node<'a>(run: &'a Value, id: &str) -> &'a Value {
    run["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("no node {id} in {run}"))
}

#[test]
fn untrusted_flows_need_a_person() {
    let fx = fixture();
    let (code, v) = fx.json("claude", &["run", "ok", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(v["error"]["code"], "GITCH_CONFIRMATION_REQUIRED");
    assert_eq!(v["error"]["flowCode"], "TRUST-01");
    // AI 는 신뢰를 승인할 수 없다.
    let (code, v) = fx.json("claude", &["trust", "--yes", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(v["error"]["flowCode"], "TRUST-02");
    // 비대화형 스크립트도 --yes 없이는 안 된다.
    let (code, _) = fx.json("script", &["run", "ok", "--json"]);
    assert_eq!(code, 2);
}

#[test]
fn a_passing_flow_is_signed_and_replayable() {
    let fx = fixture();
    fx.trust();
    let (code, run) = fx.json("script", &["run", "ok", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(run["state"], "SUCCEEDED");
    assert_eq!(node(&run, "unit")["state"], "PASSED");
    assert_eq!(node(&run, "unit")["tests"]["executed"], 2);
    assert!(run["signature"].is_string());
    // 서명된 기록은 status 에서 signed=true.
    let (_, st) = fx.json("script", &["status", "last", "--json"]);
    assert_eq!(st["signed"], true);
    // 이벤트: seq 가 1부터 빠짐없이 늘고 run.done 으로 끝난다.
    let id = run["runId"].as_str().unwrap();
    let (_, evs, _) = fx.run("script", &["events", id]);
    let lines: Vec<Value> = evs
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    for (i, e) in lines.iter().enumerate() {
        assert_eq!(e["seq"].as_u64().unwrap(), i as u64 + 1);
    }
    assert_eq!(lines.last().unwrap()["type"], "run.done");
    let (_, later, _) = fx.run("script", &["events", id, "--since", "3"]);
    assert_eq!(later.lines().count(), lines.len() - 3);
    // 기록을 고치면 서명이 맞지 않는다.
    let path = Path::new(run["runDir"].as_str().unwrap()).join("run.json");
    let text = std::fs::read_to_string(&path)
        .unwrap()
        .replace("\"SUCCEEDED\"", "\"SUCCEEDED\" ");
    let mut forged: Value = serde_json::from_str(&text).unwrap();
    forged["nodes"][1]["state"] = "PASSED".into();
    forged["git"]["sha"] = "deadbeef".into();
    std::fs::write(&path, forged.to_string()).unwrap();
    let (_, st2) = fx.json("script", &["status", id, "--json"]);
    assert_eq!(st2["signed"], false);
}

#[test]
fn failures_branch_and_fail_fast() {
    let fx = fixture();
    fx.trust();
    let (code, run) = fx.json("script", &["run", "bad", "--json"]);
    assert_eq!(code, 1);
    assert_eq!(run["state"], "FAILED");
    let broken = node(&run, "broken");
    assert_eq!(broken["state"], "FAILED");
    assert_eq!(broken["code"], "TEST-01");
    assert_eq!(broken["failures"][0]["file"], "src/m.test.ts");
    assert_eq!(broken["failures"][0]["line"], 14);
    assert_eq!(node(&run, "broken/on-failure/dump")["state"], "PASSED");
    assert_eq!(node(&run, "later")["state"], "SKIPPED");
    // AI 용 짧은 요약은 결정적이다.
    let (_, s1, _) = fx.run("script", &["report", "last"]);
    assert!(s1.contains("src/m.test.ts:14"));
}

#[test]
fn traps_are_not_passes() {
    let fx = fixture();
    fx.trust();
    let (code, run) = fx.json("script", &["run", "traps", "--json"]);
    assert_eq!(code, 1);
    let empty = node(&run, "empty");
    assert_eq!(empty["state"], "FAILED");
    assert_eq!(empty["code"], "TEST-03");
    let liar = node(&run, "liar");
    assert_ne!(liar["state"], "PASSED");
    assert!(liar["verdicts"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["rule"] == "X1" && v["result"] == "INDETERMINATE"));
    // 시작 전에 있던 보고서는 읽지 않는다 → 보고서 없음(판정 불가).
    let stale = node(&run, "stale");
    assert_eq!(stale["state"], "INDETERMINATE");
    assert_eq!(stale["code"], "TEST-02");
}

#[test]
fn flaky_policy() {
    let fx = fixture();
    fx.trust();
    let (_, run) = fx.json("script", &["run", "flake", "--json"]);
    let lenient = node(&run, "lenient");
    assert_eq!(lenient["state"], "PASSED", "{lenient}");
    assert_eq!(lenient["tests"]["flaky"], 1);
    assert_eq!(lenient["attempts"], 2);
    let strict = node(&run, "strict");
    assert_eq!(strict["state"], "FAILED");
    assert_eq!(strict["code"], "TEST-05");
}

#[test]
fn changing_the_flow_file_revokes_trust() {
    let fx = fixture();
    fx.trust();
    let (code, _) = fx.json("script", &["plan", "ok", "--json"]);
    assert_eq!(code, 0);
    fx.write(
        ".gitch/flow.yml",
        &FLOW.replace("echo lint-ok", "echo changed"),
    );
    let (code, v) = fx.json("script", &["run", "ok", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(v["error"]["flowCode"], "TRUST-01");
    let (_, plan) = fx.json("script", &["plan", "ok", "--json"]);
    assert_eq!(plan["trust"]["trusted"], false);
    assert_eq!(plan["trust"]["changed"][0], ".gitch/flow.yml");
}

#[test]
fn idempotency_key_replays_the_same_run() {
    let fx = fixture();
    fx.trust();
    let (_, a) = fx.json(
        "script",
        &["run", "ok", "--json", "--idempotency-key", "k1"],
    );
    let (_, b) = fx.json(
        "script",
        &["run", "ok", "--json", "--idempotency-key", "k1"],
    );
    assert_eq!(a["runId"], b["runId"]);
    let (_, c) = fx.json(
        "script",
        &["run", "ok", "--json", "--idempotency-key", "k2"],
    );
    assert_ne!(a["runId"], c["runId"]);
}

#[test]
fn cancel_stops_the_whole_process_tree() {
    let fx = fixture();
    fx.trust();
    let (code, d) = fx.json("script", &["run", "slow", "--detach", "--json"]);
    assert_eq!(code, 0, "{d}");
    let id = d["runId"].as_str().unwrap().to_string();
    std::thread::sleep(std::time::Duration::from_millis(1500));
    let (code, _) = fx.json("script", &["cancel", &id, "--json"]);
    assert_eq!(code, 0);
    let mut state = Value::Null;
    for _ in 0..60 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        let (_, st) = fx.json("script", &["status", &id, "--json"]);
        if st["state"] != "RUNNING" && !st["state"].is_null() {
            state = st;
            break;
        }
    }
    assert_eq!(state["state"], "CANCELLED", "{state}");
    // 손자 프로세스(sleep 30 뒤 touch)는 묶음째 끝나야 한다.
    std::thread::sleep(std::time::Duration::from_millis(500));
    assert!(!fx.repo().join("survived.txt").exists());
}

#[test]
fn expressions_in_run_are_shell_quoted() {
    let fx = fixture();
    fx.write(
        ".gitch/flow.yml",
        &FLOW.replace(
            "project: { name: demo }",
            "project: { name: \"a b; touch pwned\" }",
        ),
    );
    fx.trust();
    let (code, run) = fx.json("script", &["run", "quote", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(
        std::fs::read_to_string(fx.repo().join("quoted.txt")).unwrap(),
        "a b; touch pwned\n"
    );
    assert!(!fx.repo().join("pwned").exists());
}

#[test]
fn adhoc_test_command_and_only() {
    let fx = fixture();
    fx.trust();
    let (code, run) = fx.json("script", &["test", "unit", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(run["flow"], "test");
    let (_, only) = fx.json("script", &["plan", "bad", "--only", "lint", "--json"]);
    let decisions: Vec<(String, String)> = only["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| {
            (
                n["id"].as_str().unwrap().to_string(),
                n["decision"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert!(decisions.contains(&("lint".into(), "run".into())));
    assert!(decisions.contains(&("broken".into(), "skip".into())));
}

#[test]
fn init_detects_and_never_overwrites() {
    let fx = Fx::new(&[
        (
            "package.json",
            "{\n  \"name\": \"x\",\n  \"devDependencies\": { \"vitest\": \"^2\" }\n}\n",
        ),
        ("package-lock.json", "{}"),
    ]);
    let (code, v) = fx.json("script", &["init", "--dry-run", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(v["written"], false);
    assert!(v["findings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f["kind"] == "vitest"));
    let (code, v) = fx.json("script", &["init", "--yes", "--json"]);
    assert_eq!(code, 0, "{v}");
    assert_eq!(v["written"], true);
    let (code, _) = fx.json("script", &["validate", "--json"]);
    assert_eq!(code, 0);
    let (code, _) = fx.json("script", &["init", "--yes", "--json"]);
    assert_eq!(code, 1);
}

#[test]
fn ci_mode_writes_the_result_contract() {
    let fx = fixture();
    let mut c = fx.cmd("script", &["run", "ok", "--ci"]);
    c.env("CI", "true");
    let o = c.output().unwrap();
    assert_eq!(
        o.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    let out = String::from_utf8_lossy(&o.stdout);
    let marker = out
        .lines()
        .find(|l| l.starts_with("GITCH-FLOW-RESULT "))
        .expect("marker line");
    let m: Value = serde_json::from_str(marker.trim_start_matches("GITCH-FLOW-RESULT ")).unwrap();
    assert_eq!(m["state"], "SUCCEEDED");
    assert!(fx
        .repo()
        .join("gitch-flow-out/gitch-flow-result.json")
        .is_file());
    let junit = std::fs::read_to_string(fx.repo().join("gitch-flow-out/junit.xml")).unwrap();
    assert!(junit.contains("<testsuites"));
    // AI 는 CI 예외로 신뢰를 건너뛸 수 없다.
    let mut c2 = fx.cmd("claude", &["run", "ok", "--ci"]);
    c2.env("CI", "true");
    assert_eq!(c2.output().unwrap().status.code(), Some(2));
}

#[test]
fn export_and_schema_commands() {
    let fx = fixture();
    let (code, v) = fx.json(
        "script",
        &["export", "github", "--flow", "ok", "--dry-run", "--json"],
    );
    assert_eq!(code, 0);
    assert!(v["content"]
        .as_str()
        .unwrap()
        .contains("gitch flow run ok --ci"));
    let (code, out, _) = fx.run("script", &["schema", "flow-run"]);
    assert_eq!(code, 0);
    let s: Value = serde_json::from_str(&out).unwrap();
    assert!(s["title"].as_str().unwrap().contains("run summary"));
    let (code, gate) = fx.json("script", &["gate", "status", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(gate["gate"], "OFF");
}
