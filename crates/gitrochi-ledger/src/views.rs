//! Read views: the apps' state, one session in detail, the attention counts and the
//! overview agents read. None of them delivers messages.

use crate::baseline::{self, Baseline};
use crate::error::{Error, Result};
use crate::event::{self, EventView, QuestionView};
use crate::overlap::{self, Overlap};
use crate::prompts::{self, PendingPrompt};
use crate::session::{self, SessionRow, SessionView, Viewer};
use crate::settings::Settings;
use crate::streams::{self, CycleEvent, StreamCycle};
use crate::util::{Ms, DAY};
use crate::vocab::Verdict;
use rusqlite::Connection;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

pub const API_SCHEMA: i64 = 1;

/// A range of time the views cover: the last 7 days, 30 days, or everything.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Range {
    Days(i64),
    All,
}

impl Range {
    pub fn parse(text: Option<&str>) -> Result<Range> {
        match text.unwrap_or("7d") {
            "7d" => Ok(Range::Days(7)),
            "30d" => Ok(Range::Days(30)),
            "all" => Ok(Range::All),
            other => Err(Error::invalid(format!(
                "range must be 7d, 30d or all (not {other})"
            ))),
        }
    }

    /// The first moment inside the range.
    pub fn start(self, now: Ms) -> Option<Ms> {
        match self {
            Range::Days(days) => Some(now - days * DAY),
            Range::All => None,
        }
    }
}

/// Counts of what needs a person, as the Inbox shows them.
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Attention {
    /// Open questions of sessions that are not archived.
    pub questions: i64,
    /// Finished sessions to confirm or archive.
    pub tidy: i64,
    /// Sessions that are done without a merge decision, or possibly abandoned (streams aside).
    pub decide: i64,
    /// Prompts auto-continue answered that nobody has looked at yet.
    pub auto_review: i64,
    pub total: i64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectEntry {
    pub key: String,
    pub name: String,
    /// Live sessions that are not streams.
    pub open: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_at: Option<Ms>,
}

/// Everything the apps draw (`State` in CONTRACT.md).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub schema_version: i64,
    pub rev: i64,
    pub now: Ms,
    pub projects: Vec<ProjectEntry>,
    pub baselines: Vec<Baseline>,
    pub sessions: Vec<SessionView>,
    pub questions: Vec<QuestionView>,
    pub streams: Vec<StreamCycle>,
    pub overlaps: Vec<Overlap>,
    pub pending_prompts: Vec<PendingPrompt>,
    /// Automatic answers waiting for a person's review.
    pub auto_review: Vec<PendingPrompt>,
    pub attention: Attention,
    /// Archived sessions left out because they are older than the range.
    pub hidden_before: i64,
}

/// The loaded material most views share.
pub struct Snapshot {
    pub trunks: BTreeMap<String, Vec<Baseline>>,
    pub rows: Vec<SessionRow>,
    pub views: Vec<SessionView>,
}

pub fn snapshot(
    connection: &Connection,
    settings: &Settings,
    project: Option<&str>,
    now: Ms,
) -> Result<Snapshot> {
    let mut trunks = baseline::trunks(connection)?;
    if let Some(project) = project {
        trunks.retain(|k, _| k == project);
    }
    let rows = session::list(connection, project)?;
    let counts = session::open_counts(connection, project)?;
    let mut viewers: HashMap<&str, Viewer> = HashMap::new();
    let mut views = Vec::with_capacity(rows.len());
    for row in &rows {
        let viewer = viewers
            .entry(row.project.as_str())
            .or_insert_with(|| Viewer {
                settings,
                versions: trunks
                    .get(&row.project)
                    .map(|t| t.iter().map(|b| b.version.clone()).collect())
                    .unwrap_or_default(),
                now,
            });
        views.push(viewer.view(row, counts.get(&row.id).copied().unwrap_or(0)));
    }
    Ok(Snapshot {
        trunks,
        rows,
        views,
    })
}

/// The cycles of every live stream that is not archived, most recently active first.
pub fn stream_cycles(
    connection: &Connection,
    views: &[SessionView],
    trunks: &BTreeMap<String, Vec<Baseline>>,
) -> Result<Vec<StreamCycle>> {
    let mut streams: Vec<&SessionView> = views
        .iter()
        .filter(|v| v.is_stream() && v.archived_at.is_none())
        .collect();
    streams.sort_by(|a, b| b.last_at.cmp(&a.last_at).then(a.id.cmp(&b.id)));
    let mut out = Vec::new();
    for view in streams {
        out.extend(cycles_for(connection, view, trunks.get(&view.project))?);
    }
    Ok(out)
}

pub fn cycles_for(
    connection: &Connection,
    view: &SessionView,
    trunk: Option<&Vec<Baseline>>,
) -> Result<Vec<StreamCycle>> {
    let Some(stream) = &view.stream else {
        return Ok(Vec::new());
    };
    let released: HashMap<String, String> = trunk
        .into_iter()
        .flatten()
        .filter_map(|b| b.by_session.clone().map(|by| (b.version.clone(), by)))
        .collect();
    let events: Vec<EventView> = event::for_session(connection, &view.id)?
        .into_iter()
        .filter(|e| e.actor == "agent")
        .collect();
    let walk: Vec<CycleEvent> = events
        .iter()
        .map(|e| CycleEvent {
            id: e.id,
            ts: e.ts,
            kind: &e.kind,
            summary: &e.summary,
            data: &e.data,
            artifacts: e.artifact_names(),
        })
        .collect();
    Ok(streams::cycles(
        &view.id,
        &stream.line,
        view.base_version.as_deref(),
        &walk,
        &released,
    ))
}

/// Open questions of sessions that are not archived.
pub fn open_questions(connection: &Connection, project: Option<&str>) -> Result<Vec<QuestionView>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {} FROM questions q JOIN sessions s ON s.id = q.session_id
         WHERE q.state = 'open' AND s.archived_at IS NULL AND (?1 IS NULL OR s.project = ?1)
         ORDER BY q.id",
        event::QUESTION_COLUMNS
            .split(", ")
            .map(|c| format!("q.{c}"))
            .collect::<Vec<_>>()
            .join(", ")
    ))?;
    let rows = statement.query_map([project], QuestionView::from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn attention_of(views: &[SessionView], questions: i64, auto_review: i64) -> Attention {
    let shown = || views.iter().filter(|v| v.archived_at.is_none());
    let tidy = shown()
        .filter(|v| matches!(v.verdict, Verdict::Confirm | Verdict::Expirable))
        .count() as i64;
    let decide = shown()
        .filter(|v| !v.is_stream() && matches!(v.verdict, Verdict::PendingMerge | Verdict::Stale))
        .count() as i64;
    Attention {
        questions,
        tidy,
        decide,
        auto_review,
        total: questions + tidy + decide + auto_review,
    }
}

fn project_entries(connection: &Connection, snapshot: &Snapshot) -> Result<Vec<ProjectEntry>> {
    let mut entries: BTreeMap<String, ProjectEntry> = BTreeMap::new();
    for config in baseline::projects(connection)? {
        entries.insert(
            config.key.clone(),
            ProjectEntry {
                key: config.key,
                name: config.name,
                open: 0,
                head: None,
                last_at: None,
            },
        );
    }
    for view in &snapshot.views {
        let entry = entries
            .entry(view.project.clone())
            .or_insert_with(|| ProjectEntry {
                key: view.project.clone(),
                name: view.project.clone(),
                open: 0,
                head: None,
                last_at: None,
            });
        if view.is_live() && !view.is_stream() {
            entry.open += 1;
        }
        entry.last_at = Some(entry.last_at.map_or(view.last_at, |t| t.max(view.last_at)));
    }
    for (project, trunk) in &snapshot.trunks {
        if let Some(entry) = entries.get_mut(project) {
            entry.head = trunk.last().map(|b| b.version.clone());
        }
    }
    let mut out: Vec<ProjectEntry> = entries.into_values().collect();
    out.sort_by(|a, b| b.last_at.cmp(&a.last_at).then(a.key.cmp(&b.key)));
    Ok(out)
}

/// The apps' view of one project (or all of them).
pub fn state(
    connection: &Connection,
    settings: &Settings,
    project: Option<&str>,
    range: Range,
    rev: i64,
    now: Ms,
) -> Result<State> {
    let snapshot = snapshot(connection, settings, project, now)?;
    let start = range.start(now);
    let mut hidden_before = 0;
    let sessions: Vec<SessionView> = snapshot
        .views
        .iter()
        .filter(|v| {
            let Some(archived) = v.archived_at else {
                return true;
            };
            let keep = start.is_none_or(|s| archived.max(v.last_at) >= s);
            if !keep {
                hidden_before += 1;
            }
            keep
        })
        .cloned()
        .collect();
    let questions = open_questions(connection, project)?;
    let pending = prompts::list(connection, project, &["waiting"], false)?;
    let auto_review = prompts::list(connection, project, &["auto"], true)?;
    let attention = attention_of(
        &snapshot.views,
        questions.len() as i64,
        auto_review.len() as i64,
    );
    let projects = project_entries(connection, &snapshot)?;
    // Without a project, the projects' trunks follow one another in key order.
    let baselines: Vec<Baseline> = snapshot.trunks.values().flatten().cloned().collect();
    Ok(State {
        schema_version: API_SCHEMA,
        rev,
        now,
        projects,
        baselines,
        streams: stream_cycles(connection, &snapshot.views, &snapshot.trunks)?,
        overlaps: overlap::overlaps(&snapshot.views),
        sessions,
        questions,
        pending_prompts: pending,
        auto_review,
        attention,
        hidden_before,
    })
}

/// One session with its whole history (`session` in CONTRACT.md); never delivers.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDetail {
    pub session: SessionView,
    pub events: Vec<EventView>,
    pub questions: Vec<QuestionView>,
    pub overlaps: Vec<Overlap>,
    pub cycles: Vec<StreamCycle>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    /// Messages from a person still waiting for the agent.
    pub waiting_messages: i64,
}

pub fn session_detail(
    connection: &Connection,
    settings: &Settings,
    id: &str,
    now: Ms,
) -> Result<SessionDetail> {
    let row = session::require(connection, id)?;
    let snapshot = snapshot(connection, settings, Some(&row.project), now)?;
    let view = snapshot
        .views
        .iter()
        .find(|v| v.id == row.id)
        .cloned()
        .ok_or_else(|| Error::not_found(format!("No session {id}")))?;
    let trunk = snapshot.trunks.get(&row.project);
    let overlaps = overlap::overlaps(&snapshot.views)
        .into_iter()
        .filter(|o| o.a == row.id || o.b == row.id)
        .collect();
    Ok(SessionDetail {
        cycles: cycles_for(connection, &view, trunk)?,
        head: trunk.and_then(|t| t.last()).map(|b| b.version.clone()),
        events: event::for_session(connection, &row.id)?,
        questions: event::questions_for(connection, &row.id)?,
        waiting_messages: event::waiting(connection, &row.id)?,
        overlaps,
        session: view,
    })
}

/// What agents read at the start of a conversation (`overview` in CONTRACT.md, `data`).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    pub project: Option<String>,
    pub projects: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    pub recent_baselines: Vec<Baseline>,
    /// Live sessions that are not streams.
    pub open: Vec<SessionView>,
    /// Finished sessions a person has not archived yet.
    pub finished: Vec<SessionView>,
    pub shelved: Vec<SessionView>,
    pub streams: Vec<StreamSummary>,
    pub overlaps: Vec<Overlap>,
    pub messages: Vec<event::Message>,
}

/// A stream and its latest cycles, short enough for an agent's context.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamSummary {
    pub session: SessionView,
    pub label: String,
    pub cycles: Vec<StreamCycle>,
}

/// The project an overview is about: the given one, the session's, or the most recently
/// active one.
pub fn overview_project(
    connection: &Connection,
    project: Option<&str>,
    session_id: Option<&str>,
) -> Result<Option<String>> {
    if let Some(project) = project {
        return Ok(Some(project.to_string()));
    }
    if let Some(id) = session_id {
        if let Some(row) = session::load(connection, id)? {
            return Ok(Some(row.project));
        }
    }
    Ok(connection
        .query_row(
            "SELECT project FROM sessions ORDER BY last_at DESC, created_at DESC LIMIT 1",
            [],
            |r| r.get::<_, String>(0),
        )
        .ok())
}

pub fn overview(
    connection: &Connection,
    settings: &Settings,
    project: Option<&str>,
    messages: Vec<event::Message>,
    now: Ms,
) -> Result<Overview> {
    let projects: Vec<String> = baseline::projects(connection)?
        .into_iter()
        .map(|p| p.key)
        .collect();
    let Some(project) = project else {
        return Ok(Overview {
            project: None,
            projects,
            head: None,
            recent_baselines: Vec::new(),
            open: Vec::new(),
            finished: Vec::new(),
            shelved: Vec::new(),
            streams: Vec::new(),
            overlaps: Vec::new(),
            messages,
        });
    };
    let snapshot = snapshot(connection, settings, Some(project), now)?;
    let trunk = snapshot.trunks.get(project).cloned().unwrap_or_default();
    let shown = || snapshot.views.iter().filter(|v| v.archived_at.is_none());
    let mut streams = Vec::new();
    let mut stream_views: Vec<&SessionView> = shown().filter(|v| v.is_stream()).collect();
    stream_views.sort_by(|a, b| b.last_at.cmp(&a.last_at).then(a.id.cmp(&b.id)));
    for view in stream_views {
        let mut cycles = cycles_for(connection, view, Some(&trunk))?;
        cycles.truncate(6);
        for cycle in &mut cycles {
            cycle.event_ids.clear();
        }
        streams.push(StreamSummary {
            label: streams::label(&view.title),
            session: view.clone(),
            cycles,
        });
    }
    Ok(Overview {
        project: Some(project.to_string()),
        projects,
        head: trunk.last().map(|b| b.version.clone()),
        recent_baselines: trunk.iter().rev().take(6).rev().cloned().collect(),
        open: shown()
            .filter(|v| v.is_live() && !v.is_stream())
            .cloned()
            .collect(),
        finished: shown()
            .filter(|v| crate::vocab::is_terminal(&v.status))
            .cloned()
            .collect(),
        shelved: shown().filter(|v| v.status == "shelved").cloned().collect(),
        streams,
        overlaps: overlap::overlaps(&snapshot.views),
        messages,
    })
}

pub fn to_value<T: Serialize>(value: &T) -> Result<Value> {
    serde_json::to_value(value).map_err(|e| Error::new("DATABASE", e.to_string()))
}
