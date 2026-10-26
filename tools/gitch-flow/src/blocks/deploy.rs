//! `deploy.compose` — compose 서비스 하나의 이미지를 바꾼다(이 컴퓨터, 또는 `host:` 로 SSH 원격 docker).
//! ① 지금 떠 있는 이미지를 관측하고(`expectCurrent` 가 있으면 비교 후 교체), ② 새 이미지를 받고,
//! ③ 지금 이미지에 되돌림 태그를 붙여 **바꾸기 전에** 되돌림을 등록한 뒤, ④ 덧붙임 compose 파일로 그 서비스만
//! 바꿔 띄우고(`--no-deps --wait`), ⑤ 새 이미지로 떴는지(S2) · 건강 확인(S1)을 본다.
//! 되돌림 = 되돌림 태그로 다시 바꿔 띄우고 그 이미지로 떴는지 확인. DB 스키마는 되돌리지 않는다(앞으로만).

use super::{observe_outcome, schema, Block, Meta, NodeCx, NodeResult, UndoAction, UndoStep};
use crate::process::ProcSpec;
use crate::util::{shell_quote, tr};
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

pub struct Compose;

fn inputs() -> Value {
    schema(
        json!({
            "file": {"type": "string", "description": "Compose file (default compose.yml or docker-compose.yml)."},
            "project": {"type": "string", "description": "Compose project name (-p)."},
            "service": {"type": "string"},
            "image": {"type": "string", "description": "New image, for example registry/app:${{ git.short }}."},
            "host": {"type": "string", "description": "Remote Docker over SSH: user@host or ssh://user@host."},
            "expectCurrent": {"type": "string", "description": "Refuse unless the running image id or reference is this (compare-and-swap)."},
            "pull": {"type": "boolean", "default": true},
            "wait": {"type": "boolean", "default": true, "description": "Pass --wait so compose waits for health checks."},
            "health": {"type": "object", "properties": {"url": {"type": "string"}, "status": {}, "timeout": {"type": "string", "default": "60s"}}},
        }),
        &["project", "service", "image"],
    )
}

static META: Meta = Meta {
    id: "deploy.compose",
    version: "1.0.0",
    title: ("compose 서비스 배포", "Deploy a compose service"),
    category: "deploy",
    capabilities: &["docker", "network", "outward"],
    env_classes: &[],
    destructive: true,
    outward: true,
    codes: &[
        "DEPLOY-01",
        "DOCKER-01",
        "DOCKER-02",
        "DOCKER-03",
        "VERIFY-01",
        "VERIFY-02",
        "ROLLBACK-01",
    ],
    inputs,
    selects_files: false,
    estimate_ms: 120_000,
};

struct Ctx {
    base: Vec<String>,
    service: String,
}

fn docker(cx: &mut NodeCx, args: &[String], timeout_ms: u64) -> super::Captured {
    let spec = ProcSpec {
        program: crate::docker::bin(),
        args: args.to_vec(),
        cwd: cx.cwd.clone(),
        env: cx.env.clone(),
        clear_env: true,
        timeout_ms: Some(timeout_ms),
        settle_ms: 5000,
    };
    cx.run_proc(&spec)
}

fn first_line(c: &super::Captured) -> Option<String> {
    (c.outcome.exit_code == Some(0))
        .then(|| {
            c.stdout
                .lines()
                .map(|l| l.trim())
                .find(|l| !l.is_empty())
                .map(|s| s.to_string())
        })
        .flatten()
}

impl Ctx {
    fn compose(&self, extra: &[&str]) -> Vec<String> {
        let mut v = self.base.clone();
        v.extend(extra.iter().map(|s| s.to_string()));
        v
    }
    /// 지금 그 서비스의 컨테이너와 이미지 id.
    fn current(&self, cx: &mut NodeCx) -> Option<(String, String, String)> {
        let ps = docker(cx, &self.compose(&["ps", "-q", &self.service]), 60_000);
        let cid = first_line(&ps)?;
        let img = docker(
            cx,
            &[
                "inspect".into(),
                "--format".into(),
                "{{.Image}}|{{.Config.Image}}".into(),
                cid.clone(),
            ],
            30_000,
        );
        let line = first_line(&img)?;
        let (id, r) = line.split_once('|').unwrap_or((line.as_str(), ""));
        Some((cid, id.to_string(), r.to_string()))
    }
}

fn override_yaml(service: &str, image: &str) -> String {
    format!(
        "services:\n  {}:\n    image: {}\n",
        serde_json::to_string(service).unwrap_or_default(),
        serde_json::to_string(image).unwrap_or_default()
    )
}

fn fail(
    r: &mut NodeResult,
    rule: &'static str,
    title: String,
    observed: String,
    expected: String,
    code: &'static str,
) {
    r.verdicts.push(Verdict::new(
        rule,
        title,
        observed,
        expected,
        Outcome::Fail,
        Some(code),
    ));
}

impl Block for Compose {
    fn meta(&self) -> &Meta {
        &META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let mut e = Vec::new();
        for k in ["project", "service", "image"] {
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
        let service = cx.input_str("service").unwrap_or_default();
        let project = cx.input_str("project").unwrap_or_default();
        let image = cx.input_str("image").unwrap_or_default();
        let file = cx.input_str("file").unwrap_or_else(|| {
            [
                "compose.yml",
                "compose.yaml",
                "docker-compose.yml",
                "docker-compose.yaml",
            ]
            .iter()
            .find(|f| cx.cwd.join(f).is_file())
            .unwrap_or(&"compose.yml")
            .to_string()
        });
        if let Some(h) = cx.input_str("host") {
            let h = if h.contains("://") {
                h
            } else {
                format!("ssh://{h}")
            };
            // 되돌림도 같은 대상으로 가게 노드 환경에 둔다.
            cx.env.retain(|(k, _)| k != "DOCKER_HOST");
            cx.env.push(("DOCKER_HOST".into(), h));
        }
        let c = Ctx {
            base: vec![
                "compose".into(),
                "-f".into(),
                file.clone(),
                "-p".into(),
                project.clone(),
            ],
            service: service.clone(),
        };
        // ① 지금 것.
        let before = c.current(cx);
        r.observe("previous", json!(before.as_ref().map(|b| &b.1)));
        if let Some(expect) = cx.input_str("expectCurrent") {
            let ok = before
                .as_ref()
                .map(|(_, id, rf)| id == &expect || rf == &expect)
                .unwrap_or(false);
            if !ok {
                fail(
                    &mut r,
                    "D1",
                    tr("지금 버전", "running version"),
                    before.map(|b| b.1).unwrap_or_else(|| tr("없음", "none")),
                    expect,
                    "DEPLOY-01",
                );
                return r;
            }
        }
        // ② 새 이미지.
        if cx
            .with
            .get("pull")
            .and_then(|p| p.as_bool())
            .unwrap_or(true)
        {
            let p = docker(cx, &["pull".into(), image.clone()], 900_000);
            if p.outcome.exit_code != Some(0) {
                observe_outcome(&mut r, &p);
                let code = super::container::docker_error_code(&p.tail.join("\n"));
                fail(
                    &mut r,
                    "D2",
                    tr("이미지 받기", "image pull"),
                    format!("exit {:?}", p.outcome.exit_code),
                    "0".into(),
                    if code == "DOCKER-03" {
                        "DOCKER-02"
                    } else {
                        code
                    },
                );
                return r;
            }
        }
        let new_id = first_line(&docker(
            cx,
            &[
                "image".into(),
                "inspect".into(),
                "--format".into(),
                "{{.Id}}".into(),
                image.clone(),
            ],
            30_000,
        ));
        let Some(new_id) = new_id else {
            fail(
                &mut r,
                "D2",
                tr("새 이미지", "new image"),
                tr("없음", "missing"),
                image.clone(),
                "DOCKER-02",
            );
            return r;
        };
        r.observe("image", json!(image));
        r.outputs.insert("current".into(), json!(new_id));
        if before.as_ref().map(|b| b.1 == new_id).unwrap_or(false) {
            cx.note(&tr(
                "이미 이 이미지로 떠 있어 바꾸지 않습니다.",
                "already running this image; nothing to change.",
            ));
            r.observe("unchanged", json!(true));
            r.verdicts.push(Verdict::new(
                "S2",
                tr("떠 있는 이미지", "running image"),
                new_id.clone(),
                new_id,
                Outcome::Pass,
                None,
            ));
            return r;
        }
        // ③ 되돌림 등록(바꾸기 전에).
        let out = cx.out_dir.clone();
        let undo_file = out.join("compose.undo.yml");
        let compose_q = |extra: &str| -> String {
            let mut parts: Vec<String> = vec![
                shell_quote(&crate::docker::bin()),
                "compose".into(),
                "-f".into(),
                shell_quote(&file),
                "-p".into(),
                shell_quote(&project),
            ];
            parts.push(extra.to_string());
            parts.join(" ")
        };
        let wait = cx
            .with
            .get("wait")
            .and_then(|w| w.as_bool())
            .unwrap_or(true);
        match &before {
            Some((_, prev_id, _)) => {
                let tag = format!(
                    "gitch-rollback/{}-{}:{}",
                    crate::store::safe(&project).to_ascii_lowercase(),
                    crate::store::safe(&service).to_ascii_lowercase(),
                    crate::store::safe(&cx.run_id).to_ascii_lowercase()
                );
                let t = docker(cx, &["tag".into(), prev_id.clone(), tag.clone()], 30_000);
                if t.outcome.exit_code != Some(0) {
                    fail(
                        &mut r,
                        "D3",
                        tr("되돌림 태그", "rollback tag"),
                        format!("exit {:?}", t.outcome.exit_code),
                        "0".into(),
                        "DOCKER-03",
                    );
                    return r;
                }
                let _ = std::fs::write(&undo_file, override_yaml(&service, &tag));
                let mut args =
                    c.compose(&["-f", &undo_file.to_string_lossy(), "up", "-d", "--no-deps"]);
                // 덧붙임 파일은 앞의 -f 뒤에 와야 한다: compose -f F -p P -f U … 는 허용된다.
                if wait {
                    args.push("--wait".into());
                }
                args.push(service.clone());
                cx.register_undo(UndoStep {
                    title: tr(&format!("{service} 을(를) 이전 이미지로"), &format!("{service} back to the previous image")),
                    action: UndoAction::Argv { program: crate::docker::bin(), args },
                    check: Some(UndoAction::Script(format!(
                        "test \"$({} inspect --format '{{{{.Image}}}}' \"$({} | head -n 1)\")\" = {}",
                        shell_quote(&crate::docker::bin()),
                        compose_q(&format!("ps -q {}", shell_quote(&service))),
                        shell_quote(prev_id)
                    ))),
                    timeout_ms: 5 * 60_000,
                    always: false,
                });
                r.outputs.insert("previous".into(), json!(prev_id));
                r.outputs.insert("rollbackTag".into(), json!(tag));
            }
            None => {
                cx.register_undo(UndoStep {
                    title: tr(
                        &format!("처음 띄운 {service} 내리기"),
                        &format!("remove the first {service}"),
                    ),
                    action: UndoAction::Argv {
                        program: crate::docker::bin(),
                        args: c.compose(&["rm", "-s", "-f", &service]),
                    },
                    check: None,
                    timeout_ms: 5 * 60_000,
                    always: false,
                });
            }
        }
        r.mutated = true;
        // ④ 바꿔 띄우기.
        let over = out.join("compose.override.yml");
        let _ = std::fs::write(&over, override_yaml(&service, &image));
        let mut args = c.compose(&["-f", &over.to_string_lossy(), "up", "-d", "--no-deps"]);
        if wait {
            args.push("--wait".into());
        }
        args.push(service.clone());
        let up = docker(cx, &args, cx.timeout_ms.unwrap_or(600_000));
        observe_outcome(&mut r, &up);
        if up.outcome.exit_code != Some(0) {
            let code = super::container::docker_error_code(&up.tail.join("\n"));
            fail(
                &mut r,
                "D4",
                tr("바꿔 띄우기", "swap"),
                format!("exit {:?}", up.outcome.exit_code),
                "0".into(),
                code,
            );
            return r;
        }
        // ⑤ 새 이미지로 떴는지 · 건강 확인.
        let after = c.current(cx);
        let running = after.as_ref().map(|a| a.1.clone());
        r.verdicts.push(Verdict::new(
            "S2",
            tr("떠 있는 이미지", "running image"),
            running.clone().unwrap_or_else(|| tr("없음", "none")),
            new_id.clone(),
            if running.as_deref() == Some(new_id.as_str()) {
                Outcome::Pass
            } else {
                Outcome::Fail
            },
            Some("VERIFY-02"),
        ));
        if let Some(h) = cx.with.get("health").filter(|h| h.is_object()).cloned() {
            let url = h["url"].as_str().unwrap_or("").to_string();
            let timeout = h["timeout"]
                .as_str()
                .and_then(crate::util::parse_duration)
                .unwrap_or(60_000);
            let want = h.get("status").cloned().unwrap_or(Value::Null);
            let started = Instant::now();
            let mut last: Option<u16> = None;
            let mut err: Option<String>;
            loop {
                match crate::http::send(&crate::http::Req {
                    timeout_ms: 5000,
                    ..crate::http::Req::get(&url)
                }) {
                    Ok(resp) => {
                        last = Some(resp.status);
                        err = None;
                        if crate::verify::status_matches(&want, resp.status) {
                            break;
                        }
                    }
                    Err(e) => err = Some(e),
                }
                if started.elapsed().as_millis() as u64 >= timeout || cx.cancel.is_cancelled() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(1000));
            }
            let mut v = crate::verify::reach(last, 1, &want, err.as_deref());
            v.title = format!("{} {}", v.title, cx.masker.mask(&url));
            r.verdicts.push(v);
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn override_files_quote_values() {
        assert_eq!(
            override_yaml("web", "reg/app:1"),
            "services:\n  \"web\":\n    image: \"reg/app:1\"\n"
        );
    }
}
