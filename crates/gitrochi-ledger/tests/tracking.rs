//! Sessions for agents Gitrochi starts (`track`, DESIGN.md §7.11): created before the launch
//! from the checkout, unreported until the agent reports, and replaced by the agent's own
//! title, base and project on its first report. Other sessions keep the conflict rules.

mod common;

use common::{app, cli, json_of, Schemas, TempDir};
use gitrochi_ledger::Caller;
use serde_json::{json, Value};
use std::path::Path;
use std::process::Command;

fn git(dir: &Path, args: &[&str]) {
    let home = dir.join(".home");
    std::fs::create_dir_all(&home).unwrap();
    let output = Command::new("git")
        .current_dir(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", home.join("gitconfig"))
        .env("HOME", &home)
        .env("GIT_AUTHOR_NAME", "Fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.com")
        .env("GIT_COMMITTER_NAME", "Fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.com")
        .env("GIT_AUTHOR_DATE", "1700000000 +0000")
        .env("GIT_COMMITTER_DATE", "1700000000 +0000")
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A repository named `harbor` with v1.0.0 and v1.1.0 on main, a branch `feature/retry`
/// cut at v1.0.0 in a linked worktree, and a v2.0.0 tag the branch cannot reach.
struct Repo {
    dir: TempDir,
}

impl Repo {
    fn new() -> Repo {
        let dir = TempDir::new("track");
        let repo = dir.join("harbor");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        let commit = |text: &str| {
            std::fs::write(repo.join("a.txt"), text).unwrap();
            git(&repo, &["add", "a.txt"]);
            git(&repo, &["commit", "-q", "-m", text]);
        };
        commit("one");
        git(&repo, &["tag", "v1.0.0"]);
        git(&repo, &["branch", "feature/retry"]);
        commit("two");
        git(&repo, &["tag", "v1.1.0"]);
        git(&repo, &["tag", "nightly"]);
        commit("three");
        git(&repo, &["tag", "v2.0.0"]);
        git(
            &repo,
            &[
                "worktree",
                "add",
                "-q",
                &dir.join("harbor-retry").to_string_lossy(),
                "feature/retry",
            ],
        );
        Repo { dir }
    }

    fn db(&self) -> std::path::PathBuf {
        self.dir.join("ledger.sqlite3")
    }

    fn path(&self, name: &str) -> String {
        self.dir.join(name).to_string_lossy().into_owned()
    }

    /// `track` for an agent in the worktree, as the app sends it.
    fn track(&self, extra: Value) -> Value {
        let mut args = json!({"repoPath": self.path("harbor"), "cwd": self.path("harbor-retry"), "agentId": "agent-1"});
        for (key, value) in extra.as_object().unwrap() {
            args[key] = value.clone();
        }
        app(&self.db(), "track", args)
    }

    fn report(&self, args: Value) -> Value {
        let mut args = args;
        args["db"] = json!(self.db().to_string_lossy());
        gitrochi_ledger::call_as(Caller::Agent, "report", &args).unwrap()
    }

    fn try_report(&self, args: Value) -> gitrochi_ledger::Error {
        let mut args = args;
        args["db"] = json!(self.db().to_string_lossy());
        gitrochi_ledger::call_as(Caller::Agent, "report", &args).unwrap_err()
    }

    fn detail(&self, id: &str) -> Value {
        app(&self.db(), "session", json!({"id": id}))
    }
}

#[test]
fn a_launched_session_is_set_from_the_checkout_and_stays_unreported() {
    let repo = Repo::new();
    let result = repo.track(json!({}));
    assert_eq!(result["ok"], true);
    let session = &result["session"];
    let id = session["id"].as_str().unwrap().to_string();
    assert!(id.starts_with('S') && id.len() == 8, "an issued ID: {id}");
    assert_eq!(session["project"], "harbor", "the repository's folder name");
    assert_eq!(session["title"], "feature/retry", "the branch");
    assert_eq!(
        (
            session["baseVersion"].clone(),
            session["baseCurrent"].clone()
        ),
        (json!("1.0.0"), json!("1.0.0")),
        "the newest matching tag the worktree reaches, not v2.0.0 or nightly"
    );
    assert_eq!(session["status"], "active");
    assert_eq!(session["verdict"], "active");
    assert!(session.get("lastAgentAt").is_none(), "unreported (D13)");
    let links = &session["links"];
    assert_eq!(links["branch"], "feature/retry");
    assert_eq!(links["agentId"], "agent-1");
    assert_eq!(links["repoPath"], repo.path("harbor").as_str());
    assert!(links["worktree"]
        .as_str()
        .unwrap()
        .ends_with("harbor-retry"));
    assert!(session.get("autoContinue").is_none());
    Schemas::load().check("session.schema.json", session);

    // The new project is bound to the repository, so its tags are its baselines.
    let projects = app(&repo.db(), "projects", json!({}));
    let harbor = &projects["projects"][0];
    assert_eq!(
        (harbor["key"].clone(), harbor["repoPath"].clone()),
        (json!("harbor"), json!(repo.path("harbor")))
    );
    let state = app(&repo.db(), "state", json!({"project": "harbor"}));
    let versions: Vec<_> = state["baselines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| {
            (
                b["version"].as_str().unwrap(),
                b["source"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        versions,
        [("1.0.0", "tag"), ("1.1.0", "tag"), ("2.0.0", "tag")]
    );
    assert_eq!(state["attention"]["total"], 0, "nothing for a person yet");

    // One event says where it came from; it is not a message for the agent.
    let detail = repo.detail(&id);
    let events = detail["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(
        (
            events[0]["type"].clone(),
            events[0]["actor"].clone(),
            events[0]["data"]["hook"].clone()
        ),
        (json!("hook"), json!("hook"), json!("launch"))
    );
    assert_eq!(detail["waitingMessages"], 0);

    // The graph has nothing of it to draw yet, and draws the rest as before.
    let graph = app(&repo.db(), "graph", json!({"project": "harbor"}));
    assert!(graph["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .all(|n| n["sessionId"] != json!(id)));
}

#[test]
fn the_agents_first_start_replaces_what_gitrochi_set() {
    let repo = Repo::new();
    let id = repo.track(json!({}))["session"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let reply = repo.report(
        json!({"session": id, "event": "start", "project": "harbor", "title": "Retry sign-in",
                                   "kind": "research", "base": "1.1.0", "summary": "starting"}),
    );
    assert_eq!(reply["created"], false);
    assert_eq!(
        reply["event"], "start",
        "the agent's own start, not progress"
    );
    assert!(reply["notices"].as_array().unwrap().iter().any(|n| n
        .as_str()
        .unwrap()
        .contains("Gitrochi created this session")));
    let session = &repo.detail(&id)["session"];
    assert_eq!(session["title"], "Retry sign-in");
    assert_eq!(session["kind"], "research");
    assert_eq!(session["baseVersion"], "1.1.0");
    assert!(session["lastAgentAt"].is_number(), "reported now");
    assert_eq!(session["links"]["branch"], "feature/retry", "links stay");

    // From now on the usual rules hold: another title is a conflict again.
    let again =
        repo.try_report(json!({"session": id, "event": "start", "title": "Something else"}));
    assert_eq!(again.code, "CONFLICT");
    let other =
        repo.try_report(json!({"session": id, "event": "progress", "project": "elsewhere"}));
    assert_eq!(other.code, "CONFLICT");
}

#[test]
fn the_agent_may_name_another_project() {
    let repo = Repo::new();
    let id = repo.track(json!({}))["session"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let reply = repo.report(
        json!({"session": id, "event": "start", "project": "Harbor App", "title": "Retry",
                                   "summary": "starting"}),
    );
    assert_eq!(reply["session"]["project"], "Harbor App");
    assert!(
        reply["session"].get("baseVersion").is_none(),
        "the guessed base belonged to the other trunk"
    );
    let detail = repo.detail(&id);
    assert_eq!(detail["session"]["project"], "Harbor App");
    let moved = app(&repo.db(), "state", json!({"project": "Harbor App"}));
    assert!(moved["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["id"] == json!(id)));
    let left = app(&repo.db(), "state", json!({"project": "harbor"}));
    assert!(left["sessions"].as_array().unwrap().is_empty());
}

#[test]
fn a_report_that_is_not_a_start_keeps_the_base_and_adds_the_title() {
    let repo = Repo::new();
    let id = repo.track(json!({}))["session"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let reply = repo.report(
        json!({"session": id, "event": "progress", "title": "Retry sign-in", "summary": "working"}),
    );
    assert_eq!(reply["event"], "progress");
    let session = &repo.detail(&id)["session"];
    assert_eq!(
        (session["title"].clone(), session["baseVersion"].clone()),
        (json!("Retry sign-in"), json!("1.0.0"))
    );
}

#[test]
fn explicit_values_and_the_policy_are_kept() {
    let repo = Repo::new();
    let result = repo.track(
        json!({"project": "Harbor", "title": "Launch title", "base": "latest",
                                   "autoContinue": {"enabled": true, "delaySec": 45}}),
    );
    let session = &result["session"];
    assert_eq!(
        (session["project"].clone(), session["title"].clone()),
        (json!("Harbor"), json!("Launch title"))
    );
    assert!(
        session.get("baseVersion").is_none(),
        "a new project has no HEAD yet"
    );
    assert_eq!(
        session["autoContinue"],
        json!({"enabled": true, "delaySec": 45})
    );
    let detail = repo.detail(session["id"].as_str().unwrap());
    assert_eq!(
        detail["events"][0]["data"]["autoContinue"],
        json!({"enabled": true, "delaySec": 45})
    );
    // A project bound to the repository is found by its path, whatever its name.
    app(
        &repo.db(),
        "project_set",
        json!({"project": "Harbor", "repoPath": format!("{}/", repo.path("harbor"))}),
    );
    let bound = repo.track(json!({}));
    assert_eq!(bound["session"]["project"], "Harbor");
    assert_eq!(bound["session"]["baseVersion"], "1.0.0");
    let invalid = gitrochi_ledger::call(
        "track",
        &json!({"db": repo.db().to_string_lossy(), "repoPath": repo.path("harbor"),
                "autoContinue": {"enabled": "yes"}}),
    );
    assert_eq!(invalid["error"]["code"], "INVALID_ARGUMENT");
    let nothing = gitrochi_ledger::call("track", &json!({"db": repo.db().to_string_lossy()}));
    assert_eq!(nothing["error"]["code"], "INVALID_ARGUMENT");
}

#[test]
fn the_repositorys_policy_is_the_sessions_unless_the_app_gives_one() {
    let repo = Repo::new();
    let policy = json!({"enabled": true, "delaySec": 20});
    app(
        &repo.db(),
        "settings_set",
        json!({"values": {"autoContinue": {"enabled": false, "delaySec": 30,
                                            "repositories": {format!("{}/", repo.path("harbor")): policy}}}}),
    );
    assert_eq!(repo.track(json!({}))["session"]["autoContinue"], policy);
    let given = json!({"enabled": false, "delaySec": 60});
    assert_eq!(
        repo.track(json!({"autoContinue": given}))["session"]["autoContinue"],
        given
    );
    assert!(repo.track(json!({"autoContinue": null}))["session"]
        .get("autoContinue")
        .is_none());
    let elsewhere = repo.track(json!({"repoPath": repo.path("harbor-retry")}));
    assert!(elsewhere["session"].get("autoContinue").is_none());
    // The hook handler reads the setting as a policy; the extra key does not stop it.
    let settings = app(&repo.db(), "settings", json!({}));
    assert_eq!(
        settings["autoContinue"]["repositories"]
            .as_object()
            .unwrap()
            .len(),
        1
    );
    let bad = gitrochi_ledger::call(
        "settings_set",
        &json!({"db": repo.db().to_string_lossy(),
                "values": {"autoContinue": {"repositories": {"/x": {"enabled": true}}}}}),
    );
    assert_eq!(bad["error"]["code"], "INVALID_ARGUMENT");
}

#[test]
fn outside_a_repository_the_folder_names_the_session() {
    let dir = TempDir::new("track-plain");
    let folder = dir.join("notes");
    std::fs::create_dir_all(&folder).unwrap();
    let db = dir.join("ledger.sqlite3");
    let result = app(
        &db,
        "track",
        json!({"repoPath": folder.to_string_lossy(), "cwd": folder.to_string_lossy()}),
    );
    let session = &result["session"];
    assert_eq!(
        (session["project"].clone(), session["title"].clone()),
        (json!("notes"), json!("notes"))
    );
    assert!(session.get("baseVersion").is_none());
    assert!(session["links"].get("branch").is_none());
}

#[test]
fn only_the_apps_track_and_reported_sessions_keep_their_rules() {
    let repo = Repo::new();
    let db = repo.db();
    let output = cli(&db, &["call", "track", r#"{"repoPath": "/tmp/x"}"#]);
    assert!(!output.status.success());
    assert_eq!(json_of(&output)["error"]["code"], "NOT_ALLOWED");
    // A session an agent started itself never takes another title or project.
    let started = repo
        .report(json!({"event": "start", "project": "harbor", "title": "Own", "base": "1.0.0"}));
    let id = started["sessionId"].as_str().unwrap();
    assert_eq!(
        repo.try_report(json!({"session": id, "event": "start", "title": "Other"}))
            .code,
        "CONFLICT"
    );
    assert_eq!(
        repo.try_report(json!({"session": id, "event": "progress", "project": "other"}))
            .code,
        "CONFLICT"
    );
}
