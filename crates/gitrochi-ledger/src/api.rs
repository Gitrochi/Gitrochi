//! The one dispatcher behind the C ABI and the Tauri command (the apps), the CLI's `call`
//! and MCP (agents). Who may call what depends on the entry point, never on the request:
//! a person's operations exist only for the apps.

use crate::backup;
use crate::baseline;
use crate::db::{self, Db};
use crate::error::{Error, Result};
use crate::event;
use crate::graph;
use crate::human;
use crate::import;
use crate::prompts;
use crate::report;
use crate::search;
use crate::settings::{self, Settings};
use crate::text;
use crate::util::{self, arg_str, arg_str_any, now_ms};
use crate::views::{self, Range, API_SCHEMA};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

/// Where a call comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caller {
    /// The macOS and Windows apps: a person is at the controls.
    App,
    /// The CLI and the MCP server: an agent, or someone acting like one.
    Agent,
    /// The hook handler (wave 2): prompts only.
    Hook,
}

/// Every method, with the callers allowed to use it.
pub const METHODS: [(&str, &[Caller]); 24] = [
    ("info", &[Caller::App, Caller::Agent, Caller::Hook]),
    ("rev", &[Caller::App, Caller::Agent, Caller::Hook]),
    ("state", &[Caller::App, Caller::Agent]),
    ("session", &[Caller::App, Caller::Agent]),
    ("graph", &[Caller::App, Caller::Agent]),
    ("search", &[Caller::App, Caller::Agent]),
    ("attention", &[Caller::App, Caller::Agent]),
    ("overview", &[Caller::App, Caller::Agent]),
    ("report", &[Caller::App, Caller::Agent]),
    ("import", &[Caller::App, Caller::Agent]),
    ("scan", &[Caller::App, Caller::Agent]),
    ("register_baseline", &[Caller::App, Caller::Agent]),
    ("backup", &[Caller::App, Caller::Agent]),
    ("settings", &[Caller::App, Caller::Agent, Caller::Hook]),
    ("projects", &[Caller::App, Caller::Agent]),
    ("human", &[Caller::App]),
    ("prompt_answer", &[Caller::App]),
    ("prompt_review", &[Caller::App]),
    ("settings_set", &[Caller::App]),
    ("project_set", &[Caller::App]),
    ("prompt_create", &[Caller::App, Caller::Hook]),
    ("prompt_get", &[Caller::App, Caller::Hook]),
    ("prompt_resolve", &[Caller::App, Caller::Hook]),
    ("prompt_expire", &[Caller::App, Caller::Hook]),
];

/// The database for a call: `args.db` when given (tests and tools), else the default.
pub fn db_path(args: &Value) -> PathBuf {
    match arg_str(args, "db") {
        Some(path) => PathBuf::from(path),
        None => db::default_db_path(),
    }
}

/// The apps' entry point (C ABI, Tauri): the result, or `{"error": {code, message}}`.
pub fn call(method: &str, args: &Value) -> Value {
    match call_as(Caller::App, method, args) {
        Ok(value) => value,
        Err(error) => json!({"error": error.to_json()}),
    }
}

pub fn call_as(caller: Caller, method: &str, args: &Value) -> Result<Value> {
    let empty = json!({});
    let args = if args.is_null() { &empty } else { args };
    if !args.is_object() {
        return Err(Error::invalid("Arguments are a JSON object"));
    }
    let Some((_, allowed)) = METHODS.iter().find(|(name, _)| *name == method) else {
        return Err(Error::invalid(format!("Unknown method: {method}")));
    };
    if !allowed.contains(&caller) {
        return Err(Error::not_allowed(format!(
            "{method} is for the Gitrochi apps only; agents cannot confirm, answer or change settings"
        )));
    }
    let path = db_path(args);
    if method == "info" {
        return info(&path);
    }
    if !db::enabled() {
        return Err(Error::new(
            "DISABLED",
            "The ledger is turned off (GITROCHI_LEDGER=0)",
        ));
    }
    let db = db::shared(&path)?;
    dispatch(&db, caller, method, args)
}

fn info(path: &std::path::Path) -> Result<Value> {
    let enabled = db::enabled();
    let rev = if enabled { db::shared(path)?.rev()? } else { 0 };
    Ok(json!({
        "schemaVersion": API_SCHEMA,
        "dbPath": path.to_string_lossy(),
        "rev": rev,
        "enabled": enabled,
        "dbSchema": db::DB_SCHEMA,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

fn settings_of(db: &Db) -> Result<Settings> {
    db.read(Settings::load)
}

fn range(args: &Value) -> Result<Range> {
    Range::parse(arg_str(args, "range").as_deref())
}

/// Runs one method on an open database.
pub fn dispatch(db: &Arc<Db>, caller: Caller, method: &str, args: &Value) -> Result<Value> {
    let now = now_ms();
    match method {
        "rev" => Ok(json!({"rev": db.rev()?})),
        "state" => {
            let project = arg_str(args, "project");
            if let Some(project) = &project {
                let _ = baseline::refresh(db, project, false);
            }
            let range = range(args)?;
            db.read(|c| {
                let settings = Settings::load(c)?;
                let rev = db::rev(c)?;
                views::to_value(&views::state(
                    c,
                    &settings,
                    project.as_deref(),
                    range,
                    rev,
                    now,
                )?)
            })
        }
        "session" => {
            let id = arg_str_any(args, &["id", "sessionId", "session"])
                .ok_or_else(|| Error::invalid("Missing id"))?;
            db.read(|c| {
                let settings = Settings::load(c)?;
                views::to_value(&views::session_detail(c, &settings, &id, now)?)
            })
        }
        "graph" => {
            let project =
                arg_str(args, "project").ok_or_else(|| Error::invalid("Missing project"))?;
            let options = graph::Options {
                range: range(args)?,
                key_only: util::arg_bool(args, "keyOnly").unwrap_or(false),
                include_archived: util::arg_bool(args, "includeArchived").unwrap_or(false),
            };
            db.read(|c| {
                let settings = Settings::load(c)?;
                views::to_value(&graph::graph(c, &settings, &project, &options, now)?)
            })
        }
        "search" => {
            let query = arg_str(args, "query").ok_or_else(|| Error::invalid("Missing query"))?;
            let limit = util::arg_i64(args, "limit")?.unwrap_or(50).clamp(1, 500) as usize;
            let project = arg_str(args, "project");
            db.read(|c| Ok(json!({"hits": search::search(c, &query, project.as_deref(), limit)?})))
        }
        "attention" => {
            let project = arg_str(args, "project");
            db.read(|c| {
                let settings = Settings::load(c)?;
                let snapshot = views::snapshot(c, &settings, project.as_deref(), now)?;
                let questions = views::open_questions(c, project.as_deref())?.len() as i64;
                let review = prompts::list(c, project.as_deref(), &["auto"], true)?.len() as i64;
                let attention = views::attention_of(&snapshot.views, questions, review);
                Ok(json!({"rev": db::rev(c)?, "attention": attention}))
            })
        }
        "overview" => {
            overview(db, args, now).map(|(text, data)| json!({"text": text, "data": data}))
        }
        "report" => report_json(&report(db, args, channel(caller, args))?),
        "import" => {
            let text = args["text"]
                .as_str()
                .ok_or_else(|| Error::invalid("Missing text"))?;
            let settings = settings_of(db)?;
            let results = import::import(
                db,
                &settings,
                text,
                arg_str(args, "project").as_deref(),
                now,
            )?;
            Ok(json!({"results": results}))
        }
        "scan" => {
            let projects: Vec<String> = match arg_str(args, "project") {
                Some(project) => vec![project],
                None => {
                    db.read(|c| Ok(baseline::projects(c)?.into_iter().map(|p| p.key).collect()))?
                }
            };
            let mut results = Vec::new();
            for project in projects {
                results.push(baseline::refresh(db, &project, true)?);
            }
            Ok(json!({"results": results}))
        }
        "register_baseline" => {
            let project =
                arg_str(args, "project").ok_or_else(|| Error::invalid("Missing project"))?;
            let version = arg_str(args, "version")
                .and_then(|v| util::parse_version(&v))
                .filter(|v| v != "latest")
                .ok_or_else(|| Error::invalid("Give a version number (for example 1.4.2)"))?;
            let note = arg_str(args, "note").unwrap_or_default();
            let (_, rev) = db.write(|c| baseline::register(c, &project, &version, &note, now))?;
            Ok(json!({"ok": true, "rev": rev, "project": project, "version": version}))
        }
        "backup" => {
            let keep = match util::arg_i64(args, "keep")? {
                Some(keep) => keep.clamp(1, 365) as u32,
                None => settings_of(db)?.backup_keep,
            };
            let daily = util::arg_bool(args, "daily").unwrap_or(false);
            views::to_value(&backup::run(db, now, keep, daily)?)
        }
        "settings" => db.read(|c| Ok(Settings::load(c)?.to_json())),
        "projects" => db.read(|c| Ok(json!({"projects": baseline::projects(c)?}))),
        "human" => {
            let (_, rev) = db.write(|c| {
                let settings = Settings::load(c)?;
                human::apply(c, &settings, args, now)
            })?;
            Ok(json!({"ok": true, "rev": rev}))
        }
        "settings_set" => {
            let values = args["values"]
                .as_object()
                .ok_or_else(|| {
                    Error::invalid("Give values: {staleHours?, kinds?, autoContinue?, backupKeep?}")
                })?
                .clone();
            let (settings, rev) = db.write(|c| {
                settings::store(c, &values, now)?;
                Settings::load(c)
            })?;
            Ok(json!({"ok": true, "rev": rev, "settings": settings.to_json()}))
        }
        "project_set" => {
            let (project, rev) = db.write(|c| baseline::set_project(c, args, now))?;
            Ok(json!({"ok": true, "rev": rev, "project": project}))
        }
        "prompt_create" => {
            let (prompt, rev) = db.write(|c| prompts::create(c, args, now))?;
            Ok(json!({"ok": true, "rev": rev, "prompt": prompt}))
        }
        "prompt_get" => {
            let id = util::arg_i64(args, "id")?.ok_or_else(|| Error::invalid("Missing id"))?;
            db.read(|c| views::to_value(&prompts::get(c, id)?))
        }
        "prompt_answer" => {
            let ((ok, prompt), rev) = db.write(|c| prompts::answer(c, args, now))?;
            Ok(json!({"ok": ok, "rev": rev, "state": prompt.state, "prompt": prompt}))
        }
        "prompt_resolve" => {
            let ((ok, prompt), rev) = db.write(|c| prompts::resolve(c, args, now))?;
            Ok(json!({"ok": ok, "rev": rev, "state": prompt.state, "prompt": prompt}))
        }
        "prompt_expire" => {
            let (expired, rev) = db.write(|c| prompts::expire(c, now))?;
            Ok(json!({"ok": true, "rev": rev, "expired": expired}))
        }
        "prompt_review" => {
            let (reviewed, rev) = db.write(|c| prompts::review(c, args, now))?;
            Ok(json!({"ok": true, "rev": rev, "reviewed": reviewed}))
        }
        other => Err(Error::invalid(format!("Unknown method: {other}"))),
    }
}

fn channel(caller: Caller, args: &Value) -> &'static str {
    match (caller, arg_str(args, "channel").as_deref()) {
        (_, Some("mcp")) => "mcp",
        (_, Some("cli")) => "cli",
        (Caller::App, _) => "app",
        (Caller::Hook, _) => "hook",
        (Caller::Agent, _) => "cli",
    }
}

/// A report's result as every caller sees it: the reply plus the text for agents.
pub fn report_json(reply: &report::ReportReply) -> Result<Value> {
    let mut value = views::to_value(reply)?;
    value["text"] = json!(text::report(reply));
    Ok(value)
}

/// Scans the report's project (throttled), then records it.
pub fn report(db: &Db, args: &Value, channel: &str) -> Result<report::ReportReply> {
    if let Some(project) = db.read(|c| report::project_of(c, args))? {
        let _ = baseline::refresh(db, &project, false);
    }
    let now = now_ms();
    let (reply, _) = db.write(|c| {
        let settings = Settings::load(c)?;
        report::report(c, &settings, args, channel, now, now)
    })?;
    Ok(reply)
}

/// The overview for agents, delivering messages only when `deliver` and a session are
/// given (the session asking for its own messages).
pub fn overview(db: &Db, args: &Value, now: i64) -> Result<(String, Value)> {
    let session = arg_str_any(args, &["session", "sessionId"]);
    let deliver = util::arg_bool(args, "deliver").unwrap_or(false);
    let project = db.read(|c| {
        views::overview_project(c, arg_str(args, "project").as_deref(), session.as_deref())
    })?;
    if let Some(project) = &project {
        let _ = baseline::refresh(db, project, false);
    }
    let messages = match (&session, deliver) {
        (Some(id), true) => deliver_to(db, id, now)?,
        _ => Vec::new(),
    };
    db.read(|c| {
        let settings = Settings::load(c)?;
        let data = views::overview(c, &settings, project.as_deref(), messages, now)?;
        Ok((text::overview(&data, now), views::to_value(&data)?))
    })
}

/// Delivers the session's waiting messages (a write only when there are any).
pub fn deliver_to(db: &Db, session_id: &str, now: i64) -> Result<Vec<event::Message>> {
    let waiting = db.read(|c| {
        Ok(crate::session::load(c, session_id)?.is_some() && event::waiting(c, session_id)? > 0)
    })?;
    if !waiting {
        return Ok(Vec::new());
    }
    Ok(db.write(|c| event::deliver(c, session_id, now))?.0)
}

/// The session detail text for agents; with `deliver`, the session's own messages too.
pub fn session_text(db: &Db, id: &str, deliver: bool) -> Result<(String, Value)> {
    let now = now_ms();
    let messages = if deliver {
        deliver_to(db, id, now)?
    } else {
        Vec::new()
    };
    db.read(|c| {
        let settings = Settings::load(c)?;
        let detail = views::session_detail(c, &settings, id, now)?;
        let mut data = views::to_value(&detail)?;
        data["messages"] = views::to_value(&messages)?;
        Ok((text::session(&detail, &messages, now), data))
    })
}
