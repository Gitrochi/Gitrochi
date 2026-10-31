//! Scenario tests on temporary databases. Each test gets a project whose baselines come from
//! a folder (v1.0.0, v1.0.3, v1.0.5 and a folder that is not a version) and a clock that
//! moves one second per operation, so event order is exact.

mod reports;
mod storage;
mod streams;
mod views;

use crate::baseline;
use crate::db::Db;
use crate::error::Result;
use crate::human;
use crate::report::{self, ReportReply};
use crate::session::SessionView;
use crate::settings::Settings;
use crate::util::{now_ms, Ms};
use crate::views::{self as v, Overview, Range, SessionDetail, State};
use serde_json::{json, Value};
use std::cell::Cell;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

pub const P: &str = "Example App";
pub const HOUR: Ms = crate::util::HOUR;

static NEXT: AtomicUsize = AtomicUsize::new(0);

pub fn temp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "gitrochi-ledger-{label}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

pub struct H {
    pub dir: PathBuf,
    pub folder: PathBuf,
    pub db: Db,
    clock: Cell<Ms>,
}

impl Drop for H {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn merge(mut base: Value, extra: Value) -> Value {
    if let Value::Object(map) = extra {
        for (k, v) in map {
            base[k] = v;
        }
    }
    base
}

impl H {
    pub fn new() -> H {
        let dir = temp_dir("scenario");
        let folder = dir.join("baselines");
        for version in ["1.0.0", "1.0.3", "1.0.5"] {
            std::fs::create_dir_all(folder.join(format!("v{version}"))).unwrap();
        }
        std::fs::create_dir_all(folder.join("backup_old")).unwrap();
        let db = Db::open(&dir.join("ledger.sqlite3")).unwrap();
        let now = now_ms();
        db.write(|c| {
            baseline::set_project(
                c,
                &json!({"project": P, "baselineSource": "folder", "baselineDir": folder.to_string_lossy()}),
                now,
            )
        })
        .unwrap();
        let scan = baseline::refresh(&db, P, true).unwrap();
        assert_eq!((scan.found, scan.added, scan.error), (3, 3, None));
        H {
            dir,
            folder,
            db,
            clock: Cell::new(now),
        }
    }

    pub fn now(&self) -> Ms {
        self.clock.get()
    }

    pub fn tick(&self) -> Ms {
        self.clock.set(self.clock.get() + 1000);
        self.clock.get()
    }

    pub fn advance(&self, ms: Ms) {
        self.clock.set(self.clock.get() + ms);
    }

    pub fn report_at(&self, ts: Ms, args: Value) -> Result<ReportReply> {
        let now = self.now().max(ts);
        Ok(self
            .db
            .write(|c| {
                let settings = Settings::load(c)?;
                report::report(c, &settings, &args, "cli", ts, now)
            })?
            .0)
    }

    pub fn try_report(&self, args: Value) -> Result<ReportReply> {
        let ts = self.tick();
        self.report_at(ts, args)
    }

    /// A start with defaults (research, base 1.0.0) overridden by `extra`.
    pub fn start(&self, extra: Value) -> ReportReply {
        let args = merge(
            json!({"project": P, "event": "start", "kind": "research", "title": "Title",
                   "base": "1.0.0", "summary": "start"}),
            extra,
        );
        self.try_report(args).unwrap()
    }

    pub fn sid(&self, extra: Value) -> String {
        self.start(extra).session_id
    }

    pub fn try_rep(&self, session: &str, event: &str, extra: Value) -> Result<ReportReply> {
        let args = merge(
            json!({"session": session, "event": event, "summary": event}),
            extra,
        );
        self.try_report(args)
    }

    pub fn rep(&self, session: &str, event: &str, extra: Value) -> ReportReply {
        self.try_rep(session, event, extra).unwrap()
    }

    pub fn human(&self, args: Value) -> Result<()> {
        let now = self.tick();
        self.db
            .write(|c| {
                let settings = Settings::load(c)?;
                human::apply(c, &settings, &args, now)
            })
            .map(|_| ())
    }

    pub fn detail(&self, session: &str) -> SessionDetail {
        let now = self.now();
        self.db
            .read(|c| v::session_detail(c, &Settings::load(c)?, session, now))
            .unwrap()
    }

    pub fn view(&self, session: &str) -> SessionView {
        self.detail(session).session
    }

    pub fn state(&self, range: Range) -> State {
        let now = self.now();
        self.db
            .read(|c| {
                v::state(
                    c,
                    &Settings::load(c)?,
                    Some(P),
                    range,
                    crate::db::rev(c)?,
                    now,
                )
            })
            .unwrap()
    }

    pub fn overview(&self) -> Overview {
        let now = self.now();
        self.db
            .read(|c| v::overview(c, &Settings::load(c)?, Some(P), Vec::new(), now))
            .unwrap()
    }

    pub fn versions(&self) -> Vec<(String, String)> {
        self.db
            .read(|c| baseline::trunk(c, P))
            .unwrap()
            .into_iter()
            .map(|b| (b.version, b.source))
            .collect()
    }
}

pub fn has(notices: &[String], needle: &str) -> bool {
    notices.iter().any(|n| n.contains(needle))
}
