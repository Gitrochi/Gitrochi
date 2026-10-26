//! `gate.window`: a time-window gate. It stops in a blocked window (`deny`) or outside the allowed ones (`allow`).
//! The flow preflight checks it first at the **expected start time** (the sum of the earlier nodes' expected durations), and again at the current time when the node's turn comes.
//! The time zone is required (`tz: "+09:00"`, `UTC`, `Asia/Seoul`). A time zone that cannot be resolved makes the verdict INDETERMINATE (not a pass).

use super::{schema, Block, Issue, Meta, NodeCx, NodeResult, PreCx};
use crate::util::{self, tr};
use crate::verify::{Outcome, Verdict};
use serde_json::{json, Value};

pub struct Window;

fn inputs() -> Value {
    let window = json!({"type": "object", "properties": {
        "days": {"type": "array", "items": {"enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}},
        "from": {"type": "string", "description": "HH:MM, inclusive"},
        "to": {"type": "string", "description": "HH:MM, exclusive; earlier than from = crosses midnight"},
        "dates": {"type": "array", "items": {"type": "string", "description": "YYYY-MM-DD"}},
        "reason": {"type": "string"}}});
    schema(
        json!({"tz": {"type": "string", "description": "+09:00, UTC or an IANA name such as Asia/Seoul. Required."},
               "deny": {"type": "array", "items": window}, "allow": {"type": "array", "items": window}}),
        &["tz"],
    )
}

static META: Meta = Meta {
    id: "gate.window",
    version: "1.0.0",
    title: ("시간대 관문", "Time window gate"),
    category: "gate",
    capabilities: &[],
    env_classes: &[],
    destructive: false,
    outward: false,
    codes: &["GATE-01", "VERIFY-03"],
    inputs,
    selects_files: false,
    estimate_ms: 0,
};

/// `+09:00`, `-0530`, `UTC` or `Z` → minutes. Anything else is None (`offset_at` resolves IANA names).
pub fn fixed_offset(tz: &str) -> Option<i64> {
    let t = tz.trim();
    if t.eq_ignore_ascii_case("utc") || t == "Z" || t.eq_ignore_ascii_case("gmt") {
        return Some(0);
    }
    let (sign, rest) = match t.as_bytes().first()? {
        b'+' => (1, &t[1..]),
        b'-' => (-1, &t[1..]),
        _ => return None,
    };
    let digits: String = rest.chars().filter(|c| *c != ':').collect();
    if digits.len() != 4 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let h: i64 = digits[..2].parse().ok()?;
    let m: i64 = digits[2..].parse().ok()?;
    (h <= 14 && m < 60).then_some(sign * (h * 60 + m))
}

/// The UTC offset at that moment, in minutes. IANA names are resolved with the system `date` and its time zone data (GNU and BSD alike).
pub fn offset_at(tz: &str, ms: u64) -> Option<i64> {
    if let Some(o) = fixed_offset(tz) {
        return Some(o);
    }
    if !tz
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "/_-+".contains(c))
        || tz.contains("..")
    {
        return None;
    }
    let secs = (ms / 1000).to_string();
    for args in [
        vec!["-d".to_string(), format!("@{secs}"), "+%z".to_string()],
        vec!["-r".to_string(), secs.clone(), "+%z".to_string()],
    ] {
        let out = std::process::Command::new("date")
            .args(&args)
            .env("TZ", tz)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output();
        if let Ok(o) = out {
            if o.status.success() {
                if let Some(v) = fixed_offset(String::from_utf8_lossy(&o.stdout).trim()) {
                    // Without time zone data, date silently uses UTC, so a non-UTC name that comes back as 0 is checked once more.
                    if v == 0 && !known_utc_zone(tz) && !zone_file_exists(tz) {
                        return None;
                    }
                    return Some(v);
                }
            }
        }
    }
    None
}

fn known_utc_zone(tz: &str) -> bool {
    matches!(
        tz,
        "UTC"
            | "Etc/UTC"
            | "Etc/GMT"
            | "GMT"
            | "Europe/London"
            | "Africa/Abidjan"
            | "Atlantic/Reykjavik"
    )
}

fn zone_file_exists(tz: &str) -> bool {
    ["/usr/share/zoneinfo", "/var/db/timezone/zoneinfo"]
        .iter()
        .any(|d| std::path::Path::new(d).join(tz).is_file())
}

fn hm(s: &str) -> Option<i64> {
    let (h, m) = s.trim().split_once(':')?;
    let (h, m): (i64, i64) = (h.parse().ok()?, m.parse().ok()?);
    (h <= 24 && m < 60).then_some(h * 60 + m)
}

const DAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/// Whether a window covers the local time.
pub fn in_window(w: &Value, local_ms: i64) -> bool {
    let days = local_ms.div_euclid(86_400_000);
    let (y, mo, d) = util::civil_from_days(days);
    let date = format!("{y:04}-{mo:02}-{d:02}");
    let dow = DAYS[(days + 4).rem_euclid(7) as usize];
    let minute = local_ms.rem_euclid(86_400_000) / 60_000;
    if let Some(ds) = w.get("dates").and_then(|d| d.as_array()) {
        if !ds.iter().any(|x| x.as_str() == Some(date.as_str())) {
            return false;
        }
    }
    let (from, to) = (
        w.get("from").and_then(|v| v.as_str()).and_then(hm),
        w.get("to").and_then(|v| v.as_str()).and_then(hm),
    );
    let day_ok = |day: &str| {
        w.get("days")
            .and_then(|d| d.as_array())
            .map(|a| {
                a.iter().any(|x| {
                    x.as_str()
                        .map(|s| s.eq_ignore_ascii_case(day))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(true)
    };
    match (from, to) {
        (Some(f), Some(t)) if t <= f => {
            // A window across midnight (22:00–06:00, say): after f today, or before t in a window that started yesterday.
            let yesterday = DAYS[(days + 3).rem_euclid(7) as usize];
            (minute >= f && day_ok(dow)) || (minute < t && day_ok(yesterday))
        }
        (f, t) => day_ok(dow) && minute >= f.unwrap_or(0) && minute < t.unwrap_or(1440),
    }
}

/// (blocked?, reason). Err when the time zone cannot be resolved.
pub fn blocked(with: &Value, ms: u64) -> Result<Option<String>, String> {
    let tz = with.get("tz").and_then(|t| t.as_str()).ok_or_else(|| {
        tr(
            "tz 가 필요합니다(예: +09:00, Asia/Seoul).",
            "tz is required (for example +09:00 or Asia/Seoul).",
        )
    })?;
    let off = offset_at(tz, ms).ok_or_else(|| {
        tr(
            &format!("시간대 '{tz}' 을(를) 풀지 못했습니다."),
            &format!("could not resolve time zone '{tz}'."),
        )
    })?;
    let local = ms as i64 + off * 60_000;
    let stamp = {
        let (y, mo, d) = util::civil_from_days(local.div_euclid(86_400_000));
        let m = local.rem_euclid(86_400_000) / 60_000;
        format!("{y:04}-{mo:02}-{d:02} {:02}:{:02} ({tz})", m / 60, m % 60)
    };
    let list = |k: &str| {
        with.get(k)
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
    };
    if let Some(w) = list("deny").iter().find(|w| in_window(w, local)) {
        let why = w.get("reason").and_then(|r| r.as_str()).unwrap_or("");
        return Ok(Some(
            format!("{stamp} {} {why}", tr("금지 시간대", "blocked window"))
                .trim()
                .to_string(),
        ));
    }
    let allow = list("allow");
    if !allow.is_empty() && !allow.iter().any(|w| in_window(w, local)) {
        return Ok(Some(format!(
            "{stamp} {}",
            tr("허용 시간대 밖", "outside the allowed windows")
        )));
    }
    Ok(None)
}

impl Block for Window {
    fn meta(&self) -> &Meta {
        &META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let mut e = Vec::new();
        match with.get("tz").and_then(|t| t.as_str()) {
            None => e.push(tr(
                "tz 가 필요합니다(예: +09:00, Asia/Seoul).",
                "tz is required (for example +09:00 or Asia/Seoul).",
            )),
            Some(t) if t.contains("${{") => {}
            Some(_) => {}
        }
        for k in ["deny", "allow"] {
            for w in with
                .get(k)
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
            {
                for f in ["from", "to"] {
                    if let Some(s) = w.get(f).and_then(|v| v.as_str()) {
                        if hm(s).is_none() {
                            e.push(format!("{k}.{f}: '{s}' (HH:MM)"));
                        }
                    }
                }
            }
        }
        e
    }

    fn preflight(&self, cx: &PreCx) -> Vec<Issue> {
        match blocked(cx.with, cx.planned_start_ms) {
            Ok(Some(why)) => vec![Issue {
                code: "GATE-01",
                message: tr(
                    &format!("예상 시작 시각이 막힘: {why}"),
                    &format!("the planned start is blocked: {why}"),
                ),
            }],
            Ok(None) => Vec::new(),
            Err(e) => vec![Issue {
                code: "VERIFY-03",
                message: e,
            }],
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let now = util::now_ms();
        let (result, observed, code) = match blocked(&cx.with, now) {
            Ok(None) => (Outcome::Pass, tr("열림", "open"), None),
            Ok(Some(why)) => (Outcome::Fail, why, Some("GATE-01")),
            Err(e) => (Outcome::Indeterminate, e, Some("VERIFY-03")),
        };
        r.observe("at", json!(util::rfc3339(now)));
        r.verdicts.push(Verdict::new(
            "G2",
            tr("시간대", "time window"),
            observed,
            tr("열림", "open"),
            result,
            code,
        ));
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-10-26 is a Monday. 00:30Z = 09:30 KST.
    const MON_0030Z: u64 = 1_792_974_600_000;

    #[test]
    fn offsets() {
        assert_eq!(fixed_offset("+09:00"), Some(540));
        assert_eq!(fixed_offset("-0530"), Some(-330));
        assert_eq!(fixed_offset("UTC"), Some(0));
        assert_eq!(fixed_offset("Asia/Seoul"), None);
        assert_eq!(fixed_offset("+9"), None);
    }

    #[test]
    fn windows_in_a_fixed_zone() {
        let business = json!({"tz": "+09:00", "deny": [{"days": ["mon", "tue", "wed", "thu", "fri"], "from": "09:00", "to": "18:00", "reason": "business hours"}]});
        let b = blocked(&business, MON_0030Z).unwrap().unwrap();
        assert!(b.contains("2026-10-26 09:30"), "{b}");
        assert!(b.contains("business hours"));
        // The same moment in UTC is 00:30, so it is open.
        let utc = json!({"tz": "UTC", "deny": business["deny"].clone()});
        assert!(blocked(&utc, MON_0030Z).unwrap().is_none());
        // A window across midnight: Sunday 23:00 to Monday 06:00.
        let night =
            json!({"tz": "UTC", "deny": [{"days": ["sun"], "from": "23:00", "to": "06:00"}]});
        assert!(blocked(&night, MON_0030Z).unwrap().is_some());
        // Dated and allowed windows.
        let freeze = json!({"tz": "+09:00", "deny": [{"dates": ["2026-10-26"]}]});
        assert!(blocked(&freeze, MON_0030Z).unwrap().is_some());
        let only_weekend = json!({"tz": "+09:00", "allow": [{"days": ["sat", "sun"]}]});
        assert!(
            blocked(&only_weekend, MON_0030Z)
                .unwrap()
                .unwrap()
                .contains("outside")
                || blocked(&only_weekend, MON_0030Z)
                    .unwrap()
                    .unwrap()
                    .contains("밖")
        );
        assert!(blocked(&json!({"deny": []}), MON_0030Z).is_err());
    }
}
