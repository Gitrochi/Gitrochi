//! Agent processes started outside Gitrochi (Claude Code, Codex, Gemini CLI in Windows Terminal, VS Code, …)
//! and the app windows that run them. The scan only reads; deciding which ones belong to a repository, and
//! which ancestor is the app, happens in the frontend (entities/agent/lib/external-agents.ts).
//! (macOS: Services/ExternalAgents.swift)

use serde::Serialize;
use std::collections::HashSet;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

/// One process on the way from an agent up to the system: its name and whether it owns a visible app window
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessLink {
    pid: u32,
    name: String,
    window: bool,
}

/// A process that may be an agent: its executable, the first arguments of a script runtime, its folder and parents
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentProcess {
    pid: u32,
    name: String,
    args: Vec<String>,
    cwd: String,
    /// Seconds since 1970
    started: u64,
    /// Parent first
    ancestors: Vec<ProcessLink>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentScan {
    /// Gitrochi's own process: agents below it are the app's own sessions
    own: u32,
    processes: Vec<AgentProcess>,
}

/// The executable's name without ".exe", lowercased
fn stem(name: &str) -> String {
    let lower = name.to_lowercase();
    lower.strip_suffix(".exe").unwrap_or(&lower).to_string()
}

/// Agent executables, and the script runtimes that agent CLIs installed with npm run under
fn is_candidate(stem: &str) -> bool {
    matches!(stem, "claude" | "codex" | "gemini" | "node" | "bun") || stem.starts_with("codex-")
}

fn is_runtime(stem: &str) -> bool {
    matches!(stem, "node" | "bun")
}

fn scan() -> AgentScan {
    let mut system = System::new();
    // names and parents of every process first; folders and arguments only for the few candidates
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    let candidates: Vec<Pid> = system
        .processes()
        .iter()
        .filter(|(_, p)| is_candidate(&stem(&p.name().to_string_lossy())))
        .map(|(pid, _)| *pid)
        .collect();
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&candidates),
        false,
        ProcessRefreshKind::nothing()
            .with_cwd(UpdateKind::Always)
            .with_cmd(UpdateKind::Always),
    );
    let windows = window_owners();
    let link = |pid: Pid| ProcessLink {
        pid: pid.as_u32(),
        name: system
            .process(pid)
            .map(|p| p.name().to_string_lossy().into_owned())
            .unwrap_or_default(),
        window: windows.contains(&pid.as_u32()),
    };
    let mut processes = Vec::new();
    for pid in candidates {
        let Some(process) = system.process(pid) else {
            continue;
        };
        // a folder that cannot be read (another user, an elevated process) means the process is skipped
        let Some(cwd) = process.cwd().filter(|c| !c.as_os_str().is_empty()) else {
            continue;
        };
        let name = process.name().to_string_lossy().into_owned();
        let args = if is_runtime(&stem(&name)) {
            process
                .cmd()
                .iter()
                .skip(1)
                .take(6)
                .map(|a| a.to_string_lossy().chars().take(300).collect())
                .collect()
        } else {
            Vec::new()
        };
        let mut ancestors = Vec::new();
        let mut seen = HashSet::from([pid]);
        let mut current = process.parent();
        while let Some(parent) = current {
            if ancestors.len() >= 24 || !seen.insert(parent) {
                break;
            }
            ancestors.push(link(parent));
            current = system.process(parent).and_then(|p| p.parent());
        }
        processes.push(AgentProcess {
            pid: pid.as_u32(),
            name,
            args,
            cwd: cwd.to_string_lossy().into_owned(),
            started: process.start_time(),
            ancestors,
        });
    }
    AgentScan {
        own: std::process::id(),
        processes,
    }
}

/// Reads the process table off the UI thread
#[tauri::command]
pub async fn external_agents() -> Result<AgentScan, String> {
    tauri::async_runtime::spawn_blocking(scan)
        .await
        .map_err(|e| e.to_string())
}

/// Brings the app window of a process to the front, restoring it when minimized
#[tauri::command]
pub async fn bring_app_forward(pid: u32) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || bring_forward(pid))
        .await
        .map_err(|e| e.to_string())?
}

/// Processes that own a visible, unowned top-level window with a title (an app's main window)
#[cfg(windows)]
fn window_owners() -> HashSet<u32> {
    app_windows().into_iter().map(|(_, pid)| pid).collect()
}

#[cfg(not(windows))]
fn window_owners() -> HashSet<u32> {
    HashSet::new()
}

#[cfg(windows)]
fn app_windows() -> Vec<(windows::Win32::Foundation::HWND, u32)> {
    use windows::core::BOOL;
    use windows::Win32::Foundation::{HWND, LPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindow, GetWindowTextLengthW, GetWindowThreadProcessId, IsWindowVisible,
        GW_OWNER,
    };

    unsafe extern "system" fn collect(hwnd: HWND, data: LPARAM) -> BOOL {
        let found = unsafe { &mut *(data.0 as *mut Vec<(HWND, u32)>) };
        let owned = unsafe { GetWindow(hwnd, GW_OWNER) }
            .map(|o| !o.is_invalid())
            .unwrap_or(false);
        if unsafe { IsWindowVisible(hwnd) }.as_bool()
            && !owned
            && unsafe { GetWindowTextLengthW(hwnd) } > 0
        {
            let mut pid = 0u32;
            unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
            if pid != 0 {
                found.push((hwnd, pid));
            }
        }
        BOOL(1)
    }

    let mut found: Vec<(HWND, u32)> = Vec::new();
    let _ = unsafe { EnumWindows(Some(collect), LPARAM(&mut found as *mut _ as isize)) };
    found
}

#[cfg(windows)]
fn bring_forward(pid: u32) -> Result<(), String> {
    use windows::Win32::UI::WindowsAndMessaging::{
        IsIconic, SetForegroundWindow, ShowWindow, SW_RESTORE,
    };
    let Some((hwnd, _)) = app_windows().into_iter().find(|(_, owner)| *owner == pid) else {
        return Err("The app's window was not found.".into());
    };
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        if !SetForegroundWindow(hwnd).as_bool() {
            return Err("Windows did not bring the app to the front.".into());
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn bring_forward(_pid: u32) -> Result<(), String> {
    Err("Bringing another app forward is only available on Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_are_agent_executables_and_script_runtimes() {
        assert_eq!(stem("Claude.EXE"), "claude");
        for name in [
            "claude.exe",
            "codex",
            "codex-x86_64-pc-windows-msvc.exe",
            "gemini",
            "node.exe",
            "bun",
        ] {
            assert!(is_candidate(&stem(name)), "{name}");
        }
        for name in [
            "code.exe",
            "WindowsTerminal.exe",
            "cmd.exe",
            "claude-helper.exe",
        ] {
            assert!(!is_candidate(&stem(name)), "{name}");
        }
        assert!(is_runtime("node") && !is_runtime("claude"));
    }

    #[test]
    fn a_scan_lists_this_test_process_tree_without_failing() {
        // the test binary is not an agent; the scan must still run and report this process as its own
        let result = scan();
        assert_eq!(result.own, std::process::id());
        assert!(result.processes.iter().all(|p| !p.cwd.is_empty()));
    }
}
