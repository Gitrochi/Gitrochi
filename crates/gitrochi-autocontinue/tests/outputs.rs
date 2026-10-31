//! The exact hook outputs and the shapes the Ledger stores, through the binary and pinned
//! by snapshots in tests/snapshots. After a deliberate change, rewrite them with
//! `UPDATE_SNAPSHOTS=1 cargo test -p gitrochi-autocontinue --test outputs` and review the diff.

use gitrochi_autocontinue::{
    hook_settings, permission_allow, permission_deny, pre_tool_use_allow, stop_wake,
};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const BIN: &str = env!("CARGO_BIN_EXE_gitrochi-autocontinue");

fn dir(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join(name)
}

fn fixture(name: &str) -> String {
    std::fs::read_to_string(dir("fixtures").join(format!("{name}.json"))).unwrap()
}

/// Exit code, stdout and stderr of the binary.
fn run(args: &[&str], stdin: &str) -> (i32, String, String) {
    let mut child = Command::new(BIN)
        .args(args)
        // the home folder is always passed explicitly; HOME must not leak into results
        .env_remove("HOME")
        .env_remove("USERPROFILE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8(out.stdout).unwrap(),
        String::from_utf8(out.stderr).unwrap(),
    )
}

fn eval(name: &str, event: &str, extra: &[&str]) -> (i32, String, String) {
    let mut args = vec![
        "eval",
        event,
        "--home",
        "/Users/me",
        "--branch",
        "feature/parser",
    ];
    args.extend_from_slice(extra);
    run(&args, &fixture(name))
}

fn snapshot(name: &str, value: &Value) {
    let path = dir("snapshots").join(format!("{name}.json"));
    let pretty = serde_json::to_string_pretty(value).unwrap() + "\n";
    if std::env::var_os("UPDATE_SNAPSHOTS").is_some() {
        std::fs::write(&path, pretty).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|_| panic!("missing snapshot {name}; run with UPDATE_SNAPSHOTS=1"));
    let expected: Value = serde_json::from_str(&expected).unwrap();
    assert_eq!(&expected, value, "snapshot {name} differs:\n{pretty}");
}

const CASES: &[(&str, &str)] = &[
    ("stop-question-ko", "Stop"),
    ("stop-question-en", "Stop"),
    ("stop-report", "Stop"),
    ("stop-risky", "Stop"),
    ("stop-hook-active", "Stop"),
    ("ask-user-question", "PreToolUse"),
    ("ask-user-question-ko", "PreToolUse"),
    ("exit-plan-mode", "PreToolUse"),
    ("permission-bash", "PermissionRequest"),
    ("permission-force-push", "PermissionRequest"),
    ("permission-edit-outside", "PermissionRequest"),
    ("user-prompt", "UserPromptSubmit"),
];

#[test]
fn eval_reports_match_the_snapshots() {
    for (name, event) in CASES {
        let (code, stdout, stderr) = eval(name, event, &[]);
        assert_eq!(code, 0, "{name}: {stderr}");
        let report: Value = serde_json::from_str(&stdout).unwrap();
        snapshot(name, &report);
    }
}

#[test]
fn plan_approval_is_off_until_turned_on() {
    let (_, stdout, _) = eval("exit-plan-mode", "PreToolUse", &[]);
    let report: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(report["decision"], "pass");
    assert_eq!(report["reason"]["code"], "trigger_off");

    let policy = dir("fixtures").join("policy-plan-on.json");
    let (_, stdout, _) = eval(
        "exit-plan-mode",
        "PreToolUse",
        &["--policy", policy.to_str().unwrap()],
    );
    let report: Value = serde_json::from_str(&stdout).unwrap();
    snapshot("exit-plan-mode-on", &report);
}

#[test]
fn stop_wakes_claude_with_exit_2_and_the_reply_on_stderr() {
    let (code, stdout, stderr) = eval("stop-question-ko", "Stop", &["--emit"]);
    assert_eq!(code, 2);
    assert!(stdout.is_empty());
    assert!(stderr.starts_with("[Gitrochi] 자동 진행 — 질문: 어떻게 할까요? — 기존 API를 그대로 둔다 / 새 API로 바꾼다 (추천)\n"), "{stderr}");
    assert!(stderr.contains("30초 동안 답이 없어 자동으로 진행합니다."));
    assert!(stderr.contains("고른 가정은 마지막 요약에 적으세요."));

    // nothing to answer: exit 0 and silence
    for (name, event) in [
        ("stop-report", "Stop"),
        ("stop-risky", "Stop"),
        ("permission-force-push", "PermissionRequest"),
    ] {
        let (code, stdout, stderr) = eval(name, event, &["--emit"]);
        assert_eq!(
            (code, stdout.as_str(), stderr.as_str()),
            (0, "", ""),
            "{name}"
        );
    }
}

#[test]
fn ask_user_question_echoes_the_questions_with_answers() {
    let (code, stdout, stderr) = eval("ask-user-question", "PreToolUse", &["--emit"]);
    assert_eq!((code, stderr.as_str()), (0, ""));
    let out: Value = serde_json::from_str(&stdout).unwrap();
    let input: Value = serde_json::from_str(&fixture("ask-user-question")).unwrap();
    let specific = &out["hookSpecificOutput"];
    assert_eq!(specific["hookEventName"], "PreToolUse");
    assert_eq!(specific["permissionDecision"], "allow");
    assert_eq!(
        specific["updatedInput"]["questions"],
        input["tool_input"]["questions"]
    );
    assert_eq!(
        specific["updatedInput"]["answers"],
        json!({
            "Which storage should the ledger use?": "SQLite (Recommended)",
            "Which platforms should get the screen first?": "macOS",
        })
    );
    let note = specific["additionalContext"].as_str().unwrap();
    assert!(note.starts_with("[Gitrochi] Auto-continue — Chosen answer: "));
    assert!(note.contains("No answer for 30 seconds"));
    assert_eq!(out.as_object().unwrap().len(), 1);
}

#[test]
fn the_app_being_closed_lets_synchronous_hooks_end_at_once() {
    for (name, event) in [
        ("ask-user-question", "PreToolUse"),
        ("permission-bash", "PermissionRequest"),
    ] {
        let (code, stdout, stderr) = eval(name, event, &["--emit", "--app-closed"]);
        assert_eq!(
            (code, stdout.as_str(), stderr.as_str()),
            (0, "", ""),
            "{name}"
        );
    }
    // the Stop hook runs in the background and does not need the app
    let (code, _, _) = eval("stop-question-en", "Stop", &["--emit", "--app-closed"]);
    assert_eq!(code, 2);
}

#[test]
fn the_consecutive_limit_stops_every_kind() {
    let (_, stdout, _) = eval("stop-question-en", "Stop", &["--consecutive", "3"]);
    let report: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(
        report["reason"],
        json!({"code": "limit_reached", "consecutive": 3, "max": 3})
    );
    let (_, stdout, _) = eval(
        "permission-bash",
        "PermissionRequest",
        &["--consecutive", "3"],
    );
    let report: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(report["reason"]["code"], "limit_reached");
}

#[test]
fn builders_print_the_documented_shapes() {
    assert_eq!(stop_wake("go").exit_code(), 2);
    assert_eq!(stop_wake("go").stderr(), "go");
    assert!(stop_wake("go").stdout().is_empty());

    let allow: Value = serde_json::from_str(&permission_allow().stdout()).unwrap();
    assert_eq!(
        allow,
        json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
    );
    let deny: Value = serde_json::from_str(&permission_deny("Use a branch").stdout()).unwrap();
    assert_eq!(
        deny,
        json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "Use a branch"}}})
    );
    assert_eq!(permission_allow().exit_code(), 0);
    // never a permanent rule
    assert!(!permission_allow().stdout().contains("updatedPermissions"));

    let pre: Value =
        serde_json::from_str(&pre_tool_use_allow(json!({"questions": []}), None).stdout()).unwrap();
    assert_eq!(
        pre,
        json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": {"questions": []}}})
    );
}

#[test]
fn hook_settings_add_the_delay_to_each_timeout() {
    snapshot(
        "hook-settings",
        &hook_settings(
            "\"/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger\" hook",
            30,
        ),
    );
    let s = hook_settings("h", 120);
    assert_eq!(s["Stop"][0]["hooks"][0]["timeout"], 135);
    assert_eq!(s["Stop"][0]["hooks"][0]["async"], true);
    assert_eq!(s["Stop"][0]["hooks"][0]["asyncRewake"], true);
    assert_eq!(
        s["PreToolUse"][0]["matcher"],
        "AskUserQuestion|ExitPlanMode"
    );
    assert_eq!(s["PreToolUse"][0]["hooks"][0]["command"], "h PreToolUse");
    assert_eq!(s["PermissionRequest"][0]["hooks"][0]["timeout"], 135);
    // out-of-range delays are clamped to 10–300 seconds
    assert_eq!(hook_settings("h", 1)["Stop"][0]["hooks"][0]["timeout"], 25);
    assert_eq!(
        hook_settings("h", 9999)["Stop"][0]["hooks"][0]["timeout"],
        315
    );

    let (code, stdout, _) = run(&["settings", "h", "--delay", "60"], "");
    assert_eq!(code, 0);
    let printed: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(printed, hook_settings("h", 60));
}

#[test]
fn the_binary_reports_bad_input_and_usage() {
    let (code, _, stderr) = run(&["eval", "Stop"], "not json");
    assert_eq!(code, 1);
    assert!(stderr.contains("not JSON"));
    let (code, _, _) = run(&["eval", "Stop", "--nope"], "{}");
    assert_eq!(code, 2);
    let (code, stdout, _) = run(&["--help"], "");
    assert_eq!(code, 0);
    assert!(stdout.contains("eval EVENT"));
    let (code, stdout, _) = run(&["version"], "");
    assert_eq!(code, 0);
    assert!(stdout.starts_with("gitrochi-autocontinue "));
}
