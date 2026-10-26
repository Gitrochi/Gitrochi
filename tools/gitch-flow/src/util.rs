//! 시간 · 해시 · 난수 · 경로 · 언어 · glob 처럼 모든 모듈이 쓰는 작은 도구.

use regex::Regex;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------- 시간 ----------

/// 1970-01-01 UTC 부터의 밀리초.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 밀리초를 RFC 3339 UTC 문자열로. 시간대 데이터베이스 없이 쓰려고 직접 계산한다.
pub fn rfc3339(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let millis = ms % 1000;
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let sod = secs.rem_euclid(86_400);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y,
        m,
        d,
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60,
        millis
    )
}

/// 실행 ID 앞부분처럼 정렬되는 짧은 시각 표기(UTC): 20261026-123456.
pub fn compact_stamp(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let sod = secs.rem_euclid(86_400);
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        y,
        m,
        d,
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60
    )
}

/// 하루 안의 분(0..1440). `offset_min` 은 UTC 와의 차이(분).
pub fn minute_of_day(ms: u64, offset_min: i64) -> i64 {
    let secs = (ms / 1000) as i64 + offset_min * 60;
    secs.rem_euclid(86_400) / 60
}

// Howard Hinnant 의 날짜 계산(그레고리력, 날짜 → 연월일).
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// "90s" · "10m" · "1h30m" · "1500ms" · 숫자(초)를 밀리초로.
pub fn parse_duration(text: &str) -> Option<u64> {
    let s = text.trim();
    if s.is_empty() {
        return None;
    }
    if let Ok(n) = s.parse::<u64>() {
        return Some(n * 1000);
    }
    let mut total: u64 = 0;
    let mut num = String::new();
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    let mut seen = false;
    while i < chars.len() {
        let c = chars[i];
        if c.is_ascii_digit() || c == '.' {
            num.push(c);
            i += 1;
            continue;
        }
        let mut unit = String::new();
        while i < chars.len() && chars[i].is_ascii_alphabetic() {
            unit.push(chars[i]);
            i += 1;
        }
        let value: f64 = num.parse().ok()?;
        num.clear();
        let factor = match unit.as_str() {
            "ms" => 1.0,
            "s" => 1000.0,
            "m" => 60_000.0,
            "h" => 3_600_000.0,
            _ => return None,
        };
        total += (value * factor) as u64;
        seen = true;
    }
    if !num.is_empty() {
        return None;
    }
    if seen {
        Some(total)
    } else {
        None
    }
}

/// 사람이 읽는 소요 시간: 850ms · 12.3s · 2m 5s.
pub fn human_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        format!("{:.1}s", ms as f64 / 1000.0)
    } else {
        let s = ms / 1000;
        format!("{}m {}s", s / 60, s % 60)
    }
}

// ---------- 해시 · 난수 ----------

pub fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 0xf) as usize] as char);
    }
    out
}

/// RFC 2104 HMAC-SHA256. 결과 위조 방지 서명에 쓴다(별도 crate 없이 sha2 로).
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= block[i];
        opad[i] ^= block[i];
    }
    let inner = Sha256::new()
        .chain_update(ipad)
        .chain_update(msg)
        .finalize();
    let outer = Sha256::new()
        .chain_update(opad)
        .chain_update(inner)
        .finalize();
    outer.into()
}

/// 운영체제 난수. 실패하면 시각 · PID 로 만든 값으로 대신한다(실행 ID 처럼 겹치지만 않으면 되는 곳에만).
pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    if getrandom::getrandom(&mut buf).is_err() {
        let seed = format!(
            "{}:{}:{:?}",
            now_ms(),
            std::process::id(),
            std::thread::current().id()
        );
        let digest = Sha256::digest(seed.as_bytes());
        for (i, b) in buf.iter_mut().enumerate() {
            *b = digest[i % 32];
        }
    }
    buf
}

pub fn random_hex(n_bytes: usize) -> String {
    hex(&random_bytes(n_bytes))
}

// ---------- 경로 ----------

/// 사용자 홈. Windows 에서 Git Bash 가 넘긴 `/c/Users/me` 는 `C:\Users\me` 로 바꾼다.
pub fn home_dir() -> Option<PathBuf> {
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() {
            return Some(PathBuf::from(msys_to_native(&h)));
        }
    }
    std::env::var("USERPROFILE")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

/// MSYS 형식 경로(/c/x)를 Windows 형식(C:\x)으로. 다른 운영체제에서는 그대로.
pub fn msys_to_native(p: &str) -> String {
    if cfg!(windows) {
        let b = p.as_bytes();
        if b.len() >= 2
            && b[0] == b'/'
            && b[1].is_ascii_alphabetic()
            && (b.len() == 2 || b[2] == b'/')
        {
            let drive = (b[1] as char).to_ascii_uppercase();
            let rest = if b.len() > 2 { &p[2..] } else { "" };
            return format!("{drive}:{}", rest.replace('/', "\\"));
        }
    }
    p.to_string()
}

/// gitch 설정 폴더(`~/.config/gitsw`). gitch 와 같은 규칙으로 찾는다.
pub fn gitsw_dir() -> PathBuf {
    if let Ok(cfg) = std::env::var("GITSW_CONFIG") {
        if !cfg.is_empty() {
            let p = PathBuf::from(msys_to_native(&cfg));
            if let Some(parent) = p.parent() {
                return parent.to_path_buf();
            }
        }
    }
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        if !x.is_empty() {
            return PathBuf::from(msys_to_native(&x)).join("gitsw");
        }
    }
    home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config")
        .join("gitsw")
}

/// gitch 상태 폴더(`~/.local/state/gitsw`) — 행동 기록 actions.jsonl 이 있는 곳.
pub fn gitsw_state_dir() -> PathBuf {
    if let Ok(x) = std::env::var("XDG_STATE_HOME") {
        if !x.is_empty() {
            return PathBuf::from(msys_to_native(&x)).join("gitsw");
        }
    }
    home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".local")
        .join("state")
        .join("gitsw")
}

/// 결과 캐시 폴더.
pub fn cache_dir() -> PathBuf {
    if let Ok(p) = std::env::var("GITCH_FLOW_CACHE") {
        if !p.is_empty() {
            return PathBuf::from(msys_to_native(&p));
        }
    }
    if let Ok(x) = std::env::var("XDG_CACHE_HOME") {
        if !x.is_empty() {
            return PathBuf::from(msys_to_native(&x)).join("gitch").join("flow");
        }
    }
    let home = home_dir().unwrap_or_else(|| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        home.join("Library")
            .join("Caches")
            .join("gitch")
            .join("flow")
    } else if cfg!(windows) {
        std::env::var("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join("AppData").join("Local"))
            .join("gitch")
            .join("cache")
            .join("flow")
    } else {
        home.join(".cache").join("gitch").join("flow")
    }
}

/// 저장소 안 경로를 `/` 로 통일한 상대 경로로.
pub fn rel_slash(root: &Path, p: &Path) -> String {
    let r = p.strip_prefix(root).unwrap_or(p);
    r.to_string_lossy().replace('\\', "/")
}

/// 원자적으로 쓰기: 임시 파일에 쓰고 이름을 바꾼다(읽는 쪽이 반쯤 쓴 파일을 보지 않게).
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", random_hex(4)));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)
}

// ---------- 언어 ----------

static LANG_EN: OnceLock<bool> = OnceLock::new();

/// 사람용 글의 언어. gitch 와 같게 기본은 한국어, `--lang en` · `GITCH_FLOW_LANG=en` 이면 영어.
pub fn set_lang(lang: Option<&str>) {
    let from_env = std::env::var("GITCH_FLOW_LANG").ok();
    let pick = lang.map(|s| s.to_string()).or(from_env).unwrap_or_default();
    let _ = LANG_EN.set(pick.to_ascii_lowercase().starts_with("en"));
}

pub fn is_en() -> bool {
    *LANG_EN.get_or_init(|| {
        std::env::var("GITCH_FLOW_LANG")
            .map(|s| s.to_ascii_lowercase().starts_with("en"))
            .unwrap_or(false)
    })
}

/// 두 언어 중 지금 언어의 글.
pub fn tr(ko: &str, en: &str) -> String {
    if is_en() {
        en.to_string()
    } else {
        ko.to_string()
    }
}

// ---------- glob ----------

fn glob_cache() -> &'static Mutex<HashMap<String, Regex>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Regex>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// glob(`*` · `**` · `?` · `{a,b}` · `[abc]`)을 정규식으로. 경로 구분자는 `/`.
pub fn glob_to_regex(pattern: &str) -> String {
    let p: Vec<char> = pattern.chars().collect();
    let mut out = String::from("^");
    let mut i = 0;
    let mut in_brace = 0;
    while i < p.len() {
        let c = p[i];
        match c {
            '*' => {
                if i + 1 < p.len() && p[i + 1] == '*' {
                    // "**/" 는 0개 이상의 폴더, 끝의 "**" 는 무엇이든
                    if i + 2 < p.len() && p[i + 2] == '/' {
                        out.push_str("(?:.*/)?");
                        i += 3;
                        continue;
                    }
                    out.push_str(".*");
                    i += 2;
                    continue;
                }
                out.push_str("[^/]*");
            }
            '?' => out.push_str("[^/]"),
            '{' => {
                in_brace += 1;
                out.push_str("(?:");
            }
            '}' if in_brace > 0 => {
                in_brace -= 1;
                out.push(')');
            }
            ',' if in_brace > 0 => out.push('|'),
            '[' => {
                let mut j = i + 1;
                let mut class = String::from("[");
                if j < p.len() && (p[j] == '!' || p[j] == '^') {
                    class.push('^');
                    j += 1;
                }
                while j < p.len() && p[j] != ']' {
                    if p[j] == '\\' {
                        class.push_str("\\\\");
                    } else {
                        class.push(p[j]);
                    }
                    j += 1;
                }
                if j < p.len() {
                    class.push(']');
                    out.push_str(&class);
                    i = j + 1;
                    continue;
                }
                out.push_str("\\[");
            }
            _ => {
                if "\\.+()|^$".contains(c) {
                    out.push('\\');
                }
                out.push(c);
            }
        }
        i += 1;
    }
    out.push('$');
    out
}

/// 경로가 glob 에 맞는지. 패턴에 `/` 가 없으면 파일 이름만 비교한다(`*.ts` 가 하위 폴더에도 맞게).
pub fn glob_match(pattern: &str, path: &str) -> bool {
    let path = path.trim_start_matches("./");
    let pattern = pattern.trim_start_matches("./");
    let target = if pattern.contains('/') {
        path
    } else {
        path.rsplit('/').next().unwrap_or(path)
    };
    let mut cache = glob_cache().lock().unwrap_or_else(|e| e.into_inner());
    if !cache.contains_key(pattern) {
        let re = Regex::new(&glob_to_regex(pattern)).unwrap_or_else(|_| Regex::new("^$").unwrap());
        cache.insert(pattern.to_string(), re);
    }
    cache
        .get(pattern)
        .map(|re| re.is_match(target))
        .unwrap_or(false)
}

// ---------- 셸 ----------

/// POSIX 셸에 한 인자로 넘기도록 작은따옴표로 감싼다.
pub fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "@%+=:,./-_".contains(c))
    {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// PowerShell 에 한 인자로 넘기도록 감싼다.
pub fn pwsh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339_known_dates() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00.000Z");
        // 2026-10-26T12:34:56.789Z
        assert_eq!(rfc3339(1_793_018_096_789), "2026-10-26T12:34:56.789Z");
        assert_eq!(compact_stamp(1_793_018_096_789), "20261026-123456");
        // 윤년 2월 29일
        assert_eq!(rfc3339(951_782_400_000), "2000-02-29T00:00:00.000Z");
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("90s"), Some(90_000));
        assert_eq!(parse_duration("10m"), Some(600_000));
        assert_eq!(parse_duration("1h30m"), Some(5_400_000));
        assert_eq!(parse_duration("1500ms"), Some(1500));
        assert_eq!(parse_duration("2.5s"), Some(2500));
        assert_eq!(parse_duration("30"), Some(30_000));
        assert_eq!(parse_duration("abc"), None);
        assert_eq!(parse_duration("10x"), None);
        assert_eq!(parse_duration("10"), Some(10_000));
        assert_eq!(parse_duration(""), None);
    }

    #[test]
    fn hmac_matches_rfc4231_case2() {
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            hex(&mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn globs() {
        assert!(glob_match("*.ts", "src/a/b.ts"));
        assert!(!glob_match("*.ts", "src/a/b.tsx"));
        assert!(glob_match("src/**/*.ts", "src/a/b/c.ts"));
        assert!(glob_match("src/**/*.ts", "src/c.ts"));
        assert!(!glob_match("src/*.ts", "src/a/c.ts"));
        assert!(glob_match("**/*.{yml,yaml}", ".github/workflows/x.yaml"));
        assert!(glob_match("package-lock.json", "package-lock.json"));
        assert!(glob_match("docs/**", "docs/a/b.md"));
        assert!(glob_match("test_?.py", "tests/test_a.py"));
        assert!(glob_match("[ab].txt", "a.txt"));
        assert!(!glob_match("[!ab].txt", "a.txt"));
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("abc"), "abc");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote("$(rm -rf /)"), "'$(rm -rf /)'");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(pwsh_quote("it's"), "'it''s'");
    }

    #[test]
    fn minute_of_day_offsets() {
        // 1970-01-01T00:30Z → UTC 30분, +09:00 이면 570분
        assert_eq!(minute_of_day(30 * 60_000, 0), 30);
        assert_eq!(minute_of_day(30 * 60_000, 540), 570);
        assert_eq!(minute_of_day(30 * 60_000, -60), 1410);
    }
}
