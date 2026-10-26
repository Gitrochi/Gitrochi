//! Operations block tests: setup.* (version comparison, skipping the install when nothing changed), gitch.preflight, gitch.graph.check,
//! notifications (block and end of flow), deploy.compose (compare then replace, back to the previous image on failure, production guard).

#![cfg(unix)]

mod common;

use common::fake::{Req, Resp, Server};
use common::Fx;
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

fn node<'a>(run: &'a Value, id: &str) -> &'a Value {
    run["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("no node {id} in {run}"))
}

fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    let p = dir.join("bin").join(name);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(&p, body).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

fn run_with(fx: &Fx, args: &[&str], env: &[(&str, &str)]) -> (i32, Value) {
    let mut c = fx.cmd("script", args);
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

// ---------- setup ----------

const SETUP_FLOW: &str = r#"version: 1
flows:
  py:
    nodes:
      deps: { use: setup.python, with: { version: ">=3", command: "mkdir -p .venv && echo installed >> ../install.log" } }
  old-py:
    nodes:
      deps: { use: setup.python, with: { version: "2.7", install: false } }
"#;

#[test]
fn setup_compares_versions_and_skips_unchanged_installs() {
    let fx = Fx::new(&[
        (".gitch/flow.yml", SETUP_FLOW),
        ("requirements.txt", "requests==2.31.0\n"),
    ]);
    fx.trust();
    let installs = || {
        std::fs::read_to_string(fx.dir.join("install.log"))
            .unwrap_or_default()
            .lines()
            .count()
    };
    let (code, run) = fx.json("script", &["run", "py", "--json"]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(installs(), 1);
    let (_, again) = fx.json("script", &["run", "py", "--json"]);
    assert_eq!(
        node(&again, "deps")["observations"]["installSkipped"],
        true,
        "{again}"
    );
    assert_eq!(installs(), 1, "unchanged lock files must not reinstall");
    fx.write("requirements.txt", "requests==2.32.0\n");
    let (_, third) = fx.json("script", &["run", "py", "--json"]);
    assert_eq!(node(&third, "deps")["state"], "PASSED");
    assert_eq!(installs(), 2);
    let (code, old) = fx.json("script", &["run", "old-py", "--json"]);
    assert_eq!(code, 1);
    assert_eq!(node(&old, "deps")["code"], "SETUP-01", "{old}");
}

// ---------- gitch ----------

const FAKE_GITCH: &str = r#"#!/bin/sh
case "$1" in
  preflight) echo '{"schemaVersion":1,"result":"WARN","checks":[{"level":"OK","code":"identity","message":"ok"},{"level":"WARN","code":"behind","message":"behind by 2"}]}' ;;
  g) echo '{"schemaVersion":1,"ok":false,"violations":[{"from":"ui","to":"db","rule":"no-ui-to-db"}]}'; exit 1 ;;
esac
"#;

const GITCH_FLOW: &str = r#"version: 1
flows:
  lenient:
    nodes:
      pf: { use: gitch.preflight }
  strict:
    nodes:
      pf: { use: gitch.preflight, with: { strict: true } }
  rules:
    nodes:
      deps: { use: gitch.graph.check }
"#;

#[test]
fn gitch_blocks_read_gitch_json() {
    let fx = Fx::new(&[(".gitch/flow.yml", GITCH_FLOW)]);
    fx.trust();
    let g = script(&fx.dir, "gitch", FAKE_GITCH);
    let env = [("GITCH_PATH", g.to_str().unwrap())];
    let (code, run) = run_with(&fx, &["run", "lenient", "--json"], &env);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "pf")["observations"]["result"], "WARN");
    let (code, run) = run_with(&fx, &["run", "strict", "--json"], &env);
    assert_eq!(code, 1);
    assert_eq!(node(&run, "pf")["code"], "GITCH-01", "{run}");
    let (code, run) = run_with(&fx, &["run", "rules", "--json"], &env);
    assert_eq!(code, 1);
    let deps = node(&run, "deps");
    assert_eq!(deps["code"], "GITCH-02", "{deps}");
    assert_eq!(deps["observations"]["violations"], 1);
}

// ---------- notifications ----------

#[test]
fn notifications_never_change_the_result() {
    let got: Arc<Mutex<Vec<Req>>> = Arc::new(Mutex::new(Vec::new()));
    let g2 = got.clone();
    let srv = Server::start(move |r: &Req| {
        g2.lock().unwrap().push(r.clone());
        if r.path == "/broken" {
            Some(Resp::status(500))
        } else {
            Some(Resp::status(204))
        }
    });
    let flow = format!(
        "version: 1\nflows:\n  failing:\n    notify:\n      - {{ on: failure, webhook: hook, message: \"deploy broke\" }}\n      - {{ on: success, webhook: hook }}\n    nodes:\n      boom: {{ run: \"exit 1\" }}\n  pinging:\n    nodes:\n      ping: {{ use: notify.webhook, with: {{ to: \"{b}/broken\", message: hi }} }}\n",
        b = srv.base
    );
    let fx = Fx::new(&[(".gitch/flow.yml", &flow)]);
    fx.trust();
    let (code, out, err) = fx.run(
        "script",
        &[
            "connect",
            "add",
            "webhook",
            "--name",
            "hook",
            "--url",
            &format!("{}/hook", srv.base),
            "--secret-from",
            "env:HOOK_TOKEN",
        ],
    );
    assert_eq!(code, 0, "{out}{err}");
    let (code, run) = run_with(
        &fx,
        &["run", "failing", "--json"],
        &[("HOOK_TOKEN", "hook-Tok3n-abcdef")],
    );
    assert_eq!(code, 1);
    assert_eq!(run["state"], "FAILED");
    assert_eq!(run["notifications"][0]["ok"], true, "{run}");
    assert_eq!(
        run["notifications"].as_array().unwrap().len(),
        1,
        "only the failure entry fires"
    );
    let reqs = got.lock().unwrap().clone();
    let hook = reqs
        .iter()
        .find(|r| r.path == "/hook")
        .expect("webhook call");
    assert_eq!(
        hook.header("Authorization"),
        Some("Bearer hook-Tok3n-abcdef")
    );
    let body: Value = serde_json::from_str(&hook.body).unwrap();
    assert!(
        body["text"]
            .as_str()
            .unwrap()
            .starts_with("deploy broke\nFLOW=FAILED"),
        "{body}"
    );
    assert_eq!(body["data"]["state"], "FAILED");
    // Even when sending fails (500) the node stays passed and the error is recorded as an observation.
    let (code, run) = run_with(&fx, &["run", "pinging", "--json"], &[]);
    assert_eq!(code, 0, "{run}");
    assert_eq!(node(&run, "ping")["observations"]["delivered"], false);
}

// ---------- deploy.compose ----------

const FAKE_DOCKER: &str = r#"#!/bin/sh
st="$FAKE_STATE"
printf '%s\n' "$*" >> "$st/log"
key() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }
id_of() { printf 'sha256:%s' "$(key "$1")"; }
case "$1" in
  version) echo 27.3.1 ;;
  compose)
    shift; files=""; sub=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) files="$files $2"; shift 2 ;;
        -p) shift 2 ;;
        ps|up|rm) sub="$1"; shift; break ;;
        *) shift ;;
      esac
    done
    case "$sub" in
      ps) [ -f "$st/current" ] && echo cid123 ;;
      up)
        if [ -n "$FAKE_UP_FAIL" ] && [ ! -f "$st/failed-once" ]; then touch "$st/failed-once"; echo "container web is unhealthy" >&2; exit 1; fi
        img=""
        for f in $files; do
          i=$(sed -n 's/^ *image: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$f" 2>/dev/null | tail -n 1)
          [ -n "$i" ] && img="$i"
        done
        if [ -f "$st/tag-$(key "$img")" ]; then cat "$st/tag-$(key "$img")" > "$st/current"; else id_of "$img" > "$st/current"; fi ;;
      rm) rm -f "$st/current" ;;
    esac ;;
  inspect)
    case "$3" in
      *'|'*) printf '%s|ref\n' "$(cat "$st/current")" ;;
      *) cat "$st/current"; echo ;;
    esac ;;
  pull) if [ -n "$FAKE_PULL_FAIL" ]; then echo "pull access denied for reg/app" >&2; exit 1; fi; echo pulled ;;
  image) id_of "$5"; echo ;;
  tag) printf '%s' "$2" > "$st/tag-$(key "$3")" ;;
esac
exit 0
"#;

const DEPLOY_FLOW: &str = r#"version: 1
environments:
  prod: { class: prod }
flows:
  ship:
    nodes:
      web: { use: deploy.compose, with: { project: shop, service: web, image: "reg/app:2" } }
  guarded:
    nodes:
      web: { use: deploy.compose, with: { project: shop, service: web, image: "reg/app:2", expectCurrent: "sha256:reg_app_0" } }
  checked:
    nodes:
      web: { use: deploy.compose, with: { project: shop, service: web, image: "reg/app:2", health: { url: "http://127.0.0.1:1/health", timeout: 2s } } }
  to-prod:
    env: prod
    nodes:
      web: { use: deploy.compose, with: { project: shop, service: web, image: "reg/app:2" } }
"#;

struct Dep {
    fx: Fx,
    shim: PathBuf,
    state: PathBuf,
}

impl Dep {
    fn new() -> Dep {
        let fx = Fx::new(&[
            (".gitch/flow.yml", DEPLOY_FLOW),
            ("compose.yml", "services:\n  web:\n    image: reg/app:1\n"),
        ]);
        fx.trust();
        let shim = script(&fx.dir, "docker", FAKE_DOCKER);
        let state = fx.dir.join("dstate");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(state.join("current"), "sha256:reg_app_1").unwrap();
        Dep { fx, shim, state }
    }
    fn run(&self, flow: &str, env: &[(&str, &str)]) -> (i32, Value) {
        let mut e: Vec<(&str, &str)> = vec![
            ("GITCH_DOCKER", self.shim.to_str().unwrap()),
            ("FAKE_STATE", self.state.to_str().unwrap()),
        ];
        e.extend_from_slice(env);
        run_with(&self.fx, &["run", flow, "--json"], &e)
    }
    fn current(&self) -> String {
        std::fs::read_to_string(self.state.join("current"))
            .unwrap_or_default()
            .trim()
            .to_string()
    }
    fn log(&self) -> String {
        std::fs::read_to_string(self.state.join("log")).unwrap_or_default()
    }
}

#[test]
fn deploy_swaps_one_service_and_reports_both_versions() {
    let d = Dep::new();
    let (code, run) = d.run("ship", &[]);
    assert_eq!(code, 0, "{run}");
    let web = node(&run, "web");
    assert_eq!(web["state"], "PASSED", "{web}");
    assert_eq!(d.current(), "sha256:reg_app_2");
    assert_eq!(web["observations"]["previous"], "sha256:reg_app_1");
    let log = d.log();
    assert!(
        log.contains("tag sha256:reg_app_1 gitch-rollback/shop-web:"),
        "{log}"
    );
    assert!(log.contains("up -d --no-deps --wait web"), "{log}");
    // Already on that image: nothing changes.
    let (code, again) = d.run("ship", &[]);
    assert_eq!(code, 0);
    assert_eq!(
        node(&again, "web")["observations"]["unchanged"],
        true,
        "{again}"
    );
}

#[test]
fn a_failed_swap_rolls_back_to_the_previous_image() {
    let d = Dep::new();
    let (code, run) = d.run("ship", &[("FAKE_UP_FAIL", "1")]);
    assert_eq!(code, 1, "{run}");
    assert_eq!(run["state"], "ROLLED_BACK", "{run}");
    assert_eq!(run["rollback"]["steps"][0]["checked"], true);
    assert_eq!(
        d.current(),
        "sha256:reg_app_1",
        "the previous image must be running again"
    );
}

#[test]
fn a_failed_health_check_rolls_back_too() {
    let d = Dep::new();
    let (code, run) = d.run("checked", &[]);
    assert_eq!(code, 1);
    assert_eq!(node(&run, "web")["code"], "VERIFY-01", "{run}");
    assert_eq!(run["state"], "ROLLED_BACK");
    assert_eq!(d.current(), "sha256:reg_app_1");
}

#[test]
fn compare_and_swap_refuses_an_unexpected_running_version() {
    let d = Dep::new();
    let (code, run) = d.run("guarded", &[]);
    assert_eq!(code, 1);
    assert_eq!(node(&run, "web")["code"], "DEPLOY-01", "{run}");
    assert!(!d.log().contains(" up "), "nothing may be swapped");
    assert_eq!(d.current(), "sha256:reg_app_1");
}

#[test]
fn production_deploys_are_refused_without_permission() {
    let d = Dep::new();
    let (code, run) = d.run("to-prod", &[]);
    assert_eq!(code, 1);
    assert_eq!(node(&run, "web")["code"], "GUARD-01", "{run}");
    assert!(d.log().is_empty(), "docker must not be called");
}
