use super::*;
use std::collections::{BTreeMap, BTreeSet};

pub(super) fn call(c: &Connection, args: &Value, action: &str, now: i64) -> Result<Value> {
    let project = project(c, args)?;
    match action {
        "list" => state(c, &project, args, now),
        "detail" => {
            let id = item_id(args)?;
            let mut item = load_item(c, &project, &id)?;
            let events = events(c, &project, Some(&id))?;
            enrich(&mut item, &events);
            let history = history(c, &project, Some(&id))?;
            Ok(json!({"project":project,"item":item,"events":events,"history":history}))
        }
        "report" => report(c, &project, args, now),
        "unassigned" => unassigned(c, &project, args),
        _ => Err(Error::invalid(format!(
            "Unknown work read action: {action}"
        ))),
    }
}

fn history(c: &Connection, project: &str, item: Option<&str>) -> Result<Vec<Value>> {
    let mut q = c.prepare("SELECT id,item,event_id,action,date,before_value,after_value,created_at FROM ledger_work_history WHERE project=?1 AND (?2 IS NULL OR item=?2 OR json_extract(after_value,'$.item')=?2 OR event_id IN (SELECT id FROM ledger_work_events WHERE project=?1 AND item=?2)) ORDER BY id")?;
    let rows = q.query_map(params![project,item],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"item":r.get::<_,Option<String>>(1)?,"eventId":r.get::<_,Option<i64>>(2)?,"action":r.get::<_,String>(3)?,"date":r.get::<_,String>(4)?,"before":json_column(r.get(5)?)?,"after":json_column(r.get(6)?)?,"createdAt":r.get::<_,i64>(7)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

fn enrich(item: &mut Value, events: &[Value]) {
    let mut status = "planned";
    let mut latest_plan = Value::Null;
    let mut progress = 0;
    let mut estimates = 0;
    for event in events {
        let kind = event["event"].as_str().unwrap_or("");
        status = match kind {
            "started" | "resumed" => "active",
            "completed" => "completed",
            "frozen" => "frozen",
            "held" => "held",
            "cancelled" => "cancelled",
            _ => status,
        };
        if kind == "progress" {
            progress += 1;
        }
        if event["estimated"].as_bool().unwrap_or(false) {
            estimates += 1;
        }
        if kind == "plan" {
            latest_plan = event["plan"].clone();
        }
    }
    let issues: Vec<_> = events
        .iter()
        .filter(|e| matches!(e["event"].as_str(), Some("issue" | "progress")))
        .collect();
    if !super::write::closed(status)
        && !issues.is_empty()
        && issues.iter().all(|e| !e["data"]["carriedTo"].is_null())
    {
        status = "carried";
    }
    item["status"] = json!(status);
    item["plan"] = latest_plan;
    item["progressCount"] = json!(progress);
    item["estimatedCount"] = json!(estimates);
    item["firstDate"] = events
        .first()
        .map(|e| e["date"].clone())
        .unwrap_or(Value::Null);
    item["lastDate"] = events
        .last()
        .map(|e| e["date"].clone())
        .unwrap_or(Value::Null);
    item["eventCount"] = json!(events.len());
}

pub(super) fn state(c: &Connection, project: &str, args: &Value, _now: i64) -> Result<Value> {
    let all_events = events(c, project, None)?;
    let mut q = c.prepare(
        "SELECT id FROM ledger_work_items WHERE project=?1 ORDER BY bundle,stem,created_date,id",
    )?;
    let ids = q
        .query_map([project], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let filter_bundle = arg_str_any(args, &["bundle", "b"]);
    let filter_status = arg_str(args, "status");
    let filter_stem = arg_str_any(args, &["stem", "g"]);
    let mut items = Vec::new();
    let mut warnings = Vec::new();
    for id in ids {
        let mut item = load_item(c, project, &id)?;
        let item_events: Vec<_> = all_events
            .iter()
            .filter(|e| e["item"] == id)
            .cloned()
            .collect();
        enrich(&mut item, &item_events);
        if filter_bundle.as_ref().is_some_and(|f| item["bundle"] != *f)
            || filter_status.as_ref().is_some_and(|f| item["status"] != *f)
            || filter_stem.as_ref().is_some_and(|f| item["stem"] != *f)
        {
            continue;
        }
        let later = matches!(item["bundle"].as_str(), Some("Later" | "차후 과제"));
        if !later
            && !super::write::closed(item["status"].as_str().unwrap_or(""))
            && item["plan"].is_null()
        {
            warnings.push(json!({"code":"missing_plan","item":id,"message":"An unfinished item has no dated plan"}));
        }
        let duration = item["firstDate"]
            .as_str()
            .and_then(day_number)
            .zip(item["lastDate"].as_str().and_then(day_number))
            .map(|(a, b)| b - a)
            .unwrap_or(0);
        if !later && (duration > 14 || item["progressCount"].as_i64().unwrap_or(0) > 5) {
            warnings.push(json!({"code":"large_item","item":id,"message":"Consider splitting this long-running work item"}));
        }
        for event in &item_events {
            if event["data"]["carryCount"].as_i64().unwrap_or(0) >= 2 {
                warnings.push(json!({"code":"repeated_carry","item":id,"eventId":event["id"],"message":"This issue has carried forward more than once"}));
            }
            let sentence = event["text"].as_str().unwrap_or("").to_lowercase();
            if [
                "판정",
                "통지",
                "회신",
                "상신",
                "판단 요청",
                "received instructions",
                "requested approval",
            ]
            .iter()
            .any(|word| sentence.contains(word))
            {
                warnings.push(json!({"code":"report_text","item":id,"eventId":event["id"],"message":"Describe the work performed rather than the reporting procedure"}));
            }
        }
        items.push(item);
    }
    let mut q=c.prepare("SELECT name,created_date,created_at FROM ledger_work_bundles WHERE project=?1 ORDER BY created_date,name")?;
    let bundles = q
        .query_map([project], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut output = Vec::new();
    for (name, date, at) in bundles {
        if filter_bundle.as_ref().is_some_and(|f| f != &name) {
            continue;
        }
        let relevant: Vec<_> = items.iter().filter(|i| i["bundle"] == name).collect();
        let completion = all_events.iter().rev().find(|e| {
            e["item"].is_null()
                && e["bundle"] == name
                && matches!(
                    e["event"].as_str(),
                    Some("bundle_completed" | "bundle_reopened")
                )
        });
        let completed = completion.is_some_and(|e| e["event"] == "bundle_completed");
        let mut stems: BTreeMap<String, usize> = BTreeMap::new();
        for item in &relevant {
            *stems
                .entry(item["stem"].as_str().unwrap_or("").into())
                .or_default() += 1;
        }
        if !matches!(name.as_str(), "Later" | "차후 과제") {
            for (stem, count) in &stems {
                if (stem.is_empty() && *count > 8)
                    || (!stem.is_empty() && (*count < 2 || *count > 6))
                {
                    warnings.push(json!({"code":"bundle_size","bundle":name,"stem":stem,"count":count,"message":"Review the grouping of these work items"}));
                }
            }
        }
        output.push(json!({"name":name,"createdDate":date,"createdAt":at,"status":if completed {"completed"} else {"active"},"itemCount":relevant.len(),"stems":stems,"completion":completion}));
    }
    let mut q=c.prepare("SELECT id,target,text,created_at,delivered_at FROM ledger_work_notes WHERE project=?1 ORDER BY id")?;
    let notes=q.query_map([project],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"target":r.get::<_,String>(1)?,"text":r.get::<_,String>(2)?,"createdAt":r.get::<_,i64>(3)?,"deliveredAt":r.get::<_,Option<i64>>(4)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"project":project,"bundles":output,"items":items,"warnings":warnings,"notes":notes}))
}

fn markdown(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]")
        .replace('#', "\\#")
        .replace('*', "\\*")
        .replace('_', "\\_")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn report(c: &Connection, project: &str, args: &Value, now: i64) -> Result<Value> {
    let state = state(c, project, args, now)?;
    let from = arg_str(args, "from")
        .map(|v| date_value(&v, false).map(|v| v.0))
        .transpose()?;
    let to = arg_str(args, "to")
        .map(|v| date_value(&v, false).map(|v| v.0))
        .transpose()?;
    if from.as_ref().zip(to.as_ref()).is_some_and(|(a, b)| a > b) {
        return Err(Error::invalid("from cannot follow to"));
    }
    let events = events(c, project, None)?;
    let summary = arg_bool(args, "summary").unwrap_or(false)
        || arg_str(args, "view").as_deref() == Some("summary");
    let show_refs = arg_bool(args, "refs")
        .or_else(|| arg_bool(args, "includeRefs"))
        .unwrap_or(false);
    let mut output = format!("# Work report: {}\n\n", markdown(project));
    let mut footnotes = Vec::new();
    let mut count = 0;
    for bundle in state["bundles"].as_array().into_iter().flatten() {
        let name = bundle["name"].as_str().unwrap_or("");
        let mut body = String::new();
        let mut previous_stem = String::new();
        for item in state["items"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|i| i["bundle"] == name)
        {
            let records: Vec<_> = events
                .iter()
                .filter(|e| {
                    e["item"] == item["id"]
                        && from
                            .as_ref()
                            .is_none_or(|d| e["date"].as_str().unwrap_or("") >= d.as_str())
                        && to
                            .as_ref()
                            .is_none_or(|d| e["date"].as_str().unwrap_or("") <= d.as_str())
                })
                .collect();
            if records.is_empty() {
                continue;
            }
            count += 1;
            let stem = item["stem"].as_str().unwrap_or("");
            if !stem.is_empty() && previous_stem != stem {
                body.push_str(&format!("### {}\n\n", markdown(stem)));
                previous_stem = stem.into();
            }
            if summary {
                let recent = records
                    .iter()
                    .rev()
                    .find(|e| !e["text"].as_str().unwrap_or("").is_empty());
                body.push_str(&format!(
                    "- **{}** ({}, {}): {}\n",
                    markdown(item["title"].as_str().unwrap_or("")),
                    item["id"].as_str().unwrap_or(""),
                    item["status"].as_str().unwrap_or(""),
                    recent
                        .map(|e| markdown(e["text"].as_str().unwrap_or("")))
                        .unwrap_or_default()
                ));
            } else {
                body.push_str(&format!(
                    "#### {} — {}\n\nStatus: {}\n\n",
                    item["id"].as_str().unwrap_or(""),
                    markdown(item["title"].as_str().unwrap_or("")),
                    item["status"].as_str().unwrap_or("")
                ));
                for event in records {
                    if event["event"] == "registered" && !item["from"].is_null() {
                        continue;
                    }
                    let text = event["text"].as_str().unwrap_or("");
                    if text.is_empty() {
                        continue;
                    }
                    let mut refs = String::new();
                    if show_refs {
                        for reference in event["refs"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                        {
                            footnotes.push(reference.to_string());
                            refs.push_str(&format!(" [{}]", footnotes.len()));
                        }
                    }
                    let carried = event["data"]["carriedTo"]
                        .as_str()
                        .map(|to| format!(" (carried to {to})"))
                        .unwrap_or_default();
                    body.push_str(&format!(
                        "- {}{} · {}: {}{}{}\n",
                        if event["estimated"].as_bool().unwrap_or(false) {
                            "~"
                        } else {
                            ""
                        },
                        event["date"].as_str().unwrap_or(""),
                        event["event"].as_str().unwrap_or(""),
                        markdown(text),
                        carried,
                        refs
                    ));
                }
                body.push('\n');
            }
        }
        if !body.is_empty() {
            output.push_str(&format!("## {}\n\n{}\n", markdown(name), body));
        }
    }
    if count == 0 {
        output.push_str("No work records match these filters.\n");
    }
    if !footnotes.is_empty() {
        output.push_str("## References\n\n");
        for (i, note) in footnotes.iter().enumerate() {
            output.push_str(&format!("[{}]: {}\n", i + 1, markdown(note)));
        }
    }
    Ok(
        json!({"project":project,"markdown":output,"itemCount":count,"from":from,"to":to,"warnings":state["warnings"]}),
    )
}

fn unassigned(c: &Connection, project: &str, args: &Value) -> Result<Value> {
    let from = arg_str(args, "from")
        .map(|v| date_value(&v, false).map(|v| v.0))
        .transpose()?;
    let to = arg_str(args, "to")
        .map(|v| date_value(&v, false).map(|v| v.0))
        .transpose()?;
    if from.as_ref().zip(to.as_ref()).is_some_and(|(a, b)| a > b) {
        return Err(Error::invalid("from cannot follow to"));
    }
    let mut assigned = BTreeSet::new();
    let mut links = c.prepare("SELECT event_id FROM ledger_work_links WHERE project=?1")?;
    for id in links.query_map([project], |r| r.get::<_, i64>(0))? {
        assigned.insert(id?);
    }
    for event in events(c, project, None)? {
        for reference in event["refs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            if let Some(id) = reference
                .trim_start_matches('#')
                .strip_prefix('E')
                .and_then(|s| s.parse::<i64>().ok())
            {
                assigned.insert(id);
            }
        }
    }
    let mut q = c.prepare("SELECT event_id,reason,date FROM ledger_work_marks WHERE project=?1")?;
    let skipped = q
        .query_map([project], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                (r.get::<_, String>(1)?, r.get::<_, String>(2)?),
            ))
        })?
        .collect::<rusqlite::Result<BTreeMap<_, _>>>()?;
    let mut q=c.prepare("SELECT id,session_id,type,summary,ts,strftime('%Y-%m-%d',ts/1000,'unixepoch') FROM events WHERE project=?1 AND type IN ('release','applied','decision','done') ORDER BY ts DESC,id DESC")?;
    let rows=q.query_map([project],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"session":r.get::<_,String>(1)?,"event":r.get::<_,String>(2)?,"summary":r.get::<_,String>(3)?,"ts":r.get::<_,i64>(4)?,"date":r.get::<_,Option<String>>(5)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let mut items = Vec::new();
    let mut marked = Vec::new();
    for mut row in rows {
        let id = row["id"].as_i64().unwrap_or_default();
        if assigned.contains(&id)
            || from
                .as_ref()
                .is_some_and(|d| row["date"].as_str().unwrap_or("") < d.as_str())
            || to
                .as_ref()
                .is_some_and(|d| row["date"].as_str().unwrap_or("") > d.as_str())
        {
            continue;
        }
        if let Some((reason, date)) = skipped.get(&id) {
            row["reason"] = json!(reason);
            row["skippedDate"] = json!(date);
            marked.push(row);
        } else {
            items.push(row);
        }
    }
    Ok(json!({"project":project,"events":items,"unassigned":items,"skipped":marked}))
}
