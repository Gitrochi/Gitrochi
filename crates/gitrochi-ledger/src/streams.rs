//! Streams: a live implementation session keeps reporting under one ID, cycle after cycle
//! (`sync` vX → work → `applied` vX). Its reports are grouped by the baseline they belong to.

use crate::util::{compare_versions, Ms};
use serde::Serialize;
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::HashMap;

/// An agent event as the cycle walk needs it.
pub struct CycleEvent<'a> {
    pub id: i64,
    pub ts: Ms,
    pub kind: &'a str,
    pub summary: &'a str,
    pub data: &'a Value,
    pub artifacts: Vec<String>,
}

/// One cycle (`StreamCycle` in CONTRACT.md).
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StreamCycle {
    pub session_id: String,
    pub line: String,
    /// Empty when the session reported before it had a base.
    pub version: String,
    /// `applied` (the version was applied), `active` (the newest), `skipped` (moved on).
    pub state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub synced_at: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub applied_at: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub released_by: Option<String>,
    pub event_ids: Vec<i64>,
    pub first_at: Ms,
    pub last_at: Ms,
    pub events: usize,
    pub questions: usize,
    pub artifacts: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sync_summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub applied_summary: Option<String>,
}

fn version_order(a: &str, b: &str) -> Ordering {
    match (a.is_empty(), b.is_empty()) {
        (true, true) => Ordering::Equal,
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
        (false, false) => compare_versions(a, b),
    }
}

/// Walks the session's agent events in time order. `sync` to vX starts the vX cycle; the
/// session's own `applied` vX joins the vX cycle and moves the current version forward
/// only; anything else joins the current cycle. Newest version first.
pub fn cycles(
    session_id: &str,
    line: &str,
    base_version: Option<&str>,
    events: &[CycleEvent],
    released_by: &HashMap<String, String>,
) -> Vec<StreamCycle> {
    let mut by_version: HashMap<String, StreamCycle> = HashMap::new();
    let mut current = base_version.unwrap_or("").to_string();
    for event in events {
        let data = event.data;
        let key = if event.kind == "sync" && data["to"].is_string() {
            current = data["to"].as_str().unwrap_or("").to_string();
            current.clone()
        } else if event.kind == "applied" && data["version"].is_string() && data["by"].is_null() {
            // `data.by` marks the record a hand-off left on the decision side.
            let version = data["version"].as_str().unwrap_or("").to_string();
            if current.is_empty() || compare_versions(&version, &current) == Ordering::Greater {
                current = version.clone();
            }
            version
        } else {
            current.clone()
        };
        let cycle = by_version
            .entry(key.clone())
            .or_insert_with(|| StreamCycle {
                session_id: session_id.to_string(),
                line: line.to_string(),
                released_by: released_by.get(&key).cloned(),
                version: key.clone(),
                state: "skipped",
                synced_at: None,
                applied_at: None,
                event_ids: Vec::new(),
                first_at: event.ts,
                last_at: event.ts,
                events: 0,
                questions: 0,
                artifacts: Vec::new(),
                sync_summary: None,
                applied_summary: None,
            });
        if event.kind == "sync" && cycle.synced_at.is_none() && data["to"].is_string() {
            cycle.synced_at = Some(event.ts);
            cycle.sync_summary = Some(event.summary.to_string());
        }
        if event.kind == "applied" && data["version"].is_string() && data["by"].is_null() {
            cycle.applied_at = Some(event.ts);
            cycle.applied_summary = Some(event.summary.to_string());
        }
        cycle.events += 1;
        cycle.event_ids.push(event.id);
        cycle.first_at = cycle.first_at.min(event.ts);
        cycle.last_at = cycle.last_at.max(event.ts);
        cycle.questions += usize::from(event.kind == "question")
            + data["questionIds"].as_array().map_or(0, Vec::len);
        for name in &event.artifacts {
            if !cycle.artifacts.contains(name) {
                cycle.artifacts.push(name.clone());
            }
        }
    }
    let mut out: Vec<StreamCycle> = by_version.into_values().collect();
    out.sort_by(|a, b| version_order(&b.version, &a.version).then(b.first_at.cmp(&a.first_at)));
    for (index, cycle) in out.iter_mut().enumerate() {
        cycle.state = if cycle.applied_at.is_some() {
            "applied"
        } else if index == 0 {
            "active"
        } else {
            "skipped"
        };
    }
    out
}

/// The stream's name: the title up to a spaced dash ("Core channel — v1.4 sync" → "Core channel").
pub fn label(title: &str) -> String {
    let title = title.trim();
    let cut = [" — ", " – ", " -- ", " - "]
        .iter()
        .filter_map(|separator| title.find(separator))
        .min();
    match cut.map(|at| title[..at].trim()) {
        Some(head) if !head.is_empty() => head.to_string(),
        _ => title.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn labels_cut_at_a_spaced_dash() {
        assert_eq!(label("Core channel — v1.4 sync · CD-1"), "Core channel");
        assert_eq!(label("Local channel - rewrite"), "Local channel");
        assert_eq!(label("cache refactor"), "cache refactor");
        assert_eq!(label("CD-114 measure"), "CD-114 measure");
    }

    #[test]
    fn cycles_follow_sync_and_applied() {
        let none = json!({});
        let sync6 = json!({"from": "1.5", "to": "1.6"});
        let applied6 = json!({"version": "1.6"});
        let sync7 = json!({"from": "1.6", "to": "1.7"});
        let target_record = json!({"version": "1.7", "by": "S0101-09"});
        let questions = json!({"questionIds": [4, 5]});
        let e = |id, kind, data| CycleEvent {
            id,
            ts: id * 10,
            kind,
            summary: "s",
            data,
            artifacts: vec![],
        };
        let events = vec![
            e(1, "start", &none),
            e(2, "artifact", &none),
            e(3, "sync", &sync6),
            e(4, "artifact", &questions),
            e(5, "applied", &applied6),
            e(6, "progress", &none),
            e(7, "sync", &sync7),
            e(8, "applied", &target_record),
        ];
        let released = HashMap::from([("1.6".to_string(), "S0101-02".to_string())]);
        let out = cycles("S0101-05", "core", Some("1.5"), &events, &released);
        let summary: Vec<_> = out.iter().map(|c| (c.version.as_str(), c.state)).collect();
        assert_eq!(
            summary,
            [("1.7", "active"), ("1.6", "applied"), ("1.5", "skipped")]
        );
        assert_eq!(out[1].event_ids, [3, 4, 5, 6]);
        assert_eq!(out[1].released_by.as_deref(), Some("S0101-02"));
        assert_eq!(out[1].questions, 2);
        assert_eq!((out[1].synced_at, out[1].applied_at), (Some(30), Some(50)));
        // a hand-off record left by another session does not count as applying
        assert_eq!(out[0].applied_at, None);
        assert_eq!(out[0].event_ids, [7, 8]);
    }
}
