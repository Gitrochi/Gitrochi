//! Sessions for the agents Gitrochi starts (DESIGN.md §7.11). With **Track agents I start**
//! on, the app calls `track` before the launch and gives the agent the session's ID as
//! `GITROCHI_LEDGER_SESSION`, so its hooks and reports land on that session. The title, base
//! and links are Gitrochi's guess from the checkout: the branch, and the newest baseline tag
//! reachable from it. The session stays unreported (no `lastAgentAt`, D13) until its agent
//! reports, and the agent's first report replaces the guess (`report`, through
//! `is_unreported_launch`). Until then it turns stale only once its branch has moved on from
//! where it started (`waiting_unreported`).

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
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
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
    /// The commit the agent starts on, from which D13 counts the branch's own commits.
    pub head: Option<String>,
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
    let mut head = None;
    if let Some(checkout) = folder.as_deref().and_then(|f| git::checkout(Path::new(f))) {
        let start = folder.as_deref().and_then(|f| git::start(Path::new(f)));
        // the main checkout is the repository itself; only a linked worktree is worth a link
        if start.as_ref().is_none_or(|s| s.linked) {
            links.entry("worktree").or_insert(json!(checkout.root));
        }
        if let Some(branch) = checkout.branch {
            links.entry("branch").or_insert(json!(branch));
        }
        head = start.and_then(|s| s.head);
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
        head,
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

/// How a folder's path compares: `~` expanded and trailing separators dropped. A Windows
/// path (on Windows, or one with a drive letter or a `\\server` share) also ignores case and
/// takes `\` and `/` as one, as Windows does: a folder picked in Settings comes as
/// `C:\Work\app`, git and the apps send `C:/Work/app`.
fn same_path_key(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let path = match path.strip_prefix('~') {
        Some(rest) if !home.is_empty() => format!("{home}{rest}"),
        _ => path.to_string(),
    };
    let path = path.trim_end_matches(['/', '\\']);
    if cfg!(windows) || is_windows_path(path) {
        path.replace('\\', "/").to_lowercase()
    } else {
        path.to_string()
    }
}

fn is_windows_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    (bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':')
        || path.starts_with(r"\\")
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
    if let Some(head) = &plan.head {
        data["head"] = json!(head);
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

/// D13 for one snapshot: which of `rows` are unreported launches that wait under Unreported,
/// and do not turn stale, while their branch's tip is still the commit their agent started on.
/// One `for-each-ref` per repository answers for all of its launches on a branch; a launch on a
/// detached HEAD asks its own folder. When git cannot tell (a launch that recorded no commit,
/// its folders gone, its branch deleted), the session counts like any other, so nothing that
/// may need a person is hidden; so does a branch reset behind where it started.
pub fn waiting_unreported(
    connection: &Connection,
    rows: &[&SessionRow],
) -> Result<HashSet<String>> {
    let mut tips: HashMap<String, Option<HashMap<String, String>>> = HashMap::new();
    let mut waiting = HashSet::new();
    for row in rows.iter().filter(|r| r.last_agent_at.is_none()) {
        let Some(head) = launch_head(connection, &row.id)? else {
            continue;
        };
        let link = |key: &str| row.links.get(key).and_then(Value::as_str);
        let folder = |keys: &[&str]| {
            keys.iter()
                .filter_map(|key| link(key))
                .find(|f| Path::new(f).is_dir())
                .map(str::to_string)
        };
        let tip = match link("branch") {
            // a branch is the repository's: the repository folder first, so its launches share one call
            Some(branch) => folder(&["repoPath", "worktree", "cwd"]).and_then(|folder| {
                tips.entry(folder)
                    .or_insert_with_key(|f| git::branch_tips(Path::new(f)))
                    .as_ref()
                    .and_then(|tips| tips.get(branch).cloned())
            }),
            None => folder(&["worktree", "cwd"]).and_then(|f| git::head_commit(Path::new(&f))),
        };
        if tip.as_deref() == Some(head.as_str()) {
            waiting.insert(row.id.clone());
        }
    }
    Ok(waiting)
}

/// The commit a launch started on (`data.head` of its `launch` event), if it recorded one.
fn launch_head(connection: &Connection, id: &str) -> Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT json_extract(data, '$.head') FROM events WHERE session_id = ?1
               AND type = 'hook' AND actor = 'hook' AND json_extract(data, '$.hook') = ?2
             ORDER BY id LIMIT 1",
            params![id, LAUNCH],
            |r| r.get(0),
        )
        .optional()?
        .flatten())
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
