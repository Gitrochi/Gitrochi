//! Rollback: after a failure or cancel, runs the undo steps nodes registered, in reverse; if that fails, the environment is put on hold.
//! Scope node (default) undoes only what the failed node changed; flow undoes every node that changed something (after a failed check node, which changes nothing,
//! only with `onCheckFailure: true`). A cancel undoes every change whatever the scope. The engine never retries
//! a rollback on its own: when one fails, a person checks the environment and releases it with `gitch flow hold release`.

use crate::blocks::{UndoAction, UndoStep};
use crate::mask::Masker;
use crate::process::{self, Cancel, ProcSpec, Stream};
use crate::spec::RollbackScope;
use crate::store::{Events, Store};
use crate::util::{self, tr};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// The node's environment for its undo steps (as the node ran).
#[derive(Debug, Clone, Default)]
pub struct UndoCtx {
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
    pub shell: String,
}

/// A node that changed something (in the order nodes finished).
pub struct Changed<'a> {
    pub node: &'a str,
    pub bad: bool,
    pub steps: &'a [UndoStep],
    pub ctx: &'a UndoCtx,
}

pub struct Choice {
    /// Nodes to undo, in finishing order (they run in reverse).
    pub nodes: Vec<String>,
    /// Nodes that changed something but are kept.
    pub kept: Vec<String>,
    pub why: String,
}

/// Decides what to undo. `check_failed` says whether a node that changed nothing failed (a check such as a smoke test).
pub fn decide(
    scope: RollbackScope,
    on_check: bool,
    cancelled: bool,
    failed: bool,
    changed: &[Changed],
    check_failed: bool,
) -> Choice {
    let all: Vec<String> = changed
        .iter()
        .filter(|c| c.steps.iter().any(|s| !s.always))
        .map(|c| c.node.to_string())
        .collect();
    let pick = |nodes: Vec<String>, why: String| {
        let kept = all.iter().filter(|n| !nodes.contains(n)).cloned().collect();
        Choice { nodes, kept, why }
    };
    if all.is_empty() || !(cancelled || failed) {
        return pick(Vec::new(), String::new());
    }
    if cancelled {
        return pick(
            all.clone(),
            tr(
                "취소: 바꾼 것을 모두 되돌림",
                "cancelled: undo every change",
            ),
        );
    }
    let change_failed = changed
        .iter()
        .any(|c| c.bad && c.steps.iter().any(|s| !s.always));
    match scope {
        RollbackScope::Node => pick(
            changed
                .iter()
                .filter(|c| c.bad && c.steps.iter().any(|s| !s.always))
                .map(|c| c.node.to_string())
                .collect(),
            tr(
                "범위 node: 실패한 노드가 바꾼 것만 되돌림",
                "scope node: undo only what the failed nodes changed",
            ),
        ),
        RollbackScope::Flow if change_failed || (check_failed && on_check) => pick(
            all.clone(),
            tr(
                "범위 flow: 바꾼 노드를 모두 거꾸로 되돌림",
                "scope flow: undo every changed node in reverse",
            ),
        ),
        RollbackScope::Flow => pick(
            Vec::new(),
            tr(
                "검사 노드만 실패 — onCheckFailure 가 꺼져 있어 바꾼 것을 그대로 둠",
                "only a check failed and onCheckFailure is off, so changes were kept",
            ),
        ),
    }
}

pub struct Done {
    pub ok: bool,
    pub steps: Vec<Value>,
    pub failed_at: Option<(String, String)>,
}

fn spec_for(action: &UndoAction, ctx: &UndoCtx, timeout_ms: u64) -> ProcSpec {
    let (program, args) = match action {
        UndoAction::Script(s) => process::shell_command(&ctx.shell, s),
        UndoAction::Argv { program, args } => (program.clone(), args.clone()),
    };
    ProcSpec {
        program,
        args,
        cwd: ctx.cwd.clone(),
        env: ctx.env.clone(),
        clear_env: true,
        timeout_ms: Some(timeout_ms.max(1000)),
        settle_ms: 3000,
    }
}

/// Runs one action and writes its masked output to the log. Ok on exit code 0.
fn run_action(
    spec: &ProcSpec,
    masker: &Masker,
    log: &mut Option<std::fs::File>,
    events: &Events,
    node: &str,
) -> Result<u64, String> {
    let mut batch: Vec<Value> = Vec::new();
    let o = process::run(spec, &Cancel::new(), &mut |s, l| {
        let m = masker.mask(l);
        if let Some(f) = log.as_mut() {
            let _ = writeln!(f, "{m}");
        }
        batch.push(json!({"s": if s == Stream::Out { "out" } else { "err" }, "t": m}));
    });
    if !batch.is_empty() {
        events.emit(
            "log",
            Some(node),
            json!({"phase": "rollback", "lines": batch}),
        );
    }
    if let Some(e) = o.spawn_error {
        return Err(e);
    }
    if o.timed_out {
        return Err(tr("시간 초과", "timed out"));
    }
    match o.exit_code {
        Some(0) => Ok(o.duration_ms),
        c => Err(format!(
            "exit {}",
            c.map(|x| x.to_string()).unwrap_or("?".into())
        )),
    }
}

/// Runs the chosen nodes' undo steps in reverse finishing order, and within a node in reverse registration order.
/// A step with a `check` is verified after it runs. Past the time budget the remaining steps do not run and count as failed.
pub fn execute(
    choice: &Choice,
    changed: &[Changed],
    budget_ms: u64,
    run_dir: &Path,
    masker: &Masker,
    events: &Events,
) -> Done {
    let started = Instant::now();
    let mut steps = Vec::new();
    let mut failed_at: Option<(String, String)> = None;
    for c in changed
        .iter()
        .rev()
        .filter(|c| choice.nodes.iter().any(|n| n == c.node))
    {
        let mut log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(
                run_dir
                    .join("logs")
                    .join(format!("{}.rollback.log", crate::store::safe(c.node))),
            )
            .ok();
        for step in c.steps.iter().rev().filter(|s| !s.always) {
            let left = budget_ms.saturating_sub(started.elapsed().as_millis() as u64);
            let mut rec = json!({"node": c.node, "title": masker.mask(&step.title), "action": masker.mask(&step.action.show())});
            if failed_at.is_some() || left == 0 {
                // After a failed step, or with the budget spent, change nothing more so a person sees the state as it is.
                rec["state"] = json!("NOT_RUN");
                rec["reason"] = json!(if left == 0 {
                    tr("되돌림 예산을 넘김", "rollback budget exhausted")
                } else {
                    tr(
                        "앞 되돌림이 실패해 멈춤",
                        "stopped after an earlier undo failed",
                    )
                });
                if failed_at.is_none() {
                    failed_at = Some((c.node.to_string(), step.title.clone()));
                }
                steps.push(rec);
                continue;
            }
            events.emit(
                "rollback.step",
                Some(c.node),
                json!({"state": "RUNNING", "title": masker.mask(&step.title)}),
            );
            let res = run_action(
                &spec_for(&step.action, c.ctx, step.timeout_ms.min(left)),
                masker,
                &mut log,
                events,
                c.node,
            );
            let res = res.and_then(|ms| match &step.check {
                None => Ok(ms),
                Some(chk) => {
                    let left = budget_ms.saturating_sub(started.elapsed().as_millis() as u64);
                    run_action(
                        &spec_for(chk, c.ctx, left.min(120_000)),
                        masker,
                        &mut log,
                        events,
                        c.node,
                    )
                    .map(|m| ms + m)
                    .map_err(|e| {
                        tr(
                            &format!("되돌린 뒤 확인 실패: {e}"),
                            &format!("check after undo failed: {e}"),
                        )
                    })
                }
            });
            match res {
                Ok(ms) => {
                    rec["state"] = json!("UNDONE");
                    rec["durationMs"] = json!(ms);
                    rec["checked"] = json!(step.check.is_some());
                }
                Err(e) => {
                    rec["state"] = json!("FAILED");
                    rec["error"] = json!(masker.mask(&e));
                    failed_at = Some((c.node.to_string(), step.title.clone()));
                }
            }
            events.emit("rollback.step", Some(c.node), rec.clone());
            steps.push(rec);
        }
    }
    Done {
        ok: failed_at.is_none(),
        steps,
        failed_at,
    }
}

/// Cleanup steps that always run (`always: true`). A failure is recorded but does not change the run's result.
pub fn cleanup(
    changed: &[Changed],
    run_dir: &Path,
    masker: &Masker,
    events: &Events,
) -> Vec<Value> {
    let mut out = Vec::new();
    for c in changed.iter().rev() {
        let mut log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(
                run_dir
                    .join("logs")
                    .join(format!("{}.cleanup.log", crate::store::safe(c.node))),
            )
            .ok();
        for step in c.steps.iter().rev().filter(|s| s.always) {
            let res = run_action(
                &spec_for(&step.action, c.ctx, step.timeout_ms),
                masker,
                &mut log,
                events,
                c.node,
            );
            out.push(match res {
                Ok(ms) => json!({"node": c.node, "title": masker.mask(&step.title), "state": "DONE", "durationMs": ms}),
                Err(e) => json!({"node": c.node, "title": masker.mask(&step.title), "state": "FAILED", "error": masker.mask(&e)}),
            });
        }
    }
    out
}

/// Puts an environment whose rollback failed on hold. Until it is released, new runs there are refused with GUARD-02.
pub fn hold(st: &Store, env: &str, run_id: &str, flow: &str, at: &(String, String)) -> PathBuf {
    let p = st.hold_path(env);
    let message = tr(
        &format!(
            "실행 {run_id}({flow}) 의 되돌림이 {} 에서 실패했습니다({}). 환경을 직접 확인한 뒤 gitch flow hold release {env} 로 푸세요.",
            at.0, at.1
        ),
        &format!(
            "rollback of run {run_id} ({flow}) failed at {} ({}). Check the environment by hand, then run gitch flow hold release {env}.",
            at.0, at.1
        ),
    );
    let rec = json!({"schemaVersion": 1, "env": env, "runId": run_id, "flow": flow, "node": at.0, "step": at.1,
                     "at": util::rfc3339(util::now_ms()), "message": message});
    let _ = util::write_atomic(
        &p,
        serde_json::to_string_pretty(&rec)
            .unwrap_or_default()
            .as_bytes(),
    );
    p
}

/// The hold record's text for people (old records are plain text).
pub fn hold_message(text: &str) -> String {
    serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| v["message"].as_str().map(|s| s.to_string()))
        .unwrap_or_else(|| text.trim().to_string())
}

/// Closes runs whose engine disappeared before they finished. With traces of changes (registered undo steps) the target is left alone
/// and the run closes as ROLLBACK_FAILED with a hold, otherwise as FAILED (EXEC-06). So that a detached run that just started is not closed by mistake,
/// records without a pid file count only after a minute.
pub fn sweep_orphans(st: &Store, current: &str) -> Vec<String> {
    let mut closed = Vec::new();
    for id in st.run_ids() {
        if id == current {
            continue;
        }
        let Some(mut r) = st.read_run(&id) else {
            continue;
        };
        let state = r["state"].as_str().unwrap_or("").to_string();
        if !matches!(
            state.as_str(),
            "PENDING" | "PREFLIGHT" | "RUNNING" | "ROLLING_BACK"
        ) {
            continue;
        }
        let dir = st.run_dir(&id);
        if crate::store::pid_alive(&dir) {
            continue;
        }
        if !dir.join("pid").is_file() {
            let age = std::fs::metadata(dir.join("run.json"))
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            if age < 60_000 {
                continue;
            }
        }
        let pending: Vec<Value> = std::fs::read_to_string(dir.join("undo.ndjson"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|v| v["always"] != true)
            .collect();
        let now = util::now_ms();
        r["finishedAt"] = json!(util::rfc3339(now));
        r["finishedAtMs"] = json!(now);
        r["orphan"] = json!(true);
        if pending.is_empty() {
            r["state"] = json!("FAILED");
            r["code"] = json!("EXEC-06");
        } else {
            r["state"] = json!("ROLLBACK_FAILED");
            r["code"] = json!("ROLLBACK-01");
            let last = pending.last().cloned().unwrap_or(Value::Null);
            let env = r["env"].as_str().unwrap_or("local").to_string();
            let at = (
                last["node"].as_str().unwrap_or("").to_string(),
                last["title"].as_str().unwrap_or("").to_string(),
            );
            hold(st, &env, &id, r["flow"].as_str().unwrap_or(""), &at);
            r["rollback"] = json!({"needed": true, "state": "NOT_RUN", "pending": pending,
                                    "note": tr("엔진이 멈춰 되돌리지 못함 — 환경을 잠갔습니다", "the engine stopped before undoing — the environment is on hold")});
        }
        r["failure"] = crate::codes::failure(r["code"].as_str().unwrap_or(""), "");
        if let Some(o) = r.as_object_mut() {
            o.remove("signature");
        }
        r["signature"] = crate::store::sign(&r)
            .map(Value::String)
            .unwrap_or(Value::Null);
        let _ = st.write_run(&id, &r);
        let _ = std::fs::remove_file(dir.join("pid"));
        closed.push(id);
    }
    closed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(always: bool) -> UndoStep {
        UndoStep {
            title: "u".into(),
            action: UndoAction::Script("true".into()),
            check: None,
            timeout_ms: 1000,
            always,
        }
    }

    #[test]
    fn scope_rules() {
        let ctx = UndoCtx::default();
        let s = [step(false)];
        let changed = [
            Changed {
                node: "deploy-api",
                bad: false,
                steps: &s,
                ctx: &ctx,
            },
            Changed {
                node: "deploy-web",
                bad: true,
                steps: &s,
                ctx: &ctx,
            },
        ];
        // node: only the failed node.
        let c = decide(RollbackScope::Node, false, false, true, &changed, false);
        assert_eq!(c.nodes, vec!["deploy-web"]);
        assert_eq!(c.kept, vec!["deploy-api"]);
        // flow: everything when a changing node fails.
        let c = decide(RollbackScope::Flow, false, false, true, &changed, false);
        assert_eq!(c.nodes, vec!["deploy-api", "deploy-web"]);
        // flow with only a check failing: only with onCheckFailure.
        let ok = [Changed {
            node: "deploy",
            bad: false,
            steps: &s,
            ctx: &ctx,
        }];
        assert!(decide(RollbackScope::Flow, false, false, true, &ok, true)
            .nodes
            .is_empty());
        assert_eq!(
            decide(RollbackScope::Flow, true, false, true, &ok, true).nodes,
            vec!["deploy"]
        );
        // In node scope a failed check does not undo earlier nodes.
        assert!(decide(RollbackScope::Node, true, false, true, &ok, true)
            .nodes
            .is_empty());
        // A cancel undoes everything, a success nothing.
        assert_eq!(
            decide(RollbackScope::Node, false, true, false, &ok, false).nodes,
            vec!["deploy"]
        );
        assert!(decide(RollbackScope::Flow, true, false, false, &ok, false)
            .nodes
            .is_empty());
        // A node with only cleanup steps (always) is not undone.
        let a = [step(true)];
        let only_cleanup = [Changed {
            node: "seed",
            bad: true,
            steps: &a,
            ctx: &ctx,
        }];
        assert!(
            decide(RollbackScope::Flow, true, false, true, &only_cleanup, false)
                .nodes
                .is_empty()
        );
    }

    #[test]
    fn hold_messages() {
        assert_eq!(hold_message("{\"message\": \"locked\"}"), "locked");
        assert_eq!(hold_message("plain reason\n"), "plain reason");
    }
}
