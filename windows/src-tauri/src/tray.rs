//! Gitrochi in the background: the tray icon and its menu, and closing the window into the tray, so runs scheduled for
//! later still start and terminals keep running. The screen builds the menu (app/lib/background-menu.ts) and decides
//! what closing the window does (app/lib/tray.ts). (macOS: App/MenuBar.swift)

use serde::Deserialize;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, CloseRequestApi, Emitter, Manager, State, Window};

const TRAY: &str = "main";

#[derive(Default)]
pub struct Background {
    /// The screen answers the window's close button (set once it has sent its first menu)
    handles_close: AtomicBool,
    /// Quitting for good: the window closes without asking the screen
    quitting: AtomicBool,
}

/// One line of the tray menu; without a label it is a separator
#[derive(Deserialize)]
pub struct TrayItem {
    id: Option<String>,
    label: Option<String>,
    enabled: bool,
}

/// The tray icon, hidden until the screen sends its menu and the setting is on
pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = Menu::new(app)?;
    let mut builder = TrayIconBuilder::with_id(TRAY)
        .tooltip("Gitrochi")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let _ = app.emit_to("main", "tray-action", event.id().as_ref());
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    let tray = builder.build(app)?;
    tray.set_visible(false)?;
    Ok(())
}

pub fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// The window's close button: the screen hides the window into the tray or asks before quitting. Until the screen is
/// running (or after it failed to start) the window closes as it always did.
pub fn close_requested(window: &Window, api: &CloseRequestApi) {
    let state = window.state::<Background>();
    if state.quitting.load(Ordering::SeqCst) || !state.handles_close.load(Ordering::SeqCst) {
        return;
    }
    api.prevent_close();
    let _ = window.emit("app-close-requested", ());
}

#[tauri::command]
pub fn tray_update(
    app: AppHandle,
    state: State<'_, Background>,
    items: Vec<TrayItem>,
    visible: bool,
) -> Result<(), String> {
    state.handles_close.store(true, Ordering::SeqCst);
    let tray = app.tray_by_id(TRAY).ok_or("The tray icon is missing")?;
    let menu = Menu::new(&app).map_err(|e| e.to_string())?;
    for item in items {
        match item.label {
            Some(label) => {
                let id = item.id.unwrap_or_default();
                let entry = MenuItem::with_id(&app, id, label, item.enabled, None::<&str>)
                    .map_err(|e| e.to_string())?;
                menu.append(&entry).map_err(|e| e.to_string())?;
            }
            None => {
                let separator = PredefinedMenuItem::separator(&app).map_err(|e| e.to_string())?;
                menu.append(&separator).map_err(|e| e.to_string())?;
            }
        }
    }
    tray.set_menu(Some(menu)).map_err(|e| e.to_string())?;
    tray.set_visible(visible).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn window_hide(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.hide();
    }
}

#[tauri::command]
pub fn window_show(app: AppHandle) {
    show_main(&app);
}

/// Quits for good (the screen has asked already)
#[tauri::command]
pub fn app_quit(app: AppHandle, state: State<'_, Background>) {
    state.quitting.store(true, Ordering::SeqCst);
    app.exit(0);
}
