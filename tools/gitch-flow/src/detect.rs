//! `gitch flow init`: 프로젝트 파일을 읽기만 해서(실행하지 않음) 테스트 · 도구를 감지하고 흐름 파일을 제안한다.
//! 감지마다 근거(파일:줄)와 확신도를 남긴다. 기존 파일은 묻지 않고 덮어쓰지 않는다.

use crate::cli::{Args, Out};
use crate::util::tr;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Finding {
    pub kind: String,
    pub evidence: String,
    pub confidence: &'static str,
    pub note: String,
}

#[derive(Debug, Clone, Default)]
struct Proposal {
    findings: Vec<Finding>,
    setup: Vec<(String, String, String)>,
    suites: Vec<SuiteP>,
    checks: Vec<(String, String)>,
    services: Vec<String>,
    commented: Vec<String>,
    ci_files: Vec<String>,
}

#[derive(Debug, Clone)]
struct SuiteP {
    name: String,
    uses: String,
    cwd: Option<String>,
    affected: bool,
    run: Option<String>,
    report: Option<String>,
    tags: Vec<String>,
    in_prepush: bool,
}

fn read(p: &Path) -> Option<String> {
    std::fs::read_to_string(p).ok()
}

/// 글에서 처음 나오는 줄 번호(1부터).
fn line_of(text: &str, needle: &str) -> usize {
    text.lines()
        .position(|l| l.contains(needle))
        .map(|i| i + 1)
        .unwrap_or(1)
}

fn ev(root: &Path, p: &Path, text: &str, needle: &str) -> String {
    format!(
        "{}:{}",
        crate::util::rel_slash(root, p),
        line_of(text, needle)
    )
}

fn rel(root: &Path, p: &Path) -> String {
    crate::util::rel_slash(root, p)
}

fn pm_install(dir: &Path, root: &Path) -> (&'static str, &'static str) {
    for d in [dir, root] {
        if d.join("pnpm-lock.yaml").is_file() {
            return ("pnpm", "pnpm install --frozen-lockfile");
        }
        if d.join("yarn.lock").is_file() {
            return ("yarn", "yarn install --immutable");
        }
        if d.join("bun.lockb").is_file() || d.join("bun.lock").is_file() {
            return ("bun", "bun install --frozen-lockfile");
        }
        if d.join("package-lock.json").is_file() {
            return ("npm", "npm ci");
        }
    }
    ("npm", "npm install")
}

/// 워크스페이스 패키지 폴더(pnpm-workspace.yaml · package.json workspaces). 단순 glob(`packages/*`)만 펼친다.
fn workspace_dirs(root: &Path) -> Vec<PathBuf> {
    let mut pats: Vec<String> = Vec::new();
    if let Some(t) = read(&root.join("pnpm-workspace.yaml")) {
        if let Ok(d) = crate::yaml::parse(&t) {
            if let Some(a) = d.value["packages"].as_array() {
                pats.extend(a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())));
            }
        }
    }
    if let Some(t) = read(&root.join("package.json")) {
        if let Ok(v) = serde_json::from_str::<Value>(&t) {
            let ws = if v["workspaces"].is_array() {
                v["workspaces"].clone()
            } else {
                v["workspaces"]["packages"].clone()
            };
            if let Some(a) = ws.as_array() {
                pats.extend(a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())));
            }
        }
    }
    let mut out = Vec::new();
    for p in pats {
        if p.starts_with('!') {
            continue;
        }
        let base = p.trim_end_matches("/**").trim_end_matches("/*");
        if p.ends_with("/*") || p.ends_with("/**") {
            if let Ok(rd) = std::fs::read_dir(root.join(base)) {
                for e in rd.flatten() {
                    if e.path().join("package.json").is_file() {
                        out.push(e.path());
                    }
                }
            }
        } else if root.join(&p).join("package.json").is_file() {
            out.push(root.join(&p));
        }
    }
    out.sort();
    out.dedup();
    out
}

fn detect_node(root: &Path, p: &mut Proposal) {
    let mut dirs = vec![root.to_path_buf()];
    dirs.extend(workspace_dirs(root));
    let mut installed = false;
    for dir in dirs {
        let pj = dir.join("package.json");
        let Some(text) = read(&pj) else { continue };
        let Ok(v) = serde_json::from_str::<Value>(&text) else {
            p.findings.push(Finding {
                kind: "node".into(),
                evidence: rel(root, &pj),
                confidence: "low",
                note: tr("package.json 을 읽지 못함", "could not parse package.json"),
            });
            continue;
        };
        let is_root = dir == root;
        let cwd = if is_root { None } else { Some(rel(root, &dir)) };
        let label = cwd.clone().map(|c| c.replace('/', "-")).unwrap_or_default();
        let dep = |name: &str| {
            v["devDependencies"].get(name).is_some() || v["dependencies"].get(name).is_some()
        };
        let scripts = v["scripts"].as_object().cloned().unwrap_or_default();
        let (pm, install) = pm_install(&dir, root);
        if !installed && (is_root || !root.join("package.json").is_file()) {
            p.findings.push(Finding {
                kind: "node".into(),
                evidence: ev(root, &pj, &text, "\"name\""),
                confidence: "high",
                note: pm.to_string(),
            });
            p.setup
                .push(("install".into(), install.into(), "package.json".into()));
            installed = true;
        }
        let suffix = |base: &str| {
            if label.is_empty() {
                base.to_string()
            } else {
                format!("{base}-{label}")
            }
        };
        if dep("vitest") {
            p.findings.push(Finding {
                kind: "vitest".into(),
                evidence: ev(root, &pj, &text, "\"vitest\""),
                confidence: "high",
                note: String::new(),
            });
            p.suites.push(SuiteP {
                name: suffix("unit"),
                uses: "test.vitest".into(),
                cwd: cwd.clone(),
                affected: true,
                run: None,
                report: None,
                tags: vec!["unit".into()],
                in_prepush: true,
            });
        } else if dep("jest")
            || scripts
                .get("test")
                .and_then(|s| s.as_str())
                .map(|s| s.contains("jest"))
                .unwrap_or(false)
        {
            p.findings.push(Finding {
                kind: "jest".into(),
                evidence: ev(root, &pj, &text, "jest"),
                confidence: "high",
                note: String::new(),
            });
            p.suites.push(SuiteP {
                name: suffix("unit"),
                uses: "test.jest".into(),
                cwd: cwd.clone(),
                affected: true,
                run: None,
                report: None,
                tags: vec!["unit".into()],
                in_prepush: true,
            });
        } else if dep("mocha") {
            p.findings.push(Finding {
                kind: "mocha".into(),
                evidence: ev(root, &pj, &text, "\"mocha\""),
                confidence: "medium",
                note: tr("TAP 보고서로 읽음", "read through the TAP reporter"),
            });
            p.suites.push(SuiteP {
                name: suffix("unit"),
                uses: "test.tap".into(),
                cwd: cwd.clone(),
                affected: false,
                run: Some("npx --no-install mocha --reporter tap".into()),
                report: None,
                tags: vec!["unit".into()],
                in_prepush: true,
            });
        } else if let Some(t) = scripts.get("test").and_then(|s| s.as_str()) {
            if !t.contains("no test specified") {
                p.findings.push(Finding { kind: "npm-test".into(), evidence: ev(root, &pj, &text, "\"test\""), confidence: "low", note: tr("보고서 형식을 몰라 종료 코드만 봅니다. 가능하면 JUnit 보고서를 남기게 바꾸세요.", "the report format is unknown, so only the exit code is checked. Prefer a JUnit report.") });
                p.checks.push((suffix("test"), format!("{pm} test")));
            }
        }
        if dep("@playwright/test") {
            p.findings.push(Finding {
                kind: "playwright".into(),
                evidence: ev(root, &pj, &text, "@playwright/test"),
                confidence: "high",
                note: String::new(),
            });
            p.suites.push(SuiteP {
                name: suffix("e2e"),
                uses: "test.playwright".into(),
                cwd: cwd.clone(),
                affected: false,
                run: None,
                report: None,
                tags: vec!["e2e".into()],
                in_prepush: false,
            });
        }
        for (script, node) in [
            ("lint", "lint"),
            ("typecheck", "typecheck"),
            ("type-check", "typecheck"),
        ] {
            if scripts.contains_key(script) {
                let cmd = match &cwd {
                    Some(c) => format!("cd {} && {pm} run {script}", crate::util::shell_quote(c)),
                    None => format!("{pm} run {script}"),
                };
                p.checks.push((suffix(node), cmd));
            }
        }
    }
}

fn detect_python(root: &Path, p: &mut Proposal) {
    let pyproject = root.join("pyproject.toml");
    let mut evidence = None;
    if let Some(t) = read(&pyproject) {
        if t.contains("[tool.pytest") || t.contains("pytest") {
            evidence = Some(ev(root, &pyproject, &t, "pytest"));
        }
        if t.contains("[tool.uv]") || root.join("uv.lock").is_file() {
            p.setup
                .push(("install-python".into(), "uv sync".into(), "uv.lock".into()));
        } else if root.join("poetry.lock").is_file() {
            p.setup.push((
                "install-python".into(),
                "poetry install".into(),
                "poetry.lock".into(),
            ));
        }
    }
    for f in ["pytest.ini", "tox.ini", "setup.cfg"] {
        let path = root.join(f);
        if let Some(t) = read(&path) {
            if t.contains("pytest") && evidence.is_none() {
                evidence = Some(ev(root, &path, &t, "pytest"));
            }
        }
    }
    if evidence.is_none() {
        for f in [
            "requirements-dev.txt",
            "requirements.txt",
            "requirements-test.txt",
        ] {
            let path = root.join(f);
            if let Some(t) = read(&path) {
                if t.contains("pytest") {
                    evidence = Some(ev(root, &path, &t, "pytest"));
                    p.commented.push(format!(
                        "# install-python: {{ run: python3 -m pip install -r {f} }}   # {}",
                        tr("가상환경에서 쓰세요", "use a virtual environment")
                    ));
                }
            }
        }
    }
    if evidence.is_none() && root.join("tests").is_dir() {
        let has = std::fs::read_dir(root.join("tests"))
            .map(|rd| {
                rd.flatten()
                    .any(|e| e.file_name().to_string_lossy().starts_with("test_"))
            })
            .unwrap_or(false);
        if has {
            evidence = Some("tests/".into());
        }
    }
    if let Some(e) = evidence {
        p.findings.push(Finding {
            kind: "pytest".into(),
            evidence: e,
            confidence: "high",
            note: String::new(),
        });
        p.suites.push(SuiteP {
            name: "pytest".into(),
            uses: "test.pytest".into(),
            cwd: None,
            affected: true,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
    }
}

fn detect_simple(root: &Path, p: &mut Proposal) {
    if let Some(t) = read(&root.join("go.mod")) {
        p.findings.push(Finding {
            kind: "go".into(),
            evidence: ev(root, &root.join("go.mod"), &t, "module"),
            confidence: "high",
            note: String::new(),
        });
        p.suites.push(SuiteP {
            name: "go".into(),
            uses: "test.go".into(),
            cwd: None,
            affected: true,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
        p.checks.push(("vet".into(), "go vet ./...".into()));
    }
    if let Some(t) = read(&root.join("Cargo.toml")) {
        p.findings.push(Finding {
            kind: "rust".into(),
            evidence: ev(root, &root.join("Cargo.toml"), &t, "["),
            confidence: "high",
            note: String::new(),
        });
        p.suites.push(SuiteP {
            name: "cargo".into(),
            uses: "test.cargo".into(),
            cwd: None,
            affected: false,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
        p.commented
            .push("# clippy: { run: cargo clippy --all-targets -- -D warnings }".into());
    }
    if root.join("gradlew").is_file()
        || root.join("build.gradle").is_file()
        || root.join("build.gradle.kts").is_file()
    {
        let f = if root.join("build.gradle.kts").is_file() {
            "build.gradle.kts"
        } else {
            "build.gradle"
        };
        p.findings.push(Finding {
            kind: "gradle".into(),
            evidence: format!("{f}:1"),
            confidence: "high",
            note: String::new(),
        });
        p.suites.push(SuiteP {
            name: "gradle".into(),
            uses: "test.gradle".into(),
            cwd: None,
            affected: false,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
    } else if root.join("pom.xml").is_file() {
        p.findings.push(Finding {
            kind: "maven".into(),
            evidence: "pom.xml:1".into(),
            confidence: "high",
            note: String::new(),
        });
        p.suites.push(SuiteP {
            name: "maven".into(),
            uses: "test.maven".into(),
            cwd: None,
            affected: false,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
    }
    if let Some(t) = read(&root.join("Package.swift")) {
        p.findings.push(Finding {
            kind: "swift".into(),
            evidence: ev(root, &root.join("Package.swift"), &t, "Package("),
            confidence: if t.contains("testTarget") {
                "high"
            } else {
                "medium"
            },
            note: tr(
                "swift test 를 씁니다(매니페스트는 실행하지 않음)",
                "uses swift test (the manifest is not executed)",
            ),
        });
        p.suites.push(SuiteP {
            name: "swift".into(),
            uses: "test.swift".into(),
            cwd: None,
            affected: false,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
    }
    let has_xcode = std::fs::read_dir(root)
        .map(|rd| {
            rd.flatten().any(|e| {
                e.file_name().to_string_lossy().ends_with(".xcodeproj")
                    || e.file_name().to_string_lossy().ends_with(".xcworkspace")
            })
        })
        .unwrap_or(false);
    if has_xcode {
        p.findings.push(Finding { kind: "xcode".into(), evidence: tr("*.xcodeproj", "*.xcodeproj"), confidence: "medium", note: tr("xcodebuild 실행기는 아직 없어 test.junit 과 xcpretty 같은 JUnit 출력으로 연결하세요", "there is no xcodebuild runner yet; connect it through test.junit with a JUnit producer") });
    }
    let dotnet = std::fs::read_dir(root)
        .map(|rd| {
            rd.flatten().any(|e| {
                let n = e.file_name().to_string_lossy().to_string();
                n.ends_with(".sln") || n.ends_with(".csproj")
            })
        })
        .unwrap_or(false);
    if dotnet {
        p.findings.push(Finding {
            kind: "dotnet".into(),
            evidence: "*.sln".into(),
            confidence: "high",
            note: String::new(),
        });
        p.suites.push(SuiteP {
            name: "dotnet".into(),
            uses: "test.dotnet".into(),
            cwd: None,
            affected: false,
            run: None,
            report: None,
            tags: vec!["unit".into()],
            in_prepush: true,
        });
    }
    if p.suites.is_empty() {
        if let Some(t) = read(&root.join("Makefile")) {
            if t.lines().any(|l| l.starts_with("test:")) {
                p.findings.push(Finding {
                    kind: "make".into(),
                    evidence: ev(root, &root.join("Makefile"), &t, "test:"),
                    confidence: "low",
                    note: tr("종료 코드만 봅니다", "only the exit code is checked"),
                });
                p.checks.push(("test".into(), "make test".into()));
            }
        }
    }
    for f in [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ] {
        if root.join(f).is_file() {
            p.findings.push(Finding {
                kind: "compose".into(),
                evidence: format!("{f}:1"),
                confidence: "medium",
                note: tr(
                    "통합 테스트용 서비스 후보(기본은 꺼 둠)",
                    "service candidate for integration tests (off by default)",
                ),
            });
            p.services.push(f.to_string());
            break;
        }
    }
    for f in [".github/workflows", ".gitlab-ci.yml", "Jenkinsfile"] {
        if root.join(f).exists() {
            p.ci_files.push(f.to_string());
            p.findings.push(Finding {
                kind: "ci".into(),
                evidence: f.into(),
                confidence: "high",
                note: tr(
                    "gitch flow import 로 흐름 제안을 받을 수 있습니다",
                    "gitch flow import can propose flows from it",
                ),
            });
        }
    }
}

fn yaml_str(s: &str) -> String {
    if s.is_empty()
        || s.contains([
            '#', ':', '{', '}', '[', ']', ',', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`',
        ])
        || s.starts_with(' ')
        || s.ends_with(' ')
    {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

fn render(root: &Path, p: &Proposal) -> String {
    let name = root
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".into());
    let mut y = String::new();
    y.push_str(&format!(
        "# {}\n# {}\nversion: 1\nproject:\n  name: {}\n",
        tr(
            "gitch flow init 이 만든 흐름 파일입니다. 손으로 고쳐도 됩니다.",
            "Created by gitch flow init. Edit it freely."
        ),
        tr(
            "문서: gitch flow help · 블록 목록: gitch flow blocks",
            "Docs: gitch flow help · blocks: gitch flow blocks"
        ),
        yaml_str(&name)
    ));
    if !p.findings.is_empty() {
        y.push_str("  detected:\n");
        for f in &p.findings {
            y.push_str(&format!(
                "    - {{ kind: {}, evidence: {}, confidence: {} }}\n",
                yaml_str(&f.kind),
                yaml_str(&f.evidence),
                f.confidence
            ));
        }
    }
    y.push_str("\ndefaults:\n  timeout: 15m\n");
    if !p.services.is_empty() {
        y.push_str(&format!("\n# {}\n# services:\n#   stack:\n#     use: compose.up\n#     with: {{ file: {}, wait: true }}\n", tr("통합 테스트에 쓰려면 주석을 푸세요(Docker 필요).", "Uncomment to use in integration tests (needs Docker)."), p.services[0]));
    }
    if !p.suites.is_empty() {
        y.push_str("\nsuites:\n");
        for s in &p.suites {
            y.push_str(&format!("  {}:\n    use: {}\n", s.name, s.uses));
            let mut with = Vec::new();
            if let Some(c) = &s.cwd {
                with.push(format!("cwd: {}", yaml_str(c)));
            }
            if let Some(r) = &s.run {
                with.push(format!("run: {}", yaml_str(r)));
            }
            if let Some(r) = &s.report {
                with.push(format!("report: {}", yaml_str(r)));
            }
            if !with.is_empty() {
                y.push_str(&format!("    with: {{ {} }}\n", with.join(", ")));
            }
            if s.affected {
                y.push_str(&format!(
                    "    select: {{ affected: true }}   # {}\n",
                    tr(
                        "영향받은 테스트만(확신 못 하면 전체)",
                        "affected tests only (all when unsure)"
                    )
                ));
            }
            y.push_str("    expect: { minTests: 1, passRate: 1.0 }\n");
            if !s.tags.is_empty() {
                y.push_str(&format!("    tags: [{}]\n", s.tags.join(", ")));
            }
        }
    }
    y.push_str("\nflows:\n");
    let mut flow = |name: &str, desc: &str, trigger: &str, prepush_only: bool, all: bool| {
        y.push_str(&format!(
            "  {name}:\n    description: {}\n    trigger: [{trigger}]\n",
            yaml_str(desc)
        ));
        if prepush_only {
            y.push_str("    failFast: true\n");
        }
        y.push_str("    nodes:\n");
        let mut setup_ids = Vec::new();
        for (id, cmd, input) in &p.setup {
            y.push_str(&format!(
                "      {id}: {{ run: {}, cache: {{ inputs: [{}] }} }}\n",
                yaml_str(cmd),
                yaml_str(input)
            ));
            setup_ids.push(id.clone());
        }
        let needs = if setup_ids.is_empty() {
            String::new()
        } else {
            format!("needs: [{}], ", setup_ids.join(", "))
        };
        for (id, cmd) in &p.checks {
            y.push_str(&format!(
                "      {id}: {{ {needs}run: {} }}\n",
                yaml_str(cmd)
            ));
        }
        for s in p.suites.iter().filter(|s| all || s.in_prepush) {
            y.push_str(&format!(
                "      {}: {{ {needs}suite: {} }}\n",
                s.name, s.name
            ));
        }
        if setup_ids.is_empty()
            && p.checks.is_empty()
            && !p.suites.iter().any(|s| all || s.in_prepush)
        {
            y.push_str(&format!(
                "      hello: {{ run: \"echo {}\" }}\n",
                tr(
                    "테스트 명령을 여기에 연결하세요",
                    "connect your test command here"
                )
            ));
        }
    };
    flow(
        "pre-push",
        &tr(
            "push 전에 빠르게(영향받은 테스트)",
            "quick check before push (affected tests)",
        ),
        "manual, pre-push",
        true,
        false,
    );
    flow(
        "full",
        &tr("전체 테스트", "all tests"),
        "manual, ci",
        false,
        true,
    );
    if !p.commented.is_empty() {
        y.push_str(&format!(
            "\n# {}\n",
            tr(
                "제안(필요하면 노드로 옮기세요):",
                "Suggestions (move them into nodes if useful):"
            )
        ));
        for c in &p.commented {
            y.push_str(&format!("{c}\n"));
        }
    }
    y
}

pub fn propose(root: &Path) -> (Value, String) {
    let mut p = Proposal::default();
    detect_node(root, &mut p);
    detect_python(root, &mut p);
    detect_simple(root, &mut p);
    let yaml = render(root, &p);
    let findings: Vec<Value> = p.findings.iter().map(|f| json!({"kind": f.kind, "evidence": f.evidence, "confidence": f.confidence, "note": f.note})).collect();
    let commands: Vec<Value> = p
        .setup
        .iter()
        .map(|(id, c, _)| json!({"node": id, "run": c}))
        .chain(p.checks.iter().map(|(id, c)| json!({"node": id, "run": c})))
        .chain(
            p.suites
                .iter()
                .map(|s| json!({"node": s.name, "use": s.uses, "run": s.run})),
        )
        .collect();
    (
        json!({"findings": findings, "commands": commands, "ciFiles": p.ci_files, "suites": p.suites.len()}),
        yaml,
    )
}

pub fn cmd_init(out: &Out, args: &Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return fail(
            out,
            "SPEC-08",
            &tr(
                "git 저장소 안에서 실행하세요.",
                "run this inside a git repository.",
            ),
        );
    };
    let (info, yaml) = propose(&root);
    // 제안이 실제로 읽히는지 스스로 검사한다(파서 · 검증과 같은 길).
    let parsed_ok = crate::yaml::parse(&yaml).is_ok();
    let target = root.join(".gitch").join("flow.yml");
    let exists = crate::spec::exists(&root);
    let dry = args.has("--dry-run") || !args.has("--yes");
    let doctor = crate::doctor::quick(&root);
    let result = json!({
        "schemaVersion": 1,
        "root": root.to_string_lossy(),
        "path": ".gitch/flow.yml",
        "exists": exists,
        "written": false,
        "valid": parsed_ok,
        "findings": info["findings"],
        "commands": info["commands"],
        "ciFiles": info["ciFiles"],
        "doctor": doctor,
        "yaml": yaml,
    });
    if dry {
        if out.json {
            println!(
                "{}",
                serde_json::to_string_pretty(&result).unwrap_or_default()
            );
        } else {
            println!(
                "{}",
                tr("감지 결과(파일만 읽음):", "Detected (files read only):")
            );
            for f in info["findings"].as_array().cloned().unwrap_or_default() {
                println!(
                    "  • {:<10} {}  [{}] {}",
                    f["kind"].as_str().unwrap_or(""),
                    f["evidence"].as_str().unwrap_or(""),
                    f["confidence"].as_str().unwrap_or(""),
                    f["note"].as_str().unwrap_or("")
                );
            }
            println!(
                "\n{}\n",
                tr("제안하는 .gitch/flow.yml:", "Proposed .gitch/flow.yml:")
            );
            println!("{yaml}");
            if exists {
                println!("{}", tr("⚠ 이미 흐름 파일이 있어 쓰지 않습니다. 위 제안을 직접 합치세요.", "⚠ a flow file already exists, so nothing was written. Merge the proposal by hand."));
            } else {
                println!(
                    "{}",
                    tr(
                        "쓰려면: gitch flow init --yes",
                        "to write it: gitch flow init --yes"
                    )
                );
            }
        }
        return 0;
    }
    if exists && !args.has("--force") {
        return fail(
            out,
            "SPEC-03",
            &tr(
                "이미 흐름 파일이 있습니다. 덮어쓰지 않습니다(바꾸려면 --force).",
                "a flow file already exists and was not overwritten (use --force to replace it).",
            ),
        );
    }
    if let Err(e) = crate::util::write_atomic(&target, yaml.as_bytes()) {
        return fail(out, "ENGINE-02", &e.to_string());
    }
    let mut gitignore_added = false;
    let gi = root.join(".gitignore");
    let entry = ".gitch/flow.local.yml";
    let cur = std::fs::read_to_string(&gi).unwrap_or_default();
    if !cur.lines().any(|l| l.trim() == entry) {
        let mut s = cur.clone();
        if !s.is_empty() && !s.ends_with('\n') {
            s.push('\n');
        }
        s.push_str(&format!(
            "# {}\n{entry}\n",
            tr(
                "gitch flow: 기계마다 다른 흐름 설정",
                "gitch flow: machine-specific flow settings"
            )
        ));
        gitignore_added = std::fs::write(&gi, s).is_ok();
    }
    let mut r = result;
    r["written"] = json!(true);
    r["gitignoreUpdated"] = json!(gitignore_added);
    if out.json {
        println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
    } else {
        println!(
            "{}",
            tr(
                "✔ .gitch/flow.yml 을 만들었습니다. 확인한 뒤 커밋하세요.",
                "✔ created .gitch/flow.yml. Review it, then commit it."
            )
        );
        if gitignore_added {
            println!(
                "{}",
                tr(
                    "  .gitignore 에 .gitch/flow.local.yml 을 더했습니다.",
                    "  added .gitch/flow.local.yml to .gitignore."
                )
            );
        }
        println!(
            "{}",
            tr(
                "  다음: gitch flow plan pre-push → gitch flow run pre-push",
                "  next: gitch flow plan pre-push → gitch flow run pre-push"
            )
        );
    }
    0
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(files: &[(&str, &str)]) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gf-detect-{}", crate::util::random_hex(4)));
        for (p, c) in files {
            let path = d.join(p);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, c).unwrap();
        }
        d
    }

    #[test]
    fn node_vitest_project() {
        let d = tmp(&[("package.json", "{\n  \"name\": \"demo\",\n  \"scripts\": {\"lint\": \"eslint .\"},\n  \"devDependencies\": {\n    \"vitest\": \"^2\"\n  }\n}\n"), ("package-lock.json", "{}")]);
        let (info, yaml) = propose(&d);
        let kinds: Vec<&str> = info["findings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["kind"].as_str().unwrap())
            .collect();
        assert!(kinds.contains(&"vitest"));
        assert!(info["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["evidence"] == "package.json:5"));
        assert!(yaml.contains("use: test.vitest"));
        assert!(yaml.contains("npm ci"));
        assert!(yaml.contains("lint"));
        let doc = crate::yaml::parse(&yaml).unwrap();
        assert_eq!(doc.value["version"], 1);
        assert!(doc.value["flows"]["pre-push"]["nodes"]["unit"].is_object());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn python_go_and_empty_projects() {
        let d = tmp(&[
            (
                "pyproject.toml",
                "[project]\nname='x'\n[tool.pytest.ini_options]\naddopts='-q'\n",
            ),
            ("go.mod", "module example.com/x\n"),
        ]);
        let (info, yaml) = propose(&d);
        let kinds: Vec<String> = info["findings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["kind"].as_str().unwrap().to_string())
            .collect();
        assert!(kinds.contains(&"pytest".to_string()) && kinds.contains(&"go".to_string()));
        assert!(yaml.contains("test.pytest") && yaml.contains("test.go"));
        crate::yaml::parse(&yaml).unwrap();
        let e = tmp(&[("README.md", "hi")]);
        let (_, y2) = propose(&e);
        assert!(
            crate::yaml::parse(&y2).unwrap().value["flows"]["pre-push"]["nodes"]["hello"]
                .is_object()
        );
        let _ = std::fs::remove_dir_all(&d);
        let _ = std::fs::remove_dir_all(&e);
    }
}
