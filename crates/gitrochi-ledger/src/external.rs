//! Passive local-client activity. No prompts, transcripts, tool arguments, results or decisions.

use crate::db::{self, Db, OpenOptions};
use crate::event::{self, NewEvent};
use crate::hook::HookResult;
use crate::session::{self, SessionRow};
use crate::track;
use crate::util::{self, Ms};
use crate::{Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

/// The local client whose hooks supplied the activity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Client {
    Claude,
    Codex,
}

impl Client {
    /// Accepts the two supported local providers.
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "claude" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            _ => Err(Error::invalid("Client must be claude or codex")),
        }
    }

    /// Stable configuration and session-binding key.
    pub fn key(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    /// Provider label for observed activity.
    pub fn title(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
        }
    }

    /// Passive lifecycle events, without permission or continuation hooks.
    pub fn events(self) -> &'static [&'static str] {
        match self {
            Self::Claude => &[
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "PostToolUseFailure",
                "Stop",
                "StopFailure",
                "SessionEnd",
            ],
            Self::Codex => &[
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "Stop",
                "Interrupt",
                "SessionEnd",
            ],
        }
    }
}

/// Only the database and existing app-issued session come from the environment.
#[derive(Clone, Debug)]
pub struct ObserverEnv {
    pub db: PathBuf,
    pub session: Option<String>,
    pub enabled: bool,
}

impl ObserverEnv {
    /// Reads the switches shared with the existing launch-only hook.
    pub fn from_process(db: Option<PathBuf>) -> Self {
        Self {
            db: db.unwrap_or_else(db::default_db_path),
            session: std::env::var("GITROCHI_LEDGER_SESSION")
                .ok()
                .and_then(|v| util::clean(&v)),
            enabled: db::enabled(),
        }
    }
}

fn identifier(value: &Value) -> Option<String> {
    value.as_str().and_then(util::clean).filter(|v| {
        v.len() <= 200
            && v.chars()
                .all(|c| c.is_alphanumeric() || "._-:/".contains(c))
    })
}

/// All observer failures fail open. SessionStart context carries an ID, never permission.
pub fn run(client: Client, event: &str, input: &str, env: &ObserverEnv) -> HookResult {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !env.enabled || !client.events().contains(&event) || input.len() > 1_048_576 {
            return Ok(HookResult::default());
        }
        let raw: Value = serde_json::from_str(input)
            .map_err(|_| Error::invalid("Observer input must be a JSON object"))?;
        if !raw.is_object() {
            return Err(Error::invalid("Observer input must be a JSON object"));
        }
        observe(client, event, &raw, env)
    }));
    match result {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => HookResult {
            stderr: format!("gitrochi-ledger observe: {}; no decision", error.message),
            ..HookResult::default()
        },
        Err(_) => HookResult {
            stderr: "gitrochi-ledger observe: activity could not be recorded; no decision".into(),
            ..HookResult::default()
        },
    }
}

fn find(connection: &Connection, client: Client, id: &str) -> Result<Option<SessionRow>> {
    let sql = format!(
        "SELECT {} FROM sessions WHERE
         (json_extract(links, '$.observer.client') = ?1
          AND json_extract(links, '$.observer.sessionId') = ?2)
         OR (?1 = 'claude' AND json_extract(links, '$.agentSessionId') = ?2)
         ORDER BY last_at DESC, id LIMIT 1",
        session::COLUMNS
    );
    Ok(connection
        .query_row(&sql, params![client.key(), id], SessionRow::from_row)
        .optional()?)
}

fn existing(
    connection: &Connection,
    client: Client,
    id: &str,
    issued: Option<&str>,
) -> Result<Option<SessionRow>> {
    if let Some(issued) = issued {
        if !util::valid_session_id(issued) {
            return Err(Error::invalid(
                "GITROCHI_LEDGER_SESSION is not a session ID",
            ));
        }
        return session::require(connection, issued).map(Some);
    }
    find(connection, client, id)
}

fn plan(db: &Db, client: Client, raw: &Value) -> Result<track::Plan> {
    let cwd = raw["cwd"]
        .as_str()
        .filter(|v| {
            v.len() <= 4096 && !v.chars().any(char::is_control) && Path::new(v).is_absolute()
        })
        .ok_or_else(|| Error::invalid("Observer needs an absolute cwd"))?;
    let repo = crate::git::checkout(Path::new(cwd))
        .map(|c| c.root)
        .unwrap_or_else(|| cwd.into());
    let folder = Path::new(&repo)
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("External work");
    let mut args = json!({
        "cwd": cwd, "repoPath": repo,
        "title": format!("{}: {}", client.title(), folder),
        "kind": "other", "autoContinue": {"enabled": false, "delaySec": 30}
    });
    if Path::new(&repo).file_name().is_none() {
        args["project"] = json!("External work");
    }
    track::plan(db, &args)
}

fn summary(client: Client, event: &str, tool: Option<&str>) -> String {
    let action = match event {
        "SessionStart" => "Session started",
        "UserPromptSubmit" => "Turn started",
        "PreToolUse" => "Using tool",
        "PostToolUse" => "Tool finished",
        "PostToolUseFailure" => "Tool failed",
        "Stop" => "Turn stopped",
        "StopFailure" => "Turn failed",
        "Interrupt" => "Turn interrupted",
        "SessionEnd" => "Session ended",
        _ => "Activity",
    };
    match tool {
        Some(tool) => format!("{}: {action} — {tool}", client.title()),
        None => format!("{}: {action}", client.title()),
    }
}

fn observe(client: Client, event: &str, raw: &Value, env: &ObserverEnv) -> Result<HookResult> {
    let client_id = identifier(&raw["session_id"])
        .or_else(|| identifier(&raw["thread_id"]))
        .ok_or_else(|| Error::invalid("Observer input has no valid session ID"))?;
    let db = Db::open_with(&env.db, OpenOptions::hook())?;
    let known = db.read(|c| existing(c, client, &client_id, env.session.as_deref()))?;
    let prepared = if known.is_none() {
        Some(plan(&db, client, raw)?)
    } else {
        None
    };
    let tool = identifier(&raw["tool_name"]);
    let call = identifier(&raw["tool_use_id"]);
    let turn = identifier(&raw["turn_id"]);
    let agent = identifier(&raw["agent_id"]);
    let now = util::now_ms();
    let ((id, project), _) = db.write(|c| {
        // Recheck under BEGIN IMMEDIATE: concurrent first hooks create exactly one row.
        let row = match existing(c, client, &client_id, env.session.as_deref())? {
            Some(row) => row,
            None => track::create_observed(
                c,
                prepared
                    .as_ref()
                    .ok_or_else(|| Error::conflict("Session binding changed"))?,
                now,
                client.title(),
                client.key(),
            )?,
        };
        record(
            c,
            &row,
            client,
            &client_id,
            event,
            tool.as_deref(),
            call.as_deref(),
            turn.as_deref(),
            agent.as_deref(),
            now,
        )?;
        Ok((row.id, row.project))
    })?;
    let stdout = if event == "SessionStart" && agent.is_none() {
        let fields = if project.len() <= 200 {
            json!({"session": id, "project": project})
        } else {
            json!({"session": id})
        };
        let context = format!(
            "Gitrochi Ledger observes this local {} session. \
             If ledger_report is available, send a start report with {} and \
             a short title and the appropriate kind; send milestone progress, question and done \
             reports as the work changes. Include this session ID explicitly. \
             Hook activity is not an agent report and does not mark work complete.",
            client.title(),
            fields
        );
        json!({"hookSpecificOutput": {
            "hookEventName": "SessionStart", "additionalContext": context
        }})
        .to_string()
    } else {
        String::new()
    };
    Ok(HookResult {
        stdout,
        ..HookResult::default()
    })
}

#[allow(clippy::too_many_arguments)]
fn record(
    connection: &Connection,
    row: &SessionRow,
    client: Client,
    client_id: &str,
    event: &str,
    tool: Option<&str>,
    call: Option<&str>,
    turn: Option<&str>,
    agent: Option<&str>,
    now: Ms,
) -> Result<()> {
    let mut metadata = json!({"client": client.key(), "sessionId": client_id, "event": event});
    for (key, value) in [
        ("tool", tool),
        ("toolUseId", call),
        ("turnId", turn),
        ("agentId", agent),
    ] {
        if let Some(value) = value {
            metadata[key] = json!(value);
        }
    }
    let previous = &row.links["observer"];
    let duplicate = (call.is_some() || turn.is_some()) && previous == &metadata;
    let mut links: Map<String, Value> = row.links.as_object().cloned().unwrap_or_default();
    links.insert("observer".into(), metadata.clone());
    if client == Client::Claude {
        links.insert("agentSessionId".into(), json!(client_id));
    }
    connection.execute(
        "UPDATE sessions SET last_at = MAX(last_at, ?2), links = ?3 WHERE id = ?1",
        params![row.id, now, Value::Object(links).to_string()],
    )?;
    if !duplicate {
        event::insert(
            connection,
            &NewEvent {
                session_id: &row.id,
                project: &row.project,
                ts: now,
                kind: "hook",
                actor: "hook",
                summary: &summary(client, event, tool),
                body: None,
                version: None,
                artifacts: &json!([]),
                data: &json!({"hook": event, "observer": metadata}),
                channel: "observer",
                delivered_at: Some(now),
            },
        )?;
    }
    Ok(())
}
