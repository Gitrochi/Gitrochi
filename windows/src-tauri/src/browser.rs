// Browser tabs in the terminal panel: native child webviews placed over the pane, so every site opens (an <iframe>
// is refused by sites that forbid framing). Pages load from other origins than the app, so Tauri gives them no IPC.
// macOS: Services/BrowserSession.swift

use serde::Serialize;
use tauri::ipc::Channel;
use tauri::webview::{NewWindowResponse, PageLoadEvent};
use tauri::{LogicalPosition, LogicalSize, Manager, Url, WebviewBuilder, WebviewUrl};

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum BrowserEvent {
    Title { value: String },
    Url { value: String },
    Loading { value: bool },
}

fn label(id: &str) -> String {
    format!("browser-{id}")
}

fn parse(url: &str) -> Result<Url, String> {
    let parsed = Url::parse(url).map_err(|e| e.to_string())?;
    match parsed.scheme() {
        "http" | "https" | "about" => Ok(parsed),
        other => Err(format!("unsupported scheme: {other}")),
    }
}

fn webview(app: &tauri::AppHandle, id: &str) -> Result<tauri::Webview, String> {
    app.get_webview(&label(id))
        .ok_or_else(|| "browser tab is gone".to_string())
}

/// Opens a page in a new child webview of the calling window, at the given logical rectangle
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub fn browser_open(
    window: tauri::Window,
    id: String,
    url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    on_event: Channel<BrowserEvent>,
) -> Result<(), String> {
    let target = parse(&url)?;
    let app = window.app_handle().clone();
    let name = label(&id);
    let (titles, loads, navigations) = (on_event.clone(), on_event.clone(), on_event);
    let opener = name.clone();
    let builder = WebviewBuilder::new(&name, WebviewUrl::External(target))
        .on_document_title_changed(move |_, title| {
            let _ = titles.send(BrowserEvent::Title { value: title });
        })
        .on_page_load(move |view, payload| {
            let loading = matches!(payload.event(), PageLoadEvent::Started);
            let _ = loads.send(BrowserEvent::Loading { value: loading });
            if let Ok(url) = view.url() {
                let _ = loads.send(BrowserEvent::Url {
                    value: url.to_string(),
                });
            }
        })
        .on_navigation(move |url| {
            let allowed = matches!(url.scheme(), "http" | "https" | "about" | "blob" | "data");
            if allowed {
                let _ = navigations.send(BrowserEvent::Url {
                    value: url.to_string(),
                });
            }
            allowed
        })
        // a link that asks for a new window opens in the same tab
        .on_new_window(move |url, _| {
            if let Some(view) = app.get_webview(&opener) {
                let _ = view.navigate(url);
            }
            NewWindowResponse::Deny
        });
    window
        .add_child(
            builder,
            LogicalPosition::new(x, y),
            LogicalSize::new(width.max(1.0), height.max(1.0)),
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Follows the pane: its place, its size, and whether it is on screen
#[tauri::command]
pub fn browser_place(
    app: tauri::AppHandle,
    id: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    visible: bool,
) -> Result<(), String> {
    let view = webview(&app, &id)?;
    if !visible {
        return view.hide().map_err(|e| e.to_string());
    }
    view.set_position(LogicalPosition::new(x, y))
        .map_err(|e| e.to_string())?;
    view.set_size(LogicalSize::new(width.max(1.0), height.max(1.0)))
        .map_err(|e| e.to_string())?;
    view.show().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_navigate(app: tauri::AppHandle, id: String, url: String) -> Result<(), String> {
    webview(&app, &id)?
        .navigate(parse(&url)?)
        .map_err(|e| e.to_string())
}

/// Back (-1) or forward (1) in the page's history
#[tauri::command]
pub fn browser_history(app: tauri::AppHandle, id: String, step: i32) -> Result<(), String> {
    webview(&app, &id)?
        .eval(format!("history.go({step})"))
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_reload(app: tauri::AppHandle, id: String) -> Result<(), String> {
    webview(&app, &id)?.reload().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_focus(app: tauri::AppHandle, id: String) -> Result<(), String> {
    webview(&app, &id)?.set_focus().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_close(app: tauri::AppHandle, id: String) -> Result<(), String> {
    match app.get_webview(&label(&id)) {
        Some(view) => view.close().map_err(|e| e.to_string()),
        None => Ok(()),
    }
}
