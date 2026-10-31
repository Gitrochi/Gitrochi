//! Views: state, attention, the graph, search, prompts, the caller boundary and the text
//! agents read.

use super::*;
use crate::api::{self, Caller};
use crate::graph::{self, Graph};
use crate::prompts;
use crate::search;
use crate::vocab::Verdict;
use std::collections::{HashMap, HashSet};

#[test]
fn attention_counts_like_the_inbox() {
    let h = H::new();
    let q = h.sid(json!({"kind": "research", "title": "research with a question"}));
    h.rep(&q, "question", json!({"question": "Which axis?"}));
    let d = h.sid(json!({"kind": "decision", "title": "finished decision"}));
    h.rep(&d, "done", json!({}));
    let c = h.sid(json!({"kind": "research", "title": "closed report"}));
    h.rep(&c, "closed", json!({}));
    let j = h.sid(json!({"kind": "decision", "title": "release", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    let implementation =
        h.sid(json!({"kind": "implementation", "title": "channel", "base": "1.0.5"}));
    h.rep(&implementation, "applied", json!({"version": "1.0.6"}));
    // Archived sessions and their questions do not count.
    let archived = h.sid(json!({"title": "archived with a question"}));
    h.rep(&archived, "question", json!({"question": "?"}));
    h.human(json!({"action": "archive", "sessionId": archived}))
        .unwrap();
    // A stale stream is not something to decide.
    let old = h.now() - 100 * HOUR;
    h.report_at(old, json!({"project": P, "event": "start", "kind": "implementation", "title": "quiet stream", "base": "1.0.0"}))
        .unwrap();
    let state = h.state(Range::All);
    let a = &state.attention;
    assert_eq!(
        (a.questions, a.tidy, a.decide, a.auto_review, a.total),
        (1, 2, 1, 0, 4)
    );
    assert_eq!(
        state
            .questions
            .iter()
            .map(|x| x.session_id.clone())
            .collect::<Vec<_>>(),
        [q]
    );
    let tidy: HashSet<_> = state
        .sessions
        .iter()
        .filter(|s| matches!(s.verdict, Verdict::Confirm | Verdict::Expirable))
        .map(|s| s.id.clone())
        .collect();
    assert_eq!(tidy, HashSet::from([c, j]));
}

#[test]
fn state_lists_sessions_baselines_and_hides_old_archived_ones() {
    let h = H::new();
    let recent = h.sid(json!({"title": "recent archived"}));
    h.rep(&recent, "closed", json!({}));
    h.human(json!({"action": "archive", "sessionId": recent}))
        .unwrap();
    let old = h.now() - 40 * 24 * HOUR;
    let ancient = h
        .report_at(
            old,
            json!({"project": P, "event": "start", "title": "old archived", "base": "1.0.0"}),
        )
        .unwrap()
        .session_id;
    h.db.write(|c| {
        c.execute(
            "UPDATE sessions SET archived_at = ?2 WHERE id = ?1",
            rusqlite::params![ancient, old],
        )?;
        Ok(())
    })
    .unwrap();
    let live = h.sid(json!({"title": "live"}));
    let week = h.state(Range::Days(7));
    let ids: Vec<_> = week.sessions.iter().map(|s| s.id.clone()).collect();
    assert!(ids.contains(&recent) && ids.contains(&live) && !ids.contains(&ancient));
    assert_eq!(week.hidden_before, 1);
    let all = h.state(Range::All);
    assert!(all.sessions.iter().any(|s| s.id == ancient));
    assert_eq!(all.hidden_before, 0);
    assert_eq!(all.schema_version, 1);
    assert!(all.rev > 0);
    let versions: Vec<_> = all.baselines.iter().map(|b| b.version.as_str()).collect();
    assert_eq!(versions, ["1.0.0", "1.0.3", "1.0.5"]);
    assert!(all
        .baselines
        .iter()
        .all(|b| b.source == "folder" && b.ref_name.is_some()));
    let project = all.projects.iter().find(|p| p.key == P).unwrap();
    assert_eq!((project.head.as_deref(), project.open), (Some("1.0.5"), 1));
    assert!(Range::parse(Some("2w")).is_err());
}

#[test]
fn overview_picks_the_project_and_delivers_only_when_asked() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.human(json!({"action": "message", "sessionId": id, "text": "hello"}))
        .unwrap();
    let db = std::sync::Arc::new(Db::open(&h.db.path).unwrap());
    let (text, data) = api::overview(&db, &json!({}), h.now()).unwrap();
    assert!(text.starts_with(&format!("[{P}] HEAD 1.0.5")), "{text}");
    assert!(data["messages"].as_array().unwrap().is_empty());
    let (text, data) = api::overview(&db, &json!({"session": id}), h.now()).unwrap();
    assert!(
        data["messages"].as_array().unwrap().is_empty(),
        "no delivery without deliver"
    );
    assert!(!text.contains("From a person"));
    let (text, data) =
        api::overview(&db, &json!({"session": id, "deliver": true}), h.now()).unwrap();
    assert_eq!(data["messages"][0]["text"], "[Note from a person] hello");
    assert!(text
        .contains("From a person to this session (act on these):\n  - [Note from a person] hello"));
    let (_, data) = api::overview(&db, &json!({"session": id, "deliver": true}), h.now()).unwrap();
    assert!(
        data["messages"].as_array().unwrap().is_empty(),
        "exactly once"
    );
    // The session view for agents reads without delivering unless asked.
    h.human(json!({"action": "message", "sessionId": id, "text": "again"}))
        .unwrap();
    let (text, _) = api::session_text(&db, &id, false).unwrap();
    assert!(!text.contains("From a person"));
    let (text, _) = api::session_text(&db, &id, true).unwrap();
    assert!(text.contains("[Note from a person] again"), "{text}");
    let empty = Db::open(&crate::tests::temp_dir("empty").join("l.sqlite3")).unwrap();
    let (text, _) = api::overview(&std::sync::Arc::new(empty), &json!({}), h.now()).unwrap();
    assert!(text.starts_with("The ledger has no projects yet"));
}

#[test]
fn texts_for_agents_are_short_english() {
    let h = H::new();
    let id = h.sid(json!({"touches": ["F-12"]}));
    h.rep(&id, "question", json!({"question": "Q?"}));
    let overview = crate::text::overview(&h.overview(), h.now());
    assert!(overview.contains("HEAD 1.0.5"));
    assert!(overview.contains(&format!("• {id} research “Title” · base 1.0.0 (2 behind) · Needs a person (1 question) · F-12 ·")), "{overview}");
    let detail = h.detail(&id);
    let session = crate::text::session(&detail, &[], h.now());
    assert!(session.contains(&id) && session.contains("Open questions:"));
    let reply = h.rep(&id, "progress", json!({}));
    let report = crate::text::report(&reply);
    assert!(report.starts_with(&format!("Recorded ✓ {id} · progress")));
    assert!(report.contains("Base 1.0.0 · HEAD 1.0.5 (2 behind)"));
    let created = h.start(json!({"title": "new"}));
    assert!(crate::text::report(&created).contains("New session ID:"));
    assert!(
        overview.is_ascii()
            || !overview
                .chars()
                .any(|c| ('\u{ac00}'..='\u{d7a3}').contains(&c)),
        "no Korean in agent text"
    );
}

#[test]
fn prompts_wait_get_answered_once_and_automatic_answers_need_review() {
    let h = H::new();
    let id = h.sid(json!({"kind": "implementation"}));
    let now = h.now();
    let (waiting, _) =
        h.db.write(|c| {
            prompts::create(
                c,
                &json!({"sessionId": id, "kind": "ask_user_question", "payload": {"q": 1}}),
                now,
            )
        })
        .unwrap();
    assert_eq!(
        (waiting.state.as_str(), waiting.deadline),
        ("waiting", now + 30_000)
    );
    let state = h.state(Range::All);
    assert_eq!(state.pending_prompts.len(), 1);
    let ((ok, answered), _) =
        h.db.write(|c| {
            prompts::answer(
                c,
                &json!({"id": waiting.id, "answer": {"choice": "3"}}),
                now + 1,
            )
        })
        .unwrap();
    assert!(ok);
    assert_eq!(
        (answered.state.as_str(), answered.answered_by.as_deref()),
        ("answered", Some("human"))
    );
    let ((again, _), _) =
        h.db.write(|c| {
            prompts::answer(
                c,
                &json!({"id": waiting.id, "answer": {"choice": "5"}}),
                now + 2,
            )
        })
        .unwrap();
    assert!(!again, "a second answer is refused");
    // Auto-continue answers another; a person reviews it later.
    let (auto, _) =
        h.db.write(|c| {
            prompts::create(
                c,
                &json!({"sessionId": id, "kind": "stop_question", "delaySec": 5}),
                now,
            )
        })
        .unwrap();
    h.db.write(|c| {
        prompts::resolve(
            c,
            &json!({"id": auto.id, "state": "auto", "answer": {"text": "go on"}}),
            now + 5_000,
        )
    })
    .unwrap();
    let state = h.state(Range::All);
    assert_eq!(
        (state.pending_prompts.len(), state.attention.auto_review),
        (0, 1)
    );
    let reply = h
        .detail(&id)
        .events
        .into_iter()
        .find(|e| e.kind == "auto_reply")
        .unwrap();
    assert_eq!(
        (reply.actor.as_str(), reply.data["promptId"].as_i64()),
        ("auto", Some(auto.id))
    );
    // Auto-continue never answers ledger questions or confirms anything.
    assert_eq!(h.view(&id).ack_at, None);
    h.db.write(|c| prompts::review(c, &json!({"all": true}), now + 6_000))
        .unwrap();
    assert_eq!(h.state(Range::All).attention.auto_review, 0);
    // Prompts nobody resolved expire after their deadline and a grace period.
    let (late, _) =
        h.db.write(|c| {
            prompts::create(
                c,
                &json!({"kind": "permission", "deadline": now - prompts::EXPIRE_GRACE - 1}),
                now,
            )
        })
        .unwrap();
    let (expired, _) = h.db.write(|c| prompts::expire(c, now)).unwrap();
    assert_eq!(expired, 1);
    assert_eq!(
        h.db.read(|c| prompts::get(c, late.id)).unwrap().state,
        "expired"
    );
    for bad in [
        json!({"kind": "telepathy"}),
        json!({"kind": "permission", "sessionId": "S0000-00"}),
        json!({"kind": "permission", "payload": 5}),
    ] {
        assert!(
            h.db.write(|c| prompts::create(c, &bad, now)).is_err(),
            "{bad}"
        );
    }
    assert!(h
        .db
        .write(|c| prompts::resolve(c, &json!({"id": late.id, "state": "answered"}), now))
        .is_err());
}

#[test]
fn agents_cannot_reach_a_persons_operations() {
    let h = H::new();
    let id = h.sid(json!({}));
    let db = h.db.path.to_string_lossy().to_string();
    for (method, args) in [
        ("human", json!({"action": "ack", "sessionId": id})),
        ("prompt_answer", json!({"id": 1, "answer": {}})),
        ("prompt_review", json!({"all": true})),
        ("settings_set", json!({"values": {"staleHours": 1}})),
        ("project_set", json!({"project": P, "repoPath": "/tmp"})),
        ("prompt_create", json!({"kind": "permission"})),
        ("prompt_resolve", json!({"id": 1, "state": "auto"})),
    ] {
        let mut args = args;
        args["db"] = json!(db);
        let error = api::call_as(Caller::Agent, method, &args).unwrap_err();
        assert_eq!(error.code, "NOT_ALLOWED", "{method}");
    }
    assert_eq!(h.view(&id).ack_at, None);
    let ok = api::call_as(
        Caller::App,
        "human",
        &json!({"db": db, "action": "ack", "sessionId": id}),
    )
    .unwrap();
    assert_eq!(ok["ok"], true);
    assert!(ok["rev"].as_i64().unwrap() > 0);
    assert!(h.view(&id).ack_at.is_some());
    let error = api::call_as(Caller::Hook, "report", &json!({"db": db})).unwrap_err();
    assert_eq!(error.code, "NOT_ALLOWED");
    assert_eq!(
        api::call_as(Caller::App, "nope", &json!({}))
            .unwrap_err()
            .code,
        "INVALID_ARGUMENT"
    );
    let refused = api::call("human", &json!({"db": db, "action": "ack"}));
    assert_eq!(refused["error"]["code"], "INVALID_ARGUMENT");
}

#[test]
fn settings_change_the_stale_limit_and_are_validated() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.advance(2 * HOUR);
    assert_eq!(h.view(&id).verdict, Verdict::Active);
    let db = h.db.path.to_string_lossy().to_string();
    let reply = api::call_as(
        Caller::App,
        "settings_set",
        &json!({"db": db, "values": {"staleHours": 1}}),
    )
    .unwrap();
    assert_eq!(reply["settings"]["staleHours"], 1.0);
    assert_eq!(h.view(&id).verdict, Verdict::Stale);
    for bad in [
        json!({"staleHours": 0}),
        json!({"colour": 1}),
        json!({"kinds": {"x": {"role": "boss"}}}),
    ] {
        assert!(api::call_as(
            Caller::App,
            "settings_set",
            &json!({"db": db, "values": bad})
        )
        .is_err());
    }
    let read = api::call_as(Caller::Agent, "settings", &json!({"db": db})).unwrap();
    assert_eq!(read["staleHours"], 1.0);
    assert_eq!(read["kinds"]["implementation"]["line"], "core");
    assert_eq!(read["autoContinue"]["delaySec"], 30);
    api::call_as(
        Caller::App,
        "settings_set",
        &json!({"db": db, "values": {"staleHours": null}}),
    )
    .unwrap();
    assert_eq!(h.view(&id).verdict, Verdict::Active);
}

#[test]
fn per_session_auto_continue_policy() {
    let h = H::new();
    let id = h.sid(json!({}));
    assert!(h.view(&id).auto_continue.is_none());
    h.human(json!({"action": "auto_continue", "sessionId": id, "autoContinue": {"enabled": true, "delaySec": 45}}))
        .unwrap();
    assert_eq!(
        h.view(&id).auto_continue,
        Some(json!({"enabled": true, "delaySec": 45}))
    );
    assert!(h
        .human(
            json!({"action": "auto_continue", "sessionId": id, "autoContinue": {"enabled": true}})
        )
        .is_err());
    h.human(json!({"action": "auto_continue", "sessionId": id, "autoContinue": null}))
        .unwrap();
    assert!(h.view(&id).auto_continue.is_none());
}

#[test]
fn search_finds_sessions_questions_events_and_baselines() {
    let h = H::new();
    let id = h.sid(json!({"title": "Login retry", "touches": ["src/auth.rs"]}));
    h.rep(
        &id,
        "question",
        json!({"question": "Retry three times on a gateway error?"}),
    );
    h.rep(&id, "progress", json!({"summary": "measured", "body": "The p99 latency went from 900 ms to 300 ms after the change; 100% of runs passed."}));
    h.db.write(|c| baseline::register(c, P, "1.0.8", "hotfix for the retry loop", h.now()))
        .unwrap();
    let find = |query: &str| {
        h.db.read(|c| search::search(c, query, Some(P), 50))
            .unwrap()
    };
    let kinds = |hits: &[search::Hit]| hits.iter().map(|x| x.kind).collect::<Vec<_>>();
    let hits = find("retry");
    assert_eq!(kinds(&hits)[0], "session");
    assert!(kinds(&hits).contains(&"question") && kinds(&hits).contains(&"baseline"));
    let hits = find(&id.to_lowercase());
    assert_eq!(
        (hits[0].kind, hits[0].id.as_str()),
        ("session", id.as_str())
    );
    let hits = find("p99 latency");
    assert_eq!(kinds(&hits), ["event"]);
    assert!(hits[0].snippet.contains("p99 latency"));
    assert_eq!(hits[0].session_id.as_deref(), Some(id.as_str()));
    assert_eq!(
        kinds(&find("100%")),
        ["event"],
        "LIKE wildcards are literal"
    );
    assert!(find("p99 nowhere").is_empty(), "every word must match");
    assert_eq!(kinds(&find("auth.rs")), ["session"]);
    assert!(h.db.read(|c| search::search(c, "  ", None, 5)).is_err());
    assert!(h
        .db
        .read(|c| search::search(c, "retry", Some("Other"), 5))
        .unwrap()
        .is_empty());
}

fn graph_of(h: &H, range: Range, key_only: bool) -> Graph {
    let now = h.now();
    h.db.read(|c| {
        graph::graph(
            c,
            &Settings::load(c)?,
            P,
            &graph::Options {
                range,
                key_only,
                include_archived: false,
            },
            now,
        )
    })
    .unwrap()
}

fn check_layout(graph: &Graph) {
    let rows: Vec<usize> = graph.nodes.iter().map(|n| n.row).collect();
    assert_eq!(
        rows,
        (0..graph.nodes.len()).collect::<Vec<_>>(),
        "one node per row, in order"
    );
    assert!(
        graph.nodes.windows(2).all(|w| w[0].ts >= w[1].ts),
        "newest on top"
    );
    let ids: HashSet<&str> = graph.nodes.iter().map(|n| n.id.as_str()).collect();
    for edge in &graph.edges {
        assert!(
            ids.contains(edge.from.as_str()) && ids.contains(edge.to.as_str()),
            "{edge:?}"
        );
    }
    for node in &graph.nodes {
        assert_eq!(node.kind == "baseline", node.lane == 0, "{node:?}");
        assert!(node.lane < graph.lanes);
    }
    // Sessions sharing a lane keep at least one free row between them.
    let mut spans: HashMap<(usize, &str), (usize, usize)> = HashMap::new();
    for node in graph.nodes.iter().filter(|n| n.lane > 0) {
        let entry = spans
            .entry((node.lane, node.session_id.as_deref().unwrap()))
            .or_insert((node.row, node.row));
        entry.0 = entry.0.min(node.row);
        entry.1 = entry.1.max(node.row);
    }
    let list: Vec<_> = spans.into_iter().collect();
    for (i, ((lane_a, a), (top_a, bottom_a))) in list.iter().enumerate() {
        for ((lane_b, b), (top_b, bottom_b)) in &list[i + 1..] {
            if lane_a == lane_b && a != b {
                assert!(
                    bottom_a < top_b || bottom_b < top_a,
                    "{a} and {b} overlap in lane {lane_a}"
                );
            }
        }
    }
}

#[test]
fn the_graph_draws_trunk_lanes_forks_and_joins_the_same_way_every_time() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    let a = h.sid(json!({"title": "A", "base": "1.0.3"}));
    h.rep(&a, "artifact", json!({"artifacts": ["notes"]}));
    h.rep(&a, "merged", json!({"into": "1.0.6"}));
    let c = h.sid(json!({"kind": "implementation", "title": "channel", "base": "1.0.5"}));
    h.rep(&c, "sync", json!({"version": "1.0.6"}));
    h.rep(&c, "applied", json!({"version": "1.0.6"}));
    let open = h.sid(json!({"title": "still open", "base": "1.0.6"}));
    h.rep(&open, "question", json!({"question": "?"}));

    let graph = graph_of(&h, Range::All, false);
    check_layout(&graph);
    assert_eq!(
        graph,
        graph_of(&h, Range::All, false),
        "same database, same graph"
    );
    assert_eq!(
        serde_json::to_string(&graph).unwrap(),
        serde_json::to_string(&graph_of(&h, Range::All, false)).unwrap()
    );
    let node = |id: &str| graph.nodes.iter().find(|n| n.id == id).unwrap();
    assert!(node("b:1.0.6").head);
    assert_eq!(node("b:1.0.6").handoff, Some("applied"));
    assert_eq!(node("b:1.0.6").by_session.as_deref(), Some(j.as_str()));
    let edges = |kind: &str| -> Vec<(String, String)> {
        graph
            .edges
            .iter()
            .filter(|e| e.kind == kind)
            .map(|e| (e.from.clone(), e.to.clone()))
            .collect()
    };
    let trunk = edges("trunk");
    assert!(trunk.contains(&("b:1.0.0".into(), "b:1.0.3".into())));
    assert!(trunk.contains(&("b:1.0.5".into(), "b:1.0.6".into())));
    let first_a = graph
        .nodes
        .iter()
        .filter(|n| n.session_id.as_deref() == Some(a.as_str()))
        .max_by_key(|n| n.row)
        .unwrap();
    assert!(
        edges("branch").contains(&("b:1.0.3".into(), first_a.id.clone())),
        "a fork from its base"
    );
    let merged_a = graph
        .nodes
        .iter()
        .find(|n| n.session_id.as_deref() == Some(a.as_str()) && n.kind == "merge")
        .unwrap();
    assert!(
        edges("merge").contains(&(merged_a.id.clone(), "b:1.0.6".into())),
        "a join into the baseline"
    );
    let release = graph
        .nodes
        .iter()
        .find(|n| n.event_type.as_deref() == Some("release"))
        .unwrap();
    assert!(edges("merge").contains(&(release.id.clone(), "b:1.0.6".into())));
    // The decision session released 1.0.6 itself: no second join line.
    let joins_from_j = graph
        .edges
        .iter()
        .filter(|e| e.kind == "merge" && e.to == "b:1.0.6")
        .filter(|e| {
            graph
                .nodes
                .iter()
                .any(|n| n.id == e.from && n.session_id.as_deref() == Some(j.as_str()))
        })
        .count();
    assert_eq!(joins_from_j, 1);
    let sync = graph
        .nodes
        .iter()
        .find(|n| n.event_type.as_deref() == Some("sync"))
        .unwrap();
    assert!(edges("handoff").contains(&("b:1.0.6".into(), sync.id.clone())));
    let target_record = graph
        .nodes
        .iter()
        .find(|n| {
            n.session_id.as_deref() == Some(j.as_str())
                && n.event_type.as_deref() == Some("applied")
        })
        .unwrap();
    let applied = graph
        .nodes
        .iter()
        .find(|n| {
            n.session_id.as_deref() == Some(c.as_str())
                && n.event_type.as_deref() == Some("applied")
        })
        .unwrap();
    assert!(edges("handoff").contains(&(applied.id.clone(), target_record.id.clone())));
    let tails: Vec<_> = graph.tails.iter().map(|t| t.session_id.clone()).collect();
    assert!(tails.contains(&open) && tails.contains(&c) && !tails.contains(&a));
    // Key events only: fewer nodes, same rules.
    let key = graph_of(&h, Range::All, true);
    check_layout(&key);
    assert!(key.nodes.len() <= graph.nodes.len());
}

#[test]
fn the_graph_range_hides_old_rows_but_keeps_head() {
    let h = H::new();
    let old = h.now() - 20 * 24 * HOUR;
    let id = h
        .report_at(
            old,
            json!({"project": P, "event": "start", "title": "old", "base": "1.0.0"}),
        )
        .unwrap()
        .session_id;
    h.report_at(old + HOUR, json!({"session": id, "event": "closed"}))
        .unwrap();
    h.db.write(|c| {
        c.execute("UPDATE baselines SET ts = ?1", [old - HOUR])?;
        Ok(())
    })
    .unwrap();
    let week = graph_of(&h, Range::Days(7), false);
    check_layout(&week);
    assert_eq!(
        week.nodes.iter().map(|n| n.id.as_str()).collect::<Vec<_>>(),
        ["b:1.0.5"],
        "HEAD stays"
    );
    assert!(week.hidden_before >= 4);
    let all = graph_of(&h, Range::All, false);
    check_layout(&all);
    assert_eq!(all.hidden_before, 0);
    assert!(all.nodes.len() >= 5);
}

#[test]
fn many_sessions_share_lanes_without_overlapping() {
    let h = H::new();
    for i in 0..30 {
        let base = ["1.0.0", "1.0.3", "1.0.5"][i % 3];
        let id = h.sid(json!({"title": format!("s{i}"), "base": base}));
        h.rep(&id, "artifact", json!({}));
        if i % 2 == 0 {
            h.rep(&id, "closed", json!({}));
        }
    }
    let graph = graph_of(&h, Range::All, false);
    check_layout(&graph);
    assert!(graph.lanes > 1);
}
