//! User settings edits on temporary files only; existing callbacks and trust are preserved.

mod common;

#[cfg(unix)]
use common::stdout;
use common::{app, binary, cli, json_of, stderr, Schemas, TempDir};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};

fn integrate(db: &Path, config: &Path, client: &str, action: &str) -> Output {
    // Never the developer's own MCP settings: a file beside the fixture, usually absent.
    let mcp = config.with_file_name("mcp-fixture");
    integrate_with(db, config, &mcp, client, action, &[])
}

fn integrate_with(
    db: &Path,
    config: &Path,
    mcp: &Path,
    client: &str,
    action: &str,
    extra: &[&str],
) -> Output {
    let mut args = vec![
        "--json",
        "integrate",
        client,
        action,
        "--config",
        config.to_str().unwrap(),
        "--mcp-config",
        mcp.to_str().unwrap(),
    ];
    args.extend_from_slice(extra);
    cli(db, &args)
}

fn this_cli() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_gitrochi-ledger"))
}

/// A build from before the database's schema: it answers `call info` as every build does.
#[cfg(unix)]
fn stale_cli(dir: &TempDir) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("old build/gitrochi-ledger");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let info = r#"{"schemaVersion":1,"dbPath":"x","rev":0,"enabled":false,"dbSchema":1,"version":"0.0.1"}"#;
    std::fs::write(
        &path,
        format!("#!/bin/sh\n[ \"$GITROCHI_LEDGER\" = 0 ] || exit 3\necho '{info}'\n"),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

// Only the stale-command check calls it, and that needs a shell script for a command
#[cfg_attr(not(unix), allow(dead_code))]
fn observe(db: &Path, cwd: &Path) {
    let mut child = binary()
        .args([
            "--db",
            db.to_str().unwrap(),
            "observe",
            "claude",
            "SessionStart",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let input = json!({"session_id": "health-01", "cwd": cwd}).to_string();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());
}

fn existing_claude() -> Value {
    let events = [
        "Notification",
        "PermissionRequest",
        "PostToolUse",
        "PreToolUse",
        "SessionEnd",
        "SessionStart",
        "Stop",
        "StopFailure",
        "SubagentStop",
        "UserPromptSubmit",
    ];
    let mut value = json!({"hooks": {}, "permissions": {"deny": ["Read(.env)"]}, "env": {"UNCHANGED": "private fixture"}, "disableAllHooks": false});
    for event in events {
        value["hooks"][event] = json!([{"matcher": "", "hooks": [{"type": "command", "command": format!("existing-{event}")}]}]);
    }
    value["hooks"]["PreToolUse"].as_array_mut().unwrap().extend([
        json!({"matcher": "Bash", "hooks": [{"type": "command", "command": "existing-guard"}]}),
        json!({"matcher": "Write", "hooks": [{"type": "command", "command": "existing-style"}]}),
    ]);
    value["hooks"]["PreCompact"] = json!([]);
    value["hooks"]["PostToolUseFailure"] = json!([{"hooks": []}]);
    value
}

#[test]
fn preserves_twelve_existing_handlers_and_backs_up_then_removes_only_owned_entries() {
    let dir = TempDir::new("claude-integration");
    let db = dir.join("ledger.sqlite3");
    let config = dir.join("settings with spaces.json");
    let original = existing_claude();
    let original_bytes = serde_json::to_vec_pretty(&original).unwrap();
    std::fs::write(&config, &original_bytes).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o640)).unwrap();
    }
    let output = integrate(&db, &config, "claude", "--install");
    assert!(output.status.success(), "{}", stderr(&output));
    let result = json_of(&output);
    assert_eq!(result["installed"], true);
    assert_eq!(result["otherHookCount"], 12);
    assert_eq!(result["ownedHookCount"], 8);
    assert_eq!(result["verification"], "configuration_only");
    assert_eq!(result["requiresClientTrust"], false);
    let backup = Path::new(result["backupPath"].as_str().unwrap());
    assert_eq!(std::fs::read(backup).unwrap(), original_bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(&config).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
    let installed: Value = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
    assert_eq!(installed["permissions"], original["permissions"]);
    assert_eq!(installed["env"], original["env"]);
    assert_eq!(
        installed["hooks"]["PermissionRequest"],
        original["hooks"]["PermissionRequest"]
    );
    assert_eq!(
        installed["hooks"]["PreToolUse"][0],
        original["hooks"]["PreToolUse"][0]
    );
    assert_eq!(
        installed["hooks"]["PreToolUse"][1],
        original["hooks"]["PreToolUse"][1]
    );
    assert_eq!(
        installed["hooks"]["PreToolUse"][2],
        original["hooks"]["PreToolUse"][2]
    );
    let bytes = std::fs::read(&config).unwrap();
    let again = json_of(&integrate(&db, &config, "claude", "--install"));
    assert!(again["backupPath"].is_null());
    assert_eq!(std::fs::read(&config).unwrap(), bytes);
    let status = json_of(&integrate(&db, &config, "claude", "--status"));
    assert_eq!(status["installed"], true);
    assert!(status["backupPath"].is_null());
    let removed = json_of(&integrate(&db, &config, "claude", "--remove"));
    assert_eq!(removed["installed"], false);
    assert_eq!(removed["ownedHookCount"], 0);
    assert_eq!(removed["otherHookCount"], 12);
    let after: Value = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
    assert_eq!(after, original);
}

#[test]
fn codex_reports_trust_requirement_without_touching_config_or_trust_hashes() {
    let dir = TempDir::new("codex-integration");
    let db = dir.join("ledger.sqlite3");
    let config = dir.join("hooks.json");
    let trust = dir.join("config.toml");
    std::fs::write(&trust, "existing_trust = \"unchanged\"\n").unwrap();
    std::fs::write(&config, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"existing-stop\"}]}]}}\n").unwrap();
    let output = integrate(&db, &config, "codex", "--install");
    assert!(output.status.success(), "{}", stderr(&output));
    let result = json_of(&output);
    assert_eq!(result["installed"], true);
    assert_eq!(result["requiresClientTrust"], true);
    assert_eq!(result["ownedHookCount"], 7);
    assert_eq!(result["otherHookCount"], 1);
    let hooks: Value = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
    assert!(hooks["hooks"].get("PermissionRequest").is_none());
    assert!(hooks["hooks"].get("PostToolUseFailure").is_none());
    assert_eq!(hooks["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"], 3);
    assert_eq!(
        std::fs::read_to_string(&trust).unwrap(),
        "existing_trust = \"unchanged\"\n"
    );
    let removed = json_of(&integrate(&db, &config, "codex", "--remove"));
    assert_eq!(removed["otherHookCount"], 1);
    assert_eq!(
        std::fs::read_to_string(&trust).unwrap(),
        "existing_trust = \"unchanged\"\n"
    );
}

#[test]
fn status_remove_and_bad_json_do_not_create_or_overwrite_settings() {
    let dir = TempDir::new("integration-errors");
    let db = dir.join("ledger.sqlite3");
    let config = dir.join("absent/hooks.json");
    for action in ["--status", "--remove"] {
        let output = integrate(&db, &config, "codex", action);
        assert!(output.status.success(), "{}", stderr(&output));
        assert_eq!(json_of(&output)["installed"], false);
        assert!(!config.exists());
        assert!(!db.exists());
    }
    std::fs::create_dir_all(config.parent().unwrap()).unwrap();
    std::fs::write(&config, "invalid JSON fixture").unwrap();
    let output = integrate(&db, &config, "codex", "--install");
    assert!(!output.status.success());
    assert_eq!(
        std::fs::read_to_string(&config).unwrap(),
        "invalid JSON fixture"
    );
    assert!(std::fs::read_dir(config.parent().unwrap())
        .unwrap()
        .all(|f| f.unwrap().path() == config));
}

#[test]
fn each_client_removes_only_its_own_marked_handlers() {
    let dir = TempDir::new("integration-ownership");
    let db = dir.join("ledger.sqlite3");
    let config = dir.join("shared-fixture.json");
    assert!(integrate(&db, &config, "claude", "--install")
        .status
        .success());
    assert!(integrate(&db, &config, "codex", "--install")
        .status
        .success());
    let removed = json_of(&integrate(&db, &config, "claude", "--remove"));
    assert_eq!(removed["ownedHookCount"], 0);
    assert_eq!(removed["otherHookCount"], 7);
    assert_eq!(
        json_of(&integrate(&db, &config, "codex", "--status"))["installed"],
        true
    );
}

#[cfg(unix)]
#[test]
fn status_names_a_stale_or_missing_command_and_when_data_last_arrived() {
    let dir = TempDir::new("integration-health");
    let db = dir.join("ledger.sqlite3");
    let config = dir.join("settings.json");
    let mcp = dir.join("claude.json");
    let stale = stale_cli(&dir);
    let schemas = Schemas::load();
    let status = |extra: &[&str], action: &str| {
        json_of(&integrate_with(&db, &config, &mcp, "claude", action, extra))
    };
    let installed = status(&["--cli", stale.to_str().unwrap()], "--install");
    assert_eq!(installed["installed"], true);
    std::fs::write(
        &mcp,
        json!({"numStartups": 3, "mcpServers": {"gitrochi-ledger": {
            "type": "stdio", "command": dir.join("moved/gitrochi-ledger"), "args": ["--db", db, "mcp"]
        }}})
        .to_string(),
    )
    .unwrap();
    let before = (
        std::fs::read(&config).unwrap(),
        std::fs::read(&mcp).unwrap(),
    );

    let current = status(&[], "--status");
    schemas.check("integration-status.schema.json", &current);
    assert_eq!(current["databaseSchema"], 8);
    let hook = &current["hookCommand"];
    assert_eq!(hook["path"], stale.to_str().unwrap());
    assert_eq!(hook["executable"], true);
    assert_eq!(hook["writesSchema"], 1);
    assert_eq!(hook["version"], "0.0.1");
    assert_eq!(hook["canWrite"], false);
    assert_eq!(hook["sameDatabase"], true);
    assert_eq!(current["mcp"]["registered"], true);
    assert_eq!(current["mcp"]["command"]["exists"], false);
    // a missing command outranks an outdated one
    assert_eq!(current["health"], "missing_command");
    assert!(current["lastObservedAt"].is_null() && current["lastReportAt"].is_null());
    let after = (
        std::fs::read(&config).unwrap(),
        std::fs::read(&mcp).unwrap(),
    );
    assert_eq!(after, before, "status must not change client settings");

    let entry = json!({"command": this_cli(), "args": ["--db", db, "mcp"]});
    std::fs::write(
        &mcp,
        json!({"mcpServers": {"gitrochi-ledger": entry}}).to_string(),
    )
    .unwrap();
    let current = status(&[], "--status");
    assert_eq!(current["health"], "outdated_command");
    assert_eq!(current["mcp"]["command"]["canWrite"], true);
    assert_eq!(current["mcp"]["command"]["writesSchema"], 8);
    let text = cli(
        &db,
        &[
            "integrate",
            "claude",
            "--status",
            "--config",
            config.to_str().unwrap(),
            "--mcp-config",
            mcp.to_str().unwrap(),
        ],
    );
    assert!(stdout(&text).contains("writes schema 1, but this ledger has schema 8"));

    let repaired = status(&["--cli", this_cli().to_str().unwrap()], "--install");
    assert_eq!(repaired["health"], "no_data_yet");
    assert_eq!(repaired["hookCommand"]["canWrite"], true);

    let cwd = dir.join("harbor");
    std::fs::create_dir_all(&cwd).unwrap();
    observe(&db, &cwd);
    let current = status(&[], "--status");
    assert_eq!(current["health"], "ok");
    assert!(current["lastObservedAt"].as_i64().unwrap() > 0);
    assert!(current["lastReportAt"].is_null());
    let session = app(&db, "state", json!({"range": "all"}))["sessions"][0]["id"].clone();
    let reported = cli(
        &db,
        &[
            "report",
            "-s",
            session.as_str().unwrap(),
            "-e",
            "progress",
            "-m",
            "Halfway",
        ],
    );
    assert!(reported.status.success(), "{}", stderr(&reported));
    let current = status(&[], "--status");
    assert!(current["lastReportAt"].as_i64() >= current["lastObservedAt"].as_i64());
    // the other client has no data of its own
    let codex = json_of(&integrate_with(
        &db,
        &dir.join("hooks.json"),
        &dir.join("config.toml"),
        "codex",
        "--status",
        &[],
    ));
    schemas.check("integration-status.schema.json", &codex);
    assert_eq!(codex["health"], "not_installed");
    assert!(codex["lastObservedAt"].is_null() && codex["hookCommand"].is_null());
}

#[test]
fn codex_mcp_registration_is_read_from_toml_and_another_database_needs_repair() {
    let dir = TempDir::new("integration-codex-mcp");
    let db = dir.join("ledger.sqlite3");
    let config = dir.join("hooks.json");
    let mcp = dir.join("config.toml");
    let entry = |database: &Path| {
        format!(
            "model = \"fixture\"\n\n[mcp_servers.gitrochi-ledger]\ncommand = {}\nargs = [\n  \"--db\", {},\n  \"mcp\",\n]\n",
            json!(this_cli()),
            json!(database)
        )
    };
    let status = || {
        json_of(&integrate_with(
            &db,
            &config,
            &mcp,
            "codex",
            "--status",
            &[],
        ))
    };
    assert!(cli(&db, &["--json", "call", "info"]).status.success());
    std::fs::write(&mcp, entry(&dir.join("other.sqlite3"))).unwrap();
    let current = status();
    assert_eq!(current["installed"], false);
    assert_eq!(current["mcp"]["registered"], true);
    assert_eq!(
        current["mcp"]["command"]["path"],
        this_cli().to_str().unwrap()
    );
    assert_eq!(current["mcp"]["command"]["sameDatabase"], false);
    assert_eq!(current["health"], "other_database");
    std::fs::write(&mcp, entry(&db)).unwrap();
    // MCP reports cannot be told apart by client, so an MCP-only connection is not "no data yet"
    assert_eq!(status()["health"], "ok");
    std::fs::write(&mcp, "[mcp_servers.gitrochi-ledger\n").unwrap();
    let current = status();
    assert_eq!(current["mcp"]["registered"], false);
    assert_eq!(current["health"], "not_installed");
}

#[test]
fn app_setup_runs_hooks_from_the_stable_command_and_keeps_it_current() {
    let dir = TempDir::new("integration-app");
    let db = dir.join("ledger.sqlite3");
    let stable = dir
        .join("data")
        .join("bin")
        .join(format!("gitrochi-ledger{}", std::env::consts::EXE_SUFFIX));
    let bundled = this_cli();
    let base = json!({"client": "claude", "config": dir.join("settings.json"),
                      "mcpConfig": dir.join("claude.json"), "path": stable});
    let with = |extra: Value| {
        let mut args = base.clone();
        args.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        args
    };
    let schemas = Schemas::load();

    let status = app(&db, "integration_status", base.clone());
    schemas.check("integration-status.schema.json", &status);
    assert_eq!(status["health"], "not_installed");
    let command = json!({"bundled": bundled, "path": stable});
    let refreshed = app(&db, "integration_command", command.clone());
    assert_eq!(refreshed["exists"], false);
    assert!(
        !stable.exists(),
        "a refresh never creates the stable command"
    );

    let installed = app(
        &db,
        "integration_install",
        with(json!({"bundled": bundled})),
    );
    schemas.check("integration-status.schema.json", &installed);
    assert_eq!(installed["installed"], true);
    assert_eq!(installed["cliPath"], json!(stable));
    assert_eq!(installed["hookCommand"]["path"], json!(stable));
    assert_eq!(installed["hookCommand"]["canWrite"], true);
    assert_eq!(installed["health"], "no_data_yet");
    assert_eq!(
        std::fs::read(&stable).unwrap(),
        std::fs::read(&bundled).unwrap()
    );

    let outdated = b"#!/bin/sh\nexit 0\n";
    std::fs::write(&stable, outdated).unwrap();
    let refreshed = app(&db, "integration_command", command.clone());
    assert_eq!(
        (refreshed["refreshed"].clone(), refreshed["current"].clone()),
        (json!(true), json!(true))
    );
    assert_eq!(
        std::fs::read(&stable).unwrap(),
        std::fs::read(&bundled).unwrap()
    );
    let again = app(&db, "integration_command", command);
    assert_eq!(again["refreshed"], false);

    let removed = app(&db, "integration_remove", base.clone());
    assert_eq!(removed["installed"], false);
    assert!(
        stable.exists(),
        "MCP entries may still name the stable command"
    );
    for method in [
        "integration_command",
        "integration_status",
        "integration_install",
        "integration_remove",
    ] {
        let refused = gitrochi_ledger::call_as(gitrochi_ledger::Caller::Agent, method, &base);
        assert_eq!(refused.unwrap_err().code, "NOT_ALLOWED", "{method}");
    }
}

/// A client's own `mcp` command as the real ones behave: it keeps one server, `add` refuses a second one and `remove` a
/// missing one, and every call is logged.
#[cfg(unix)]
fn fake_client(dir: &TempDir, client: &str, config: &Path) -> (PathBuf, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let script = dir.join(&format!("fake-{client}"));
    let log = dir.join(&format!("{client}.log"));
    let (config, log_path) = (config.display(), log.display());
    let entry = if client == "claude" {
        r#"{"mcpServers":{"gitrochi-ledger":{"command":"%s","args":["%s","%s","%s"]}}}"#
    } else {
        r#"[mcp_servers.gitrochi-ledger]\ncommand = "%s"\nargs = ["%s", "%s", "%s"]\n"#
    };
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
printf '%s\n' "$*" >> '{log_path}'
case "$2" in
add)
  [ ! -e '{config}' ] || {{ echo 'MCP server gitrochi-ledger already exists in user config' >&2; exit 1; }}
  while [ "$1" != "--" ]; do shift; done
  shift
  printf '{entry}' "$1" "$2" "$3" "$4" > '{config}'
  ;;
remove)
  [ -e '{config}' ] || {{ echo 'No MCP server named gitrochi-ledger' >&2; exit 1; }}
  rm '{config}'
  ;;
esac
"#
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    (script, log)
}

#[cfg(unix)]
fn client_calls(log: &Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect()
}

#[cfg(unix)]
#[test]
fn set_up_asks_the_client_to_register_and_leaves_a_registration_that_works() {
    for (client, scope, file) in [
        ("claude", "--scope user ", "claude.json"),
        ("codex", "", "config.toml"),
    ] {
        let dir = TempDir::new("integration-mcp");
        let db = dir.join("ledger.sqlite3");
        let stable = dir.join("data").join("bin").join("gitrochi-ledger");
        let mcp_config = dir.join(file);
        let (program, log) = fake_client(&dir, client, &mcp_config);
        let base = json!({"client": client, "config": dir.join("hooks.json"), "mcpConfig": mcp_config,
                          "path": stable, "program": program, "bundled": this_cli()});
        let with = |action: &str| {
            let mut args = base.clone();
            args["action"] = json!(action);
            args
        };
        let schemas = Schemas::load();

        // Nothing registered: the client adds the stable command, told its database as the hooks are.
        let added = app(&db, "integration_mcp", with("register"));
        schemas.check("integration-status.schema.json", &added);
        let add = format!(
            "mcp add {scope}gitrochi-ledger -- {} --db {} mcp",
            stable.display(),
            db.display()
        );
        assert_eq!(client_calls(&log), std::slice::from_ref(&add));
        assert_eq!(added["mcp"]["registered"], true);
        assert_eq!(added["mcp"]["command"]["path"], json!(stable));
        assert_eq!(added["mcp"]["command"]["sameDatabase"], true);
        assert_eq!(added["mcp"]["command"]["canWrite"], true);
        assert_eq!(added["health"], "ok");
        assert!(
            stable.is_file(),
            "the registration names a file that exists"
        );

        // Registering again is free: a registration that works stays, whoever made it.
        app(&db, "integration_mcp", with("register"));
        assert_eq!(client_calls(&log).len(), 1, "a working entry is left alone");

        // A registration that cannot work is replaced, which takes a remove first.
        let gone = dir.join("moved").join("gitrochi-ledger");
        let broken = std::fs::read_to_string(&mcp_config)
            .unwrap()
            .replace(stable.to_str().unwrap(), gone.to_str().unwrap());
        std::fs::write(&mcp_config, broken).unwrap();
        let before = app(&db, "integration_status", base.clone());
        assert_eq!(before["health"], "missing_command");
        let repaired = app(&db, "integration_mcp", with("register"));
        let remove = format!("mcp remove {scope}gitrochi-ledger");
        assert_eq!(
            client_calls(&log)[1..],
            [remove.clone(), add.clone()],
            "add refuses a server that exists"
        );
        assert_eq!(repaired["mcp"]["command"]["path"], json!(stable));
        assert_eq!(repaired["health"], "ok");

        // Remove undoes it, and has nothing to do the second time.
        let removed = app(&db, "integration_mcp", with("remove"));
        assert_eq!(&client_calls(&log)[3..], std::slice::from_ref(&remove));
        assert_eq!(removed["mcp"]["registered"], false);
        assert_eq!(removed["health"], "not_installed");
        app(&db, "integration_mcp", with("remove"));
        assert_eq!(
            client_calls(&log).len(),
            4,
            "remove refuses a missing server"
        );
    }
}

#[test]
fn a_client_that_cannot_register_says_why() {
    let dir = TempDir::new("integration-mcp-fail");
    let db = dir.join("ledger.sqlite3");
    let stable = dir
        .join("data")
        .join("bin")
        .join(format!("gitrochi-ledger{}", std::env::consts::EXE_SUFFIX));
    let mcp_config = dir.join("claude.json");
    let config = dir.join("settings.json");
    let args = |program: Value, action: &str| {
        json!({"client": "claude", "config": config, "mcpConfig": mcp_config, "path": stable, "action": action,
               "program": program, "bundled": this_cli(), "db": db})
    };
    let call = |method: &str, args: &Value| {
        gitrochi_ledger::api::call_as(gitrochi_ledger::api::Caller::App, method, args)
    };

    // Not installed, as with a client that only has a desktop app: the person is told, and can copy the command.
    let missing = dir.join("no-such-client");
    let error = call("integration_mcp", &args(json!(missing), "register")).unwrap_err();
    assert_eq!(error.code, "NOT_FOUND");
    assert!(
        error.message.contains("Claude Code") && error.message.contains("not found"),
        "{}",
        error.message
    );
    assert!(stable.is_file(), "the command to copy names this file");
    assert!(!config.exists(), "the hooks are not this method's business");

    // Only a person's app may run a program.
    let agent = gitrochi_ledger::api::call_as(
        gitrochi_ledger::api::Caller::Agent,
        "integration_mcp",
        &args(json!("/bin/sh"), "register"),
    )
    .unwrap_err();
    assert_eq!(agent.code, "NOT_ALLOWED", "{}", agent.message);
    let unknown = call("integration_mcp", &args(json!(missing), "replace")).unwrap_err();
    assert_eq!(unknown.code, "INVALID_ARGUMENT");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let script = dir.join("failing-client");
        let write = |body: &str| {
            std::fs::write(&script, format!("#!/bin/sh\n{body}\n")).unwrap();
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        };
        write("echo 'Config is read-only' >&2\necho 'second line' >&2\nexit 1");
        let refused = call("integration_mcp", &args(json!(script), "register")).unwrap_err();
        assert_eq!(refused.code, "CLIENT_FAILED");
        assert!(
            refused.message.contains("Config is read-only"),
            "{}",
            refused.message
        );
        assert!(
            !refused.message.contains("second line"),
            "{}",
            refused.message
        );

        // It says it worked, yet the entry is not where the status reads it: the row must not pretend.
        write("exit 0");
        let lost = call("integration_mcp", &args(json!(script), "register")).unwrap_err();
        assert_eq!(lost.code, "CLIENT_FAILED");
        assert!(lost.message.contains("did not keep"), "{}", lost.message);
    }
}
