//! Whether a client's connection still reaches this ledger: the executable its owned hooks and
//! its user-level MCP entry run, whether that executable can write this database, and when
//! data from the client last arrived. Read-only: the database is opened read-only, and the
//! executables only answer `call info` with the Ledger turned off, so nothing is created or
//! migrated by checking.

use crate::external::Client;
use crate::util::Ms;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The MCP server name both clients register.
pub const SERVER: &str = "gitrochi-ledger";

/// A command older than the database answers quickly; a slow first launch (a malware scan)
/// leaves `canWrite` unknown instead of failing the check.
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

/// One executable a client runs for this ledger.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandCheck {
    pub path: PathBuf,
    pub exists: bool,
    pub executable: bool,
    /// The newest storage schema the executable writes, from its own `call info`.
    pub writes_schema: Option<i64>,
    pub version: Option<String>,
    /// False when the database is newer than the executable, which then refuses every write.
    pub can_write: Option<bool>,
    /// The database the client passes it; for MCP without `--db`, the per-user default.
    pub db_path: Option<PathBuf>,
    pub same_database: Option<bool>,
}

/// The client's user-level MCP registration, where it can be read.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpCheck {
    pub config_path: PathBuf,
    pub registered: bool,
    pub command: Option<CommandCheck>,
}

/// Additive fields of the integrate status.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    pub hook_command: Option<CommandCheck>,
    pub mcp: McpCheck,
    /// `PRAGMA user_version` of this database; null when it does not exist yet.
    pub database_schema: Option<i64>,
    /// The newest passive observation from a session bound to this client.
    pub last_observed_at: Option<Ms>,
    /// The newest agent report from a session bound to this client.
    pub last_report_at: Option<Ms>,
    /// not_installed | ok | no_data_yet | incomplete | outdated_command | missing_command | other_database
    pub health: &'static str,
}

/// Claude Code's `~/.claude.json` (user scope) or Codex's `~/.codex/config.toml`.
pub fn default_mcp_config(client: Client, home: &Path) -> PathBuf {
    match client {
        Client::Claude => home.join(".claude.json"),
        Client::Codex => home.join(".codex").join("config.toml"),
    }
}

/// The checks behind `integrate --status`. `hooks` are the owned hook commands.
pub fn check(
    client: Client,
    hooks: &[String],
    complete: bool,
    mcp_config: &Path,
    database: &Path,
) -> Health {
    let database_schema = schema_of(database);
    let mut probes = HashMap::new();
    let mut checks: Vec<CommandCheck> = hooks
        .iter()
        .filter_map(|command| parse_hook(command))
        .map(|(cli, db)| {
            let same = db.as_deref().map(|db| same_file(db, database));
            inspect(&cli, db, same, database_schema, &mut probes)
        })
        .collect();
    // Owned hooks normally share one executable; when they differ, the worst one speaks for all.
    checks.sort_by_key(severity);
    let hook_command = checks.pop();
    let registered = registration(client, mcp_config);
    let mcp = McpCheck {
        config_path: mcp_config.to_path_buf(),
        registered: registered.is_some(),
        command: registered.flatten().map(|(command, db)| {
            let resolved = db.clone().unwrap_or_else(home_default_db);
            let same = Some(same_file(&resolved, database));
            inspect(
                Path::new(&command),
                Some(resolved),
                same,
                database_schema,
                &mut probes,
            )
        }),
    };
    let (last_observed_at, last_report_at) = last_data(database, client);
    let health = classify(
        !hooks.is_empty(),
        complete,
        hook_command.as_ref(),
        &mcp,
        last_observed_at.or(last_report_at).is_some(),
    );
    Health {
        hook_command,
        mcp,
        database_schema,
        last_observed_at,
        last_report_at,
        health,
    }
}

fn severity(check: &CommandCheck) -> u8 {
    match classify_command(check) {
        Some("missing_command") => 3,
        Some("outdated_command") => 2,
        Some(_) => 1,
        None => 0,
    }
}

fn classify_command(check: &CommandCheck) -> Option<&'static str> {
    if !check.exists || !check.executable {
        Some("missing_command")
    } else if check.can_write == Some(false) {
        Some("outdated_command")
    } else if check.same_database == Some(false) {
        Some("other_database")
    } else {
        None
    }
}

/// Overall state, the most urgent problem first. MCP reports cannot be attributed to a client,
/// so an MCP-only connection is never called "no data yet".
fn classify(
    hooks: bool,
    complete: bool,
    hook: Option<&CommandCheck>,
    mcp: &McpCheck,
    has_data: bool,
) -> &'static str {
    if !hooks && !mcp.registered {
        return "not_installed";
    }
    let problems: Vec<&str> = [hook, mcp.command.as_ref()]
        .into_iter()
        .flatten()
        .filter_map(classify_command)
        .collect();
    for problem in ["missing_command", "outdated_command", "other_database"] {
        if problems.contains(&problem) {
            return problem;
        }
    }
    if hooks && !complete {
        "incomplete"
    } else if hooks && !has_data {
        "no_data_yet"
    } else {
        "ok"
    }
}

fn inspect(
    path: &Path,
    db_path: Option<PathBuf>,
    same_database: Option<bool>,
    database_schema: Option<i64>,
    probes: &mut HashMap<PathBuf, Option<(i64, Option<String>)>>,
) -> CommandCheck {
    let exists = path.is_file();
    let executable = exists && is_executable(path);
    let probe = if executable {
        probes
            .entry(path.to_path_buf())
            .or_insert_with(|| probe(path))
            .clone()
    } else {
        None
    };
    let writes_schema = probe.as_ref().map(|(schema, _)| *schema);
    CommandCheck {
        path: path.to_path_buf(),
        exists,
        executable,
        writes_schema,
        version: probe.and_then(|(_, version)| version),
        can_write: writes_schema
            .zip(database_schema)
            .map(|(writes, has)| writes >= has),
        db_path,
        same_database,
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// Every gitrochi-ledger build answers `call info` without opening the database while the
/// Ledger is turned off, and names the newest schema it writes in `dbSchema`.
fn probe(path: &Path) -> Option<(i64, Option<String>)> {
    let mut command = Command::new(path);
    command
        .args(["--json", "call", "info"])
        .env("GITROCHI_LEDGER", "0")
        .env_remove("GITROCHI_LEDGER_DB")
        .env_remove("GITROCHI_LEDGER_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW: a check from the app must not flash a console.
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().ok()?;
    let deadline = Instant::now() + PROBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut output = String::new();
    child
        .stdout
        .take()?
        .take(65_536)
        .read_to_string(&mut output)
        .ok()?;
    let info: Value = serde_json::from_str(output.trim()).ok()?;
    Some((
        info["dbSchema"].as_i64()?,
        info["version"].as_str().map(str::to_string),
    ))
}

/// The executable and `--db` of an owned hook command, as `integrations` writes it: POSIX
/// shell quoting, or PowerShell's after `& `.
pub fn parse_hook(command: &str) -> Option<(PathBuf, Option<PathBuf>)> {
    let (powershell, rest) = match command.strip_prefix("& ") {
        Some(rest) => (true, rest),
        None => (false, command),
    };
    let words = words(rest, powershell)?;
    let cli = words.first().filter(|w| !w.is_empty())?;
    Some((
        PathBuf::from(cli),
        flag(&words[1..], "--db").map(PathBuf::from),
    ))
}

fn flag(words: &[String], name: &str) -> Option<String> {
    let mut items = words.iter();
    while let Some(word) = items.next() {
        if word == name {
            return items.next().cloned();
        }
        if let Some(value) = word.strip_prefix(name).and_then(|v| v.strip_prefix('=')) {
            return Some(value.to_string());
        }
    }
    None
}

fn words(text: &str, powershell: bool) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut chars = text.chars().peekable();
    loop {
        while chars.next_if(|c| c.is_whitespace()).is_some() {}
        if chars.peek().is_none() {
            return Some(words);
        }
        let mut word = String::new();
        while let Some(c) = chars.next_if(|c| !c.is_whitespace()) {
            match c {
                '\'' => loop {
                    match chars.next()? {
                        '\'' if powershell && chars.peek() == Some(&'\'') => {
                            chars.next();
                            word.push('\'');
                        }
                        '\'' => break,
                        other => word.push(other),
                    }
                },
                '"' if !powershell => loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => word.push(chars.next()?),
                        other => word.push(other),
                    }
                },
                '\\' if !powershell => word.push(chars.next()?),
                other => word.push(other),
            }
        }
        words.push(word);
    }
}

/// `Some(None)` is a registration without a local command (a remote server).
fn registration(client: Client, config: &Path) -> Option<Option<(String, Option<PathBuf>)>> {
    let text = fs::read_to_string(config).ok()?;
    let root = match client {
        Client::Claude => serde_json::from_str::<Value>(&text).ok()?,
        Client::Codex => crate::toml_lite::parse(&text)?,
    };
    let key = match client {
        Client::Claude => "mcpServers",
        Client::Codex => "mcp_servers",
    };
    let server = root.get(key)?.get(SERVER)?;
    let Some(command) = server["command"].as_str().filter(|c| !c.is_empty()) else {
        return Some(None);
    };
    let args: Vec<String> = server["args"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let db = flag(&args, "--db").or_else(|| {
        server["env"]["GITROCHI_LEDGER_DB"]
            .as_str()
            .filter(|v| !v.is_empty())
            .map(str::to_string)
    });
    Some(Some((command.to_string(), db.map(PathBuf::from))))
}

/// The database a server started without `--db` opens: the per-user default, since clients
/// do not pass the app's environment.
fn home_default_db() -> PathBuf {
    crate::db::data_dir().join("ledger").join("ledger.sqlite3")
}

fn same_file(a: &Path, b: &Path) -> bool {
    if let (Ok(a), Ok(b)) = (fs::canonicalize(a), fs::canonicalize(b)) {
        return a == b;
    }
    let text = |p: &Path| {
        let text = p.to_string_lossy().replace('\\', "/");
        if cfg!(windows) {
            text.to_lowercase()
        } else {
            text
        }
    };
    text(a) == text(b)
}

fn read_only(database: &Path) -> Option<Connection> {
    if !database.is_file() {
        return None;
    }
    let connection = Connection::open_with_flags(
        database,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    connection.busy_timeout(Duration::from_secs(1)).ok()?;
    Some(connection)
}

fn schema_of(database: &Path) -> Option<i64> {
    read_only(database)?
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .ok()
}

/// Sessions bound to the client through `links.observer` (their passive observations and
/// their agents' reports).
fn last_data(database: &Path, client: Client) -> (Option<Ms>, Option<Ms>) {
    let Some(connection) = read_only(database) else {
        return (None, None);
    };
    connection
        .query_row(
            "WITH bound AS (
                 SELECT id, last_agent_at FROM sessions
                 WHERE json_valid(links) AND json_extract(links, '$.observer.client') = ?1)
             SELECT (SELECT MAX(e.ts) FROM events e JOIN bound b ON e.session_id = b.id
                     WHERE e.channel = 'observer'),
                    (SELECT MAX(last_agent_at) FROM bound)",
            [client.key()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .ok()
        .flatten()
        .unwrap_or((None, None))
}

/// A sentence for the CLI's text output; JSON callers read the fields.
pub fn describe(health: &Health) -> Option<String> {
    let culprit = [health.hook_command.as_ref(), health.mcp.command.as_ref()]
        .into_iter()
        .flatten()
        .find(|c| classify_command(c) == Some(health.health));
    Some(match (health.health, culprit) {
        ("missing_command", Some(c)) => {
            format!("{} is missing or not executable.", c.path.display())
        }
        ("outdated_command", Some(c)) => format!(
            "{} writes schema {}, but this ledger has schema {}; it refuses every write.",
            c.path.display(),
            c.writes_schema.unwrap_or_default(),
            health.database_schema.unwrap_or_default()
        ),
        ("other_database", Some(c)) => format!(
            "{} writes to another database: {}.",
            c.path.display(),
            c.db_path.as_deref().unwrap_or(Path::new("")).display()
        ),
        ("incomplete", _) => "Some owned hooks are missing; install again.".into(),
        ("no_data_yet", _) => "No activity from this client has reached the ledger yet.".into(),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_commands_give_back_the_quoted_paths() {
        let (cli, db) =
            parse_hook("'/tmp/a'\\''b/$x' --db '/tmp/my db' observe claude Stop --managed-hook")
                .unwrap();
        assert_eq!(cli, PathBuf::from("/tmp/a'b/$x"));
        assert_eq!(db, Some(PathBuf::from("/tmp/my db")));
        let (cli, db) =
            parse_hook("& 'C:/a''b/cli.exe' --db 'C:/db' observe codex Stop --managed-hook")
                .unwrap();
        assert_eq!(cli, PathBuf::from("C:/a'b/cli.exe"));
        assert_eq!(db, Some(PathBuf::from("C:/db")));
        assert_eq!(
            parse_hook("/bin/cli --db=/x observe claude Stop")
                .unwrap()
                .1,
            Some(PathBuf::from("/x"))
        );
        assert!(parse_hook("'unterminated --db x").is_none());
    }

    fn command(exists: bool, can_write: Option<bool>, same: Option<bool>) -> CommandCheck {
        CommandCheck {
            path: "/x".into(),
            exists,
            executable: exists,
            writes_schema: None,
            version: None,
            can_write,
            db_path: None,
            same_database: same,
        }
    }

    #[test]
    fn health_names_the_most_urgent_problem() {
        let none = McpCheck {
            config_path: "/c".into(),
            registered: false,
            command: None,
        };
        let ok = command(true, Some(true), Some(true));
        assert_eq!(classify(false, false, None, &none, false), "not_installed");
        assert_eq!(classify(true, true, Some(&ok), &none, false), "no_data_yet");
        assert_eq!(classify(true, true, Some(&ok), &none, true), "ok");
        assert_eq!(classify(true, false, Some(&ok), &none, true), "incomplete");
        let stale = command(true, Some(false), Some(true));
        assert_eq!(
            classify(true, true, Some(&stale), &none, true),
            "outdated_command"
        );
        let mcp = McpCheck {
            config_path: "/c".into(),
            registered: true,
            command: Some(command(false, None, Some(true))),
        };
        assert_eq!(
            classify(true, true, Some(&stale), &mcp, true),
            "missing_command"
        );
        let other = command(true, Some(true), Some(false));
        assert_eq!(
            classify(true, true, Some(&other), &none, true),
            "other_database"
        );
        let mcp_only = McpCheck {
            command: Some(ok.clone()),
            ..mcp
        };
        assert_eq!(classify(false, false, None, &mcp_only, false), "ok");
    }
}
