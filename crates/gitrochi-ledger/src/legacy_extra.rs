//! Keeps the optional legacy records in the same snapshot and transaction as session history.

use crate::error::Result;
use crate::sha1;
use rusqlite::{params, types::ValueRef, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

pub type Tables = BTreeMap<String, Vec<Value>>;
const TABLES: [&str; 14] = [
    "work_bundles",
    "work_bundle_events",
    "work_items",
    "work_events",
    "work_date_fixes",
    "work_notes",
    "work_marks",
    "work_text_fixes",
    "work_carries",
    "work_stems",
    "work_item_fixes",
    "work_moves",
    "work_splits",
    "notes",
];

pub fn read(c: &Connection, available: &HashSet<String>) -> Result<Tables> {
    let mut tables = Tables::new();
    for table in TABLES.into_iter().filter(|t| available.contains(*t)) {
        let mut statement = c.prepare(&format!("SELECT * FROM \"{table}\""))?;
        let columns: Vec<String> = statement
            .column_names()
            .iter()
            .map(|s| s.to_string())
            .collect();
        let rows = statement.query_map([], |row| {
            let mut value = Map::new();
            for (index, name) in columns.iter().enumerate() {
                let field = match row.get_ref(index)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(bytes) => json!(String::from_utf8_lossy(bytes)),
                    ValueRef::Blob(bytes) => json!({"hex": bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()}),
                };
                value.insert(name.clone(), field);
            }
            Ok(Value::Object(value))
        })?.collect::<rusqlite::Result<Vec<_>>>()?;
        tables.insert(table.to_string(), rows);
    }
    Ok(tables)
}

pub fn preserve(c: &Connection, source: &str, tables: &Tables, write: bool) -> Result<usize> {
    let mut count = 0;
    for (table, rows) in tables {
        for row in rows {
            let body = row.to_string();
            let key = sha1::hex(body.as_bytes());
            let have: bool = c.query_row(
                "SELECT EXISTS(SELECT 1 FROM ledger_legacy_rows WHERE source=?1 AND table_name=?2 AND row_key=?3)",
                params![source, table, key], |r| r.get(0),
            )?;
            if !have {
                count += 1;
                if write {
                    c.execute(
                        "INSERT INTO ledger_legacy_rows VALUES (?1,?2,?3,?4)",
                        params![source, table, key, body],
                    )?;
                }
            }
        }
    }
    Ok(count)
}

pub fn event_ids(c: &Connection, source: &str) -> Result<HashMap<i64, i64>> {
    Ok(
        c.prepare("SELECT legacy_id,event_id FROM ledger_legacy_event_ids WHERE source=?1")?
            .query_map([source], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?,
    )
}

pub fn notes(c: &Connection, source: &str, tables: &Tables, write: bool) -> Result<usize> {
    let mut count = 0;
    for row in tables.get("notes").into_iter().flatten() {
        let id = row["id"].to_string();
        let have = c
            .query_row(
                "SELECT note_id FROM ledger_legacy_notes WHERE source=?1 AND legacy_id=?2",
                params![source, id],
                |r| r.get::<_, i64>(0),
            )
            .optional()?;
        if have.is_some() {
            continue;
        }
        count += 1;
        if write {
            let created = row["created_ts"].as_i64().unwrap_or(1).max(1);
            let updated = row["updated_ts"].as_i64().unwrap_or(created).max(created);
            c.execute("INSERT INTO notebook_notes(title,body,pinned,created_at,updated_at) VALUES (?1,?2,?3,?4,?5)",
                params![row["title"].as_str().unwrap_or(""),row["body"].as_str().unwrap_or(""),row["pinned"].as_i64().unwrap_or(0),created,updated])?;
            c.execute(
                "INSERT INTO ledger_legacy_notes VALUES (?1,?2,?3)",
                params![source, id, c.last_insert_rowid()],
            )?;
        }
    }
    Ok(count)
}
