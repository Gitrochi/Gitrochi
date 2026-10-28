//! Repository index (crates/gitrochi-index): the same SQLite index and JSON commands the
//! macOS app reaches through the C ABI. macOS: macos/Sources/Core/RepoIndex.swift.

use serde_json::{json, Value};

/// Runs `{"repo", "git"?, "command", "args"}` off the async runtime (a sync can take a while)
/// and answers `{"result"}` or `{"error"}`. `GITROCHI_INDEX=0` turns the index off, as on macOS.
#[tauri::command]
pub async fn index_call(request: Value) -> Value {
    if std::env::var("GITROCHI_INDEX").as_deref() == Ok("0") {
        return json!({"error": {"code": "DISABLED", "message": "The repository index is turned off"}});
    }
    tauri::async_runtime::spawn_blocking(move || gitrochi_index::call(&request))
        .await
        .unwrap_or_else(|_| json!({"error": {"code": "DATABASE", "message": "Index call failed"}}))
}
