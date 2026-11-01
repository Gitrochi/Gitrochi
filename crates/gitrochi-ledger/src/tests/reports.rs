//! Reports and a person's operations: IDs, bases, resume rules, statuses, release and the
//! hand-offs, questions and delivery.

use super::*;
use crate::util::valid_session_id;
use crate::vocab::Verdict;

#[test]
fn start_issues_an_id_and_says_how_far_behind() {
    let h = H::new();
    let reply = h.start(json!({}));
    let id = &reply.session_id;
    assert!(
        id.starts_with('S') && id.len() == 8 && id.as_bytes()[5] == b'-',
        "{id}"
    );
    assert!(valid_session_id(id));
    assert!(reply.created);
    assert_eq!(reply.session.behind, Some(2));
    assert!(
        has(&reply.notices, "2 baseline(s) behind HEAD 1.0.5"),
        "{:?}",
        reply.notices
    );
    assert_eq!(reply.head.as_deref(), Some("1.0.5"));
    // A second session the same day gets the next number.
    let second = h.sid(json!({"title": "Second"}));
    assert_eq!(&second[..6], &id[..6]);
    assert_ne!(&second, id);
}

#[test]
fn latest_is_stored_as_the_head_number() {
    let h = H::new();
    for word in ["latest", "최신"] {
        let s = h.start(json!({"base": word, "title": word})).session;
        assert_eq!(s.base_version.as_deref(), Some("1.0.5"));
        assert!(s.base_was_latest);
    }
    // Once stored, a newer HEAD does not move the base.
    h.db.write(|c| baseline::register(c, P, "1.0.9", "", h.now()))
        .unwrap();
    let s = h.start(json!({"base": "1.0.3", "title": "fixed"})).session;
    assert_eq!(s.base_version.as_deref(), Some("1.0.3"));
    assert!(!s.base_was_latest);
}

#[test]
fn missing_or_unreadable_base_is_noticed() {
    let h = H::new();
    let reply = h
        .try_report(json!({"project": P, "event": "start", "title": "no base", "summary": "s"}))
        .unwrap();
    assert!(has(&reply.notices, "No base"));
    assert_eq!(reply.session.base_version, None);
    let reply = h.start(json!({"base": "soon", "title": "odd base"}));
    assert!(has(&reply.notices, "Could not read base 'soon'"));
    let empty = H::new();
    empty
        .db
        .write(|c| {
            c.execute("DELETE FROM baselines", [])?;
            Ok(())
        })
        .unwrap();
    let reply = empty.start(json!({"base": "latest"}));
    assert!(has(&reply.notices, "'latest' could not be resolved"));
}

#[test]
fn a_report_without_a_session_creates_one_with_an_automatic_start() {
    let h = H::new();
    let reply = h
        .try_report(json!({"project": P, "session": "web-chat-17", "event": "artifact", "summary": "table"}))
        .unwrap();
    assert!(reply.created);
    assert!(has(&reply.notices, "registered"));
    let events = h.detail("web-chat-17").events;
    let kinds: Vec<_> = events.iter().map(|e| e.kind.as_str()).collect();
    assert_eq!(kinds, ["start", "artifact"]);
    assert!(events[0].summary.starts_with("(automatic start)"));
    assert!(events[0].ts < events[1].ts);
}

#[test]
fn start_with_the_same_title_is_progress_another_title_is_a_conflict() {
    let h = H::new();
    h.start(json!({"session": "web-1008-x", "title": "A"}));
    let again = h.start(json!({"session": "web-1008-x", "title": "A"}));
    assert_eq!(again.event, "progress");
    assert!(has(&again.notices, "recorded as progress"));
    let error = h
        .try_report(json!({"project": P, "session": "web-1008-x", "event": "start", "title": "B"}))
        .unwrap_err();
    assert_eq!(error.code, "CONFLICT");
    assert_eq!(h.view("web-1008-x").title, "A");
    // Another project is a conflict too.
    let error = h
        .try_report(json!({"project": "Other", "session": "web-1008-x", "event": "note"}))
        .unwrap_err();
    assert_eq!(error.code, "CONFLICT");
}

#[test]
fn invalid_reports_are_rejected_and_write_nothing() {
    let h = H::new();
    let id = h.sid(json!({}));
    let rev = h.db.rev().unwrap();
    let cases = [
        json!({"session": id, "event": "frobnicate", "summary": "x"}),
        json!({"session": id, "event": "ack", "summary": "agents cannot confirm"}),
        json!({"session": id, "event": "release", "summary": "no version"}),
        json!({"session": id, "event": "release", "version": "latest"}),
        json!({"session": id, "event": "sync", "summary": "no version"}),
        json!({"session": id, "event": "applied", "summary": "no version"}),
        json!({"session": id, "event": "question", "summary": ""}),
        json!({"event": "start", "title": "no project", "summary": "x"}),
        json!({"project": P, "session": "a b", "event": "start", "title": "space", "summary": "x"}),
        json!({"project": P, "session": "ab", "event": "start", "title": "short", "summary": "x"}),
        json!(["not", "an", "object"]),
    ];
    for case in cases {
        assert!(h.try_report(case.clone()).is_err(), "{case}");
    }
    assert_eq!(h.db.rev().unwrap(), rev, "a refused report changes nothing");
}

#[test]
fn korean_event_aliases_are_stored_in_english() {
    let h = H::new();
    let id = h.sid(json!({"kind": "판정", "event": "시작"}));
    assert_eq!(h.view(&id).kind, "decision");
    h.rep(&id, "결정", json!({}));
    h.rep(&id, "완료", json!({}));
    let kinds: Vec<_> = h
        .detail(&id)
        .events
        .iter()
        .map(|e| e.kind.clone())
        .collect();
    assert_eq!(kinds, ["start", "decision", "done"]);
}

#[test]
fn strings_are_nfc_normalised() {
    let h = H::new();
    let decomposed = "\u{1100}\u{1161}\u{11a8} draft"; // 각 as three jamo
    let s = h
        .start(json!({"title": decomposed, "touches": [decomposed]}))
        .session;
    assert_eq!(s.title, "각 draft");
    assert_eq!(s.touches, ["각 draft"]);
}

#[test]
fn touches_and_related_are_merged_as_sets() {
    let h = H::new();
    let id = h.sid(json!({"touches": ["a", "b"], "related": "S1-x"}));
    h.rep(
        &id,
        "progress",
        json!({"touches": "b, c", "related": ["S1-x", "S2-y"]}),
    );
    let s = h.view(&id);
    assert_eq!(s.touches, ["a", "b", "c"]);
    assert_eq!(s.related, ["S1-x", "S2-y"]);
}

#[test]
fn loose_field_types_are_accepted() {
    let h = H::new();
    let id = h.sid(json!({}));
    let first = h
        .rep(&id, "question", json!({"question": "Q1"}))
        .question_ids[0];
    let second = h
        .rep(&id, "question", json!({"question": "Q2"}))
        .question_ids[0];
    h.rep(&id, "decision", json!({"resolves": second.to_string()}));
    let states: Vec<_> = h
        .detail(&id)
        .questions
        .iter()
        .map(|q| q.state.clone())
        .collect();
    assert_eq!(states, ["open", "answered"]);
    h.rep(
        &id,
        "decision",
        json!({"resolves": first, "touches": 5, "artifacts": {"name": "single", "ssot": "1.0.0"}}),
    );
    let detail = h.detail(&id);
    assert_eq!(detail.session.open_questions, 0);
    assert_eq!(detail.session.touches, ["5"]);
    assert_eq!(detail.events.last().unwrap().artifacts[0]["name"], "single");
    // An agent's own resolution is not a person's answer.
    assert_eq!(detail.questions[0].answered_by, None);
    assert_eq!(detail.questions[0].resolved_by.as_deref(), Some("agent"));
    assert!(detail.questions[0].delivered_at.is_some());
}

#[test]
fn artifacts_without_a_version_use_the_current_base() {
    let h = H::new();
    let id = h.sid(json!({"base": "1.0.3"}));
    let reply = h.rep(&id, "artifact", json!({"artifacts": [{"name": "table"}, "notes"], "artifact": {"name": "extra", "ver": "r2"}}));
    let event = h.detail(&id).events.pop().unwrap();
    assert_eq!(event.artifacts.len(), 3);
    for artifact in &event.artifacts {
        assert_eq!(artifact["ssot"], "1.0.3");
        assert_eq!(artifact["ssotInferred"], true);
    }
    assert_eq!(event.artifacts[2]["ver"], "r2");
    // All artifacts agree on one baseline, so the event points at it.
    assert_eq!(event.version.as_deref(), Some("1.0.3"));
    assert!(reply
        .notices
        .iter()
        .all(|n| !n.contains("behind") || n.contains("1.0.3")));
}

#[test]
fn sync_moves_the_current_base_only() {
    let h = H::new();
    let id = h.sid(json!({}));
    let s = h.rep(&id, "sync", json!({"version": "1.0.5"})).session;
    assert_eq!(
        (
            s.base_version.as_deref(),
            s.base_current.as_deref(),
            s.behind
        ),
        (Some("1.0.0"), Some("1.0.5"), Some(0))
    );
    let event = h.detail(&id).events.pop().unwrap();
    assert_eq!(
        (event.data["from"].clone(), event.data["to"].clone()),
        (json!("1.0.0"), json!("1.0.5"))
    );
}

#[test]
fn a_question_is_answered_and_delivered_exactly_once() {
    let h = H::new();
    let id = h.sid(json!({}));
    let reply = h.rep(&id, "question", json!({"question": "Retry 3 or 5 times?"}));
    assert_eq!(reply.session.verdict, Verdict::NeedsHuman);
    let question = reply.question_ids[0];
    h.human(json!({"action": "answer", "questionId": question, "answer": "3, with jitter"}))
        .unwrap();
    h.human(json!({"action": "message", "sessionId": id, "text": "Also check the timeout"}))
        .unwrap();
    // Reading does not deliver.
    assert_eq!(h.detail(&id).waiting_messages, 2);
    let reply = h.rep(&id, "progress", json!({}));
    assert_eq!(reply.messages.len(), 2);
    assert!(reply.messages[0].text.contains("3, with jitter"));
    assert_eq!(reply.messages[0].kind, "answer");
    assert_eq!(reply.messages[0].question_id, Some(question));
    assert_eq!(
        reply.messages[1].text,
        "[Note from a person] Also check the timeout"
    );
    assert!(h.rep(&id, "progress", json!({})).messages.is_empty());
    assert_eq!(h.view(&id).verdict, Verdict::Active);
    assert_eq!(h.detail(&id).waiting_messages, 0);
}

#[test]
fn messages_reach_only_their_own_session() {
    let h = H::new();
    let a = h.sid(json!({"title": "A"}));
    let b = h.sid(json!({"title": "B"}));
    h.human(json!({"action": "message", "sessionId": a, "text": "for A"}))
        .unwrap();
    assert!(h.rep(&b, "progress", json!({})).messages.is_empty());
    let delivered = h.rep(&a, "note", json!({})).messages;
    assert_eq!(delivered.len(), 1);
    assert_eq!(delivered[0].text, "[Note from a person] for A");
}

#[test]
fn dismissed_questions_and_status_changes_are_delivered() {
    let h = H::new();
    let id = h.sid(json!({}));
    let question = h
        .rep(&id, "question", json!({"question": "Format?"}))
        .question_ids[0];
    h.human(json!({"action": "dismiss", "questionId": question}))
        .unwrap();
    h.human(json!({"action": "set_status", "sessionId": id, "status": "closed", "reason": "superseded"})).unwrap();
    let messages = h.rep(&id, "note", json!({})).messages;
    let texts: Vec<_> = messages.iter().map(|m| m.text.as_str()).collect();
    assert_eq!(
        texts,
        [
            format!("[Question #{question} dismissed] Format?").as_str(),
            "[Status set by a person] Status → closed (no merge needed): superseded",
        ]
    );
}

#[test]
fn a_session_may_resolve_its_own_question() {
    let h = H::new();
    let id = h.sid(json!({}));
    let question = h
        .rep(&id, "question", json!({"question": "Q?"}))
        .question_ids[0];
    h.rep(
        &id,
        "decision",
        json!({"summary": "settled it", "resolves": [question]}),
    );
    let detail = h.detail(&id);
    assert_eq!(detail.session.open_questions, 0);
    assert_eq!(detail.questions[0].answer.as_deref(), Some("settled it"));
    // Nothing to deliver back to the agent that settled it.
    assert!(h.rep(&id, "progress", json!({})).messages.is_empty());
    // A question of another session cannot be resolved from here.
    let other = h.sid(json!({"title": "other"}));
    let foreign = h
        .rep(&other, "question", json!({"question": "mine"}))
        .question_ids[0];
    h.rep(&id, "decision", json!({"resolves": [foreign]}));
    assert_eq!(h.view(&other).open_questions, 1);
}

#[test]
fn release_absorbs_sessions_then_a_person_confirms_and_archives() {
    let h = H::new();
    let a = h.sid(json!({"title": "A"}));
    assert_eq!(
        h.rep(&a, "done", json!({})).session.verdict,
        Verdict::PendingMerge
    );
    let d = h.sid(json!({"title": "baseline update", "kind": "정본", "base": "1.0.5"}));
    let reply = h.rep(
        &d,
        "release",
        json!({"version": "1.0.6", "absorbs": [a, "missing-1"]}),
    );
    assert_eq!(reply.head.as_deref(), Some("1.0.6"));
    assert!(has(&reply.notices, "Could not find session missing-1"));
    let va = h.view(&a);
    assert_eq!(
        (va.status.as_str(), va.merged_into.as_deref(), va.verdict),
        ("merged", Some("1.0.6"), Verdict::Confirm)
    );
    h.human(json!({"action": "ack", "sessionId": a})).unwrap();
    assert_eq!(h.view(&a).verdict, Verdict::Expirable);
    h.human(json!({"action": "archive", "sessionId": a}))
        .unwrap();
    assert_eq!(h.view(&a).verdict, Verdict::Archived);
    let released = h.db.read(|c| baseline::trunk(c, P)).unwrap().pop().unwrap();
    assert_eq!(
        (
            released.version.as_str(),
            released.source.as_str(),
            released.by_session.as_deref()
        ),
        ("1.0.6", "release", Some(d.as_str()))
    );
    assert_eq!(h.view(&d).base_current.as_deref(), Some("1.0.6"));
    // A release below HEAD is recorded with a notice.
    let low = h.rep(&d, "release", json!({"version": "1.0.4"}));
    assert!(has(&low.notices, "lower than HEAD 1.0.6"));
}

#[test]
fn new_work_on_a_finished_session_reopens_it() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.rep(&id, "merged", json!({"into": "1.0.3"}));
    h.human(json!({"action": "ack", "sessionId": id})).unwrap();
    h.human(json!({"action": "archive", "sessionId": id}))
        .unwrap();
    let reply = h.rep(
        &id,
        "artifact",
        json!({"artifacts": [{"name": "follow-up", "ssot": "1.0.3"}]}),
    );
    let s = reply.session;
    assert_eq!(s.status, "active");
    assert_eq!((s.ack_at, s.archived_at, s.merged_into), (None, None, None));
    assert!(has(&reply.notices, "made it active again"));
    assert_eq!(
        h.detail(&id).events.pop().unwrap().data["reopenedFrom"],
        "merged"
    );
}

#[test]
fn every_reopen_event_reopens_and_others_do_not() {
    for event in [
        "start", "progress", "artifact", "question", "decision", "sync", "applied",
    ] {
        let h = H::new();
        let id = h.sid(json!({"kind": "implementation"}));
        h.rep(&id, "closed", json!({}));
        let extra = match event {
            "sync" | "applied" => json!({"version": "1.0.5"}),
            "question" => json!({"question": "again?"}),
            "start" => json!({"title": "Title"}),
            _ => json!({}),
        };
        assert_eq!(h.rep(&id, event, extra).session.status, "active", "{event}");
    }
    for event in ["note", "heartbeat", "done", "merged", "dropped"] {
        let h = H::new();
        let id = h.sid(json!({}));
        h.rep(&id, "closed", json!({}));
        let status = h.rep(&id, event, json!({})).session.status;
        assert_ne!(status, "active", "{event} must not reopen");
    }
}

#[test]
fn notes_and_heartbeats_keep_the_confirmation() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.rep(&id, "closed", json!({}));
    h.human(json!({"action": "ack", "sessionId": id})).unwrap();
    h.rep(&id, "note", json!({"summary": "for the record"}));
    h.rep(&id, "heartbeat", json!({}));
    assert_eq!(h.view(&id).verdict, Verdict::Expirable);
    // A heartbeat leaves no event but counts as activity.
    let kinds: Vec<_> = h
        .detail(&id)
        .events
        .iter()
        .map(|e| e.kind.clone())
        .collect();
    assert!(!kinds.contains(&"heartbeat".to_string()));
    // Any other report withdraws the confirmation.
    h.rep(&id, "dropped", json!({}));
    assert_eq!(h.view(&id).verdict, Verdict::Confirm);
}

#[test]
fn an_archived_session_resurfaces_on_any_report_but_a_note() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.rep(&id, "merged", json!({"into": "1.0.3"}));
    h.human(json!({"action": "ack", "sessionId": id})).unwrap();
    h.human(json!({"action": "archive", "sessionId": id}))
        .unwrap();
    h.rep(&id, "note", json!({"summary": "for the record"}));
    assert_eq!(h.view(&id).verdict, Verdict::Archived);
    let reply = h.rep(&id, "done", json!({}));
    assert_eq!(reply.session.archived_at, None);
    assert_eq!(reply.session.verdict, Verdict::PendingMerge);
    assert!(has(&reply.notices, "archived; this report brought it back"));
    // Being absorbed by a release brings it back too.
    let b = h.sid(json!({"title": "B"}));
    h.rep(&b, "closed", json!({}));
    h.human(json!({"action": "ack", "sessionId": b})).unwrap();
    h.human(json!({"action": "archive", "sessionId": b}))
        .unwrap();
    let d = h.sid(json!({"title": "baseline", "kind": "baseline", "base": "1.0.5"}));
    h.rep(&d, "release", json!({"version": "1.0.6", "absorbs": [b]}));
    assert_eq!(h.view(&b).verdict, Verdict::Confirm);
}

#[test]
fn a_finishing_status_a_person_chooses_counts_as_confirmed() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.human(json!({"action": "set_status", "sessionId": id, "status": "closed"}))
        .unwrap();
    assert_eq!(h.view(&id).verdict, Verdict::Expirable);
    let error = h
        .human(json!({"action": "set_status", "sessionId": id, "status": "merged"}))
        .unwrap_err();
    assert_eq!(error.code, "INVALID_ARGUMENT");
    h.human(json!({"action": "set_status", "sessionId": id, "status": "merged", "into": "1.0.7"}))
        .unwrap();
    let s = h.view(&id);
    assert_eq!(
        (s.merged_into.as_deref(), s.verdict),
        (Some("1.0.7"), Verdict::Expirable)
    );
    assert!(h.versions().contains(&("1.0.7".into(), "inferred".into())));
    // Back to active clears the confirmation and the archive.
    h.human(json!({"action": "archive", "sessionId": id}))
        .unwrap();
    h.human(json!({"action": "set_status", "sessionId": id, "status": "active"}))
        .unwrap();
    let s = h.view(&id);
    assert_eq!(
        (s.ack_at, s.archived_at, s.merged_into.clone()),
        (None, None, None)
    );
    assert_eq!(s.verdict, Verdict::Active);
    // done is not a finishing status
    h.human(json!({"action": "set_status", "sessionId": id, "status": "done"}))
        .unwrap();
    assert_eq!(h.view(&id).verdict, Verdict::PendingMerge);
    assert!(h
        .human(json!({"action": "set_status", "sessionId": id, "status": "finished"}))
        .is_err());
}

#[test]
fn a_persons_operations_are_checked() {
    let h = H::new();
    let id = h.sid(json!({}));
    assert_eq!(
        h.human(json!({"action": "explode", "sessionId": id}))
            .unwrap_err()
            .code,
        "INVALID_ARGUMENT"
    );
    assert_eq!(
        h.human(json!({"action": "ack", "sessionId": "S0000-99"}))
            .unwrap_err()
            .code,
        "NOT_FOUND"
    );
    assert_eq!(
        h.human(json!({"action": "ack"})).unwrap_err().code,
        "INVALID_ARGUMENT"
    );
    assert_eq!(
        h.human(json!({"action": "answer", "questionId": 999, "answer": "x"}))
            .unwrap_err()
            .code,
        "NOT_FOUND"
    );
    let question = h
        .rep(&id, "question", json!({"question": "Q"}))
        .question_ids[0];
    let other = h.sid(json!({"title": "other"}));
    assert!(h
        .human(
            json!({"action": "answer", "questionId": question, "sessionId": other, "answer": "x"})
        )
        .is_err());
    assert!(h
        .human(json!({"action": "answer", "questionId": question, "answer": "  "}))
        .is_err());
    assert!(h
        .human(json!({"action": "message", "sessionId": id, "text": ""}))
        .is_err());
    h.human(json!({"action": "ack", "sessionId": id})).unwrap();
    h.human(json!({"action": "unack", "sessionId": id}))
        .unwrap();
    assert_eq!(h.view(&id).ack_at, None);
    h.human(json!({"action": "archive", "sessionId": id}))
        .unwrap();
    h.human(json!({"action": "unarchive", "sessionId": id}))
        .unwrap();
    assert_eq!(h.view(&id).archived_at, None);
    let kinds: Vec<_> = h
        .detail(&id)
        .events
        .iter()
        .filter(|e| e.actor == "human")
        .map(|e| e.kind.clone())
        .collect();
    assert_eq!(kinds, ["ack", "unack", "archive", "unarchive"]);
}

#[test]
fn links_are_kept_and_checked() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.human(
        json!({"action": "link", "sessionId": id, "branch": "fix/login", "worktree": "/tmp/wt",
        "pr": {"host": "example.com", "number": 7, "url": "https://example.com/pulls/7"},
        "chatUrl": "https://example.com/chat/1"}),
    )
    .unwrap();
    let s = h.view(&id);
    assert_eq!(s.links["branch"], "fix/login");
    assert_eq!(s.links["pr"]["number"], 7);
    assert_eq!(s.chat_url.as_deref(), Some("https://example.com/chat/1"));
    h.human(json!({"action": "link", "sessionId": id, "branch": null, "pr": null}))
        .unwrap();
    let s = h.view(&id);
    assert!(s.links.get("branch").is_none() && s.links.get("pr").is_none());
    assert_eq!(s.links["worktree"], "/tmp/wt");
    for bad in [
        json!({"chatUrl": "javascript:alert(1)"}),
        json!({"pr": {"host": "example.com", "number": 7, "url": "file:///etc"}}),
        json!({"branch": 5}),
        json!({}),
    ] {
        let mut args = merge(json!({"action": "link", "sessionId": id}), bad.clone());
        args["sessionId"] = json!(id);
        assert!(h.human(args).is_err(), "{bad}");
    }
    // Agents may give a chat link; anything but http(s) is ignored.
    let reply = h.rep(&id, "note", json!({"chatUrl": "ftp://example.com/x"}));
    assert!(has(&reply.notices, "chatUrl was ignored"));
    assert_eq!(
        h.view(&id).chat_url.as_deref(),
        Some("https://example.com/chat/1")
    );
}

#[test]
fn stale_after_the_limit_until_a_person_snoozes() {
    let h = H::new();
    let ts = h.now() - 100 * HOUR;
    let id = h
        .report_at(
            ts,
            json!({"project": P, "event": "start", "title": "old", "base": "1.0.0"}),
        )
        .unwrap()
        .session_id;
    assert_eq!(h.view(&id).verdict, Verdict::Stale);
    h.human(json!({"action": "snooze", "sessionId": id}))
        .unwrap();
    let s = h.view(&id);
    assert_eq!(s.verdict, Verdict::Active);
    // The snooze lasts the stale limit, and the agent's last report time is unchanged.
    assert_eq!(s.last_at, ts);
    h.advance(73 * HOUR);
    assert_eq!(h.view(&id).verdict, Verdict::Stale);
    h.human(json!({"action": "snooze", "sessionId": id, "hours": 1}))
        .unwrap();
    assert_eq!(h.view(&id).verdict, Verdict::Active);
    h.advance(2 * HOUR);
    assert_eq!(h.view(&id).verdict, Verdict::Stale);
    assert!(h
        .human(json!({"action": "snooze", "sessionId": id, "until": 5}))
        .is_err());
    // A report is activity again.
    assert_eq!(
        h.rep(&id, "progress", json!({})).session.verdict,
        Verdict::Active
    );
}

#[test]
fn shelving_is_for_research_and_documents_and_new_work_resumes() {
    let h = H::new();
    let decision = h.sid(json!({"kind": "decision", "title": "decision"}));
    let error = h.try_rep(&decision, "shelved", json!({})).unwrap_err();
    assert!(error.message.contains("Only research and document"));
    assert!(h
        .human(json!({"action": "shelve", "sessionId": decision}))
        .is_err());
    let doc = h.sid(json!({"kind": "문서", "title": "draft"}));
    let question = h
        .rep(&doc, "question", json!({"question": "Which template?"}))
        .question_ids[0];
    h.rep(
        &doc,
        "보관",
        json!({"summary": "until the template is decided"}),
    );
    assert_eq!(
        h.view(&doc).verdict,
        Verdict::NeedsHuman,
        "open questions come first"
    );
    h.human(json!({"action": "dismiss", "questionId": question}))
        .unwrap();
    assert_eq!(h.view(&doc).verdict, Verdict::Shelved);
    let reply = h.rep(&doc, "progress", json!({"summary": "material arrived"}));
    assert_eq!(reply.session.status, "active");
    assert!(has(&reply.notices, "The session was shelved"));
}

#[test]
fn shelved_work_is_kept_never_stale_and_not_concurrent() {
    let h = H::new();
    let old = h.now() - 200 * HOUR;
    let id = h
        .report_at(
            old,
            json!({"project": P, "event": "start", "kind": "research", "title": "prior study",
                                "base": "1.0.0", "touches": ["F-12"]}),
        )
        .unwrap()
        .session_id;
    h.report_at(
        old + HOUR,
        json!({"session": id, "event": "shelved", "summary": "waiting for numbers"}),
    )
    .unwrap();
    let s = h.view(&id);
    assert_eq!(
        (s.status.as_str(), s.verdict),
        ("shelved", Verdict::Shelved)
    );
    let overview = h.overview();
    assert!(overview.open.is_empty());
    assert_eq!(
        overview
            .shelved
            .iter()
            .map(|s| s.id.as_str())
            .collect::<Vec<_>>(),
        [id.as_str()]
    );
    assert!(crate::text::overview(&overview, h.now()).contains("Shelved (1"));
    let state = h.state(Range::All);
    assert_eq!(state.projects.iter().find(|p| p.key == P).unwrap().open, 0);
    // Starting on the same touches mentions the material, without an overlap warning.
    let other = h.start(json!({"kind": "decision", "title": "same item", "touches": ["F-12"]}));
    assert!(other
        .notices
        .iter()
        .any(|n| n.starts_with(&format!("For reference: shelved {id}"))));
    assert!(!other.notices.iter().any(|n| n.starts_with("Overlap")));
    assert!(h.overview().overlaps.is_empty());
}

#[test]
fn a_person_can_shelve_and_the_session_is_told() {
    let h = H::new();
    let id = h.sid(json!({"kind": "research"}));
    h.human(json!({"action": "shelve", "sessionId": id, "reason": "parked"}))
        .unwrap();
    let s = h.view(&id);
    assert_eq!((s.verdict, s.ack_at), (Verdict::Shelved, None));
    let messages = h.rep(&id, "note", json!({})).messages;
    assert_eq!(messages.len(), 1);
    assert!(messages[0].text.contains("shelved: parked"));
}

#[test]
fn applied_confirms_the_decision_session_that_released_the_version() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision 1.0.6", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    let c = h.sid(json!({"kind": "implementation", "title": "implementation", "base": "1.0.5"}));
    let reply = h.rep(
        &c,
        "applied",
        json!({"version": "1.0.6", "summary": "applied as asked"}),
    );
    let s = h.view(&j);
    assert_eq!(
        (s.status.as_str(), s.merged_into.as_deref(), s.verdict),
        ("merged", Some("1.0.6"), Verdict::Expirable)
    );
    assert!(has(
        &reply.notices,
        &format!("{j} → v1.0.6 merged and confirmed: ready to archive")
    ));
    let record = h
        .detail(&j)
        .events
        .into_iter()
        .find(|e| e.kind == "applied")
        .unwrap();
    assert_eq!(
        (record.actor.as_str(), record.data["by"].as_str()),
        ("agent", Some(c.as_str()))
    );
    let own = h.detail(&c);
    assert_eq!(own.session.base_current.as_deref(), Some("1.0.6"));
    assert_eq!(own.events.last().unwrap().data["targets"], json!([j]));
    // The same report again changes nothing.
    let again = h.rep(&c, "이행", json!({"version": "1.0.6"}));
    assert!(has(
        &again.notices,
        "already merged into v1.0.6 and confirmed"
    ));
    assert_eq!(
        h.detail(&j)
            .events
            .iter()
            .filter(|e| e.kind == "applied")
            .count(),
        1
    );
}

#[test]
fn applied_leaves_open_questions_and_the_resume_rule_still_holds() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    let question = h
        .rep(&j, "question", json!({"question": "Next meeting?"}))
        .question_ids[0];
    let c = h.sid(json!({"kind": "implementation", "title": "implementation", "base": "1.0.6"}));
    let reply = h.rep(&c, "applied", json!({"version": "1.0.6"}));
    assert_eq!(h.view(&j).status, "merged");
    assert_eq!(h.view(&j).verdict, Verdict::NeedsHuman);
    assert!(has(&reply.notices, "keep it at Needs a person"));
    h.human(json!({"action": "answer", "questionId": question, "answer": "next week"}))
        .unwrap();
    assert_eq!(h.view(&j).verdict, Verdict::Expirable);
    h.rep(
        &j,
        "progress",
        json!({"summary": "the decision chat is used again"}),
    );
    let s = h.view(&j);
    assert_eq!(
        (s.status.as_str(), s.ack_at, s.merged_into.clone()),
        ("active", None, None)
    );
}

#[test]
fn applied_confirms_decision_sessions_only() {
    let h = H::new();
    let research = h.sid(json!({"kind": "research", "title": "research release", "base": "1.0.5"}));
    h.rep(&research, "release", json!({"version": "1.0.6"}));
    let j2 = h.sid(json!({"kind": "decision", "title": "did not release", "base": "1.0.5"}));
    let c = h.sid(json!({"kind": "implementation", "title": "implementation", "base": "1.0.5"}));
    let reply = h.rep(&c, "applied", json!({"version": "1.0.6"}));
    assert_eq!(h.view(&research).status, "active");
    assert!(has(&reply.notices, "is not a decision session"));
    assert_eq!(
        h.detail(&c).events.last().unwrap().data["skipped"],
        json!([research])
    );
    let reply = h.rep(
        &c,
        "applied",
        json!({"version": "1.0.6", "targets": [j2, "missing-session"]}),
    );
    assert_eq!(h.view(&j2).verdict, Verdict::Expirable);
    assert!(has(
        &reply.notices,
        "Could not find session missing-session"
    ));
    let reply = h.rep(&c, "applied", json!({"version": "1.0.3"}));
    assert!(has(
        &reply.notices,
        "No session is recorded as releasing v1.0.3"
    ));
    assert!(h.try_rep(&c, "applied", json!({})).is_err());
}

#[test]
fn applied_from_a_session_that_is_not_implementation_confirms_nothing() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    let r = h.sid(json!({"kind": "research", "title": "research", "base": "1.0.5"}));
    let reply = h.rep(&r, "applied", json!({"version": "1.0.6", "targets": [j]}));
    assert!(has(&reply.notices, "Only implementation sessions confirm"));
    let s = h.view(&j);
    assert_eq!((s.status.as_str(), s.ack_at), ("active", None));
    assert_eq!(h.view(&r).base_current.as_deref(), Some("1.0.6"));
}

#[test]
fn applied_moves_the_own_base_forward_only() {
    let h = H::new();
    let c = h.sid(json!({"kind": "implementation", "base": "1.0.5"}));
    h.rep(&c, "applied", json!({"version": "1.0.3"}));
    assert_eq!(h.view(&c).base_current.as_deref(), Some("1.0.5"));
    h.rep(&c, "applied", json!({"version": "1.0.6"}));
    assert_eq!(h.view(&c).base_current.as_deref(), Some("1.0.6"));
}

#[test]
fn an_implementation_sync_hands_off_the_releasing_decision_session() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision 1.0.6", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    let research =
        h.sid(json!({"kind": "research", "title": "research syncs too", "base": "1.0.5"}));
    h.rep(&research, "sync", json!({"version": "1.0.6"}));
    assert_eq!(
        h.view(&j).status,
        "active",
        "only implementation sessions hand off"
    );
    let c = h.sid(json!({"kind": "implementation", "title": "core channel", "base": "1.0.5"}));
    let reply = h.rep(
        &c,
        "sync",
        json!({"version": "1.0.6", "summary": "synced 1.0.6"}),
    );
    let s = h.view(&j);
    assert_eq!(
        (
            s.status.as_str(),
            s.merged_into.as_deref(),
            s.ack_at,
            s.verdict
        ),
        ("merged", Some("1.0.6"), None, Verdict::Confirm)
    );
    assert!(reply
        .notices
        .iter()
        .any(|n| n.starts_with(&format!("{j} → v1.0.6 merged (sync seen"))));
    let merged = h
        .detail(&j)
        .events
        .into_iter()
        .rfind(|e| e.kind == "merged")
        .unwrap();
    assert_eq!(
        (
            merged.data["by"].as_str(),
            merged.data["via"].as_str(),
            merged.data["fromStatus"].as_str()
        ),
        (Some(c.as_str()), Some("sync"), Some("active"))
    );
    let overview = h.overview();
    assert!(
        !overview.open.iter().any(|s| s.id == j),
        "it no longer blocks the next decision"
    );
    assert!(overview.finished.iter().any(|s| s.id == j));
    assert_eq!(
        h.detail(&c).events.last().unwrap().data["handoff"],
        json!([j])
    );
    h.rep(&c, "sync", json!({"version": "1.0.6"}));
    assert_eq!(
        h.detail(&j)
            .events
            .iter()
            .filter(|e| e.kind == "merged")
            .count(),
        1,
        "once"
    );
    h.rep(
        &c,
        "applied",
        json!({"version": "1.0.6", "summary": "applied"}),
    );
    assert_eq!(h.view(&j).verdict, Verdict::Expirable);
}

#[test]
fn a_sync_hand_off_keeps_questions_and_skips_other_kinds_and_finished_sessions() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision", "base": "1.0.5"}));
    h.rep(&j, "release", json!({"version": "1.0.6"}));
    h.rep(&j, "question", json!({"question": "Next meeting?"}));
    let c = h.sid(json!({"kind": "implementation", "title": "implementation", "base": "1.0.5"}));
    h.rep(&c, "sync", json!({"version": "1.0.6"}));
    assert_eq!(
        (h.view(&j).status.as_str(), h.view(&j).verdict),
        ("merged", Verdict::NeedsHuman)
    );
    let d = h.sid(json!({"kind": "baseline", "title": "baseline work", "base": "1.0.5"}));
    h.rep(&d, "release", json!({"version": "1.0.7"}));
    h.rep(&c, "sync", json!({"version": "1.0.7"}));
    assert_eq!(h.view(&d).status, "active", "not a decision session");
    let k = h.sid(json!({"kind": "decision", "title": "closed decision", "base": "1.0.5"}));
    h.rep(&k, "release", json!({"version": "1.0.8"}));
    h.human(json!({"action": "set_status", "sessionId": k, "status": "closed"}))
        .unwrap();
    h.rep(&c, "sync", json!({"version": "1.0.8"}));
    assert_eq!(
        h.view(&k).status,
        "closed",
        "finished sessions are left alone"
    );
    h.rep(
        &j,
        "progress",
        json!({"summary": "the decision chat is used again"}),
    );
    assert_eq!(
        (h.view(&j).status.as_str(), h.view(&j).merged_into.clone()),
        ("active", None)
    );
}

#[test]
fn bodies_and_several_questions_in_one_report() {
    let h = H::new();
    let c = h.sid(json!({"kind": "implementation", "title": "core"}));
    let body =
        "## Check\r\n| Item | Result |\n|---|---|\n| Repo | clean |\n\nDecisions\n1. fix the join";
    let reply = h.rep(
        &c,
        "progress",
        json!({"summary": "checked", "body": body,
        "questions": ["Fix the join?", "Add a line, too?"]}),
    );
    assert_eq!(reply.question_ids.len(), 2);
    let text = crate::text::report(&reply);
    assert!(text.contains(&format!(
        "Questions #{}·#{} registered",
        reply.question_ids[0], reply.question_ids[1]
    )));
    let detail = h.detail(&c);
    assert_eq!(
        detail.events.last().unwrap().body.as_deref(),
        Some(body.replace("\r\n", "\n").as_str())
    );
    assert_eq!(
        (detail.session.verdict, detail.session.open_questions),
        (Verdict::NeedsHuman, 2)
    );
    // One string is one question, commas and all.
    let one = h.rep(&c, "progress", json!({"questions": "Yes, or no?"}));
    assert_eq!(one.question_ids, [reply.question_ids[1] + 1]);
    assert_eq!(h.detail(&c).questions.last().unwrap().text, "Yes, or no?");
    // A heartbeat carries no body.
    h.rep(&c, "heartbeat", json!({"body": "ignored"}));
    assert_eq!(h.detail(&c).events.len(), detail.events.len() + 1);
}

#[test]
fn long_bodies_are_cut_to_the_limit() {
    let h = H::new();
    let c = h.sid(json!({}));
    let reply = h.rep(
        &c,
        "progress",
        json!({"body": "가".repeat(report::BODY_MAX + 500)}),
    );
    assert!(has(&reply.notices, "was cut"));
    let body = h.detail(&c).events.pop().unwrap().body.unwrap();
    assert_eq!(body.chars().count(), report::BODY_MAX);
    assert!(body.ends_with("(cut by the ledger: the report body was too long)"));
    let exact = h.rep(
        &c,
        "progress",
        json!({"body": "x".repeat(report::BODY_MAX)}),
    );
    assert!(!has(&exact.notices, "was cut"));
}

#[test]
fn overlap_notices_between_open_sessions() {
    let h = H::new();
    h.start(json!({"touches": ["F-12", "Q-03"]}));
    let reply = h.start(json!({"title": "B", "kind": "decision", "touches": ["F-12", "S-07"]}));
    assert!(
        reply
            .notices
            .iter()
            .any(|n| n.starts_with("Overlap") && n.contains("F-12")),
        "{:?}",
        reply.notices
    );
    assert!(has(
        &reply.notices,
        "Other open sessions in this project (1)"
    ));
    let overlaps = h.state(Range::All).overlaps;
    assert_eq!(overlaps.len(), 1);
    assert_eq!(
        (overlaps[0].paths.clone(), overlaps[0].kind),
        (vec!["F-12".to_string()], "same")
    );
}

#[test]
fn done_with_open_questions_says_so() {
    let h = H::new();
    let id = h.sid(json!({}));
    h.rep(&id, "question", json!({"question": "?"}));
    let reply = h.rep(&id, "done", json!({}));
    assert!(has(&reply.notices, "1 open question(s) remain"));
    assert_eq!(reply.session.verdict, Verdict::NeedsHuman);
}

#[test]
fn every_write_bumps_rev_and_reads_do_not() {
    let h = H::new();
    let r0 = h.db.rev().unwrap();
    let id = h.sid(json!({}));
    let r1 = h.db.rev().unwrap();
    h.human(json!({"action": "ack", "sessionId": id})).unwrap();
    let r2 = h.db.rev().unwrap();
    assert!(r0 < r1 && r1 < r2);
    h.detail(&id);
    h.state(Range::All);
    h.overview();
    assert_eq!(h.db.rev().unwrap(), r2);
}
