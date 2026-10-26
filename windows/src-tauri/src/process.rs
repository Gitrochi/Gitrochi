//! 외부 프로그램(git, gh, claude) 실행

use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

/// 여러 탭의 새로 고침이 겹쳐도 OS 프로세스·파이프를 한꺼번에 수십 개씩 만들지 않는다.
async fn process_permit() -> Result<OwnedSemaphorePermit, String> {
    static LIMIT: OnceLock<Arc<Semaphore>> = OnceLock::new();
    LIMIT
        .get_or_init(|| Arc::new(Semaphore::new(16)))
        .clone()
        .acquire_owned()
        .await
        .map_err(|e| e.to_string())
}
use wait_timeout::ChildExt;

#[derive(Serialize)]
pub struct ProcOutput {
    status: i32,
    stdout: String,
    stderr: String,
}

/// PATH 에서 프로그램을 찾는다(Windows 는 PATHEXT 의 .exe/.cmd 등도 붙여 본다)
pub fn find_program(program: &str) -> Option<PathBuf> {
    if program.contains('/') || program.contains('\\') {
        let p = PathBuf::from(program);
        return p.is_file().then_some(p);
    }
    let exts: Vec<String> = if cfg!(windows) {
        let pathext = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
        let mut v = vec![String::new()];
        v.extend(
            pathext
                .split(';')
                .filter(|e| !e.is_empty())
                .map(|e| e.to_lowercase()),
        );
        v
    } else {
        vec![String::new()]
    };
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for ext in &exts {
            let candidate = dir.join(format!("{program}{ext}"));
            if candidate.is_file() && (cfg!(windows) && !ext.is_empty() || !cfg!(windows)) {
                return Some(candidate);
            }
        }
    }
    None
}

/// 운영체제 기본 경로 형식으로(Windows 는 / 를 \ 로). git 은 C:/a/b 로 주지만 일부 Windows API 는 \ 만 받는다.
pub fn native(p: &str) -> String {
    if cfg!(windows) {
        p.replace('/', "\\")
    } else {
        p.to_string()
    }
}

// 명령들은 async 로 둔다: Tauri 는 async 가 아닌 명령을 화면(메인) 스레드에서 돌려, 오래 걸리면 창이 '응답 없음'이 된다
#[tauri::command]
pub async fn which(program: String) -> Option<String> {
    tauri::async_runtime::spawn_blocking(move || {
        find_program(&program).map(|p| p.to_string_lossy().into_owned())
    })
    .await
    .ok()
    .flatten()
}

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

fn run_blocking(
    program: String,
    args: Vec<String>,
    cwd: Option<String>,
    env: HashMap<String, String>,
    stdin: Option<String>,
    timeout: Duration,
    binary: bool,
) -> Result<ProcOutput, String> {
    let exe = find_program(&program).unwrap_or_else(|| PathBuf::from(&program));
    let mut cmd = Command::new(&exe);
    cmd.args(&args)
        .envs(&env)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = cwd.as_deref().filter(|d| !d.is_empty()) {
        let dir = native(dir);
        if !Path::new(&dir).is_dir() {
            return Err(format!("Folder not found: {dir}"));
        }
        cmd.current_dir(dir);
    }
    hide_window(&mut cmd);
    let name = Path::new(&program)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or(program.clone());
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Couldn't run {name}: {e}"))?;

    if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
        std::thread::spawn(move || {
            let _ = pipe.write_all(input.as_bytes());
        });
    }
    // 출력이 많을 때 파이프가 가득 차 멈추지 않도록 stdout·stderr 를 따로 비운다
    let mut out = child.stdout.take().ok_or("stdout")?;
    let mut err = child.stderr.take().ok_or("stderr")?;
    let out_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = out.read_to_end(&mut buf);
        buf
    });
    let err_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = err.read_to_end(&mut buf);
        buf
    });

    let status = match child.wait_timeout(timeout).map_err(|e| e.to_string())? {
        Some(s) => s.code().unwrap_or(-1),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            -2
        }
    };
    let stdout = out_thread.join().unwrap_or_default();
    let stderr = err_thread.join().unwrap_or_default();
    let mut stderr = String::from_utf8_lossy(&stderr).into_owned();
    if status == -2 {
        stderr.push_str(&format!(
            "\n{name} didn't finish within {}s and was stopped.",
            timeout.as_secs()
        ));
    }
    // binary: 이미지처럼 글이 아닌 출력은 그대로(base64) 넘긴다
    let stdout = if binary {
        crate::net::base64(&stdout)
    } else {
        String::from_utf8_lossy(&stdout).into_owned()
    };
    Ok(ProcOutput {
        status,
        stdout,
        stderr,
    })
}

/// 프로그램을 실행하고 끝날 때까지 기다린다. 종료 코드와 출력을 그대로 돌려준다.
#[tauri::command]
pub async fn run_process(
    program: String,
    args: Vec<String>,
    cwd: Option<String>,
    env: Option<HashMap<String, String>>,
    stdin: Option<String>,
    timeout_ms: Option<u64>,
) -> Result<ProcOutput, String> {
    let timeout = Duration::from_millis(timeout_ms.unwrap_or(120_000));
    let permit = process_permit().await?;
    tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        run_blocking(
            program,
            args,
            cwd,
            env.unwrap_or_default(),
            stdin,
            timeout,
            false,
        )
    })
    .await
    .map_err(|e| e.to_string())?
}

/// run_process 와 같되 stdout 을 바이트 그대로 base64 로(git show 로 이미지 읽기 등)
#[tauri::command]
pub async fn run_process_bytes(
    program: String,
    args: Vec<String>,
    cwd: Option<String>,
    env: Option<HashMap<String, String>>,
) -> Result<ProcOutput, String> {
    let permit = process_permit().await?;
    tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        run_blocking(
            program,
            args,
            cwd,
            env.unwrap_or_default(),
            None,
            Duration::from_secs(60),
            true,
        )
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::process_permit;
    use std::future::Future;
    use std::task::{Context, Poll, Waker};

    #[test]
    fn queued_processes_wait_without_starting_blocking_threads() {
        tauri::async_runtime::block_on(async {
            let mut held = Vec::new();
            for _ in 0..16 {
                held.push(process_permit().await.unwrap());
            }
            let mut waiting = Box::pin(process_permit());
            let mut cx = Context::from_waker(Waker::noop());
            assert!(matches!(waiting.as_mut().poll(&mut cx), Poll::Pending));
            held.pop();
            assert!(waiting.await.is_ok());
        });
    }
}
