//! The pre-push gate's decision, shared by gitch's pre-push hook, `gitch p` and the apps' push review.
//! A passing record signed by the engine for the same commit and a clean working tree means no rerun.

use crate::cli::{Args, Out};
use crate::store::{self, Store};
use crate::util::tr;
use serde_json::{json, Value};
use std::path::Path;

/// Per-repository gate settings (prePush.<repo-id> in ~/.config/gitsw/flow/settings.json).
pub fn enabled(root: &Path) -> Option<String> {
    let s = crate::cli::settings();
    let id = crate::trust::repo_id(root);
    match &s["prePush"][&id] {
        Value::String(flow) if !flow.is_empty() => Some(flow.clone()),
        Value::Bool(true) => Some("pre-push".into()),
        _ => None,
    }
}

/// A signed passing record for the current HEAD.
pub fn passing_record(st: &Store, flow: &str, sha: &str) -> Option<Value> {
    for id in st.run_ids().into_iter().take(40) {
        let Some(r) = st.read_run(&id) else { continue };
        if r["flow"] != flow || r["git"]["sha"] != sha {
            continue;
        }
        if r["state"] == "SUCCEEDED" && r["git"]["clean"] == true && store::verify(&r) {
            return Some(r);
        }
        // If the latest record for this commit failed, that is the answer.
        return None;
    }
    None
}

/// `gate on [--flow F]` and `gate off`: switch this repository's pre-push gate. People only (app or terminal).
fn toggle(out: &Out, root: &Path, on: bool, flow: Option<String>) -> i32 {
    let actor = crate::trust::actor();
    if crate::trust::is_ai(&actor) {
        let msg = tr(
            "pre-push 게이트는 사람이 켜고 끕니다(앱의 흐름 화면 또는 터미널).",
            "a person turns the pre-push gate on and off (the app's Flows panel or a terminal).",
        );
        if out.json {
            eprintln!(
                "{}",
                json!({"schemaVersion": 1, "error": {"code": "GITCH_CONFIRMATION_REQUIRED", "flowCode": "CONFIRM-01", "message": msg, "exitCode": 2}})
            );
        } else {
            eprintln!("{msg}");
        }
        return 2;
    }
    let path = crate::util::gitsw_dir().join("flow").join("settings.json");
    let mut s = crate::cli::settings();
    if !s.is_object() {
        s = json!({});
    }
    if !s["prePush"].is_object() {
        s["prePush"] = json!({});
    }
    let id = crate::trust::repo_id(root);
    let flow = flow.unwrap_or_else(|| "pre-push".into());
    if on {
        s["prePush"][&id] = json!(flow);
    } else if let Some(o) = s["prePush"].as_object_mut() {
        o.remove(&id);
    }
    if let Err(e) = crate::util::write_atomic(
        &path,
        serde_json::to_string_pretty(&s)
            .unwrap_or_default()
            .as_bytes(),
    ) {
        eprintln!("{e}");
        return 1;
    }
    if out.json {
        println!(
            "{}",
            json!({"schemaVersion": 1, "gate": if on { "ON" } else { "OFF" }, "flow": if on { json!(flow) } else { Value::Null }})
        );
    } else if on {
        println!(
            "{}",
            tr(
                &format!("✔ push 전에 '{flow}' 흐름을 확인합니다."),
                &format!("✔ pushes now check the '{flow}' flow first.")
            )
        );
    } else {
        println!(
            "{}",
            tr(
                "✔ pre-push 게이트를 껐습니다.",
                "✔ the pre-push gate is off."
            )
        );
    }
    0
}

pub fn cmd_gate(out: &Out, args: &Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return 1;
    };
    let sub = args.pos.first().map(|s| s.as_str()).unwrap_or("status");
    match sub {
        "on" => return toggle(out, &root, true, args.val("--flow")),
        "off" => return toggle(out, &root, false, None),
        _ => {}
    }
    let flow = args.val("--flow").or_else(|| enabled(&root));
    let Some(flow) = flow else {
        if out.json {
            println!("{}", json!({"schemaVersion": 1, "gate": "OFF"}));
        } else {
            println!("FLOW=OFF");
        }
        return 0;
    };
    let Some(st) = Store::open(&root) else {
        return 1;
    };
    let sha = crate::git::head_sha(&root).unwrap_or_default();
    let clean = crate::git::is_clean(&root);
    if let Some(r) = passing_record(&st, &flow, &sha) {
        if out.json {
            println!(
                "{}",
                json!({"schemaVersion": 1, "gate": "OK", "flow": flow, "runId": r["runId"], "reused": true})
            );
        } else {
            println!("FLOW=OK");
            println!(
                "{}",
                tr(
                    &format!(
                        "  같은 커밋에서 통과한 기록이 있습니다({})",
                        r["runId"].as_str().unwrap_or("")
                    ),
                    &format!(
                        "  a passing run exists for this commit ({})",
                        r["runId"].as_str().unwrap_or("")
                    )
                )
            );
        }
        return 0;
    }
    if sub == "status" {
        if out.json {
            println!(
                "{}",
                json!({"schemaVersion": 1, "gate": "WARN", "flow": flow, "reason": "no passing run for HEAD", "clean": clean})
            );
        } else {
            println!("FLOW=WARN");
            println!("{}", tr(&format!("  이 커밋에서 {flow} 를 아직 통과하지 않았습니다 — gitch flow run {flow} --affected"), &format!("  {flow} has not passed for this commit yet — gitch flow run {flow} --affected")));
        }
        return 0;
    }
    // prepush: run the flow (affected only). Human output goes to stderr so the hook does not mix with push output.
    if !clean {
        eprintln!(
            "{}",
            tr(
                "⚠ 커밋하지 않은 변경이 있어 결과를 재사용 기록으로 남기지 않습니다.",
                "⚠ there are uncommitted changes, so the result will not be reusable."
            )
        );
    }
    let raw = vec![
        "run".to_string(),
        flow.clone(),
        "--affected".into(),
        "--trigger".into(),
        "pre-push".into(),
        "--summary".into(),
    ];
    let code = crate::cli::main(raw);
    if code == 0 {
        eprintln!("FLOW=OK");
        0
    } else {
        eprintln!("FLOW=STOP");
        eprintln!("{}", tr("  push 를 멈췄습니다. 고친 뒤 다시 push 하거나, 사람이 직접 넘기려면 GITSW_SKIP=flow (기록이 남습니다).", "  push stopped. Fix it and push again; a person can skip it with GITSW_SKIP=flow (this is recorded)."));
        if code == 2 {
            2
        } else {
            1
        }
    }
}
