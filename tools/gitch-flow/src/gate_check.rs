//! pre-push 게이트 판단. gitch 의 pre-push 훅 · `gitch p` · 앱 Push 검토가 같은 판단을 쓴다.
//! 같은 커밋 · 깨끗한 작업 트리에서 엔진이 서명한 통과 기록이 있으면 다시 돌리지 않는다.

use crate::cli::{Args, Out};
use crate::store::{self, Store};
use crate::util::tr;
use serde_json::{json, Value};
use std::path::Path;

/// 저장소별 게이트 설정(~/.config/gitsw/flow/settings.json 의 prePush.<저장소ID>).
pub fn enabled(root: &Path) -> Option<String> {
    let s = crate::cli::settings();
    let id = crate::trust::repo_id(root);
    match &s["prePush"][&id] {
        Value::String(flow) if !flow.is_empty() => Some(flow.clone()),
        Value::Bool(true) => Some("pre-push".into()),
        _ => None,
    }
}

/// 지금 HEAD 에 맞는 서명된 통과 기록.
pub fn passing_record(st: &Store, flow: &str, sha: &str) -> Option<Value> {
    for id in st.run_ids().into_iter().take(40) {
        let Some(r) = st.read_run(&id) else { continue };
        if r["flow"] != flow || r["git"]["sha"] != sha {
            continue;
        }
        if r["state"] == "SUCCEEDED" && r["git"]["clean"] == true && store::verify(&r) {
            return Some(r);
        }
        // 같은 커밋의 가장 최근 기록이 실패면 그것이 답이다.
        return None;
    }
    None
}

pub fn cmd_gate(out: &Out, args: &Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return 1;
    };
    let sub = args.pos.first().map(|s| s.as_str()).unwrap_or("status");
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
    // prepush: 흐름을 돌린다(영향만). 사람 출력은 표준오류로(훅 출력이 push 출력과 섞이지 않게).
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
