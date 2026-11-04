//! Insights: how long questions wait for a person, how automatic answers fare, where
//! sessions stand and how often agents report, over a period. Counts and durations only:
//! no question text, answer, report body or note leaves this module.

use crate::error::Result;
use crate::settings::Settings;
use crate::util::Ms;
use crate::views::{self, Range};
use crate::vocab::{Role, Verdict};
use rusqlite::{params, Connection};
use serde::Serialize;
use std::collections::BTreeMap;

/// `all` charts the reports of this many days; 7d and 30d chart their own.
pub const ALL_DAYS: i64 = 90;

/// A set of durations: how many, the median and the 90th percentile (nearest rank), and
/// the longest.
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Spread {
    pub count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub median_ms: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p90_ms: Option<Ms>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_ms: Option<Ms>,
}

/// Nearest-rank percentile of sorted values: the smallest value with at least `p` percent
/// of the values at or below it.
fn percentile(sorted: &[Ms], p: i64) -> Option<Ms> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (p * sorted.len() as i64 + 99) / 100;
    Some(sorted[(rank.max(1) as usize - 1).min(sorted.len() - 1)])
}

pub fn spread(mut values: Vec<Ms>) -> Spread {
    values.retain(|v| *v >= 0);
    values.sort_unstable();
    Spread {
        count: values.len() as i64,
        median_ms: percentile(&values, 50),
        p90_ms: percentile(&values, 90),
        max_ms: values.last().copied(),
    }
}

/// Questions in the period and the ones still open.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionStats {
    /// Asked in the period.
    pub asked: i64,
    /// Answered in the period (by a person, or by auto-continue's earlier rules).
    pub answered: i64,
    /// Dismissed in the period.
    pub dismissed: i64,
    /// Closed by their own agent (`resolves`) in the period; not a wait for a person.
    pub resolved_by_agent: i64,
    /// From asked to answered or dismissed, for those settled in the period.
    pub wait: Spread,
    /// How long the questions open now have waited (sessions that are not archived).
    pub open: Spread,
}

/// Automatic answers of one prompt kind.
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AutoKind {
    pub kind: String,
    pub total: i64,
    /// A person looked at it (Confirm or Send correction…).
    pub reviewed: i64,
    /// Reviewed after a person sent the session a message (Send correction… does).
    pub corrected: i64,
    /// Still waiting for review.
    pub unreviewed: i64,
}

/// What auto-continue answered in the period, overall and by prompt kind.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoStats {
    pub total: i64,
    pub reviewed: i64,
    pub corrected: i64,
    pub unreviewed: i64,
    pub by_kind: Vec<AutoKind>,
}

/// Sessions as the Board shows them for the period.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStats {
    pub total: i64,
    /// Every verdict, zero included.
    pub by_verdict: BTreeMap<&'static str, i64>,
    /// Every role, zero included.
    pub by_role: BTreeMap<&'static str, i64>,
    pub stale: i64,
    /// Stale sessions whose agent never reported.
    pub stale_unreported: i64,
    /// Sessions whose agent never reported.
    pub unreported: i64,
}

/// Agent reports on one local day.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Day {
    /// `YYYY-MM-DD`, local time.
    pub day: String,
    pub reports: i64,
}

/// The `insights` result.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Insights {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    pub range: &'static str,
    /// The period's first moment; absent for `all`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<Ms>,
    pub to: Ms,
    pub questions: QuestionStats,
    pub auto_answers: AutoStats,
    pub sessions: SessionStats,
    /// Agent reports in the period (for `all`, ever).
    pub reports: i64,
    /// Agent reports per local day, oldest first, zero days included: 7, 30, or the last 90
    /// days for `all`.
    pub reports_per_day: Vec<Day>,
}

const VERDICTS: [Verdict; 8] = [
    Verdict::NeedsHuman,
    Verdict::Confirm,
    Verdict::Expirable,
    Verdict::PendingMerge,
    Verdict::Stale,
    Verdict::Active,
    Verdict::Shelved,
    Verdict::Archived,
];
const ROLES: [Role; 5] = [
    Role::Decision,
    Role::Implementation,
    Role::Research,
    Role::Document,
    Role::Other,
];

fn questions(
    connection: &Connection,
    project: Option<&str>,
    from: Option<Ms>,
    now: Ms,
) -> Result<QuestionStats> {
    let mut stats = QuestionStats {
        asked: connection.query_row(
            "SELECT COUNT(*) FROM questions q JOIN sessions s ON s.id = q.session_id
             WHERE (?1 IS NULL OR s.project = ?1) AND (?2 IS NULL OR q.created_at >= ?2)",
            params![project, from],
            |r| r.get(0),
        )?,
        ..Default::default()
    };
    let mut statement = connection.prepare(
        "SELECT q.state, COALESCE(q.answered_by, ''), q.created_at, q.answered_at
         FROM questions q JOIN sessions s ON s.id = q.session_id
         WHERE (?1 IS NULL OR s.project = ?1) AND q.state IN ('answered', 'dismissed')
           AND q.answered_at IS NOT NULL AND (?2 IS NULL OR q.answered_at >= ?2)",
    )?;
    let mut waits = Vec::new();
    let rows = statement.query_map(params![project, from], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Ms>(2)?,
            r.get::<_, Ms>(3)?,
        ))
    })?;
    for row in rows {
        let (state, by, created, settled) = row?;
        if by == "agent" {
            stats.resolved_by_agent += 1;
            continue;
        }
        if state == "dismissed" {
            stats.dismissed += 1;
        } else {
            stats.answered += 1;
        }
        waits.push(settled - created);
    }
    stats.wait = spread(waits);
    stats.open = spread(
        views::open_questions(connection, project)?
            .iter()
            .map(|q| now - q.created_at)
            .collect(),
    );
    Ok(stats)
}

fn auto_answers(
    connection: &Connection,
    project: Option<&str>,
    from: Option<Ms>,
) -> Result<AutoStats> {
    let mut statement = connection.prepare(
        "SELECT p.kind, p.reviewed_at IS NOT NULL,
                p.reviewed_at IS NOT NULL AND EXISTS (
                    SELECT 1 FROM events e WHERE e.session_id = p.session_id
                      AND e.type = 'message' AND e.actor = 'human'
                      AND e.ts >= COALESCE(p.answered_at, p.created_at) AND e.ts <= p.reviewed_at)
         FROM pending_prompts p LEFT JOIN sessions s ON s.id = p.session_id
         WHERE p.state = 'auto' AND (?1 IS NULL OR s.project = ?1)
           AND (?2 IS NULL OR COALESCE(p.answered_at, p.created_at) >= ?2)",
    )?;
    let mut kinds: BTreeMap<String, AutoKind> = BTreeMap::new();
    let rows = statement.query_map(params![project, from], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, bool>(1)?,
            r.get::<_, bool>(2)?,
        ))
    })?;
    for row in rows {
        let (kind, reviewed, corrected) = row?;
        let entry = kinds.entry(kind.clone()).or_insert_with(|| AutoKind {
            kind,
            ..Default::default()
        });
        entry.total += 1;
        entry.reviewed += i64::from(reviewed);
        entry.corrected += i64::from(corrected);
        entry.unreviewed += i64::from(!reviewed);
    }
    let by_kind: Vec<AutoKind> = kinds.into_values().collect();
    Ok(AutoStats {
        total: by_kind.iter().map(|k| k.total).sum(),
        reviewed: by_kind.iter().map(|k| k.reviewed).sum(),
        corrected: by_kind.iter().map(|k| k.corrected).sum(),
        unreviewed: by_kind.iter().map(|k| k.unreviewed).sum(),
        by_kind,
    })
}

fn sessions(
    connection: &Connection,
    settings: &Settings,
    project: Option<&str>,
    from: Option<Ms>,
    now: Ms,
) -> Result<SessionStats> {
    let snapshot = views::snapshot(connection, settings, project, now)?;
    let mut stats = SessionStats {
        by_verdict: VERDICTS.iter().map(|v| (v.as_str(), 0)).collect(),
        by_role: ROLES.iter().map(|r| (r.as_str(), 0)).collect(),
        ..Default::default()
    };
    // the Board's sessions: not archived, or archived inside the period
    for view in snapshot
        .views
        .iter()
        .filter(|v| v.archived_at.is_none_or(|at| from.is_none_or(|f| at >= f)))
    {
        stats.total += 1;
        *stats.by_verdict.entry(view.verdict.as_str()).or_default() += 1;
        *stats.by_role.entry(view.role).or_default() += 1;
        let unreported = view.last_agent_at.is_none();
        stats.unreported += i64::from(unreported);
        if view.verdict == Verdict::Stale {
            stats.stale += 1;
            stats.stale_unreported += i64::from(unreported);
        }
    }
    Ok(stats)
}

fn reports_per_day(
    connection: &Connection,
    project: Option<&str>,
    days: i64,
    now: Ms,
) -> Result<Vec<Day>> {
    // local midnight of the first day, so every bucket is a whole local day
    let start: Ms = connection.query_row(
        "SELECT CAST(strftime('%s', date(?1 / 1000, 'unixepoch', 'localtime', ?2), 'utc') AS INTEGER) * 1000",
        params![now, format!("-{} days", days - 1)],
        |r| r.get(0),
    )?;
    let mut statement = connection.prepare(
        "SELECT date(ts / 1000, 'unixepoch', 'localtime') AS day, COUNT(*) FROM events
         WHERE actor = 'agent' AND ts >= ?1 AND ts <= ?2 AND (?3 IS NULL OR project = ?3)
         GROUP BY day",
    )?;
    let counts: BTreeMap<String, i64> = statement
        .query_map(params![start, now, project], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut statement = connection
        .prepare("SELECT date(?1 / 1000, 'unixepoch', 'localtime', '-' || ?2 || ' days')")?;
    let mut out = Vec::with_capacity(days as usize);
    for back in (0..days).rev() {
        let day: String = statement.query_row(params![now, back], |r| r.get(0))?;
        out.push(Day {
            reports: counts.get(&day).copied().unwrap_or(0),
            day,
        });
    }
    Ok(out)
}

/// The insights for one project (or all) over a period.
pub fn build(
    connection: &Connection,
    settings: &Settings,
    project: Option<&str>,
    range: Range,
    now: Ms,
) -> Result<Insights> {
    let from = range.start(now);
    let (name, days) = match range {
        Range::Days(7) => ("7d", 7),
        Range::Days(days) => ("30d", days),
        Range::All => ("all", ALL_DAYS),
    };
    let reports: i64 = connection.query_row(
        "SELECT COUNT(*) FROM events WHERE actor = 'agent'
           AND (?1 IS NULL OR ts >= ?1) AND (?2 IS NULL OR project = ?2)",
        params![from, project],
        |r| r.get(0),
    )?;
    Ok(Insights {
        project: project.map(str::to_string),
        range: name,
        from,
        to: now,
        questions: questions(connection, project, from, now)?,
        auto_answers: auto_answers(connection, project, from)?,
        sessions: sessions(connection, settings, project, from, now)?,
        reports,
        reports_per_day: reports_per_day(connection, project, days, now)?,
    })
}

/// A duration in its largest unit and the next one when that is not zero: 45s, 12m, 2h 10m, 3d.
pub fn duration(ms: Ms) -> String {
    const UNITS: [(&str, Ms); 4] = [
        ("d", 86_400_000),
        ("h", 3_600_000),
        ("m", 60_000),
        ("s", 1_000),
    ];
    let total = ms.max(0);
    let Some(at) = UNITS.iter().position(|(_, size)| total >= *size) else {
        return "0s".into();
    };
    let (unit, size) = UNITS[at];
    let mut text = format!("{}{unit}", total / size);
    if let Some((next, next_size)) = UNITS.get(at + 1) {
        let rest = total % size / next_size;
        if rest > 0 {
            text.push_str(&format!(" {rest}{next}"));
        }
    }
    text
}

/// The CLI's lines for an `insights` result.
pub fn text(data: &serde_json::Value) -> String {
    let n = |v: &serde_json::Value| v.as_i64().unwrap_or(0);
    let d = |v: &serde_json::Value| v.as_i64().map(duration).unwrap_or_else(|| "—".into());
    let (q, a, s) = (&data["questions"], &data["autoAnswers"], &data["sessions"]);
    let period = match data["range"].as_str() {
        Some("7d") => "the last 7 days",
        Some("30d") => "the last 30 days",
        _ => "all time",
    };
    let mut lines = vec![format!(
        "[{}] {period}",
        data["project"].as_str().unwrap_or("All projects")
    )];
    lines.push(format!(
        "Questions: {} asked, {} answered, {} dismissed, {} closed by their agent; wait median {}, p90 {}",
        n(&q["asked"]),
        n(&q["answered"]),
        n(&q["dismissed"]),
        n(&q["resolvedByAgent"]),
        d(&q["wait"]["medianMs"]),
        d(&q["wait"]["p90Ms"])
    ));
    lines.push(format!(
        "Open now: {}, the oldest waiting {}",
        n(&q["open"]["count"]),
        d(&q["open"]["maxMs"])
    ));
    lines.push(format!(
        "Automatic answers: {} ({} reviewed, {} corrected, {} not reviewed)",
        n(&a["total"]),
        n(&a["reviewed"]),
        n(&a["corrected"]),
        n(&a["unreviewed"])
    ));
    let verdicts: Vec<String> = VERDICTS
        .iter()
        .map(|v| (v.label(), n(&s["byVerdict"][v.as_str()])))
        .filter(|(_, count)| *count > 0)
        .map(|(label, count)| format!("{count} {label}"))
        .collect();
    lines.push(format!(
        "Sessions: {}{}{}; {} stale ({} never reported)",
        n(&s["total"]),
        if verdicts.is_empty() { "" } else { " — " },
        verdicts.join(", "),
        n(&s["stale"]),
        n(&s["staleUnreported"])
    ));
    let busiest = data["reportsPerDay"]
        .as_array()
        .into_iter()
        .flatten()
        .max_by_key(|day| n(&day["reports"]))
        .filter(|day| n(&day["reports"]) > 0);
    lines.push(match busiest {
        Some(day) => format!(
            "Agent reports: {}; the most in a day {} ({})",
            n(&data["reports"]),
            n(&day["reports"]),
            day["day"].as_str().unwrap_or("")
        ),
        None => format!("Agent reports: {}", n(&data["reports"])),
    });
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_keep_two_units() {
        assert_eq!(duration(0), "0s");
        assert_eq!(duration(45_000), "45s");
        assert_eq!(duration(12 * 60_000 + 5_000), "12m 5s");
        assert_eq!(duration(2 * 3_600_000 + 10 * 60_000 + 59_000), "2h 10m");
        assert_eq!(duration(3 * 86_400_000 + 30 * 60_000), "3d");
    }

    #[test]
    fn percentiles_use_the_nearest_rank() {
        assert_eq!(spread(vec![]), Spread::default());
        let one = spread(vec![5]);
        assert_eq!(
            (one.median_ms, one.p90_ms, one.max_ms),
            (Some(5), Some(5), Some(5))
        );
        let ten = spread((1..=10).rev().collect());
        assert_eq!(ten.count, 10);
        assert_eq!(
            (ten.median_ms, ten.p90_ms, ten.max_ms),
            (Some(5), Some(9), Some(10))
        );
        let odd = spread(vec![30, 10, 20]);
        assert_eq!((odd.median_ms, odd.p90_ms), (Some(20), Some(30)));
        // clock skew never makes a negative wait
        assert_eq!(spread(vec![-4, 8]).count, 1);
    }
}
