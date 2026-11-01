//! The graph: the baseline trunk in lane 0 and each session as a lane that forks from its
//! base and joins the baseline it was merged into. The layout is computed here, once, so
//! both apps only draw it; the same database always gives the same graph.

use crate::baseline::Baseline;
use crate::error::Result;
use crate::event::EventView;
use crate::session::SessionView;
use crate::settings::Settings;
use crate::util::{one_line, Ms};
use crate::views::{self, Range};
use crate::vocab::{self, Role};
use rusqlite::Connection;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet};

/// Agent events the "key events only" view keeps.
const KEY_EVENTS: [&str; 12] = [
    "start", "artifact", "question", "decision", "sync", "done", "merged", "closed", "dropped",
    "release", "applied", "shelved",
];
/// A person's operations drawn on the graph: status changes, confirming and archiving.
const HUMAN_EVENTS: [&str; 4] = ["set_status", "shelve", "ack", "archive"];

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GraphNode {
    pub id: String,
    pub lane: usize,
    /// 0 is the top (newest) row.
    pub row: usize,
    pub ts: Ms,
    pub color: i64,
    /// `baseline`, `start`, `event`, `merge`, `release` or `end`.
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// The event type (`question`, `sync` …) so the apps can pick a shape.
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub event_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    /// Baselines: where the version came from (`tag`, `release`, `inferred` …).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub head: bool,
    /// Baselines a decision session released: `awaiting`, `synced` or `applied`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub handoff: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by_session: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct GraphEdge {
    pub from: String,
    pub to: String,
    /// `trunk`, `branch` (a fork or a lane segment), `merge` (into the trunk) or
    /// `handoff` (a dashed connector: a sync picking up a baseline, or a report that
    /// changed another session).
    pub kind: &'static str,
    pub color: i64,
}

/// An open session's lane continues upward from its newest node to the top, dashed.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GraphTail {
    pub session_id: String,
    pub lane: usize,
    pub row: usize,
    pub color: i64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Graph {
    pub lanes: usize,
    pub rows: usize,
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<GraphEdge>,
    pub tails: Vec<GraphTail>,
    pub from: Ms,
    pub to: Ms,
    /// Baselines and events older than the range, not drawn.
    pub hidden_before: usize,
}

pub struct Options {
    pub range: Range,
    pub key_only: bool,
    pub include_archived: bool,
}

fn node_kind(event: &EventView) -> &'static str {
    match event.kind.as_str() {
        "start" => "start",
        "release" => "release",
        "merged" => "merge",
        "applied" if !event.data["by"].is_null() => "merge",
        "done" | "closed" | "dropped" | "shelved" | "shelve" => "end",
        "set_status" => match event.data["status"].as_str() {
            Some("merged") => "merge",
            Some("done" | "closed" | "dropped" | "shelved") => "end",
            _ => "event",
        },
        _ => "event",
    }
}

fn is_merge(event: &EventView) -> bool {
    node_kind(event) == "merge"
}

fn shown(event: &EventView, first: bool, key_only: bool) -> bool {
    match event.actor.as_str() {
        "agent" => {
            !key_only
                || first
                || KEY_EVENTS.contains(&event.kind.as_str())
                || !event.data["reopenedFrom"].is_null()
        }
        "human" => {
            if key_only {
                matches!(event.kind.as_str(), "set_status" | "shelve")
            } else {
                HUMAN_EVENTS.contains(&event.kind.as_str())
            }
        }
        "auto" => !key_only,
        _ => false,
    }
}

enum Item<'a> {
    Baseline(&'a Baseline),
    Event(&'a EventView),
}

impl Item<'_> {
    fn ts(&self) -> Ms {
        match self {
            Item::Baseline(b) => b.eff_ts,
            Item::Event(e) => e.ts,
        }
    }
}

/// Handoff states of baselines released by decision sessions, from the events.
fn handoff_states(
    trunk: &[Baseline],
    sessions: &HashMap<&str, &SessionView>,
    settings: &Settings,
    events: &[EventView],
) -> HashMap<String, &'static str> {
    let mut synced = HashSet::new();
    let mut applied = HashSet::new();
    for event in events {
        if event.actor != "agent" || !event.data["by"].is_null() {
            continue;
        }
        let Some(session) = sessions.get(event.session_id.as_str()) else {
            continue;
        };
        if !settings.hands_off(&session.kind) {
            continue;
        }
        match event.kind.as_str() {
            "sync" => {
                if let Some(v) = event.data["to"].as_str() {
                    synced.insert(v.to_string());
                }
            }
            "applied" => {
                if let Some(v) = event.data["version"].as_str() {
                    applied.insert(v.to_string());
                }
            }
            _ => {}
        }
    }
    let mut out = HashMap::new();
    for baseline in trunk {
        let Some(by) = &baseline.by_session else {
            continue;
        };
        let Some(releaser) = sessions.get(by.as_str()) else {
            continue;
        };
        if settings.role(&releaser.kind) != Role::Decision {
            continue;
        }
        let state = if applied.contains(&baseline.version) {
            "applied"
        } else if synced.contains(&baseline.version) {
            "synced"
        } else if releaser.is_live() {
            "awaiting"
        } else {
            continue;
        };
        out.insert(baseline.version.clone(), state);
    }
    out
}

/// Lays out one project's graph.
pub fn graph(
    connection: &Connection,
    settings: &Settings,
    project: &str,
    options: &Options,
    now: Ms,
) -> Result<Graph> {
    let snapshot = views::snapshot(connection, settings, Some(project), now)?;
    let trunk: Vec<Baseline> = snapshot.trunks.get(project).cloned().unwrap_or_default();
    let sessions: Vec<&SessionView> = snapshot
        .views
        .iter()
        .filter(|v| options.include_archived || v.archived_at.is_none())
        .collect();
    let by_id: HashMap<&str, &SessionView> =
        snapshot.views.iter().map(|v| (v.id.as_str(), v)).collect();
    let mut statement = connection.prepare(&format!(
        "SELECT {} FROM events WHERE project = ?1 ORDER BY ts, id",
        crate::event::COLUMNS
    ))?;
    let all_events: Vec<EventView> = statement
        .query_map([project], EventView::from_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(layout(
        &trunk,
        &sessions,
        &by_id,
        &all_events,
        settings,
        options,
        now,
    ))
}

#[allow(clippy::too_many_arguments)]
fn layout(
    trunk: &[Baseline],
    sessions: &[&SessionView],
    by_id: &HashMap<&str, &SessionView>,
    all_events: &[EventView],
    settings: &Settings,
    options: &Options,
    now: Ms,
) -> Graph {
    let start = options.range.start(now);
    let in_range = |ts: Ms| start.is_none_or(|s| ts >= s);
    let included: HashSet<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
    let head = trunk.last().map(|b| b.version.clone());

    // Which events become nodes.
    let mut first_seen = HashSet::new();
    let mut hidden_before = 0;
    let mut events: Vec<&EventView> = Vec::new();
    for event in all_events {
        if !included.contains(event.session_id.as_str()) {
            continue;
        }
        let first = event.actor == "agent" && first_seen.insert(event.session_id.as_str());
        if !shown(event, first, options.key_only) {
            continue;
        }
        if in_range(event.ts) {
            events.push(event);
        } else {
            hidden_before += 1;
        }
    }
    let baselines: Vec<&Baseline> = trunk
        .iter()
        .filter(|b| {
            let keep = in_range(b.eff_ts) || Some(&b.version) == head.as_ref();
            if !keep {
                hidden_before += 1;
            }
            keep
        })
        .collect();

    // Rows: newest first; at the same time a baseline sits above events.
    let mut items: Vec<Item> = baselines.iter().map(|b| Item::Baseline(b)).collect();
    items.extend(events.iter().map(|e| Item::Event(e)));
    items.sort_by(|a, b| {
        b.ts().cmp(&a.ts()).then_with(|| match (a, b) {
            (Item::Baseline(x), Item::Baseline(y)) => {
                crate::util::compare_versions(&y.version, &x.version)
            }
            (Item::Baseline(_), Item::Event(_)) => std::cmp::Ordering::Less,
            (Item::Event(_), Item::Baseline(_)) => std::cmp::Ordering::Greater,
            (Item::Event(x), Item::Event(y)) => y.id.cmp(&x.id),
        })
    });
    let mut baseline_row: HashMap<&str, usize> = HashMap::new();
    let mut event_row: HashMap<i64, usize> = HashMap::new();
    let mut session_rows: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (row, item) in items.iter().enumerate() {
        match item {
            Item::Baseline(b) => {
                baseline_row.insert(b.version.as_str(), row);
            }
            Item::Event(e) => {
                event_row.insert(e.id, row);
                session_rows
                    .entry(e.session_id.as_str())
                    .or_default()
                    .push(row);
            }
        }
    }

    // Each session's interval of rows: its nodes, its fork and its join; open sessions
    // reach the top.
    struct Span<'a> {
        session: &'a SessionView,
        top: usize,
        bottom: usize,
    }
    let mut spans: Vec<Span> = Vec::new();
    for session in sessions {
        let Some(rows) = session_rows.get(session.id.as_str()) else {
            continue;
        };
        let mut top = *rows.iter().min().unwrap_or(&0);
        let mut bottom = *rows.iter().max().unwrap_or(&0);
        if let Some(row) = session
            .base_version
            .as_deref()
            .and_then(|v| baseline_row.get(v))
        {
            bottom = bottom.max(*row);
            top = top.min(*row);
        }
        if let Some(row) = merge_target(session).and_then(|v| baseline_row.get(v.as_str())) {
            top = top.min(*row);
            bottom = bottom.max(*row);
        }
        if session.is_live() {
            top = 0;
        }
        spans.push(Span {
            session,
            top,
            bottom,
        });
    }
    // Oldest forks first, each in the lowest lane free one row around its interval.
    spans.sort_by(|a, b| {
        b.bottom
            .cmp(&a.bottom)
            .then(a.session.created_at.cmp(&b.session.created_at))
            .then(a.session.id.cmp(&b.session.id))
    });
    let mut lanes: Vec<Vec<(usize, usize)>> = Vec::new();
    let mut lane_of: HashMap<&str, usize> = HashMap::new();
    for span in &spans {
        let free = lanes.iter().position(|taken| {
            taken
                .iter()
                .all(|(top, bottom)| *bottom + 1 < span.top || *top > span.bottom + 1)
        });
        let lane = match free {
            Some(index) => index,
            None => {
                lanes.push(Vec::new());
                lanes.len() - 1
            }
        };
        lanes[lane].push((span.top, span.bottom));
        lane_of.insert(span.session.id.as_str(), lane + 1);
    }

    let handoffs = handoff_states(trunk, by_id, settings, all_events);
    let mut nodes = Vec::with_capacity(items.len());
    for (row, item) in items.iter().enumerate() {
        nodes.push(match item {
            Item::Baseline(b) => GraphNode {
                id: format!("b:{}", b.version),
                lane: 0,
                row,
                ts: b.eff_ts,
                color: 0,
                kind: "baseline",
                session_id: None,
                version: Some(b.version.clone()),
                label: Some(format!("v{}", b.version)),
                event_type: None,
                event_id: None,
                actor: None,
                source: Some(b.source.clone()),
                head: Some(&b.version) == head.as_ref(),
                handoff: handoffs.get(&b.version).copied(),
                by_session: b.by_session.clone(),
            },
            Item::Event(e) => {
                let session = by_id.get(e.session_id.as_str());
                GraphNode {
                    id: format!("e:{}", e.id),
                    lane: lane_of.get(e.session_id.as_str()).copied().unwrap_or(1),
                    row,
                    ts: e.ts,
                    color: session.map_or(0, |s| s.color),
                    kind: node_kind(e),
                    session_id: Some(e.session_id.clone()),
                    version: e.version.clone(),
                    label: (!e.summary.is_empty()).then(|| one_line(&e.summary, 120)),
                    event_type: Some(e.kind.clone()),
                    event_id: Some(e.id),
                    actor: Some(e.actor.clone()),
                    source: None,
                    head: false,
                    handoff: None,
                    by_session: None,
                }
            }
        });
    }

    let mut edges = Vec::new();
    // Trunk: older baseline → newer one.
    let mut trunk_nodes: Vec<&GraphNode> = nodes.iter().filter(|n| n.kind == "baseline").collect();
    trunk_nodes.sort_by_key(|n| std::cmp::Reverse(n.row));
    for pair in trunk_nodes.windows(2) {
        edges.push(GraphEdge {
            from: pair[0].id.clone(),
            to: pair[1].id.clone(),
            kind: "trunk",
            color: 0,
        });
    }
    let mut tails = Vec::new();
    let mut ordered: Vec<&Span> = spans.iter().collect();
    ordered.sort_by(|a, b| {
        a.session
            .created_at
            .cmp(&b.session.created_at)
            .then(a.session.id.cmp(&b.session.id))
    });
    let shown_ids: HashSet<i64> = events.iter().map(|e| e.id).collect();
    let mut by_session: HashMap<&str, Vec<&EventView>> = HashMap::new();
    for event in &events {
        by_session
            .entry(event.session_id.as_str())
            .or_default()
            .push(event);
    }
    // Reports that may have changed another session, by (session, time).
    let mut sources: HashMap<(&str, Ms), Vec<&EventView>> = HashMap::new();
    for event in all_events {
        if event.actor == "agent" && matches!(event.kind.as_str(), "sync" | "applied" | "release") {
            sources
                .entry((event.session_id.as_str(), event.ts))
                .or_default()
                .push(event);
        }
    }
    for span in ordered {
        let session = span.session;
        let color = session.color;
        // Already in time order: the events were read ordered by time.
        let Some(own) = by_session.get(session.id.as_str()) else {
            continue;
        };
        let Some(first) = own.first() else {
            continue;
        };
        if let Some(base) = session.base_version.as_deref() {
            if baseline_row.contains_key(base) {
                edges.push(GraphEdge {
                    from: format!("b:{base}"),
                    to: format!("e:{}", first.id),
                    kind: "branch",
                    color,
                });
            }
        }
        for pair in own.windows(2) {
            edges.push(GraphEdge {
                from: format!("e:{}", pair[0].id),
                to: format!("e:{}", pair[1].id),
                kind: "branch",
                color,
            });
        }
        for event in own {
            if event.kind == "release" {
                if let Some(v) = event.data["version"]
                    .as_str()
                    .filter(|v| baseline_row.contains_key(v))
                {
                    edges.push(GraphEdge {
                        from: format!("e:{}", event.id),
                        to: format!("b:{v}"),
                        kind: "merge",
                        color,
                    });
                }
            }
            if event.kind == "sync" && event.actor == "agent" {
                if let Some(v) = event.data["to"]
                    .as_str()
                    .filter(|v| baseline_row.contains_key(v))
                {
                    edges.push(GraphEdge {
                        from: format!("b:{v}"),
                        to: format!("e:{}", event.id),
                        kind: "handoff",
                        color,
                    });
                }
            }
            // A report of another session that changed this one (absorbs, sync, applied).
            if let Some(by) = event.data["by"].as_str() {
                let source = sources
                    .get(&(by, event.ts))
                    .and_then(|found| found.iter().find(|s| shown_ids.contains(&s.id)));
                if let Some(source) = source {
                    edges.push(GraphEdge {
                        from: format!("e:{}", source.id),
                        to: format!("e:{}", event.id),
                        kind: "handoff",
                        color: by_id.get(by).map_or(color, |s| s.color),
                    });
                }
            }
        }
        // Join: from the newest merge event to the baseline it went into, unless the
        // session released that baseline itself (the release line already reaches it).
        if session.status == "merged" {
            if let Some(into) =
                merge_target(session).filter(|v| baseline_row.contains_key(v.as_str()))
            {
                let released_itself = trunk.iter().any(|b| {
                    b.version == into && b.by_session.as_deref() == Some(session.id.as_str())
                });
                if let Some(merge) = own.iter().rev().find(|e| is_merge(e)) {
                    if !released_itself {
                        edges.push(GraphEdge {
                            from: format!("e:{}", merge.id),
                            to: format!("b:{into}"),
                            kind: "merge",
                            color,
                        });
                    }
                }
            }
        }
        if session.is_live() {
            let newest = own
                .iter()
                .filter_map(|e| event_row.get(&e.id))
                .min()
                .copied()
                .unwrap_or(0);
            tails.push(GraphTail {
                session_id: session.id.clone(),
                lane: lane_of.get(session.id.as_str()).copied().unwrap_or(1),
                row: newest,
                color,
            });
        }
    }
    let from = start.unwrap_or_else(|| items.iter().map(Item::ts).min().unwrap_or(now));
    Graph {
        lanes: lanes.len() + 1,
        rows: items.len(),
        nodes,
        edges,
        tails,
        from,
        to: now,
        hidden_before,
    }
}

fn merge_target(session: &SessionView) -> Option<String> {
    vocab::is_terminal(&session.status)
        .then(|| session.merged_into.clone())
        .flatten()
}
