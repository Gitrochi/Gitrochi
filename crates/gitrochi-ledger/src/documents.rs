//! Read-only evidence from document folders a person explicitly selected.
mod files;
mod parse;
mod summaries;

use crate::db::Db;
use crate::error::{Error, Result};
use crate::util::{arg_str, Ms};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::Path;

fn project(db: &Db, args: &Value, action: &str) -> Result<String> {
    if let Some(project) = arg_str(args, "project") {
        return Ok(project);
    }
    if matches!(action, "set_roots" | "hold" | "summary_save") {
        return Err(Error::invalid("Choose a project for document tracking"));
    }
    db.read(|c| {
        c.query_row(
            "SELECT r.project FROM document_roots r LEFT JOIN sessions s ON s.project=r.project
        GROUP BY r.project ORDER BY coalesce(max(s.last_at),0) DESC,r.project LIMIT 1",
            [],
            |r| r.get(0),
        )
        .optional()?
        .ok_or_else(|| Error::invalid("Choose a project for document tracking"))
    })
}

fn roots(c: &Connection, project: &str) -> Result<Vec<String>> {
    Ok(
        c.prepare("SELECT path FROM document_roots WHERE project=?1 ORDER BY path")?
            .query_map([project], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?,
    )
}

fn snapshot(c: &Connection, project: &str, args: &Value) -> Result<Value> {
    let query = arg_str(args, "query").unwrap_or_default().to_lowercase();
    let wanted = arg_str(args, "id");
    let action = arg_str(args, "action").unwrap_or_else(|| "list".into());
    let mut file_rows = Vec::new();
    let mut entries = Vec::new();
    let mut ids = BTreeSet::new();
    let mut rows = c.prepare("SELECT root,path,hash,held_hash,modified_at,scanned_at,entries FROM document_files WHERE project=?1 ORDER BY root,path")?;
    for row in rows.query_map([project], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, Option<String>>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, String>(6)?,
        ))
    })? {
        let (root, path, hash, held, modified, scanned, raw) = row?;
        let changed = held.as_ref().is_some_and(|h| h != &hash);
        file_rows.push(json!({"root":root,"path":path,"hash":hash,"heldHash":held,"changed":changed,"modifiedAt":modified,"scannedAt":scanned}));
        let parsed: Vec<Value> = serde_json::from_str(&raw)?;
        for mut entry in parsed {
            if let Some(id) = entry["id"].as_str() {
                ids.insert(id.to_owned());
            }
            if wanted.as_ref().is_some_and(|id| {
                !entry["id"]
                    .as_str()
                    .is_some_and(|candidate| candidate.eq_ignore_ascii_case(id))
            }) {
                continue;
            }
            if !query.is_empty() && !entry.to_string().to_lowercase().contains(&query) {
                continue;
            }
            if action == "worklist" && (entry["task"] != true || entry["status"] == "done") {
                continue;
            }
            if action == "backflow" && (entry["kind"] != "backflow" || entry["status"] == "done") {
                continue;
            }
            entry["root"] = json!(root);
            entry["path"] = json!(path);
            entry["hash"] = json!(hash);
            entry["changed"] = json!(changed);
            entries.push(entry);
        }
    }
    let mut related = Vec::new();
    if let Some(id) = &wanted {
        let mut sessions = c.prepare(
            "SELECT id,title,touches FROM sessions WHERE project=?1 ORDER BY last_at DESC",
        )?;
        for row in sessions.query_map([project], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })? {
            let (session, title, touches) = row?;
            let touches: Vec<String> = serde_json::from_str(&touches).unwrap_or_default();
            if touches.iter().any(|touch| touch.eq_ignore_ascii_case(id)) {
                related.push(json!({"id":session,"title":title}));
            }
        }
    }
    let total = entries.len();
    entries.truncate(2000);
    let summary = wanted
        .as_ref()
        .and_then(|_| {
            entries
                .iter()
                .find(|e| e["definition"] == true)
                .or_else(|| entries.first())
        })
        .map(|e| json!({"text":e["text"],"path":e["path"],"line":e["line"],"source":"excerpt"}));
    Ok(
        json!({"project":project,"roots":roots(c,project)?,"files":file_rows,"ids":ids,"entries":entries,
        "total":total,"truncated":total>2000,"relatedSessions":related,"summary":summary}),
    )
}

/// Dispatches document tracking; folder changes and held checksums are person-only.
pub fn call(db: &Db, args: &Value, now: Ms, human: bool) -> Result<Value> {
    let action = arg_str(args, "action").unwrap_or_else(|| "list".into());
    let project = project(db, args, &action)?;
    match action.as_str() {
        "summary_get" => db.read(|c| summaries::get(c, &project, args, now)),
        "usage" => db.read(|c| Ok(json!({"usage":summaries::usage(c,&project,now)?}))),
        "summary_save" => {
            if !human {
                return Err(Error::not_allowed("Only a person can save an AI summary"));
            }
            let (mut value, rev) = db.write(|c| summaries::save(c, &project, args, now))?;
            value["rev"] = json!(rev);
            Ok(value)
        }
        "roots" => db.read(|c| Ok(json!({"project":project,"roots":roots(c,&project)?}))),
        "set_roots" => {
            if !human {
                return Err(Error::not_allowed(
                    "Only a person can choose document folders",
                ));
            }
            let input = args["roots"]
                .as_array()
                .ok_or_else(|| Error::invalid("roots must be a list of folders"))?;
            if input.len() > 16 {
                return Err(Error::invalid("Choose at most 16 document folders"));
            }
            let mut paths = BTreeSet::new();
            for item in input {
                let raw = item
                    .as_str()
                    .filter(|path| !path.is_empty())
                    .ok_or_else(|| Error::invalid("Each document folder must be a path"))?;
                let path = Path::new(&raw);
                if !path.is_absolute() || !path.is_dir() {
                    return Err(Error::invalid(
                        "Choose an existing absolute document folder",
                    ));
                }
                let canonical = std::fs::canonicalize(path)
                    .map_err(|_| Error::invalid("Could not read document folder"))?;
                let path = canonical
                    .to_str()
                    .ok_or_else(|| Error::invalid("Document folder paths must be valid Unicode"))?;
                paths.insert(path.to_owned());
            }
            let ((),rev) = db.write(|c| {
                c.execute("DELETE FROM document_roots WHERE project=?1",[&project])?;
                for path in &paths { c.execute("INSERT INTO document_roots(project,path) VALUES (?1,?2)",params![project,path])?; }
                c.execute("DELETE FROM document_files WHERE project=?1 AND root NOT IN (SELECT path FROM document_roots WHERE project=?1)",[&project])?;
                Ok(())
            })?;
            Ok(json!({"ok":true,"rev":rev,"roots":paths}))
        }
        "scan" => {
            if args.get("path").is_some() || args.get("roots").is_some() {
                return Err(Error::invalid(
                    "Scan uses the document folders already selected in Gitrochi",
                ));
            }
            let approved = db.read(|c| roots(c, &project))?;
            let (files, warnings) = files::scan(&approved)?;
            let (changed,rev) = db.write(|c| {
                if roots(c,&project)? != approved { return Err(Error::conflict("Document folders changed during the scan; scan again")); }
                let mut changed = 0;
                // A missing file or unreadable root must not keep presenting old evidence as current.
                let mut keep = BTreeSet::new();
                for file in &files {
                    keep.insert((&file.root,&file.path));
                    let updated = c.execute("INSERT INTO document_files(project,root,path,hash,modified_at,scanned_at,entries) VALUES (?1,?2,?3,?4,?5,?6,?7)
                        ON CONFLICT(project,root,path) DO UPDATE SET hash=excluded.hash,modified_at=excluded.modified_at,scanned_at=excluded.scanned_at,entries=excluded.entries",
                        params![project,file.root,file.path,file.hash,file.modified,now,serde_json::to_string(&file.entries)?])?;
                    changed += updated;
                }
                let existing = c.prepare("SELECT root,path FROM document_files WHERE project=?1")?.query_map([&project], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
                for (root,path) in existing {
                    if !keep.contains(&(&root,&path)) { c.execute("DELETE FROM document_files WHERE project=?1 AND root=?2 AND path=?3",params![project,root,path])?; }
                }
                Ok(changed)
            })?;
            Ok(
                json!({"ok":true,"rev":rev,"files":files.len(),"updated":changed,"warnings":warnings}),
            )
        }
        "hold" => {
            if !human {
                return Err(Error::not_allowed(
                    "Only a person can hold a document checksum",
                ));
            }
            let root = arg_str(args, "root").ok_or_else(|| Error::invalid("Missing root"))?;
            let path = arg_str(args, "path").ok_or_else(|| Error::invalid("Missing path"))?;
            let ((),rev) = db.write(|c| {
                let count = c.execute("UPDATE document_files SET held_hash=hash WHERE project=?1 AND root=?2 AND path=?3",params![project,root,path])?;
                if count==0 { return Err(Error::not_found("Document is not in the selected folders")); }
                Ok(())
            })?;
            Ok(json!({"ok":true,"rev":rev}))
        }
        "list" | "lookup" | "search" | "worklist" | "backflow" => {
            if action == "lookup" && arg_str(args, "id").is_none() {
                return Err(Error::invalid("Missing document ID"));
            }
            db.read(|c| snapshot(c, &project, args))
        }
        _ => Err(Error::invalid(format!("Unknown document action: {action}"))),
    }
}
