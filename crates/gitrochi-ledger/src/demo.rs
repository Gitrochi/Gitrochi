//! Demo data for screenshots, the apps' demo backends and timing tests: two neutral
//! projects with every verdict, a stream with cycles, questions, waiting prompts and an
//! overlap. `large` adds 1,000 sessions and 50,000 events.

use crate::baseline;
use crate::db::Db;
use crate::error::Result;
use crate::event::{self, NewEvent};
use crate::human;
use crate::prompts;
use crate::report;
use crate::settings::Settings;
use crate::util::{Ms, DAY, HOUR};
use rusqlite::params;
use serde_json::{json, Value};

pub const APP: &str = "Example App";
pub const DOCS: &str = "Docs Site";

/// What the demo wrote.
#[derive(Clone, Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DemoSummary {
    pub projects: usize,
    pub sessions: usize,
    pub events: usize,
    pub path: String,
}

struct Writer<'a> {
    db: &'a Db,
    now: Ms,
}

impl Writer<'_> {
    fn report(&self, at: Ms, args: Value) -> Result<String> {
        let (reply, _) = self.db.write(|c| {
            let settings = Settings::load(c)?;
            report::report(c, &settings, &args, "demo", at, self.now)
        })?;
        Ok(reply.session_id)
    }

    fn start(
        &self,
        at: Ms,
        project: &str,
        kind: &str,
        title: &str,
        base: &str,
        touches: &[&str],
    ) -> Result<String> {
        self.report(
            at,
            json!({"project": project, "event": "start", "kind": kind, "title": title, "base": base,
                   "summary": format!("Started: {title}"), "touches": touches}),
        )
    }

    fn event(&self, at: Ms, session: &str, event: &str, extra: Value) -> Result<()> {
        let mut args = json!({"session": session, "event": event});
        if let Value::Object(map) = extra {
            for (k, v) in map {
                args[k] = v;
            }
        }
        if args["summary"].is_null() {
            args["summary"] = json!(event);
        }
        self.report(at, args)?;
        Ok(())
    }

    fn human(&self, at: Ms, args: Value) -> Result<()> {
        self.db.write(|c| {
            let settings = Settings::load(c)?;
            human::apply(c, &settings, &args, at)
        })?;
        Ok(())
    }
}

/// Writes the demo into `db` (which should be empty).
pub fn seed(db: &Db, now: Ms, large: bool) -> Result<DemoSummary> {
    let w = Writer { db, now };
    let ago = |hours: f64| now - (hours * HOUR as f64) as Ms;

    // Baselines: tags of the example app, folders of the docs site.
    db.write(|c| {
        for (version, days) in [("1.0.0", 60), ("1.1.0", 45), ("1.2.0", 30), ("1.3.0", 14), ("1.4.0", 6), ("1.4.1", 3)] {
            baseline::ensure_project(c, APP, now - 90 * DAY)?;
            c.execute(
                "INSERT INTO baselines (project, version, ts, source, ref_name) VALUES (?1, ?2, ?3, 'tag', ?4)",
                params![APP, version, now - days * DAY, format!("v{version}")],
            )?;
        }
        for (version, days) in [("2.0", 40), ("2.1", 9)] {
            baseline::ensure_project(c, DOCS, now - 90 * DAY)?;
            c.execute(
                "INSERT INTO baselines (project, version, ts, source, ref_name) VALUES (?1, ?2, ?3, 'folder', ?4)",
                params![DOCS, version, now - days * DAY, format!("v{version}")],
            )?;
        }
        Ok(())
    })?;

    // A decision session releases 1.4.2; the implementation stream applied 1.4.0 and has
    // synced 1.4.2 (so the decision session waits for confirmation), three cycles in all.
    let decision = w.start(
        ago(70.0),
        APP,
        "decision",
        "Retry policy for the sync client",
        "1.4.1",
        &["src/sync/retry.rs"],
    )?;
    w.event(
        ago(60.0),
        &decision,
        "decision",
        json!({"summary": "Retry 3 times with jitter; give up after 30 s"}),
    )?;
    w.event(
        ago(50.0),
        &decision,
        "release",
        json!({"version": "1.4.2", "summary": "Release 1.4.2 with the retry policy"}),
    )?;
    let stream = w.start(
        ago(200.0),
        APP,
        "implementation",
        "Core channel — feature work",
        "1.3.0",
        &["src/sync"],
    )?;
    w.event(
        ago(190.0),
        &stream,
        "sync",
        json!({"version": "1.4.0", "summary": "Synced 1.4.0"}),
    )?;
    w.event(
        ago(180.0),
        &stream,
        "artifact",
        json!({"summary": "Offline queue", "artifacts": [{"name": "Offline queue", "ver": "r1"}]}),
    )?;
    w.event(
        ago(150.0),
        &stream,
        "applied",
        json!({"version": "1.4.0", "summary": "Applied 1.4.0"}),
    )?;
    w.event(
        ago(48.0),
        &stream,
        "sync",
        json!({"version": "1.4.2", "summary": "Synced 1.4.2"}),
    )?;
    w.event(ago(30.0), &stream, "artifact", json!({"summary": "Retry with jitter", "artifacts": [{"name": "Retry with jitter"}],
        "body": "## Done\n| Step | Result |\n|---|---|\n| Retry | 3 tries, jitter |\n| Tests | pass |"}))?;
    w.event(
        ago(2.0),
        &stream,
        "progress",
        json!({"summary": "Cleaning up after 1.4.2"}),
    )?;

    // Every verdict.
    let asking = w.start(
        ago(9.0),
        APP,
        "research",
        "Login retry options",
        "1.4.1",
        &["src/auth/login.rs", "src/sync/retry.rs"],
    )?;
    w.event(
        ago(3.0),
        &asking,
        "question",
        json!({"question": "Retry 3 or 5 times on a 503?", "summary": "Asked about retries"}),
    )?;
    let research = w.start(
        ago(30.0),
        APP,
        "research",
        "Cache spike",
        "1.4.1",
        &["src/cache"],
    )?;
    w.event(ago(26.0), &research, "artifact", json!({"summary": "Benchmark table", "artifacts": [{"name": "Cache benchmark", "ssot": "1.4.1", "ver": "r2"}]}))?;
    w.event(
        ago(25.0),
        &research,
        "done",
        json!({"summary": "Findings written up"}),
    )?;
    let export = w.start(
        ago(40.0),
        APP,
        "implementation",
        "Export as CSV",
        "1.4.1",
        &["src/export"],
    )?;
    w.event(
        ago(10.0),
        &export,
        "merged",
        json!({"into": "1.4.2", "summary": "Merged into 1.4.2"}),
    )?;
    let docs_fix = w.start(
        ago(80.0),
        DOCS,
        "document",
        "Fix broken links",
        "2.1",
        &["docs/links.md"],
    )?;
    w.event(
        ago(70.0),
        &docs_fix,
        "closed",
        json!({"summary": "Links fixed, nothing to merge"}),
    )?;
    w.human(ago(5.0), json!({"action": "ack", "sessionId": &docs_fix}))?;
    let quiet = w.start(
        ago(120.0),
        APP,
        "review",
        "Review the settings screen",
        "1.4.0",
        &["src/settings"],
    )?;
    w.event(
        ago(100.0),
        &quiet,
        "progress",
        json!({"summary": "Halfway through"}),
    )?;
    let shelved = w.start(
        ago(150.0),
        DOCS,
        "research",
        "Search engine options",
        "2.0",
        &["docs/search"],
    )?;
    w.event(
        ago(140.0),
        &shelved,
        "shelved",
        json!({"summary": "Waiting for usage numbers; resume when they arrive"}),
    )?;
    let archived = w.start(ago(60.0), DOCS, "document", "Release notes 2.1", "2.0", &[])?;
    w.event(
        ago(55.0),
        &archived,
        "merged",
        json!({"into": "2.1", "summary": "In 2.1"}),
    )?;
    w.human(ago(54.0), json!({"action": "ack", "sessionId": &archived}))?;
    w.human(
        ago(53.0),
        json!({"action": "archive", "sessionId": &archived}),
    )?;
    let active = w.start(
        ago(4.0),
        DOCS,
        "document",
        "Getting started guide",
        "2.1",
        &["docs/start.md"],
    )?;
    w.event(
        ago(1.0),
        &active,
        "artifact",
        json!({"summary": "Draft", "artifacts": [{"name": "Getting started", "ver": "r1"}],
        "chatUrl": "https://example.com/chat/getting-started"}),
    )?;
    // Two live sessions touching the same file: an overlap.
    let overlap = w.start(
        ago(6.0),
        APP,
        "research",
        "Retry telemetry",
        "1.4.2",
        &["src/sync/retry.rs"],
    )?;
    w.event(
        ago(5.0),
        &overlap,
        "progress",
        json!({"summary": "Collecting numbers"}),
    )?;
    w.human(
        ago(4.5),
        json!({"action": "link", "sessionId": &asking, "branch": "fix/login-retry",
        "pr": {"host": "example.com", "number": 142, "url": "https://example.com/pulls/142"}}),
    )?;
    w.human(
        ago(4.0),
        json!({"action": "message", "sessionId": &research, "text": "Please add p99 numbers."}),
    )?;

    // Prompts: one waiting for an answer, one answered automatically for review.
    db.write(|c| {
        prompts::create(
            c,
            &json!({"sessionId": &asking, "kind": "ask_user_question", "delaySec": 30,
                    "payload": {"questions": [{"question": "Which retry count?", "options": [{"label": "3 (Recommended)"}, {"label": "5"}]}]}}),
            now,
        )?;
        let auto = prompts::create(
            c,
            &json!({"sessionId": &active, "kind": "stop_question", "delaySec": 30,
                    "payload": {"text": "Shall I also add screenshots?"}}),
            now - 3_600_000,
        )?;
        prompts::resolve(
            c,
            &json!({"id": auto.id, "state": "auto", "answer": {"text": "Yes, go ahead with the safest option."}}),
            now - 3_570_000,
        )?;
        Ok(())
    })?;

    if large {
        seed_large(db, now)?;
    }
    db.read(|c| {
        Ok(DemoSummary {
            projects: c.query_row("SELECT COUNT(*) FROM projects", [], |r| r.get::<_, i64>(0))?
                as usize,
            sessions: c.query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get::<_, i64>(0))?
                as usize,
            events: c.query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0))?
                as usize,
            path: db.path.to_string_lossy().into_owned(),
        })
    })
}

/// A small deterministic generator, so large demos are the same every time.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

/// 1,000 sessions and 50,000 events in a third project over 90 days, written in one
/// transaction (reports one by one would take minutes).
fn seed_large(db: &Db, now: Ms) -> Result<()> {
    const PROJECT: &str = "Large Demo";
    const SESSIONS: usize = 1_000;
    const EVENTS: usize = 50_000;
    let kinds = [
        "research",
        "decision",
        "implementation",
        "review",
        "document",
    ];
    let statuses = [
        "active", "active", "active", "done", "merged", "closed", "dropped", "shelved",
    ];
    let types = [
        "progress", "artifact", "decision", "note", "artifact", "progress", "question",
    ];
    db.write(|c| {
        baseline::ensure_project(c, PROJECT, now - 120 * DAY)?;
        for minor in 0..40 {
            c.execute(
                "INSERT OR IGNORE INTO baselines (project, version, ts, source) VALUES (?1, ?2, ?3, 'tag')",
                params![PROJECT, format!("3.{minor}.0"), now - (90 - 2 * minor) * DAY],
            )?;
        }
        let mut random = Random(0x9E37_79B9_7F4A_7C15);
        let per_session = EVENTS / SESSIONS;
        let mut insert_session = c.prepare(
            "INSERT INTO sessions (id, project, kind, title, base_version, base_current, status, merged_into,
                touches, color, created_at, last_at, last_agent_at, ack_at, archived_at, channel)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12, ?13, ?14, 'demo')",
        )?;
        for index in 0..SESSIONS {
            let id = format!("L{index:04}");
            let kind = kinds[random.below(kinds.len() as u64) as usize];
            let mut status = statuses[random.below(statuses.len() as u64) as usize];
            if status == "shelved" && !matches!(kind, "research" | "document") {
                status = "closed";
            }
            let created = now - 90 * DAY + (index as Ms) * (88 * DAY / SESSIONS as Ms);
            let base_minor = (((created - (now - 90 * DAY)) / (2 * DAY)).clamp(0, 39)) as usize;
            let base = format!("3.{base_minor}.0");
            let current = format!("3.{}.0", (base_minor + random.below(3) as usize).min(39));
            let merged_into = (status == "merged").then(|| format!("3.{}.0", (base_minor + 1).min(39)));
            let touches = json!([format!("src/module{}", random.below(60)), format!("docs/page{}", random.below(40))]);
            let mut at = created;
            for step in 0..per_session {
                at += 1 + random.below(3 * HOUR as u64) as Ms;
                let kind_of_event = if step == 0 {
                    "start"
                } else if step + 1 == per_session && status != "active" && status != "shelved" {
                    status_event(status)
                } else {
                    types[random.below(types.len() as u64) as usize]
                };
                event::insert(
                    c,
                    &NewEvent {
                        session_id: &id,
                        project: PROJECT,
                        ts: at.min(now),
                        kind: kind_of_event,
                        actor: "agent",
                        summary: &format!("Step {step} of session {index}"),
                        body: None,
                        version: (step == 0).then_some(base.as_str()),
                        artifacts: &json!([]),
                        data: &json!({}),
                        channel: "demo",
                        delivered_at: None,
                    },
                )?;
                if kind_of_event == "question" && random.below(2) == 0 {
                    event::add_question(c, &id, &format!("Question from step {step}"), at.min(now))?;
                }
            }
            let last = at.min(now);
            let ack = (matches!(status, "merged" | "closed" | "dropped") && random.below(2) == 0).then_some(last);
            let archived = (ack.is_some() && random.below(2) == 0).then_some(last);
            insert_session.execute(params![
                id,
                PROJECT,
                kind,
                format!("Generated session {index}"),
                base,
                current,
                status,
                merged_into,
                touches.to_string(),
                (index % 8) as i64,
                created,
                last,
                ack,
                archived,
            ])?;
        }
        Ok(())
    })?;
    Ok(())
}

fn status_event(status: &str) -> &'static str {
    match status {
        "done" => "done",
        "merged" => "merged",
        "closed" => "closed",
        "dropped" => "dropped",
        _ => "progress",
    }
}
