//! The system `git`, asked for machine-readable output. The ledger only reads tags.

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
mod tests {
    use super::*;

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
