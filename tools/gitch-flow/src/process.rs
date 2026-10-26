//! Child processes. To end grandchildren together with them,
//! they go into a process group on Unix and a Job Object on Windows.

use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// No console window on Windows (code style: CREATE_NO_WINDOW).
pub fn hide_window(cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    let _ = cmd;
}

#[derive(Clone, Default)]
pub struct Cancel(Arc<AtomicBool>);

impl Cancel {
    pub fn new() -> Cancel {
        Cancel(Arc::new(AtomicBool::new(false)))
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stream {
    Out,
    Err,
}

pub struct ProcSpec {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub clear_env: bool,
    pub timeout_ms: Option<u64>,
    /// How long to wait after a cancel or timeout before killing the processes and calling them stuck.
    pub settle_ms: u64,
}

#[derive(Debug, Clone, Default)]
pub struct Outcome {
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub timed_out: bool,
    pub cancelled: bool,
    pub hung: bool,
    pub duration_ms: u64,
    pub spawn_error: Option<String>,
}

impl Outcome {
    pub fn success(&self) -> bool {
        self.exit_code == Some(0)
            && !self.timed_out
            && !self.cancelled
            && self.spawn_error.is_none()
    }
}

/// A handle that ends the whole process group.
pub struct Group {
    #[cfg(unix)]
    pgid: i32,
    #[cfg(windows)]
    job: isize,
}

impl Group {
    fn attach(child: &Child) -> Group {
        #[cfg(unix)]
        {
            Group {
                pgid: child.id() as i32,
            }
        }
        #[cfg(windows)]
        {
            Group {
                job: win::attach(child),
            }
        }
    }

    /// Asks the processes to stop (SIGTERM on Unix). Windows has no such signal, so they end at once.
    pub fn terminate(&self) {
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.pgid, libc::SIGTERM);
        }
        #[cfg(windows)]
        win::terminate(self.job);
    }

    pub fn kill(&self) {
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.pgid, libc::SIGKILL);
        }
        #[cfg(windows)]
        win::terminate(self.job);
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        #[cfg(windows)]
        win::close(self.job);
    }
}

#[cfg(windows)]
mod win {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    pub fn attach(child: &std::process::Child) -> isize {
        unsafe {
            let job: HANDLE = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return 0;
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            AssignProcessToJobObject(job, child.as_raw_handle() as HANDLE);
            job as isize
        }
    }

    pub fn terminate(job: isize) {
        if job != 0 {
            unsafe {
                TerminateJobObject(job as HANDLE, 1);
            }
        }
    }

    pub fn close(job: isize) {
        if job != 0 {
            unsafe {
                CloseHandle(job as HANDLE);
            }
        }
    }
}

/// Starts the command in a new process group.
pub fn spawn(spec: &ProcSpec, stdout: Stdio, stderr: Stdio) -> std::io::Result<(Child, Group)> {
    let mut cmd = Command::new(&spec.program);
    cmd.args(&spec.args)
        .current_dir(&spec.cwd)
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr);
    if spec.clear_env {
        cmd.env_clear();
    }
    for (k, v) in &spec.env {
        cmd.env(k, v);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    hide_window(&mut cmd);
    let child = cmd.spawn()?;
    let group = Group::attach(&child);
    Ok((child, group))
}

fn pump<R: Read + Send + 'static>(
    r: R,
    stream: Stream,
    tx: mpsc::Sender<(Stream, String)>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(r);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    while buf.last() == Some(&b'\n') || buf.last() == Some(&b'\r') {
                        buf.pop();
                    }
                    if tx
                        .send((stream, String::from_utf8_lossy(&buf).to_string()))
                        .is_err()
                    {
                        break;
                    }
                }
            }
        }
    })
}

/// Runs to the end and calls `on_line` for every line. A timeout or cancel ends the whole group.
pub fn run(spec: &ProcSpec, cancel: &Cancel, on_line: &mut dyn FnMut(Stream, &str)) -> Outcome {
    let started = Instant::now();
    let (mut child, group) = match spawn(spec, Stdio::piped(), Stdio::piped()) {
        Ok(x) => x,
        Err(e) => {
            return Outcome {
                spawn_error: Some(format!("{}: {e}", spec.program)),
                ..Default::default()
            };
        }
    };
    let (tx, rx) = mpsc::channel();
    let mut readers = Vec::new();
    if let Some(o) = child.stdout.take() {
        readers.push(pump(o, Stream::Out, tx.clone()));
    }
    if let Some(e) = child.stderr.take() {
        readers.push(pump(e, Stream::Err, tx.clone()));
    }
    drop(tx);
    let deadline = spec
        .timeout_ms
        .map(|ms| started + Duration::from_millis(ms));
    let mut out = Outcome::default();
    let mut stop_sent: Option<Instant> = None;
    let status = loop {
        while let Ok((s, line)) = rx.try_recv() {
            on_line(s, &line);
        }
        match child.try_wait() {
            Ok(Some(st)) => break Some(st),
            Ok(None) => {}
            Err(_) => break None,
        }
        let now = Instant::now();
        if stop_sent.is_none() {
            if cancel.is_cancelled() {
                out.cancelled = true;
            } else if deadline.map(|d| now >= d).unwrap_or(false) {
                out.timed_out = true;
            }
            if out.cancelled || out.timed_out {
                group.terminate();
                stop_sent = Some(now);
            }
        } else if let Some(t) = stop_sent {
            if now.duration_since(t) >= Duration::from_millis(spec.settle_ms) {
                out.hung = true;
                group.kill();
                let _ = child.kill();
            }
        }
        match rx.recv_timeout(Duration::from_millis(40)) {
            Ok((s, line)) => on_line(s, &line),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                std::thread::sleep(Duration::from_millis(20))
            }
        }
    };
    // A grandchild holding the pipe keeps reading from finishing after the main process exits, so end the whole group.
    group.kill();
    let drain_until = Instant::now() + Duration::from_millis(1500);
    loop {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok((s, line)) => on_line(s, &line),
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if Instant::now() >= drain_until {
                    break;
                }
            }
        }
    }
    for r in readers {
        if r.is_finished() {
            let _ = r.join();
        }
    }
    if let Some(st) = status {
        out.exit_code = st.code();
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            out.signal = st.signal();
        }
    }
    out.duration_ms = started.elapsed().as_millis() as u64;
    out
}

/// The program and arguments that run a script in a shell. On Windows, bash is Git for Windows' bash.
pub fn shell_command(shell: &str, script: &str) -> (String, Vec<String>) {
    match shell {
        "sh" => ("sh".into(), vec!["-c".into(), script.into()]),
        "pwsh" | "powershell" => {
            let prog = if shell == "pwsh" {
                "pwsh"
            } else {
                "powershell"
            };
            (
                prog.into(),
                vec![
                    "-NoProfile".into(),
                    "-NonInteractive".into(),
                    "-Command".into(),
                    format!("$ErrorActionPreference='Stop'; {script}"),
                ],
            )
        }
        "cmd" => (
            "cmd".into(),
            vec!["/D".into(), "/S".into(), "/C".into(), script.into()],
        ),
        _ => (
            bash_path(),
            vec![
                "--noprofile".into(),
                "--norc".into(),
                "-eo".into(),
                "pipefail".into(),
                "-c".into(),
                script.into(),
            ],
        ),
    }
}

/// Where bash is: GITCH_BASH, then (Windows) Git for Windows' bash.exe, then bash on PATH.
pub fn bash_path() -> String {
    if let Ok(b) = std::env::var("GITCH_BASH") {
        if !b.is_empty() {
            return crate::util::msys_to_native(&b);
        }
    }
    #[cfg(windows)]
    {
        let mut cands: Vec<PathBuf> = Vec::new();
        if let Ok(p) = std::env::var("EXEPATH") {
            cands.push(PathBuf::from(&p).join("bash.exe"));
            cands.push(PathBuf::from(&p).join("..").join("bin").join("bash.exe"));
        }
        for base in ["ProgramFiles", "ProgramW6432", "LOCALAPPDATA"] {
            if let Ok(p) = std::env::var(base) {
                cands.push(PathBuf::from(&p).join("Git").join("bin").join("bash.exe"));
                cands.push(
                    PathBuf::from(&p)
                        .join("Programs")
                        .join("Git")
                        .join("bin")
                        .join("bash.exe"),
                );
            }
        }
        for c in cands {
            if c.is_file() {
                return c.to_string_lossy().to_string();
            }
        }
    }
    "bash".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn sh(script: &str, timeout_ms: Option<u64>) -> (Outcome, Vec<String>) {
        let (program, args) = shell_command("sh", script);
        let spec = ProcSpec {
            program,
            args,
            cwd: std::env::temp_dir(),
            env: vec![],
            clear_env: false,
            timeout_ms,
            settle_ms: 500,
        };
        let mut lines = Vec::new();
        let o = run(&spec, &Cancel::new(), &mut |_, l| lines.push(l.to_string()));
        (o, lines)
    }

    #[cfg(unix)]
    #[test]
    fn captures_output_and_exit() {
        let (o, lines) = sh("echo one; echo two 1>&2; exit 3", None);
        assert_eq!(o.exit_code, Some(3));
        assert!(lines.contains(&"one".to_string()) && lines.contains(&"two".to_string()));
        let (ok, _) = sh("true", None);
        assert!(ok.success());
    }

    #[cfg(unix)]
    #[test]
    fn timeout_kills_the_whole_group() {
        let marker = std::env::temp_dir().join(format!("gf-orphan-{}", crate::util::random_hex(4)));
        // A grandchild tries to create a file after 1.5 s; ending the group must prevent it.
        let script = format!("(sleep 1.5; touch {}) & sleep 30", marker.display());
        let (o, _) = sh(&script, Some(300));
        assert!(o.timed_out);
        std::thread::sleep(Duration::from_millis(1800));
        assert!(!marker.exists(), "grandchild survived the timeout");
    }

    #[cfg(unix)]
    #[test]
    fn cancel_stops_the_process() {
        let (program, args) = shell_command("sh", "sleep 30");
        let spec = ProcSpec {
            program,
            args,
            cwd: std::env::temp_dir(),
            env: vec![],
            clear_env: false,
            timeout_ms: None,
            settle_ms: 500,
        };
        let c = Cancel::new();
        let c2 = c.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            c2.cancel();
        });
        let o = run(&spec, &c, &mut |_, _| {});
        assert!(o.cancelled);
        assert!(o.duration_ms < 5000);
    }

    #[test]
    fn missing_program_is_a_spawn_error() {
        let spec = ProcSpec {
            program: "definitely-not-a-real-program-xyz".into(),
            args: vec![],
            cwd: std::env::temp_dir(),
            env: vec![],
            clear_env: false,
            timeout_ms: None,
            settle_ms: 100,
        };
        let o = run(&spec, &Cancel::new(), &mut |_, _| {});
        assert!(o.spawn_error.is_some());
        assert!(!o.success());
    }
}
