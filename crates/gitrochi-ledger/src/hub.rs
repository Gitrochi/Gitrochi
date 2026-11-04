//! Sharing with the team hub (DESIGN.md §14 D4, opt-in, off by default): the presence
//! bodies an app posts to `POST /api/v1/presence` for this computer's live sessions.
//!
//! This is the one place that decides what leaves the computer. Per live, non-stream
//! session: its ID, project, title, kind and role, branch, verdict, shareable touches and
//! the last activity time (to the minute), with the repository key of its remote and the
//! app's client name. Never: questions, answers, report bodies or summaries, messages,
//! notes, the notebook, work or document records, chat links, agent IDs, folder paths or
//! credentials embedded in a remote URL. The apps send the bodies as they are; they only
//! drop `ledger` for a hub that predates it.

use crate::baseline;
use crate::db::{self, Db};
use crate::error::{Error, Result};
use crate::session::SessionView;
use crate::settings::Settings;
use crate::util::{arg_str, truncate, Ms};
use crate::views;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Sessions shared at most, most recently active first.
pub const LIMIT: usize = 100;
/// Touches shared per session at most (the hub takes 5000).
pub const MAX_TOUCHES: usize = 500;
const TITLE_MAX: usize = 200;
const PROJECT_MAX: usize = 200;
const KIND_MAX: usize = 64;
const BRANCH_MAX: usize = 255;
/// Repository keys are read again after this long, so a changed remote is noticed.
const KEY_TTL: Duration = Duration::from_secs(300);

/// The `hub_share` method: `{client}` is the app's random name for this computer.
pub fn share(db: &Db, args: &Value, now: Ms) -> Result<Value> {
    let client = arg_str(args, "client")
        .filter(|c| valid_client(c))
        .ok_or_else(|| {
            Error::invalid("Give client: 4 to 32 letters, digits or -, naming this computer")
        })?;
    let (rev, views, project_repos) = db.read(|c| {
        let settings = Settings::load(c)?;
        let snapshot = views::snapshot(c, &settings, None, now)?;
        let repos: HashMap<String, String> = baseline::projects(c)?
            .into_iter()
            .filter_map(|p| p.repo_path.map(|path| (p.key, path)))
            .collect();
        Ok((db::rev(c)?, snapshot.views, repos))
    })?;
    let mut candidates: Vec<&SessionView> = views.iter().filter(|v| shared(v)).collect();
    candidates.sort_by(|a, b| b.last_at.cmp(&a.last_at).then_with(|| a.id.cmp(&b.id)));
    let mut sessions = Vec::new();
    let mut unshared = Vec::new();
    for view in candidates {
        let dirs = folders(view, project_repos.get(&view.project));
        let Some(repo) = dirs.iter().find_map(|dir| cached_key(dir)) else {
            unshared.push(json!({"sessionId": view.id, "reason": "no_remote"}));
            continue;
        };
        if sessions.len() >= LIMIT {
            unshared.push(json!({"sessionId": view.id, "reason": "limit"}));
            continue;
        }
        let name = client_name(&client, &view.id);
        sessions.push(json!({
            "sessionId": view.id,
            "repo": repo,
            "client": name,
            "presence": presence(view, &repo, &name),
        }));
    }
    Ok(json!({"rev": rev, "sessions": sessions, "unshared": unshared}))
}

/// Live (not finished, shelved or archived) and not a stream: the sessions overlaps count.
pub fn shared(view: &SessionView) -> bool {
    view.is_live() && !view.is_stream()
}

/// The presence body for one session: only the allowed fields, nothing else from `view`.
pub fn presence(view: &SessionView, repo: &str, client: &str) -> Value {
    let branch = view.links["branch"]
        .as_str()
        .map(|b| single_line(b, BRANCH_MAX))
        .unwrap_or_default();
    let changed: Vec<&String> = view
        .touches
        .iter()
        .filter(|t| shareable_touch(t))
        .take(MAX_TOUCHES)
        .collect();
    json!({
        "repo": repo,
        "branch": branch,
        "changed": changed,
        "related": [],
        "client": client,
        "ledger": {
            "session": view.id,
            "project": single_line(&view.project, PROJECT_MAX),
            "title": single_line(&view.title, TITLE_MAX),
            "kind": single_line(&view.kind, KIND_MAX),
            "role": view.role,
            "verdict": view.verdict.as_str(),
            "lastActivity": rfc3339_minute(view.last_at),
        },
    })
}

/// The hub's client name for a session: `ledger/<this computer>/<session ID>`.
pub fn client_name(client: &str, session: &str) -> String {
    format!("ledger/{client}/{session}")
}

fn valid_client(client: &str) -> bool {
    (4..=32).contains(&client.len())
        && client
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Where the session's repository may be found, best first.
fn folders(view: &SessionView, project_repo: Option<&String>) -> Vec<String> {
    let mut dirs: Vec<String> = ["repoPath", "worktree", "cwd"]
        .iter()
        .filter_map(|key| view.links[*key].as_str())
        .map(str::to_string)
        .collect();
    dirs.extend(project_repo.cloned());
    dirs.retain(|d| !d.trim().is_empty());
    dirs.dedup();
    dirs
}

/// Folder → its repository key (or none) and when that was read.
type KeyCache = Mutex<HashMap<String, (Option<String>, Instant)>>;

/// The repository key of a folder's remote, remembered for a few minutes per process so
/// frequent shares do not start git every time.
fn cached_key(dir: &str) -> Option<String> {
    static CACHE: OnceLock<KeyCache> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some((key, at)) = cache.lock().ok()?.get(dir) {
        if at.elapsed() < KEY_TTL {
            return key.clone();
        }
    }
    let key = crate::git::remote_url(Path::new(dir)).and_then(|url| repo_key(&url));
    if let Ok(mut map) = cache.lock() {
        map.insert(dir.to_string(), (key.clone(), Instant::now()));
    }
    key
}

/// A touch the hub may see: a repository-relative path or an identifier. Absolute and
/// home paths, Windows paths, URLs, paths leaving the repository and control characters
/// stay on this computer.
pub fn shareable_touch(touch: &str) -> bool {
    let bytes = touch.as_bytes();
    !touch.trim().is_empty()
        && touch.len() <= 1024
        && !touch.chars().any(char::is_control)
        && !touch.starts_with('/')
        && !touch.starts_with('~')
        && !touch.contains('\\')
        && !touch.contains("://")
        && !(bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic())
        && !touch.split('/').any(|segment| segment == "..")
}

/// The hub's repository key for a remote URL, as `services/hub/internal/repokey` makes
/// it: lower-cased host and path, without scheme, user, password, port or `.git`. Local
/// paths and unsupported schemes have none.
pub fn repo_key(remote: &str) -> Option<String> {
    let s = remote.trim();
    if s.is_empty() || s.len() > 2048 {
        return None;
    }
    let (host, path) = if let Some(at) = s.find("://") {
        let scheme = s[..at].to_ascii_lowercase();
        if !["http", "https", "ssh", "git", "git+ssh", "ssh+git"].contains(&scheme.as_str()) {
            return None;
        }
        let rest = &s[at + 3..];
        let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let authority = &rest[..end];
        let mut path = &rest[end..];
        if let Some(cut) = path.find(['?', '#']) {
            path = &path[..cut];
        }
        let host_port = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
        if host_port.starts_with('[') {
            return None;
        }
        (host_port.split(':').next().unwrap_or(""), path)
    } else if local_path(s) {
        return None;
    } else if scp_like(s) {
        let (host_part, rest) = s.split_once(':')?;
        (
            host_part.rsplit_once('@').map_or(host_part, |(_, h)| h),
            rest,
        )
    } else {
        s.split_once('/')?
    };
    let host = host.to_lowercase();
    let host = host.trim_end_matches('.');
    if host.is_empty()
        || host.len() > 255
        || host
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "/\\@?#%[]".contains(c))
    {
        return None;
    }
    let mut segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let last = segments.pop()?;
    let last = last.strip_suffix(".git").unwrap_or(last);
    segments.push(last);
    let valid = |seg: &&str| {
        !seg.is_empty()
            && *seg != "."
            && *seg != ".."
            && !seg
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || "\\?#".contains(c))
    };
    if !segments.iter().all(valid) {
        return None;
    }
    let key = format!("{host}/{}", segments.join("/"));
    (key.len() <= 512).then_some(key)
}

fn scp_like(s: &str) -> bool {
    match (s.find(':'), s.find('/')) {
        (Some(colon), slash) => colon > 0 && slash.is_none_or(|slash| colon < slash),
        _ => false,
    }
}

fn local_path(s: &str) -> bool {
    let b = s.as_bytes();
    s.starts_with('/')
        || s.starts_with("./")
        || s.starts_with("../")
        || s.starts_with('~')
        || s.starts_with('\\')
        || s == "."
        || s == ".."
        || (b.len() >= 2 && b[1] == b':' && b[0].is_ascii_alphabetic())
}

/// One line: control characters become spaces, runs of spaces one, cut to `limit`.
fn single_line(text: &str, limit: usize) -> String {
    let plain: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    truncate(
        &plain.split_whitespace().collect::<Vec<_>>().join(" "),
        limit,
    )
}

/// RFC 3339 in UTC, to the minute (the hub's times are whole seconds; minutes keep a
/// busy session from changing its body on every hook).
pub fn rfc3339_minute(ms: Ms) -> String {
    let minutes = ms.div_euclid(60_000);
    let (days, minute) = (minutes.div_euclid(1440), minutes.rem_euclid(1440));
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:00Z",
        minute / 60,
        minute % 60
    )
}

/// Days since 1970-01-01 to a proleptic Gregorian date.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_keys_follow_the_hub() {
        for (remote, key) in [
            ("git@example.com:team/app.git", Some("example.com/team/app")),
            ("https://example.com/team/app", Some("example.com/team/app")),
            (
                "ssh://git@example.com:2222/team/app.git",
                Some("example.com/team/app"),
            ),
            (
                "https://user:s3cret@Example.COM/Team/App.git/",
                Some("example.com/Team/App"),
            ),
            ("example.com/team/app", Some("example.com/team/app")),
            (
                "https://example.com/team/app?x=1#y",
                Some("example.com/team/app"),
            ),
            ("file:///srv/git/app.git", None),
            ("/srv/git/app.git", None),
            ("../app", None),
            ("~/src/app", None),
            ("C:\\repos\\app", None),
            ("C:/repos/app", None),
            ("ftp://example.com/team/app", None),
            ("https://example.com/", None),
            ("https://exa mple.com/team/app", None),
            ("https://example.com/team/../app", None),
            ("", None),
        ] {
            assert_eq!(repo_key(remote).as_deref(), key, "{remote}");
        }
    }

    #[test]
    fn only_repository_relative_touches_are_shareable() {
        for touch in [
            "src/retry.rs",
            "REQ-12",
            "docs/한글.md",
            "a/./b",
            "module:auth",
        ] {
            assert!(shareable_touch(touch), "{touch}");
        }
        for touch in [
            "",
            "  ",
            "/Users/me/notes.md",
            "~/notes.md",
            "C:\\Users\\me\\x",
            "D:/work/x",
            "src\\win.rs",
            "https://example.com/x",
            "../outside.txt",
            "a/../../b",
            "line\nbreak",
        ] {
            assert!(!shareable_touch(touch), "{touch:?}");
        }
        assert!(!shareable_touch(&"a".repeat(1025)));
    }

    #[test]
    fn times_are_utc_minutes() {
        assert_eq!(rfc3339_minute(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_minute(59_999), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_minute(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339_minute(1_793_701_234_567), "2026-11-03T10:20:00Z");
        assert_eq!(rfc3339_minute(-60_000), "1969-12-31T23:59:00Z");
    }

    #[test]
    fn clients_and_lines_are_bounded() {
        assert!(valid_client("a1b2c3d4e5f6"));
        assert!(!valid_client("abc"));
        assert!(!valid_client("has space"));
        assert!(!valid_client(&"a".repeat(33)));
        assert_eq!(client_name("a1b2", "S1103-01"), "ledger/a1b2/S1103-01");
        assert_eq!(single_line("Fix\nthe\t retry\u{7}", 50), "Fix the retry");
        assert_eq!(single_line(&"x".repeat(300), 200).chars().count(), 200);
    }
}
