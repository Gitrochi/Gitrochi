//! Test blocks: a runner = a default command + where its report comes from + how files are picked.
//! The verdict always comes from the report (T2), the executed count (T3), the pass rate (T1) and agreement with the exit code (X1).

use super::{find_files, observe_outcome, schema, Block, Meta, NodeCx, NodeResult};
use crate::report::{self, TestReport};
use crate::spec::FlakyPolicy;
use crate::util::{shell_quote, tr};
use crate::verify;
use serde_json::{json, Value};
use std::path::Path;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Vitest,
    Jest,
    Pytest,
    Go,
    Cargo,
    Junit,
    Tap,
    Gradle,
    Maven,
    Swift,
    Dotnet,
    Playwright,
}

pub struct Runner {
    pub meta: Meta,
    pub kind: Kind,
}

fn inputs() -> Value {
    schema(
        json!({
            "run": {"type": "string", "description": "Replace the default command. Write the report where `report` points (GITCH_FLOW_OUT is the node's output folder)."},
            "args": {"type": "array", "items": {"type": "string"}, "description": "Extra arguments for the default command."},
            "report": {"type": ["string", "array"], "description": "Report file glob(s), relative to the repository or ${{ node.out }}."},
            "cwd": {"type": "string"},
        }),
        &[],
    )
}

const TEST_CODES: &[&str] = &[
    "TEST-01", "TEST-02", "TEST-03", "TEST-04", "TEST-05", "TEST-06", "EXEC-02", "EXEC-04",
    "EXEC-05",
];

macro_rules! runner {
    ($id:literal, $ko:literal, $en:literal, $kind:expr, $sel:expr, $est:expr) => {
        Runner {
            meta: Meta {
                id: $id,
                version: "1.0.0",
                title: ($ko, $en),
                category: "test",
                capabilities: &["process"],
                env_classes: &[],
                destructive: false,
                outward: false,
                codes: TEST_CODES,
                inputs,
                selects_files: $sel,
                estimate_ms: $est,
            },
            kind: $kind,
        }
    };
}

pub static RUNNERS: &[Runner] = &[
    runner!(
        "test.vitest",
        "Vitest 테스트",
        "Vitest tests",
        Kind::Vitest,
        true,
        60_000
    ),
    runner!(
        "test.jest",
        "Jest 테스트",
        "Jest tests",
        Kind::Jest,
        true,
        60_000
    ),
    runner!(
        "test.pytest",
        "pytest 테스트",
        "pytest tests",
        Kind::Pytest,
        true,
        60_000
    ),
    runner!("test.go", "Go 테스트", "Go tests", Kind::Go, true, 60_000),
    runner!(
        "test.cargo",
        "Rust(cargo) 테스트",
        "Rust (cargo) tests",
        Kind::Cargo,
        false,
        120_000
    ),
    runner!(
        "test.junit",
        "JUnit 보고서 테스트",
        "Tests with a JUnit report",
        Kind::Junit,
        false,
        60_000
    ),
    runner!(
        "test.tap",
        "TAP 테스트",
        "TAP tests",
        Kind::Tap,
        false,
        60_000
    ),
    runner!(
        "test.gradle",
        "Gradle 테스트",
        "Gradle tests",
        Kind::Gradle,
        false,
        180_000
    ),
    runner!(
        "test.maven",
        "Maven 테스트",
        "Maven tests",
        Kind::Maven,
        false,
        180_000
    ),
    runner!(
        "test.swift",
        "Swift 패키지 테스트",
        "Swift package tests",
        Kind::Swift,
        false,
        120_000
    ),
    runner!(
        "test.dotnet",
        ".NET 테스트",
        ".NET tests",
        Kind::Dotnet,
        false,
        120_000
    ),
    runner!(
        "test.playwright",
        "Playwright 테스트",
        "Playwright tests",
        Kind::Playwright,
        true,
        180_000
    ),
];

/// The start of a Node package command. The lock file picks the package manager; npx gets --no-install so nothing is downloaded silently.
pub fn node_exec(cwd: &Path, root: &Path) -> &'static str {
    for d in [cwd, root] {
        if d.join("pnpm-lock.yaml").is_file() {
            return "pnpm exec";
        }
        if d.join("yarn.lock").is_file() {
            return "yarn";
        }
        if d.join("bun.lockb").is_file() || d.join("bun.lock").is_file() {
            return "bunx";
        }
        if d.join("package-lock.json").is_file() {
            break;
        }
    }
    "npx --no-install"
}

pub fn python(cwd: &Path, root: &Path) -> String {
    for d in [cwd, root] {
        for venv in [".venv", "venv"] {
            let unix = d.join(venv).join("bin").join("python");
            if unix.is_file() {
                return shell_quote(&unix.to_string_lossy());
            }
            let win = d.join(venv).join("Scripts").join("python.exe");
            if win.is_file() {
                return shell_quote(&win.to_string_lossy());
            }
        }
    }
    if cfg!(windows) {
        "python".into()
    } else {
        "python3".into()
    }
}

#[derive(Clone)]
enum Source {
    Files(Vec<String>),
    Stdout,
}

impl Runner {
    fn default_command(
        &self,
        cx: &NodeCx,
        out: &str,
        files: &[String],
    ) -> (String, Source, Vec<(String, String)>) {
        let exec = node_exec(&cx.cwd, &cx.root);
        let extra: Vec<String> = cx
            .with
            .get("args")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .map(|x| shell_quote(&crate::expr::to_text(x)))
                    .collect()
            })
            .unwrap_or_default();
        let files_q: Vec<String> = files.iter().map(|f| shell_quote(f)).collect();
        let tail = |mut v: Vec<String>| {
            v.extend(extra.iter().cloned());
            v.extend(files_q.iter().cloned());
            v.join(" ")
        };
        let out_file = |name: &str| format!("{out}/{name}");
        match self.kind {
            Kind::Vitest => (
                tail(vec![
                    exec.into(),
                    "vitest".into(),
                    "run".into(),
                    "--reporter=default".into(),
                    "--reporter=junit".into(),
                    format!("--outputFile.junit={}", shell_quote(&out_file("junit.xml"))),
                ]),
                Source::Files(vec![out_file("junit.xml")]),
                vec![],
            ),
            Kind::Jest => (
                tail(vec![
                    exec.into(),
                    "jest".into(),
                    "--ci".into(),
                    "--json".into(),
                    format!("--outputFile={}", shell_quote(&out_file("jest.json"))),
                ]),
                Source::Files(vec![out_file("jest.json")]),
                vec![],
            ),
            Kind::Pytest => (
                tail(vec![
                    python(&cx.cwd, &cx.root),
                    "-m".into(),
                    "pytest".into(),
                    "-q".into(),
                    format!("--junitxml={}", shell_quote(&out_file("junit.xml"))),
                ]),
                Source::Files(vec![out_file("junit.xml")]),
                vec![],
            ),
            Kind::Go => {
                let pkgs = if files.is_empty() {
                    vec!["./...".to_string()]
                } else {
                    files_q.clone()
                };
                let mut v = vec!["go".into(), "test".into(), "-json".into()];
                v.extend(extra.iter().cloned());
                v.extend(pkgs);
                (v.join(" "), Source::Stdout, vec![])
            }
            Kind::Cargo => (
                tail(vec!["cargo".into(), "test".into(), "--no-fail-fast".into()]),
                Source::Stdout,
                vec![],
            ),
            Kind::Junit | Kind::Tap => (String::new(), Source::Stdout, vec![]),
            Kind::Gradle => {
                let g = if cx.cwd.join("gradlew").is_file() || cx.root.join("gradlew").is_file() {
                    "./gradlew"
                } else {
                    "gradle"
                };
                (
                    tail(vec![g.into(), "test".into(), "--continue".into()]),
                    Source::Files(vec!["**/build/test-results/**/*.xml".into()]),
                    vec![],
                )
            }
            Kind::Maven => {
                let m = if cx.cwd.join("mvnw").is_file() {
                    "./mvnw"
                } else {
                    "mvn"
                };
                (
                    tail(vec![
                        m.into(),
                        "-B".into(),
                        "test".into(),
                        "-Dmaven.test.failure.ignore=false".into(),
                    ]),
                    Source::Files(vec![
                        "**/target/surefire-reports/*.xml".into(),
                        "**/target/failsafe-reports/*.xml".into(),
                    ]),
                    vec![],
                )
            }
            Kind::Swift => (
                tail(vec![
                    "swift".into(),
                    "test".into(),
                    "--parallel".into(),
                    "--xunit-output".into(),
                    shell_quote(&out_file("xunit.xml")),
                ]),
                Source::Files(vec![
                    out_file("xunit.xml"),
                    out_file("xunit-swift-testing.xml"),
                ]),
                vec![],
            ),
            Kind::Dotnet => (
                tail(vec![
                    "dotnet".into(),
                    "test".into(),
                    "--logger".into(),
                    shell_quote("trx;LogFileName=results.trx"),
                    "--results-directory".into(),
                    shell_quote(out),
                ]),
                Source::Files(vec![out_file("results.trx"), format!("{out}/**/*.trx")]),
                vec![],
            ),
            Kind::Playwright => (
                tail(vec![
                    exec.into(),
                    "playwright".into(),
                    "test".into(),
                    "--reporter=junit".into(),
                ]),
                Source::Files(vec![out_file("junit.xml")]),
                vec![("PLAYWRIGHT_JUNIT_OUTPUT_NAME".into(), out_file("junit.xml"))],
            ),
        }
    }

    fn parse_stdout(&self, text: &str) -> TestReport {
        match self.kind {
            Kind::Go => report::parse_gotest(text, "stdout"),
            Kind::Cargo => report::parse_libtest(text, "stdout"),
            _ => report::parse_tap(text, "stdout"),
        }
    }

    fn collect(&self, cx: &NodeCx, source: &Source, stdout: &str) -> Option<TestReport> {
        match source {
            Source::Stdout => {
                let r = self.parse_stdout(stdout);
                if r.cases.is_empty() && !r.problems.is_empty() && !r.harness_failed {
                    None
                } else {
                    Some(r)
                }
            }
            Source::Files(globs) => {
                let root_s = cx.root.to_string_lossy().replace('\\', "/");
                let mut found = Vec::new();
                for g in globs {
                    let g = g.replace('\\', "/");
                    let p = Path::new(&g);
                    if p.is_absolute() {
                        // An absolute path, like the node output folder inside .git, is searched right there.
                        let (dir, pat) = split_glob(p);
                        found.extend(find_files(&dir, &[pat], cx.started_ms));
                    } else {
                        found.extend(find_files(&cx.cwd, std::slice::from_ref(&g), cx.started_ms));
                        if cx.cwd != cx.root {
                            found.extend(find_files(
                                &cx.root,
                                std::slice::from_ref(&g),
                                cx.started_ms,
                            ));
                        }
                    }
                }
                found.sort();
                found.dedup();
                if found.is_empty() {
                    return None;
                }
                let mut rep = TestReport::default();
                for f in found {
                    let text = std::fs::read_to_string(&f).unwrap_or_default();
                    let rel = crate::util::rel_slash(&cx.root, &f);
                    let part = if rel.ends_with(".json") {
                        report::parse_jest_json(&text, &rel, &root_s)
                    } else if rel.ends_with(".trx") {
                        report::parse_trx(&text, &rel)
                    } else {
                        report::parse_junit(&text, &rel)
                    };
                    rep.merge(part);
                }
                Some(rep)
            }
        }
    }
}

/// `/a/b/**/*.xml` → (`/a/b`, `**/*.xml`): the fixed leading folder and the rest of the glob.
fn split_glob(p: &Path) -> (std::path::PathBuf, String) {
    let s = p.to_string_lossy().replace('\\', "/");
    let mut fixed = Vec::new();
    let mut rest = Vec::new();
    let mut in_glob = false;
    for part in s.split('/') {
        if !in_glob && !part.contains(['*', '?', '[', '{']) {
            fixed.push(part.to_string());
        } else {
            in_glob = true;
            rest.push(part.to_string());
        }
    }
    if rest.is_empty() {
        let name = fixed.pop().unwrap_or_default();
        rest.push(name);
    }
    let dir = fixed.join("/");
    (
        std::path::PathBuf::from(if dir.is_empty() { "/".to_string() } else { dir }),
        rest.join("/"),
    )
}

impl Block for Runner {
    fn meta(&self) -> &Meta {
        &self.meta
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let mut e = Vec::new();
        if matches!(self.kind, Kind::Junit | Kind::Tap)
            && with
                .get("run")
                .and_then(|r| r.as_str())
                .map(|s| s.trim().is_empty())
                .unwrap_or(true)
        {
            e.push(tr(
                "이 실행기는 run 에 테스트 명령이 필요합니다.",
                "this runner needs a test command in run.",
            ));
        }
        if self.kind == Kind::Junit && with.get("report").is_none() {
            e.push(tr(
                "test.junit 은 report 에 JUnit 파일 경로(glob)가 필요합니다.",
                "test.junit needs report: a JUnit file path (glob).",
            ));
        }
        e
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult::default();
        let out = cx.out_dir.to_string_lossy().replace('\\', "/");
        let files = cx.selection.clone().unwrap_or_default();
        let (default_cmd, default_src, extra_env) = self.default_command(cx, &out, &files);
        let (script, source) = match cx.input_str("run") {
            Some(run) => {
                let src = match cx.with.get("report") {
                    Some(Value::String(g)) => Source::Files(vec![g.clone()]),
                    Some(Value::Array(a)) => {
                        Source::Files(a.iter().map(crate::expr::to_text).collect())
                    }
                    _ => default_src.clone(),
                };
                (run, src)
            }
            None => (default_cmd, default_src),
        };
        let mut env = extra_env;
        env.push(("GITCH_FLOW_OUT".into(), out.clone()));
        if !files.is_empty() {
            env.push(("GITCH_FLOW_SELECTED".into(), files.join("\n")));
        }
        r.observe("command", json!(cx.masker.mask(&script)));
        if let Some(sel) = &cx.selection {
            r.observe("selected", json!(sel.len()));
        }
        let first = cx.run_script(&script, &env);
        observe_outcome(&mut r, &first);
        r.attempts = 1;
        let mut rep = self.collect(cx, &source, &first.stdout);
        let mut exit = first.outcome.exit_code;
        let flaky = cx
            .retry
            .as_ref()
            .map(|x| x.flaky)
            .unwrap_or(FlakyPolicy::Fail);
        // Retry: with failures, run the same command again (most runners need their own way to rerun only the failures).
        if let (Some(retry), Some(base)) = (cx.retry.clone(), rep.as_mut()) {
            let mut tries = 0;
            while base.failed() > 0
                && tries < retry.max
                && !cx.cancel.is_cancelled()
                && !first.outcome.timed_out
            {
                tries += 1;
                cx.note(&tr(
                    &format!("실패 {}개 — 다시 실행 {tries}/{}", base.failed(), retry.max),
                    &format!("{} failed — retry {tries}/{}", base.failed(), retry.max),
                ));
                let again = cx.run_script(&script, &env);
                r.attempts += 1;
                if let Some(rr) = self.collect(cx, &source, &again.stdout) {
                    base.apply_retry(&rr);
                    if base.failed() == 0 {
                        exit = again.outcome.exit_code;
                    }
                }
            }
        }
        let timed_out_or_cancelled = first.outcome.timed_out
            || first.outcome.cancelled
            || first.outcome.spawn_error.is_some();
        if timed_out_or_cancelled {
            r.verdicts.push(super::exit_verdict(&first, &[0]));
        }
        r.verdicts.push(verify::report_present(rep.as_ref()));
        if let Some(rp) = &rep {
            let min = cx.expect.min_tests.unwrap_or(1);
            r.verdicts.push(verify::min_tests(rp, min));
            let q = verify::Quarantined {
                entries: &cx.quarantine,
                today: cx.today.clone(),
            };
            r.verdicts.push(verify::pass_rate(
                rp,
                cx.expect.pass_rate.unwrap_or(1.0),
                flaky,
                &q,
            ));
            if !timed_out_or_cancelled {
                r.verdicts.push(verify::consistency(exit, rp, flaky));
            }
            r.observe("tests", json!({"executed": rp.executed(), "passed": rp.passed(), "failed": rp.failed(), "skipped": rp.skipped(), "flaky": rp.flaky()}));
        }
        r.report = rep;
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_glob_parts() {
        let (d, g) = split_glob(Path::new("/tmp/x/out/**/*.trx"));
        assert_eq!(d, std::path::PathBuf::from("/tmp/x/out"));
        assert_eq!(g, "**/*.trx");
        let (d2, g2) = split_glob(Path::new("/tmp/x/out/junit.xml"));
        assert_eq!(d2, std::path::PathBuf::from("/tmp/x/out"));
        assert_eq!(g2, "junit.xml");
    }

    #[test]
    fn package_manager_detection() {
        let d = std::env::temp_dir().join(format!("gf-pm-{}", crate::util::random_hex(4)));
        std::fs::create_dir_all(&d).unwrap();
        assert_eq!(node_exec(&d, &d), "npx --no-install");
        std::fs::write(d.join("pnpm-lock.yaml"), "").unwrap();
        assert_eq!(node_exec(&d, &d), "pnpm exec");
        let _ = std::fs::remove_dir_all(&d);
    }
}
