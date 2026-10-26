//! `cmd` — 셸 명령 한 줄(`run:` 줄임 노드). 주 관측값은 종료 코드, 선택으로 출력 기대.

use super::{exit_verdict, observe_outcome, schema, Block, Meta, NodeCx, NodeResult};
use crate::util::tr;
use crate::verify;
use serde_json::{json, Value};

pub struct Cmd;

fn inputs() -> Value {
    schema(
        json!({
            "run": {"type": "string", "description": "Shell script to run (bash by default)."},
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
        match with.get("run") {
            Some(Value::String(s)) if !s.trim().is_empty() => Vec::new(),
            _ => vec![tr(
                "run 에 실행할 명령이 필요합니다.",
                "run needs a command.",
            )],
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let script = cx.input_str("run").unwrap_or_default();
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
