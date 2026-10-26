//! 영향 선택: 바뀐 파일 → 영향받는 테스트 파일. 확신이 없으면 그 스위트는 전부 돌리고 이유를 남긴다.
//! "후보가 없다"는 "테스트가 필요 없다"가 아니다 — 고른 근거와 뺀 이유를 계획에 그대로 적는다.

use crate::plan::{Decision, Plan};
use crate::spec::Spec;
use crate::util::{glob_match, tr};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::Path;

/// 바뀌면 그 범위 전체를 다시 돌려야 하는 파일(의존 · 빌드 · 테스트 설정).
const GLOBAL: &[&str] = &[
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "pnpm-workspace.yaml",
    "yarn.lock",
    "bun.lockb",
    "bun.lock",
    "Cargo.toml",
    "Cargo.lock",
    "go.mod",
    "go.sum",
    "pyproject.toml",
    "poetry.lock",
    "uv.lock",
    "Pipfile.lock",
    "requirements*.txt",
    "setup.py",
    "setup.cfg",
    "tox.ini",
    "pytest.ini",
    "conftest.py",
    "noxfile.py",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "gradle.properties",
    "pom.xml",
    "*.csproj",
    "*.sln",
    "Directory.Build.props",
    "Package.swift",
    "Package.resolved",
    "Gemfile",
    "Gemfile.lock",
    "composer.json",
    "composer.lock",
    "tsconfig*.json",
    "jsconfig.json",
    "vite.config.*",
    "vitest.config.*",
    "vitest.workspace.*",
    "jest.config.*",
    "babel.config.*",
    ".babelrc",
    "playwright.config.*",
    ".nvmrc",
    ".node-version",
    ".python-version",
    ".tool-versions",
    "rust-toolchain*",
    "Dockerfile",
    "compose*.yml",
    "compose*.yaml",
    "docker-compose*.yml",
    "docker-compose*.yaml",
    "Makefile",
    ".gitch/**",
    ".github/workflows/**",
    ".gitlab-ci.yml",
    "Jenkinsfile",
];

const TEST_GLOBS: &[&str] = &[
    "*.test.*",
    "*.spec.*",
    "*_test.go",
    "test_*.py",
    "*_test.py",
    "*Test.java",
    "*Tests.java",
    "*IT.java",
    "*Test.kt",
    "*Tests.kt",
    "*Tests.swift",
    "*Test.swift",
    "*_spec.rb",
    "*_test.rb",
    "*Test.php",
    "*Tests.cs",
    "*Test.cs",
    "**/__tests__/**",
    "tests/**",
    "test/**",
    "spec/**",
    "**/tests/**",
    "**/test/**",
    "**/src/test/**",
];

pub fn is_test_file(path: &str) -> bool {
    TEST_GLOBS.iter().any(|g| glob_match(g, path))
}

pub fn is_global(path: &str) -> bool {
    GLOBAL.iter().any(|g| glob_match(g, path))
}

/// 파일 이름에서 테스트 표식을 뺀 줄기: `a/foo.test.ts` → `foo`, `test_foo.py` → `foo`, `FooTests.swift` → `foo`.
pub fn stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    let base = name.split('.').next().unwrap_or(name);
    let mut s = base.to_string();
    for suf in ["_test", "_spec", "Tests", "Test", "IT", "Spec"] {
        if s.len() > suf.len() && s.ends_with(suf) {
            s.truncate(s.len() - suf.len());
            break;
        }
    }
    if let Some(rest) = s.strip_prefix("test_") {
        s = rest.to_string();
    }
    s.to_ascii_lowercase()
}

pub struct Changes {
    pub mode: String,
    pub base: Option<String>,
    pub files: Vec<String>,
}

/// 바뀐 파일. base = 기본 브랜치와 갈라진 곳부터 작업 트리까지(커밋 안 한 것 포함).
pub fn changes(root: &Path, mode: &str) -> Changes {
    match mode {
        "staged" => Changes {
            mode: mode.into(),
            base: None,
            files: crate::git::changed_files(root, None, true),
        },
        "worktree" | "head" => Changes {
            mode: mode.into(),
            base: crate::git::head_sha(root),
            files: crate::git::changed_files(root, None, false),
        },
        other => {
            let explicit = other
                .strip_prefix("base:")
                .or(if other == "base" || other.is_empty() {
                    None
                } else {
                    Some(other)
                });
            let base = match explicit {
                Some(b) => Some(b.to_string()),
                None => crate::git::default_branch(root)
                    .and_then(|d| crate::git::merge_base(root, &d, "HEAD")),
            };
            let files = crate::git::changed_files(root, base.as_deref(), false);
            Changes {
                mode: "base".into(),
                base,
                files,
            }
        }
    }
}

/// `gitch graph affected --json` 로 전이 영향 파일을 받는다. gitch 가 없으면 None.
fn graph_affected(root: &Path, base: Option<&str>) -> Option<(Vec<String>, Vec<String>)> {
    let gitch = std::env::var("GITCH_PATH").ok().filter(|s| !s.is_empty())?;
    let bash = crate::process::bash_path();
    let mut args = vec![
        gitch,
        "g".to_string(),
        "affected".to_string(),
        "--json".to_string(),
        "--no-open".to_string(),
    ];
    if let Some(b) = base {
        args.push("--base".into());
        args.push(b.to_string());
    }
    let spec = crate::process::ProcSpec {
        program: bash,
        args,
        cwd: root.to_path_buf(),
        env: vec![("GITSW_COLOR".into(), "never".into())],
        clear_env: false,
        timeout_ms: Some(180_000),
        settle_ms: 2000,
    };
    let mut out = String::new();
    let o = crate::process::run(&spec, &crate::process::Cancel::new(), &mut |s, l| {
        if s == crate::process::Stream::Out {
            out.push_str(l);
            out.push('\n');
        }
    });
    if o.exit_code != Some(0) {
        return None;
    }
    let v: Value = serde_json::from_str(&out).ok()?;
    let a = &v["stats"]["affected"];
    let list = |k: &str| {
        a[k].as_array()
            .map(|x| {
                x.iter()
                    .filter_map(|s| s.as_str().map(|t| t.to_string()))
                    .collect()
            })
            .unwrap_or_default()
    };
    Some((list("files"), list("unresolvedFiles")))
}

pub fn apply(spec: &Spec, plan: &mut Plan, mode: &str) {
    let root = &spec.root;
    let ch = changes(root, mode);
    let global: Option<String> = ch.files.iter().find(|f| is_global(f)).cloned();
    let wants = plan.nodes.iter().any(|n| {
        n.select.as_ref().map(|s| s.affected).unwrap_or(false) && n.decision == Decision::Run
    });
    let all_files = if wants {
        crate::git::ls_files(root)
    } else {
        Vec::new()
    };
    let tests: Vec<String> = all_files
        .iter()
        .filter(|f| is_test_file(f))
        .cloned()
        .collect();
    let graph = if wants && global.is_none() && !ch.files.is_empty() {
        graph_affected(root, ch.base.as_deref())
    } else {
        None
    };
    let mut summary_nodes = Vec::new();
    for n in plan.nodes.iter_mut() {
        let Some(sel) = n.select.clone() else {
            continue;
        };
        if !sel.affected || n.decision != Decision::Run {
            continue;
        }
        let always = spec
            .suite(n.suite.as_deref().unwrap_or(""))
            .map(|s| s.always_run || s.tags.iter().any(|t| t == "smoke"))
            .unwrap_or(false);
        let scope: Vec<String> = sel
            .paths
            .iter()
            .cloned()
            .chain(
                spec.suite(n.suite.as_deref().unwrap_or(""))
                    .map(|s| s.paths.clone())
                    .unwrap_or_default(),
            )
            .collect();
        let cwd = n.def.cwd.clone().or_else(|| {
            n.with
                .get("cwd")
                .and_then(|c| c.as_str())
                .map(|s| s.to_string())
        });
        let in_scope = |f: &str| -> bool {
            let under_cwd = cwd
                .as_ref()
                .map(|c| f.starts_with(&format!("{}/", c.trim_end_matches('/'))))
                .unwrap_or(true);
            under_cwd && (scope.is_empty() || scope.iter().any(|g| glob_match(g, f)))
        };
        if let Some(g) = &global {
            n.selection_reason = Some(tr(
                &format!("전체: 의존 · 설정 파일 {g} 이(가) 바뀜"),
                &format!("all: dependency or config file {g} changed"),
            ));
            continue;
        }
        if ch.files.iter().all(|f| !in_scope(f)) {
            if always {
                n.selection_reason = Some(tr(
                    "전체: 바뀐 파일은 없지만 항상 도는 스위트",
                    "all: no relevant changes, but this suite always runs",
                ));
            } else {
                n.decision = Decision::Skip(
                    "not-affected",
                    tr(
                        "이 범위에 바뀐 파일이 없음",
                        "no changed files in this scope",
                    ),
                );
            }
            continue;
        }
        if let Some((_, unresolved)) = &graph {
            if let Some(u) = unresolved.iter().find(|u| in_scope(u)) {
                n.selection_reason = Some(tr(
                    &format!("전체: 정적으로 해석하지 못한 파일 {u}"),
                    &format!("all: could not resolve {u} statically"),
                ));
                continue;
            }
        }
        let mut picked: BTreeSet<String> = BTreeSet::new();
        let (mut by_change, mut by_name, mut by_graph) = (0, 0, 0);
        for f in ch.files.iter().filter(|f| in_scope(f)) {
            if is_test_file(f) {
                if all_files.contains(f) && picked.insert(f.clone()) {
                    by_change += 1;
                }
                continue;
            }
            let s = stem(f);
            for t in tests.iter().filter(|t| in_scope(t) && stem(t) == s) {
                if picked.insert(t.clone()) {
                    by_name += 1;
                }
            }
        }
        if let Some((files, _)) = &graph {
            for f in files.iter().filter(|f| is_test_file(f) && in_scope(f)) {
                if picked.insert(f.clone()) {
                    by_graph += 1;
                }
            }
        }
        let block_selects = crate::blocks::get(&n.block)
            .map(|b| b.meta().selects_files)
            .unwrap_or(false);
        if picked.is_empty() {
            if always {
                n.selection_reason = Some(tr(
                    "전체: 영향받은 테스트 후보가 없지만 항상 도는 스위트",
                    "all: no candidate tests, but this suite always runs",
                ));
            } else {
                n.decision = Decision::Skip(
                    "not-affected",
                    tr(
                        "영향받은 테스트 후보 없음(후보가 없다 ≠ 테스트가 필요 없다)",
                        "no affected test candidates (no candidates ≠ no tests needed)",
                    ),
                );
            }
            continue;
        }
        if !block_selects {
            n.selection_reason = Some(tr(
                &format!(
                    "전체: {} 은(는) 파일 고르기를 지원하지 않음(후보 {}개)",
                    n.block,
                    picked.len()
                ),
                &format!(
                    "all: {} cannot select files ({} candidates)",
                    n.block,
                    picked.len()
                ),
            ));
            continue;
        }
        let mut list: Vec<String> = picked.into_iter().collect();
        if n.block == "test.go" {
            let mut pk: BTreeSet<String> = BTreeSet::new();
            for f in &list {
                let dir = f.rsplit_once('/').map(|x| x.0).unwrap_or(".");
                pk.insert(format!("./{dir}"));
            }
            list = pk.into_iter().collect();
        }
        if let Some(c) = &cwd {
            let prefix = format!("{}/", c.trim_end_matches('/'));
            list = list
                .into_iter()
                .map(|f| f.strip_prefix(&prefix).map(|s| s.to_string()).unwrap_or(f))
                .collect();
        }
        n.selection_reason = Some(tr(
            &format!("{}개 선택 — 바뀐 테스트 {by_change} · 이름 관례 {by_name} · 의존 그래프 {by_graph}", list.len()),
            &format!("{} selected — changed tests {by_change}, name convention {by_name}, dependency graph {by_graph}", list.len()),
        ));
        summary_nodes.push(json!({"node": n.id, "selected": list.len()}));
        n.selection = Some(list);
    }
    plan.affected = Some(json!({
        "mode": ch.mode,
        "base": ch.base,
        "changed": ch.files.iter().take(200).collect::<Vec<_>>(),
        "changedTotal": ch.files.len(),
        "global": global,
        "graph": if graph.is_some() { "gitch graph affected" } else { "unavailable" },
        "nodes": summary_nodes,
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_file_patterns() {
        for f in [
            "src/a.test.ts",
            "pkg/x_test.go",
            "tests/test_a.py",
            "src/test/java/a/FooTest.java",
            "Tests/AppTests/FooTests.swift",
            "src/__tests__/b.js",
        ] {
            assert!(is_test_file(f), "{f}");
        }
        for f in ["src/a.ts", "main.go", "app/models.py", "README.md"] {
            assert!(!is_test_file(f), "{f}");
        }
    }

    #[test]
    fn stems() {
        assert_eq!(stem("src/math.test.ts"), "math");
        assert_eq!(stem("src/math.ts"), "math");
        assert_eq!(stem("tests/test_parser.py"), "parser");
        assert_eq!(stem("x/parser_test.go"), "parser");
        assert_eq!(stem("FooTests.swift"), "foo");
        assert_eq!(stem("FooTest.java"), "foo");
    }

    #[test]
    fn global_files() {
        assert!(is_global("package-lock.json"));
        assert!(is_global("apps/web/package.json"));
        assert!(is_global(".gitch/flow.yml"));
        assert!(is_global(".github/workflows/ci.yml"));
        assert!(is_global("vitest.config.ts"));
        assert!(!is_global("src/app.ts"));
    }
}
