//! 알림: `notify.webhook` · `notify.desktop` 블록과 흐름 끝의 `notify:` 목록이 함께 쓰는 보내기.
//! 알림은 실행 결과를 바꾸지 않는다 — 보내지 못해도 판정은 통과로 두고 관측값에 오류를 남긴다.
//! 웹훅 주소는 연결(kind: webhook)에 두면 주소 · 토큰이 흐름 파일과 기록에 남지 않는다.

use super::{schema, Block, Meta, NodeCx, NodeResult};
use crate::http::{self, Req};
use crate::util::tr;
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};

pub struct Webhook;
pub struct Desktop;

/// 웹훅 대상: 연결 이름(kind webhook) 또는 https 주소.
pub fn send_webhook(
    target: &str,
    text: &str,
    data: &Value,
    masker: &crate::mask::Masker,
    ci: bool,
) -> Result<u16, String> {
    let (url, auth) = match crate::connect::find(target) {
        Some(c) => {
            let tok = crate::connect::secret(&c, ci);
            if let Some(t) = &tok {
                masker.add_secret(&format!("conn-{}", c.name), t);
            }
            (c.url.clone(), tok.map(|t| format!("Bearer {t}")))
        }
        None if target.starts_with("https://")
            || target.starts_with("http://127.0.0.1")
            || target.starts_with("http://localhost") =>
        {
            (target.to_string(), None)
        }
        None => {
            return Err(tr(
                &format!("웹훅 '{target}' 은(는) 연결 이름도 https 주소도 아닙니다."),
                &format!("webhook '{target}' is neither a connection name nor an https address."),
            ))
        }
    };
    masker.add_secret("webhook-url", &url);
    // Slack · Teams · Mattermost 는 text 를, 다른 곳은 data 를 읽는다.
    let body = json!({"text": text, "data": data});
    let mut req = Req {
        method: "POST",
        body: Some(body.to_string()),
        timeout_ms: 15_000,
        ..Req::get(&url).header("Content-Type", "application/json")
    };
    if let Some(a) = &auth {
        req.headers.push(("Authorization".into(), a.clone()));
    }
    match http::send(&req) {
        Ok(r) if r.status < 300 => Ok(r.status),
        Ok(r) => Err(format!("HTTP {}", r.status)),
        Err(e) => Err(masker.mask(&e)),
    }
}

/// 데스크톱 알림(macOS · Linux). Windows 는 앱이 이벤트로 알린다.
pub fn send_desktop(title: &str, text: &str) -> Result<(), String> {
    let clean = |s: &str| s.replace(['"', '\\', '\n'], " ");
    let (prog, args): (&str, Vec<String>) = if cfg!(target_os = "macos") {
        (
            "osascript",
            vec![
                "-e".into(),
                format!(
                    "display notification \"{}\" with title \"{}\"",
                    clean(text),
                    clean(title)
                ),
            ],
        )
    } else if cfg!(target_os = "linux") {
        ("notify-send", vec![title.to_string(), text.to_string()])
    } else {
        return Err(tr(
            "이 운영체제에서는 앱 알림을 쓰세요.",
            "use the app's notifications on this OS.",
        ));
    };
    let o = std::process::Command::new(prog)
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("{prog}: {e}"))?;
    if o.success() {
        Ok(())
    } else {
        Err(format!("{prog}: {o}"))
    }
}

fn webhook_inputs() -> Value {
    schema(
        json!({"to": {"type": "string", "description": "Connection name (kind webhook) or an https address."},
               "message": {"type": "string"}, "data": {"type": "object"}}),
        &["to", "message"],
    )
}

fn desktop_inputs() -> Value {
    schema(
        json!({"title": {"type": "string"}, "message": {"type": "string"}}),
        &["message"],
    )
}

static WEBHOOK_META: Meta = Meta {
    id: "notify.webhook",
    version: "1.0.0",
    title: ("웹훅 알림", "Webhook notification"),
    category: "notify",
    capabilities: &["network", "outward"],
    env_classes: &[],
    destructive: false,
    outward: true,
    codes: &[],
    inputs: webhook_inputs,
    selects_files: false,
    estimate_ms: 2_000,
};

static DESKTOP_META: Meta = Meta {
    id: "notify.desktop",
    version: "1.0.0",
    title: ("데스크톱 알림", "Desktop notification"),
    category: "notify",
    capabilities: &[],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &[],
    inputs: desktop_inputs,
    selects_files: false,
    estimate_ms: 500,
};

fn delivered(r: &mut NodeResult, res: Result<String, String>) {
    let (ok, detail) = match res {
        Ok(d) => (true, d),
        Err(e) => (false, e),
    };
    r.observe("delivered", json!(ok));
    r.observe("detail", json!(detail));
    // 알림은 결과를 바꾸지 않는다.
    r.verdicts.push(Verdict::new(
        "N1",
        tr("알림", "notification"),
        if ok {
            tr("보냄", "sent")
        } else {
            format!("{}: {detail}", tr("보내지 못함", "not sent"))
        },
        "-".into(),
        Outcome::Pass,
        None,
    ));
}

impl Block for Webhook {
    fn meta(&self) -> &Meta {
        &WEBHOOK_META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let to = cx.input_str("to").unwrap_or_default();
        let msg = cx.input_str("message").unwrap_or_default();
        let data = cx.with.get("data").cloned().unwrap_or(json!({}));
        let res = send_webhook(&to, &msg, &data, cx.masker, cx.ci).map(|s| format!("HTTP {s}"));
        delivered(&mut r, res);
        r
    }
}

impl Block for Desktop {
    fn meta(&self) -> &Meta {
        &DESKTOP_META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let title = cx.input_str("title").unwrap_or_else(|| "gitch flow".into());
        let msg = cx.input_str("message").unwrap_or_default();
        delivered(&mut r, send_desktop(&title, &msg).map(|_| "ok".to_string()));
        r
    }
}
