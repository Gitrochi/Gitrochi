//! Sessions for the agents Gitrochi starts (DESIGN.md §7.11). With **Track agents I start**
//! on, the app calls `track` before the launch and gives the agent the session's ID as
//! `GITROCHI_LEDGER_SESSION`, so its hooks and reports land on that session. The title, base
//! and links are Gitrochi's guess from the checkout: the branch, and the newest baseline tag
//! reachable from it. The session stays unreported (no `lastAgentAt`, D13) until its agent
//! reports, and the agent's first report replaces the guess (`report`, through
//! `is_unreported_launch`).

use crate::baseline;
use crate::db::Db;
use crate::error::{Error, Result};
use crate::event::{self, NewEvent};
use crate::git;
use crate::report;
use crate::session::{self, SessionRow};
use crate::settings::{self, Settings};
use crate::util::{self, arg_str, Ms};
use crate::vocab;
use rusqlite::{params, Connection};
use serde_json::{json, Map, Value};
use std::path::Path;

/// `data.hook` of the event `track` records: how a session is known to come from a launch.
pub const LAUNCH: &str = "launch";

const LINK_KEYS: [&str; 5] = ["repoPath", "branch", "worktree", "agentId", "cwd"];

/// What `track` creates, worked out before the write so git runs outside the transaction.
#[derive(Clone, Debug)]
pub struct Plan {
    pub project: String,
    pub title: String,
    /// A version, or `latest` (HEAD at the write).
    pub base: Option<String>,
    pub kind: String,
    pub links: Map<String, Value>,
    pub auto_continue: Option<Value>,
}

/// Reads the arguments and the checkout: `{project?, title?, base?, kind?, repoPath?,
/// branch?, worktree?, agentId?, cwd?, autoContinue?}`. Without `project`, the project bound
/// to `repoPath` in the ledger, else the repository folder's name; without `branch` and
/// `worktree`, what git says about `cwd`; without `title`, the branch (or the folder's name);
/// without `base`, the newest tag reachable from `cwd` that matches the project's pattern,
/// when its baselines come from tags; without `autoContinue`, the repository's policy from
/// the `autoContinue.repositories` setting (`null` = the global default).
pub fn plan(db: &Db, args: &Value) -> Result<Plan> {
    if !args.is_object() {
        return Err(Error::invalid("track takes a JSON object"));
    }
    let mut links = Map::new();
    for key in LINK_KEYS {
        match args.get(key) {
            None | Some(Value::Null) => {}
            Some(Value::String(text)) => {
                if let Some(text) = util::clean(text) {
                    links.insert(key.into(), json!(text));
                }
            }
            Some(_) => return Err(Error::invalid(format!("{key} must be text"))),
        }
    }
    let text = |key: &str| links.get(key).and_then(Value::as_str).map(str::to_string);
    let folder = text("cwd")
        .or_else(|| text("worktree"))
        .or_else(|| text("repoPath"));
    if let Some(checkout) = folder.as_deref().and_then(|f| git::checkout(Path::new(f))) {
        links.entry("worktree").or_insert(json!(checkout.root));
        if let Some(branch) = checkout.branch {
            links.entry("branch").or_insert(json!(branch));
        }
    }
    let text = |key: &str| links.get(key).and_then(Value::as_str).map(str::to_string);
    let project = match arg_str(args, "project") {
        Some(project) => project,
        None => {
            let repo = text("repoPath")
                .or_else(|| text("worktree"))
                .ok_or_else(|| Error::invalid("Give project or repoPath"))?;
            db.read(|c| project_for(c, &repo))?
        }
    };
    let title = arg_str(args, "title")
        .or_else(|| text("branch"))
        .or_else(|| folder.as_deref().and_then(folder_name))
        .unwrap_or_else(|| "(untitled)".into());
    let base =
        match arg_str(args, "base") {
            Some(base) => Some(util::parse_version(&base).ok_or_else(|| {
                Error::invalid(format!("Could not read base '{base}' as a version"))
            })?),
            None => match &folder {
                Some(folder) => reachable_base(db, &project, folder)?,
                None => None,
            },
        };
    let auto_continue = match args.get("autoContinue") {
        Some(Value::Null) => None,
        Some(value) => Some(settings::session_auto_continue(value)?),
        None => match text("repoPath") {
            Some(repo) => db.read(|c| repository_policy(c, &repo))?,
            None => None,
        },
    };
    Ok(Plan {
        project,
        title,
        base,
        kind: arg_str(args, "kind").map_or_else(String::new, |k| vocab::kind(&k)),
        links,
        auto_continue,
    })
}

/// The policy Settings › Ledger keeps for the repository (`autoContinue.repositories`), if any.
fn repository_policy(connection: &Connection, repo: &str) -> Result<Option<Value>> {
    let stored = Settings::load(connection)?.auto_continue;
    let wanted = same_path_key(repo);
    Ok(stored["repositories"]
        .as_object()
        .into_iter()
        .flatten()
        .find(|(path, _)| same_path_key(path) == wanted)
        .and_then(|(_, policy)| settings::session_auto_continue(policy).ok()))
}

/// The project a repository's sessions belong to: the one bound to it, else its folder name.
fn project_for(connection: &Connection, repo: &str) -> Result<String> {
    let wanted = same_path_key(repo);
    for project in baseline::projects(connection)? {
        if project.repo_path.as_deref().map(same_path_key) == Some(wanted.clone()) {
            return Ok(project.key);
        }
    }
    folder_name(repo).ok_or_else(|| Error::invalid(format!("No project for {repo}")))
}

fn same_path_key(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let path = match path.strip_prefix('~') {
        Some(rest) if !home.is_empty() => format!("{home}{rest}"),
        _ => path.to_string(),
    };
    path.trim_end_matches(['/', '\\']).to_string()
}

fn folder_name(path: &str) -> Option<String> {
    Path::new(path.trim_end_matches(['/', '\\']))
        .file_name()
        .and_then(|name| util::clean(&name.to_string_lossy()))
}

/// The newest matching tag reachable from the folder's HEAD, for a project whose baselines
/// come from tags (a project that does not exist yet will, from the repository it is bound
/// to). A git failure (no commits yet, not a repository) leaves the base unset.
fn reachable_base(db: &Db, project: &str, folder: &str) -> Result<Option<String>> {
    let config = db.read(|c| baseline::project(c, project))?;
    let pattern = match &config {
        Some(config) if config.baseline_source != "tags" => return Ok(None),
        Some(config) => config.baseline_pattern.clone(),
        None => baseline::DEFAULT_PATTERN.to_string(),
    };
    Ok(baseline::newest_reachable(Path::new(folder), &pattern).unwrap_or(None))
}

/// Creates the session in one write: active, unreported, its links and policy set, and a
/// `hook` event that says it came from a launch. A project that does not exist yet is bound
/// to `repoPath`, so its tags become its baselines.
pub fn create(connection: &Connection, plan: &Plan, now: Ms) -> Result<SessionRow> {
    connection.execute(
        "INSERT OR IGNORE INTO projects (key, name, repo_path, created_at) VALUES (?1, ?1, ?2, ?3)",
        params![
            plan.project,
            plan.links.get("repoPath").and_then(Value::as_str),
            now
        ],
    )?;
    let base = match plan.base.as_deref() {
        Some("latest") => baseline::head(connection, &plan.project)?,
        other => other.map(str::to_string),
    };
    if let Some(base) = &base {
        baseline::ensure(connection, &plan.project, base, now - 1000)?;
    }
    let id = report::new_id(connection, now)?;
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sessions WHERE project = ?1",
        [&plan.project],
        |r| r.get(0),
    )?;
    connection.execute(
        "INSERT INTO sessions (id, project, kind, title, base_version, base_current,
            base_was_latest, status, links, color, created_at, last_at, auto_continue)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, 'active', ?7, ?8, ?9, ?9, ?10)",
        params![
            id,
            plan.project,
            plan.kind,
            plan.title,
            base,
            (plan.base.as_deref() == Some("latest") && base.is_some()) as i64,
            Value::Object(plan.links.clone()).to_string(),
            count % 8,
            now,
            plan.auto_continue.as_ref().map(Value::to_string),
        ],
    )?;
    let mut data = json!({"hook": LAUNCH});
    if let Some(agent) = plan.links.get("agentId") {
        data["agentId"] = agent.clone();
    }
    if let Some(policy) = &plan.auto_continue {
        data["autoContinue"] = policy.clone();
    }
    event::insert(
        connection,
        &NewEvent {
            session_id: &id,
            project: &plan.project,
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
    session::require(connection, &id)
}

/// A session `track` created whose agent has not reported yet.
pub fn is_unreported_launch(connection: &Connection, row: &SessionRow) -> Result<bool> {
    if row.last_agent_at.is_some() {
        return Ok(false);
    }
    Ok(connection.query_row(
        "SELECT EXISTS (SELECT 1 FROM events WHERE session_id = ?1 AND type = 'hook'
            AND actor = 'hook' AND json_extract(data, '$.hook') = ?2)",
        params![row.id, LAUNCH],
        |r| r.get(0),
    )?)
}

/// The agent named another project than Gitrochi guessed: the session moves there, with a
/// colour from its new project. Its base was a version of the old project's trunk, so it is
/// cleared; the agent's own base, if any, is set after this.
pub fn move_to_project(connection: &Connection, row: &mut SessionRow, project: &str) -> Result<()> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sessions WHERE project = ?1",
        [project],
        |r| r.get(0),
    )?;
    connection.execute(
        "UPDATE sessions SET project = ?2, color = ?3, base_version = NULL, base_current = NULL,
            base_was_latest = 0 WHERE id = ?1",
        params![row.id, project, count % 8],
    )?;
    connection.execute(
        "UPDATE events SET project = ?2 WHERE session_id = ?1",
        params![row.id, project],
    )?;
    row.project = project.to_string();
    row.color = count % 8;
    row.base_version = None;
    row.base_current = None;
    row.base_was_latest = false;
    Ok(())
}

/// The agent's own base replaces Gitrochi's guess.
pub fn set_base(
    connection: &Connection,
    row: &mut SessionRow,
    base: Option<String>,
    was_latest: bool,
) -> Result<()> {
    connection.execute(
        "UPDATE sessions SET base_version = ?2, base_current = ?2, base_was_latest = ?3 WHERE id = ?1",
        params![row.id, base, was_latest as i64],
    )?;
    row.base_version = base.clone();
    row.base_current = base;
    row.base_was_latest = was_latest;
    Ok(())
}
