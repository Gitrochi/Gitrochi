//! Small helpers shared by the modules: time, NFC, lenient argument reading and versions.

use crate::error::{Error, Result};
use crate::vocab;
use serde_json::Value;
use std::cmp::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};
use unicode_normalization::{is_nfc_quick, IsNormalized, UnicodeNormalization};

/// Epoch milliseconds, the ledger's only time unit.
pub type Ms = i64;

pub const HOUR: Ms = 3_600_000;
pub const DAY: Ms = 24 * HOUR;

pub fn now_ms() -> Ms {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as Ms)
        .unwrap_or(0)
}

/// NFC without trimming, for bodies whose layout matters. Text unpacked from archives on
/// macOS often arrives decomposed (NFD), which would otherwise never compare equal.
pub fn nfc_text(text: &str) -> String {
    match is_nfc_quick(text.chars()) {
        IsNormalized::Yes => text.to_string(),
        _ => text.nfc().collect(),
    }
}

/// NFC and trimmed; `None` when nothing is left.
pub fn clean(text: &str) -> Option<String> {
    let normalized = nfc_text(text);
    let trimmed = normalized.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn scalar_text(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => clean(s),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// A string argument (numbers are accepted as their text), NFC-normalised and trimmed.
pub fn arg_str(args: &Value, key: &str) -> Option<String> {
    scalar_text(&args[key])
}

/// The first of several spellings that is present (`chatUrl`, `chat_url`).
pub fn arg_str_any(args: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| arg_str(args, key))
}

/// Whether the key is present with a non-null value.
pub fn has(args: &Value, key: &str) -> bool {
    !args[key].is_null()
}

/// A list argument. Agents send arrays, comma or newline separated text, or one number;
/// all of them are accepted, like the original tool did.
pub fn arg_list(args: &Value, key: &str) -> Vec<String> {
    list_of(&args[key])
}

pub fn list_of(value: &Value) -> Vec<String> {
    match value {
        Value::Array(items) => items.iter().filter_map(scalar_text).collect(),
        Value::String(text) => text
            .split([',', '\n'])
            .filter_map(clean)
            .collect::<Vec<_>>(),
        Value::Number(n) => vec![n.to_string()],
        _ => Vec::new(),
    }
}

/// Whole numbers from an array, a number, or text split on commas and spaces ("12" stays 12).
pub fn arg_ints(args: &Value, key: &str) -> Vec<i64> {
    match &args[key] {
        Value::Array(items) => items
            .iter()
            .filter_map(|v| match v {
                Value::Number(n) => n.as_i64(),
                Value::String(s) => s.trim().parse().ok(),
                _ => None,
            })
            .collect(),
        Value::Number(n) => n.as_i64().into_iter().collect(),
        Value::String(s) => s
            .split(|c: char| c == ',' || c.is_whitespace())
            .filter_map(|p| p.trim().parse().ok())
            .collect(),
        _ => Vec::new(),
    }
}

pub fn arg_bool(args: &Value, key: &str) -> Option<bool> {
    match &args[key] {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => Some(n.as_i64() == Some(1)),
        Value::String(s) => match s.trim() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" | "" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

pub fn arg_i64(args: &Value, key: &str) -> Result<Option<i64>> {
    match &args[key] {
        Value::Null => Ok(None),
        Value::Number(n) => n
            .as_i64()
            .or_else(|| n.as_f64().map(|f| f as i64))
            .map(Some)
            .ok_or_else(|| Error::invalid(format!("{key} must be a whole number"))),
        Value::String(s) if s.trim().is_empty() => Ok(None),
        Value::String(s) => s
            .trim()
            .parse()
            .map(Some)
            .map_err(|_| Error::invalid(format!("{key} must be a whole number"))),
        _ => Err(Error::invalid(format!("{key} must be a whole number"))),
    }
}

/// `"v2.5.100"`, `"Release 2.5.100"` → `"2.5.100"`; the latest words → `"latest"`.
/// A version has at least two numeric parts, ASCII digits only.
pub fn parse_version(text: &str) -> Option<String> {
    let text = clean(text)?;
    if vocab::is_latest_word(&text) {
        return Some("latest".into());
    }
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if !bytes[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        let start = i;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        let mut end = i;
        let mut groups = 0;
        while end + 1 < bytes.len() && bytes[end] == b'.' && bytes[end + 1].is_ascii_digit() {
            end += 1;
            while end < bytes.len() && bytes[end].is_ascii_digit() {
                end += 1;
            }
            groups += 1;
        }
        if groups > 0 {
            return Some(text[start..end].to_string());
        }
    }
    None
}

/// A version argument resolved against the project's HEAD (`latest` → HEAD).
pub fn resolve_version(text: Option<&str>, head: Option<&str>) -> Option<String> {
    match parse_version(text?)?.as_str() {
        "latest" => head.map(str::to_string),
        version => Some(version.to_string()),
    }
}

/// Numeric order of versions: 2.10 > 2.9, 2.5.100 > 2.5.99, 1.0 < 1.0.1.
pub fn compare_versions(a: &str, b: &str) -> Ordering {
    let key = |v: &str| -> Vec<u64> {
        let parts: Option<Vec<u64>> = v.split('.').map(|p| p.parse().ok()).collect();
        parts.unwrap_or_else(|| vec![u64::MAX])
    };
    key(a).cmp(&key(b)).then_with(|| a.cmp(b))
}

/// Session IDs: 3 to 48 letters (any script), digits, `.`, `_` and `-`.
pub fn valid_session_id(id: &str) -> bool {
    let count = id.chars().count();
    (3..=48).contains(&count)
        && id
            .chars()
            .all(|c| c.is_alphanumeric() || c == '.' || c == '_' || c == '-')
}

/// At most `limit` characters, with an ellipsis when cut.
pub fn truncate(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    let mut out: String = text.chars().take(limit.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// One line for lists: whitespace collapsed, Markdown emphasis markers dropped.
pub fn one_line(text: &str, limit: usize) -> String {
    let plain = text.replace("**", "").replace('`', "");
    truncate(
        &plain.split_whitespace().collect::<Vec<_>>().join(" "),
        limit,
    )
}

/// A JSON array column read back as strings (unknown shapes read as empty).
pub fn string_list(text: &str) -> Vec<String> {
    serde_json::from_str::<Vec<String>>(text).unwrap_or_default()
}

pub fn json_text(value: &impl serde::Serialize) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

/// Adds the new entries to the list, keeping the existing order (a set union).
pub fn union(existing: &mut Vec<String>, new: Vec<String>) -> bool {
    let mut changed = false;
    for item in new {
        if !existing.contains(&item) {
            existing.push(item);
            changed = true;
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn versions_are_read_from_names() {
        assert_eq!(parse_version("v2.5.100").as_deref(), Some("2.5.100"));
        assert_eq!(parse_version("Example 2.5.107").as_deref(), Some("2.5.107"));
        assert_eq!(parse_version("a1b2.3").as_deref(), Some("2.3"));
        assert_eq!(parse_version("2.5.100.").as_deref(), Some("2.5.100"));
        assert_eq!(parse_version("v2"), None);
        assert_eq!(parse_version("1..2"), None);
        assert_eq!(parse_version("  "), None);
        assert_eq!(parse_version("LATEST").as_deref(), Some("latest"));
        assert_eq!(parse_version("head").as_deref(), Some("latest"));
        assert_eq!(
            resolve_version(Some("latest"), Some("1.4.2")).as_deref(),
            Some("1.4.2")
        );
        assert_eq!(resolve_version(Some("latest"), None), None);
    }

    #[test]
    fn versions_compare_as_numbers() {
        assert_eq!(compare_versions("2.10", "2.9"), Ordering::Greater);
        assert_eq!(compare_versions("2.5.100", "2.5.99"), Ordering::Greater);
        assert_eq!(compare_versions("1.0", "1.0.1"), Ordering::Less);
        assert_eq!(compare_versions("1.0", "1.0"), Ordering::Equal);
    }

    #[test]
    fn loose_lists_and_numbers() {
        let args =
            json!({"a": "x, y\nz", "b": ["p", 5, "", null], "c": 7, "d": "12", "e": "1 2,3"});
        assert_eq!(arg_list(&args, "a"), ["x", "y", "z"]);
        assert_eq!(arg_list(&args, "b"), ["p", "5"]);
        assert_eq!(arg_list(&args, "c"), ["7"]);
        assert!(arg_list(&args, "missing").is_empty());
        assert_eq!(arg_ints(&args, "d"), [12]);
        assert_eq!(arg_ints(&args, "e"), [1, 2, 3]);
        assert_eq!(arg_ints(&args, "c"), [7]);
    }

    #[test]
    fn session_ids() {
        assert!(valid_session_id("S1031-02"));
        assert!(valid_session_id("web.chat_id-7"));
        assert!(valid_session_id("세션-01"));
        assert!(!valid_session_id("a b"));
        assert!(!valid_session_id("ab"));
        assert!(!valid_session_id(&"x".repeat(49)));
        assert!(!valid_session_id("x/y"));
    }

    #[test]
    fn nfc_and_trim() {
        let decomposed = "\u{1100}\u{1161}"; // 가 as two jamo
        assert_eq!(clean(&format!("  {decomposed} ")).as_deref(), Some("가"));
        assert_eq!(clean(" \n "), None);
        assert_eq!(truncate("abcdef", 4), "abc…");
        assert_eq!(one_line("**a**\n  `b`   c", 20), "a b c");
    }
}
