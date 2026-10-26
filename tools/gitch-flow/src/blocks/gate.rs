//! `gate.manual`: a person's approval. Asks when interactive, passes with `--yes` (after the app has asked), and otherwise exits with code 2.

use super::{schema, Block, Meta, NodeCx, NodeResult};
use crate::util::tr;
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};
use std::io::{BufRead, Write};

pub struct Manual;

fn inputs() -> Value {
    schema(
        json!({"message": {"type": "string", "description": "Question shown to the person."}}),
        &[],
    )
}

static META: Meta = Meta {
    id: "gate.manual",
    version: "1.0.0",
    title: ("사람 확인", "Manual approval"),
    category: "gate",
    capabilities: &[],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["CONFIRM-01", "GATE-02"],
    inputs,
    selects_files: false,
    estimate_ms: 0,
};

fn verdict(result: Outcome, observed: String, code: Option<&'static str>) -> Verdict {
    Verdict {
        rule: "G1",
        title: tr("사람 확인", "manual approval"),
        observed,
        expected: tr("승인", "approved"),
        result,
        code,
        phase: "main",
    }
}

impl Block for Manual {
    fn meta(&self) -> &Meta {
        &META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let msg = cx
            .input_str("message")
            .unwrap_or_else(|| tr("계속할까요?", "Continue?"));
        if cx.yes {
            r.observe("approvedBy", json!("--yes"));
            r.verdicts
                .push(verdict(Outcome::Pass, "--yes".into(), None));
            return r;
        }
        if !cx.interactive {
            r.needs_confirmation = true;
            r.verdicts.push(verdict(
                Outcome::Indeterminate,
                tr("비대화형", "non-interactive"),
                Some("CONFIRM-01"),
            ));
            return r;
        }
        let mut err = std::io::stderr();
        let _ = write!(err, "\n? {msg} [y/N] ");
        let _ = err.flush();
        let mut answer = String::new();
        let _ = std::io::stdin().lock().read_line(&mut answer);
        let yes = matches!(
            answer.trim().to_ascii_lowercase().as_str(),
            "y" | "yes" | "ㅇ" | "예" | "네"
        );
        cx.note(&format!("{msg} → {}", if yes { "yes" } else { "no" }));
        r.observe("answer", json!(answer.trim()));
        if yes {
            r.verdicts.push(verdict(Outcome::Pass, "yes".into(), None));
        } else {
            r.verdicts
                .push(verdict(Outcome::Fail, "no".into(), Some("GATE-02")));
        }
        r
    }
}
