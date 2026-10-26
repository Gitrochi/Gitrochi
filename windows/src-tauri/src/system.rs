//! 파일·자격 증명·대화상자·탐색기 등 운영체제 기능

use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

const SERVICE: &str = "Gitrochi";
/// Credentials saved before the rename (Branchwork, up to 0.3.5) move to SERVICE when first read
const LEGACY_SERVICE: &str = "Branchwork";
const CREDENTIAL_READ_FAILED: &str = "credential_read_failed";

// MARK: 자격 증명(Windows 자격 증명 관리자 / macOS 키체인)

#[tauri::command]
pub async fn secret_get(name: String) -> Result<Option<String>, String> {
    let entry =
        keyring::Entry::new(SERVICE, &name).map_err(|_| CREDENTIAL_READ_FAILED.to_owned())?;
    if let Some(value) = credential_value(entry.get_password())? {
        return Ok(Some(value));
    }
    let old = keyring::Entry::new(LEGACY_SERVICE, &name)
        .map_err(|_| CREDENTIAL_READ_FAILED.to_owned())?;
    let Some(value) = credential_value(old.get_password())? else {
        return Ok(None);
    };
    if entry.set_password(&value).is_ok() {
        let _ = old.delete_credential();
    }
    Ok(Some(value))
}

fn credential_value(result: keyring::Result<String>) -> Result<Option<String>, String> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err(CREDENTIAL_READ_FAILED.to_owned()),
    }
}

#[cfg(test)]
mod credential_tests {
    use super::{credential_value, CREDENTIAL_READ_FAILED};

    #[test]
    fn only_missing_entries_are_reported_as_absent() {
        assert_eq!(
            credential_value(Ok("fixture-token".into())),
            Ok(Some("fixture-token".into()))
        );
        assert_eq!(credential_value(Err(keyring::Error::NoEntry)), Ok(None));
        for error in [
            keyring::Error::NoStorageAccess(Box::new(std::io::Error::other(
                "private credential detail",
            ))),
            keyring::Error::PlatformFailure(Box::new(std::io::Error::other(
                "private platform detail",
            ))),
            keyring::Error::BadEncoding(b"private credential bytes".to_vec()),
        ] {
            assert_eq!(
                credential_value(Err(error)),
                Err(CREDENTIAL_READ_FAILED.to_owned())
            );
        }
    }
}

#[tauri::command]
pub async fn secret_set(name: String, value: Option<String>) -> Result<(), String> {
    if let Ok(old) = keyring::Entry::new(LEGACY_SERVICE, &name) {
        let _ = old.delete_credential();
    }
    let entry = keyring::Entry::new(SERVICE, &name).map_err(|e| e.to_string())?;
    match value.filter(|v| !v.is_empty()) {
        Some(v) => entry.set_password(&v).map_err(|e| e.to_string()),
        None => {
            match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(error) => Err(error.to_string()),
            }
        }
    }
}

// MARK: 파일

#[tauri::command]
pub async fn fs_exists(path: String) -> bool {
    Path::new(&path).exists()
}

#[tauri::command]
pub async fn fs_read_text(path: String) -> Option<String> {
    std::fs::read(&path).ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}

#[derive(Serialize)]
pub struct FileHead {
    text: String,
    binary: bool,
    truncated: bool,
    size: u64,
}

/// 파일 전체를 base64 로(이미지 diff 용, 너무 크면 None)
#[tauri::command]
pub async fn fs_read_base64(path: String, max: u64) -> Option<String> {
    let meta = std::fs::metadata(&path).ok()?;
    if meta.len() > max {
        return None;
    }
    std::fs::read(&path).ok().map(|b| crate::net::base64(&b))
}

/// 파일 앞부분(새 파일 diff 용). NUL 이 있으면 바이너리로 본다.
#[tauri::command]
pub async fn fs_read_head(path: String, max: usize) -> Result<FileHead, String> {
    use std::io::Read;
    let f = std::fs::File::open(&path).map_err(|e| e.to_string())?;
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    let mut buf = Vec::new();
    f.take(max as u64).read_to_end(&mut buf).map_err(|e| e.to_string())?;
    let binary = buf.iter().take(8000).any(|&b| b == 0);
    Ok(FileHead {
        text: if binary { String::new() } else { String::from_utf8_lossy(&buf).into_owned() },
        binary,
        truncated: (buf.len() as u64) < size,
        size,
    })
}

/// 임시 파일에 쓰고 바꿔치기(쓰다 끊겨도 원래 파일이 깨지지 않게)
#[tauri::command]
pub async fn fs_write_text(path: String, content: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = p.with_extension("tmp-write");
    std::fs::write(&tmp, content).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &p).map_err(|e| e.to_string())
}

/// Saves what the webview got from a paste or drop (an image, a dropped file) under the temp folder and returns the path.
/// The body is raw bytes; the file name comes hex-encoded in a header, since headers are ASCII only.
#[tauri::command]
pub fn fs_write_temp(request: tauri::ipc::Request<'_>) -> Result<String, String> {
    let hex = request.headers().get("x-name-hex").and_then(|v| v.to_str().ok()).ok_or("missing x-name-hex")?;
    let raw = (0..hex.len())
        .step_by(2)
        .map(|i| hex.get(i..i + 2).and_then(|h| u8::from_str_radix(h, 16).ok()))
        .collect::<Option<Vec<u8>>>()
        .ok_or("bad x-name-hex")?;
    let name: String = String::from_utf8_lossy(&raw).chars().filter(|c| !matches!(c, '/' | '\\' | ':')).collect();
    let name = if name.trim().is_empty() { "pasted".to_string() } else { name };
    let body = match request.body() {
        tauri::ipc::InvokeBody::Raw(b) => b,
        _ => return Err("expected raw bytes".to_string()),
    };
    let dir = std::env::temp_dir().join("Gitrochi");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let p = dir.join(name);
    std::fs::write(&p, body).map_err(|e| e.to_string())?;
    Ok(p.to_string_lossy().into_owned())
}

#[tauri::command]
pub async fn fs_list(path: String) -> Vec<String> {
    std::fs::read_dir(&path)
        .map(|it| it.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default()
}

#[tauri::command]
pub async fn fs_remove(path: String) {
    let p = Path::new(&path);
    if p.is_dir() {
        let _ = std::fs::remove_dir_all(p);
    } else {
        let _ = std::fs::remove_file(p);
    }
}

#[tauri::command]
pub async fn fs_mkdirs(path: String) -> Result<(), String> {
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())
}

// MARK: 환경

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvInfo {
    os: &'static str,
    home: String,
    data_dir: String,
    exe: String,
    temp: String,
    shell: String,
    version: String,
    /// 자동 점검(CI): 열어 볼 테스트 저장소 경로
    selftest: Option<String>,
    /// 자동 점검이 끝난 뒤 열어 둘 설정 탭(화면 확인용)
    selftest_open: Option<String>,
    /// %APPDATA% / %LOCALAPPDATA% (맥은 Application Support) — 프로그램 설치 위치를 찾을 때
    app_data: String,
    local_app_data: String,
    /// 앱과 함께 설치되는 파일(gitch 등)이 있는 폴더 — Windows 는 설치 폴더(Gitrochi.exe 옆)
    resource_dir: String,
}

#[tauri::command]
pub fn env_info(app: AppHandle) -> EnvInfo {
    let shell = if cfg!(windows) {
        crate::process::find_program("pwsh")
            .or_else(|| crate::process::find_program("powershell"))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| "powershell.exe".into())
    } else {
        std::env::var("SHELL").ok().filter(|s| Path::new(s).exists()).unwrap_or_else(|| "/bin/zsh".into())
    };
    EnvInfo {
        os: std::env::consts::OS,
        home: dirs::home_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        data_dir: crate::helper::data_dir().to_string_lossy().into_owned(),
        exe: std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        temp: std::env::temp_dir().to_string_lossy().into_owned(),
        shell,
        version: app.package_info().version.to_string(),
        selftest: std::env::var("GITROCHI_SELFTEST").ok().filter(|s| !s.is_empty()),
        selftest_open: std::env::var("GITROCHI_SELFTEST_OPEN").ok().filter(|s| !s.is_empty()),
        app_data: dirs::data_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        local_app_data: dirs::data_local_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        resource_dir: app.path().resource_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
    }
}

// MARK: 대화상자·탐색기·브라우저

#[tauri::command]
pub async fn pick_folder(app: AppHandle, title: String, start: Option<String>) -> Option<String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut d = app.dialog().file().set_title(&title);
        if let Some(s) = start.filter(|s| Path::new(s).is_dir()) {
            d = d.set_directory(s);
        }
        d.blocking_pick_folder().and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().into_owned())
    })
    .await
    .ok()
    .flatten()
}

/// 실행 파일 하나 고르기(PC 마다 설치 위치가 달라 자동으로 못 찾을 때)
#[tauri::command]
pub async fn pick_file(app: AppHandle, title: String, start: Option<String>) -> Option<String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut d = app.dialog().file().set_title(&title);
        if cfg!(windows) {
            d = d.add_filter("Programs", &["exe", "cmd", "bat"]).add_filter("All files", &["*"]);
        }
        if let Some(s) = start.map(|s| crate::process::native(&s)).filter(|s| Path::new(s).is_dir()) {
            d = d.set_directory(s);
        }
        d.blocking_pick_file().and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().into_owned())
    })
    .await
    .ok()
    .flatten()
}

#[tauri::command]
pub fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("Only web addresses can be opened".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

/// 탐색기(Finder)에서 파일·폴더를 선택해 보여 준다
#[tauri::command]
pub fn reveal_path(path: String) -> Result<(), String> {
    tauri_plugin_opener::reveal_item_in_dir(PathBuf::from(crate::process::native(&path))).map_err(|e| e.to_string())
}

/// 앱이 만든 html 페이지(구조 그래프)를 기본 앱(보통 브라우저)으로 연다. html 파일만 받는다.
#[tauri::command]
pub fn open_html(app: AppHandle, path: String) -> Result<(), String> {
    let p = PathBuf::from(crate::process::native(&path));
    let html = p.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("html"));
    if !html || !p.is_file() {
        return Err("Only an existing .html file can be opened".into());
    }
    app.opener().open_path(p.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}

/// 의존 규칙 파일(.gitch/graph.rules)을 메모장(macOS 는 기본 글 편집기)으로 연다 — .rules 에 묶인 앱이 없어도 열리게. 그 파일만 받는다.
#[tauri::command]
pub fn open_rules(path: String) -> Result<(), String> {
    let p = PathBuf::from(crate::process::native(&path));
    let rules = p.file_name().is_some_and(|n| n == "graph.rules") && p.parent().and_then(Path::file_name).is_some_and(|n| n == ".gitch");
    if !rules || !p.is_file() {
        return Err("Only an existing .gitch/graph.rules file can be opened".into());
    }
    let mut cmd = Command::new(if cfg!(windows) { "notepad.exe" } else { "open" });
    if !cfg!(windows) {
        cmd.arg("-t");
    }
    cmd.arg(&p).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// 바깥 터미널 앱으로 폴더 열기(Windows Terminal → PowerShell, macOS Terminal)
#[tauri::command]
pub fn open_terminal(path: String) -> Result<(), String> {
    let path = crate::process::native(&path);
    if cfg!(windows) {
        if let Some(wt) = crate::process::find_program("wt") {
            Command::new(wt).args(["-d", &path]).spawn().map_err(|e| e.to_string())?;
            return Ok(());
        }
        let shell = crate::process::find_program("pwsh")
            .or_else(|| crate::process::find_program("powershell"))
            .ok_or("Couldn't find PowerShell")?;
        let mut cmd = Command::new(shell);
        cmd.arg("-NoExit").current_dir(&path);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
            cmd.creation_flags(CREATE_NEW_CONSOLE);
        }
        cmd.spawn().map_err(|e| e.to_string())?;
    } else {
        Command::new("open").args(["-a", "Terminal", &path]).spawn().map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// 새 콘솔 창에서 프로그램 하나를 띄운다(gitch add · setup · doctor 처럼 묻거나 길게 보여 주는 것). 끝나도 창은 프로그램이 닫는다.
#[tauri::command]
pub fn open_console(program: String, args: Vec<String>, cwd: String) -> Result<(), String> {
    if !cfg!(windows) {
        return Err("Opening a console window is only supported on Windows".into());
    }
    let cwd = crate::process::native(&cwd);
    let mut cmd = Command::new(crate::process::native(&program));
    cmd.args(&args);
    if Path::new(&cwd).is_dir() {
        cmd.current_dir(&cwd);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
        cmd.creation_flags(CREATE_NEW_CONSOLE);
    }
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// 화면이 준비되면 창을 보여 준다(처음부터 띄우면 흰 화면이 번쩍인다)
#[tauri::command]
pub fn app_ready(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        // 자동 점검 중에는 다른 작업을 방해하지 않게 앞으로 가져오지 않는다
        if std::env::var("GITROCHI_SELFTEST").is_err() {
            let _ = w.set_focus();
        } else if std::env::var("GITROCHI_SELFTEST_ON_TOP").is_ok() {
            // 개발 중 화면 캡처용: 포커스는 가져오지 않고 맨 위에만 띄운다
            let _ = w.set_always_on_top(true);
            // 맥은 비활성 앱의 창을 화면에 올리지 않으므로 강제로 올린다
            #[cfg(target_os = "macos")]
            if let Ok(ptr) = w.ns_window() {
                unsafe {
                    let obj = &*(ptr as *mut objc2::runtime::AnyObject);
                    let _: () = objc2::msg_send![obj, orderFrontRegardless];
                }
            }
        }
    }
}
