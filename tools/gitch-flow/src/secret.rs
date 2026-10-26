//! 비밀값 찾기. 흐름 파일에는 참조 이름만 있고, 값은 여기서만 꺼낸다(꺼내는 즉시 마스킹 사전에 넣는다).
//! 순서: 앱이 표준 입력으로 넘긴 값 → GITCH_SECRET_<이름> → (CI 모드) 같은 이름의 환경변수 → OS 보관소.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

fn provided() -> &'static Mutex<HashMap<String, String>> {
    static P: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    P.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 앱이 `--secrets-stdin` 으로 넘긴 {"이름": "값"} 을 받아 둔다.
pub fn provide_json(text: &str) -> Result<usize, String> {
    let v: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let obj = v.as_object().ok_or("expected a JSON object")?;
    let mut p = provided().lock().unwrap_or_else(|e| e.into_inner());
    for (k, x) in obj {
        if let Some(s) = x.as_str() {
            p.insert(k.clone(), s.to_string());
        }
    }
    Ok(obj.len())
}

fn env_key(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect()
}

pub fn resolve(name: &str, ci: bool) -> Option<String> {
    if let Some(v) = provided()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(name)
    {
        return Some(v.clone());
    }
    if let Ok(v) = std::env::var(format!("GITCH_SECRET_{}", env_key(name))) {
        if !v.is_empty() {
            return Some(v);
        }
    }
    if ci {
        for k in [name.to_string(), env_key(name)] {
            if let Ok(v) = std::env::var(&k) {
                if !v.is_empty() {
                    return Some(v);
                }
            }
        }
    }
    crate::keystore::get(name)
}

/// 비밀처럼 보이는 환경변수 이름(물려줄 때 뺀다).
pub fn looks_secret(name: &str) -> bool {
    let u = name.to_ascii_uppercase();
    if u.starts_with("GITCH_SECRET_") {
        return true;
    }
    [
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "API_KEY",
        "APIKEY",
        "PRIVATE_KEY",
        "CREDENTIAL",
        "ACCESS_KEY",
    ]
    .iter()
    .any(|w| u.contains(w))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert!(looks_secret("GITHUB_TOKEN"));
        assert!(looks_secret("db_password"));
        assert!(looks_secret("AWS_SECRET_ACCESS_KEY"));
        assert!(!looks_secret("PATH"));
        assert!(!looks_secret("JAVA_HOME"));
        assert_eq!(env_key("deploy-token"), "DEPLOY_TOKEN");
    }

    #[test]
    fn provided_values_win() {
        provide_json(r#"{"unit-test-secret": "v1"}"#).unwrap();
        assert_eq!(resolve("unit-test-secret", false).as_deref(), Some("v1"));
        assert!(provide_json("[1]").is_err());
    }
}
