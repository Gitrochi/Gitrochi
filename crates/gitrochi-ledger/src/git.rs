//! The system `git`, asked for machine-readable output. The ledger only reads tags, and
//! the hook handler reads the agent's branch for permission checks.

use crate::error::{Error, Result};
use std::path::Path;
use std::process::{Command, Stdio};

/// One tag: its name without `refs/tags/`, its date (the tagger's, or the commit's for a
/// lightweight tag) and the commit it points at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tag {
    pub name: String,
    pub time: i64,
    pub commit: String,
}

/// The git to run: `GITROCHI_GIT`, else `git` on PATH (the index does the same).
fn git_executable() -> String {
    std::env::var("GITROCHI_GIT")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "git".into())
}

fn command(repo: &Path) -> Command {
    let mut command = Command::new(git_executable());
    command
        .arg("-C")
        .arg(repo)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW: helpers started from the app must not flash a console.
        command.creation_flags(0x0800_0000);
    }
    command
}

/// `git for-each-ref refs/tags` with NUL-separated fields; ref names cannot hold newlines.
pub fn tags(repo: &Path) -> Result<Vec<Tag>> {
    let output = command(repo)
        .args([
            "for-each-ref",
            "--format=%(refname)%00%(creatordate:unix)%00%(objectname)%00%(*objectname)",
            "refs/tags",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| Error::new("GIT_FAILED", format!("Could not run git: {e}")))?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr);
        return Err(Error::new(
            "GIT_FAILED",
            format!(
                "git for-each-ref failed in {}: {}",
                repo.display(),
                message.lines().next().unwrap_or("").trim()
            ),
        ));
    }
    Ok(parse_tags(&String::from_utf8_lossy(&output.stdout)))
}

/// What a permission check needs to know about the agent's checkout: where it is, the
/// branch, the branch it pushes to on the remote, and the remote's default branch.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Checkout {
    pub root: String,
    pub branch: Option<String>,
    /// The upstream's name on its remote (`main`, not `origin/main`).
    pub upstream: Option<String>,
    /// `origin/HEAD`, when the clone recorded it.
    pub default_branch: Option<String>,
}

fn stdout_of(command: &mut Command) -> Option<String> {
    let output = command
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The checkout at `dir`, or `None` outside a repository. Each part that git cannot tell
/// (a detached HEAD, no upstream) stays empty.
pub fn checkout(dir: &Path) -> Option<Checkout> {
    let root = stdout_of(command(dir).args(["rev-parse", "--show-toplevel"]))?
        .trim()
        .to_string();
    if root.is_empty() {
        return None;
    }
    // symbolic-ref also names an unborn branch, and fails on a detached HEAD
    let branch = stdout_of(command(dir).args(["symbolic-ref", "--quiet", "--short", "HEAD"]))
        .map(|b| b.trim().to_string())
        .filter(|b| !b.is_empty());
    let mut refs = vec!["refs/remotes/origin/HEAD".to_string()];
    if let Some(branch) = &branch {
        refs.push(format!("refs/heads/{branch}"));
    }
    let listed = stdout_of(
        command(dir)
            .args([
                "for-each-ref",
                "--format=%(refname)%00%(upstream:remoteref)%00%(symref)",
            ])
            .args(&refs),
    )
    .unwrap_or_default();
    let (upstream, default_branch) = parse_checkout_refs(&listed, branch.as_deref());
    Some(Checkout {
        root,
        branch,
        upstream,
        default_branch,
    })
}

/// The upstream of `branch` and origin's default branch from `checkout`'s for-each-ref.
pub fn parse_checkout_refs(text: &str, branch: Option<&str>) -> (Option<String>, Option<String>) {
    let (mut upstream, mut default_branch) = (None, None);
    let mine = branch.map(|b| format!("refs/heads/{b}"));
    for line in text.lines() {
        let mut fields = line.split('\0');
        let (Some(name), Some(remote), Some(target)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        if Some(name) == mine.as_deref() {
            upstream = remote
                .strip_prefix("refs/heads/")
                .filter(|b| !b.is_empty())
                .map(str::to_string);
        } else if name == "refs/remotes/origin/HEAD" {
            default_branch = target
                .strip_prefix("refs/remotes/origin/")
                .filter(|b| !b.is_empty())
                .map(str::to_string);
        }
    }
    (upstream, default_branch)
}

pub fn parse_tags(text: &str) -> Vec<Tag> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split('\0');
            let name = fields.next()?.strip_prefix("refs/tags/")?.to_string();
            let time = fields.next()?.trim().parse().ok()?;
            let object = fields.next()?.to_string();
            let peeled = fields.next().unwrap_or("").to_string();
            Some(Tag {
                name,
                time,
                commit: if peeled.is_empty() { object } else { peeled },
            })
        })
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn checkout_refs_name_the_upstream_and_the_default_branch() {
        let text = "refs/remotes/origin/HEAD\x00\x00refs/remotes/origin/develop\nrefs/heads/feature/x\x00refs/heads/feature/x\x00\n";
        assert_eq!(
            parse_checkout_refs(text, Some("feature/x")),
            (Some("feature/x".into()), Some("develop".into()))
        );
        // no upstream, no origin/HEAD, a branch that pushes elsewhere
        assert_eq!(
            parse_checkout_refs("refs/heads/topic\x00\x00\n", Some("topic")),
            (None, None)
        );
        assert_eq!(
            parse_checkout_refs("refs/heads/topic\x00refs/heads/main\x00\n", Some("topic")),
            (Some("main".into()), None)
        );
        assert_eq!(parse_checkout_refs("garbage", None), (None, None));
    }

    /// git in a throwaway repository with its own configuration, as in tests/storage.rs.
    fn fixture_git(dir: &Path, repo: &Path, args: &[&str]) {
        let output = Command::new("git")
            .current_dir(repo)
            .args(args)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", dir.join("gitconfig"))
            .env("HOME", dir)
            .env("GIT_AUTHOR_NAME", "Fixture")
            .env("GIT_AUTHOR_EMAIL", "fixture@example.com")
            .env("GIT_COMMITTER_NAME", "Fixture")
            .env("GIT_COMMITTER_EMAIL", "fixture@example.com")
            .output()
            .expect("git runs");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    /// Branch `feature/hooks` with one commit, tracking `develop` on origin, whose HEAD is
    /// `develop`.
    pub(crate) fn fixture_repo(dir: &Path) -> std::path::PathBuf {
        let repo = dir.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let git = |args: &[&str]| fixture_git(dir, &repo, args);
        git(&["init", "-q"]);
        git(&["symbolic-ref", "HEAD", "refs/heads/feature/hooks"]);
        // an unborn branch already has its name
        let unborn = checkout(&repo).unwrap();
        assert_eq!(unborn.branch.as_deref(), Some("feature/hooks"));
        assert_eq!((unborn.upstream, unborn.default_branch), (None, None));
        git(&["commit", "-q", "--allow-empty", "-m", "first"]);
        git(&["remote", "add", "origin", "https://example.com/example.git"]);
        git(&["config", "branch.feature/hooks.remote", "origin"]);
        git(&["config", "branch.feature/hooks.merge", "refs/heads/develop"]);
        git(&["update-ref", "refs/remotes/origin/develop", "HEAD"]);
        git(&[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/develop",
        ]);
        repo.canonicalize().unwrap()
    }

    #[test]
    fn checkout_reads_the_branch_its_upstream_and_origins_default() {
        let dir =
            std::env::temp_dir().join(format!("gitrochi-ledger-checkout-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = fixture_repo(&dir);
        std::fs::create_dir_all(repo.join("src")).unwrap();
        let found = checkout(&repo.join("src")).unwrap();
        assert_eq!(found.branch.as_deref(), Some("feature/hooks"));
        assert_eq!(found.upstream.as_deref(), Some("develop"));
        assert_eq!(found.default_branch.as_deref(), Some("develop"));
        assert_eq!(Path::new(&found.root).canonicalize().unwrap(), repo);
        // a detached HEAD has no branch
        fixture_git(&dir, &repo, &["checkout", "-q", "--detach"]);
        let detached = checkout(&repo).unwrap();
        assert_eq!((detached.branch, detached.upstream), (None, None));
        assert_eq!(detached.default_branch.as_deref(), Some("develop"));
        // outside a repository there is nothing to read (unless the temporary folder
        // itself sits in one)
        let outside = dir.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        let in_a_repository = Command::new("git")
            .current_dir(&outside)
            .args(["rev-parse", "--show-toplevel"])
            .output()
            .unwrap()
            .status
            .success();
        if !in_a_repository {
            assert_eq!(checkout(&outside), None);
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn tag_lines_are_parsed() {
        let text = "refs/tags/v1.0.0\x001700000000\x00aaa\x00bbb\nrefs/tags/v1.1.0\x001700000100\x00ccc\x00\nrefs/heads/x\x001\x00d\x00\n";
        let tags = parse_tags(text);
        assert_eq!(
            tags,
            vec![
                Tag {
                    name: "v1.0.0".into(),
                    time: 1_700_000_000,
                    commit: "bbb".into()
                },
                Tag {
                    name: "v1.1.0".into(),
                    time: 1_700_000_100,
                    commit: "ccc".into()
                },
            ]
        );
    }
}
