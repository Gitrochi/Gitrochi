//! 내장 터미널: 의사 터미널(Windows ConPTY, macOS pty)에서 셸을 띄우고 입출력을 화면과 주고받는다.
//!
//! Terminals run in the terminal host (crates/gitrochi-terminal), so they outlive the app and a relaunched app
//! reattaches to them. When the host cannot be started the app runs them itself, as before, and they end with it.

use gitrochi_terminal::{Client, Endpoint, Event, SessionInfo, SpawnSpec};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager};

struct PtyHandle {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
}

/// Where a host session's output goes, and the end of a character cut between two chunks
struct Route {
    channel: Channel<PtyEvent>,
    carry: Vec<u8>,
}

type Routes = Arc<Mutex<HashMap<String, Route>>>;

/// The connection to the terminal host
struct HostLink {
    client: Arc<Client>,
    routes: Routes,
    alive: Arc<AtomicBool>,
}

#[derive(Default)]
struct Inner {
    /// Terminals the app runs itself (no host)
    local: Mutex<HashMap<String, PtyHandle>>,
    host: Mutex<Option<Arc<HostLink>>>,
    /// The host could not be started this run; don't try again for every new tab
    host_failed: AtomicBool,
}

#[derive(Default, Clone)]
pub struct Ptys(Arc<Inner>);

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum PtyEvent {
    Data { data: String },
    Exit { code: Option<i32> },
}

/// A host session as the screen sees it, to restore its tab
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PtySession {
    id: String,
    pid: Option<u32>,
    running: bool,
    exit_code: Option<i32>,
    meta: serde_json::Value,
}

impl From<SessionInfo> for PtySession {
    fn from(s: SessionInfo) -> Self {
        Self { id: s.id, pid: s.pid, running: s.running, exit_code: s.exit_code, meta: s.meta }
    }
}

/// 바이트 덩어리를 UTF-8 로 바꾸되, 끝에 잘린 글자(한글 등)는 다음 덩어리로 넘긴다
fn decode(carry: &mut Vec<u8>, chunk: &[u8]) -> String {
    carry.extend_from_slice(chunk);
    let mut out = String::new();
    loop {
        match std::str::from_utf8(carry) {
            Ok(s) => {
                out.push_str(s);
                carry.clear();
                break;
            }
            Err(e) => {
                let valid = e.valid_up_to();
                out.push_str(std::str::from_utf8(&carry[..valid]).unwrap_or(""));
                match e.error_len() {
                    // 잘못된 바이트는 대체 문자로 바꾸고 계속
                    Some(n) => {
                        out.push('\u{FFFD}');
                        carry.drain(..valid + n);
                    }
                    // 덩어리 끝에서 글자가 잘림 → 남겨 둔다
                    None => {
                        carry.drain(..valid);
                        break;
                    }
                }
            }
        }
    }
    out
}

/// In the app's data folder, so self-tests and the development build keep a host of their own
fn state_dir() -> PathBuf {
    crate::helper::data_dir().join("terminal-host")
}

/// GITROCHI_TERMINAL_HOST names another host executable, or turns the host off with "off"
fn host_executable(app: &AppHandle) -> Option<PathBuf> {
    match std::env::var_os("GITROCHI_TERMINAL_HOST") {
        Some(v) if v == "off" => None,
        Some(path) => Some(PathBuf::from(path)).filter(|p| p.is_file()),
        None => Some(app.path().resource_dir().ok()?.join("gitrochi-terminal-host.exe")).filter(|p| p.is_file()),
    }
}

/// Windows keeps a running program's file locked, and the host outlives the app: run a copy per app version, so an
/// update can replace the installed one
fn runnable_copy(bundled: &Path, state_dir: &Path, version: &str) -> std::io::Result<PathBuf> {
    if !cfg!(windows) {
        return Ok(bundled.to_path_buf());
    }
    let folder = state_dir.join("bin").join(version);
    let copy = folder.join("gitrochi-terminal-host.exe");
    let size = |p: &Path| std::fs::metadata(p).ok().map(|m| m.len());
    if size(&copy).is_none() || size(&copy) != size(bundled) {
        std::fs::create_dir_all(&folder)?;
        let temp = folder.join(format!("gitrochi-terminal-host.{}.tmp", std::process::id()));
        std::fs::copy(bundled, &temp)?;
        if std::fs::rename(&temp, &copy).is_err() {
            // a host of this version runs from it already
            let _ = std::fs::remove_file(&temp);
        }
    }
    Ok(copy)
}

/// Starts the host apart from the app: no console, its own process group, out of the app's job
fn launch_host(exe: &Path, state_dir: &Path) -> std::io::Result<()> {
    let mut cmd = Command::new(exe);
    cmd.arg("--state-dir").arg(state_dir).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB);
        if cmd.spawn().is_ok() {
            return Ok(());
        }
        // a job that forbids breaking away: the host then ends with that job
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    cmd.spawn().map(|_| ())
}

fn connect(state_dir: &Path) -> std::io::Result<HostLink> {
    let routes: Routes = Arc::default();
    let alive = Arc::new(AtomicBool::new(true));
    let cell: Arc<OnceLock<Arc<Client>>> = Arc::default();
    let client = {
        let routes = routes.clone();
        let alive = alive.clone();
        let cell = cell.clone();
        Client::connect(state_dir, move |event| match event {
            Event::Output { id, bytes } => {
                if let Some(route) = routes.lock().unwrap().get_mut(&id) {
                    let data = decode(&mut route.carry, &bytes);
                    if !data.is_empty() {
                        let _ = route.channel.send(PtyEvent::Data { data });
                    }
                }
            }
            Event::Exited { id, exit_code } => {
                if let Some(route) = routes.lock().unwrap().remove(&id) {
                    let _ = route.channel.send(PtyEvent::Exit { code: exit_code });
                }
                // the tab has heard of it, so the host need not keep the ended session (asked off this reader thread,
                // which is the one that brings the reply)
                if let Some(client) = cell.get().cloned() {
                    std::thread::spawn(move || {
                        let _ = client.forget(&id);
                    });
                }
            }
            Event::Closed => {
                alive.store(false, Ordering::SeqCst);
                for (_, route) in routes.lock().unwrap().drain() {
                    let _ = route.channel.send(PtyEvent::Exit { code: None });
                }
            }
        })?
    };
    let client = Arc::new(client);
    let _ = cell.set(client.clone());
    Ok(HostLink { client, routes, alive })
}

impl Ptys {
    fn current(&self) -> Option<Arc<HostLink>> {
        self.0.host.lock().unwrap().clone().filter(|l| l.alive.load(Ordering::SeqCst))
    }

    fn keep(&self, link: HostLink) -> Arc<HostLink> {
        let mut slot = self.0.host.lock().unwrap();
        match slot.as_ref().filter(|l| l.alive.load(Ordering::SeqCst)) {
            Some(other) => other.clone(),
            None => {
                let link = Arc::new(link);
                *slot = Some(link.clone());
                link
            }
        }
    }

    /// The host that already runs, without starting one
    fn running_host(&self) -> Option<Arc<HostLink>> {
        self.current().or_else(|| Some(self.keep(connect(&state_dir()).ok()?)))
    }

    /// The host, started when none answers; `None` when it can't be (then the app runs terminals itself)
    fn host(&self, app: &AppHandle) -> Option<Arc<HostLink>> {
        if let Some(link) = self.running_host() {
            return Some(link);
        }
        if self.0.host_failed.load(Ordering::SeqCst) {
            return None;
        }
        let started = (|| {
            let state_dir = state_dir();
            let exe = runnable_copy(&host_executable(app)?, &state_dir, &app.package_info().version.to_string()).ok()?;
            launch_host(&exe, &state_dir).ok()?;
            let start = Instant::now();
            while start.elapsed() < Duration::from_secs(5) {
                std::thread::sleep(Duration::from_millis(50));
                if let Ok(link) = connect(&state_dir) {
                    return Some(self.keep(link));
                }
            }
            None
        })();
        if started.is_none() {
            self.0.host_failed.store(true, Ordering::SeqCst);
        }
        started
    }

    /// The host link that carries this session, if it does
    fn hosted(&self, id: &str) -> Option<Arc<HostLink>> {
        self.current().filter(|l| l.routes.lock().unwrap().contains_key(id))
    }
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn pty_spawn(
    app: AppHandle,
    state: tauri::State<'_, Ptys>,
    id: String,
    program: String,
    args: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
    cols: u16,
    rows: u16,
    meta: Option<serde_json::Value>,
    on_event: Channel<PtyEvent>,
) -> Result<Option<u32>, String> {
    let ptys = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let exe = crate::process::find_program(&program).map(|p| p.to_string_lossy().into_owned()).unwrap_or(program);
        let cwd = crate::process::native(&cwd);
        let Some(link) = ptys.host(&app) else {
            return spawn_local(&ptys, id, exe, args, cwd, env, cols, rows, on_event);
        };
        // the app's environment now, not the host's from when it started (a newly installed tool's PATH)
        let mut full: std::collections::BTreeMap<String, String> = std::env::vars().collect();
        full.extend(env);
        let spec = SpawnSpec {
            id: id.clone(),
            program: exe,
            args,
            cwd,
            env: full,
            cols,
            rows,
            meta: meta.unwrap_or_default(),
        };
        link.routes.lock().unwrap().insert(id.clone(), Route { channel: on_event, carry: Vec::new() });
        let started = link.client.spawn(spec).and_then(|pid| link.client.attach(&id).map(|_| pid));
        started.map_err(|e| {
            link.routes.lock().unwrap().remove(&id);
            e.to_string()
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Takes up a host session after a relaunch: its output so far, then what follows, or its end when it has ended
#[tauri::command]
pub async fn pty_attach(
    state: tauri::State<'_, Ptys>,
    id: String,
    cols: u16,
    rows: u16,
    on_event: Channel<PtyEvent>,
) -> Result<PtySession, String> {
    let ptys = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let link = ptys.running_host().ok_or("The terminal host is not running")?;
        link.routes.lock().unwrap().insert(id.clone(), Route { channel: on_event, carry: Vec::new() });
        let attached = link.client.attach(&id).map_err(|e| {
            link.routes.lock().unwrap().remove(&id);
            e.to_string()
        })?;
        if attached.running && (attached.cols, attached.rows) != (cols, rows) {
            // a full-screen program redraws for the tab's size
            let _ = link.client.resize(&id, cols, rows);
        }
        Ok(attached.into())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// The host's sessions, to restore their tabs; empty when no host runs (none is started for this)
#[tauri::command]
pub async fn pty_sessions(state: tauri::State<'_, Ptys>) -> Result<Vec<PtySession>, String> {
    let ptys = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        if ptys.current().is_none() && Endpoint::read(&state_dir()).is_err() {
            return Ok(Vec::new());
        }
        let Some(link) = ptys.running_host() else { return Ok(Vec::new()) };
        link.client.list().map(|s| s.into_iter().map(PtySession::from).collect()).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[allow(clippy::too_many_arguments)]
fn spawn_local(
    ptys: &Ptys,
    id: String,
    exe: String,
    args: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
    cols: u16,
    rows: u16,
    on_event: Channel<PtyEvent>,
) -> Result<Option<u32>, String> {
    let pair = native_pty_system()
        .openpty(PtySize { rows: rows.max(2), cols: cols.max(10), pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;
    let mut cmd = CommandBuilder::new(exe);
    cmd.args(&args);
    cmd.cwd(cwd);
    for (k, v) in &env {
        cmd.env(k, v);
    }
    let mut child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let pid = child.process_id();
    let killer = child.clone_killer();
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    ptys.0.local.lock().unwrap().insert(id.clone(), PtyHandle { master: pair.master, writer, killer });

    let exit_code: Arc<Mutex<Option<Option<i32>>>> = Arc::new(Mutex::new(None));

    // 셸이 끝나길 기다렸다가 의사 터미널을 닫는다(ConPTY 는 닫아야 출력 쪽이 끝난다)
    {
        let exit_code = exit_code.clone();
        let ptys = ptys.clone();
        std::thread::spawn(move || {
            let code = child.wait().ok().map(|s| s.exit_code() as i32);
            *exit_code.lock().unwrap() = Some(code);
            std::thread::sleep(Duration::from_millis(150));
            ptys.0.local.lock().unwrap().remove(&id);
        });
    }

    std::thread::spawn(move || {
        let mut buf = [0u8; 16 * 1024];
        let mut carry = Vec::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let text = decode(&mut carry, &buf[..n]);
                    if !text.is_empty() && on_event.send(PtyEvent::Data { data: text }).is_err() {
                        break;
                    }
                }
            }
        }
        // 종료 코드가 정해질 때까지 잠깐 기다린다
        let mut code = None;
        for _ in 0..50 {
            if let Some(c) = *exit_code.lock().unwrap() {
                code = c;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = on_event.send(PtyEvent::Exit { code });
    });

    Ok(pid)
}

#[tauri::command]
pub fn pty_write(state: tauri::State<'_, Ptys>, id: String, data: String) -> Result<(), String> {
    if let Some(link) = state.hosted(&id) {
        return link.client.input(&id, data.as_bytes()).map_err(|e| e.to_string());
    }
    let mut map = state.0.local.lock().unwrap();
    let h = map.get_mut(&id).ok_or("The terminal is already closed")?;
    h.writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    h.writer.flush().map_err(|e| e.to_string())
}

// resize and kill wait for the host's answer, so they run off the main thread
#[tauri::command]
pub async fn pty_resize(state: tauri::State<'_, Ptys>, id: String, cols: u16, rows: u16) -> Result<(), String> {
    if let Some(link) = state.hosted(&id) {
        return tauri::async_runtime::spawn_blocking(move || link.client.resize(&id, cols, rows).map_err(|e| e.to_string()))
            .await
            .map_err(|e| e.to_string())?;
    }
    let map = state.0.local.lock().unwrap();
    if let Some(h) = map.get(&id) {
        h.master
            .resize(PtySize { rows: rows.max(2), cols: cols.max(10), pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn pty_kill(state: tauri::State<'_, Ptys>, id: String) -> Result<(), String> {
    if let Some(link) = state.hosted(&id) {
        return tauri::async_runtime::spawn_blocking(move || link.client.kill(&id).map_err(|e| e.to_string()))
            .await
            .map_err(|e| e.to_string())?;
    }
    let mut map = state.0.local.lock().unwrap();
    if let Some(h) = map.get_mut(&id) {
        let _ = h.killer.kill();
    }
    Ok(())
}
