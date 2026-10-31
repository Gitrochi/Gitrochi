//! Short English text for agents. Every reply lands in an agent's context, so it says
//! only what the agent needs: what was recorded, what to watch for, what a person said.

use crate::event::Message;
use crate::report::ReportReply;
use crate::session::SessionView;
use crate::streams::StreamCycle;
use crate::util::{one_line, truncate, Ms, DAY, HOUR};
use crate::views::{Overview, SessionDetail, StreamSummary};
use crate::vocab::{self, Verdict};

pub fn ago(ms: Ms, now: Ms) -> String {
    let seconds = (now - ms).max(0) / 1000;
    if seconds < 60 {
        "just now".into()
    } else if seconds < 3600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h ago", seconds * 1000 / HOUR)
    } else {
        format!("{}d ago", seconds * 1000 / DAY)
    }
}

fn kind_or_dash(kind: &str) -> &str {
    if kind.is_empty() {
        "-"
    } else {
        kind
    }
}

/// `S1031-02 implementation “Fix login retry” · base 1.4.0 (2 behind) · Needs a person (1 question) · src/auth · 2h ago`
pub fn session_line(view: &SessionView, now: Ms) -> String {
    let mut parts = vec![format!(
        "{} {} “{}”",
        view.id,
        kind_or_dash(&view.kind),
        view.title
    )];
    if let Some(base) = &view.base_current {
        parts.push(match view.behind {
            Some(behind) if behind > 0 => format!("base {base} ({behind} behind)"),
            _ => format!("base {base} (latest)"),
        });
    }
    let mut verdict = view.verdict.label().to_string();
    if view.open_questions > 0 {
        verdict.push_str(&format!(
            " ({} question{})",
            view.open_questions,
            if view.open_questions == 1 { "" } else { "s" }
        ));
    }
    parts.push(verdict);
    if !view.touches.is_empty() {
        parts.push(truncate(&view.touches.join(", "), 120));
    }
    parts.push(ago(view.last_at, now));
    parts.join(" · ")
}

fn cycle_text(cycle: &StreamCycle, now: Ms) -> String {
    let version = if cycle.version.is_empty() {
        "(no base)".to_string()
    } else {
        format!("v{}", cycle.version)
    };
    match cycle.state {
        "applied" => format!(
            "{version} applied ({})",
            ago(cycle.applied_at.unwrap_or(cycle.last_at), now)
        ),
        "active" => match cycle.synced_at {
            Some(at) => format!("{version} in progress (synced {})", ago(at, now)),
            None => format!("{version} in progress"),
        },
        _ => format!("{version} moved on without an applied report"),
    }
}

fn stream_line(stream: &StreamSummary, now: Ms) -> String {
    let view = &stream.session;
    let line = view.stream.as_ref().map(|s| s.line.as_str()).unwrap_or("");
    let mut text = String::new();
    if !line.is_empty() && line != crate::settings::DEFAULT_LINE {
        text.push_str(&format!("[{line}] "));
    }
    text.push_str(&format!("{} “{}”", view.id, stream.label));
    if let Some(cycle) = stream.cycles.first() {
        text.push(' ');
        text.push_str(&cycle_text(cycle, now));
    }
    if matches!(view.verdict, Verdict::NeedsHuman | Verdict::Stale) {
        text.push_str(&format!(" · {}", view.verdict.label()));
        if view.open_questions > 0 {
            text.push_str(&format!(" ({} question(s))", view.open_questions));
        }
    }
    text.push_str(&format!(" · {}", ago(view.last_at, now)));
    text
}

fn messages_block(lines: &mut Vec<String>, messages: &[Message]) {
    if !messages.is_empty() {
        lines.push("From a person to this session (act on these):".into());
        lines.extend(messages.iter().map(|m| format!("  - {}", m.text)));
    }
}

pub fn overview(data: &Overview, now: Ms) -> String {
    let Some(project) = &data.project else {
        return if data.projects.is_empty() {
            "The ledger has no projects yet. Report a start with a project name to begin.".into()
        } else {
            format!("Name a project: {}", data.projects.join(", "))
        };
    };
    let mut lines = Vec::new();
    let recent: Vec<String> = data
        .recent_baselines
        .iter()
        .map(|b| match &b.by_session {
            Some(by) => format!("{} (released by {by})", b.version),
            None => b.version.clone(),
        })
        .collect();
    let mut head = format!(
        "[{project}] HEAD {}",
        data.head.as_deref().unwrap_or("(no baselines yet)")
    );
    if !recent.is_empty() {
        head.push_str(&format!(" · recent baselines: {}", recent.join(" → ")));
    }
    lines.push(head);
    lines.push(if data.open.is_empty() {
        "Open sessions: 0".to_string()
    } else {
        format!("Open sessions ({}):", data.open.len())
    });
    lines.extend(
        data.open
            .iter()
            .map(|s| format!("• {}", session_line(s, now))),
    );
    if !data.finished.is_empty() {
        let items: Vec<String> = data
            .finished
            .iter()
            .map(|s| {
                let mut item = format!("{} ({}", s.id, vocab::status_label(&s.status));
                if let Some(into) = &s.merged_into {
                    item.push_str(&format!(" → {into}"));
                }
                item.push_str(&format!(", {})", s.verdict.label()));
                item
            })
            .collect();
        lines.push(format!(
            "Finished, not archived yet ({}): {}",
            data.finished.len(),
            items.join("; ")
        ));
    }
    if !data.streams.is_empty() {
        let items: Vec<String> = data.streams.iter().map(|s| stream_line(s, now)).collect();
        lines.push(format!(
            "Streams (ongoing implementation, not for clean-up): {}",
            items.join("; ")
        ));
    }
    if !data.shelved.is_empty() {
        let items: Vec<String> = data
            .shelved
            .iter()
            .map(|s| {
                format!(
                    "{} {} “{}”",
                    s.id,
                    kind_or_dash(&s.kind),
                    truncate(&s.title, 40)
                )
            })
            .collect();
        lines.push(format!(
            "Shelved ({}, paused without a merge; material to reuse): {}",
            data.shelved.len(),
            items.join("; ")
        ));
    }
    for overlap in &data.overlaps {
        lines.push(format!(
            "⚠ Overlap: {} ↔ {} ({})",
            overlap.a,
            overlap.b,
            overlap.paths.join(", ")
        ));
    }
    messages_block(&mut lines, &data.messages);
    lines.join("\n")
}

pub fn report(reply: &ReportReply) -> String {
    let view = &reply.session;
    let mut lines = vec![format!(
        "Recorded ✓ {} · {} · status {} · {}",
        view.id,
        reply.event,
        vocab::status_label(&view.status),
        view.verdict.label()
    )];
    if reply.created {
        lines.push(format!(
            "New session ID: {} — use session=\"{}\" in this conversation's later reports, and tell the user the ID.",
            view.id, view.id
        ));
    }
    let mut base = format!(
        "Base {} · HEAD {}",
        view.base_current.as_deref().unwrap_or("-"),
        reply.head.as_deref().unwrap_or("-")
    );
    if let Some(behind) = view.behind.filter(|b| *b > 0) {
        base.push_str(&format!(" ({behind} behind)"));
    }
    lines.push(base);
    if !reply.question_ids.is_empty() {
        let ids: Vec<String> = reply
            .question_ids
            .iter()
            .map(|id| format!("#{id}"))
            .collect();
        lines.push(format!(
            "Question{} {} registered — a person's answer arrives with a later report or read.",
            if ids.len() == 1 { "" } else { "s" },
            ids.join("·")
        ));
    }
    if !reply.notices.is_empty() {
        lines.push("Notices:".into());
        lines.extend(reply.notices.iter().map(|n| format!("  - {n}")));
    }
    messages_block(&mut lines, &reply.messages);
    lines.join("\n")
}

pub fn session(detail: &SessionDetail, messages: &[Message], now: Ms) -> String {
    let view = &detail.session;
    let mut status = format!(
        "Project {} · status {}",
        view.project,
        vocab::status_label(&view.status)
    );
    if let Some(into) = &view.merged_into {
        status.push_str(&format!(" · merged into {into}"));
    }
    status.push_str(&format!(
        " · started from {}{}",
        view.base_version.as_deref().unwrap_or("?"),
        if view.base_was_latest {
            " (then latest)"
        } else {
            ""
        }
    ));
    status.push_str(&format!(
        " · HEAD {}",
        detail.head.as_deref().unwrap_or("-")
    ));
    let mut lines = vec![session_line(view, now), status];
    let open: Vec<_> = detail
        .questions
        .iter()
        .filter(|q| q.state == "open")
        .collect();
    if !open.is_empty() {
        lines.push("Open questions:".into());
        lines.extend(open.iter().map(|q| format!("  #{} {}", q.id, q.text)));
    }
    let answered: Vec<_> = detail
        .questions
        .iter()
        .filter(|q| q.state == "answered")
        .collect();
    if !answered.is_empty() {
        lines.push("Answered questions:".into());
        lines.extend(answered.iter().map(|q| {
            format!(
                "  #{} {} → {} ({})",
                q.id,
                q.text,
                q.answer.as_deref().unwrap_or(""),
                q.answered_by
                    .as_deref()
                    .or(q.resolved_by.as_deref())
                    .unwrap_or("-")
            )
        }));
    }
    messages_block(&mut lines, messages);
    if !detail.cycles.is_empty() {
        let cycles: Vec<String> = detail
            .cycles
            .iter()
            .take(4)
            .map(|c| cycle_text(c, now))
            .collect();
        lines.push(format!("Cycles: {}", cycles.join("; ")));
    }
    lines.push("Recent events:".into());
    let start = detail.events.len().saturating_sub(12);
    for event in &detail.events[start..] {
        let artifacts: Vec<String> = event
            .artifacts
            .iter()
            .filter_map(|a| {
                let name = a["name"].as_str()?;
                Some(match a["ssot"].as_str() {
                    Some(v) => format!("{name}@{v}"),
                    None => name.to_string(),
                })
            })
            .collect();
        let mut line = format!(
            "  {} [{}:{}] {}",
            ago(event.ts, now),
            event.actor,
            event.kind,
            one_line(&event.summary, 160)
        );
        if !artifacts.is_empty() {
            line.push_str(&format!(" ({})", artifacts.join(", ")));
        }
        lines.push(line);
    }
    lines.join("\n")
}
