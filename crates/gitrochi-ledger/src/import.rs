//! Pasted reports: conversations that cannot call a tool (a chat in a browser) end their
//! answer with a ```` ```ledger ```` block, and a person pastes the conversation here.
//! Blocks already imported are recognised by a hash of their canonical JSON.

use crate::baseline;
use crate::db::Db;
use crate::error::{Error, Result};
use crate::report;
use crate::session;
use crate::settings::Settings;
use crate::sha1;
use crate::util::{self, Ms};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::OnceLock;

/// Every fenced ```` ```ledger ```` block; without one, the whole text as JSON, or each
/// line that starts with `{` and has an `"event"` key (a block copied without its fence).
pub fn blocks(text: &str) -> Vec<Value> {
    static FENCE: OnceLock<regex_lite::Regex> = OnceLock::new();
    let fence = FENCE.get_or_init(|| {
        regex_lite::Regex::new(r"(?is)```[ \t]*ledger[^\n]*\n(.*?)```").expect("valid pattern")
    });
    let text = util::nfc_text(text);
    let fenced: Vec<&str> = fence
        .captures_iter(&text)
        .filter_map(|c| c.get(1).map(|m| m.as_str()))
        .collect();
    let chunks = if fenced.is_empty() {
        vec![text.as_str()]
    } else {
        fenced
    };
    let mut out = Vec::new();
    for chunk in chunks {
        let chunk = chunk.trim();
        if let Ok(value) = serde_json::from_str::<Value>(chunk) {
            match value {
                Value::Array(items) => out.extend(items.into_iter().filter(Value::is_object)),
                Value::Object(_) => out.push(value),
                _ => {}
            }
            continue;
        }
        for line in chunk.lines() {
            let mut line = line.trim();
            if line
                .get(..7)
                .is_some_and(|p| p.eq_ignore_ascii_case("ledger:"))
            {
                line = line[7..].trim();
            }
            if !line.starts_with('{') {
                continue;
            }
            if let Ok(value) = serde_json::from_str::<Value>(line) {
                if value.get("event").is_some() {
                    out.push(value);
                }
            }
        }
    }
    out
}

/// JSON with sorted keys and `", "` / `": "` separators, the canonical form the original
/// tool hashed, so the same block hashes the same in both.
pub fn canonical(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => match (n.as_i64(), n.as_u64(), n.as_f64()) {
            (Some(i), _, _) => out.push_str(&i.to_string()),
            (None, Some(u), _) => out.push_str(&u.to_string()),
            (None, None, Some(f)) => out.push_str(&float_repr(f)),
            _ => out.push_str(&n.to_string()),
        },
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let keys: BTreeSet<&String> = map.keys().collect();
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_string(key, out);
                out.push_str(": ");
                write_canonical(&map[key], out);
            }
            out.push('}');
        }
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A float as the original's language prints it: shortest digits, fixed notation for
/// exponents from -4 to 15, otherwise `1e-05` / `1e+16`.
fn float_repr(value: f64) -> String {
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let negative = mantissa.starts_with('-');
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if negative { "-" } else { "" };
    if (-4..16).contains(&exponent) {
        let point = exponent + 1;
        let body = if point <= 0 {
            format!("0.{}{}", "0".repeat((-point) as usize), digits)
        } else if point as usize >= digits.len() {
            format!("{}{}.0", digits, "0".repeat(point as usize - digits.len()))
        } else {
            format!(
                "{}.{}",
                &digits[..point as usize],
                &digits[point as usize..]
            )
        };
        format!("{sign}{body}")
    } else {
        let rest = if digits.len() > 1 {
            format!(".{}", &digits[1..])
        } else {
            String::new()
        };
        let exp_sign = if exponent < 0 { '-' } else { '+' };
        format!(
            "{sign}{}{rest}e{exp_sign}{:02}",
            &digits[..1],
            exponent.unsigned_abs()
        )
    }
}

pub fn hash(block: &Value) -> String {
    sha1::hex(canonical(block).as_bytes())
}

/// One block's outcome (`import` in CONTRACT.md).
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ImportResult {
    pub index: usize,
    /// No error (a duplicate is skipped, not an error).
    pub ok: bool,
    pub duplicate: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notices: Vec<String>,
}

/// Imports every block, each in its own transaction (the duplicate check, the report and
/// the hash together), so one bad block does not stop the rest. Blocks without a project
/// take `project` unless their session already exists.
pub fn import(
    db: &Db,
    settings: &Settings,
    text: &str,
    project: Option<&str>,
    now: Ms,
) -> Result<Vec<ImportResult>> {
    let found = blocks(text);
    if found.is_empty() {
        return Err(Error::invalid(
            "No ledger blocks found (a ```ledger fence, or a JSON line with \"event\")",
        ));
    }
    let mut projects = BTreeSet::new();
    for block in &found {
        let named = util::arg_str(block, "project").or_else(|| project.map(str::to_string));
        if let Some(p) = named {
            projects.insert(p);
        }
    }
    for p in &projects {
        let _ = baseline::refresh(db, p, false);
    }
    let mut results = Vec::with_capacity(found.len());
    for (index, block) in found.iter().enumerate() {
        let digest = hash(block);
        let outcome = db.write(|c| {
            let seen: bool = c.query_row(
                "SELECT EXISTS (SELECT 1 FROM imports WHERE hash = ?1)",
                [&digest],
                |r| r.get(0),
            )?;
            if seen {
                return Ok(None);
            }
            let mut args = block.clone();
            if args.get("project").is_none_or(Value::is_null) {
                if let Some(project) = project {
                    let session = util::arg_str_any(&args, &["session", "sessionId"]);
                    let known = match &session {
                        Some(id) => session::load(c, id)?.is_some(),
                        None => false,
                    };
                    if !known {
                        args["project"] = json!(project);
                    }
                }
            }
            let reply = report::report(c, settings, &args, "import", now + index as Ms, now)?;
            c.execute(
                "INSERT OR IGNORE INTO imports (hash, ts) VALUES (?1, ?2)",
                rusqlite::params![digest, now],
            )?;
            Ok(Some(reply))
        });
        results.push(match outcome {
            Ok((Some(reply), _)) => ImportResult {
                index,
                ok: true,
                duplicate: false,
                error: None,
                session_id: Some(reply.session_id),
                event: Some(reply.event.to_string()),
                notices: reply.notices,
            },
            Ok((None, _)) => ImportResult {
                index,
                ok: true,
                duplicate: true,
                error: None,
                session_id: util::arg_str_any(block, &["session", "sessionId"]),
                event: util::arg_str(block, "event"),
                notices: Vec::new(),
            },
            Err(error) => ImportResult {
                index,
                ok: false,
                duplicate: false,
                error: Some(error.message),
                session_id: util::arg_str_any(block, &["session", "sessionId"]),
                event: util::arg_str(block, "event"),
                notices: Vec::new(),
            },
        });
    }
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fenced_blocks_lines_and_arrays() {
        let text = "intro\n```ledger\n{\"event\":\"start\",\"project\":\"P\"}\n```\nmiddle\n```Ledger extra\n[{\"event\":\"note\"}, 3]\n```\n";
        let found = blocks(text);
        assert_eq!(found.len(), 2);
        assert_eq!(found[1]["event"], "note");
        let plain = "chat line\n{\"session\":\"x-1\",\"event\":\"done\"}\nLEDGER: {\"event\":\"note\"}\n{\"no\":\"event\"}\n{broken";
        let found = blocks(plain);
        assert_eq!(found.len(), 2);
        assert!(blocks("nothing here").is_empty());
        assert_eq!(blocks("{\"event\": \"start\"}").len(), 1);
    }

    #[test]
    fn canonical_json_matches_the_original_form() {
        let value: Value = serde_json::from_str(
            r#"{"summary":"a\"b\\c\nd\u0001","event":"start","n":[1,2.5,true,null],"가":{"z":1,"a":1e-5}}"#,
        )
        .unwrap();
        assert_eq!(
            canonical(&value),
            r#"{"event": "start", "n": [1, 2.5, true, null], "summary": "a\"b\\c\nd\u0001", "가": {"a": 1e-05, "z": 1}}"#
        );
        // sha1 of that exact text, as Python's json.dumps(sort_keys=True, ensure_ascii=False) prints it
        assert_eq!(
            hash(&serde_json::from_str(r#"{"event":"start","project":"P"}"#).unwrap()),
            sha1::hex(br#"{"event": "start", "project": "P"}"#)
        );
    }

    #[test]
    fn floats_print_like_the_original() {
        assert_eq!(float_repr(1.0), "1.0");
        assert_eq!(float_repr(100.0), "100.0");
        assert_eq!(float_repr(2.5), "2.5");
        assert_eq!(float_repr(0.0001), "0.0001");
        assert_eq!(float_repr(0.00001), "1e-05");
        assert_eq!(float_repr(1e16), "1e+16");
        assert_eq!(float_repr(1.5e300), "1.5e+300");
        assert_eq!(float_repr(-0.25), "-0.25");
        assert_eq!(float_repr(123456789012345.6), "123456789012345.6");
    }
}
