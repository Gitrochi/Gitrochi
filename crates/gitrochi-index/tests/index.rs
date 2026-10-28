mod common;

use common::{subjects, Fixture};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

const KIM: (&str, &str) = ("Kim Haneul", "haneul@example.com");
const LEE: (&str, &str) = ("Lee Doyun", "doyun@example.com");

#[test]
fn sync_is_incremental_and_records_file_changes() {
    let mut fx = Fixture::new();
    fx.commit("Add a and b", &[("a.txt", "1\n"), ("b.txt", "1\n")]);
    fx.commit("Change a, add c", &[("a.txt", "1\n2\n"), ("c.txt", "x\n")]);
    fx.git(&["mv", "a.txt", "d.txt"]);
    let rename = fx.commit("Rename a to d", &[("d.txt", "1\n2\n3\n")]);

    let first = fx.run("sync", json!({}));
    assert_eq!(first["newCommits"], 3);
    assert_eq!(first["upToDate"], false);
    let again = fx.run("sync", json!({}));
    assert_eq!(again["upToDate"], true);
    assert_eq!(again["newCommits"], 0);

    fx.commit("Touch b", &[("b.txt", "1\n2\n")]);
    let third = fx.run("sync", json!({}));
    assert_eq!(third["newCommits"], 1);
    assert_eq!(third["totalCommits"], 4);

    let shown = fx.run("show", json!({"sha": rename}));
    let files = shown["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["path"], "d.txt");
    assert_eq!(files[0]["oldPath"], "a.txt");
    assert_eq!(files[0]["status"], "R");
    assert_eq!(files[0]["additions"], 1);

    let status = fx.run("status", json!({}));
    assert_eq!(status["commits"], 4);
    assert_eq!(status["stale"], false);
    assert_eq!(status["shallow"], false);
}

#[test]
fn history_follows_renames() {
    let mut fx = Fixture::new();
    fx.commit("Create a", &[("a.txt", "1\n")]);
    fx.commit("Edit a", &[("a.txt", "1\n2\n")]);
    fx.git(&["mv", "a.txt", "d.txt"]);
    fx.commit("Rename a to d", &[]);
    fx.commit("Edit d", &[("d.txt", "1\n2\n3\n")]);
    fx.run("sync", json!({}));

    let plain = fx.run("log", json!({"path": "d.txt"}));
    assert_eq!(subjects(&plain, "commits"), ["Edit d", "Rename a to d"]);
    let followed = fx.run("log", json!({"path": "d.txt", "follow": true}));
    assert_eq!(
        subjects(&followed, "commits"),
        ["Edit d", "Rename a to d", "Edit a", "Create a"]
    );
}

#[test]
fn change_relationships_skip_large_commits_and_suggest_missing_files() {
    let mut fx = Fixture::new();
    for round in 0..3 {
        let body = format!("{round}\n");
        fx.commit(
            "Change parser with its test",
            &[("src/parser.rs", &body), ("tests/parser.rs", &body)],
        );
    }
    fx.commit("Parser alone", &[("src/parser.rs", "solo\n")]);
    // 40 files at once: a formatting sweep, not a relationship.
    let sweep: Vec<(String, String)> = (0..40)
        .map(|i| (format!("wide/f{i}.txt"), "x\n".to_string()))
        .chain([("src/parser.rs".to_string(), "sweep\n".to_string())])
        .collect();
    let sweep: Vec<(&str, &str)> = sweep
        .iter()
        .map(|(p, c)| (p.as_str(), c.as_str()))
        .collect();
    fx.commit("Format everything", &sweep);
    fx.run("sync", json!({}));

    let coupled = fx.run("coupled", json!({"path": "src/parser.rs"}));
    // 4 small commits touched the parser (the sweep is excluded from the denominator).
    assert_eq!(coupled["commits"], 4);
    let partners = coupled["partners"].as_array().unwrap();
    assert_eq!(partners.len(), 1, "{coupled}");
    assert_eq!(partners[0]["path"], "tests/parser.rs");
    assert_eq!(partners[0]["commits"], 3);
    assert_eq!(partners[0]["confidence"], 0.75);
    assert_eq!(partners[0]["jaccard"], 0.75);

    let impact = fx.run("impact", json!({"paths": ["src/parser.rs"]}));
    let suggestions = impact["suggestions"].as_array().unwrap();
    assert_eq!(suggestions[0]["path"], "tests/parser.rs");
    assert_eq!(suggestions[0]["score"], 0.75);
    // Nothing is suggested when the partner is already part of the change.
    let complete = fx.run(
        "impact",
        json!({"paths": ["src/parser.rs", "tests/parser.rs"]}),
    );
    assert!(complete["suggestions"].as_array().unwrap().is_empty());
    let pairs = fx.run("status", json!({}))["cochangePairs"]
        .as_i64()
        .unwrap();
    assert_eq!(pairs, 1, "the 41-file commit must not add pairs");
}

#[test]
fn full_text_search_handles_korean_identifiers_and_filters() {
    let mut fx = Fixture::new();
    fx.commit_as(KIM, "로그인오류 수정", &[("login.ts", "a\n")]);
    fx.commit_as(
        LEE,
        "Add parseHTTPResponse helper\n\nWraps the response parser.",
        &[("net.ts", "b\n")],
    );
    fx.commit_as(LEE, "Fix typo in README", &[("README.md", "c\n")]);
    fx.run("sync", json!({}));

    let korean = fx.run("search", json!({"query": "로그인"}));
    assert_eq!(subjects(&korean, "results"), ["로그인오류 수정"]);
    assert_eq!(
        korean["results"][0]["highlight"],
        "\u{2}로그인\u{3}오류 수정"
    );
    // A single syllable that ends a word still matches.
    assert_eq!(
        subjects(&fx.run("search", json!({"query": "류"})), "results"),
        ["로그인오류 수정"]
    );

    let part = fx.run("search", json!({"query": "response"}));
    assert_eq!(subjects(&part, "results"), ["Add parseHTTPResponse helper"]);
    let prefix = fx.run("search", json!({"query": "pars"}));
    assert_eq!(
        subjects(&prefix, "results"),
        ["Add parseHTTPResponse helper"]
    );
    let phrase = fx.run("search", json!({"query": "\"typo in\""}));
    assert_eq!(subjects(&phrase, "results"), ["Fix typo in README"]);
    assert!(fx.run("search", json!({"query": "\"in typo\""}))["results"]
        .as_array()
        .unwrap()
        .is_empty());

    let author = fx.run("search", json!({"query": "author:haneul"}));
    assert_eq!(subjects(&author, "results"), ["로그인오류 수정"]);
    let by_lee = fx.run("search", json!({"query": "fix author:Doyun"}));
    assert_eq!(subjects(&by_lee, "results"), ["Fix typo in README"]);
    let path = fx.run("search", json!({"query": "path:net"}));
    assert_eq!(subjects(&path, "results"), ["Add parseHTTPResponse helper"]);

    let sha = fx.git(&["rev-parse", "HEAD"]);
    let by_sha = fx.run("search", json!({"query": &sha[..10]}));
    assert_eq!(subjects(&by_sha, "results"), ["Fix typo in README"]);

    let paths = fx.run("search", json!({"query": "readme", "scope": "paths"}));
    assert_eq!(paths["results"][0]["path"], "README.md");
}

#[test]
fn match_reproduces_the_apps_search() {
    let mut fx = Fixture::new();
    fx.commit("로그 인 화면", &[("Src/Lib/Login.swift", "a\n")]);
    fx.commit(
        "Unrelated\n\nbody mentions FIXME here",
        &[("docs/guide.md", "b\n")],
    );
    fx.commit("Other", &[("src/other.rs", "c\n")]);
    fx.run("sync", json!({}));

    // Whitespace and case are ignored, as in CommitSearchQuery.
    let spaced = fx.run("match", json!({"query": "로그인"}));
    assert_eq!(spaced["shas"].as_array().unwrap().len(), 1);
    let body = fx.run("match", json!({"query": "fix me"}));
    assert_eq!(body["shas"].as_array().unwrap().len(), 1);
    assert_eq!(body["stale"], false);

    let files = fx.run("match", json!({"query": "src/lib", "scope": "files"}));
    assert_eq!(files["shas"].as_array().unwrap().len(), 1);
    let limited = fx.run("match", json!({"query": "s", "scope": "files", "limit": 1}));
    assert_eq!(limited["shas"].as_array().unwrap().len(), 1);
    assert_eq!(limited["truncated"], true);

    fx.commit("New", &[("n.txt", "n\n")]);
    assert_eq!(fx.run("match", json!({"query": "new"}))["stale"], true);
}

#[test]
fn a_limited_sync_is_shallow_until_a_full_one_completes_it() {
    let mut fx = Fixture::new();
    for i in 0..10 {
        fx.commit(&format!("Commit {i}"), &[("f.txt", &format!("{i}\n"))]);
    }
    let partial = fx.run("sync", json!({"limit": 3}));
    assert_eq!(partial["totalCommits"], 3);
    assert_eq!(partial["shallow"], true);
    assert_eq!(fx.run("status", json!({}))["stale"], true);

    let deeper = fx.run("sync", json!({"limit": 4}));
    assert_eq!(deeper["totalCommits"], 7);
    assert_eq!(deeper["shallow"], true);

    let complete = fx.run("sync", json!({}));
    assert_eq!(complete["totalCommits"], 10);
    assert_eq!(complete["shallow"], false);
    let stats = fx.run("file", json!({"path": "f.txt"}));
    assert_eq!(stats["stats"]["commits"], 10);
}

#[test]
fn rewritten_history_is_survived_and_pruned() {
    let mut fx = Fixture::new();
    let base = fx.commit("Base", &[("a.txt", "1\n")]);
    fx.git(&["switch", "-q", "-c", "topic"]);
    fx.commit("Topic one", &[("a.txt", "2\n"), ("b.txt", "2\n")]);
    fx.commit("Topic two", &[("a.txt", "3\n"), ("b.txt", "3\n")]);
    fx.run("sync", json!({}));
    assert_eq!(fx.run("status", json!({}))["cochangePairs"], 1);

    // A force push that drops the topic commits, then gc removes their objects.
    fx.git(&["switch", "-q", "main"]);
    fx.git(&["branch", "-f", "topic", &base]);
    fx.git(&["reflog", "expire", "--expire=now", "--all"]);
    fx.git(&["gc", "-q", "--prune=now"]);
    fx.commit("After rewrite", &[("c.txt", "c\n")]);

    let synced = fx.run("sync", json!({}));
    assert_eq!(synced["newCommits"], 1);
    let pruned = fx.run("prune", json!({}));
    assert_eq!(pruned["removedCommits"], 2);
    let status = fx.run("status", json!({}));
    assert_eq!(status["commits"], 2);
    assert_eq!(status["cochangePairs"], 0);
    assert!(fx.run("search", json!({"query": "topic"}))["results"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        fx.run("file", json!({"path": "a.txt"}))["stats"]["commits"],
        1
    );
}

#[test]
fn concurrent_syncs_do_not_double_count() {
    let mut fx = Fixture::new();
    for i in 0..60 {
        fx.commit(
            &format!("Pair {i}"),
            &[("x.rs", &format!("{i}\n")), ("y.rs", &format!("{i}\n"))],
        );
    }
    // Two processes and two threads at once, all against one database.
    let spawn = || {
        Command::new(env!("CARGO_BIN_EXE_gitrochi-index"))
            .arg("--repo")
            .arg(fx.path())
            .arg("--db")
            .arg(&fx.db)
            .arg("sync")
            .stdout(Stdio::null())
            .spawn()
            .unwrap()
    };
    let mut processes = [spawn(), spawn()];
    std::thread::scope(|scope| {
        for _ in 0..2 {
            scope.spawn(|| fx.run("sync", json!({})));
        }
    });
    for process in &mut processes {
        assert!(process.wait().unwrap().success());
    }
    let status = fx.run("status", json!({}));
    assert_eq!(status["commits"], 60);
    assert_eq!(status["fileChanges"], 120);
    let coupled = fx.run("coupled", json!({"path": "x.rs"}));
    assert_eq!(coupled["partners"][0]["commits"], 60);
    assert_eq!(coupled["commits"], 60);
}

#[test]
fn search_cache_reuses_and_extends_results() {
    let mut fx = Fixture::new();
    fx.commit("Add needle", &[("src/a.rs", "let needle = 1;\n")]);
    fx.commit("Other work", &[("src/b.rs", "nothing\n")]);
    fx.run("sync", json!({}));

    let first = fx.run("cache", json!({"action": "grep", "pattern": "needle"}));
    assert_eq!(first["cached"], false);
    assert_eq!(first["matches"][0]["path"], "src/a.rs");
    assert_eq!(first["matches"][0]["line"], 1);
    assert_eq!(
        fx.run("cache", json!({"action": "grep", "pattern": "needle"}))["cached"],
        true
    );
    let none = fx.run("cache", json!({"action": "grep", "pattern": "absent-word"}));
    assert!(none["matches"].as_array().unwrap().is_empty());

    let pickaxe = fx.run("cache", json!({"action": "pickaxe", "text": "needle"}));
    assert_eq!(subjects(&pickaxe, "commits"), ["Add needle"]);
    assert_eq!(pickaxe["cached"], false);
    assert_eq!(
        fx.run("cache", json!({"action": "pickaxe", "text": "needle"}))["cached"],
        true
    );

    // New tips: only the new commit is searched, and the old hit is kept.
    fx.commit("Remove needle", &[("src/a.rs", "let pin = 1;\n")]);
    let extended = fx.run("cache", json!({"action": "pickaxe", "text": "needle"}));
    assert_eq!(extended["cached"], false);
    assert_eq!(
        subjects(&extended, "commits"),
        ["Remove needle", "Add needle"]
    );
    // The tree changed too, so grep searches again.
    let regrep = fx.run("cache", json!({"action": "grep", "pattern": "needle"}));
    assert_eq!(regrep["cached"], false);
    assert!(regrep["matches"].as_array().unwrap().is_empty());

    let stats = fx.run("cache", json!({"action": "stats"}));
    assert_eq!(stats["entries"], 3);
    assert_eq!(fx.run("cache", json!({"action": "clear"}))["removed"], 3);
}

#[test]
fn hotspots_and_owners() {
    let mut fx = Fixture::new();
    fx.commit_as(KIM, "One", &[("app/main.rs", "1\n"), ("app/old.rs", "1\n")]);
    fx.commit_as(KIM, "Two", &[("app/main.rs", "2\n")]);
    fx.commit_as(
        LEE,
        "Three",
        &[("app/main.rs", "3\n"), ("lib/util.rs", "u\n")],
    );
    fx.git(&["rm", "-q", "app/old.rs"]);
    fx.commit_as(KIM, "Delete old", &[]);
    fx.run("sync", json!({}));

    let hot = fx.run("hotspots", json!({}));
    let files: Vec<&str> = hot["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["path"].as_str().unwrap())
        .collect();
    assert_eq!(files[0], "app/main.rs");
    assert!(
        !files.contains(&"app/old.rs"),
        "deleted files are not hotspots: {files:?}"
    );
    let scoped = fx.run("hotspots", json!({"prefix": "lib/"}));
    assert_eq!(scoped["files"].as_array().unwrap().len(), 1);

    let owners = fx.run("owners", json!({"prefix": "app/"}));
    assert_eq!(owners["commits"], 4);
    assert_eq!(owners["authors"][0]["email"], "haneul@example.com");
    assert_eq!(owners["authors"][0]["commits"], 3);
    assert_eq!(owners["authors"][0]["share"], 0.75);
    assert_eq!(owners["busFactor"], 1);
}

#[test]
fn errors_have_codes_and_exit_statuses() {
    let fx = Fixture::new();
    assert_eq!(
        fx.fails("search", json!({"query": "x"})).code,
        "NOT_INDEXED"
    );
    assert_eq!(fx.run("status", json!({}))["indexed"], false);

    let elsewhere = std::env::temp_dir();
    let not_repo = gitrochi_index::run(Some(&elsewhere), None, "status", &json!({})).unwrap_err();
    assert_eq!(not_repo.code, "NOT_A_REPOSITORY");

    let (code, body) = fx.cli(&["frobnicate"]);
    assert_eq!(code, 2);
    assert_eq!(body["error"]["code"], "INVALID_ARGUMENT");
    let (code, body) = fx.cli(&["search", "x"]);
    assert_eq!(code, 1);
    assert_eq!(body["error"]["code"], "NOT_INDEXED");
    let (code, body) = fx.cli(&["version"]);
    assert_eq!(code, 0);
    assert_eq!(body["schemaVersion"], 1);
}

#[test]
fn cli_and_serve_share_the_contract() {
    let mut fx = Fixture::new();
    fx.commit("Add login", &[("login.ts", "a\n")]);
    let (code, synced) = fx.cli(&["sync", "--max-files", "10"]);
    assert_eq!(code, 0, "{synced}");
    assert_eq!(fx.run("status", json!({}))["maxFiles"], 10);
    let (_, found) = fx.cli(&["search", "login", "--limit", "5"]);
    assert_eq!(subjects(&found, "results"), ["Add login"]);
    let (_, impact) = fx.cli(&["impact", "login.ts", "--min-confidence", "0.1"]);
    assert_eq!(impact["changed"], json!(["login.ts"]));

    let mut child = Command::new(env!("CARGO_BIN_EXE_gitrochi-index"))
        .arg("--repo")
        .arg(fx.path())
        .arg("--db")
        .arg(&fx.db)
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(
        stdin,
        r#"{{"id": 1, "command": "search", "args": {{"query": "login"}}}}"#
    )
    .unwrap();
    writeln!(
        stdin,
        r#"{{"id": "two", "command": "show", "args": {{"sha": "0000000"}}}}"#
    )
    .unwrap();
    writeln!(stdin, "not json").unwrap();
    drop(stdin);
    let lines: Vec<Value> = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
        .collect();
    assert!(child.wait().unwrap().success());
    assert_eq!(lines.len(), 3);
    assert_eq!(lines[0]["id"], 1);
    assert_eq!(subjects(&lines[0]["result"], "results"), ["Add login"]);
    assert_eq!(lines[1]["id"], "two");
    assert_eq!(lines[1]["error"]["code"], "NOT_FOUND");
    assert_eq!(lines[2]["error"]["code"], "INVALID_ARGUMENT");
}

#[test]
fn the_c_abi_round_trips_json() {
    let mut fx = Fixture::new();
    fx.commit("Through the C ABI", &[("a.txt", "a\n")]);
    let call = |request: Value| -> Value {
        let input = serde_json::to_vec(&request).unwrap();
        unsafe {
            let output = gitrochi_index::ffi::gitrochi_index_call(input.as_ptr(), input.len());
            let mut length = [0u8; 8];
            std::ptr::copy_nonoverlapping(output, length.as_mut_ptr(), 8);
            let length = u64::from_le_bytes(length) as usize;
            let body = std::slice::from_raw_parts(output.add(8), length).to_vec();
            gitrochi_index::ffi::gitrochi_index_free(output, length + 8);
            serde_json::from_slice(&body).unwrap()
        }
    };
    let repo = fx.path().to_string_lossy().to_string();
    let db = fx.db.to_string_lossy().to_string();
    let synced = call(json!({"repo": repo, "db": db, "command": "sync"}));
    assert_eq!(synced["result"]["newCommits"], 1);
    let found =
        call(json!({"repo": repo, "db": db, "command": "search", "args": {"query": "abi"}}));
    assert_eq!(subjects(&found["result"], "results"), ["Through the C ABI"]);
    let broken = unsafe {
        let output = gitrochi_index::ffi::gitrochi_index_call(b"{".as_ptr(), 1);
        let mut length = [0u8; 8];
        std::ptr::copy_nonoverlapping(output, length.as_mut_ptr(), 8);
        let length = u64::from_le_bytes(length) as usize;
        let body: Value =
            serde_json::from_slice(std::slice::from_raw_parts(output.add(8), length)).unwrap();
        gitrochi_index::ffi::gitrochi_index_free(output, length + 8);
        body
    };
    assert_eq!(broken["error"]["code"], "INVALID_ARGUMENT");
}

#[test]
fn plain_sqlite_readers_see_the_core_tables_only() {
    let mut fx = Fixture::new();
    fx.commit("Readable", &[("a.txt", "a\n")]);
    fx.run("sync", json!({}));
    // What Python's sqlite3 or Go sees: no gitrochi tokenizer registered.
    let reader =
        rusqlite::Connection::open_with_flags(&fx.db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    let version: i64 = reader
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 1);
    let subject: String = reader
        .query_row("SELECT subject FROM commits", [], |r| r.get(0))
        .unwrap();
    assert_eq!(subject, "Readable");
    let fts = reader.query_row(
        "SELECT COUNT(*) FROM commit_text WHERE commit_text MATCH 'readable'",
        [],
        |r| r.get::<_, i64>(0),
    );
    assert!(fts.unwrap_err().to_string().contains("tokenizer"));
}

#[test]
fn newer_schemas_and_tokenizer_changes_are_handled() {
    let mut fx = Fixture::new();
    fx.commit("Tokenizer upgrade", &[("a.txt", "a\n")]);
    let (code, _) = fx.cli(&["sync"]);
    assert_eq!(code, 0);
    // A row the full-text index has never seen: only a rebuild can make it searchable.
    let plain = rusqlite::Connection::open(&fx.db).unwrap();
    plain
        .execute(
            "INSERT INTO commits (sha, tree, author_name, author_email, author_time, committer_name,
                 committer_email, commit_time, subject, body, parent_count, files_changed, additions, deletions)
             VALUES (?1, 't', 'A', 'a@example.com', 1, 'A', 'a@example.com', 1, 'Inserted behind the index', '', 0, 0, 0, 0)",
            [&"f".repeat(40)],
        )
        .unwrap();
    let (_, before) = fx.cli(&["search", "inserted"]);
    assert!(before["results"].as_array().unwrap().is_empty(), "{before}");
    plain
        .execute(
            "UPDATE meta SET value = 'gitrochi-text 0' WHERE key = 'tokenizer'",
            [],
        )
        .unwrap();
    let (_, after) = fx.cli(&["search", "inserted"]);
    assert_eq!(subjects(&after, "results"), ["Inserted behind the index"]);
    let (_, kept) = fx.cli(&["search", "upgrade"]);
    assert_eq!(subjects(&kept, "results"), ["Tokenizer upgrade"]);
    drop(plain);
    {
        let db = rusqlite::Connection::open(&fx.db).unwrap();
        db.execute_batch("PRAGMA user_version = 99").unwrap();
    }
    let (code, refused) = fx.cli(&["status"]);
    assert_eq!(code, 1);
    assert_eq!(refused["error"]["code"], "SCHEMA_MISMATCH");
}

#[test]
fn pickaxe_stops_at_the_limit_and_searches_again_for_more() {
    let mut fx = Fixture::new();
    fx.commit("First token", &[("a.rs", "token\n")]);
    fx.commit("Second token", &[("b.rs", "token\n")]);
    fx.run("sync", json!({}));
    let one = fx.run(
        "cache",
        json!({"action": "pickaxe", "text": "token", "limit": 1}),
    );
    assert_eq!(subjects(&one, "commits"), ["Second token"]);
    assert_eq!(one["cached"], false);
    // The first answer may be incomplete, so a larger limit must ask git again.
    let more = fx.run(
        "cache",
        json!({"action": "pickaxe", "text": "token", "limit": 5}),
    );
    assert_eq!(more["cached"], false);
    assert_eq!(subjects(&more, "commits"), ["Second token", "First token"]);
    let again = fx.run(
        "cache",
        json!({"action": "pickaxe", "text": "token", "limit": 5}),
    );
    assert_eq!(again["cached"], true);
    let fewer = fx.run(
        "cache",
        json!({"action": "pickaxe", "text": "token", "limit": 1}),
    );
    assert_eq!(fewer["cached"], true);
    assert_eq!(fewer["truncated"], true);
}

#[test]
fn an_up_to_date_sync_writes_nothing() {
    let mut fx = Fixture::new();
    fx.commit("Quiet", &[("a.txt", "a\n")]);
    fx.run("sync", json!({}));
    // The apps sync after every reload and watch the git dir: a write here would loop.
    let stamp = |suffix: &str| {
        let mut path = fx.db.clone().into_os_string();
        path.push(suffix);
        std::fs::metadata(path)
            .map(|m| (m.len(), m.modified().unwrap()))
            .ok()
    };
    let before = (stamp(""), stamp("-wal"));
    // Past the next second, so a timestamp written now would differ (SQLite skips writes
    // that store identical bytes).
    std::thread::sleep(std::time::Duration::from_millis(1100));
    assert_eq!(fx.run("sync", json!({}))["upToDate"], true);
    fx.run("search", json!({"query": "quiet"}));
    assert_eq!((stamp(""), stamp("-wal")), before);
}

#[test]
fn the_git_executable_can_be_chosen() {
    let mut fx = Fixture::new();
    fx.commit("Chosen git", &[("a.txt", "a\n")]);
    let broken = gitrochi_index::run(
        Some(fx.path()),
        Some(&fx.db),
        "sync",
        &json!({"git": "/nonexistent/git"}),
    )
    .unwrap_err();
    assert_eq!(broken.code, "GIT_FAILED");
    let request = json!({"repo": fx.path(), "db": fx.db, "git": "git", "command": "sync"});
    assert_eq!(gitrochi_index::call(&request)["result"]["newCommits"], 1);
}

#[test]
fn commits_in_one_second_keep_gits_order() {
    let fx = Fixture::new();
    // A rebase leaves many commits with the same committer time.
    let commit = |fx: &Fixture, message: &str, file: &str| {
        fx.write(file, message);
        fx.git(&["add", "-A"]);
        let output = fx
            .command()
            .args(["commit", "-q", "-m", message])
            .env("GIT_AUTHOR_DATE", "@1780000000 +0000")
            .env("GIT_COMMITTER_DATE", "@1780000000 +0000")
            .output()
            .unwrap();
        assert!(output.status.success());
    };
    commit(&fx, "One", "a.txt");
    commit(&fx, "Two", "a.txt");
    fx.run("sync", json!({}));
    commit(&fx, "Three", "a.txt");
    commit(&fx, "Four", "a.txt");
    fx.run("sync", json!({}));
    let log = fx.run("log", json!({}));
    assert_eq!(subjects(&log, "commits"), ["Four", "Three", "Two", "One"]);
    let history = fx.run("log", json!({"path": "a.txt"}));
    assert_eq!(
        subjects(&history, "commits"),
        ["Four", "Three", "Two", "One"]
    );
    let found = fx.run("match", json!({"query": "o"}));
    let order: Vec<String> = found["shas"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect();
    assert_eq!(order[0], fx.git(&["rev-parse", "HEAD"]));
}

#[test]
fn grep_stops_at_the_limit() {
    let mut fx = Fixture::new();
    let many: String = (0..500).map(|i| format!("line {i} match\n")).collect();
    fx.commit(
        "Many matches",
        &[("big.txt", &many), ("small.txt", "match\n")],
    );
    fx.run("sync", json!({}));
    let found = fx.run(
        "cache",
        json!({"action": "grep", "pattern": "match", "limit": 3}),
    );
    assert_eq!(found["matches"].as_array().unwrap().len(), 3);
    assert_eq!(found["truncated"], true);
    let all = fx.run(
        "cache",
        json!({"action": "grep", "pattern": "match", "limit": 1000}),
    );
    assert_eq!(all["matches"].as_array().unwrap().len(), 501);
    assert_eq!(all["truncated"], false);
    let bad = fx.fails("cache", json!({"action": "grep", "pattern": "(unclosed"}));
    assert_eq!(bad.code, "GIT_FAILED");
}

#[test]
fn a_double_dash_ends_the_options() {
    let mut fx = Fixture::new();
    fx.commit("Dashed", &[("--weird.txt", "a\n"), ("plain.txt", "b\n")]);
    fx.commit(
        "Dashed again",
        &[("--weird.txt", "c\n"), ("plain.txt", "d\n")],
    );
    fx.cli(&["sync"]);
    let (code, coupled) = fx.cli(&["coupled", "--", "--weird.txt"]);
    assert_eq!(code, 0, "{coupled}");
    assert_eq!(coupled["path"], "--weird.txt");
    assert_eq!(coupled["partners"][0]["path"], "plain.txt");
    let (_, impact) = fx.cli(&["impact", "--min-confidence", "0.5", "--", "--weird.txt"]);
    assert_eq!(impact["suggestions"][0]["path"], "plain.txt");
}
