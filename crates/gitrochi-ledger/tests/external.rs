//! Passive local-client hooks, run as real processes on isolated databases.

mod common;

use common::{app, binary, json_of, stderr, stdout, Schemas, TempDir};
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;
use std::process::{Output, Stdio};

fn observe(db: &Path, client: &str, event: &str, input: Value, issued: Option<&str>) -> Output {
    let mut command = binary();
    command
        .args(["--db", db.to_str().unwrap(), "observe", client, event])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(issued) = issued {
        command.env("GITROCHI_LEDGER_SESSION", issued);
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.to_string().as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn sessions(db: &Path) -> Vec<Value> {
    app(db, "state", json!({"range": "all"}))["sessions"]
        .as_array()
        .unwrap()
        .clone()
}

#[test]
fn both_clients_bind_resume_record_metadata_and_leave_reporting_semantics_alone() {
    for client in ["claude", "codex"] {
        let dir = TempDir::new(client);
        let db = dir.join("ledger.sqlite3");
        let cwd = dir.join("harbor");
        std::fs::create_dir_all(&cwd).unwrap();
        app(&db, "info", json!({}));
        app(
            &db,
            "settings_set",
            json!({"values": {"autoContinue": {"enabled": true, "delaySec": 30}}}),
        );
        let input = json!({
            "session_id": "client-session-01", "cwd": cwd, "source": "startup",
            "prompt": "PRIVATE_PROMPT_SENTINEL", "transcript_path": "PRIVATE_TRANSCRIPT_SENTINEL",
            "last_assistant_message": "PRIVATE_OUTPUT_SENTINEL",
            "tool_input": {"command": "PRIVATE_ARGUMENT_SENTINEL"}
        });
        let first = observe(&db, client, "SessionStart", input.clone(), None);
        assert!(first.status.success(), "{}", stderr(&first));
        let context = json_of(&first);
        assert!(context["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap()
            .contains("ledger_report"));
        assert!(context.get("decision").is_none());
        let rows = sessions(&db);
        assert_eq!(rows.len(), 1);
        Schemas::load().check("session.schema.json", &rows[0]);
        let id = rows[0]["id"].as_str().unwrap().to_owned();
        assert!(stdout(&first).contains(&id));
        assert_eq!(rows[0]["kind"], "other");
        assert_eq!(rows[0]["status"], "active");
        assert!(rows[0]["lastAgentAt"].is_null());
        assert_eq!(rows[0]["autoContinue"]["enabled"], false);
        let mut resume = input.clone();
        resume["source"] = json!("resume");
        let resumed = observe(&db, client, "SessionStart", resume, None);
        assert!(resumed.status.success());
        assert!(stdout(&resumed).contains(&id));
        assert_eq!(sessions(&db).len(), 1);
        let tool = json!({
            "session_id": "client-session-01", "cwd": cwd, "tool_name": "Edit",
            "tool_use_id": "tool-1", "turn_id": "turn-1",
            "tool_input": {"file_path": "PRIVATE_FILE_SENTINEL", "new_string": "PRIVATE_ARGUMENT_SENTINEL"},
            "tool_response": "PRIVATE_RESULT_SENTINEL"
        });
        let output = observe(&db, client, "PostToolUse", tool.clone(), None);
        assert!(output.status.success());
        assert!(stdout(&output).is_empty());
        let before = app(&db, "session", json!({"id": id}))["events"]
            .as_array()
            .unwrap()
            .len();
        observe(&db, client, "PostToolUse", tool, None);
        assert_eq!(
            app(&db, "session", json!({"id": id}))["events"]
                .as_array()
                .unwrap()
                .len(),
            before
        );
        let stopped = observe(&db, client, "Stop", input.clone(), None);
        assert!(stopped.status.success() && stdout(&stopped).is_empty());
        let ended = observe(&db, client, "SessionEnd", input, None);
        assert!(ended.status.success() && stdout(&ended).is_empty());
        let detail = app(&db, "session", json!({"id": id}));
        assert_eq!(detail["session"]["status"], "active");
        assert!(detail["session"]["lastAgentAt"].is_null());
        assert!(detail.to_string().contains("Tool finished"));
        for secret in [
            "PRIVATE_PROMPT",
            "PRIVATE_TRANSCRIPT",
            "PRIVATE_OUTPUT",
            "PRIVATE_ARGUMENT",
            "PRIVATE_FILE",
            "PRIVATE_RESULT",
        ] {
            assert!(!detail.to_string().contains(secret), "{secret} was stored");
        }
        let launch = detail["events"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["data"]["hook"] == "launch")
            .unwrap();
        assert_eq!(launch["data"]["source"], "external");
        assert_ne!(launch["summary"], "Started from Gitrochi");
        assert_eq!(
            app(&db, "state", json!({"range": "all"}))["attention"]["total"],
            0
        );
        assert!(app(&db, "state", json!({"range": "all"}))["pendingPrompts"]
            .as_array()
            .unwrap()
            .is_empty());
        app(
            &db,
            "report",
            json!({"session": id, "project": "harbor", "event": "start", "kind": "research", "title": "Real report"}),
        );
        assert!(!sessions(&db)[0]["lastAgentAt"].is_null());
        observe(
            &db,
            client,
            "PostToolUse",
            json!({
                "session_id": "client-session-01", "tool_name": "Read", "cwd": cwd
            }),
            None,
        );
        let after_report = sessions(&db);
        assert_eq!(after_report.len(), 1);
        assert_eq!(after_report[0]["title"], "Real report");
        assert_eq!(after_report[0]["kind"], "research");
    }
}

#[test]
fn concurrent_first_hooks_create_one_session_and_providers_do_not_collide() {
    let dir = TempDir::new("concurrent-observers");
    let db = dir.join("ledger.sqlite3");
    let cwd = dir.join("harbor");
    std::fs::create_dir_all(&cwd).unwrap();
    app(&db, "info", json!({}));
    let workers: Vec<_> = (0..6)
        .map(|_| {
            let db = db.clone();
            let cwd = cwd.clone();
            std::thread::spawn(move || {
                observe(
                    &db,
                    "claude",
                    "SessionStart",
                    json!({"session_id": "same-id", "cwd": cwd}),
                    None,
                )
            })
        })
        .collect();
    for worker in workers {
        assert!(worker.join().unwrap().status.success());
    }
    assert_eq!(sessions(&db).len(), 1);
    observe(
        &db,
        "codex",
        "SessionStart",
        json!({"session_id": "same-id", "cwd": cwd}),
        None,
    );
    assert_eq!(sessions(&db).len(), 2);
}

#[test]
fn app_tracked_row_keeps_its_kind_policy_and_report_state() {
    let dir = TempDir::new("reuse-launch");
    let db = dir.join("ledger.sqlite3");
    let cwd = dir.join("harbor");
    std::fs::create_dir_all(&cwd).unwrap();
    let tracked = app(
        &db,
        "track",
        json!({
            "project": "harbor", "cwd": cwd, "kind": "implementation",
            "autoContinue": {"enabled": true, "delaySec": 90}
        }),
    );
    let id = tracked["session"]["id"].as_str().unwrap();
    observe(
        &db,
        "claude",
        "SessionStart",
        json!({"session_id": "real-claude-id", "cwd": cwd}),
        Some(id),
    );
    let rows = sessions(&db);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"], id);
    assert_eq!(rows[0]["kind"], "implementation");
    assert_eq!(rows[0]["autoContinue"]["enabled"], true);
    assert_eq!(rows[0]["autoContinue"]["delaySec"], 90);
    assert!(rows[0]["lastAgentAt"].is_null());
    observe(
        &db,
        "claude",
        "PostToolUse",
        json!({"session_id": "real-claude-id", "tool_name": "Read"}),
        None,
    );
    assert_eq!(sessions(&db).len(), 1);
}

#[test]
fn bad_missing_disabled_and_nonpassive_hooks_never_block_or_create_data() {
    let dir = TempDir::new("observer-fail-open");
    let db = dir.join("missing.sqlite3");
    for (client, event, input) in [
        ("claude", "SessionStart", json!({})),
        ("codex", "Stop", json!({"session_id": "safe"})),
        ("unknown", "SessionStart", json!({})),
        ("claude", "PermissionRequest", json!({"session_id": "safe"})),
    ] {
        let output = observe(&db, client, event, input, None);
        assert!(output.status.success());
        assert!(stdout(&output).is_empty());
    }
    assert!(!db.exists());
    let result = gitrochi_ledger::external::run(
        gitrochi_ledger::external::Client::Claude,
        "SessionStart",
        "invalid",
        &gitrochi_ledger::external::ObserverEnv {
            db,
            session: None,
            enabled: false,
        },
    );
    assert_eq!(result.code, 0);
    assert!(result.stdout.is_empty() && result.stderr.is_empty());
}

fn run_git(dir: &Path, args: &[&str]) {
    let home = dir.join(".fixture-home");
    std::fs::create_dir_all(&home).unwrap();
    let output = std::process::Command::new("git")
        .current_dir(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", home.join("gitconfig"))
        .env("HOME", &home)
        .env("GIT_AUTHOR_NAME", "Fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.com")
        .env("GIT_COMMITTER_NAME", "Fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.com")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", stderr(&output));
}

fn title(client: &str) -> &'static str {
    match client {
        "claude" => "Claude Code",
        _ => "Codex",
    }
}

fn observed(db: &Path, client_session: &str) -> Value {
    sessions(db)
        .into_iter()
        .find(|s| s["links"]["observer"]["sessionId"] == client_session)
        .unwrap()
}

#[test]
fn new_observed_sessions_are_titled_by_client_and_branch_and_older_titles_stay() {
    let dir = TempDir::new("observer-titles");
    let db = dir.join("ledger.sqlite3");
    app(&db, "info", json!({}));
    let repo = dir.join("harbor");
    std::fs::create_dir_all(&repo).unwrap();
    run_git(&repo, &["init", "-q", "-b", "main"]);
    run_git(&repo, &["commit", "-q", "--allow-empty", "-m", "Start"]);
    run_git(&repo, &["switch", "-q", "-c", "feature/foo"]);
    run_git(
        &repo,
        &["worktree", "add", "-q", "--detach", "../harbor-review"],
    );
    let notes = dir.join("notes");
    std::fs::create_dir_all(&notes).unwrap();
    let start = |client: &str, id: &str, cwd: &Path| {
        let input = json!({"session_id": id, "cwd": cwd});
        let output = observe(&db, client, "SessionStart", input, None);
        assert!(output.status.success(), "{}", stderr(&output));
    };

    start("claude", "title-branch", &repo);
    assert_eq!(
        observed(&db, "title-branch")["title"],
        "Claude Code · feature/foo"
    );
    start("codex", "title-detached", &dir.join("harbor-review"));
    assert_eq!(
        observed(&db, "title-detached")["title"],
        "Codex · harbor-review"
    );
    start("claude", "title-folder", &notes);
    assert_eq!(
        observed(&db, "title-folder")["title"],
        "Claude Code · notes"
    );

    // A session titled before this change keeps its title: observing never renames.
    let id = observed(&db, "title-branch")["id"].clone();
    let old = json!({"action": "update", "sessionId": id, "title": "Claude Code: harbor"});
    app(&db, "records", old);
    run_git(&repo, &["switch", "-q", "main"]);
    start("claude", "title-branch", &repo);
    let tool = json!({"session_id": "title-branch", "cwd": repo, "tool_name": "Read"});
    assert!(observe(&db, "claude", "PostToolUse", tool, None)
        .status
        .success());
    assert_eq!(
        observed(&db, "title-branch")["title"],
        "Claude Code: harbor"
    );
}

/// What git calls the checkout at `dir`, which is how links name folders on every platform.
fn top_folder(dir: &Path) -> String {
    let output = std::process::Command::new("git")
        .current_dir(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    stdout(&output).trim().to_string()
}

/// A repository with a branch checked out in a linked worktree, the way Claude Code's and
/// Codex's desktop apps and Gitrochi's own Run agent start most sessions.
fn worktree_fixture(dir: &TempDir) -> (std::path::PathBuf, std::path::PathBuf) {
    let repo = dir.join("harbor");
    std::fs::create_dir_all(&repo).unwrap();
    run_git(&repo, &["init", "-q", "-b", "main"]);
    run_git(&repo, &["commit", "-q", "--allow-empty", "-m", "Start"]);
    run_git(&repo, &["tag", "v1.2.0"]);
    run_git(
        &repo,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "retry",
            "../nimble-otter-1f2e",
        ],
    );
    let worktree = dir.join("nimble-otter-1f2e");
    (repo, worktree)
}

#[test]
fn a_session_in_a_linked_worktree_joins_its_repositorys_project_and_reports_there() {
    for client in ["claude", "codex"] {
        let dir = TempDir::new("observer-worktree");
        let db = dir.join("ledger.sqlite3");
        app(&db, "info", json!({}));
        let (repo, worktree) = worktree_fixture(&dir);
        let start = |id: &str, cwd: &Path| {
            let input = json!({"session_id": id, "cwd": cwd});
            let output = observe(&db, client, "SessionStart", input, None);
            assert!(output.status.success(), "{}", stderr(&output));
            json_of(&output)["hookSpecificOutput"]["additionalContext"]
                .as_str()
                .unwrap()
                .to_string()
        };

        // The first session of a repository may well be one in a worktree.
        let context = start("in-worktree", &worktree);
        assert!(
            context.contains(r#""project":"harbor""#),
            "the agent is told its repository's project: {context}"
        );
        let session = observed(&db, "in-worktree");
        assert_eq!(session["project"], "harbor");
        assert_eq!(session["title"], format!("{} · retry", title(client)));
        assert_eq!(session["baseVersion"], "1.2.0", "a tag of the repository");
        assert_eq!(session["links"]["repoPath"], top_folder(&repo));
        assert_eq!(session["links"]["worktree"], top_folder(&worktree));
        assert_eq!(session["links"]["branch"], "retry");
        Schemas::load().check("session.schema.json", &session);

        // Deep inside the worktree and in the main checkout, it is still the one project.
        let deep = worktree.join("src/deep");
        std::fs::create_dir_all(&deep).unwrap();
        start("deep-in-worktree", &deep);
        start("in-main-checkout", &repo);
        assert_eq!(observed(&db, "deep-in-worktree")["project"], "harbor");
        let main = observed(&db, "in-main-checkout");
        assert_eq!(main["project"], "harbor");
        assert_eq!(main["links"]["repoPath"], top_folder(&repo));
        assert!(main["links"].get("worktree").is_none());

        let projects = app(&db, "projects", json!({}));
        let keys: Vec<&str> = projects["projects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p["key"].as_str().unwrap())
            .collect();
        assert_eq!(keys, ["harbor"], "no project named after the worktree");
        assert_eq!(projects["projects"][0]["repoPath"], top_folder(&repo));

        // The report the context asks for lands there, and the repository's page shows it.
        let id = session["id"].as_str().unwrap();
        let reported = gitrochi_ledger::call_as(
            gitrochi_ledger::Caller::Agent,
            "report",
            &json!({"db": db.to_string_lossy(), "event": "start", "session": id,
                    "project": "harbor", "kind": "implementation", "title": "Retry the upload",
                    "summary": "Started"}),
        )
        .unwrap();
        assert_eq!(reported["session"]["project"], "harbor");
        let page = app(&db, "state", json!({"project": "harbor", "range": "all"}));
        let shown: Vec<&str> = page["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["id"].as_str().unwrap())
            .collect();
        assert_eq!(shown.len(), 3, "every session of the repository: {shown:?}");
        assert!(shown.contains(&id));
    }
}

#[test]
fn a_worktree_joins_the_project_bound_to_its_repository_whatever_its_name() {
    let dir = TempDir::new("observer-bound-worktree");
    let db = dir.join("ledger.sqlite3");
    app(&db, "info", json!({}));
    let (repo, worktree) = worktree_fixture(&dir);
    app(
        &db,
        "project_set",
        json!({"project": "Harbor app", "repoPath": top_folder(&repo)}),
    );
    let input = json!({"session_id": "bound", "cwd": worktree});
    let output = observe(&db, "claude", "SessionStart", input, None);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(observed(&db, "bound")["project"], "Harbor app");
}

#[test]
fn a_session_outside_a_linked_worktree_keeps_its_folder_as_its_project() {
    let dir = TempDir::new("observer-no-worktree");
    let db = dir.join("ledger.sqlite3");
    app(&db, "info", json!({}));
    let notes = dir.join("notes");
    std::fs::create_dir_all(&notes).unwrap();
    let input = json!({"session_id": "plain", "cwd": notes});
    assert!(observe(&db, "claude", "SessionStart", input, None)
        .status
        .success());
    let session = observed(&db, "plain");
    assert_eq!(session["project"], "notes");
    assert!(session["links"].get("worktree").is_none());
}
