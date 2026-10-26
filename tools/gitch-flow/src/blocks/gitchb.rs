//! gitch 블록: `gitch.preflight`(커밋 · push 전 점검) · `gitch.graph.check`(의존 규칙).
//! gitch 의 JSON 출력만 읽어 판정한다. gitch 는 앞문이 넘긴 `GITCH_PATH`(없으면 PATH 의 gitch)를 bash 로 부른다.

use super::{observe_outcome, schema, Block, Meta, NodeCx, NodeResult};
use crate::process::ProcSpec;
use crate::util::tr;
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};

pub struct Preflight;
pub struct GraphCheck;

/// gitch 스크립트 경로.
pub fn gitch_path() -> Option<String> {
    if let Ok(p) = std::env::var("GITCH_PATH") {
        if !p.is_empty() {
            return Some(p);
        }
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join("gitch"))
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().to_string())
}

fn gitch(cx: &mut NodeCx, args: &[&str]) -> Result<(Value, super::Captured), String> {
    let g = gitch_path().ok_or_else(|| tr("gitch 를 찾지 못했습니다.", "gitch was not found."))?;
    let mut a = vec![g];
    a.extend(args.iter().map(|s| s.to_string()));
    let mut env = cx.env.clone();
    env.push(("GITSW_COLOR".into(), "never".into()));
    let spec = ProcSpec {
        program: crate::process::bash_path(),
        args: a,
        cwd: cx.cwd.clone(),
        env,
        clear_env: true,
        timeout_ms: cx.timeout_ms.or(Some(300_000)),
        settle_ms: 3000,
    };
    let c = cx.run_proc(&spec);
    let v = c
        .stdout
        .lines()
        .rev()
        .find_map(|l| {
            serde_json::from_str::<Value>(l.trim())
                .ok()
                .filter(|v| v.is_object())
        })
        .or_else(|| serde_json::from_str::<Value>(c.stdout.trim()).ok())
        .ok_or_else(|| {
            tr(
                "gitch 의 JSON 출력을 읽지 못했습니다.",
                "could not read gitch's JSON output.",
            )
        })?;
    Ok((v, c))
}

fn unknown(msg: String) -> Verdict {
    Verdict::new(
        "G0",
        "gitch".into(),
        msg,
        "JSON".into(),
        Outcome::Indeterminate,
        Some("VERIFY-03"),
    )
}

fn preflight_inputs() -> Value {
    schema(
        json!({"strict": {"type": "boolean", "default": false, "description": "Treat WARN as a failure."},
               "fetch": {"type": "boolean", "default": false, "description": "Let gitch fetch the remote first."}}),
        &[],
    )
}

fn graph_inputs() -> Value {
    schema(
        json!({"base": {"type": "string"}, "rules": {"type": "string"}, "dir": {"type": "string"}}),
        &[],
    )
}

static PREFLIGHT_META: Meta = Meta {
    id: "gitch.preflight",
    version: "1.0.0",
    title: ("gitch 사전 점검", "gitch preflight"),
    category: "gitch",
    capabilities: &["process"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["GITCH-01", "VERIFY-03", "EXEC-04"],
    inputs: preflight_inputs,
    selects_files: false,
    estimate_ms: 5_000,
};

static GRAPH_META: Meta = Meta {
    id: "gitch.graph.check",
    version: "1.0.0",
    title: ("gitch 의존 규칙 점검", "gitch dependency rules"),
    category: "gitch",
    capabilities: &["process"],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["GITCH-02", "VERIFY-03", "EXEC-04"],
    inputs: graph_inputs,
    selects_files: false,
    estimate_ms: 20_000,
};

impl Block for Preflight {
    fn meta(&self) -> &Meta {
        &PREFLIGHT_META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let fetch = cx
            .with
            .get("fetch")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let mut args = vec!["preflight", "--json"];
        if !fetch {
            args.push("--no-fetch");
        }
        let (v, c) = match gitch(cx, &args) {
            Ok(x) => x,
            Err(e) => {
                r.verdicts.push(unknown(e));
                return r;
            }
        };
        observe_outcome(&mut r, &c);
        let level = v["result"].as_str().unwrap_or("").to_string();
        let strict = cx
            .with
            .get("strict")
            .and_then(|s| s.as_bool())
            .unwrap_or(false);
        let issues: Vec<Value> = v["checks"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|c| c["level"] != "OK")
            .collect();
        r.observe("result", json!(level));
        r.observe("issues", json!(issues));
        let ok = level == "OK" || (level == "WARN" && !strict);
        let observed = if issues.is_empty() {
            level.clone()
        } else {
            format!(
                "{level}: {}",
                issues
                    .iter()
                    .filter_map(|i| i["message"].as_str())
                    .collect::<Vec<_>>()
                    .join(" · ")
            )
        };
        r.verdicts.push(Verdict::new(
            "G3",
            "gitch preflight".into(),
            observed,
            if strict {
                "OK".into()
            } else {
                "OK | WARN".into()
            },
            if level.is_empty() {
                Outcome::Indeterminate
            } else if ok {
                Outcome::Pass
            } else {
                Outcome::Fail
            },
            Some(if level.is_empty() {
                "VERIFY-03"
            } else {
                "GITCH-01"
            }),
        ));
        r
    }
}

impl Block for GraphCheck {
    fn meta(&self) -> &Meta {
        &GRAPH_META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let base = cx.input_str("base");
        let rules = cx.input_str("rules");
        let dir = cx.input_str("dir");
        let mut args: Vec<String> = vec!["g".into(), "check".into(), "--json".into()];
        if let Some(b) = &base {
            args.extend(["--base".to_string(), b.clone()]);
        }
        if let Some(f) = &rules {
            args.extend(["--rules".to_string(), f.clone()]);
        }
        if let Some(d) = &dir {
            args.push(d.clone());
        }
        let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let (v, c) = match gitch(cx, &refs) {
            Ok(x) => x,
            Err(e) => {
                r.verdicts.push(unknown(e));
                return r;
            }
        };
        observe_outcome(&mut r, &c);
        let violations = v["violations"].as_array().cloned().unwrap_or_default();
        r.observe("violations", json!(violations.len()));
        r.observe(
            "details",
            json!(violations.iter().take(20).collect::<Vec<_>>()),
        );
        let ok = v["ok"].as_bool();
        r.verdicts.push(Verdict::new(
            "G4",
            tr("의존 규칙", "dependency rules"),
            format!("{} {}", violations.len(), tr("개 위반", "violations")),
            "0".into(),
            match ok {
                Some(true) => Outcome::Pass,
                Some(false) => Outcome::Fail,
                None => Outcome::Indeterminate,
            },
            Some(if ok.is_none() {
                "VERIFY-03"
            } else {
                "GITCH-02"
            }),
        ));
        r
    }
}
