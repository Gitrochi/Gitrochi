//! Waking a waiting agent with a person's answer (DESIGN.md §7.6). With **Wake waiting agents
//! with my answers** on (the `wakeAgents` setting, off by default), the Stop hook of an agent
//! Gitrochi launched keeps running in the background once its turn ends. As soon as a person
//! answers or dismisses one of the session's Ledger questions, or leaves it a message, the hook
//! delivers what waits — marked delivered in the same transaction, exactly as a report would —
//! and wakes the agent with it: exit 2 with the text on stderr, the `asyncRewake` wake-up the
//! stop-question path of auto-continue uses (#171). A newer SessionStart, UserPromptSubmit,
//! Stop or SessionEnd of the session releases the wait, and so does its time running out.
//!
//! The waiting hook holds a claim in `meta` (`wake:<session>` → `{token, until}`), which those
//! events delete and a newer Stop replaces, so a wait always knows whether it is still the
//! newest. The apps read the claims as `Session.wakeUntil` to say that an answer wakes the agent.

use crate::db::{self, Db};
use crate::error::{Error, Result};
use crate::event;
use crate::session::SessionView;
use crate::settings::Settings;
use crate::text;
use crate::util::{now_ms, Ms};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;

/// The Stop entry's timeout is 310 s (the longest auto-continue wait plus a 10 s margin), so a
/// wait ends by then; the shortest matches auto-continue's.
pub const MAX_WAIT_SEC: u64 = 300;
pub const MIN_WAIT_SEC: u64 = 10;
pub const DEFAULT_WAIT_SEC: u64 = 300;

/// How often a waiting hook reads `rev`; the rest is read only when it moved.
pub const POLL: Duration = Duration::from_millis(250);

const KEY: &str = "wake:";

/// `wakeAgents`: whether Stop hooks wait for a person's answer, and for how long.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WakeSetting {
    pub enabled: bool,
    pub wait_sec: u64,
}

impl Default for WakeSetting {
    fn default() -> Self {
        WakeSetting {
            enabled: false,
            wait_sec: DEFAULT_WAIT_SEC,
        }
    }
}

impl WakeSetting {
    /// Reads `{enabled?, waitSec?}`; a missing field keeps its default.
    pub fn parse(value: &Value) -> Result<WakeSetting> {
        let object = value
            .as_object()
            .ok_or_else(|| Error::invalid("wakeAgents must be an object"))?;
        let mut setting = WakeSetting::default();
        match object.get("enabled") {
            None => {}
            Some(Value::Bool(enabled)) => setting.enabled = *enabled,
            Some(_) => return Err(Error::invalid("wakeAgents.enabled must be true or false")),
        }
        if let Some(wait) = object.get("waitSec") {
            setting.wait_sec = wait
                .as_u64()
                .filter(|w| (MIN_WAIT_SEC..=MAX_WAIT_SEC).contains(w))
                .ok_or_else(|| {
                    Error::invalid(format!(
                        "wakeAgents.waitSec must be a whole number of seconds ({MIN_WAIT_SEC}–{MAX_WAIT_SEC})"
                    ))
                })?;
        }
        Ok(setting)
    }

    pub fn to_json(self) -> Value {
        json!({"enabled": self.enabled, "waitSec": self.wait_sec})
    }
}

/// A Stop hook's hold on its session's wake-up.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Claim {
    pub token: String,
    pub until: Ms,
}

impl Claim {
    /// The claim a Stop at `now` makes when the setting is on.
    pub fn new(setting: WakeSetting, now: Ms) -> Option<Claim> {
        setting.enabled.then(|| Claim {
            token: format!("{}-{now}", std::process::id()),
            until: now + (setting.wait_sec.min(MAX_WAIT_SEC) * 1000) as Ms,
        })
    }
}

fn key(session: &str) -> String {
    format!("{KEY}{session}")
}

/// A Stop: its claim replaces any earlier one, or without the setting there is none left.
pub fn stopped(connection: &Connection, session: &str, claim: Option<&Claim>) -> Result<()> {
    match claim {
        Some(claim) => {
            connection.execute(
                "INSERT INTO meta (key, value) VALUES (?1, ?2)
                 ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                params![
                    key(session),
                    json!({"token": claim.token, "until": claim.until}).to_string()
                ],
            )?;
            Ok(())
        }
        None => release(connection, session),
    }
}

/// The agent is working again (or gone): no wait of the session may wake it any more.
pub fn release(connection: &Connection, session: &str) -> Result<()> {
    connection.execute("DELETE FROM meta WHERE key = ?1", [key(session)])?;
    Ok(())
}

/// Ends this wait's own claim, and nothing newer.
pub fn release_own(connection: &Connection, session: &str, claim: &Claim) -> Result<()> {
    if holds(connection, session, claim)? {
        release(connection, session)?;
    }
    Ok(())
}

fn holds(connection: &Connection, session: &str, claim: &Claim) -> Result<bool> {
    Ok(stored(connection, session)?.is_some_and(|held| held.token == claim.token))
}

/// The session's claim as stored.
fn stored(connection: &Connection, session: &str) -> Result<Option<Claim>> {
    let value: Option<String> = connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [key(session)],
            |r| r.get(0),
        )
        .optional()?;
    Ok(value
        .and_then(|v| serde_json::from_str::<Value>(&v).ok())
        .and_then(|v| {
            Some(Claim {
                token: v["token"].as_str()?.to_string(),
                until: v["until"].as_i64()?,
            })
        }))
}

/// Sessions whose agent waits now, and until when.
pub fn waiting(connection: &Connection, now: Ms) -> Result<HashMap<String, Ms>> {
    let mut statement = connection
        .prepare_cached("SELECT key, value FROM meta WHERE key > 'wake:' AND key < 'wake;'")?;
    let rows = statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    let mut waiting = HashMap::new();
    for row in rows {
        let (key, value) = row?;
        let until = serde_json::from_str::<Value>(&value)
            .ok()
            .and_then(|v| v["until"].as_i64());
        if let (Some(session), Some(until)) = (key.strip_prefix(KEY), until) {
            if until > now {
                waiting.insert(session.to_string(), until);
            }
        }
    }
    Ok(waiting)
}

/// `Session.wakeUntil` on the views of sessions whose agent waits.
pub fn apply(connection: &Connection, views: &mut [SessionView], now: Ms) -> Result<()> {
    let waiting = waiting(connection, now)?;
    if waiting.is_empty() {
        return Ok(());
    }
    for view in views.iter_mut() {
        view.wake_until = waiting.get(&view.id).copied();
    }
    Ok(())
}

/// What a person wrote that wakes the agent: an answer or dismissal of a Ledger question, or a
/// message. Status changes are delivered with them but wake no one.
fn wake_worthy(connection: &Connection, session: &str) -> Result<i64> {
    Ok(connection.query_row(
        "SELECT (SELECT COUNT(*) FROM questions WHERE session_id = ?1 AND delivered_at IS NULL
                   AND browser_source_url IS NULL AND answered_by = 'human'
                   AND state IN ('answered', 'dismissed'))
              + (SELECT COUNT(*) FROM events WHERE session_id = ?1 AND actor = 'human'
                   AND delivered_at IS NULL AND type = 'message')",
        [session],
        |r| r.get(0),
    )?)
}

/// How a wait ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Woken {
    /// Delivered: the text that wakes the agent.
    Wake(String),
    /// Released, timed out or turned off: nothing to send.
    Quiet,
}

/// Waits for a person's answer or message until the claim's `until`, reading `rev` every
/// 250 ms and the rest only when it moved. The stored `until` can only bring the end forward.
pub fn wait(db: &Db, session: &str, claim: &Claim) -> Result<Woken> {
    let mut seen = None;
    let mut deadline = claim.until;
    loop {
        let now = now_ms();
        if now >= deadline {
            db.write(|c| release_own(c, session, claim))?;
            return Ok(Woken::Quiet);
        }
        let rev = db.read(db::rev)?;
        if seen != Some(rev) {
            seen = Some(rev);
            let (held, on, worthy) = db.read(|c| {
                Ok((
                    stored(c, session)?,
                    Settings::load(c)?.wake_agents.enabled,
                    wake_worthy(c, session)?,
                ))
            })?;
            let Some(held) = held.filter(|held| held.token == claim.token) else {
                return Ok(Woken::Quiet);
            };
            deadline = deadline.min(held.until);
            if !on {
                db.write(|c| release_own(c, session, claim))?;
                return Ok(Woken::Quiet);
            }
            if worthy > 0 {
                let (messages, _) = db.write(|c| {
                    if !holds(c, session, claim)? {
                        return Ok(None);
                    }
                    let messages = event::deliver(c, session, now_ms())?;
                    if !messages.is_empty() {
                        release(c, session)?;
                    }
                    Ok(Some(messages))
                })?;
                match messages {
                    None => return Ok(Woken::Quiet),
                    Some(messages) if !messages.is_empty() => {
                        return Ok(Woken::Wake(text::wake(&messages)))
                    }
                    Some(_) => {}
                }
            }
        }
        let left = u64::try_from(deadline - now_ms()).unwrap_or(0);
        std::thread::sleep(POLL.min(Duration::from_millis(left.max(1))));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_setting_is_off_by_default_and_bounded() {
        assert_eq!(
            WakeSetting::parse(&json!({})).unwrap(),
            WakeSetting::default()
        );
        assert!(!WakeSetting::default().enabled);
        assert_eq!(
            WakeSetting::parse(&json!({"enabled": true, "waitSec": 10})).unwrap(),
            WakeSetting {
                enabled: true,
                wait_sec: 10
            }
        );
        for bad in [
            json!({"enabled": 1}),
            json!({"waitSec": 9}),
            json!({"waitSec": 301}),
            json!({"waitSec": "60"}),
            json!([]),
        ] {
            assert!(WakeSetting::parse(&bad).is_err(), "{bad}");
        }
        assert_eq!(
            WakeSetting::default().to_json(),
            json!({"enabled": false, "waitSec": 300})
        );
    }

    #[test]
    fn a_claim_lasts_the_wait_and_only_with_the_setting_on() {
        assert_eq!(Claim::new(WakeSetting::default(), 1_000), None);
        let setting = WakeSetting {
            enabled: true,
            wait_sec: 45,
        };
        let claim = Claim::new(setting, 1_000).unwrap();
        assert_eq!(claim.until, 46_000);
        assert!(claim.token.ends_with("-1000"));
    }

    #[test]
    fn claims_are_kept_per_session_and_newer_ones_win() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO meta VALUES ('rev', '3'), ('wakeful', 'x');",
            )
            .unwrap();
        let older = Claim {
            token: "1-1".into(),
            until: 5_000,
        };
        let newer = Claim {
            token: "2-2".into(),
            until: 9_000,
        };
        stopped(&connection, "S1103-01", Some(&older)).unwrap();
        stopped(&connection, "S1103-02", Some(&older)).unwrap();
        stopped(&connection, "S1103-01", Some(&newer)).unwrap();
        assert!(!holds(&connection, "S1103-01", &older).unwrap());
        assert!(holds(&connection, "S1103-01", &newer).unwrap());
        // an older wait ending leaves the newer claim alone
        release_own(&connection, "S1103-01", &older).unwrap();
        assert!(holds(&connection, "S1103-01", &newer).unwrap());
        let waiting = waiting(&connection, 6_000).unwrap();
        assert_eq!(waiting.get("S1103-01"), Some(&9_000));
        assert!(!waiting.contains_key("S1103-02"), "its time is up");
        assert_eq!(waiting.len(), 1, "other meta rows are not claims");
        // without the setting, a Stop leaves no claim
        stopped(&connection, "S1103-01", None).unwrap();
        assert!(!holds(&connection, "S1103-01", &newer).unwrap());
    }
}
