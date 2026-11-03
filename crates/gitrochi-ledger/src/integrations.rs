//! Reversible user-level passive-hook configuration. Client trust is never written here.

use crate::connection::{self, Health};
use crate::external::Client;
use crate::{Error, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

const MARKER: &str = " --managed-hook";
static NEXT: AtomicUsize = AtomicUsize::new(0);

/// The explicit owner operation on passive hook configuration.
#[derive(Clone, Copy, Debug)]
pub enum Action {
    Install,
    Status,
    Remove,
}

impl Action {
    fn key(self) -> &'static str {
        match self {
            Self::Install => "install",
            Self::Status => "status",
            Self::Remove => "remove",
        }
    }
}

/// Counts describe configuration only, never trusted or active hook execution; the connection
/// fields say whether the configured executables can still write this database.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub client: Client,
    pub action: &'static str,
    pub installed: bool,
    pub config_path: PathBuf,
    pub cli_path: PathBuf,
    pub owned_hook_count: usize,
    pub expected_hook_count: usize,
    pub other_hook_count: usize,
    pub backup_path: Option<PathBuf>,
    pub verification: &'static str,
    pub requires_client_trust: bool,
    pub hooks_disabled: bool,
    #[serde(flatten)]
    pub connection: Health,
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| Error::invalid("No user home folder"))
}

/// Per-user hooks only; project and managed settings are never changed.
pub fn default_config(client: Client) -> Result<PathBuf> {
    Ok(home()?
        .join(match client {
            Client::Claude => ".claude",
            Client::Codex => ".codex",
        })
        .join(match client {
            Client::Claude => "settings.json",
            Client::Codex => "hooks.json",
        }))
}

/// The client's user-level MCP settings, read only for status.
pub fn default_mcp_config(client: Client) -> Result<PathBuf> {
    Ok(connection::default_mcp_config(client, &home()?))
}

fn io(error: std::io::Error) -> Error {
    Error::new("IO", error.to_string())
}

fn absolute(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.into())
    } else {
        Ok(std::env::current_dir().map_err(io)?.join(path))
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
fn powershell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn path_text(path: &Path) -> Result<&str> {
    path.to_str()
        .filter(|s| !s.chars().any(char::is_control))
        .ok_or_else(|| Error::invalid("Hook paths must be UTF-8 without control characters"))
}

fn command(cli: &Path, db: &Path, client: Client, event: &str, windows: bool) -> Result<String> {
    let cli = path_text(cli)?;
    let db = path_text(db)?;
    let quote = if windows {
        powershell_quote
    } else {
        shell_quote
    };
    Ok(format!(
        "{}{} --db {} observe {} {}{}",
        if windows { "& " } else { "" },
        quote(cli),
        quote(db),
        client.key(),
        event,
        MARKER
    ))
}

fn handler(cli: &Path, db: &Path, client: Client, event: &str) -> Result<Value> {
    let mut value = json!({"type": "command", "command": command(cli, db, client, event, false)?, "timeout": 3});
    if cfg!(windows) {
        let native = command(cli, db, client, event, true)?;
        match client {
            Client::Claude => {
                value["command"] = json!(native);
                value["shell"] = json!("powershell");
            }
            Client::Codex => value["commandWindows"] = json!(native),
        }
    }
    Ok(value)
}

fn owned(handler: &Value, client: Client) -> bool {
    handler["type"] == "command"
        && ["command", "commandWindows"].iter().any(|key| {
            handler[*key].as_str().is_some_and(|command| {
                command.ends_with(MARKER)
                    && command.contains(&format!(" observe {} ", client.key()))
            })
        })
}

/// The commands of the owned handlers, as this platform's client runs them.
fn owned_commands(value: &Value, client: Client) -> Vec<String> {
    let mut commands = Vec::new();
    let Some(hooks) = value.get("hooks").and_then(Value::as_object) else {
        return commands;
    };
    for group in hooks.values().filter_map(Value::as_array).flatten() {
        for hook in group["hooks"].as_array().into_iter().flatten() {
            if !owned(hook, client) {
                continue;
            }
            let native = cfg!(windows)
                .then(|| hook["commandWindows"].as_str())
                .flatten();
            if let Some(command) = native.or_else(|| hook["command"].as_str()) {
                commands.push(command.to_string());
            }
        }
    }
    commands
}

fn inspect(value: &Value, client: Client) -> Result<(usize, usize, bool)> {
    let mut count = 0;
    let mut other = 0;
    let mut complete = true;
    let hooks = value
        .get("hooks")
        .map(|v| {
            v.as_object()
                .ok_or_else(|| Error::invalid("Settings hooks must be an object"))
        })
        .transpose()?;
    if let Some(hooks) = hooks {
        for groups in hooks.values() {
            for group in groups
                .as_array()
                .ok_or_else(|| Error::invalid("Hook groups must be arrays"))?
            {
                for hook in group["hooks"]
                    .as_array()
                    .ok_or_else(|| Error::invalid("Hook handlers must be arrays"))?
                {
                    if owned(hook, client) {
                        count += 1;
                    } else {
                        other += 1;
                    }
                }
            }
        }
        for event in client.events() {
            complete &= hooks
                .get(*event)
                .and_then(Value::as_array)
                .is_some_and(|groups| {
                    groups.iter().any(|g| {
                        g["hooks"]
                            .as_array()
                            .is_some_and(|h| h.iter().any(|h| owned(h, client)))
                    })
                });
        }
    } else {
        complete = false;
    }
    Ok((count, other, complete))
}

fn remove_owned(value: &mut Value, client: Client) {
    let Some(hooks) = value.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };
    let mut emptied = Vec::new();
    for (event, value) in hooks.iter_mut() {
        let Some(groups) = value.as_array_mut() else {
            continue;
        };
        let mut removed = false;
        groups.retain_mut(|group| {
            let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
                return true;
            };
            let had_owned = handlers.iter().any(|h| owned(h, client));
            removed |= had_owned;
            handlers.retain(|h| !owned(h, client));
            !had_owned || !handlers.is_empty()
        });
        if removed && groups.is_empty() {
            emptied.push(event.clone());
        }
    }
    for event in emptied {
        hooks.remove(&event);
    }
}

/// The apps' `integration_status`, `integration_install` and `integration_remove`
/// (`{client, bundled?, path?, config?, mcpConfig?}`). Hooks the apps install run the stable
/// command, refreshed from the app's `bundled` one first, so moving or updating the app keeps
/// them working; `older` is set when this build cannot write the database.
pub fn app_call(database: &Path, method: &str, args: &Value, older: bool) -> Result<Value> {
    use crate::util::arg_str;
    let client = Client::parse(&arg_str(args, "client").unwrap_or_default())?;
    let path = |key: &str, default: fn(Client) -> Result<PathBuf>| {
        arg_str(args, key)
            .map(|p| Ok(PathBuf::from(p)))
            .unwrap_or_else(|| default(client))
    };
    let config = path("config", default_config)?;
    let mcp_config = path("mcpConfig", default_mcp_config)?;
    let stable = path("path", |_| Ok(crate::stable_command::default_path()))?;
    let action = match method {
        "integration_install" => Action::Install,
        "integration_remove" => Action::Remove,
        _ => Action::Status,
    };
    if let Action::Install = action {
        let bundled = arg_str(args, "bundled").ok_or_else(|| Error::invalid("Missing bundled"))?;
        crate::stable_command::refresh(Path::new(&bundled), &stable, true, older)?;
    }
    Ok(serde_json::to_value(configure(
        client,
        action,
        &config,
        &mcp_config,
        &stable,
        database,
    )?)?)
}

/// Update only owned handlers. No MCP entries, permissions, feature flags or trust hashes change;
/// `mcp_config` is only read.
pub fn configure(
    client: Client,
    action: Action,
    config: &Path,
    mcp_config: &Path,
    cli: &Path,
    database: &Path,
) -> Result<Status> {
    let config = absolute(config)?;
    let mcp_config = absolute(mcp_config)?;
    let cli = absolute(cli)?;
    let database = absolute(database)?;
    let before = match fs::read(&config) {
        Ok(bytes) => Some(bytes),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(io(e)),
    };
    let mut value = match &before {
        Some(bytes) => serde_json::from_slice::<Value>(bytes)
            .map_err(|_| Error::invalid("Settings are not valid JSON; nothing was changed"))?,
        None => json!({}),
    };
    if !value.is_object() {
        return Err(Error::invalid("Settings must be a JSON object"));
    }
    inspect(&value, client)?;
    let original = value.clone();
    match action {
        Action::Status => {}
        Action::Install => {
            if !cli.is_file() {
                return Err(Error::not_found("The observer executable does not exist"));
            }
            remove_owned(&mut value, client);
            let hooks = value
                .as_object_mut()
                .unwrap()
                .entry("hooks")
                .or_insert(json!({}))
                .as_object_mut()
                .unwrap();
            for event in client.events() {
                let groups = hooks
                    .entry(*event)
                    .or_insert(json!([]))
                    .as_array_mut()
                    .unwrap();
                groups.push(json!({"hooks": [handler(&cli, &database, client, event)?]}));
            }
        }
        Action::Remove => remove_owned(&mut value, client),
    }
    let backup_path = if value != original {
        write_config(&config, before.as_deref(), &value)?
    } else {
        None
    };
    let (owned_hook_count, other_hook_count, installed) = inspect(&value, client)?;
    let connection = connection::check(
        client,
        &owned_commands(&value, client),
        installed,
        &mcp_config,
        &database,
    );
    Ok(Status {
        client,
        action: action.key(),
        installed,
        config_path: config,
        cli_path: cli,
        owned_hook_count,
        expected_hook_count: client.events().len(),
        other_hook_count,
        backup_path,
        verification: "configuration_only",
        requires_client_trust: client == Client::Codex,
        hooks_disabled: value["disableAllHooks"].as_bool().unwrap_or(false),
        connection,
    })
}

fn private_file(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).map_err(io)
}

fn write_config(path: &Path, before: Option<&[u8]>, value: &Value) -> Result<Option<PathBuf>> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::invalid("Settings need a parent folder"))?;
    fs::create_dir_all(parent).map_err(io)?;
    let metadata = fs::symlink_metadata(path).ok();
    if metadata
        .as_ref()
        .is_some_and(|m| m.file_type().is_symlink() || !m.is_file() || m.permissions().readonly())
    {
        return Err(Error::not_allowed(
            "Settings must be a writable regular file; nothing was changed",
        ));
    }
    let stamp = format!(
        "{}-{}-{}",
        crate::util::now_ms(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("settings");
    let temporary = parent.join(format!(".{name}.gitrochi-ledger-{stamp}.tmp"));
    let backup = before.map(|_| parent.join(format!("{name}.gitrochi-ledger-{stamp}.bak")));
    let result = (|| {
        let mut file = private_file(&temporary)?;
        let mut bytes = serde_json::to_vec_pretty(value)?;
        bytes.push(b'\n');
        file.write_all(&bytes).map_err(io)?;
        if let Some(metadata) = &metadata {
            file.set_permissions(metadata.permissions()).map_err(io)?;
        }
        file.sync_all().map_err(io)?;
        if let (Some(original), Some(backup)) = (before, &backup) {
            let mut saved = private_file(backup)?;
            saved.write_all(original).map_err(io)?;
            saved.sync_all().map_err(io)?;
        }
        let current = match fs::read(path) {
            Ok(bytes) => Some(bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(io(e)),
        };
        if current.as_deref() != before {
            return Err(Error::conflict(
                "Settings changed during installation; nothing was overwritten",
            ));
        }
        fs::rename(&temporary, path).map_err(io)?;
        Ok(backup.clone())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
        if let Some(backup) = &backup {
            let _ = fs::remove_file(backup);
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_commands_quote_paths_without_interpolating_them() {
        let unix = command(
            Path::new("/tmp/a'b/$x"),
            Path::new("/tmp/db"),
            Client::Claude,
            "Stop",
            false,
        )
        .unwrap();
        assert!(unix.starts_with("'/tmp/a'\\''b/$x' --db '/tmp/db' observe claude Stop"));
        let windows = command(
            Path::new("C:/a'b/cli.exe"),
            Path::new("C:/db"),
            Client::Codex,
            "Stop",
            true,
        )
        .unwrap();
        assert!(windows.starts_with("& 'C:/a''b/cli.exe' --db 'C:/db' observe codex Stop"));
    }
}
