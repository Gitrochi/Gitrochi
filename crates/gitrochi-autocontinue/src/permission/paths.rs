//! Lexical paths for POSIX and Windows: `.` and `..` are folded, nothing touches the disk
//! and symlinks are not followed, so the caller passes a canonical repository root.

/// An absolute path split into components. Windows paths keep their drive (or UNC share)
/// and compare without case, POSIX paths compare exactly: treating two different POSIX
/// folders as one could let a write through, the reverse only holds one for the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AbsPath {
    windows: bool,
    root: String,
    parts: Vec<String>,
}

impl AbsPath {
    pub(crate) fn parse(text: &str) -> Option<Self> {
        let t = text.trim();
        let b = t.as_bytes();
        if b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':' {
            if b.len() > 2 && b[2] != b'\\' && b[2] != b'/' {
                // `C:foo` is relative to the drive's own working folder
                return None;
            }
            let root = format!("{}:", (b[0] as char).to_ascii_lowercase());
            return Some(Self::new(true, root).joined(&t[2..]));
        }
        if let Some(rest) = t.strip_prefix("\\\\") {
            let mut parts = rest.split(['\\', '/']).filter(|p| !p.is_empty());
            let server = parts.next()?;
            let share = parts.next()?;
            let root = format!("//{}/{}", server.to_lowercase(), share.to_lowercase());
            let tail: Vec<&str> = parts.collect();
            return Some(Self::new(true, root).joined(&tail.join("/")));
        }
        if t.starts_with('/') {
            return Some(Self::new(false, String::new()).joined(t));
        }
        None
    }

    fn new(windows: bool, root: String) -> Self {
        Self {
            windows,
            root,
            parts: Vec::new(),
        }
    }

    fn joined(mut self, rel: &str) -> Self {
        let windows = self.windows;
        for part in rel.split(|c| c == '/' || (windows && c == '\\')) {
            match part {
                "" | "." => {}
                ".." => {
                    self.parts.pop();
                }
                p => self.parts.push(p.to_string()),
            }
        }
        self
    }

    pub(crate) fn join(&self, rel: &str) -> Self {
        self.clone().joined(rel)
    }

    pub(crate) fn is_windows(&self) -> bool {
        self.windows
    }

    pub(crate) fn parts(&self) -> &[String] {
        &self.parts
    }

    pub(crate) fn starts_with(&self, base: &AbsPath) -> bool {
        self.windows == base.windows
            && self.root == base.root
            && self.parts.len() >= base.parts.len()
            && base
                .parts
                .iter()
                .zip(&self.parts)
                .all(|(a, b)| same_part(a, b, self.windows))
    }

    /// The components below `base`, when the path is inside it.
    pub(crate) fn below(&self, base: &AbsPath) -> Option<&[String]> {
        self.starts_with(base)
            .then(|| &self.parts[base.parts.len()..])
    }

    pub(crate) fn display(&self) -> String {
        if self.windows {
            let sep = if self.root.starts_with("//") {
                "/"
            } else {
                "\\"
            };
            let mut out = self.root.clone();
            if self.root.starts_with("//") {
                for p in &self.parts {
                    out.push('/');
                    out.push_str(p);
                }
                return out;
            }
            out.push_str(sep);
            out.push_str(&self.parts.join(sep));
            out
        } else {
            format!("/{}", self.parts.join("/"))
        }
    }
}

fn same_part(a: &str, b: &str, windows: bool) -> bool {
    if windows {
        a.to_lowercase() == b.to_lowercase()
    } else {
        a == b
    }
}

/// Files and folders that hold keys, tokens or account settings, as component sequences
/// matched anywhere in a path (case is ignored: macOS and Windows file systems ignore it).
const CREDENTIAL_PATHS: &[&[&str]] = &[
    &[".ssh"],
    &[".gnupg"],
    &[".gitconfig"],
    &[".git-credentials"],
    &[".netrc"],
    &["_netrc"],
    &[".config", "gitsw"],
    &[".config", "git", "credentials"],
    &[".config", "git", "config"],
    &[".config", "gh"],
    &[".config", "glab-cli"],
    &[".config", "gcloud"],
    &[".aws"],
    &[".azure"],
    &[".kube"],
    &[".docker", "config.json"],
    &[".npmrc"],
    &[".pypirc"],
    &[".cargo", "credentials"],
    &[".cargo", "credentials.toml"],
    &[".gem", "credentials"],
    &[".password-store"],
    &[".vault-token"],
    &[".terraform.d", "credentials.tfrc.json"],
    &[".claude", ".credentials.json"],
    &["Library", "Keychains"],
];

/// Agent settings that can add hooks, permissions or MCP servers.
const AGENT_SETTINGS: &[&[&str]] = &[
    &[".claude", "settings.json"],
    &[".claude", "settings.local.json"],
    &[".mcp.json"],
];

fn contains_sequence(parts: &[String], seq: &[&str]) -> bool {
    parts.windows(seq.len()).any(|w| {
        w.iter()
            .zip(seq)
            .all(|(a, b)| a.to_lowercase() == b.to_lowercase())
    })
}

/// Components of a path-like word, split on both separators.
pub(crate) fn split_text(text: &str) -> Vec<String> {
    text.split(['/', '\\'])
        .filter(|p| !p.is_empty() && *p != ".")
        .map(|p| p.trim_start_matches('~').to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

pub(crate) fn credential_parts(parts: &[String]) -> bool {
    CREDENTIAL_PATHS
        .iter()
        .any(|seq| contains_sequence(parts, seq))
}

pub(crate) fn agent_settings_parts(parts: &[String]) -> bool {
    AGENT_SETTINGS
        .iter()
        .any(|seq| contains_sequence(parts, seq))
}

/// Writes that would end up inside a `.git` folder (hooks, config) or replace a worktree's
/// `.git` file.
pub(crate) fn git_internal_parts(parts: &[String]) -> bool {
    parts.iter().any(|p| p.eq_ignore_ascii_case(".git"))
}
