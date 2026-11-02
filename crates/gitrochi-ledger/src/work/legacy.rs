use super::*;
use std::collections::{BTreeMap, HashMap};

type Tables = BTreeMap<String, Vec<Value>>;

fn rows<'a>(tables: &'a Tables, table: &str) -> &'a [Value] {
    tables.get(table).map(Vec::as_slice).unwrap_or_default()
}

fn string(value: &Value, key: &str) -> String {
    value[key].as_str().map(nfc_text).unwrap_or_default()
}

fn encoded(value: &Value, key: &str, default: Value) -> Value {
    match &value[key] {
        Value::Null => default,
        Value::String(s) => serde_json::from_str(s).unwrap_or(default),
        value => value.clone(),
    }
}

fn stamp(value: &Value, key: &str) -> i64 {
    value[key].as_i64().unwrap_or(0)
}

fn key(c: &Connection, source: &str, kind: &str, original: &str) -> Result<Option<String>> {
    Ok(c.query_row(
        "SELECT target FROM ledger_work_legacy_keys WHERE source=?1 AND kind=?2 AND original=?3",
        params![source, kind, original],
        |r| r.get(0),
    )
    .optional()?)
}

fn remember(c: &Connection, source: &str, kind: &str, original: &str, target: &str) -> Result<()> {
    c.execute(
        "INSERT INTO ledger_work_legacy_keys(source,kind,original,target) VALUES (?1,?2,?3,?4)",
        params![source, kind, original, target],
    )?;
    Ok(())
}

fn remap_refs(value: &Value, key: &str, events: &HashMap<i64, i64>, source: &str) -> Value {
    let refs = encoded(value, key, json!([]));
    json!(refs
        .as_array()
        .into_iter()
        .flatten()
        .map(|reference| {
            if let Some(id) = reference
                .as_str()
                .and_then(|s| s.trim_start_matches('#').strip_prefix('E'))
                .and_then(|s| s.parse::<i64>().ok())
            {
                if let Some(mapped) = events.get(&id) {
                    return json!(format!("E{mapped}"));
                }
                return json!(format!("legacy:{source}:E{id}"));
            }
            reference.clone()
        })
        .collect::<Vec<_>>())
}

/// Imports legacy work tables into the active model without replacing existing work IDs.
/// The outer legacy importer owns the read snapshot and destination transaction.
pub fn import_legacy(
    c: &Connection,
    tables: &Tables,
    event_ids: &HashMap<i64, i64>,
    source: &str,
    write: bool,
) -> Result<Value> {
    let mut count = 0;
    for item in rows(tables, "work_items") {
        if key(c, source, "item", &string(item, "id"))?.is_none() {
            count += 1;
        }
    }
    let mut event_count = 0;
    for (table, kind) in [
        ("work_events", "event"),
        ("work_bundle_events", "bundle_event"),
    ] {
        for event in rows(tables, table) {
            if key(c, source, kind, &stamp(event, "id").to_string())?.is_none() {
                event_count += 1;
            }
        }
    }
    if !write {
        return Ok(json!({"items":count,"events":event_count}));
    }
    let mut item_ids = HashMap::new();
    for item in rows(tables, "work_items") {
        let original = string(item, "id");
        let id = if let Some(id) = key(c, source, "item", &original)? {
            id
        } else {
            let exists: bool = c.query_row(
                "SELECT EXISTS(SELECT 1 FROM ledger_work_items WHERE id=?1)",
                [&original],
                |r| r.get(0),
            )?;
            let id = if exists {
                format!(
                    "W-import{}-{:02}",
                    &crate::sha1::hex(format!("{source}:{original}").as_bytes())[..12],
                    item_ids.len() + 1
                )
            } else {
                original.clone()
            };
            let project = string(item, "project");
            let bundle = string(item, "bundle");
            let date = string(item, "created_date");
            crate::baseline::ensure_project(c, &project, stamp(item, "created_ts"))?;
            super::write::add_bundle(c, &project, &bundle, &date, stamp(item, "created_ts"))?;
            c.execute("INSERT INTO ledger_work_items(id,project,bundle,title,output,scope,created_date,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",params![id,project,bundle,string(item,"title"),string(item,"output"),encoded(item,"scope",json!([])).to_string(),date,stamp(item,"created_ts")])?;
            remember(c, source, "item", &original, &id)?;
            id
        };
        item_ids.insert(original, id);
    }
    for bundle in rows(tables, "work_bundles") {
        let project = string(bundle, "project");
        crate::baseline::ensure_project(c, &project, stamp(bundle, "created_ts"))?;
        super::write::add_bundle(
            c,
            &project,
            &string(bundle, "name"),
            &string(bundle, "created_date"),
            stamp(bundle, "created_ts"),
        )?;
    }
    let item_map = |original: &str| {
        item_ids
            .get(original)
            .cloned()
            .unwrap_or_else(|| original.to_string())
    };
    let mut imported_events = HashMap::new();
    for (table, key_kind) in [
        ("work_events", "event"),
        ("work_bundle_events", "bundle_event"),
    ] {
        for event in rows(tables, table) {
            let original = stamp(event, "id");
            let existing = key(c, source, key_kind, &original.to_string())?;
            let eid = if let Some(id) = existing {
                id.parse::<i64>()
                    .map_err(|_| Error::invalid("Invalid saved legacy work event mapping"))?
            } else {
                let project = string(event, "project");
                let item = (table == "work_events").then(|| item_map(&string(event, "item")));
                let bundle = if let Some(item) = &item {
                    load_item(c, &project, item)?["bundle"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string()
                } else {
                    string(event, "bundle")
                };
                let kind = kind(&json!({"event":string(event,"type")}))?;
                let plan = encoded(event, "plan", Value::Null);
                let plan = if plan.is_object() {
                    json!({"conservative":arg_str_any(&plan,&["conservative","보수"]),"slack":arg_str_any(&plan,&["slack","여유"])})
                } else {
                    plan
                };
                let data = if kind == "transfer" {
                    json!({"toBundle":string(event,"to_bundle")})
                } else {
                    json!({})
                };
                let eid = insert_event(
                    c,
                    &json!({"project":project,"item":item,"bundle":bundle,"event":kind,"date":string(event,"date"),"estimated":stamp(event,"date_est")==1,"text":string(event,"text"),"refs":remap_refs(event,"refs",event_ids,source),"plan":plan,"data":data}),
                    stamp(event, "ts"),
                )?;
                remember(c, source, key_kind, &original.to_string(), &eid.to_string())?;
                eid
            };
            if table == "work_events" {
                imported_events.insert(original, eid);
            }
        }
    }
    // Current metadata is derived from the source's append-only history.
    for item in rows(tables, "work_items") {
        let original = string(item, "id");
        if key(c, source, "projection", &original)?.is_some() {
            continue;
        }
        let id = item_map(&original);
        let project = string(item, "project");
        let mut transfers: Vec<_> = rows(tables, "work_events")
            .iter()
            .filter(|e| e["item"] == original && e["type"] == "이관")
            .collect();
        transfers.sort_by_key(|e| (string(e, "date"), stamp(e, "id")));
        if let Some(last) = transfers.last() {
            c.execute(
                "UPDATE ledger_work_items SET bundle=?2 WHERE id=?1",
                params![id, string(last, "to_bundle")],
            )?;
        }
        let mut stems: Vec<_> = rows(tables, "work_stems")
            .iter()
            .filter(|e| e["item"] == original)
            .collect();
        stems.sort_by_key(|e| (string(e, "date"), stamp(e, "id")));
        if let Some(last) = stems.last() {
            c.execute(
                "UPDATE ledger_work_items SET stem=?2 WHERE id=?1",
                params![id, string(last, "g")],
            )?;
        }
        for split in rows(tables, "work_splits")
            .iter()
            .filter(|e| e["item"] == original)
        {
            c.execute(
                "UPDATE ledger_work_items SET from_item=?2 WHERE id=?1",
                params![id, item_map(&string(split, "from_item"))],
            )?;
        }
        for fix in rows(tables, "work_item_fixes")
            .iter()
            .filter(|e| e["item"] == original)
        {
            let field = string(fix, "field");
            if matches!(field.as_str(), "title" | "output" | "scope") {
                c.execute(
                    &format!("UPDATE ledger_work_items SET {field}=?2 WHERE id=?1"),
                    params![id, string(fix, "new_value")],
                )?;
            }
        }
        // A repeat import must not apply old projections over newer app edits.
        remember(c, source, "projection", &original, &project)?;
    }
    for carry in rows(tables, "work_carries") {
        if key(c, source, "work_carries", &stamp(carry, "id").to_string())?.is_some() {
            continue;
        }
        let Some(from) = imported_events.get(&stamp(carry, "from_event")) else {
            continue;
        };
        let Some(to) = imported_events.get(&stamp(carry, "to_event")) else {
            continue;
        };
        let target = item_map(&string(carry, "to_item"));
        let origin = string(carry, "origin_date");
        let count = stamp(carry, "count");
        c.execute(
            "UPDATE ledger_work_events SET data=json_set(data,'$.carriedTo',?2) WHERE id=?1",
            params![from, target],
        )?;
        c.execute("UPDATE ledger_work_events SET data=json_set(data,'$.originDate',?2,'$.carryCount',?3,'$.from',?4) WHERE id=?1",params![to,origin,count,item_map(&string(carry,"from_item"))])?;
    }
    for movement in rows(tables, "work_moves") {
        if key(c, source, "work_moves", &stamp(movement, "id").to_string())?.is_some() {
            continue;
        }
        if let Some(eid) = imported_events.get(&stamp(movement, "event_id")) {
            let destination = item_map(&string(movement, "to_item"));
            let project = string(movement, "project");
            let bundle = load_item(c, &project, &destination)?["bundle"].clone();
            c.execute(
                "UPDATE ledger_work_events SET item=?2,bundle=?3 WHERE id=?1",
                params![eid, destination, bundle.as_str()],
            )?;
        }
    }
    for mark in rows(tables, "work_marks") {
        let references = remap_refs(mark, "refs", event_ids, source);
        for reference in references
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            if let Some(eid) = reference
                .strip_prefix('E')
                .and_then(|s| s.parse::<i64>().ok())
            {
                c.execute("INSERT OR IGNORE INTO ledger_work_marks(project,event_id,date,reason,created_at) VALUES (?1,?2,?3,?4,?5)",params![string(mark,"project"),eid,string(mark,"date"),string(mark,"text"),stamp(mark,"ts")])?;
            }
        }
    }
    for note in rows(tables, "work_notes") {
        let original = stamp(note, "id").to_string();
        if key(c, source, "note", &original)?.is_some() {
            continue;
        }
        let target = string(note, "target");
        c.execute("INSERT INTO ledger_work_notes(project,target,text,created_at,delivered_at) VALUES (?1,?2,?3,?4,?5)",params![string(note,"project"),item_ids.get(&target).unwrap_or(&target),string(note,"text"),stamp(note,"ts"),note["delivered_ts"].as_i64()])?;
        remember(
            c,
            source,
            "note",
            &original,
            &c.last_insert_rowid().to_string(),
        )?;
    }
    for table in [
        "work_date_fixes",
        "work_text_fixes",
        "work_item_fixes",
        "work_stems",
        "work_moves",
        "work_carries",
        "work_splits",
    ] {
        for entry in rows(tables, table) {
            let original = entry
                .get("id")
                .map(Value::to_string)
                .unwrap_or_else(|| string(entry, "item"));
            if key(c, source, table, &original)?.is_some() {
                continue;
            }
            let mut item = arg_str_any(entry, &["item", "from_item"]).map(|id| item_map(&id));
            let eid = if entry["target"] == "bundle" {
                key(
                    c,
                    source,
                    "bundle_event",
                    &stamp(entry, "event_id").to_string(),
                )?
                .and_then(|v| v.parse().ok())
            } else {
                imported_events.get(&stamp(entry, "event_id")).copied()
            };
            if item.is_none() {
                if let Some(eid) = eid {
                    item = c
                        .query_row(
                            "SELECT item FROM ledger_work_events WHERE id=?1",
                            [eid],
                            |r| r.get(0),
                        )
                        .optional()?
                        .flatten();
                }
            }
            let before = match table {
                "work_date_fixes" => json!({"date":entry["old_date"],"estimated":entry["old_est"]}),
                "work_text_fixes" => json!({"text":entry["old_text"]}),
                "work_item_fixes" => json!({"field":entry["field"],"value":entry["old_value"]}),
                _ => entry.clone(),
            };
            let after = match table {
                "work_date_fixes" => {
                    json!({"date":entry["new_date"],"refs":remap_refs(entry,"refs",event_ids,source)})
                }
                "work_text_fixes" => {
                    json!({"text":entry["new_text"],"refs":remap_refs(entry,"refs",event_ids,source)})
                }
                "work_item_fixes" => json!({"field":entry["field"],"value":entry["new_value"]}),
                _ => entry.clone(),
            };
            c.execute("INSERT INTO ledger_work_history(project,item,event_id,action,date,before_value,after_value,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",params![string(entry,"project"),item,eid,table,string(entry,"date"),before.to_string(),after.to_string(),stamp(entry,"ts")])?;
            remember(
                c,
                source,
                table,
                &original,
                &c.last_insert_rowid().to_string(),
            )?;
        }
    }
    Ok(json!({"items":count,"events":event_count}))
}
