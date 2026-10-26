//! `cmd` — 셸 명령 한 줄(`run:` 줄임 노드). 주 관측값은 종료 코드, 선택으로 출력 기대.

use super::{
    exit_verdict, observe_outcome, schema, Block, Meta, NodeCx, NodeResult, UndoAction, UndoStep,
};
use crate::util::tr;
use crate::verify;
use serde_json::{json, Value};

pub struct Cmd;

fn inputs() -> Value {
    schema(
        json!({
            "run": {"type": "string", "description": "Shell script to run (bash by default)."},
            "undo": {"description": "Script that reverses this command, or { run, check, timeout, always }. It runs when the flow fails or is cancelled (rollback), even if this command failed half-way, so it must be safe to run when nothing changed.",
                     "oneOf": [{"type": "string"}, {"type": "object", "properties": {"run": {"type": "string"}, "check": {"type": "string"}, "timeout": {"type": "string"}, "always": {"type": "boolean"}}, "required": ["run"]}]},
        }),
        &["run"],
    )
}

static META: Meta = Meta {
    id: "cmd",
    version: "1.0.0",
    title: ("명령", "Command"),
    category: "run",
    capabilities: &["process"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &[
        "EXEC-01",
        "EXEC-02",
        "EXEC-03",
        "EXEC-04",
        "EXEC-05",
        "VERIFY-04",
    ],
    inputs,
    selects_files: false,
    estimate_ms: 30_000,
};

impl Block for Cmd {
    fn meta(&self) -> &Meta {
        &META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let mut e = match with.get("run") {
            Some(Value::String(s)) if !s.trim().is_empty() => Vec::new(),
            _ => vec![tr(
                "run 에 실행할 명령이 필요합니다.",
                "run needs a command.",
            )],
        };
        match with.get("undo") {
            None | Some(Value::Null) | Some(Value::String(_)) => {}
            Some(Value::Object(o)) if o.get("run").map(|r| r.is_string()).unwrap_or(false) => {}
            Some(_) => e.push(tr(
                "undo 는 명령 글이거나 { run, check, timeout, always } 입니다.",
                "undo is a command string or { run, check, timeout, always }.",
            )),
        }
        e
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let script = cx.input_str("run").unwrap_or_default();
        if let Some(step) = undo_step(&cx.with) {
            cx.register_undo(step);
            r.mutated = true;
        }
        let c = cx.run_script(&script, &[]);
        observe_outcome(&mut r, &c);
        let allowed = cx.expect.exit.clone().unwrap_or_else(|| vec![0]);
        r.verdicts.push(exit_verdict(&c, &allowed));
        if let Some(p) = cx.expect.output.clone() {
            let text = format!("{}\n{}", c.stdout, c.tail.join("\n"));
            r.verdicts.push(verify::output(&text, &p));
        }
        r
    }
}

/// `undo:` 입력 → 되돌림 단계.
fn undo_step(with: &Value) -> Option<UndoStep> {
    let (run, check, timeout, always) = match with.get("undo")? {
        Value::String(s) if !s.trim().is_empty() => (s.clone(), None, None, false),
        Value::Object(o) => (
            o.get("run")?.as_str()?.to_string(),
            o.get("check")
                .and_then(|c| c.as_str())
                .map(|c| c.to_string()),
            o.get("timeout")
                .and_then(|t| t.as_str())
                .and_then(crate::util::parse_duration),
            o.get("always").and_then(|a| a.as_bool()).unwrap_or(false),
        ),
        _ => return None,
    };
    Some(UndoStep {
        title: run.lines().next().unwrap_or("").to_string(),
        action: UndoAction::Script(run),
        check: check.map(UndoAction::Script),
        timeout_ms: timeout.unwrap_or(5 * 60_000),
        always,
    })
}
