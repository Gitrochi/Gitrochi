//! Blocks for assembling test environments: the mock.http service, mock.fault, check.mock, fixture.seed, gate.window and check.log.

mod common;

use common::Fx;
use serde_json::Value;

const FLOW: &str = r#"version: 1
services:
  pay:
    use: mock.http
    with:
      routes:
        - { method: GET, path: /health, body: ok }
        - { method: POST, path: /charge, status: 201, json: { id: ch_1 } }
      faults:
        down: [{ path: "*", status: 503 }]
  files:
    use: mock.http
  api:
    use: process.service
    with:
      run: "echo 'listening on 127.0.0.1:'$PORT; exec python3 -m http.server $PORT --bind 127.0.0.1"
flows:
  mocked:
    nodes:
      charge: { run: "curl -fsS -X POST -d amount=5 ${{ services.pay.url }}/charge", services: [pay] }
      verify:
        needs: [charge]
        use: check.mock
        with: { service: pay, calls: [{ method: POST, path: /charge, count: 1, contains: "amount=5" }, { path: /refund, count: 0 }] }
  too-many:
    nodes:
      twice: { run: "curl -fsS -X POST ${{ services.pay.url }}/charge; curl -fsS -X POST ${{ services.pay.url }}/charge", services: [pay] }
      verify: { needs: [twice], use: check.mock, with: { service: pay, calls: [{ method: POST, path: /charge, count: 1 }] } }
  outage:
    nodes:
      down: { use: mock.fault, services: [pay], with: { service: pay, on: [down] } }
      probe: { needs: [down], use: check.http, with: { url: "${{ services.pay.url }}/health", expect: { status: 503 } } }
      up: { needs: [probe], use: mock.fault, with: { service: pay, off: [down] } }
      again: { needs: [up], use: check.http, with: { url: "${{ services.pay.url }}/health", expect: { status: 200, contains: ok } } }
  from-dir:
    nodes:
      get: { use: check.http, services: [files], with: { url: "${{ services.files.url }}/v1/items", expect: { status: 200, json: { field: items.0.name, equals: widget } } } }
  seeded:
    nodes:
      seed: { use: fixture.seed, with: { run: "echo seed >> ../db.txt", undo: "echo unseed >> ../db.txt" } }
      use: { needs: [seed], run: "grep -q seed ../db.txt" }
  kept:
    nodes:
      seed: { use: fixture.seed, with: { run: "echo seed >> ../db.txt", undo: "echo unseed >> ../db.txt", keep: true } }
  window-closed:
    nodes:
      gate: { use: gate.window, with: { tz: "UTC", deny: [{ from: "00:00", to: "24:00", reason: "frozen" }] } }
      after: { needs: [gate], run: "echo should-not-run > ../ran.txt" }
  window-open:
    nodes:
      gate: { use: gate.window, with: { tz: "+09:00", deny: [{ dates: ["1999-01-01"] }] } }
  logs:
    nodes:
      started: { use: check.log, services: [api], with: { service: api, contains: "listening on", absent: "Traceback", timeout: 10s } }
"#;

const ROUTES: &str = r#"routes:
  - method: GET
    path: /v1/items
    file: items.json
"#;

/// Windows runners have python but no python3.
const PY: &str = if cfg!(windows) { "python" } else { "python3" };

fn fx() -> Fx {
    let fx = Fx::new(&[
        (".gitch/flow.yml", &FLOW.replace("python3", PY)),
        (".gitch/mocks/files/routes.yml", ROUTES),
        (
            ".gitch/mocks/files/items.json",
            "{\"items\": [{\"name\": \"widget\"}]}",
        ),
    ]);
    fx.trust();
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
fn a_mock_service_answers_and_records_calls() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "mocked", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "verify")["state"], "PASSED", "{run}");
    // Received requests stay in the run folder.
    let log = std::path::Path::new(run["runDir"].as_str().unwrap()).join("logs/service-pay.log");
    assert!(std::fs::read_to_string(log)
        .unwrap()
        .contains("\"/charge\""));
    let (code, run) = fx.json("script", &["run", "too-many", "--json"]);
    assert_eq!(code, 1);
    let v = node(&run, "verify");
    assert_eq!(v["state"], "FAILED", "{v}");
    assert_eq!(v["code"], "VERIFY-01");
}

#[test]
fn fault_switches_turn_on_and_off_inside_a_flow() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "outage", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "probe")["state"], "PASSED");
    assert_eq!(node(&run, "again")["state"], "PASSED");
}

#[test]
fn mock_routes_can_live_in_the_repository() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "from-dir", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "get")["state"], "PASSED");
}

#[test]
fn seeds_are_removed_after_the_run_unless_kept() {
    let fx = fx();
    let db = || std::fs::read_to_string(fx.dir.join("db.txt")).unwrap_or_default();
    let (code, run) = fx.json("script", &["run", "seeded", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(db(), "seed\nunseed\n");
    let (code, _) = fx.json("script", &["run", "kept", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(
        db(),
        "seed\nunseed\nseed\n",
        "a kept seed stays after a successful run"
    );
}

#[test]
fn a_closed_window_rejects_the_flow_before_anything_runs() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "window-closed", "--json"]);
    assert_eq!(code, 1, "{run}");
    assert_eq!(run["state"], "REJECTED");
    assert_eq!(node(&run, "gate")["code"], "GATE-01");
    assert!(node(&run, "gate")["failure"]["detail"]
        .as_str()
        .unwrap()
        .contains("frozen"));
    assert!(!fx.dir.join("ran.txt").exists());
    let (code, run) = fx.json("script", &["run", "window-open", "--json"]);
    assert_eq!(code, 0, "{run}");
}

#[test]
fn check_log_waits_for_a_service_line() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "logs", "--json"]);
    assert_eq!(code, 0, "{run}");
    let n = node(&run, "started");
    assert_eq!(n["state"], "PASSED", "{n}");
}
