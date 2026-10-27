//! Shared helpers for integration tests: run the executable in a temporary repository and HOME. Real user settings are never touched.
//! Each test sets the actor (person, script, AI), the same way as gitch's test helper (t_setup).
#![allow(dead_code)]

pub mod fake;

use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;

pub struct Fx {
    pub dir: PathBuf,
}

impl Fx {
    pub fn new(files: &[(&str, &str)]) -> Fx {
        let dir = std::env::temp_dir().join(format!("gf-cli-{}-{}", std::process::id(), rand()));
        std::fs::create_dir_all(dir.join("home")).unwrap();
        std::fs::create_dir_all(dir.join("repo")).unwrap();
        // A configuration file in the temporary HOME keeps the user's git settings (global hooks, templates) out.
        std::fs::write(
            dir.join("home").join("gitconfig"),
            "[user]\n\tname = Flow Test\n\temail = flow-test@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n",
        )
        .unwrap();
        let fx = Fx { dir };
        fx.git(&["init", "-q"]);
        for (p, c) in files {
            fx.write(p, c);
        }
        fx
    }
    /// Runs git in the temporary repository (with the temporary HOME's settings only).
    pub fn git(&self, args: &[&str]) -> String {
        let o = Command::new("git")
            .args(args)
            .current_dir(self.repo())
            .env("HOME", self.home())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", self.home().join("gitconfig"))
            .output()
            .unwrap();
        assert!(
            o.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
        String::from_utf8_lossy(&o.stdout).to_string()
    }
    /// Commits the whole working tree.
    pub fn commit(&self, msg: &str) {
        self.git(&["add", "-A"]);
        self.git(&["commit", "-q", "-m", msg]);
    }
    pub fn repo(&self) -> PathBuf {
        self.dir.join("repo")
    }
    pub fn home(&self) -> PathBuf {
        self.dir.join("home")
    }
    pub fn write(&self, p: &str, c: &str) {
        let path = self.repo().join(p);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, c).unwrap();
    }
    pub fn cmd(&self, actor: &str, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_gitch-flow"));
        c.args(args).current_dir(self.repo()).env_clear();
        c.env("PATH", std::env::var("PATH").unwrap_or_default());
        // Winsock needs SystemRoot to load its providers in the isolated Windows process.
        #[cfg(windows)]
        if let Some(root) = std::env::var_os("SystemRoot") {
            c.env("SystemRoot", root);
        }
        c.env("HOME", self.home());
        c.env("XDG_CONFIG_HOME", self.home().join(".config"));
        c.env("XDG_STATE_HOME", self.home().join(".local/state"));
        c.env("XDG_CACHE_HOME", self.home().join(".cache"));
        c.env("TMPDIR", std::env::temp_dir());
        c.env("LANG", "C");
        c.env("GITCH_FLOW_NO_KEYSTORE", "1");
        c.env("GIT_CONFIG_NOSYSTEM", "1");
        c.env("GIT_CONFIG_GLOBAL", self.home().join("gitconfig"));
        match actor {
            "claude" => {
                c.env("CLAUDECODE", "1");
            }
            other => {
                c.env("GITSW_ACTOR", other);
            }
        }
        c
    }
    pub fn run(&self, actor: &str, args: &[&str]) -> (i32, String, String) {
        let o = self.cmd(actor, args).output().unwrap();
        (
            o.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&o.stdout).to_string(),
            String::from_utf8_lossy(&o.stderr).to_string(),
        )
    }
    pub fn json(&self, actor: &str, args: &[&str]) -> (i32, Value) {
        let (c, out, err) = self.run(actor, args);
        let v = serde_json::from_str(&out).unwrap_or_else(|_| {
            serde_json::from_str(err.lines().last().unwrap_or("null")).unwrap_or(Value::Null)
        });
        (c, v)
    }
    pub fn trust(&self) {
        let (c, _, e) = self.run("script", &["trust", "--yes"]);
        assert_eq!(c, 0, "trust failed: {e}");
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

pub fn rand() -> String {
    // Tests run in parallel; a sequence number keeps folders made at the same moment apart.
    static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!(
        "{:x}-{}",
        n & 0xffff_ffff,
        N.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
    )
}
