//! Running the system git and parsing its machine-readable output. Nothing here
//! writes to the repository.

use crate::error::{Error, Result};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread::JoinHandle;

// Field order of one commit record; %aN/%aE follow .mailmap so identities line up.
const FORMAT: &str =
    "--format=%x1e%H%x00%T%x00%P%x00%aN%x00%aE%x00%at%x00%cN%x00%cE%x00%ct%x00%s%x00%b%x00";
const MAX_STDERR: usize = 16 * 1024;

/// The git to run: the caller's choice (the Windows app passes the git.exe it found),
/// else `GITROCHI_GIT`, else `git` on PATH.
fn git_executable(chosen: Option<&str>) -> String {
    chosen
        .filter(|v| !v.is_empty())
        .map(str::to_string)
        .or_else(|| std::env::var("GITROCHI_GIT").ok().filter(|v| !v.is_empty()))
        .unwrap_or_else(|| "git".into())
}

fn base_command(git: &str) -> Command {
    let mut command = Command::new(git);
    command
        .args([
            "-c",
            "core.quotePath=false",
            "-c",
            "log.showSignature=false",
        ])
        .args(["-c", "color.ui=false"])
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

fn first_line(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    text.lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim()
        .chars()
        .take(300)
        .collect()
}

/// A repository as git sees it: the work tree (or the git dir of a bare repository)
/// and the common dir that every worktree shares.
#[derive(Debug, Clone)]
pub struct Repo {
    pub top: PathBuf,
    pub common_dir: PathBuf,
    git: String,
}

impl Repo {
    pub fn discover(dir: &Path, git: Option<&str>) -> Result<Repo> {
        let git = git_executable(git);
        let output = base_command(&git)
            .arg("-C")
            .arg(dir)
            .args([
                "rev-parse",
                "--is-bare-repository",
                "--git-common-dir",
                "--show-toplevel",
            ])
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| Error::git(format!("Could not run git: {e}")))?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut lines = text.lines();
        let bare = lines.next().map(str::trim) == Some("true");
        let common = lines.next().map(str::trim).unwrap_or("");
        if common.is_empty() || (!output.status.success() && !bare) {
            return Err(Error::new(
                "NOT_A_REPOSITORY",
                format!("Not a Git repository: {}", dir.display()),
            ));
        }
        let common_dir = absolute(dir, common);
        let top = match lines.next().map(str::trim).filter(|t| !t.is_empty()) {
            Some(top) if !bare => absolute(dir, top),
            _ => common_dir.clone(),
        };
        Ok(Repo {
            top,
            common_dir,
            git,
        })
    }

    pub fn database(&self) -> PathBuf {
        self.common_dir.join("gitrochi").join("index.sqlite3")
    }

    pub fn command(&self) -> Command {
        let mut command = base_command(&self.git);
        command.arg("-C").arg(&self.top);
        command
    }

    pub fn output(&self, args: &[&str]) -> Result<Vec<u8>> {
        self.output_with_input(args, None)
    }

    pub fn output_with_input(&self, args: &[&str], input: Option<Vec<u8>>) -> Result<Vec<u8>> {
        let (code, stdout, stderr) = self.run(args, input)?;
        if code != Some(0) {
            return Err(Error::git(format!(
                "git {} failed: {}",
                args[0],
                first_line(&stderr)
            )));
        }
        Ok(stdout)
    }

    /// Runs git and returns its exit code with both outputs, for commands where a
    /// non-zero code is an answer (git grep exits with 1 when nothing matches).
    pub fn run(
        &self,
        args: &[&str],
        input: Option<Vec<u8>>,
    ) -> Result<(Option<i32>, Vec<u8>, Vec<u8>)> {
        let mut child = self
            .command()
            .args(args)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| Error::git(format!("Could not run git: {e}")))?;
        let writer = feed(&mut child, input);
        let output = child
            .wait_with_output()
            .map_err(|e| Error::git(format!("git {}: {e}", args[0])))?;
        if let Some(writer) = writer {
            let _ = writer.join();
        }
        Ok((output.status.code(), output.stdout, output.stderr))
    }

    /// Reads NUL- or newline-separated records from git as they come and stops git once
    /// `keep` returns false, so a match-everything pattern cannot fill memory. Returns
    /// git's exit code (None when stopped early) and its stderr.
    pub fn stream_lines(
        &self,
        args: &[&str],
        mut keep: impl FnMut(&[u8]) -> bool,
    ) -> Result<(Option<i32>, Vec<u8>)> {
        let mut child = self
            .command()
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| Error::git(format!("Could not run git: {e}")))?;
        let stderr = child.stderr.take().map(|mut stream| {
            std::thread::spawn(move || {
                let mut buffer = Vec::new();
                let _ = (&mut stream)
                    .take(MAX_STDERR as u64)
                    .read_to_end(&mut buffer);
                buffer
            })
        });
        let mut reader = BufReader::new(child.stdout.take().expect("piped stdout"));
        let mut line = Vec::new();
        let mut stopped = false;
        loop {
            line.clear();
            let read = reader
                .read_until(b'\n', &mut line)
                .map_err(|e| Error::git(format!("Reading git {} failed: {e}", args[0])))?;
            if read == 0 {
                break;
            }
            if line.last() == Some(&b'\n') {
                line.pop();
            }
            if !keep(&line) {
                stopped = true;
                break;
            }
        }
        if stopped {
            let _ = child.kill();
        }
        drop(reader);
        let status = child
            .wait()
            .map_err(|e| Error::git(format!("git {}: {e}", args[0])))?;
        let stderr = stderr.and_then(|h| h.join().ok()).unwrap_or_default();
        Ok((if stopped { None } else { status.code() }, stderr))
    }

    /// Ref tips to index: every ref (tags peeled) and HEAD, except the ones `excluded`
    /// leaves out.
    pub fn refs(&self) -> Result<Vec<(String, String)>> {
        let output = self.output(&[
            "for-each-ref",
            "--format=%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(refname)",
        ])?;
        let mut refs = Vec::new();
        // Ref names cannot contain control characters, so lines are safe to split.
        for line in output.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
            let fields: Vec<&[u8]> = line.split(|b| *b == 0).collect();
            if fields.len() != 5 {
                continue;
            }
            let (sha, kind) = if fields[2].is_empty() {
                (fields[0], fields[1])
            } else {
                (fields[2], fields[3])
            };
            let name = String::from_utf8_lossy(fields[4]).into_owned();
            if kind != b"commit" || excluded(&name) {
                continue;
            }
            refs.push((name, String::from_utf8_lossy(sha).into_owned()));
        }
        if let Ok(head) = self.output(&["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) {
            let head = String::from_utf8_lossy(&head).trim().to_string();
            if is_sha(&head) {
                refs.push(("HEAD".into(), head));
            }
        }
        refs.sort();
        refs.dedup();
        Ok(refs)
    }

    /// Which of the given objects still exist as commits (old tips may be gone after a
    /// force push and gc, and git refuses to exclude a missing commit).
    pub fn existing_commits(&self, shas: &[String]) -> Result<Vec<String>> {
        if shas.is_empty() {
            return Ok(vec![]);
        }
        let input: Vec<u8> = shas
            .iter()
            .flat_map(|s| format!("{s}\n").into_bytes())
            .collect();
        let output = self.output_with_input(&["cat-file", "--batch-check"], Some(input))?;
        Ok(String::from_utf8_lossy(&output)
            .lines()
            .filter_map(|line| {
                let mut parts = line.split(' ');
                let sha = parts.next()?;
                (parts.next() == Some("commit")).then(|| sha.to_string())
            })
            .collect())
    }

    pub fn head_tree(&self) -> Result<Option<String>> {
        match self.output(&["rev-parse", "--verify", "--quiet", "HEAD^{tree}"]) {
            Ok(out) => Ok(Some(String::from_utf8_lossy(&out).trim().to_string())),
            Err(_) => Ok(None),
        }
    }

    /// Paths in the HEAD tree, to leave deleted and renamed-away files out of reports.
    pub fn head_paths(&self) -> Result<Option<std::collections::HashSet<String>>> {
        if self.head_tree()?.is_none() {
            return Ok(None);
        }
        let output = self.output(&["ls-tree", "-r", "-z", "--name-only", "HEAD"])?;
        Ok(Some(
            output
                .split(|b| *b == 0)
                .filter(|p| !p.is_empty())
                .map(|p| String::from_utf8_lossy(p).into_owned())
                .collect(),
        ))
    }

    /// Streams commits reachable from `include` but not from `exclude`, newest first.
    pub fn log(
        &self,
        include: &[String],
        exclude: &[String],
        options: &LogOptions,
    ) -> Result<LogStream> {
        let mut args: Vec<String> = vec![
            "log".into(),
            "--stdin".into(),
            "--raw".into(),
            "--numstat".into(),
            "-z".into(),
            "--no-ext-diff".into(),
            "--no-textconv".into(),
            "--no-color".into(),
            if options.renames {
                "-M"
            } else {
                "--no-renames"
            }
            .into(),
            FORMAT.into(),
        ];
        // A user's log.diffMerges setting must not add merge diffs (git 2.31+ has both).
        if version_at_least(&self.git, 2, 31) {
            args.push("--diff-merges=off".into());
        }
        if let Some(limit) = options.limit {
            args.push(format!("--max-count={limit}"));
        }
        let mut input = String::new();
        for sha in include {
            input.push_str(sha);
            input.push('\n');
        }
        // `^sha` rather than `--not`: older git does not take options on stdin.
        for sha in exclude {
            input.push('^');
            input.push_str(sha);
            input.push('\n');
        }
        let mut child = self
            .command()
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| Error::git(format!("Could not run git log: {e}")))?;
        let writer = feed(&mut child, Some(input.into_bytes()));
        let stderr = child.stderr.take().map(|mut stream| {
            std::thread::spawn(move || {
                let mut buffer = Vec::new();
                let _ = (&mut stream)
                    .take(MAX_STDERR as u64)
                    .read_to_end(&mut buffer);
                buffer
            })
        });
        let stdout = child.stdout.take().expect("piped stdout");
        Ok(LogStream {
            child,
            reader: BufReader::with_capacity(256 * 1024, stdout),
            pending: None,
            writer,
            stderr,
            finished: false,
        })
    }
}

fn feed(child: &mut Child, input: Option<Vec<u8>>) -> Option<JoinHandle<()>> {
    let input = input?;
    let mut stdin = child.stdin.take()?;
    // A thread, so a large input cannot deadlock against git's output.
    Some(std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    }))
}

fn absolute(base: &Path, value: &str) -> PathBuf {
    let path = PathBuf::from(value);
    let joined = if path.is_absolute() {
        path
    } else {
        base.join(path)
    };
    joined.canonicalize().unwrap_or(joined)
}

// The apps search `--all --exclude=refs/stash`; of the rest only refs whose commits
// would distort the history (notes trees, filter-branch backups, replacements) stay out.
fn excluded(name: &str) -> bool {
    name == "refs/stash"
        || ["refs/notes/", "refs/original/", "refs/replace/"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

pub fn is_sha(text: &str) -> bool {
    (text.len() == 40 || text.len() == 64) && text.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Whether this git is at least `major.minor` (asked once per executable).
pub fn version_at_least(git: &str, major: u32, minor: u32) -> bool {
    static VERSIONS: OnceLock<Mutex<HashMap<String, (u32, u32)>>> = OnceLock::new();
    let versions = VERSIONS.get_or_init(Default::default);
    let known = versions
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(git)
        .copied();
    let version = known.unwrap_or_else(|| {
        let output = base_command(git).arg("version").output().ok();
        let text = output
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        // "git version 2.39.5 (Apple Git-154)" or "git version 2.47.1.windows.1"
        let number = text.split_whitespace().nth(2).unwrap_or("0.0");
        let mut parts = number.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
        let version = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
        versions
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(git.to_string(), version);
        version
    });
    version >= (major, minor)
}

#[derive(Debug, Clone, Default)]
pub struct LogOptions {
    pub renames: bool,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawChange {
    pub path: String,
    pub old_path: Option<String>,
    pub status: char,
    pub similarity: Option<i64>,
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawCommit {
    pub sha: String,
    pub tree: String,
    pub parents: Vec<String>,
    pub author_name: String,
    pub author_email: String,
    pub author_time: i64,
    pub committer_name: String,
    pub committer_email: String,
    pub commit_time: i64,
    pub subject: String,
    pub body: String,
    pub files: Vec<RawChange>,
}

/// Commits parsed one at a time from `git log --raw --numstat -z`.
pub struct LogStream {
    child: Child,
    reader: BufReader<ChildStdout>,
    pending: Option<Vec<u8>>,
    writer: Option<JoinHandle<()>>,
    stderr: Option<JoinHandle<Vec<u8>>>,
    finished: bool,
}

impl LogStream {
    fn token(&mut self) -> Result<Option<Vec<u8>>> {
        if let Some(token) = self.pending.take() {
            return Ok(Some(token));
        }
        let mut buffer = Vec::new();
        let read = self
            .reader
            .read_until(0, &mut buffer)
            .map_err(|e| Error::git(format!("Reading git log failed: {e}")))?;
        if read == 0 {
            return Ok(None);
        }
        if buffer.last() == Some(&0) {
            buffer.pop();
        }
        Ok(Some(buffer))
    }

    fn field(&mut self) -> Result<String> {
        let token = self.token()?.ok_or_else(truncated)?;
        Ok(String::from_utf8_lossy(&token).into_owned())
    }

    fn finish(&mut self) -> Result<()> {
        self.finished = true;
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        let status = self
            .child
            .wait()
            .map_err(|e| Error::git(format!("git log: {e}")))?;
        let stderr = self
            .stderr
            .take()
            .and_then(|h| h.join().ok())
            .unwrap_or_default();
        if status.success() {
            Ok(())
        } else {
            Err(Error::git(format!(
                "git log failed: {}",
                first_line(&stderr)
            )))
        }
    }

    fn next_commit(&mut self) -> Result<Option<RawCommit>> {
        let Some(first) = self.token()? else {
            self.finish()?;
            return Ok(None);
        };
        if first.first() != Some(&0x1e) {
            return Err(truncated());
        }
        let sha = String::from_utf8_lossy(&first[1..]).into_owned();
        if !is_sha(&sha) {
            return Err(truncated());
        }
        let tree = self.field()?;
        let parents = self.field()?;
        let author_name = self.field()?;
        let author_email = self.field()?;
        let author_time = self.field()?.trim().parse().unwrap_or(0);
        let committer_name = self.field()?;
        let committer_email = self.field()?;
        let commit_time = self.field()?.trim().parse().unwrap_or(0);
        let subject = self.field()?;
        let body = self.field()?.trim_end().to_string();
        let mut changes: Vec<RawChange> = Vec::new();
        let mut counts: std::collections::HashMap<String, (Option<i64>, Option<i64>)> =
            std::collections::HashMap::new();
        while let Some(token) = self.token()? {
            if token.first() == Some(&0x1e) {
                self.pending = Some(token);
                break;
            }
            let entry = token.strip_prefix(b"\n").unwrap_or(&token);
            if entry.is_empty() {
                continue;
            }
            if entry[0] == b':' {
                // ":100644 100644 abc1234 def5678 R066", then the path(s).
                let header = String::from_utf8_lossy(entry);
                let code = header.rsplit(' ').next().unwrap_or("M");
                let status = code.chars().next().unwrap_or('M');
                let similarity = code[status.len_utf8()..].parse().ok();
                let first_path = self.field()?;
                let (old_path, path) = if matches!(status, 'R' | 'C') {
                    (Some(first_path), self.field()?)
                } else {
                    (None, first_path)
                };
                changes.push(RawChange {
                    path,
                    old_path,
                    status,
                    similarity,
                    additions: None,
                    deletions: None,
                });
            } else {
                // "12\t3\tpath", "-\t-\tpath" for binary files, "1\t0\t" then old, new for renames.
                let mut parts = entry.splitn(3, |b| *b == b'\t');
                let additions = parse_count(parts.next().unwrap_or(b"-"));
                let deletions = parse_count(parts.next().unwrap_or(b"-"));
                let rest = parts.next().unwrap_or(b"");
                let path = if rest.is_empty() {
                    let _old = self.field()?;
                    self.field()?
                } else {
                    String::from_utf8_lossy(rest).into_owned()
                };
                counts.insert(path, (additions, deletions));
            }
        }
        for change in &mut changes {
            if let Some((additions, deletions)) = counts.get(&change.path) {
                change.additions = *additions;
                change.deletions = *deletions;
            }
        }
        Ok(Some(RawCommit {
            sha,
            tree,
            parents: parents.split_whitespace().map(str::to_string).collect(),
            author_name,
            author_email,
            author_time,
            committer_name,
            committer_email,
            commit_time,
            subject,
            body,
            files: changes,
        }))
    }
}

fn parse_count(bytes: &[u8]) -> Option<i64> {
    std::str::from_utf8(bytes).ok()?.parse().ok()
}

fn truncated() -> Error {
    Error::git("Unexpected git log output")
}

impl Iterator for LogStream {
    type Item = Result<RawCommit>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.finished {
            return None;
        }
        match self.next_commit() {
            Ok(Some(commit)) => Some(Ok(commit)),
            Ok(None) => None,
            Err(error) => {
                // Stop and reap git now, so a long-running app keeps no zombie process.
                let _ = self.child.kill();
                let _ = self.child.wait();
                self.finished = true;
                Some(Err(error))
            }
        }
    }
}

impl Drop for LogStream {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}
