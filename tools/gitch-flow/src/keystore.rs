//! OS 비밀 보관소(맥 키체인 · Windows 자격 증명 관리자 · 리눅스 키링). 앱과 같은 keyring crate 형식을 쓴다.

/// 엔진이 저장하는 연결 비밀값의 서비스 이름.
pub const ENGINE_SERVICE: &str = "gitch-flow";

/// Gitrochi 앱이 호스팅 계정 토큰을 둔 서비스 이름(맥 Accounts.swift · Windows system.rs 와 같아야 한다).
pub fn app_service() -> &'static str {
    if cfg!(target_os = "macos") {
        "com.ensnif.Gitrochi"
    } else {
        "Gitrochi"
    }
}

fn disabled() -> bool {
    // 테스트 · CI 에서는 보관소를 건드리지 않는다(확인 창이 뜨거나 멈추지 않게).
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

/// 엔진 연결 비밀값.
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

/// 앱이 저장한 호스팅 계정 토큰(`acct:<id>`).
pub fn app_token(account_id: &str) -> Option<String> {
    get_from(app_service(), &format!("acct:{account_id}"))
}
