//! User settings edits on temporary files only; existing callbacks and trust are preserved.

mod common;

use common::{cli, json_of, stderr, TempDir};
use serde_json::{json, Value};
use std::path::Path;
use std::process::Output;

fn integrate(db: &Path, config: &Path, client: &str, action: &str) -> Output {
    cli(
        db,
        &[
            "--json",
            "integrate",
            client,
            action,
            "--config",
            config.to_str().unwrap(),
        ],
    )
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
