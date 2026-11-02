//! Response aliases for the old Python client's formatters, without changing the core API.
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

fn snake(key: &str) -> String {
    let mut out = String::new();
    for ch in key.chars() {
        if ch.is_ascii_uppercase() {
            out.push('_');
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

fn aliases(value: Value) -> Value {
    match value {
        Value::Array(rows) => Value::Array(rows.into_iter().map(aliases).collect()),
        Value::Object(rows) => {
            let mut out = Map::new();
            for (key, value) in rows {
                let value = aliases(value);
                out.insert(snake(&key), value.clone());
                out.insert(key, value);
            }
            Value::Object(out)
        }
        value => value,
    }
}

fn messages(value: &mut Value) {
    value["messages"] = json!(value["messages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m.as_str().or_else(|| m["text"].as_str()))
        .collect::<Vec<_>>());
}

fn session(mut value: Value) -> Value {
    value = aliases(value);
    value["status_label"] = value["status"].clone();
    value["verdict_label"] = json!(match value["verdict"].as_str().unwrap_or("") {
        "needs_human" => "Needs a person",
        "expirable" => "Ready to archive",
        "confirm" => "Awaiting confirmation",
        "pending_merge" => "Merge undecided",
        "stale" => "Quiet",
        "shelved" => "Shelved",
        "archived" => "Archived",
        _ => "Active",
    });
    value["open_items"] = value["openQuestions"].clone();
    value["last_rel"] = json!("");
    for (from, to) in [
        ("createdAt", "created_ts"),
        ("lastAt", "last_ts"),
        ("ackAt", "ack_ts"),
        ("archivedAt", "archived_ts"),
    ] {
        value[to] = value[from].clone();
    }
    value
}

pub(super) fn report(mut value: Value) -> Value {
    value["session"] = session(value["session"].take());
    value["item_ids"] = value["questionIds"].clone();
    messages(&mut value);
    value
}

pub(super) fn overview(mut value: Value) -> Value {
    value["trunk_recent"] = aliases(value["recentBaselines"].take());
    value["closed_pending"] = value["finished"].take();
    for key in ["open", "closed_pending", "shelved"] {
        value[key] = json!(value[key]
            .as_array()
            .into_iter()
            .flatten()
            .cloned()
            .map(session)
            .collect::<Vec<_>>());
    }
    value["projects"] = json!(value["projects"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|p| if p.is_string() {
            json!({"name":p})
        } else {
            p.clone()
        })
        .collect::<Vec<_>>());
    if let Some(overlaps) = value["overlaps"].as_array_mut() {
        for overlap in overlaps {
            overlap["common"] = overlap["paths"].clone();
        }
    }
    value["streams"] = json!(value["streams"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|stream| {
            let mut row = session(stream["session"].clone());
            row["label"] = stream["label"].clone();
            row["line"] = row["stream"]["line"].clone();
            row["cycles"] = json!(stream["cycles"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|cycle| {
                    let mut cycle = aliases(cycle.clone());
                    cycle["state_label"] = cycle["state"].clone();
                    cycle["sync"] = if cycle["syncedAt"].is_number() {
                        json!({"ts":cycle["syncedAt"]})
                    } else {
                        Value::Null
                    };
                    cycle["applied"] = if cycle["appliedAt"].is_number() {
                        json!([{"ts":cycle["appliedAt"]}])
                    } else {
                        json!([])
                    };
                    cycle
                })
                .collect::<Vec<_>>());
            row
        })
        .collect::<Vec<_>>());
    messages(&mut value);
    value
}

pub(super) fn detail(mut value: Value) -> Value {
    value["session"] = session(value["session"].take());
    value["items"] = aliases(value["questions"].take());
    if let Some(events) = value["events"].as_array_mut() {
        for event in events {
            *event = aliases(event.take());
            if event["data"].is_null() {
                event["data"] = json!({});
            }
            if !event["body"].is_null() {
                event["data"]["body"] = event["body"].clone();
            }
            if !event["summary"].is_string() {
                event["summary"] = json!("");
            }
            if !event["artifacts"].is_array() {
                event["artifacts"] = json!([]);
            }
            event["ssot"] = event["version"].clone();
            if event["actor"] == "agent" {
                event["actor"] = json!("claude");
            }
        }
    }
    messages(&mut value);
    value
}

pub(super) fn state(mut value: Value) -> Value {
    if let Some(rows) = value["sessions"].as_array_mut() {
        for row in rows {
            *row = session(row.take());
        }
    }
    value["versions"] = aliases(value["baselines"].clone());
    value["items"] = aliases(value["questions"].clone());
    value
}

pub(super) fn attention(value: Value) -> Value {
    let sessions: Vec<_> = value["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .cloned()
        .map(session)
        .collect();
    let cleanup: Vec<_> = sessions
        .iter()
        .filter(|s| matches!(s["verdict"].as_str(), Some("confirm" | "expirable")))
        .cloned()
        .collect();
    let decide: Vec<_> = sessions
        .iter()
        .filter(|s| {
            s["stream"].is_null()
                && matches!(s["verdict"].as_str(), Some("pending_merge" | "stale"))
        })
        .cloned()
        .collect();
    let questions:Vec<_>=value["questions"].as_array().into_iter().flatten().map(|q|{
        let row=sessions.iter().find(|s|s["id"]==q["sessionId"]);
        json!({"id":q["id"],"session":q["sessionId"],"text":q["text"],"ts":q["createdAt"],"title":row.map(|s|s["title"].clone()).unwrap_or(Value::Null),"kind":row.map(|s|s["kind"].clone()).unwrap_or(Value::Null)})
    }).collect();
    json!({"rev":value["rev"],"questions":questions,"cleanup":cleanup,"decide":decide,"applied":[],"count":questions.len()+cleanup.len()+decide.len()})
}

fn work_item(mut item: Value) -> Value {
    if !item["status"].is_string() {
        item["status"] = json!("planned");
    }
    if !item["firstDate"].is_string() {
        item["firstDate"] = item["createdDate"].clone();
    }
    if !item["progressCount"].is_number() {
        item["progressCount"] = json!(0);
    }
    if !item["estimatedCount"].is_number() {
        item["estimatedCount"] = json!(0);
    }
    item["label"] = item["status"].clone();
    item["start"] = item["firstDate"].clone();
    item["end"] = if matches!(item["status"].as_str(), Some("completed" | "cancelled")) {
        item["lastDate"].clone()
    } else {
        Value::Null
    };
    item["start_est"] = json!(false);
    item["end_est"] = json!(false);
    item["n_progress"] = item["progressCount"].clone();
    item["n_est"] = item["estimatedCount"].clone();
    item
}

pub(super) fn work(mut value: Value, args: &Value) -> Value {
    let action = args["action"].as_str().unwrap_or("list");
    value["action"] = json!(action);
    if action == "list" {
        let items: Vec<_> = value["items"]
            .as_array()
            .into_iter()
            .flatten()
            .cloned()
            .map(work_item)
            .collect();
        value["n_items"] = json!(items.len());
        if let Some(bundles) = value["bundles"].as_array_mut() {
            for bundle in bundles {
                let its: Vec<_> = items
                    .iter()
                    .filter(|i| i["bundle"] == bundle["name"])
                    .cloned()
                    .collect();
                let mut counts = BTreeMap::<String, usize>::new();
                for item in &its {
                    *counts
                        .entry(item["label"].as_str().unwrap_or("").into())
                        .or_default() += 1;
                }
                bundle["later"] = json!(bundle["name"] == "Later");
                bundle["waiting"] = json!(0);
                bundle["counts"] = json!(counts);
                bundle["items"] = json!(its);
                bundle["stems"] = json!([]);
                bundle["done"] = if bundle["status"] == "completed" {
                    json!({"date":bundle["completion"]["date"],"est":bundle["completion"]["estimated"]})
                } else {
                    Value::Null
                };
            }
        }
        if let Some(warnings) = value["warnings"].as_array_mut() {
            for warning in warnings {
                warning["text"] = warning["message"].clone();
            }
        }
    } else if action == "add_item" || action == "event" {
        value["w"] = args["w"]
            .as_str()
            .or_else(|| args["item"].as_str())
            .map(|s| json!(s))
            .unwrap_or(Value::Null);
        value["b"] = args["b"]
            .as_str()
            .or_else(|| args["bundle"].as_str())
            .map(|s| json!(s))
            .unwrap_or(Value::Null);
        value["ev"] = args["ev"]
            .as_str()
            .or_else(|| args["event"].as_str())
            .map(|s| json!(s))
            .unwrap_or_else(|| json!("registered"));
        value["date"] = args["d"]
            .as_str()
            .or_else(|| args["date"].as_str())
            .map(|s| json!(s.trim_start_matches('~')))
            .unwrap_or(Value::Null);
        value["date_est"] = json!(args["d"]
            .as_str()
            .or_else(|| args["date"].as_str())
            .is_some_and(|s| s.starts_with('~')));
        if value["item"].is_object() {
            value["item"] = work_item(value["item"].take());
        } else {
            value["item"] = Value::Null;
        }
    }
    messages(&mut value);
    value
}

pub(super) fn documents(mut value: Value, path: &str, args: &Value, now: i64) -> Value {
    value["configured"] = json!(!value["roots"].as_array().is_none_or(|r| r.is_empty()));
    if path == "/api/id" {
        let entries = value["entries"].as_array().cloned().unwrap_or_default();
        let mentions: Vec<_> = entries
            .iter()
            .map(|e| json!({"src":e["path"],"line":e["line"],"text":e["text"]}))
            .collect();
        value["query"] = args["id"].clone();
        value["id"] = args["id"].clone();
        value["since"] = json!(now);
        value["n"] = json!(entries.len());
        value["counts"] = json!({"documents":entries.len()});
        value["mentions"] = json!(mentions);
        value["def"]=entries.iter().find(|e|e["definition"]==true).map(|e|json!({"src":e["path"],"line":e["line"],"closed":e["status"]=="done","cells":[{"name":"","text":e["text"]}]})).unwrap_or(Value::Null);
        value["excerpt"] = value["summary"].take();
        value["summary"] = Value::Null;
        value["files"] = json!(value["files"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|f| json!({"name":f["path"],"path":f["path"]}))
            .collect::<Vec<_>>());
        value["sessions"] = json!([]);
    }
    if path == "/api/worklist" {
        let items: Vec<_> = value["entries"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|e| json!({"mark":e["id"].as_str().unwrap_or(""),"text":e["text"],"done":false}))
            .collect();
        value["directive"] = json!({"exists":!items.is_empty(),"version":"","items":items,"extras":[],"reply":null,"remaining":null});
        value["registry"] = json!({"groups":[]});
        value["notices"] = json!([]);
        value["warnings"]=json!(["General document tracking; organization-specific directive and notice formats are not interpreted."]);
    }
    value
}
