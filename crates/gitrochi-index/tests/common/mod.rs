//! Temporary repositories for the integration tests. Git runs with a private HOME and
//! global config, so the developer's own settings and hooks never apply.

#![allow(dead_code)]

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

pub struct Fixture {
    pub root: PathBuf,
    pub repo: PathBuf,
    pub db: PathBuf,
    home: PathBuf,
    clock: i64,
}

impl Fixture {
    pub fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "gitrochi-index-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&root);
        let repo = root.join("repo");
        let home = root.join("home");
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join("gitconfig"), "").unwrap();
        let fixture = Self {
            db: root.join("index.sqlite3"),
            root,
            repo,
            home,
            clock: 1_780_000_000,
        };
        fixture.git(&["init", "-q", "-b", "main"]);
        fixture.git(&["config", "user.name", "Fixture Author"]);
        fixture.git(&["config", "user.email", "fixture@example.com"]);
        fixture.git(&["config", "core.autocrlf", "false"]);
        fixture
    }

    pub fn command(&self) -> Command {
        let mut command = Command::new("git");
        command
            .current_dir(&self.repo)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", self.home.join("gitconfig"))
            .env("HOME", &self.home)
            .env("GIT_TERMINAL_PROMPT", "0");
        command
    }

    pub fn git(&self, args: &[&str]) -> String {
        let output = self.command().args(args).output().expect("git runs");
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    pub fn write(&self, path: &str, content: &str) {
        let file = self.repo.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, content).unwrap();
    }

    /// Commits the given files as `author` one hour after the previous commit.
    pub fn commit_as(
        &mut self,
        author: (&str, &str),
        message: &str,
        files: &[(&str, &str)],
    ) -> String {
        for (path, content) in files {
            self.write(path, content);
        }
        self.git(&["add", "-A"]);
        // The fixture's own identity, like the repository's other test-repo scripts.
        self.git(&["config", "user.name", author.0]);
        self.git(&["config", "user.email", author.1]);
        self.clock += 3600;
        let date = format!("@{} +0000", self.clock);
        let output = self
            .command()
            .args(["commit", "-q", "--allow-empty", "-m", message])
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_DATE", &date)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        self.git(&["rev-parse", "HEAD"])
    }

    pub fn commit(&mut self, message: &str, files: &[(&str, &str)]) -> String {
        self.commit_as(("Fixture Author", "fixture@example.com"), message, files)
    }

    pub fn run(&self, command: &str, args: Value) -> Value {
        gitrochi_index::run(Some(&self.repo), Some(&self.db), command, &args)
            .unwrap_or_else(|e| panic!("{command} failed: {e}"))
    }

    pub fn fails(&self, command: &str, args: Value) -> gitrochi_index::Error {
        gitrochi_index::run(Some(&self.repo), Some(&self.db), command, &args).unwrap_err()
    }

    /// Runs the built `gitrochi-index` binary; returns (exit code, parsed stdout).
    pub fn cli(&self, args: &[&str]) -> (i32, Value) {
        let output = Command::new(env!("CARGO_BIN_EXE_gitrochi-index"))
            .arg("--repo")
            .arg(&self.repo)
            .arg("--db")
            .arg(&self.db)
            .args(args)
            .env("HOME", &self.home)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", self.home.join("gitconfig"))
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&output.stdout);
        let value = serde_json::from_str(text.trim()).unwrap_or(Value::Null);
        (output.status.code().unwrap_or(-1), value)
    }

    pub fn path(&self) -> &Path {
        &self.repo
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

pub fn shas(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["sha"].as_str().or(c.as_str()).unwrap().to_string())
        .collect()
}

pub fn subjects(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["subject"].as_str().unwrap().to_string())
        .collect()
}
