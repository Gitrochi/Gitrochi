//! Sessions the apps register for the agents they launch while **Track agents I start** is on
//! (DESIGN.md §7.11). The app passes the new ID to the agent as `GITROCHI_LEDGER_SESSION`, so
//! the hooks and the MCP server find the session from the first moment. No agent has reported
//! yet (`lastAgentAt` stays empty), and the agent's own first `start` fills in the title, kind
//! and base the app chose (report.rs).

use crate::baseline;
use crate::error::{Error, Result};
use crate::event::{self, NewEvent};
use crate::human::LINK_KEYS;
use crate::report;
use crate::settings;
use crate::util::{self, arg_str, Ms};
use crate::vocab;
use rusqlite::{params, Connection};
use serde_json::{json, Map, Value};

/// What `track` made: the new session's ID and what the agent should know about the input.
#[derive(Debug)]
pub struct Tracked {
    pub session_id: String,
    pub notices: Vec<String>,
}

/// Registers a session for an agent about to be launched. `args` = `{project, title?, base?,
/// kind?, links?: {repoPath?, branch?, worktree?, cwd?, agentId?}, autoContinue?}`; the title
/// defaults to the branch.
pub fn track(connection: &Connection, args: &Value, now: Ms) -> Result<Tracked> {
    let project = arg_str(args, "project")
        .ok_or_else(|| Error::invalid("A launched agent's session needs a project"))?;
    let mut links = Map::new();
    match &args["links"] {
        Value::Null => {}
        Value::Object(given) => {
            for key in LINK_KEYS {
                match given.get(key) {
                    None | Some(Value::Null) => {}
                    Some(Value::String(text)) => {
                        if let Some(text) = util::clean(text) {
                            links.insert(key.into(), json!(text));
                        }
                    }
                    Some(_) => return Err(Error::invalid(format!("links.{key} must be text"))),
                }
            }
        }
        _ => return Err(Error::invalid("links must be an object")),
    }
    let auto_continue = match args.get("autoContinue") {
        None | Some(Value::Null) => None,
        Some(value) => Some(settings::session_auto_continue(value)?),
    };

    baseline::ensure_project(connection, &project, now)?;
    let head = baseline::head(connection, &project)?;
    let mut notices = Vec::new();
    let (base, was_latest) = match arg_str(args, "base") {
        // a launch without a known base is normal: the agent's start may still give one
        None => (None, false),
        text => report::base_of(
            connection,
            &project,
            head.as_deref(),
            text,
            now,
            &mut notices,
        )?,
    };
    let title = arg_str(args, "title")
        .or_else(|| {
            links
                .get("branch")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| "(untitled)".into());
    let kind = arg_str(args, "kind").map_or_else(String::new, |k| vocab::kind(&k));
    let id = report::new_id(connection, now)?;
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sessions WHERE project = ?1",
        [&project],
        |r| r.get(0),
    )?;
    connection.execute(
        "INSERT INTO sessions (id, project, kind, title, base_version, base_current,
            base_was_latest, status, links, channel, color, created_at, last_at, auto_continue)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, 'active', ?7, 'app', ?8, ?9, ?9, ?10)",
        params![
            id,
            project,
            kind,
            title,
            base,
            was_latest as i64,
            Value::Object(links.clone()).to_string(),
            count % 8,
            now,
            auto_continue.as_ref().map(Value::to_string),
        ],
    )?;
    let mut data = json!({"launch": true});
    if let Some(agent) = links.get("agentId") {
        data["agentId"] = agent.clone();
    }
    event::insert(
        connection,
        &NewEvent {
            session_id: &id,
            project: &project,
            ts: now,
            kind: "hook",
            actor: "hook",
            summary: "Started from Gitrochi",
            body: None,
            version: base.as_deref(),
            artifacts: &json!([]),
            data: &data,
            channel: "app",
            delivered_at: Some(now),
        },
    )?;
    Ok(Tracked {
        session_id: id,
        notices,
    })
}
