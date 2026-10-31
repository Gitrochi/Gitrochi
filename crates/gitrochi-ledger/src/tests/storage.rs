//! Storage: migrations, baselines from folders and git tags, imports, backups and several
//! writers at once.

use super::*;
use crate::backup;
use crate::db;
use crate::import;
use std::process::Command;
use std::sync::Arc;

#[test]
fn migrations_are_idempotent_and_additive() {
    let dir = temp_dir("migrate");
    let path = dir.join("ledger.sqlite3");
    let first = Db::open(&path).unwrap();
    first
        .write(|c| baseline::register(c, P, "1.0.0", "", 1))
        .unwrap();
    drop(first);
    // Opening again, and migrating an open connection again, change nothing.
    let again = Db::open(&path).unwrap();
    let mut raw = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(db::migrate(&mut raw).unwrap(), db::DB_SCHEMA);
    assert_eq!(db::migrate(&mut raw).unwrap(), db::DB_SCHEMA);
    let tables: i64 = raw
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(tables, 9);
    assert_eq!(again.read(|c| baseline::trunk(c, P)).unwrap().len(), 1);
    // Re-running the first step's SQL on a migrated file is harmless (IF NOT EXISTS).
    raw.execute_batch(include_str!("../schema.sql")).unwrap();
    assert_eq!(again.rev().unwrap(), 1, "rev survives");
    // Threads opening a brand-new file at once all succeed.
    let fresh = dir.join("fresh.sqlite3");
    let handles: Vec<_> = (0..6)
        .map(|_| {
            let fresh = fresh.clone();
            std::thread::spawn(move || Db::open(&fresh).map(|_| ()))
        })
        .collect();
    for handle in handles {
        handle.join().unwrap().unwrap();
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_file_from_a_newer_build_is_read_but_not_written() {
    let dir = temp_dir("newer");
    let path = dir.join("ledger.sqlite3");
    drop(Db::open(&path).unwrap());
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch("PRAGMA user_version = 99")
        .unwrap();
    let newer = Db::open(&path).unwrap();
    assert_eq!(newer.rev().unwrap(), 0);
    let error = newer.write(|_| Ok(())).unwrap_err();
    assert_eq!(error.code, "SCHEMA_MISMATCH");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn only_version_folders_count_unless_files_are_scanned() {
    let h = H::new();
    assert_eq!(h.overview().head.as_deref(), Some("1.0.5"));
    let recent: Vec<_> = h
        .overview()
        .recent_baselines
        .into_iter()
        .map(|b| b.version)
        .collect();
    assert_eq!(recent, ["1.0.0", "1.0.3", "1.0.5"]);
    std::fs::write(h.folder.join("v1.1.0"), "a file, not a folder").unwrap();
    std::fs::write(h.folder.join("SPEC_v1.1.1.md"), "# spec").unwrap();
    let scan = baseline::refresh(&h.db, P, true).unwrap();
    assert_eq!((scan.found, scan.added), (3, 0));
    assert_eq!(h.overview().head.as_deref(), Some("1.0.5"));
}

#[test]
fn files_and_listed_sub_folders_with_a_pattern() {
    let h = H::new();
    let touch = |parts: &[&str]| {
        let path = parts.iter().fold(h.folder.clone(), |p, part| p.join(part));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "# spec").unwrap();
        path
    };
    touch(&["SPEC_v1.1.0.md"]);
    touch(&["REF_SPEC_v1.2.0.md"]); // outside the anchored pattern
    touch(&["old", "SPEC_v0.9.md"]);
    touch(&["old", "SPEC_v0.9.5.md"]);
    std::fs::create_dir_all(h.folder.join("old").join("published_v0.8.4")).unwrap();
    h.db.write(|c| {
        baseline::set_project(
            c,
            &json!({"project": P, "baselinePattern": r"^SPEC_v(\d+(?:\.\d+)+)\.md$", "scanFiles": true,
                    "scanSubdirs": ["old", "missing"]}),
            h.now(),
        )
    })
    .unwrap();
    let scan = baseline::refresh(&h.db, P, true).unwrap();
    assert_eq!(
        (scan.found, scan.added),
        (3, 3),
        "a missing sub-folder is skipped"
    );
    let versions = h.versions();
    for v in ["0.9", "0.9.5", "1.1.0"] {
        assert!(
            versions.contains(&(v.to_string(), "folder".to_string())),
            "{v}"
        );
    }
    assert!(!versions.iter().any(|(v, _)| v == "1.2.0" || v == "0.8.4"));
    assert_eq!(h.overview().head.as_deref(), Some("1.1.0"));
    // A pattern without a group takes the version from the whole match.
    std::fs::create_dir_all(h.folder.join("Release Example 1.3.7")).unwrap();
    h.db.write(|c| {
        baseline::set_project(c, &json!({"project": P, "baselinePattern": r"Example \d+\.\d+\.\d+$", "scanFiles": false}), h.now())
    })
    .unwrap();
    baseline::refresh(&h.db, P, true).unwrap();
    assert!(h
        .versions()
        .contains(&("1.3.7".to_string(), "folder".to_string())));
    // A broken pattern is refused up front.
    let error =
        h.db.write(|c| {
            baseline::set_project(c, &json!({"project": P, "baselinePattern": "("}), h.now())
        })
        .unwrap_err();
    assert_eq!(error.code, "INVALID_ARGUMENT");
}

#[test]
fn a_copied_file_takes_the_earlier_of_created_and_modified() {
    let h = H::new();
    let path = h.folder.join("SPEC_v1.1.0.md");
    std::fs::write(&path, "# spec").unwrap();
    let old = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_modified(old)
        .unwrap();
    h.db.write(|c| {
        baseline::set_project(c, &json!({"project": P, "baselinePattern": r"^SPEC_v(\d+(?:\.\d+)+)\.md$", "scanFiles": true}), h.now())
    })
    .unwrap();
    baseline::refresh(&h.db, P, true).unwrap();
    let trunk = h.db.read(|c| baseline::trunk(c, P)).unwrap();
    let found = trunk.iter().find(|b| b.version == "1.1.0").unwrap();
    assert_eq!(found.ts, 1_700_000_000_000);
}

#[test]
fn an_inferred_version_is_promoted_when_it_appears() {
    let h = H::new();
    h.start(json!({"base": "1.0.1"}));
    assert!(h
        .versions()
        .contains(&("1.0.1".to_string(), "inferred".to_string())));
    std::fs::create_dir_all(h.folder.join("v1.0.1")).unwrap();
    let scan = baseline::refresh(&h.db, P, true).unwrap();
    assert_eq!(scan.added, 1);
    assert!(h
        .versions()
        .contains(&("1.0.1".to_string(), "folder".to_string())));
    // Registration promotes too, and a registered note is kept.
    h.start(json!({"base": "1.0.2", "title": "second"}));
    h.db.write(|c| baseline::register(c, P, "1.0.2", "hotfix", h.now()))
        .unwrap();
    let trunk = h.db.read(|c| baseline::trunk(c, P)).unwrap();
    let registered = trunk.iter().find(|b| b.version == "1.0.2").unwrap();
    assert_eq!(
        (registered.source.as_str(), registered.note.as_str()),
        ("registered", "hotfix")
    );
}

#[test]
fn an_inferred_version_is_drawn_below_the_next_one() {
    let h = H::new();
    h.db.write(|c| baseline::register(c, "Q", "1.0.5", "", 1_000_000_000_000))
        .unwrap();
    h.try_report(json!({"project": "Q", "event": "start", "title": "x", "base": "1.0.1"}))
        .unwrap();
    let trunk = h.db.read(|c| baseline::trunk(c, "Q")).unwrap();
    let v1 = trunk.iter().find(|b| b.version == "1.0.1").unwrap();
    let v5 = trunk.iter().find(|b| b.version == "1.0.5").unwrap();
    assert!(v1.ts > v5.ts && v1.eff_ts < v5.eff_ts);
}

fn git(dir: &std::path::Path, args: &[&str], date: &str) {
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
        .env("GIT_AUTHOR_DATE", date)
        .env("GIT_COMMITTER_DATE", date)
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn baselines_come_from_git_tags() {
    let h = H::new();
    let repo = h.dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"], "1700000000 +0000");
    std::fs::write(repo.join("a.txt"), "1").unwrap();
    git(&repo, &["add", "a.txt"], "1700000000 +0000");
    git(&repo, &["commit", "-q", "-m", "first"], "1700000000 +0000");
    git(&repo, &["tag", "v2.0.0"], "1700000000 +0000");
    std::fs::write(repo.join("a.txt"), "2").unwrap();
    git(
        &repo,
        &["commit", "-q", "-am", "second"],
        "1700003600 +0000",
    );
    git(
        &repo,
        &["tag", "-a", "v2.1.0", "-m", "annotated"],
        "1700007200 +0000",
    );
    git(&repo, &["tag", "v2.2.0-rc.1"], "1700007200 +0000");
    git(&repo, &["tag", "nightly"], "1700007200 +0000");
    h.db.write(|c| {
        baseline::set_project(
            c,
            &json!({"project": "Tagged", "repoPath": repo.to_string_lossy(), "baselineSource": "tags"}),
            h.now(),
        )
    })
    .unwrap();
    let scan = baseline::refresh(&h.db, "Tagged", true).unwrap();
    assert_eq!(
        (
            scan.source.as_str(),
            scan.found,
            scan.added,
            scan.error.clone()
        ),
        ("tags", 2, 2, None)
    );
    let trunk = h.db.read(|c| baseline::trunk(c, "Tagged")).unwrap();
    let summary: Vec<_> = trunk
        .iter()
        .map(|b| {
            (
                b.version.as_str(),
                b.source.as_str(),
                b.ts,
                b.ref_name.as_deref(),
            )
        })
        .collect();
    assert_eq!(
        summary,
        [
            ("2.0.0", "tag", 1_700_000_000_000, Some("v2.0.0")),
            ("2.1.0", "tag", 1_700_007_200_000, Some("v2.1.0")),
        ]
    );
    // The annotated tag records the commit it points at, not the tag object.
    let head = Command::new("git")
        .current_dir(&repo)
        .args(["rev-parse", "HEAD"])
        .output()
        .unwrap();
    assert_eq!(
        trunk[1].commit.as_deref(),
        Some(String::from_utf8_lossy(&head.stdout).trim())
    );
    // Nothing new: nothing is written.
    let rev = h.db.rev().unwrap();
    assert_eq!(baseline::refresh(&h.db, "Tagged", true).unwrap().added, 0);
    assert_eq!(h.db.rev().unwrap(), rev);
    // A folder that is not a repository is reported, not fatal.
    h.db.write(|c| {
        baseline::set_project(
            c,
            &json!({"project": "Tagged", "repoPath": h.folder.to_string_lossy()}),
            h.now(),
        )
    })
    .unwrap();
    let scan = baseline::refresh(&h.db, "Tagged", true).unwrap();
    assert!(scan.error.is_some());
    assert!(h
        .try_report(
            json!({"project": "Tagged", "event": "start", "title": "still works", "base": "2.1.0"})
        )
        .is_ok());
}

#[test]
fn pasted_blocks_are_imported_once() {
    let h = H::new();
    let settings = Settings::default();
    let text = format!(
        "intro\n```ledger\n{}\n```\nmiddle\n```ledger\n{}\n```\n",
        r#"{"project":"Example App","session":"web-1008-rv","event":"start","title":"review","base":"1.0.5","summary":"s"}"#,
        r#"{"session":"web-1008-rv","event":"artifact","summary":"notes","artifacts":[{"name":"notes","ssot":"1.0.5"}]}"#,
    );
    let first = import::import(&h.db, &settings, &text, None, h.tick()).unwrap();
    assert!(first.iter().all(|r| r.ok && !r.duplicate), "{first:?}");
    assert_eq!(first[0].session_id.as_deref(), Some("web-1008-rv"));
    let second = import::import(&h.db, &settings, &text, None, h.tick()).unwrap();
    assert!(second.iter().all(|r| r.ok && r.duplicate));
    let plain = r#"{"session":"web-1008-rv","event":"done","summary":"finished"}"#;
    assert!(import::import(&h.db, &settings, plain, None, h.tick()).unwrap()[0].ok);
    assert_eq!(h.view("web-1008-rv").status, "done");
    let events: Vec<_> = h
        .detail("web-1008-rv")
        .events
        .iter()
        .map(|e| (e.kind.clone(), e.channel.clone()))
        .collect();
    assert_eq!(events[0], ("start".to_string(), "import".to_string()));
    assert!(import::import(&h.db, &settings, "no blocks here", None, h.tick()).is_err());
}

#[test]
fn a_bad_block_does_not_stop_the_rest_and_can_be_retried() {
    let h = H::new();
    let settings = Settings::default();
    let text = "```ledger\n{\"event\":\"start\",\"title\":\"no project\",\"session\":\"web-2\"}\n```\n```ledger\n{\"project\":\"Example App\",\"event\":\"start\",\"title\":\"fine\",\"session\":\"web-3\"}\n```";
    let results = import::import(&h.db, &settings, text, None, h.tick()).unwrap();
    assert!(
        !results[0].ok
            && results[0]
                .error
                .as_deref()
                .unwrap()
                .contains("needs a project")
    );
    assert!(results[1].ok);
    // The failed block was not remembered: given a project, it imports.
    let retry = import::import(&h.db, &settings, text, Some(P), h.tick()).unwrap();
    assert!(retry[0].ok && !retry[0].duplicate);
    assert!(retry[1].duplicate);
    assert_eq!(h.view("web-2").project, P);
}

#[test]
fn backups_while_writing_once_a_day_keeping_the_newest() {
    let h = H::new();
    let a = h.sid(json!({"title": "one"}));
    h.sid(json!({"title": "two"}));
    // Another connection is in the middle of a write.
    let writer = rusqlite::Connection::open(&h.db.path).unwrap();
    writer
        .execute_batch("BEGIN IMMEDIATE; INSERT INTO imports VALUES ('in-flight', 1);")
        .unwrap();
    let day: Ms = 1_793_000_000_000;
    let made = backup::run(&h.db, day, 14, false).unwrap();
    writer.execute_batch("ROLLBACK").unwrap();
    assert!(made.created);
    let copy = rusqlite::Connection::open(&made.path).unwrap();
    let check: String = copy
        .query_row("PRAGMA integrity_check", [], |r| r.get(0))
        .unwrap();
    assert_eq!(check, "ok");
    let sessions: i64 = copy
        .query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))
        .unwrap();
    let imports: i64 = copy
        .query_row("SELECT COUNT(*) FROM imports", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        (sessions, imports),
        (2, 0),
        "uncommitted writes are not in the copy"
    );
    assert!(
        !backup::run(&h.db, day + HOUR, 14, true).unwrap().created,
        "today's exists"
    );
    assert!(
        backup::run(&h.db, day + 24 * HOUR, 14, true)
            .unwrap()
            .created
    );
    let dir = backup::directory(&h.db.path);
    for name in [
        "ledger-20200101-0000.sqlite3",
        "ledger-20200102-0000.sqlite3",
        "notes.txt",
        "ledger-old.sqlite3",
    ] {
        std::fs::write(dir.join(name), "").unwrap();
    }
    let made = backup::run(&h.db, day + 48 * HOUR, 3, false).unwrap();
    assert_eq!(
        made.removed,
        [
            "ledger-20200101-0000.sqlite3",
            "ledger-20200102-0000.sqlite3"
        ]
    );
    assert_eq!(backup::list(&h.db.path).len(), 3);
    assert!(dir.join("notes.txt").exists() && dir.join("ledger-old.sqlite3").exists());
    assert_eq!(h.view(&a).title, "one", "the ledger itself is unchanged");
}

#[test]
fn threads_write_at_once_without_losing_anything() {
    let h = H::new();
    let db = Arc::new(Db::open(&h.db.path).unwrap());
    let before = db.rev().unwrap();
    let handles: Vec<_> = (0..4)
        .map(|t| {
            let db = db.clone();
            std::thread::spawn(move || {
                for i in 0..25 {
                    let args = json!({"project": P, "event": "start", "title": format!("t{t}-{i}"), "base": "1.0.0"});
                    db.write(|c| report::report(c, &Settings::load(c)?, &args, "cli", now_ms(), now_ms()))
                        .unwrap();
                }
            })
        })
        .collect();
    for handle in handles {
        handle.join().unwrap();
    }
    assert_eq!(db.rev().unwrap(), before + 100);
    let state = h.state(Range::All);
    assert_eq!(state.sessions.len(), 100);
    let ids: std::collections::HashSet<_> = state.sessions.iter().map(|s| s.id.clone()).collect();
    assert_eq!(ids.len(), 100, "issued IDs are unique");
}
