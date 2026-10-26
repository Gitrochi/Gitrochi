//! Calls the system git. The engine never reimplements git; it only reads machine-readable output.

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

/// Stdout without the final newline on success, None on failure.
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

/// The .git folder all worktrees share (absolute path).
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

/// The remote default branch (origin/main and so on); otherwise main or master, whichever exists.
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

/// Changed files: from `base` to the working tree, or only uncommitted changes without it. New untracked files count.
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

/// Tracked files.
pub fn ls_files(root: &Path) -> Vec<String> {
    lines(run(
        root,
        &["ls-files", "--cached", "--others", "--exclude-standard"],
    ))
}

/// Whether the working tree is clean (new untracked files count as changes).
pub fn is_clean(root: &Path) -> bool {
    matches!(run(root, &["status", "--porcelain"]), Some(s) if s.trim().is_empty())
}

/// The origin remote's URL.
pub fn remote_url(root: &Path) -> Option<String> {
    run(root, &["remote", "get-url", "origin"])
}
