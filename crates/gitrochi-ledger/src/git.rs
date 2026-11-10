//! The system `git`, asked for machine-readable output. The ledger only reads tags, the
//! hook handler reads the agent's branch for permission checks, and `track` reads where a
//! launch starts and whether its branch has moved since.

use crate::error::{Error, Result};
use std::collections::HashMap;
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
    list_tags(repo, false)
}

/// The tags reachable from the checkout's HEAD: where a new session's work starts from.
pub fn reachable_tags(dir: &Path) -> Result<Vec<Tag>> {
    list_tags(dir, true)
}

fn list_tags(repo: &Path, reachable: bool) -> Result<Vec<Tag>> {
    let mut command = command(repo);
    command.args([
        "for-each-ref",
        "--format=%(refname)%00%(creatordate:unix)%00%(objectname)%00%(*objectname)",
    ]);
    if reachable {
        command.arg("--merged=HEAD");
    }
    let output = command
        .arg("refs/tags")
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

/// Where a launch starts: HEAD's commit (`None` before the first commit), and whether the
/// folder is in a linked worktree rather than the repository's main checkout.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Start {
    pub head: Option<String>,
    pub linked: bool,
}

/// The start of a launch in `dir`, or `None` outside a repository.
pub fn start(dir: &Path) -> Option<Start> {
    // a linked worktree has a git dir of its own next to the repository's common one
    let dirs = stdout_of(command(dir).args([
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
        "--git-common-dir",
    ]))?;
    let mut lines = dirs.lines().map(str::trim);
    let (own, common) = (lines.next()?, lines.next()?);
    Some(Start {
        head: head_commit(dir),
        linked: own != common,
    })
}

/// The repository's main checkout seen from any of its worktrees, or `None` outside a repository.
/// git lists it first, whichever worktree asks.
pub fn main_checkout(dir: &Path) -> Option<String> {
    stdout_of(command(dir).args(["worktree", "list", "--porcelain"]))?
        .lines()
        .next()?
        .strip_prefix("worktree ")
        .filter(|path| !path.is_empty())
        .map(str::to_string)
}

/// The commit HEAD is on in `dir`, or `None` before the first commit or outside a repository.
pub fn head_commit(dir: &Path) -> Option<String> {
    stdout_of(command(dir).args(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]))
        .map(|h| h.trim().to_string())
        .filter(|h| !h.is_empty())
}

/// The URL of `dir`'s `origin` remote, else of its first remote; `None` without one or
/// outside a repository. For the team hub's repository key only; never shown or stored.
pub fn remote_url(dir: &Path) -> Option<String> {
    let url = |name: &str| {
        stdout_of(command(dir).args(["remote", "get-url", name]))
            .map(|u| u.trim().to_string())
            .filter(|u| !u.is_empty())
    };
    url("origin").or_else(|| {
        let names = stdout_of(command(dir).arg("remote"))?;
        url(names.lines().next()?.trim())
    })
}

/// The tip of every local branch of `dir`'s repository by branch name, or `None` when git
/// cannot tell (not a repository): one call for all of a repository's branches.
pub fn branch_tips(dir: &Path) -> Option<HashMap<String, String>> {
    let listed = stdout_of(command(dir).args([
        "for-each-ref",
        "--format=%(refname)%00%(objectname)",
        "refs/heads",
    ]))?;
    Some(
        listed
            .lines()
            .filter_map(|line| {
                let (name, commit) = line.split_once('\0')?;
                Some((
                    name.strip_prefix("refs/heads/")?.to_string(),
                    commit.to_string(),
                ))
            })
            .collect(),
    )
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
        real_path(&repo)
    }

    /// The real path (macOS's temporary folder is behind a symlink, git reports the real
    /// one), without the `\\?\` prefix Windows adds, which not every git accepts.
    pub(crate) fn real_path(path: &Path) -> std::path::PathBuf {
        let real = path.canonicalize().unwrap();
        match real.to_str().and_then(|p| p.strip_prefix(r"\\?\")) {
            Some(plain) => std::path::PathBuf::from(plain),
            None => real,
        }
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
        assert_eq!(real_path(Path::new(&found.root)), repo);
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
    fn start_tells_a_linked_worktree_and_the_tips_follow_its_branch() {
        let dir =
            std::env::temp_dir().join(format!("gitrochi-ledger-start-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = fixture_repo(&dir);
        let main = start(&repo).unwrap();
        assert!(!main.linked, "the main checkout");
        let head = main.head.unwrap();
        assert_eq!(head.len(), 40);
        let worktree = dir.join("worktree");
        let path = worktree.to_string_lossy().into_owned();
        fixture_git(
            &dir,
            &repo,
            &["worktree", "add", "-q", "-b", "retry", &path],
        );
        let linked = start(&worktree).unwrap();
        assert_eq!(
            (linked.linked, linked.head.as_deref()),
            (true, Some(head.as_str()))
        );
        // every worktree names the same main checkout
        let main_root = checkout(&repo).unwrap().root;
        assert_eq!(main_checkout(&worktree), Some(main_root.clone()));
        assert_eq!(main_checkout(&repo), Some(main_root));
        assert_eq!(main_checkout(&dir.join("not-a-repository")), None);
        // every branch's tip in one call, from any folder of the repository
        let tips = branch_tips(&repo).unwrap();
        assert_eq!(tips.get("retry"), Some(&head));
        assert_eq!(tips.get("feature/hooks"), Some(&head));
        fixture_git(
            &dir,
            &worktree,
            &["commit", "-q", "--allow-empty", "-m", "second"],
        );
        let moved = branch_tips(&worktree).unwrap();
        assert_ne!(moved.get("retry"), Some(&head));
        assert_eq!(moved.get("retry"), head_commit(&worktree).as_ref());
        assert_eq!(moved.get("gone"), None);
        assert_eq!(branch_tips(&dir.join("not-a-repository")), None);
        // before the first commit there is no HEAD to start from
        let empty = dir.join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        fixture_git(&dir, &empty, &["init", "-q"]);
        assert_eq!(
            start(&empty),
            Some(Start {
                head: None,
                linked: false
            })
        );
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
