//! 준비 블록: `setup.node` · `setup.python` · `setup.go` · `setup.rust` · `setup.java` · `setup.dotnet` · `setup.swift`.
//! ① 저장소가 바라는 런타임 버전(.nvmrc · .python-version · go.mod · rust-toolchain …)과 실제 버전을 비교하고(V1),
//! ② 잠금 파일 기준으로 의존을 설치한다(npm ci · pnpm --frozen-lockfile · uv sync --frozen …).
//! 잠금 파일 · 설치 명령 · 실행 위치가 지난번 성공 때와 같고 설치 폴더가 남아 있으면 설치를 건너뛴다(`force: true` 로 끔).
//! 명령은 노드의 실행 위치(local · docker)를 따른다.

use super::{observe_outcome, schema, Block, Meta, NodeCx, NodeResult};
use crate::util::{self, shell_quote, tr};
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tool {
    Node,
    Python,
    Go,
    Rust,
    Java,
    Dotnet,
    Swift,
}

pub struct Setup {
    pub meta: Meta,
    pub tool: Tool,
}

fn inputs() -> Value {
    schema(
        json!({
            "version": {"type": "string", "description": "Wanted runtime version; default comes from the repository (.nvmrc, .python-version, go.mod …)."},
            "install": {"type": "boolean", "default": true},
            "command": {"type": "string", "description": "Replace the detected install command."},
            "force": {"type": "boolean", "default": false, "description": "Install even when the lock files have not changed."},
        }),
        &[],
    )
}

macro_rules! setup {
    ($id:literal, $ko:literal, $en:literal, $tool:expr, $est:expr) => {
        Setup {
            meta: Meta {
                id: $id,
                version: "1.0.0",
                title: ($ko, $en),
                category: "setup",
                capabilities: &["process", "network"],
                env_classes: &[],
                destructive: false,
                outward: false,
                codes: &["SETUP-01", "SETUP-02", "EXEC-02", "EXEC-04", "EXEC-05"],
                inputs,
                selects_files: false,
                estimate_ms: $est,
            },
            tool: $tool,
        }
    };
}

pub static SETUPS: &[Setup] = &[
    setup!("setup.node", "Node 준비", "Set up Node", Tool::Node, 60_000),
    setup!(
        "setup.python",
        "Python 준비",
        "Set up Python",
        Tool::Python,
        60_000
    ),
    setup!("setup.go", "Go 준비", "Set up Go", Tool::Go, 30_000),
    setup!("setup.rust", "Rust 준비", "Set up Rust", Tool::Rust, 60_000),
    setup!(
        "setup.java",
        "Java 준비",
        "Set up Java",
        Tool::Java,
        120_000
    ),
    setup!(
        "setup.dotnet",
        ".NET 준비",
        "Set up .NET",
        Tool::Dotnet,
        60_000
    ),
    setup!(
        "setup.swift",
        "Swift 준비",
        "Set up Swift",
        Tool::Swift,
        60_000
    ),
];

/// 준비 계획: 바라는 버전 · 버전 명령 · 설치 명령 · 잠금 파일 · 설치 폴더.
#[derive(Debug, Default)]
pub struct Plan {
    pub wanted: Option<(String, String)>,
    pub version_cmd: String,
    pub version_re: &'static str,
    pub install: Option<String>,
    pub locks: Vec<String>,
    pub install_dir: Option<String>,
    pub manager: String,
}

fn read(dir: &Path, f: &str) -> Option<String> {
    std::fs::read_to_string(dir.join(f)).ok()
}

fn first_line(dir: &Path, f: &str) -> Option<(String, String)> {
    let t = read(dir, f)?;
    let l = t
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.is_empty() && !l.starts_with('#'))?
        .to_string();
    Some((l, f.to_string()))
}

/// `.tool-versions` (asdf · mise) 의 한 도구 버전.
fn tool_versions(dir: &Path, names: &[&str]) -> Option<(String, String)> {
    let t = read(dir, ".tool-versions")?;
    for l in t.lines() {
        let mut it = l.split_whitespace();
        if let (Some(n), Some(v)) = (it.next(), it.next()) {
            if names.contains(&n) {
                return Some((v.to_string(), ".tool-versions".into()));
            }
        }
    }
    None
}

fn exists(dir: &Path, f: &str) -> bool {
    dir.join(f).is_file()
}

fn venv_python(dir: &Path) -> Option<String> {
    for v in [".venv", "venv"] {
        let unix = dir.join(v).join("bin").join("python");
        if unix.is_file() {
            return Some(format!("{v}/bin/python"));
        }
        let win = dir.join(v).join("Scripts").join("python.exe");
        if win.is_file() {
            return Some(format!("{v}/Scripts/python.exe"));
        }
    }
    None
}

pub fn plan(tool: Tool, dir: &Path) -> Plan {
    let mut p = Plan::default();
    match tool {
        Tool::Node => {
            p.version_cmd = "node --version".into();
            p.version_re = r"v?(\d+(?:\.\d+){0,2})";
            p.wanted = first_line(dir, ".nvmrc")
                .or_else(|| first_line(dir, ".node-version"))
                .or_else(|| tool_versions(dir, &["nodejs", "node"]))
                .or_else(|| {
                    let pkg: Value = serde_json::from_str(&read(dir, "package.json")?).ok()?;
                    pkg["engines"]["node"]
                        .as_str()
                        .map(|s| (s.to_string(), "package.json engines.node".into()))
                });
            let pkg: Value = read(dir, "package.json")
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or(Value::Null);
            let declared = pkg["packageManager"]
                .as_str()
                .and_then(|s| s.split('@').next())
                .map(|s| s.to_string());
            let (mgr, cmd, lock) =
                if exists(dir, "pnpm-lock.yaml") || declared.as_deref() == Some("pnpm") {
                    ("pnpm", "pnpm install --frozen-lockfile", "pnpm-lock.yaml")
                } else if exists(dir, "bun.lock")
                    || exists(dir, "bun.lockb")
                    || declared.as_deref() == Some("bun")
                {
                    (
                        "bun",
                        "bun install --frozen-lockfile",
                        if exists(dir, "bun.lock") {
                            "bun.lock"
                        } else {
                            "bun.lockb"
                        },
                    )
                } else if exists(dir, "yarn.lock") || declared.as_deref() == Some("yarn") {
                    if exists(dir, ".yarnrc.yml") {
                        ("yarn", "yarn install --immutable", "yarn.lock")
                    } else {
                        ("yarn", "yarn install --frozen-lockfile", "yarn.lock")
                    }
                } else if exists(dir, "package-lock.json") || exists(dir, "npm-shrinkwrap.json") {
                    (
                        "npm",
                        "npm ci --no-audit --no-fund",
                        if exists(dir, "package-lock.json") {
                            "package-lock.json"
                        } else {
                            "npm-shrinkwrap.json"
                        },
                    )
                } else {
                    ("npm", "npm install --no-audit --no-fund", "package.json")
                };
            p.manager = mgr.into();
            if exists(dir, "package.json") {
                p.install = Some(cmd.into());
                p.locks = vec!["package.json".into(), lock.into()];
                p.locks.dedup();
                p.install_dir = Some("node_modules".into());
            }
        }
        Tool::Python => {
            let py = venv_python(dir).unwrap_or_else(|| {
                if cfg!(windows) {
                    "python".into()
                } else {
                    "python3".into()
                }
            });
            p.version_cmd = format!("{} --version", shell_quote(&py));
            p.version_re = r"Python (\d+(?:\.\d+){0,2})";
            p.wanted = first_line(dir, ".python-version")
                .or_else(|| tool_versions(dir, &["python"]))
                .or_else(|| {
                    let t = read(dir, "pyproject.toml")?;
                    let re = regex::Regex::new(r#"requires-python\s*=\s*["']([^"']+)["']"#).ok()?;
                    re.captures(&t)
                        .map(|c| (c[1].to_string(), "pyproject.toml requires-python".into()))
                });
            let venv_py = if cfg!(windows) {
                ".venv/Scripts/python.exe"
            } else {
                ".venv/bin/python"
            };
            let make_venv = format!(
                "[ -x {venv_py} ] || {} -m venv .venv",
                if cfg!(windows) { "python" } else { "python3" }
            );
            if exists(dir, "uv.lock") {
                p.manager = "uv".into();
                p.install = Some("uv sync --frozen".into());
                p.locks = vec!["uv.lock".into(), "pyproject.toml".into()];
            } else if exists(dir, "poetry.lock") {
                p.manager = "poetry".into();
                p.install = Some("poetry install --no-interaction".into());
                p.locks = vec!["poetry.lock".into(), "pyproject.toml".into()];
            } else {
                let reqs: Vec<String> = [
                    "requirements.txt",
                    "requirements-dev.txt",
                    "requirements-test.txt",
                    "dev-requirements.txt",
                ]
                .iter()
                .filter(|f| exists(dir, f))
                .map(|f| f.to_string())
                .collect();
                p.manager = "pip".into();
                if !reqs.is_empty() {
                    let args: Vec<String> = reqs
                        .iter()
                        .map(|r| format!("-r {}", shell_quote(r)))
                        .collect();
                    p.install = Some(format!(
                        "{make_venv} && {venv_py} -m pip install --disable-pip-version-check -q {}",
                        args.join(" ")
                    ));
                    p.locks = reqs;
                } else if exists(dir, "pyproject.toml") || exists(dir, "setup.py") {
                    p.install = Some(format!("{make_venv} && {venv_py} -m pip install --disable-pip-version-check -q -e ."));
                    p.locks = ["pyproject.toml", "setup.py", "setup.cfg"]
                        .iter()
                        .filter(|f| exists(dir, f))
                        .map(|f| f.to_string())
                        .collect();
                }
            }
            p.install_dir = Some(".venv".into());
        }
        Tool::Go => {
            p.version_cmd = "go version".into();
            p.version_re = r"go(\d+(?:\.\d+){0,2})";
            p.wanted = read(dir, "go.mod").and_then(|t| {
                let tc = regex::Regex::new(r"(?m)^toolchain\s+go(\S+)").ok()?;
                let gv = regex::Regex::new(r"(?m)^go\s+(\S+)").ok()?;
                tc.captures(&t)
                    .map(|c| (c[1].to_string(), "go.mod toolchain".to_string()))
                    .or_else(|| {
                        gv.captures(&t)
                            .map(|c| (format!(">={}", &c[1]), "go.mod go".to_string()))
                    })
            });
            p.manager = "go".into();
            if exists(dir, "go.mod") {
                p.install = Some("go mod download".into());
                p.locks = vec!["go.mod".into(), "go.sum".into()];
            }
        }
        Tool::Rust => {
            p.version_cmd = "rustc --version".into();
            p.version_re = r"rustc (\d+(?:\.\d+){0,2})";
            p.wanted = read(dir, "rust-toolchain.toml")
                .and_then(|t| {
                    let re = regex::Regex::new(r#"channel\s*=\s*"([^"]+)""#).ok()?;
                    re.captures(&t)
                        .map(|c| (c[1].to_string(), "rust-toolchain.toml".to_string()))
                })
                .or_else(|| first_line(dir, "rust-toolchain"))
                .filter(|(v, _)| {
                    v.chars()
                        .next()
                        .map(|c| c.is_ascii_digit())
                        .unwrap_or(false)
                });
            p.manager = "cargo".into();
            if exists(dir, "Cargo.toml") {
                p.install = Some(if exists(dir, "Cargo.lock") {
                    "cargo fetch --locked".into()
                } else {
                    "cargo fetch".into()
                });
                p.locks = vec!["Cargo.toml".into(), "Cargo.lock".into()];
            }
        }
        Tool::Java => {
            p.version_cmd = "java -version 2>&1".into();
            p.version_re = r#"version "(\d+(?:\.\d+){0,2})"#;
            p.wanted = first_line(dir, ".java-version")
                .or_else(|| tool_versions(dir, &["java"]))
                .or_else(|| {
                    let t = read(dir, ".sdkmanrc")?;
                    let re = regex::Regex::new(r"(?m)^java=(\d+(?:\.\d+){0,2})").ok()?;
                    re.captures(&t)
                        .map(|c| (c[1].to_string(), ".sdkmanrc".into()))
                })
                .map(|(v, f)| (v.split(['-', '+']).next().unwrap_or("").to_string(), f));
            if exists(dir, "gradlew")
                || exists(dir, "build.gradle")
                || exists(dir, "build.gradle.kts")
            {
                let g = if exists(dir, "gradlew") {
                    "./gradlew"
                } else {
                    "gradle"
                };
                p.manager = "gradle".into();
                p.install = Some(format!("{g} --no-daemon -q dependencies > /dev/null"));
                p.locks = [
                    "build.gradle",
                    "build.gradle.kts",
                    "settings.gradle",
                    "settings.gradle.kts",
                    "gradle.lockfile",
                    "gradle/libs.versions.toml",
                ]
                .iter()
                .filter(|f| exists(dir, f))
                .map(|f| f.to_string())
                .collect();
            } else if exists(dir, "pom.xml") {
                let m = if exists(dir, "mvnw") { "./mvnw" } else { "mvn" };
                p.manager = "maven".into();
                p.install = Some(format!("{m} -B -q dependency:go-offline"));
                p.locks = vec!["pom.xml".into()];
            }
        }
        Tool::Dotnet => {
            p.version_cmd = "dotnet --version".into();
            p.version_re = r"(\d+(?:\.\d+){0,2})";
            p.wanted = read(dir, "global.json").and_then(|t| {
                let v: Value = serde_json::from_str(&t).ok()?;
                v["sdk"]["version"]
                    .as_str()
                    .map(|s| (s.to_string(), "global.json".to_string()))
            });
            p.manager = "dotnet".into();
            let locked = exists(dir, "packages.lock.json");
            p.install = Some(if locked {
                "dotnet restore --locked-mode".into()
            } else {
                "dotnet restore".into()
            });
            p.locks = vec![
                "packages.lock.json".into(),
                "global.json".into(),
                "Directory.Packages.props".into(),
            ];
        }
        Tool::Swift => {
            p.version_cmd = "swift --version 2>&1".into();
            p.version_re = r"Swift version (\d+(?:\.\d+){0,2})";
            p.wanted = first_line(dir, ".swift-version");
            p.manager = "swiftpm".into();
            if exists(dir, "Package.swift") {
                p.install = Some("swift package resolve".into());
                p.locks = vec!["Package.swift".into(), "Package.resolved".into()];
            }
        }
    }
    p
}

fn nums(s: &str) -> Option<Vec<u64>> {
    let s = s.trim().trim_start_matches(['v', '=']);
    let core: String = s
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let v: Vec<u64> = core
        .split('.')
        .filter(|x| !x.is_empty())
        .map(|x| x.parse().ok())
        .collect::<Option<_>>()?;
    (!v.is_empty()).then_some(v)
}

fn cmp_ver(a: &[u64], b: &[u64]) -> std::cmp::Ordering {
    for (i, y) in b.iter().enumerate() {
        let x = *a.get(i).unwrap_or(&0);
        if x != *y {
            return x.cmp(y);
        }
    }
    std::cmp::Ordering::Equal
}

/// 비교식 하나(`>=3.11` · `<21` · `^18.2` · `~1.22` · `22` · `22.x`). None = 모르는 표기.
fn comparator(p: &str, a: &[u64]) -> Option<bool> {
    use std::cmp::Ordering::*;
    let p = p.trim();
    for (op, f) in [
        (">=", (|o| o != Less) as fn(std::cmp::Ordering) -> bool),
        ("<=", |o| o != Greater),
        (">", |o| o == Greater),
        ("<", |o| o == Less),
    ] {
        if let Some(rest) = p.strip_prefix(op) {
            return Some(f(cmp_ver(a, &nums(rest)?)));
        }
    }
    if let Some(rest) = p.strip_prefix('^') {
        let b = nums(rest)?;
        return Some(a[0] == b[0] && cmp_ver(a, &b) != Less);
    }
    if let Some(rest) = p.strip_prefix('~') {
        let b = nums(rest)?;
        return Some(
            a[0] == b[0]
                && a.get(1).copied().unwrap_or(0) == b.get(1).copied().unwrap_or(0)
                && cmp_ver(a, &b) != Less,
        );
    }
    // 22 · 22.3 · 22.x · 22.* → 앞자리 일치.
    let core = p.trim_start_matches(['v', '=']);
    let fixed: Vec<&str> = core
        .split('.')
        .take_while(|x| *x != "x" && *x != "X" && *x != "*")
        .collect();
    if fixed.is_empty()
        || !fixed
            .iter()
            .all(|x| !x.is_empty() && x.chars().all(|c| c.is_ascii_digit()))
    {
        return None;
    }
    let b: Vec<u64> = fixed.iter().map(|x| x.parse().unwrap_or(0)).collect();
    Some(a.len() >= b.len() && a[..b.len()] == b[..])
}

/// 바라는 버전과 실제 버전 비교(공백 = 그리고, `||` = 또는). None = 판정할 수 없는 표기(lts/* · latest 등).
pub fn version_ok(wanted: &str, actual: &str) -> Option<bool> {
    let a = nums(actual)?;
    let mut known_any = false;
    for alt in wanted.split("||") {
        let parts: Vec<&str> = alt.split_whitespace().collect();
        if parts.is_empty() {
            continue;
        }
        let mut all = true;
        let mut known = true;
        for p in parts {
            match comparator(p, &a) {
                Some(ok) => all &= ok,
                None => {
                    known = false;
                    break;
                }
            }
        }
        if known {
            known_any = true;
            if all {
                return Some(true);
            }
        }
    }
    known_any.then_some(false)
}

fn marker_path(key: &str) -> PathBuf {
    util::cache_dir().join("setup").join(format!("{key}.json"))
}

impl Block for Setup {
    fn meta(&self) -> &Meta {
        &self.meta
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let p = plan(self.tool, &cx.cwd);
        let wanted = cx
            .input_str("version")
            .map(|v| (v, "with.version".to_string()))
            .or(p.wanted.clone());
        r.observe("manager", json!(p.manager));
        // ① 버전.
        let c = cx.run_script(&p.version_cmd, &[]);
        let text = format!("{}\n{}", c.stdout, c.tail.join("\n"));
        let actual = regex::Regex::new(p.version_re)
            .ok()
            .and_then(|re| re.captures(&text).map(|m| m[1].to_string()));
        r.observe("version", json!(actual));
        match (&actual, &wanted) {
            (None, _) => {
                observe_outcome(&mut r, &c);
                r.verdicts.push(Verdict::new(
                    "V1",
                    tr("런타임", "runtime"),
                    tr("찾지 못함", "not found"),
                    wanted
                        .as_ref()
                        .map(|w| w.0.clone())
                        .unwrap_or_else(|| "-".into()),
                    Outcome::Fail,
                    Some("EXEC-04"),
                ));
                return r;
            }
            (Some(a), Some((w, src))) => match version_ok(w, a) {
                Some(ok) => r.verdicts.push(Verdict::new(
                    "V1",
                    tr("런타임 버전", "runtime version"),
                    a.clone(),
                    format!("{w} ({src})"),
                    if ok { Outcome::Pass } else { Outcome::Fail },
                    Some("SETUP-01"),
                )),
                None => cx.note(&tr(
                    &format!("버전 표기 '{w}'({src}) 는 비교하지 않습니다."),
                    &format!("version '{w}' ({src}) is not compared."),
                )),
            },
            (Some(a), None) => cx.note(&format!("{} {a}", tr("버전", "version"))),
        }
        if r.verdicts.iter().any(|v| v.result != Outcome::Pass) {
            return r;
        }
        // ② 설치.
        let install = cx.input_str("command").or(p.install.clone());
        let want_install = cx
            .with
            .get("install")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let Some(cmd) = install.filter(|_| want_install) else {
            r.verdicts.push(Verdict::new(
                "E1",
                tr("설치", "install"),
                tr("할 것 없음", "nothing to install"),
                "-".into(),
                Outcome::Pass,
                None,
            ));
            return r;
        };
        let mut h = format!("{cmd}\n{}\n", cx.exec.executor.as_str());
        for l in &p.locks {
            h.push_str(&format!(
                "{l}\0{}\n",
                util::sha256_hex(&std::fs::read(cx.cwd.join(l)).unwrap_or_default())
            ));
        }
        let lock_hash = util::sha256_hex(h.as_bytes());
        let key = util::sha256_hex(
            format!("{}\n{}\n{:?}", cx.cwd.display(), cx.block, self.tool).as_bytes(),
        )[..24]
            .to_string();
        let dir_ok = p
            .install_dir
            .as_ref()
            .map(|d| cx.cwd.join(d).is_dir())
            .unwrap_or(true);
        let force = cx
            .with
            .get("force")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let prev = std::fs::read_to_string(marker_path(&key))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok());
        if !force
            && dir_ok
            && prev
                .as_ref()
                .map(|v| v["hash"] == lock_hash.as_str())
                .unwrap_or(false)
        {
            r.observe("installSkipped", json!(true));
            cx.note(&tr(
                "잠금 파일이 그대로라 설치를 건너뜁니다(force: true 로 다시 설치).",
                "lock files unchanged, install skipped (force: true reinstalls).",
            ));
            r.verdicts.push(Verdict::new(
                "E1",
                tr("설치", "install"),
                tr("건너뜀(변경 없음)", "skipped (unchanged)"),
                "-".into(),
                Outcome::Pass,
                None,
            ));
            return r;
        }
        r.observe("install", json!(cx.masker.mask(&cmd)));
        let c = cx.run_script(&cmd, &[]);
        observe_outcome(&mut r, &c);
        let mut v = super::exit_verdict(&c, &[0]);
        if v.code == Some("EXEC-01") {
            v.code = Some("SETUP-02");
        }
        if v.result == Outcome::Pass {
            let _ = util::write_atomic(
                &marker_path(&key),
                json!({"hash": lock_hash, "at": util::rfc3339(util::now_ms())})
                    .to_string()
                    .as_bytes(),
            );
        }
        r.verdicts.push(v);
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions() {
        assert_eq!(version_ok("22", "22.3.0"), Some(true));
        assert_eq!(version_ok("v20.11.1", "v20.11.1"), Some(true));
        assert_eq!(version_ok("20", "22.3.0"), Some(false));
        assert_eq!(version_ok(">=3.11", "3.12.1"), Some(true));
        assert_eq!(version_ok(">=3.11", "3.9.6"), Some(false));
        assert_eq!(version_ok("^18.2", "18.20.0"), Some(true));
        assert_eq!(version_ok("^18.2", "19.0.0"), Some(false));
        assert_eq!(version_ok("~1.22", "1.22.5"), Some(true));
        assert_eq!(version_ok("lts/*", "22.3.0"), None);
        assert_eq!(version_ok(">=18 <21", "20.0.0"), Some(true));
        assert_eq!(version_ok(">=18 <21", "22.0.0"), Some(false));
        assert_eq!(version_ok("^18 || ^20", "20.1.0"), Some(true));
        assert_eq!(version_ok("22.x", "22.9.1"), Some(true));
        assert_eq!(version_ok("latest", "22.0.0"), None);
    }

    #[test]
    fn node_package_managers() {
        let d = std::env::temp_dir().join(format!("gf-setup-{}", util::random_hex(4)));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("package.json"),
            "{\"engines\": {\"node\": \">=20\"}}",
        )
        .unwrap();
        let p = plan(Tool::Node, &d);
        assert_eq!(
            p.install.as_deref(),
            Some("npm install --no-audit --no-fund")
        );
        assert_eq!(p.wanted.as_ref().unwrap().0, ">=20");
        std::fs::write(d.join("pnpm-lock.yaml"), "").unwrap();
        std::fs::write(d.join(".nvmrc"), "22\n").unwrap();
        let p = plan(Tool::Node, &d);
        assert_eq!(p.install.as_deref(), Some("pnpm install --frozen-lockfile"));
        assert_eq!(
            p.wanted.as_ref().unwrap(),
            &("22".to_string(), ".nvmrc".to_string())
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn go_mod_versions() {
        let d = std::env::temp_dir().join(format!("gf-setup-go-{}", util::random_hex(4)));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("go.mod"), "module x\n\ngo 1.22\n").unwrap();
        assert_eq!(plan(Tool::Go, &d).wanted.unwrap().0, ">=1.22");
        std::fs::write(
            d.join("go.mod"),
            "module x\n\ngo 1.22\ntoolchain go1.22.3\n",
        )
        .unwrap();
        assert_eq!(plan(Tool::Go, &d).wanted.unwrap().0, "1.22.3");
        let _ = std::fs::remove_dir_all(&d);
    }
}
