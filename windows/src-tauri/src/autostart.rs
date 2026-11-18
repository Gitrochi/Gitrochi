//! Opening Gitrochi at login: the current user's Run key in the registry, written with reg.exe so no registry
//! bindings are needed. (macOS: SMAppService.mainApp in Views/Settings/BackgroundSettings.swift)

#[cfg(windows)]
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
#[cfg(windows)]
const VALUE: &str = "Gitrochi";

#[cfg(windows)]
fn reg(args: &[&str]) -> Result<std::process::Output, String> {
    let mut cmd = std::process::Command::new("reg");
    cmd.args(args);
    crate::process::hide_window(&mut cmd);
    cmd.output().map_err(|e| e.to_string())
}

/// Whether Gitrochi opens at login
#[tauri::command]
pub async fn autostart_get() -> Result<bool, String> {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(|| {
            Ok::<bool, String>(reg(&["query", RUN_KEY, "/v", VALUE])?.status.success())
        })
        .await
        .map_err(|e| e.to_string())?
    }
    #[cfg(not(windows))]
    {
        Ok(false)
    }
}

#[tauri::command]
pub async fn autostart_set(enabled: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(move || {
            let out = if enabled {
                let exe = std::env::current_exe().map_err(|e| e.to_string())?;
                // quoted, so a folder with spaces starts the same program
                reg(&[
                    "add",
                    RUN_KEY,
                    "/v",
                    VALUE,
                    "/t",
                    "REG_SZ",
                    "/d",
                    &format!("\"{}\"", exe.display()),
                    "/f",
                ])?
            } else {
                let out = reg(&["delete", RUN_KEY, "/v", VALUE, "/f"])?;
                // nothing to remove is what was asked for
                if !out.status.success() && !reg(&["query", RUN_KEY, "/v", VALUE])?.status.success()
                {
                    return Ok(());
                }
                out
            };
            if out.status.success() {
                Ok(())
            } else {
                Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }
    #[cfg(not(windows))]
    {
        let _ = enabled;
        Err("Opening at login is set up by the Windows app only".into())
    }
}
