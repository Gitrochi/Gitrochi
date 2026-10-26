//! The OS secret store (macOS Keychain, Windows Credential Manager, Linux keyring), in the same keyring-crate format as the apps.

/// Service name for the connection secrets the engine stores.
pub const ENGINE_SERVICE: &str = "gitch-flow";

/// Service name under which the Gitrochi apps keep hosting account tokens (must match macOS Accounts.swift and Windows system.rs).
pub fn app_service() -> &'static str {
    if cfg!(target_os = "macos") {
        "com.ensnif.Gitrochi"
    } else {
        "Gitrochi"
    }
}

fn disabled() -> bool {
    // Tests and CI never touch the store, so no prompt appears and nothing hangs.
    std::env::var("GITCH_FLOW_NO_KEYSTORE")
        .map(|v| !v.is_empty() && v != "0")
        .unwrap_or(false)
}

pub fn get_from(service: &str, account: &str) -> Option<String> {
    if disabled() {
        return None;
    }
    keyring::Entry::new(service, account)
        .ok()?
        .get_password()
        .ok()
        .filter(|s| !s.is_empty())
}

/// An engine connection secret.
pub fn get(name: &str) -> Option<String> {
    get_from(ENGINE_SERVICE, name)
}

pub fn set(name: &str, value: &str) -> Result<(), String> {
    if disabled() {
        return Err("keystore disabled".into());
    }
    keyring::Entry::new(ENGINE_SERVICE, name)
        .map_err(|e| e.to_string())?
        .set_password(value)
        .map_err(|e| e.to_string())
}

pub fn delete(name: &str) -> bool {
    if disabled() {
        return false;
    }
    keyring::Entry::new(ENGINE_SERVICE, name)
        .ok()
        .map(|e| e.delete_credential().is_ok())
        .unwrap_or(false)
}

/// A hosting account token the app stored (`acct:<id>`).
pub fn app_token(account_id: &str) -> Option<String> {
    get_from(app_service(), &format!("acct:{account_id}"))
}
