//! Streams: live implementation sessions are kept out of clean-up and overlaps and shown as
//! cycles per baseline; a second line can be configured not to hand off.

use super::*;
use crate::vocab::Verdict;

#[test]
fn cycles_group_reports_by_baseline() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision 1.0.6", "base": "1.0.5"}));
    h.rep(
        &j,
        "release",
        json!({"version": "1.0.6", "summary": "released"}),
    );
    let c = h.sid(
        json!({"kind": "implementation", "title": "Core channel — first task", "base": "1.0.5",
                          "touches": ["F-12"]}),
    );
    h.rep(
        &c,
        "artifact",
        json!({"summary": "tidy up before the sync"}),
    );
    h.rep(
        &c,
        "sync",
        json!({"version": "1.0.6", "summary": "synced 1.0.6"}),
    );
    h.rep(
        &c,
        "artifact",
        json!({"summary": "measured", "artifacts": [{"name": "CD-1 measurement"}]}),
    );
    h.rep(
        &c,
        "applied",
        json!({"version": "1.0.6", "summary": "applied: 2 started, 0 left"}),
    );
    h.rep(&c, "progress", json!({"summary": "after applying"}));
    h.rep(
        &c,
        "sync",
        json!({"version": "1.0.7", "summary": "synced 1.0.7"}),
    );

    let overview = h.overview();
    assert!(
        !overview.open.iter().any(|s| s.id == c),
        "a stream is not an open session"
    );
    assert_eq!(
        overview
            .streams
            .iter()
            .map(|s| s.session.id.as_str())
            .collect::<Vec<_>>(),
        [c.as_str()]
    );
    let stream = &overview.streams[0];
    assert_eq!(stream.label, "Core channel");
    let states: Vec<_> = stream
        .cycles
        .iter()
        .map(|y| (y.version.as_str(), y.state))
        .collect();
    assert_eq!(
        states,
        [
            ("1.0.7", "active"),
            ("1.0.6", "applied"),
            ("1.0.5", "skipped")
        ]
    );
    let middle = &stream.cycles[1];
    assert_eq!(middle.released_by.as_deref(), Some(j.as_str()));
    assert_eq!(middle.artifacts, ["CD-1 measurement"]);
    assert_eq!(middle.events, 4);
    assert_eq!(middle.sync_summary.as_deref(), Some("synced 1.0.6"));
    assert_eq!(
        middle.applied_summary.as_deref(),
        Some("applied: 2 started, 0 left")
    );
    assert!(middle.event_ids.is_empty(), "agents get the short form");
    let state = h.state(Range::All);
    let full: Vec<_> = state
        .streams
        .iter()
        .filter(|y| y.version == "1.0.6")
        .collect();
    assert_eq!(full[0].event_ids.len(), 4);
    assert_eq!(full[0].line, "core");
    let text = crate::text::overview(&overview, h.now());
    assert!(text.contains("Open sessions: 0"), "{text}");
    assert!(text.contains(&format!("Streams (ongoing implementation, not for clean-up): {c} “Core channel” v1.0.7 in progress (synced")), "{text}");
    assert_eq!(state.projects.iter().find(|p| p.key == P).unwrap().open, 0);
    assert!(h.view(&c).is_stream());
    h.rep(
        &c,
        "applied",
        json!({"version": "1.0.7", "summary": "applied 1.0.7"}),
    );
    assert!(crate::text::overview(&h.overview(), h.now()).contains("v1.0.7 applied ("));
}

#[test]
fn streams_stay_out_of_overlaps_and_return_to_clean_up_when_closed() {
    let h = H::new();
    let c =
        h.sid(json!({"kind": "implementation", "title": "channel", "touches": ["F-12", "CD-1"]}));
    let other = h.start(json!({"kind": "decision", "title": "F-12 decision", "touches": ["F-12"]}));
    assert!(!other
        .notices
        .iter()
        .any(|n| n.starts_with("Overlap") || n.contains("Other open sessions")));
    assert!(!h
        .rep(&c, "artifact", json!({"summary": "measured"}))
        .notices
        .iter()
        .any(|n| n.starts_with("Overlap")));
    assert!(h.overview().overlaps.is_empty());
    h.rep(&c, "question", json!({"question": "CD-1 first?"}));
    let text = crate::text::overview(&h.overview(), h.now());
    assert!(text.contains("Needs a person (1 question(s))"), "{text}");
    h.human(json!({"action": "set_status", "sessionId": c, "status": "closed"}))
        .unwrap();
    let overview = h.overview();
    assert!(overview.streams.is_empty());
    assert_eq!(
        overview
            .finished
            .iter()
            .map(|s| s.id.as_str())
            .collect::<Vec<_>>(),
        [c.as_str()]
    );
    assert!(!h.view(&c).is_stream());
    h.rep(&c, "progress", json!({"summary": "used again"}));
    assert_eq!(
        h.overview().streams.len(),
        1,
        "the resume rule makes it a stream again"
    );
    // A stream still goes stale and still shows questions.
    assert_eq!(h.view(&c).verdict, Verdict::NeedsHuman);
}

#[test]
fn a_line_without_hand_off_marks_its_cycles_only() {
    let h = H::new();
    let j = h.sid(json!({"kind": "decision", "title": "decision 1.0.6", "base": "1.0.5"}));
    h.rep(
        &j,
        "release",
        json!({"version": "1.0.6", "summary": "released"}),
    );
    let reply = h.start(
        json!({"kind": "LLM 구현", "title": "Local channel — rewriting worker", "base": "1.0.5"}),
    );
    let llm = reply.session_id;
    let view = h.view(&llm);
    assert_eq!(view.kind, "llm-implementation");
    assert_eq!(view.stream.as_ref().map(|s| s.line.as_str()), Some("llm"));
    h.rep(
        &llm,
        "sync",
        json!({"version": "1.0.6", "summary": "took 1.0.6"}),
    );
    assert_eq!(h.view(&j).status, "active", "no hand-off from this line");
    let reply = h.rep(
        &llm,
        "applied",
        json!({"version": "1.0.6", "summary": "done", "targets": [j]}),
    );
    assert!(has(
        &reply.notices,
        "The llm line's applied v1.0.6 marks its cycle only"
    ));
    let s = h.view(&j);
    assert_eq!((s.status.as_str(), s.ack_at), ("active", None));
    let applied = h
        .detail(&llm)
        .events
        .into_iter()
        .find(|e| e.kind == "applied")
        .unwrap();
    assert_eq!(
        (
            applied.data["line"].clone(),
            applied.data["targets"].clone()
        ),
        (json!("llm"), json!([]))
    );

    let core = h.sid(
        json!({"kind": "implementation", "title": "Core channel — directive", "base": "1.0.5"}),
    );
    h.rep(&core, "sync", json!({"version": "1.0.6"}));
    assert_eq!(h.view(&j).status, "merged");
    h.rep(&core, "applied", json!({"version": "1.0.6"}));
    assert!(h.view(&j).ack_at.is_some());

    let overview = h.overview();
    let mut lines: Vec<_> = overview
        .streams
        .iter()
        .map(|s| (s.session.stream.clone().unwrap().line, s.session.id.clone()))
        .collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            ("core".to_string(), core.clone()),
            ("llm".to_string(), llm.clone())
        ]
    );
    let llm_stream = overview
        .streams
        .iter()
        .find(|s| s.session.id == llm)
        .unwrap();
    let states: Vec<_> = llm_stream
        .cycles
        .iter()
        .map(|y| (y.version.as_str(), y.state))
        .collect();
    assert_eq!(states, [("1.0.6", "applied"), ("1.0.5", "skipped")]);
    let text = crate::text::overview(&overview, h.now());
    assert!(
        text.contains(&format!("[llm] {llm} “Local channel” v1.0.6 applied (")),
        "{text}"
    );
    assert!(text.contains(&format!("{core} “Core channel”")), "{text}");
    assert!(
        !text.contains(&format!("[core] {core}")),
        "the default line is not tagged"
    );
}

#[test]
fn roles_and_lines_follow_the_settings() {
    let h = H::new();
    h.db.write(|c| {
        let values = json!({"kinds": {
            "decision": {"role": "decision"},
            "implementation": {"role": "implementation", "line": "main"},
            "spike": {"role": "research"},
            "pairing": {"role": "implementation", "line": "pair", "handoff": false}
        }});
        crate::settings::store(c, values.as_object().unwrap(), h.now())
    })
    .unwrap();
    let spike = h.sid(json!({"kind": "spike", "title": "spike"}));
    h.rep(&spike, "shelved", json!({"summary": "parked"}));
    assert_eq!(
        h.view(&spike).verdict,
        Verdict::Shelved,
        "a configured research kind may be shelved"
    );
    let research = h.sid(json!({"kind": "research", "title": "no longer configured"}));
    assert!(h.try_rep(&research, "shelved", json!({})).is_err());
    let main = h.sid(json!({"kind": "implementation", "title": "main"}));
    assert_eq!(h.view(&main).stream.unwrap().line, "main");
    let pair = h.sid(json!({"kind": "pairing", "title": "pair"}));
    assert_eq!(h.view(&pair).role, "implementation");
    // Resetting restores the defaults.
    h.db.write(|c| crate::settings::store(c, json!({"kinds": null}).as_object().unwrap(), h.now()))
        .unwrap();
    assert_eq!(h.view(&main).stream.unwrap().line, "core");
    assert_eq!(h.view(&spike).role, "other");
}
