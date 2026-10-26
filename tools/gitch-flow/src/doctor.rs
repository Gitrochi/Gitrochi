//! `gitch flow doctor`: checks the tools flows use, Docker, trust and held environments. It only looks and changes nothing.

use crate::cli::{Args, Out};
use crate::util::tr;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Finds an executable on PATH (with PATHEXT on Windows).
pub fn which(cmd: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let exts: Vec<String> = if cfg!(windows) {
        std::env::var("PATHEXT")
            .unwrap_or_else(|_| ".EXE;.CMD;.BAT".into())
            .split(';')
            .map(|s| s.to_ascii_lowercase())
            .collect()
    } else {
        vec![String::new()]
    };
    for dir in std::env::split_paths(&path) {
        for e in &exts {
            let p = dir.join(format!("{cmd}{e}"));
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

fn version(cmd: &str, arg: &str) -> Option<String> {
    let spec = crate::process::ProcSpec {
        program: cmd.into(),
        args: vec![arg.into()],
        cwd: std::env::temp_dir(),
        env: vec![],
        clear_env: false,
        timeout_ms: Some(8000),
        settle_ms: 500,
    };
    let mut first = None;
    let o = crate::process::run(&spec, &crate::process::Cancel::new(), &mut |_, l| {
        if first.is_none() && !l.trim().is_empty() {
            first = Some(l.trim().to_string());
        }
    });
    if o.spawn_error.is_some() {
        None
    } else {
        first
    }
}

struct Check {
    id: String,
    level: &'static str,
    code: Option<&'static str>,
    message: String,
}

fn tools_for(block: &str, root: &Path) -> Vec<(&'static str, &'static str)> {
    let node_pm = if root.join("pnpm-lock.yaml").is_file() {
        "pnpm"
    } else if root.join("yarn.lock").is_file() {
        "yarn"
    } else {
        "npx"
    };
    match block {
        "test.vitest" | "test.jest" | "test.playwright" => {
            vec![("node", "--version"), (node_pm, "--version")]
        }
        "test.pytest" => vec![(
            if cfg!(windows) { "python" } else { "python3" },
            "--version",
        )],
        "test.go" => vec![("go", "version")],
        "test.cargo" => vec![("cargo", "--version")],
        "test.gradle" => vec![("java", "-version")],
        "test.maven" => vec![("mvn", "--version")],
        "test.swift" => vec![("swift", "--version")],
        "test.dotnet" => vec![("dotnet", "--version")],
        _ => vec![],
    }
}

/// A short check, attached to the init result.
pub fn quick(root: &Path) -> Value {
    json!({"git": which("git").is_some(), "docker": which(&crate::docker::bin()).is_some(), "node": which("node").is_some(), "bash": crate::process::bash_path(), "flowFile": crate::spec::exists(root)})
}

pub fn cmd_doctor(out: &Out, args: &Args) -> i32 {
    let mut checks: Vec<Check> = Vec::new();
    let Some(root) = crate::cli::repo_root(args) else {
        checks.push(Check {
            id: "repo".into(),
            level: "error",
            code: Some("SPEC-08"),
            message: tr("git 저장소가 아닙니다.", "not a git repository."),
        });
        return finish(out, checks);
    };
    match version("git", "--version") {
        Some(v) => checks.push(Check {
            id: "git".into(),
            level: "ok",
            code: None,
            message: v,
        }),
        None => checks.push(Check {
            id: "git".into(),
            level: "error",
            code: Some("EXEC-04"),
            message: tr("git 을 찾지 못했습니다.", "git was not found."),
        }),
    }
    let bash = crate::process::bash_path();
    match version(&bash, "--version") {
        Some(v) => checks.push(Check { id: "bash".into(), level: "ok", code: None, message: v }),
        None => checks.push(Check { id: "bash".into(), level: "warn", code: Some("EXEC-04"), message: tr("bash 를 찾지 못했습니다(Windows 는 Git for Windows). run: 노드는 shell: pwsh 로 바꿀 수 있습니다.", "bash was not found (on Windows, install Git for Windows). run: nodes can use shell: pwsh.") }),
    }
    match std::env::var("GITCH_PATH") {
        Ok(p) if !p.is_empty() => checks.push(Check { id: "gitch".into(), level: "ok", code: None, message: p }),
        _ => checks.push(Check { id: "gitch".into(), level: "warn", code: None, message: tr("gitch 앞문 없이 실행 중입니다. 영향 선택이 의존 그래프 없이 이름 관례만 씁니다.", "running without the gitch front end; affected selection uses naming conventions only.") }),
    }
    let spec = match crate::spec::load(&root) {
        Ok(s) => {
            checks.push(Check {
                id: "flow-file".into(),
                level: "ok",
                code: None,
                message: tr(
                    &format!("흐름 {}개 · 파일 {}개", s.flows.len(), s.files.len()),
                    &format!("{} flows, {} files", s.flows.len(), s.files.len()),
                ),
            });
            Some(s)
        }
        Err(e) => {
            checks.push(Check {
                id: "flow-file".into(),
                level: "error",
                code: Some(e[0].code),
                message: e[0].human(),
            });
            None
        }
    };
    if let Some(spec) = &spec {
        let t = crate::trust::status(spec);
        if t.trusted {
            let at = t.approved_at.clone().unwrap_or_default();
            checks.push(Check {
                id: "trust".into(),
                level: "ok",
                code: None,
                message: tr(&format!("신뢰함({at})"), &format!("trusted ({at})")),
            });
        } else {
            checks.push(Check {
                id: "trust".into(),
                level: "warn",
                code: Some("TRUST-01"),
                message: tr(
                    &format!("아직 신뢰하지 않음: {}", t.changed.join(", ")),
                    &format!("not trusted yet: {}", t.changed.join(", ")),
                ),
            });
        }
        let mut blocks: Vec<String> = Vec::new();
        for f in &spec.flows {
            if let Ok(p) = crate::plan::build(
                spec,
                &crate::plan::PlanOptions {
                    flow: f.name.clone(),
                    env: args.val("--env"),
                    no_cache: true,
                    ..Default::default()
                },
            ) {
                for n in &p.nodes {
                    if !blocks.contains(&n.block) {
                        blocks.push(n.block.clone());
                    }
                }
            }
        }
        let mut seen: Vec<&str> = Vec::new();
        for b in &blocks {
            for (tool, arg) in tools_for(b, &root) {
                if seen.contains(&tool) {
                    continue;
                }
                seen.push(tool);
                match version(tool, arg) {
                    Some(v) => checks.push(Check {
                        id: tool.into(),
                        level: "ok",
                        code: None,
                        message: v,
                    }),
                    None => checks.push(Check {
                        id: tool.into(),
                        level: "error",
                        code: Some("EXEC-04"),
                        message: tr(
                            &format!("{tool} 을(를) 찾지 못했습니다({b} 가 씀).",),
                            &format!("{tool} was not found (used by {b})."),
                        ),
                    }),
                }
            }
        }
        let needs_docker = spec.services.iter().any(|s| s.uses != "process.service")
            || blocks
                .iter()
                .any(|b| b.starts_with("docker.") || b.starts_with("deploy."));
        if needs_docker {
            match crate::docker::available() {
                Ok(v) => checks.push(Check {
                    id: "docker".into(),
                    level: "ok",
                    code: None,
                    message: format!("Docker {v}"),
                }),
                Err(e) => checks.push(Check {
                    id: "docker".into(),
                    level: "error",
                    code: Some("DOCKER-01"),
                    message: e,
                }),
            }
        }
        if let Some(st) = crate::store::Store::open(&root) {
            if let Ok(rd) = std::fs::read_dir(st.base.join("holds")) {
                for e in rd.flatten() {
                    checks.push(Check {
                        id: format!("hold:{}", e.file_name().to_string_lossy()),
                        level: "error",
                        code: Some("GUARD-02"),
                        message: std::fs::read_to_string(e.path())
                            .unwrap_or_default()
                            .lines()
                            .next()
                            .unwrap_or("")
                            .to_string(),
                    });
                }
            }
        }
        for name in spec
            .environments
            .iter()
            .filter_map(|e| e.connection.clone())
        {
            if crate::connect::find(&name).is_none() {
                checks.push(Check {
                    id: format!("connection:{name}"),
                    level: "warn",
                    code: Some("CONN-01"),
                    message: tr(
                        &format!("연결 '{name}' 이(가) 없습니다(gitch flow connect add …)."),
                        &format!("connection '{name}' does not exist (gitch flow connect add …)."),
                    ),
                });
            }
        }
    }
    finish(out, checks)
}

fn finish(out: &Out, checks: Vec<Check>) -> i32 {
    let errors = checks.iter().filter(|c| c.level == "error").count();
    let warns = checks.iter().filter(|c| c.level == "warn").count();
    let result = if errors > 0 {
        "STOP"
    } else if warns > 0 {
        "WARN"
    } else {
        "OK"
    };
    if out.json {
        let v = json!({"schemaVersion": 1, "result": result, "checks": checks.iter().map(|c| json!({"id": c.id, "level": c.level, "code": c.code, "message": c.message, "action": c.code.map(crate::codes::action)})).collect::<Vec<_>>()});
        println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default());
    } else {
        for c in &checks {
            let m = match c.level {
                "ok" => "✔",
                "warn" => "⚠",
                _ => "✘",
            };
            println!("{m} {:<14} {}", c.id, c.message);
            if c.level != "ok" {
                if let Some(code) = c.code {
                    println!("    {}", crate::codes::line(code));
                }
            }
        }
        println!("DOCTOR={result}");
    }
    if errors > 0 {
        1
    } else {
        0
    }
}
