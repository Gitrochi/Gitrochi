//! Dated work records and reports, independent of a conversation's lifecycle.

mod legacy;
mod read;
mod write;

pub use legacy::import_legacy;

use crate::db::Db;
use crate::error::{Error, Result};
use crate::util::{arg_bool, arg_str, arg_str_any, clean, list_of, nfc_text};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

const MAX_TEXT: usize = 60_000;

/// Links a session report to work items inside the report's existing transaction.
pub fn assign_session_event(
    c: &Connection,
    project: &str,
    event_id: i64,
    item_ids: &[String],
    now: i64,
) -> Result<()> {
    for id in item_ids {
        load_item(c, project, id)?;
    }
    for id in item_ids {
        c.execute("INSERT OR IGNORE INTO ledger_work_links(project,item,event_id,created_at) VALUES (?1,?2,?3,?4)",params![project,id,event_id,now])?;
    }
    Ok(())
}

/// Executes a work operation. Human work notes are kept behind the app boundary.
pub fn call(db: &Db, args: &Value, now: i64, human: bool) -> Result<Value> {
    if !args.is_object() {
        return Err(Error::invalid("Work arguments must be an object"));
    }
    let action = arg_str(args, "action").unwrap_or_else(|| "list".into());
    if action == "import" {
        return import_lines(db, args, now, human);
    }
    let read_only = matches!(action.as_str(), "list" | "detail" | "report" | "unassigned");
    if read_only && (human || !arg_bool(args, "deliver").unwrap_or(false)) {
        return db.read(|c| read::call(c, args, &action, now));
    }
    let (mut value, rev) = db.write(|c| {
        let mut value = if read_only {
            read::call(c, args, &action, now)?
        } else {
            write::call(c, args, &action, now, human)?
        };
        if action != "note" && !human {
            let project = project(c, args)?;
            value["messages"] = deliver(c, &project, now)?;
        }
        Ok(value)
    })?;
    value["rev"] = json!(rev);
    Ok(value)
}

fn project(c: &Connection, args: &Value) -> Result<String> {
    if let Some(project) = arg_str(args, "project") {
        return Ok(project);
    }
    c.query_row(
        "SELECT project FROM ledger_work_items ORDER BY created_at DESC, id LIMIT 1",
        [],
        |r| r.get(0),
    )
    .optional()?
    .or(c
        .query_row(
            "SELECT key FROM projects ORDER BY created_at DESC, key LIMIT 1",
            [],
            |r| r.get(0),
        )
        .optional()?)
    .ok_or_else(|| Error::invalid("A project is required"))
}

fn required(args: &Value, names: &[&str]) -> Result<String> {
    arg_str_any(args, names).ok_or_else(|| Error::invalid(format!("{} is required", names[0])))
}

fn limited(text: String, field: &str, max: usize) -> Result<String> {
    if text.chars().count() > max {
        Err(Error::invalid(format!(
            "{field} must be at most {max} characters"
        )))
    } else {
        Ok(text)
    }
}

fn text(args: &Value) -> Result<String> {
    limited(
        arg_str_any(args, &["text", "txt"]).unwrap_or_default(),
        "text",
        MAX_TEXT,
    )
}

fn refs(args: &Value) -> Vec<String> {
    list_of(
        args.get("refs")
            .or_else(|| args.get("ref"))
            .unwrap_or(&Value::Null),
    )
}

fn item_id(args: &Value) -> Result<String> {
    required(args, &["item", "w", "id"])
}

fn bundle(args: &Value) -> Result<String> {
    limited(required(args, &["bundle", "b"])?, "bundle", 300)
}

fn kind(args: &Value) -> Result<String> {
    let kind = required(args, &["event", "ev"])?;
    Ok(match kind.as_str() {
        "등록" | "register" => "registered",
        "착수" | "start" => "started",
        "경과" => "progress",
        "완료" | "complete" => "completed",
        "동결" | "freeze" => "frozen",
        "보류" | "hold" => "held",
        "재개" | "resume" => "resumed",
        "취소" | "cancel" => "cancelled",
        "계획" => "plan",
        "이슈" => "issue",
        "이관" => "transfer",
        "묶음완료" | "complete_bundle" => "bundle_completed",
        "배정안함" | "skip" => "skipped",
        "이월" => "carry",
        "줄기" | "g" => "stem",
        "t_fix" | "edit_item" => "item_fix",
        "옮김" => "move",
        "txt_fix" => "text_fix",
        other => other,
    }
    .to_string())
}

fn date_value(raw: &str, estimated: bool) -> Result<(String, bool)> {
    let (raw, estimate) = match raw.strip_prefix('~') {
        Some(rest) if estimated => (rest, true),
        Some(_) => return Err(Error::invalid("This operation requires an actual date")),
        None => (raw, false),
    };
    let valid = raw.len() == 10 && raw.as_bytes()[4] == b'-' && raw.as_bytes()[7] == b'-';
    if !valid || day_number(raw).is_none() {
        return Err(Error::invalid(
            "date must be a calendar date in YYYY-MM-DD format",
        ));
    }
    Ok((raw.to_string(), estimate))
}

fn date(args: &Value, estimated: bool) -> Result<(String, bool)> {
    date_value(&required(args, &["date", "d"])?, estimated)
}

fn day_number(raw: &str) -> Option<i64> {
    if raw.len() != 10
        || raw.as_bytes().get(4) != Some(&b'-')
        || raw.as_bytes().get(7) != Some(&b'-')
    {
        return None;
    }
    let y: i64 = raw.get(..4)?.parse().ok()?;
    let m: usize = raw.get(5..7)?.parse().ok()?;
    let d: i64 = raw.get(8..)?.parse().ok()?;
    if y < 1 || !(1..=12).contains(&m) {
        return None;
    }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let months = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if d < 1 || d > months[m - 1] {
        return None;
    }
    let last = y - 1;
    Some(last * 365 + last / 4 - last / 100 + last / 400 + months[..m - 1].iter().sum::<i64>() + d)
}

fn json_column(value: String) -> rusqlite::Result<Value> {
    serde_json::from_str(&value).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })
}

fn load_item(c: &Connection, project: &str, id: &str) -> Result<Value> {
    c.query_row(
        "SELECT id,project,bundle,title,output,scope,stem,from_item,created_date,created_at FROM ledger_work_items WHERE id=?1 AND project=?2",
        params![id, project], |r| Ok(json!({
            "id":r.get::<_,String>(0)?,"project":r.get::<_,String>(1)?,"bundle":r.get::<_,String>(2)?,
            "title":r.get::<_,String>(3)?,"output":r.get::<_,String>(4)?,"scope":json_column(r.get(5)?)?,
            "stem":r.get::<_,String>(6)?,"from":r.get::<_,Option<String>>(7)?,
            "createdDate":r.get::<_,String>(8)?,"createdAt":r.get::<_,i64>(9)?
        })),
    ).optional()?.ok_or_else(|| Error::not_found(format!("Work item {id} was not found in {project}")))
}

fn events(c: &Connection, project: &str, item: Option<&str>) -> Result<Vec<Value>> {
    let mut q = c.prepare("SELECT id,project,item,bundle,kind,date,estimated,text,refs,plan,data,created_at FROM ledger_work_events WHERE project=?1 AND (?2 IS NULL OR item=?2) ORDER BY date,id")?;
    let rows = q.query_map(params![project, item], |r| Ok(json!({
        "id":r.get::<_,i64>(0)?,"project":r.get::<_,String>(1)?,"item":r.get::<_,Option<String>>(2)?,
        "bundle":r.get::<_,Option<String>>(3)?,"event":r.get::<_,String>(4)?,"date":r.get::<_,String>(5)?,
        "estimated":r.get::<_,bool>(6)?,"text":r.get::<_,String>(7)?,"refs":json_column(r.get(8)?)?,
        "plan":r.get::<_,Option<String>>(9)?.map(json_column).transpose()?,"data":json_column(r.get(10)?)?,
        "createdAt":r.get::<_,i64>(11)?
    })))?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

fn insert_event(c: &Connection, value: &Value, now: i64) -> Result<i64> {
    c.execute("INSERT INTO ledger_work_events(project,item,bundle,kind,date,estimated,text,refs,plan,data,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        params![value["project"].as_str(),value["item"].as_str(),value["bundle"].as_str(),value["event"].as_str(),
        value["date"].as_str(),value["estimated"].as_bool().unwrap_or(false),value["text"].as_str().unwrap_or(""),
        value.get("refs").unwrap_or(&json!([])).to_string(),value.get("plan").filter(|v| !v.is_null()).map(Value::to_string),
        value.get("data").unwrap_or(&json!({})).to_string(),now])?;
    Ok(c.last_insert_rowid())
}

fn deliver(c: &Connection, project: &str, now: i64) -> Result<Value> {
    let mut q = c.prepare("SELECT id,target,text,created_at FROM ledger_work_notes WHERE project=?1 AND delivered_at IS NULL ORDER BY id")?;
    let notes = q.query_map([project], |r| Ok(json!({"id":r.get::<_,i64>(0)?,"target":r.get::<_,String>(1)?,"text":r.get::<_,String>(2)?,"createdAt":r.get::<_,i64>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    c.execute(
        "UPDATE ledger_work_notes SET delivered_at=?2 WHERE project=?1 AND delivered_at IS NULL",
        params![project, now],
    )?;
    Ok(json!(notes))
}

fn import_lines(db: &Db, args: &Value, now: i64, human: bool) -> Result<Value> {
    let source = required(args, &["text"])?;
    if source.len() > 2_000_000 {
        return Err(Error::invalid("The work import is too large"));
    }
    let mut in_block = false;
    let fenced = source
        .lines()
        .any(|line| line.trim().eq_ignore_ascii_case("```work"));
    let mut results = Vec::new();
    for (i, line) in source.lines().enumerate() {
        let line = line.trim();
        if line.eq_ignore_ascii_case("```work") {
            in_block = true;
            continue;
        }
        if in_block && line.starts_with("```") {
            in_block = false;
            continue;
        }
        if line.is_empty() || (fenced && !in_block) {
            continue;
        }
        let parsed = serde_json::from_str::<Value>(line)
            .map_err(|_| Error::invalid("Each work line must be a JSON object"));
        let result = parsed.and_then(|mut value| {
            if !value.is_object() {
                return Err(Error::invalid("Each work line must be a JSON object"));
            }
            let project = arg_str(&value, "project")
                .or_else(|| arg_str(args, "project"))
                .map(Ok)
                .unwrap_or_else(|| if arg_bool(args, "requireProject").unwrap_or(false) {
                    Err(Error::invalid("Each work record needs a project when the paste has no single session project"))
                } else { db.read(|c| project(c, args)) })?;
            let hash = format!(
                "work:{}",
                crate::sha1::hex(
                    format!("{project}\n{}", crate::import::canonical(&value)).as_bytes()
                )
            );
            value["project"] = json!(project);
            let duplicate = db.read(|c| imported(c, &hash))?;
            if duplicate {
                return Ok(json!({"status":"duplicate"}));
            }
            db.write(|c| {
                let duplicate = imported(c, &hash)?;
                if duplicate {
                    return Ok(json!({"status":"duplicate"}));
                }
                let action = if matches!(kind(&value)?.as_str(), "registered") {
                    "add_item"
                } else {
                    "event"
                };
                let response = write::call(c, &value, action, now + i as i64, human)?;
                c.execute(
                    "INSERT INTO ledger_work_imports(hash,created_at) VALUES (?1,?2)",
                    params![hash, now],
                )?;
                Ok(json!({"status":"ok","result":response}))
            })
            .map(|(v, _)| v)
        });
        let mut row = match result {
            Ok(v) => v,
            Err(e) => json!({"status":"error","error":e.to_json()}),
        };
        row["line"] = json!(i + 1);
        results.push(row);
    }
    Ok(json!({"results":results}))
}

fn imported(c: &Connection, hash: &str) -> Result<bool> {
    Ok(c.query_row("SELECT EXISTS(SELECT 1 FROM ledger_work_imports WHERE hash=?1 UNION ALL SELECT 1 FROM imports WHERE hash=?1)",[hash],|r|r.get(0))?)
}
