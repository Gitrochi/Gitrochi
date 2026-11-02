//! A person's private notebook. Nothing here is included in agent reports or searches.

use crate::db::Db;
use crate::error::{Error, Result};
use crate::util::nfc_text;
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;
use serde_json::{json, Value};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Note {
    id: i64,
    title: String,
    body: String,
    pinned: bool,
    created_at: i64,
    updated_at: i64,
}

const COLUMNS: &str = "id,title,body,pinned,created_at,updated_at";

fn row(row: &Row<'_>) -> rusqlite::Result<Note> {
    Ok(Note {
        id: row.get(0)?,
        title: row.get(1)?,
        body: row.get(2)?,
        pinned: row.get::<_, i64>(3)? != 0,
        created_at: row.get(4)?,
        updated_at: row.get(5)?,
    })
}

fn get(c: &Connection, id: i64) -> Result<Note> {
    c.query_row(
        &format!("SELECT {COLUMNS} FROM notebook_notes WHERE id=?"),
        [id],
        row,
    )
    .optional()?
    .ok_or_else(|| Error::not_found("This note no longer exists"))
}

fn positive(args: &Value, key: &str) -> Result<i64> {
    args[key]
        .as_i64()
        .filter(|n| *n > 0)
        .ok_or_else(|| Error::invalid(format!("{key} must be a positive integer")))
}

fn checked_text(args: &Value, key: &str, max: usize, allow_empty: bool) -> Result<String> {
    let value = args[key]
        .as_str()
        .ok_or_else(|| Error::invalid(format!("Missing {key}")))?;
    let value = nfc_text(value).replace("\r\n", "\n");
    let value = if key == "title" {
        value.trim().to_string()
    } else {
        value
    };
    if (!allow_empty && value.is_empty()) || value.chars().count() > max {
        return Err(Error::invalid(format!(
            "{key} must contain {} to {max} characters",
            usize::from(!allow_empty)
        )));
    }
    Ok(value)
}

fn unchanged(args: &Value, note: &Note) -> Result<()> {
    let expected = args["expectedUpdatedAt"]
        .as_i64()
        .filter(|n| *n >= 0)
        .ok_or_else(|| Error::invalid("expectedUpdatedAt must be a nonnegative integer"))?;
    if expected != note.updated_at {
        return Err(Error::conflict(
            "This note changed in another window. Reload it before saving or deleting.",
        ));
    }
    Ok(())
}

/// Lists, reads, saves or deletes personal notes; the dispatcher permits only app callers.
pub fn call(db: &Db, args: &Value, now: i64) -> Result<Value> {
    match args["action"].as_str().unwrap_or("list") {
        "list" => {
            let query = match args.get("query") {
                Some(Value::String(query)) if query.chars().count() <= 500 => {
                    nfc_text(query.trim()).to_lowercase()
                }
                None => String::new(),
                _ => {
                    return Err(Error::invalid(
                        "query must be text of at most 500 characters",
                    ))
                }
            };
            db.read(|c| {
                let notes = c
                    .prepare(&format!("SELECT {COLUMNS} FROM notebook_notes ORDER BY pinned DESC,updated_at DESC,id DESC"))?
                    .query_map([], row)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
                    .into_iter()
                    .filter(|n| query.is_empty() || n.title.to_lowercase().contains(&query) || n.body.to_lowercase().contains(&query))
                    .collect::<Vec<_>>();
                Ok(json!({"notes":notes}))
            })
        }
        "get" => {
            let id = positive(args, "id")?;
            db.read(|c| Ok(json!({"note":get(c,id)?})))
        }
        "save" => {
            let title = checked_text(args, "title", 500, false)?;
            let body = checked_text(args, "body", 200_000, true)?;
            let pinned = match args.get("pinned") {
                Some(Value::Bool(pinned)) => *pinned,
                None => false,
                _ => return Err(Error::invalid("pinned must be a boolean")),
            };
            let id = if args.get("id").is_some_and(|id| !id.is_null()) {
                Some(positive(args, "id")?)
            } else {
                None
            };
            let (note, _) = db.write(|c| {
                let id = if let Some(id) = id {
                    let previous = get(c,id)?;
                    unchanged(args,&previous)?;
                    let updated = now.max(previous.updated_at.saturating_add(1));
                    c.execute("UPDATE notebook_notes SET title=?,body=?,pinned=?,updated_at=? WHERE id=?",params![title,body,pinned,updated,id])?;
                    id
                } else {
                    c.execute("INSERT INTO notebook_notes (title,body,pinned,created_at,updated_at) VALUES (?,?,?,?,?)",params![title,body,pinned,now,now])?;
                    c.last_insert_rowid()
                };
                get(c,id)
            })?;
            Ok(json!({"note":note}))
        }
        "delete" => {
            let id = positive(args, "id")?;
            db.write(|c| {
                let previous = get(c, id)?;
                unchanged(args, &previous)?;
                c.execute("DELETE FROM notebook_notes WHERE id=?", [id])?;
                Ok(())
            })?;
            Ok(json!({"ok":true}))
        }
        _ => Err(Error::invalid("Unknown notebook action")),
    }
}
