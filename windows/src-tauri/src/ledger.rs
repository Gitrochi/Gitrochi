//! Ledger (crates/gitrochi-ledger): the sessions agents report and a person's decisions about them, in the same
//! SQLite database the macOS app reaches through the C ABI. macOS: macos/Sources/Services/LedgerBackend.swift.

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;

/// Runs one ledger method off the async runtime (a write may wait for another process's) and answers the result or
/// `{"error"}`. The app is the core's `app` caller, the only one allowed a person's operations (docs/ledger/DESIGN.md
/// §8); `GITROCHI_LEDGER=0` and `GITROCHI_LEDGER_DB` are read by the core itself.
#[tauri::command]
pub async fn ledger_call(method: String, args: Value) -> Value {
    tauri::async_runtime::spawn_blocking(move || gitrochi_ledger::call(&method, &args))
        .await
        .unwrap_or_else(|_| json!({"error": {"code": "DATABASE", "message": "Ledger call failed"}}))
}

/// Asks for a claude-ledger database to import (it keeps `data/ledger.db`); None when the person cancels.
#[tauri::command]
pub async fn ledger_pick_database(app: AppHandle, title: String) -> Option<String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut d = app.dialog().file().set_title(&title);
        if cfg!(windows) {
            d = d.add_filter("SQLite", &["db", "sqlite", "sqlite3"]).add_filter("All files", &["*"]);
        }
        d.blocking_pick_file().and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().into_owned())
    })
    .await
    .ok()
    .flatten()
}

/// Shows a Ledger notification (DESIGN.md §10.11); `target` says which item a click opens. The page decides what is
/// new and how it reads; Windows shows it as a toast.
#[tauri::command]
pub fn ledger_notify(app: AppHandle, title: String, body: String, target: Value) -> Result<(), String> {
    app.notification()
        .builder()
        .title(title)
        .body(body)
        .extra("ledger", target)
        .show()
        .map_err(|e| e.to_string())
}

/// A click on a Ledger notification brings the window forward, and the page opens the item (`ledger-notification`).
/// Windows reports a click while the toast is on screen, not from the Action Center.
pub fn open_on_notification_click(app: &AppHandle) {
    let handle = app.clone();
    let _ = app.notification().on_action(move |action| {
        if action.action_id() != "tap" {
            return;
        }
        let target = action
            .notification()
            .and_then(|n| n.extra().get("ledger").cloned())
            .unwrap_or(Value::Null);
        if let Some(w) = handle.get_webview_window("main") {
            let _ = w.unminimize();
            let _ = w.show();
            let _ = w.set_focus();
        }
        let _ = handle.emit("ledger-notification", target);
    });
}

/// The taskbar overlay with the Ledger's count: a square RGBA image `size` pixels wide, or none to remove it. Other
/// systems have no overlay, so there it does nothing.
#[tauri::command]
pub fn ledger_badge(app: AppHandle, rgba: Option<Vec<u8>>, size: u32) -> Result<(), String> {
    #[cfg(windows)]
    {
        let window = app
            .get_webview_window("main")
            .ok_or("The main window was not found")?;
        let icon = rgba.map(|pixels| tauri::image::Image::new_owned(pixels, size, size));
        window.set_overlay_icon(icon).map_err(|e| e.to_string())?;
    }
    #[cfg(not(windows))]
    let _ = (app, rgba, size);
    Ok(())
}
