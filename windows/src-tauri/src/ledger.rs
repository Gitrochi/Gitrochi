//! Ledger (crates/gitrochi-ledger): the sessions agents report and a person's decisions about them, in the same
//! SQLite database the macOS app reaches through the C ABI. macOS: macos/Sources/Services/LedgerBackend.swift.

use serde_json::{json, Value};

/// Runs one ledger method off the async runtime (a write may wait for another process's) and answers the result or
/// `{"error"}`. The app is the core's `app` caller, the only one allowed a person's operations (docs/ledger/DESIGN.md
/// §8); `GITROCHI_LEDGER=0` and `GITROCHI_LEDGER_DB` are read by the core itself.
#[tauri::command]
pub async fn ledger_call(method: String, args: Value) -> Value {
    tauri::async_runtime::spawn_blocking(move || gitrochi_ledger::call(&method, &args))
        .await
        .unwrap_or_else(|_| json!({"error": {"code": "DATABASE", "message": "Ledger call failed"}}))
}
