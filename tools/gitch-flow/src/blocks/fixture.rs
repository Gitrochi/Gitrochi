//! `fixture.seed` — 시험 자료 넣기. 넣기 직전에 지우는 명령을 되돌림으로 등록해, 기본은 실행이 끝날 때마다
//! 지우고(`keep: false`), `keep: true` 면 흐름이 실패 · 취소될 때만 지운다. 명령은 노드의 실행 위치(local · docker)를 따른다.

use super::{
    exit_verdict, observe_outcome, schema, Block, Meta, NodeCx, NodeResult, UndoAction, UndoStep,
};
use crate::util::tr;
use serde_json::{json, Value};

pub struct Seed;

fn inputs() -> Value {
    schema(
        json!({"run": {"type": "string", "description": "Command that loads the fixture."},
               "undo": {"type": "string", "description": "Command that removes it again; it must be safe when nothing was loaded."},
               "keep": {"type": "boolean", "default": false, "description": "Keep the data after a successful run (undo only on failure or cancel)."},
               "timeout": {"type": "string", "description": "Time limit for undo (default 5m)."}}),
        &["run", "undo"],
    )
}

static META: Meta = Meta {
    id: "fixture.seed",
    version: "1.0.0",
    title: ("시험 자료 넣기", "Seed test data"),
    category: "fixture",
    capabilities: &["process"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["EXEC-01", "EXEC-02", "EXEC-05", "ROLLBACK-01"],
    inputs,
    selects_files: false,
    estimate_ms: 20_000,
};

impl Block for Seed {
    fn meta(&self) -> &Meta {
        &META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let mut e = Vec::new();
        for k in ["run", "undo"] {
            if with
                .get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().is_empty())
                .unwrap_or(true)
            {
                e.push(tr(
                    &format!("{k} 가 필요합니다."),
                    &format!("{k} is required."),
                ));
            }
        }
        e
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let keep = cx
            .with
            .get("keep")
            .and_then(|k| k.as_bool())
            .unwrap_or(false);
        let undo = cx.input_str("undo").unwrap_or_default();
        cx.register_undo(UndoStep {
            title: undo.lines().next().unwrap_or("").to_string(),
            action: UndoAction::Script(undo),
            check: None,
            timeout_ms: cx
                .input_str("timeout")
                .and_then(|t| crate::util::parse_duration(&t))
                .unwrap_or(5 * 60_000),
            always: !keep,
        });
        r.mutated = true;
        let script = cx.input_str("run").unwrap_or_default();
        let c = cx.run_script(&script, &[]);
        observe_outcome(&mut r, &c);
        r.observe("keep", json!(keep));
        r.verdicts.push(exit_verdict(&c, &[0]));
        r
    }
}
