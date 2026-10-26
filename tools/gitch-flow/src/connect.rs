//! 연결: Jenkins · GitLab · GitHub · 일반 HTTP CI · 웹훅 의 주소와 인증 참조. 저장소 밖 사용자 설정에 두고
//! (`~/.config/gitsw/flow/connections.json`), 비밀값은 OS 보관소 · 환경변수 · 앱 계정 토큰으로만 꺼낸다.

use crate::cli::{Args, Out};
use crate::util::{self, tr};
use serde_json::{json, Value};
use std::io::{IsTerminal, Read};

pub const KINDS: &[&str] = &["gitlab", "github", "jenkins", "http", "webhook"];

#[derive(Debug, Clone)]
pub struct Connection {
    pub name: String,
    pub kind: String,
    pub url: String,
    pub user: Option<String>,
    pub project: Option<String>,
    /// keystore · env:NAME · app:<계정ID> · gh:<로그인>
    pub secret: String,
    pub allow: Vec<String>,
}

fn path() -> std::path::PathBuf {
    util::gitsw_dir().join("flow").join("connections.json")
}

fn load_all() -> Vec<Value> {
    std::fs::read_to_string(path())
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v["connections"].as_array().cloned())
        .unwrap_or_default()
}

fn save_all(list: &[Value]) -> std::io::Result<()> {
    util::write_atomic(
        &path(),
        serde_json::to_string_pretty(&json!({"schemaVersion": 1, "connections": list}))
            .unwrap_or_default()
            .as_bytes(),
    )
}

fn from_json(v: &Value) -> Option<Connection> {
    Some(Connection {
        name: v["name"].as_str()?.to_string(),
        kind: v["kind"].as_str()?.to_string(),
        url: v["url"]
            .as_str()
            .unwrap_or("")
            .trim_end_matches('/')
            .to_string(),
        user: v["user"].as_str().map(|s| s.to_string()),
        project: v["project"].as_str().map(|s| s.to_string()),
        secret: v["secret"].as_str().unwrap_or("keystore").to_string(),
        allow: v["allow"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default(),
    })
}

pub fn find(name: &str) -> Option<Connection> {
    load_all()
        .iter()
        .filter_map(from_json)
        .find(|c| c.name == name)
}

pub fn list() -> Vec<Connection> {
    load_all().iter().filter_map(from_json).collect()
}

/// 연결의 비밀값. 꺼내면 바로 마스킹 사전에 넣도록 부르는 쪽이 책임진다.
pub fn secret(c: &Connection, ci: bool) -> Option<String> {
    if let Some(v) = crate::secret::resolve(&format!("conn-{}", c.name), ci) {
        return Some(v);
    }
    if let Some(n) = c.secret.strip_prefix("env:") {
        return std::env::var(n).ok().filter(|s| !s.is_empty());
    }
    if let Some(id) = c.secret.strip_prefix("app:") {
        return crate::keystore::app_token(id);
    }
    if let Some(login) = c.secret.strip_prefix("gh:") {
        let gh = std::env::var("GITCH_GH")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "gh".into());
        let spec = crate::process::ProcSpec {
            program: gh,
            args: vec![
                "auth".into(),
                "token".into(),
                "--hostname".into(),
                "github.com".into(),
                "--user".into(),
                login.into(),
            ],
            cwd: std::env::temp_dir(),
            env: vec![],
            clear_env: false,
            timeout_ms: Some(10_000),
            settle_ms: 500,
        };
        let mut tok = String::new();
        let o = crate::process::run(&spec, &crate::process::Cancel::new(), &mut |s, l| {
            if s == crate::process::Stream::Out && tok.is_empty() {
                tok = l.trim().to_string();
            }
        });
        return if o.exit_code == Some(0) && !tok.is_empty() {
            Some(tok)
        } else {
            None
        };
    }
    crate::keystore::get(&format!("conn:{}", c.name))
}

/// 허용 목록에 있는 작업인지. 목록이 비면 모두 허용한다(연결을 만들 때 --allow 로 좁힌다).
pub fn allowed(c: &Connection, job: &str) -> bool {
    c.allow.is_empty() || c.allow.iter().any(|p| util::glob_match(p, job) || p == job)
}

fn to_json(c: &Connection) -> Value {
    json!({"name": c.name, "kind": c.kind, "url": c.url, "user": c.user, "project": c.project, "secret": c.secret, "allow": c.allow})
}

/// 읽기 전용 연결 시험.
pub fn probe(c: &Connection) -> Result<String, (&'static str, String)> {
    let tok = secret(c, true);
    let (url, headers): (String, Vec<(String, String)>) = match c.kind.as_str() {
        "gitlab" => (
            format!("{}/api/v4/user", c.url),
            tok.iter()
                .map(|t| ("PRIVATE-TOKEN".to_string(), t.clone()))
                .collect(),
        ),
        "github" => {
            let api = if c.url.is_empty() || c.url.contains("github.com") && !c.url.contains("api.")
            {
                "https://api.github.com".to_string()
            } else {
                c.url.clone()
            };
            (
                format!("{api}/user"),
                tok.iter()
                    .map(|t| ("Authorization".to_string(), format!("Bearer {t}")))
                    .chain([(
                        "Accept".to_string(),
                        "application/vnd.github+json".to_string(),
                    )])
                    .collect(),
            )
        }
        "jenkins" => {
            let auth = match (&c.user, &tok) {
                (Some(u), Some(t)) => vec![(
                    "Authorization".to_string(),
                    format!("Basic {}", crate::ci::b64(&format!("{u}:{t}"))),
                )],
                (None, Some(t)) => vec![("Authorization".to_string(), format!("Bearer {t}"))],
                _ => vec![],
            };
            (format!("{}/api/json?tree=mode,nodeName", c.url), auth)
        }
        _ => (c.url.clone(), vec![]),
    };
    let req = crate::http::Req {
        method: "GET",
        url: &url,
        headers,
        body: None,
        timeout_ms: 10_000,
        follow_redirects: false,
    };
    match crate::http::send(&req) {
        Ok(r) if r.status < 300 => Ok(format!("HTTP {}", r.status)),
        Ok(r) if r.status == 401 || r.status == 403 => {
            Err(("CONN-02", format!("HTTP {}", r.status)))
        }
        Ok(r) if r.status == 404 => Err(("CONN-04", format!("HTTP {}", r.status))),
        Ok(r) => Err(("CONN-05", format!("HTTP {}", r.status))),
        Err(e) => Err(("CONN-05", e)),
    }
}

pub fn cmd_connect(out: &Out, args: &Args) -> i32 {
    let sub = args.pos.first().map(|s| s.as_str()).unwrap_or("list");
    match sub {
        "list" | "ls" => {
            let l = list();
            if out.json {
                println!("{}", serde_json::to_string_pretty(&json!({"schemaVersion": 1, "connections": l.iter().map(to_json).collect::<Vec<_>>()})).unwrap_or_default());
            } else if l.is_empty() {
                println!("{}", tr("연결이 없습니다. 예: gitch flow connect add jenkins --name ci --url https://jenkins.example.com --user me", "no connections. e.g. gitch flow connect add jenkins --name ci --url https://jenkins.example.com --user me"));
            } else {
                for c in l {
                    println!("{:<18} {:<8} {}  ({})", c.name, c.kind, c.url, c.secret);
                }
            }
            0
        }
        "add" => {
            let Some(kind) = args.pos.get(1).cloned() else {
                return fail(
                    out,
                    "CONN-01",
                    &tr(
                        "종류가 필요합니다(gitlab · github · jenkins · http · webhook).",
                        "a kind is required (gitlab, github, jenkins, http, webhook).",
                    ),
                );
            };
            if !KINDS.contains(&kind.as_str()) {
                return fail(
                    out,
                    "CONN-01",
                    &tr(
                        &format!("모르는 종류: {kind}"),
                        &format!("unknown kind: {kind}"),
                    ),
                );
            }
            let Some(name) = args.val("--name") else {
                return fail(
                    out,
                    "CONN-01",
                    &tr("--name 이 필요합니다.", "--name is required."),
                );
            };
            let url = args.val("--url").unwrap_or_default();
            if url.is_empty() && kind != "github" {
                return fail(
                    out,
                    "CONN-01",
                    &tr("--url 이 필요합니다.", "--url is required."),
                );
            }
            let mut secret_ref = args
                .val("--secret-from")
                .unwrap_or_else(|| "keystore".into());
            if args.has("--secret-stdin")
                || (secret_ref == "keystore" && std::io::stdin().is_terminal())
            {
                let mut buf = String::new();
                if std::io::stdin().is_terminal() {
                    eprint!(
                        "{}",
                        tr(
                            "토큰(입력이 화면에 보입니다. 비우면 저장하지 않음): ",
                            "token (input is visible; leave empty to skip): "
                        )
                    );
                    let _ = std::io::stdin().read_line(&mut buf);
                } else {
                    let _ = std::io::stdin().read_to_string(&mut buf);
                }
                let tok = buf.trim();
                if !tok.is_empty() {
                    if let Err(e) = crate::keystore::set(&format!("conn:{name}"), tok) {
                        return fail(out, "CONN-03", &e);
                    }
                    secret_ref = "keystore".into();
                }
            }
            let c = Connection {
                name: name.clone(),
                kind,
                url: url.trim_end_matches('/').to_string(),
                user: args.val("--user"),
                project: args.val("--project"),
                secret: secret_ref,
                allow: args
                    .val("--allow")
                    .map(|a| {
                        a.split(',')
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                            .collect()
                    })
                    .unwrap_or_default(),
            };
            let mut all: Vec<Value> = load_all()
                .into_iter()
                .filter(|v| v["name"] != name.as_str())
                .collect();
            all.push(to_json(&c));
            if let Err(e) = save_all(&all) {
                return fail(out, "ENGINE-02", &e.to_string());
            }
            if out.json {
                println!("{}", json!({"schemaVersion": 1, "connection": to_json(&c)}));
            } else {
                println!("{}", tr(&format!("✔ 연결 '{name}' 을(를) 저장했습니다. 시험: gitch flow connect test {name}"), &format!("✔ saved connection '{name}'. Test it: gitch flow connect test {name}")));
            }
            0
        }
        "test" => {
            let Some(name) = args.pos.get(1) else {
                return fail(
                    out,
                    "CONN-01",
                    &tr("연결 이름이 필요합니다.", "a connection name is required."),
                );
            };
            let Some(c) = find(name) else {
                return fail(out, "CONN-01", &crate::codes::describe("CONN-01"));
            };
            match probe(&c) {
                Ok(m) => {
                    if out.json {
                        println!(
                            "{}",
                            json!({"schemaVersion": 1, "name": name, "ok": true, "message": m})
                        );
                    } else {
                        println!("✔ {name}: {m}");
                    }
                    0
                }
                Err((code, m)) => {
                    if out.json {
                        println!(
                            "{}",
                            json!({"schemaVersion": 1, "name": name, "ok": false, "code": code, "message": m, "action": crate::codes::action(code)})
                        );
                    } else {
                        println!("✘ {name}: {m}\n  {}", crate::codes::line(code));
                    }
                    1
                }
            }
        }
        "remove" | "rm" => {
            let Some(name) = args.pos.get(1).cloned() else {
                return fail(
                    out,
                    "CONN-01",
                    &tr("연결 이름이 필요합니다.", "a connection name is required."),
                );
            };
            let before = load_all();
            let after: Vec<Value> = before
                .iter()
                .filter(|v| v["name"] != name.as_str())
                .cloned()
                .collect();
            let removed = after.len() != before.len();
            let _ = save_all(&after);
            let _ = crate::keystore::delete(&format!("conn:{name}"));
            if out.json {
                println!("{}", json!({"schemaVersion": 1, "removed": removed}));
            } else {
                println!(
                    "{}",
                    if removed {
                        tr("지웠습니다.", "removed.")
                    } else {
                        tr("그런 연결이 없습니다.", "no such connection.")
                    }
                );
            }
            0
        }
        other => fail(
            out,
            "CONN-01",
            &tr(
                &format!("모르는 하위 명령: {other}"),
                &format!("unknown subcommand: {other}"),
            ),
        ),
    }
}

fn fail(out: &Out, code: &str, msg: &str) -> i32 {
    if out.json {
        eprintln!(
            "{}",
            json!({"schemaVersion": 1, "error": {"code": "GITCH_ERROR", "flowCode": code, "message": msg, "exitCode": 1}})
        );
    } else {
        eprintln!("{msg}");
    }
    1
}
