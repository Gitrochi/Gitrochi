//! Global settings every writer must agree on, stored in the database (`settings` table) so
//! the apps, the CLI, MCP and the hooks read the same rules. Only the apps change them.

use crate::error::{Error, Result};
use crate::util::Ms;
use crate::vocab::{self, Role};
use rusqlite::{params, Connection};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub const KEYS: [&str; 4] = ["staleHours", "kinds", "autoContinue", "backupKeep"];
pub const DEFAULT_LINE: &str = "core";

/// What a kind means to the rules: its role, and for implementation kinds the stream line
/// and whether its `sync`/`applied` reports hand off to decision sessions.
#[derive(Clone, Debug, PartialEq)]
pub struct KindRule {
    pub role: Role,
    pub line: Option<String>,
    pub handoff: bool,
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub stale_hours: f64,
    pub kinds: BTreeMap<String, KindRule>,
    pub auto_continue: Value,
    pub backup_keep: u32,
}

fn rule(role: Role) -> KindRule {
    KindRule {
        role,
        line: None,
        handoff: true,
    }
}

impl Default for Settings {
    fn default() -> Self {
        let mut kinds = BTreeMap::new();
        kinds.insert("research".into(), rule(Role::Research));
        kinds.insert("decision".into(), rule(Role::Decision));
        kinds.insert(
            "implementation".into(),
            KindRule {
                role: Role::Implementation,
                line: Some(DEFAULT_LINE.into()),
                handoff: true,
            },
        );
        // A second implementation line (another machine or a local model): its cycles are
        // shown, but its reports never confirm decision sessions.
        kinds.insert(
            "llm-implementation".into(),
            KindRule {
                role: Role::Implementation,
                line: Some("llm".into()),
                handoff: false,
            },
        );
        kinds.insert("review".into(), rule(Role::Other));
        kinds.insert("document".into(), rule(Role::Document));
        kinds.insert("baseline".into(), rule(Role::Other));
        kinds.insert("other".into(), rule(Role::Other));
        Settings {
            stale_hours: 72.0,
            kinds,
            auto_continue: json!({"enabled": false, "delaySec": 30}),
            backup_keep: 14,
        }
    }
}

impl Settings {
    /// The defaults with whatever the apps stored on top (unreadable values are ignored).
    pub fn load(connection: &Connection) -> Result<Settings> {
        let mut settings = Settings::default();
        let mut statement = connection.prepare_cached("SELECT key, value FROM settings")?;
        let rows =
            statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (key, text) = row?;
            if let Ok(value) = serde_json::from_str::<Value>(&text) {
                let _ = settings.apply(&key, &value);
            }
        }
        Ok(settings)
    }

    fn apply(&mut self, key: &str, value: &Value) -> Result<()> {
        match key {
            "staleHours" => {
                let hours = value
                    .as_f64()
                    .filter(|h| *h > 0.0 && *h <= 10_000.0)
                    .ok_or_else(|| {
                        Error::invalid("staleHours must be a number of hours (0–10000)")
                    })?;
                self.stale_hours = hours;
            }
            "kinds" => self.kinds = parse_kinds(value)?,
            "autoContinue" => {
                let object = value
                    .as_object()
                    .ok_or_else(|| Error::invalid("autoContinue must be an object"))?;
                check_auto_continue(object)?;
                self.auto_continue = value.clone();
            }
            "backupKeep" => {
                let keep = value
                    .as_u64()
                    .filter(|k| (1..=365).contains(k))
                    .ok_or_else(|| Error::invalid("backupKeep must be a whole number (1–365)"))?;
                self.backup_keep = keep as u32;
            }
            other => {
                return Err(Error::invalid(format!(
                    "Unknown setting {other} (known: {})",
                    KEYS.join(", ")
                )))
            }
        }
        Ok(())
    }

    pub fn rule(&self, kind: &str) -> Option<&KindRule> {
        self.kinds.get(kind)
    }

    pub fn role(&self, kind: &str) -> Role {
        self.rule(kind).map_or(Role::Other, |r| r.role)
    }

    /// The stream line of an implementation kind (`core` unless configured).
    pub fn line(&self, kind: &str) -> Option<String> {
        let rule = self.rule(kind)?;
        (rule.role == Role::Implementation)
            .then(|| rule.line.clone().unwrap_or_else(|| DEFAULT_LINE.into()))
    }

    /// Whether this kind's `sync` and `applied` reports hand off to decision sessions.
    pub fn hands_off(&self, kind: &str) -> bool {
        self.rule(kind)
            .is_some_and(|r| r.role == Role::Implementation && r.handoff)
    }

    pub fn stale_ms(&self) -> Ms {
        (self.stale_hours * 3_600_000.0) as Ms
    }

    pub fn to_json(&self) -> Value {
        let kinds: Map<String, Value> = self
            .kinds
            .iter()
            .map(|(kind, rule)| {
                let mut entry = json!({"role": rule.role.as_str()});
                if rule.role == Role::Implementation {
                    entry["line"] = json!(rule.line.clone().unwrap_or_else(|| DEFAULT_LINE.into()));
                    entry["handoff"] = json!(rule.handoff);
                }
                (kind.clone(), entry)
            })
            .collect();
        json!({
            "staleHours": self.stale_hours,
            "kinds": kinds,
            "autoContinue": self.auto_continue,
            "backupKeep": self.backup_keep,
        })
    }
}

fn check_auto_continue(object: &Map<String, Value>) -> Result<()> {
    if let Some(enabled) = object.get("enabled") {
        if !enabled.is_boolean() {
            return Err(Error::invalid("autoContinue.enabled must be true or false"));
        }
    }
    if let Some(delay) = object.get("delaySec") {
        if !delay.as_u64().is_some_and(|d| (1..=3600).contains(&d)) {
            return Err(Error::invalid(
                "autoContinue.delaySec must be a whole number of seconds (1–3600)",
            ));
        }
    }
    Ok(())
}

/// A per-session auto-continue policy: `{enabled, delaySec}`, both required.
pub fn session_auto_continue(value: &Value) -> Result<Value> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::invalid("autoContinue must be an object"))?;
    check_auto_continue(object)?;
    let enabled = object.get("enabled").and_then(Value::as_bool);
    let delay = object.get("delaySec").and_then(Value::as_u64);
    match (enabled, delay) {
        (Some(enabled), Some(delay)) => Ok(json!({"enabled": enabled, "delaySec": delay})),
        _ => Err(Error::invalid("autoContinue needs enabled and delaySec")),
    }
}

fn parse_kinds(value: &Value) -> Result<BTreeMap<String, KindRule>> {
    let object = value.as_object().ok_or_else(|| {
        Error::invalid("kinds must be an object of kind → {role, line?, handoff?}")
    })?;
    let mut kinds = BTreeMap::new();
    for (name, entry) in object {
        let kind = vocab::kind(name.trim());
        if kind.is_empty() {
            return Err(Error::invalid("A kind needs a name"));
        }
        let role = entry["role"]
            .as_str()
            .and_then(Role::parse)
            .ok_or_else(|| {
                Error::invalid(format!(
                    "kinds.{name}.role must be decision, implementation, research, document or other"
                ))
            })?;
        let line = match &entry["line"] {
            Value::Null => None,
            Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
            _ => return Err(Error::invalid(format!("kinds.{name}.line must be a name"))),
        };
        let handoff = match &entry["handoff"] {
            Value::Null => true,
            Value::Bool(b) => *b,
            _ => {
                return Err(Error::invalid(format!(
                    "kinds.{name}.handoff must be true or false"
                )))
            }
        };
        kinds.insert(
            kind,
            KindRule {
                role,
                line,
                handoff,
            },
        );
    }
    Ok(kinds)
}

/// Stores validated settings (`{key: value}`); `null` restores a key's default.
pub fn store(connection: &Connection, values: &Map<String, Value>, now: Ms) -> Result<()> {
    let mut check = Settings::default();
    for (key, value) in values {
        if value.is_null() {
            if !KEYS.contains(&key.as_str()) {
                return Err(Error::invalid(format!("Unknown setting {key}")));
            }
            connection.execute("DELETE FROM settings WHERE key = ?1", [key])?;
            continue;
        }
        check.apply(key, value)?;
        let stored = match key.as_str() {
            // Kind names are stored in their canonical spelling.
            "kinds" => {
                let normalized: Map<String, Value> = value
                    .as_object()
                    .into_iter()
                    .flatten()
                    .map(|(k, v)| (vocab::kind(k.trim()), v.clone()))
                    .collect();
                Value::Object(normalized)
            }
            _ => value.clone(),
        };
        connection.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            params![key, stored.to_string(), now],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_roles_and_lines() {
        let s = Settings::default();
        assert_eq!(s.role("decision"), Role::Decision);
        assert_eq!(s.role("spike"), Role::Other);
        assert_eq!(s.line("implementation").as_deref(), Some("core"));
        assert_eq!(s.line("llm-implementation").as_deref(), Some("llm"));
        assert_eq!(s.line("research"), None);
        assert!(s.hands_off("implementation"));
        assert!(!s.hands_off("llm-implementation"));
        assert!(!s.hands_off("decision"));
        assert_eq!(s.stale_ms(), 72 * 3_600_000);
    }

    #[test]
    fn invalid_values_are_rejected() {
        let mut s = Settings::default();
        assert!(s.apply("staleHours", &json!(-1)).is_err());
        assert!(s.apply("staleHours", &json!("x")).is_err());
        assert!(s.apply("kinds", &json!({"x": {"role": "boss"}})).is_err());
        assert!(s
            .apply("kinds", &json!({"x": {"role": "other", "handoff": 3}}))
            .is_err());
        assert!(s.apply("autoContinue", &json!({"delaySec": 0})).is_err());
        assert!(s.apply("backupKeep", &json!(0)).is_err());
        assert!(s.apply("colour", &json!(1)).is_err());
        s.apply(
            "kinds",
            &json!({"구현": {"role": "implementation", "line": "main"}}),
        )
        .unwrap();
        assert_eq!(s.line("implementation").as_deref(), Some("main"));
        assert_eq!(s.role("decision"), Role::Other);
    }
}
