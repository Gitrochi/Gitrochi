//! 실행 기록. `<git 공통 폴더>/gitch/flow/runs/<워크트리ID>/<실행ID>/` 에 계획 · 이벤트 · 로그 · 보고서를 둔다.
//! 이벤트는 파일에 먼저 쓰고 내보낸다(앱이 다시 켜져도 이어 읽게). 게이트가 믿는 요약은 HMAC 으로 서명한다.

use crate::mask::Masker;
use crate::util;
use serde_json::{json, Map, Value};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub struct Store {
    pub root: PathBuf,
    pub base: PathBuf,
    pub worktree_id: String,
}

impl Store {
    pub fn open(root: &Path) -> Option<Store> {
        let common = crate::git::common_dir(root)?;
        let canonical = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
        let worktree_id =
            util::sha256_hex(canonical.to_string_lossy().as_bytes())[..12].to_string();
        Some(Store {
            root: root.to_path_buf(),
            base: common.join("gitch").join("flow"),
            worktree_id,
        })
    }

    pub fn runs_dir(&self) -> PathBuf {
        self.base.join("runs").join(&self.worktree_id)
    }

    pub fn run_dir(&self, id: &str) -> PathBuf {
        self.runs_dir().join(id)
    }

    pub fn new_run_id() -> String {
        format!(
            "{}-{}",
            util::compact_stamp(util::now_ms()),
            util::random_hex(3)
        )
    }

    /// 실행 ID 목록(새것부터).
    pub fn run_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = std::fs::read_dir(self.runs_dir())
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .filter(|e| e.path().is_dir())
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .collect()
            })
            .unwrap_or_default();
        ids.sort();
        ids.reverse();
        ids
    }

    /// 전체 ID 또는 앞부분 · `last` 로 찾는다.
    pub fn resolve(&self, key: &str, flow: Option<&str>) -> Option<String> {
        let ids = self.run_ids();
        if key == "last" || key == "--last" || key.is_empty() {
            return ids.into_iter().find(|id| {
                flow.map(|f| self.read_run(id).map(|r| r["flow"] == f).unwrap_or(false))
                    .unwrap_or(true)
            });
        }
        if ids.iter().any(|i| i == key) {
            return Some(key.to_string());
        }
        let matches: Vec<String> = ids
            .into_iter()
            .filter(|i| i.starts_with(key) || i.ends_with(key))
            .collect();
        if matches.len() == 1 {
            matches.into_iter().next()
        } else {
            None
        }
    }

    pub fn read_run(&self, id: &str) -> Option<Value> {
        let text = std::fs::read_to_string(self.run_dir(id).join("run.json")).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn write_run(&self, id: &str, run: &Value) -> std::io::Result<()> {
        util::write_atomic(
            &self.run_dir(id).join("run.json"),
            serde_json::to_string_pretty(run)
                .unwrap_or_default()
                .as_bytes(),
        )
    }

    pub fn lock_path(&self, flow: &str, env: &str) -> PathBuf {
        self.base.join("locks").join(format!(
            "{}-{}-{}.lock",
            self.worktree_id,
            safe(flow),
            safe(env)
        ))
    }

    pub fn idem_path(&self, key: &str) -> PathBuf {
        self.base
            .join("idem")
            .join(&util::sha256_hex(key.as_bytes())[..24])
    }

    pub fn hold_path(&self, env: &str) -> PathBuf {
        self.base.join("holds").join(format!("{}.json", safe(env)))
    }

    /// 오래된 실행을 지운다. 흐름마다 최근 `keep` 개는 남긴다.
    pub fn gc(&self, older_than_ms: u64, keep: usize, dry_run: bool) -> Vec<String> {
        let now = util::now_ms();
        let mut per_flow: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
        let mut removed = Vec::new();
        for id in self.run_ids() {
            let run = self.read_run(&id);
            let flow = run
                .as_ref()
                .and_then(|r| r["flow"].as_str().map(|s| s.to_string()))
                .unwrap_or_default();
            let n = per_flow.entry(flow).or_insert(0);
            *n += 1;
            let finished = run
                .as_ref()
                .and_then(|r| r["finishedAtMs"].as_u64())
                .unwrap_or(0);
            let running = run
                .as_ref()
                .map(|r| r["state"] == "RUNNING" || r["state"] == "PENDING")
                .unwrap_or(false);
            if running && pid_alive(&self.run_dir(&id)) {
                continue;
            }
            if *n > keep && finished > 0 && now.saturating_sub(finished) > older_than_ms {
                if !dry_run {
                    let _ = std::fs::remove_dir_all(self.run_dir(&id));
                }
                removed.push(id);
            }
        }
        removed
    }
}

pub fn safe(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// 실행 폴더의 pid 파일이 살아 있는 프로세스를 가리키는지.
pub fn pid_alive(run_dir: &Path) -> bool {
    let Some(pid) = std::fs::read_to_string(run_dir.join("pid"))
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
    else {
        return false;
    };
    process_alive(pid)
}

pub fn process_alive(pid: u32) -> bool {
    #[cfg(unix)]
    unsafe {
        libc::kill(pid as i32, 0) == 0
            || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        };
        unsafe {
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if h.is_null() {
                return false;
            }
            let mut code: u32 = 0;
            let ok = GetExitCodeProcess(h, &mut code) != 0;
            CloseHandle(h);
            ok && code == 259 // STILL_ACTIVE
        }
    }
}

// ---------- 이벤트 ----------

pub struct Events {
    inner: Mutex<(File, u64)>,
    run_id: String,
    echo: bool,
    masker: Arc<Masker>,
}

impl Events {
    pub fn create(
        path: &Path,
        run_id: &str,
        echo: bool,
        masker: Arc<Masker>,
    ) -> std::io::Result<Events> {
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        // 이어 쓰기: 같은 실행을 다시 열어도 seq 가 이어지게 마지막 번호를 읽는다.
        let last = last_seq(path);
        let f = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Events {
            inner: Mutex::new((f, last)),
            run_id: run_id.to_string(),
            echo,
            masker,
        })
    }

    /// 이벤트 하나를 쓴다(마스킹 → 파일 → 표준출력).
    pub fn emit(&self, ty: &str, node: Option<&str>, data: Value) -> u64 {
        let data = self.masker.mask_value(&data);
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        g.1 += 1;
        let seq = g.1;
        let mut ev = Map::new();
        ev.insert("schemaVersion".into(), json!(1));
        ev.insert("runId".into(), json!(self.run_id));
        ev.insert("seq".into(), json!(seq));
        ev.insert("at".into(), json!(util::rfc3339(util::now_ms())));
        ev.insert("type".into(), json!(ty));
        if let Some(n) = node {
            ev.insert("node".into(), json!(n));
        }
        ev.insert("data".into(), data);
        let line = Value::Object(ev).to_string();
        let _ = writeln!(g.0, "{line}");
        let _ = g.0.flush();
        if self.echo {
            let out = std::io::stdout();
            let mut o = out.lock();
            let _ = writeln!(o, "{line}");
            let _ = o.flush();
        }
        seq
    }
}

fn last_seq(path: &Path) -> u64 {
    let Ok(f) = File::open(path) else { return 0 };
    let mut last = 0;
    for line in BufReader::new(f).lines().map_while(Result::ok) {
        if let Ok(v) = serde_json::from_str::<Value>(&line) {
            last = last.max(v["seq"].as_u64().unwrap_or(0));
        }
    }
    last
}

/// 이벤트 파일을 재생하고, `follow` 면 `run.done` 이 나올 때까지 따라간다.
/// 실행 프로세스가 사라졌는데 done 이 없으면 만들어 알려 준다.
pub fn follow(run_dir: &Path, since: u64, follow: bool, on: &mut dyn FnMut(&Value)) {
    let path = run_dir.join("events.ndjson");
    let mut offset: u64 = 0;
    let mut partial = String::new();
    let mut idle_rounds = 0u32;
    loop {
        let mut got_done = false;
        if let Ok(mut f) = File::open(&path) {
            if f.seek(SeekFrom::Start(offset)).is_ok() {
                let mut reader = BufReader::new(f);
                let mut buf = String::new();
                loop {
                    buf.clear();
                    match reader.read_line(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            offset += n as u64;
                            if !buf.ends_with('\n') {
                                partial.push_str(&buf);
                                continue;
                            }
                            let line = format!("{partial}{buf}");
                            partial.clear();
                            if let Ok(v) = serde_json::from_str::<Value>(line.trim()) {
                                if v["seq"].as_u64().unwrap_or(0) > since {
                                    on(&v);
                                }
                                if v["type"] == "run.done" {
                                    got_done = true;
                                }
                            }
                        }
                        Err(_) => break,
                    }
                }
            }
        }
        if got_done || !follow {
            return;
        }
        if !pid_alive(run_dir) {
            idle_rounds += 1;
            // 쓰는 쪽이 끝났는데 done 이 없다 → 끊긴 실행으로 알린다.
            if idle_rounds > 3 {
                on(
                    &json!({"schemaVersion": 1, "type": "run.done", "seq": u64::MAX, "synthetic": true,
                           "data": {"state": "FAILED", "code": "ENGINE-02", "detail": "the engine stopped without finishing the run"}}),
                );
                return;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(150));
    }
}

// ---------- 서명 ----------

fn key_path() -> PathBuf {
    util::gitsw_dir().join("flow").join("key")
}

fn signing_key() -> Option<Vec<u8>> {
    let p = key_path();
    if let Ok(k) = std::fs::read_to_string(&p) {
        let k = k.trim().to_string();
        if k.len() >= 32 {
            return Some(k.into_bytes());
        }
    }
    let k = util::random_hex(32);
    std::fs::create_dir_all(p.parent()?).ok()?;
    let tmp = p.with_extension("tmp");
    std::fs::write(&tmp, &k).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &p).ok()?;
    Some(k.into_bytes())
}

/// 서명에 넣는 필드(순서 고정).
fn signed_payload(run: &Value) -> String {
    let nodes: Vec<String> = run["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|n| {
                    format!(
                        "{}={}",
                        n["id"].as_str().unwrap_or(""),
                        n["state"].as_str().unwrap_or("")
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    format!(
        "v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        run["runId"].as_str().unwrap_or(""),
        run["flow"].as_str().unwrap_or(""),
        run["env"].as_str().unwrap_or(""),
        run["state"].as_str().unwrap_or(""),
        run["git"]["sha"].as_str().unwrap_or(""),
        run["git"]["clean"].as_bool().unwrap_or(false),
        run["planHash"].as_str().unwrap_or(""),
        run["filesHash"].as_str().unwrap_or(""),
        run["finishedAt"].as_str().unwrap_or(""),
        nodes.join(",")
    )
}

pub fn sign(run: &Value) -> Option<String> {
    Some(sign_with(&signing_key()?, run))
}

pub fn sign_with(key: &[u8], run: &Value) -> String {
    util::hex(&util::hmac_sha256(key, signed_payload(run).as_bytes()))
}

/// 기록이 엔진이 쓴 그대로인지. 키가 없거나 다르면 믿지 않는다.
pub fn verify(run: &Value) -> bool {
    let Ok(k) = std::fs::read_to_string(key_path()) else {
        return false;
    };
    verify_with(k.trim().as_bytes(), run)
}

pub fn verify_with(key: &[u8], run: &Value) -> bool {
    let Some(sig) = run["signature"].as_str() else {
        return false;
    };
    let expect = sign_with(key, run);
    // 길이 차이로 새지 않게 끝까지 비교한다.
    expect.len() == sig.len()
        && expect
            .bytes()
            .zip(sig.bytes())
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0
}

/// 잠금: 같은 (워크트리, 흐름, 환경)에 실행은 하나. PID 가 죽었으면 잠금을 이어받는다.
pub struct Lock {
    path: PathBuf,
}

impl Lock {
    pub fn acquire(path: &Path, run_id: &str) -> Result<Lock, String> {
        if let Some(p) = path.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        for _ in 0..2 {
            match OpenOptions::new().write(true).create_new(true).open(path) {
                Ok(mut f) => {
                    let _ = writeln!(f, "{}\n{}", std::process::id(), run_id);
                    return Ok(Lock {
                        path: path.to_path_buf(),
                    });
                }
                Err(_) => {
                    let text = std::fs::read_to_string(path).unwrap_or_default();
                    let mut it = text.lines();
                    let pid = it.next().and_then(|p| p.trim().parse::<u32>().ok());
                    let holder = it.next().unwrap_or("").to_string();
                    match pid {
                        Some(p) if process_alive(p) => return Err(holder),
                        _ => {
                            let _ = std::fs::remove_file(path);
                        }
                    }
                }
            }
        }
        Err(String::new())
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_are_masked_ordered_and_followable() {
        let dir = std::env::temp_dir().join(format!("gf-ev-{}", util::random_hex(4)));
        std::fs::create_dir_all(&dir).unwrap();
        let m = Arc::new(Masker::new());
        m.add_secret("T", "topsecretvalue");
        let ev = Events::create(&dir.join("events.ndjson"), "r1", false, m.clone()).unwrap();
        ev.emit("run.state", None, json!({"state": "RUNNING"}));
        ev.emit("log", Some("a"), json!({"line": "token topsecretvalue"}));
        ev.emit("run.done", None, json!({"state": "SUCCEEDED"}));
        let mut seen = Vec::new();
        follow(&dir, 0, true, &mut |v| seen.push(v.clone()));
        assert_eq!(seen.len(), 3);
        assert_eq!(seen[1]["data"]["line"], "token ${secrets.T}");
        assert!(seen
            .windows(2)
            .all(|w| w[0]["seq"].as_u64() < w[1]["seq"].as_u64()));
        let mut later = Vec::new();
        follow(&dir, 2, false, &mut |v| later.push(v.clone()));
        assert_eq!(later.len(), 1);
        // 다시 열어도 seq 가 이어진다.
        let ev2 = Events::create(&dir.join("events.ndjson"), "r1", false, m).unwrap();
        assert_eq!(ev2.emit("x", None, json!({})), 4);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn signature_detects_tampering() {
        let key = b"0123456789abcdef0123456789abcdef";
        let mut run = json!({"runId": "r", "flow": "f", "env": "local", "state": "SUCCEEDED", "git": {"sha": "abc", "clean": true},
                             "planHash": "p", "filesHash": "h", "finishedAt": "t", "nodes": [{"id": "a", "state": "PASSED"}]});
        run["signature"] = json!(sign_with(key, &run));
        assert!(verify_with(key, &run));
        assert!(!verify_with(b"another-key-another-key-another-k", &run));
        run["nodes"][0]["state"] = json!("FAILED");
        assert!(!verify_with(key, &run));
        run["nodes"][0]["state"] = json!("PASSED");
        run["state"] = json!("FAILED");
        assert!(!verify_with(key, &run));
    }

    #[test]
    fn lock_is_exclusive_and_stale_locks_are_taken_over() {
        let p = std::env::temp_dir().join(format!("gf-lock-{}.lock", util::random_hex(4)));
        let l1 = Lock::acquire(&p, "run-1").unwrap();
        assert_eq!(Lock::acquire(&p, "run-2").err().as_deref(), Some("run-1"));
        drop(l1);
        let _l2 = Lock::acquire(&p, "run-2").unwrap();
        std::fs::write(&p, "999999\nghost\n").unwrap();
        // 죽은 PID 의 잠금은 이어받는다.
        let _l3 = Lock::acquire(&p, "run-3");
        assert!(std::fs::read_to_string(&p).unwrap().contains("run-3"));
    }
}
