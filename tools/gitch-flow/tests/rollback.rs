//! Rollback tests: node and flow scope, check failures and onCheckFailure, a failed rollback → environment hold,
//! rollback after a cancel, cleanup steps that always run, shell quoting in undo scripts, closing runs whose engine died.

mod common;

use common::Fx;
use serde_json::Value;

const FLOW: &str = r#"version: 1
project: { name: demo }
flows:
  node-scope:
    nodes:
      api: { run: "echo api >> ../state.txt", undo: "echo undo-api >> ../state.txt" }
      web: { needs: [api], run: "echo web >> ../state.txt; exit 3", undo: "echo undo-web >> ../state.txt" }
  flow-scope:
    rollback: { scope: flow }
    nodes:
      api: { run: "echo api >> ../state.txt", undo: "echo undo-api >> ../state.txt" }
      web: { needs: [api], run: "echo web >> ../state.txt; exit 3", undo: "echo undo-web >> ../state.txt" }
  smoke-kept:
    rollback: { scope: flow }
    nodes:
      deploy: { run: "echo deploy >> ../state.txt", undo: "echo undo-deploy >> ../state.txt" }
      smoke: { needs: [deploy], run: "exit 1" }
  smoke-undone:
    rollback: { scope: flow, onCheckFailure: true }
    nodes:
      deploy: { run: "echo deploy >> ../state.txt", undo: { run: "echo undo-deploy >> ../state.txt", check: "grep -q undo-deploy ../state.txt" } }
      smoke: { needs: [deploy], run: "exit 1" }
  broken-undo:
    nodes:
      migrate: { run: "echo migrate >> ../state.txt; exit 1", undo: "echo cannot-undo >&2; exit 4" }
  other:
    nodes:
      hello: { run: "echo hello" }
  slow:
    nodes:
      api: { run: "echo api >> ../state.txt", undo: "echo undo-api >> ../state.txt" }
      wait: { needs: [api], run: "sleep 30" }
  slow-plain:
    nodes:
      wait: { run: "sleep 30" }
  seeded:
    nodes:
      seed: { run: "echo seed >> ../state.txt", undo: { run: "echo unseed >> ../state.txt", always: true } }
      use: { needs: [seed], run: "echo using >> ../state.txt" }
  quoting:
    nodes:
      fail: { run: "exit 1", undo: "printf '%s\n' ${{ project.name }} > ../undone.txt" }
"#;

fn fx() -> Fx {
    let fx = Fx::new(&[(".gitch/flow.yml", FLOW)]);
    fx.trust();
    fx
}

fn state(fx: &Fx) -> Vec<String> {
    std::fs::read_to_string(fx.dir.join("state.txt"))
        .unwrap_or_default()
        .lines()
        .map(|s| s.to_string())
        .collect()
}

#[test]
fn node_scope_undoes_only_the_failed_change() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "node-scope", "--json"]);
    assert_eq!(code, 1, "{run}");
    assert_eq!(run["state"], "ROLLED_BACK", "{run}");
    assert_eq!(run["code"], "EXEC-01");
    assert_eq!(state(&fx), ["api", "web", "undo-web"]);
    assert_eq!(run["rollback"]["kept"], serde_json::json!(["api"]));
    assert_eq!(run["rollback"]["steps"][0]["state"], "UNDONE");
}

#[test]
fn flow_scope_undoes_every_change_in_reverse() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "flow-scope", "--json"]);
    assert_eq!(code, 1);
    assert_eq!(run["state"], "ROLLED_BACK", "{run}");
    assert_eq!(state(&fx), ["api", "web", "undo-web", "undo-api"]);
}

#[test]
fn a_failed_check_keeps_changes_unless_on_check_failure() {
    let fx = fx();
    let (_, kept) = fx.json("script", &["run", "smoke-kept", "--json"]);
    assert_eq!(kept["state"], "FAILED", "{kept}");
    assert_eq!(kept["rollback"]["kept"], serde_json::json!(["deploy"]));
    assert_eq!(state(&fx), ["deploy"]);
    let (_, undone) = fx.json("script", &["run", "smoke-undone", "--json"]);
    assert_eq!(undone["state"], "ROLLED_BACK", "{undone}");
    assert_eq!(undone["rollback"]["steps"][0]["checked"], true);
    assert_eq!(state(&fx), ["deploy", "deploy", "undo-deploy"]);
}

#[test]
fn a_failed_rollback_puts_the_environment_on_hold() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "broken-undo", "--json"]);
    assert_eq!(code, 1);
    assert_eq!(run["state"], "ROLLBACK_FAILED", "{run}");
    assert_eq!(run["code"], "ROLLBACK-01");
    assert!(run["rollback"]["hold"].is_string());
    let log =
        std::path::Path::new(run["runDir"].as_str().unwrap()).join("logs/migrate.rollback.log");
    assert!(std::fs::read_to_string(log)
        .unwrap()
        .contains("cannot-undo"));
    // Any new run in a held environment is refused.
    let (code, next) = fx.json("script", &["run", "other", "--json"]);
    assert_eq!(code, 1);
    assert_eq!(next["state"], "REJECTED", "{next}");
    assert_eq!(next["code"], "GUARD-02");
    let (_, holds) = fx.json("script", &["hold", "--json"]);
    assert!(holds["holds"][0]["reason"]
        .as_str()
        .unwrap()
        .contains("hold release"));
    // An AI agent cannot release the hold; a person (script) can.
    let (code, v) = fx.json("claude", &["hold", "release", "local", "--json"]);
    assert_eq!(code, 2, "{v}");
    let (code, v) = fx.json("script", &["hold", "release", "local", "--json"]);
    assert_eq!(code, 0, "{v}");
    assert_eq!(v["released"], true);
    let (code, _) = fx.json("script", &["run", "other", "--json"]);
    assert_eq!(code, 0);
}

#[test]
fn cancelling_rolls_back_what_was_changed() {
    let fx = fx();
    let (code, d) = fx.json("script", &["run", "slow", "--detach", "--json"]);
    assert_eq!(code, 0, "{d}");
    let id = d["runId"].as_str().unwrap().to_string();
    for _ in 0..80 {
        if state(&fx).contains(&"api".to_string()) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    std::thread::sleep(std::time::Duration::from_millis(300));
    let (code, _) = fx.json("script", &["cancel", &id, "--json"]);
    assert_eq!(code, 0);
    let mut last = Value::Null;
    for _ in 0..80 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        let (_, st) = fx.json("script", &["status", &id, "--json"]);
        if st["running"] == false && st["state"] != "RUNNING" {
            last = st;
            break;
        }
    }
    assert_eq!(last["state"], "ROLLED_BACK", "{last}");
    assert_eq!(last["code"], "EXEC-05");
    assert_eq!(state(&fx), ["api", "undo-api"]);
}

#[test]
fn cleanup_steps_run_even_when_the_flow_succeeds() {
    let fx = fx();
    let (code, run) = fx.json("script", &["run", "seeded", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(run["state"], "SUCCEEDED");
    assert_eq!(run["cleanup"][0]["state"], "DONE", "{run}");
    assert_eq!(state(&fx), ["seed", "using", "unseed"]);
}

#[test]
fn undo_scripts_are_shell_quoted() {
    let fx = Fx::new(&[(
        ".gitch/flow.yml",
        &FLOW.replace(
            "project: { name: demo }",
            "project: { name: \"a b; touch pwned\" }",
        ),
    )]);
    fx.trust();
    let (_, run) = fx.json("script", &["run", "quoting", "--json"]);
    assert_eq!(run["state"], "ROLLED_BACK", "{run}");
    assert_eq!(
        std::fs::read_to_string(fx.dir.join("undone.txt")).unwrap(),
        "a b; touch pwned\n"
    );
    assert!(!fx.repo().join("pwned").exists());
    assert!(!fx.dir.join("pwned").exists());
}

#[test]
fn undo_is_only_for_run_nodes() {
    let fx = Fx::new(&[(
        ".gitch/flow.yml",
        "version: 1\nflows:\n  x:\n    nodes:\n      a: { use: check.port, with: { port: 1 }, undo: \"echo no\" }\n",
    )]);
    let (code, v) = fx.json("script", &["validate", "--json"]);
    assert_ne!(code, 0, "{v}");
    assert!(v.to_string().contains("SPEC-03"), "{v}");
}

#[cfg(unix)]
fn kill_engine(fx: &Fx, flow: &str) -> String {
    let (code, d) = fx.json("script", &["run", flow, "--detach", "--json"]);
    assert_eq!(code, 0, "{d}");
    let id = d["runId"].as_str().unwrap().to_string();
    let pid = d["pid"].as_u64().unwrap().to_string();
    std::thread::sleep(std::time::Duration::from_millis(1500));
    let ok = std::process::Command::new("kill")
        .args(["-9", &pid])
        .status()
        .unwrap();
    assert!(ok.success());
    std::thread::sleep(std::time::Duration::from_millis(300));
    id
}

#[cfg(unix)]
#[test]
fn an_engine_that_died_after_a_change_leaves_the_environment_on_hold() {
    let fx = fx();
    let id = kill_engine(&fx, "slow");
    // The next run closes the leftover run as it starts: it changed something, so the target is left alone and held.
    let (code, next) = fx.json("script", &["run", "other", "--json"]);
    assert_eq!(code, 1, "{next}");
    assert_eq!(next["code"], "GUARD-02", "{next}");
    let (_, dead) = fx.json("script", &["status", &id, "--json"]);
    assert_eq!(dead["state"], "ROLLBACK_FAILED", "{dead}");
    assert_eq!(dead["orphan"], true);
    assert_eq!(dead["signed"], true);
    assert_eq!(state(&fx), ["api"], "nothing may be undone automatically");
}

#[cfg(unix)]
#[test]
fn an_engine_that_died_without_changes_is_just_closed() {
    let fx = fx();
    let id = kill_engine(&fx, "slow-plain");
    let (code, next) = fx.json("script", &["run", "other", "--json"]);
    assert_eq!(code, 0, "{next}");
    let (_, dead) = fx.json("script", &["status", &id, "--json"]);
    assert_eq!(dead["state"], "FAILED", "{dead}");
    assert_eq!(dead["code"], "EXEC-06");
}
