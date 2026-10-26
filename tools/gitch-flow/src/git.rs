//! 시스템 git 호출. 엔진은 git 동작을 새로 만들지 않고 기계용 출력만 읽는다.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn git_bin() -> String {
    std::env::var("GITCH_FLOW_GIT")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "git".into())
}

pub fn command(dir: &Path) -> Command {
    let mut c = Command::new(git_bin());
    c.arg("-C").arg(dir);
    c.env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C");
    c.stdin(Stdio::null());
    crate::process::hide_window(&mut c);
    c
}

/// 성공하면 표준출력(끝 줄바꿈 제거), 실패하면 None.
pub fn run(dir: &Path, args: &[&str]) -> Option<String> {
    let out = command(dir)
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let mut s = String::from_utf8_lossy(&out.stdout).to_string();
    while s.ends_with('\n') || s.ends_with('\r') {
        s.pop();
    }
    Some(s)
}

pub fn toplevel(dir: &Path) -> Option<PathBuf> {
    run(dir, &["rev-parse", "--show-toplevel"])
        .map(|s| PathBuf::from(crate::util::msys_to_native(&s)))
}

/// 모든 워크트리가 함께 쓰는 .git 폴더(절대 경로).
pub fn common_dir(root: &Path) -> Option<PathBuf> {
    let s = run(
        root,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    Some(PathBuf::from(crate::util::msys_to_native(&s)))
}

pub fn head_sha(root: &Path) -> Option<String> {
    run(root, &["rev-parse", "HEAD"])
}

pub fn branch(root: &Path) -> Option<String> {
    run(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
}

/// 원격 기본 브랜치(origin/main 등). 모르면 main · master 중 있는 것.
pub fn default_branch(root: &Path) -> Option<String> {
    if let Some(s) = run(
        root,
        &[
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
    ) {
        return Some(s);
    }
    for cand in ["origin/main", "origin/master", "main", "master"] {
        if run(root, &["rev-parse", "--verify", "--quiet", cand]).is_some() {
            return Some(cand.into());
        }
    }
    None
}

pub fn merge_base(root: &Path, a: &str, b: &str) -> Option<String> {
    run(root, &["merge-base", a, b])
}

fn lines(s: Option<String>) -> Vec<String> {
    s.map(|t| {
        t.lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect()
    })
    .unwrap_or_default()
}

/// 바뀐 파일. `base` 가 있으면 그 커밋부터 작업 트리까지, 없으면 커밋하지 않은 변경만. 추적 안 하는 새 파일도 넣는다.
pub fn changed_files(root: &Path, base: Option<&str>, staged_only: bool) -> Vec<String> {
    let mut out = Vec::new();
    if staged_only {
        out.extend(lines(run(
            root,
            &["diff", "--name-only", "--cached", "--no-renames"],
        )));
    } else {
        match base {
            Some(b) => out.extend(lines(run(
                root,
                &["diff", "--name-only", "--no-renames", b],
            ))),
            None => out.extend(lines(run(
                root,
                &["diff", "--name-only", "--no-renames", "HEAD"],
            ))),
        }
        out.extend(lines(run(
            root,
            &["ls-files", "--others", "--exclude-standard"],
        )));
    }
    out.sort();
    out.dedup();
    out
}

/// 추적 파일 목록.
pub fn ls_files(root: &Path) -> Vec<String> {
    lines(run(
        root,
        &["ls-files", "--cached", "--others", "--exclude-standard"],
    ))
}

/// 작업 트리가 깨끗한지(추적 안 하는 새 파일도 변경으로 본다).
pub fn is_clean(root: &Path) -> bool {
    matches!(run(root, &["status", "--porcelain"]), Some(s) if s.trim().is_empty())
}

/// 원격 주소(origin).
pub fn remote_url(root: &Path) -> Option<String> {
    run(root, &["remote", "get-url", "origin"])
}
