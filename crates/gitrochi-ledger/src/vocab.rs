//! The ledger's vocabulary: event types, statuses, roles and verdicts, stored as lower-case
//! English identifiers. Input also accepts the aliases agents of the original tool were
//! told to use; they are input data (like translations) and never appear in output.

use serde::Serialize;

/// Events an agent may report.
pub const AGENT_EVENTS: [&str; 15] = [
    "start",
    "progress",
    "artifact",
    "question",
    "decision",
    "sync",
    "done",
    "merged",
    "closed",
    "dropped",
    "shelved",
    "release",
    "applied",
    "note",
    "heartbeat",
];

/// Events that make a session that is not active active again (the resume rule).
pub const REOPEN_EVENTS: [&str; 7] = [
    "start", "progress", "artifact", "question", "decision", "sync", "applied",
];

/// Statuses that end a session; a person still confirms and archives it.
pub const TERMINAL: [&str; 3] = ["merged", "closed", "dropped"];

pub const STATUSES: [&str; 6] = ["active", "done", "merged", "closed", "dropped", "shelved"];

/// A person's operations, also the type of the event each one records.
pub const HUMAN_ACTIONS: [&str; 12] = [
    "ack",
    "unack",
    "archive",
    "unarchive",
    "set_status",
    "answer",
    "dismiss",
    "snooze",
    "shelve",
    "link",
    "message",
    "auto_continue",
];

/// Kinds with a role by default. Unknown kinds are kept as typed and have the role `other`.
pub const DEFAULT_KINDS: [&str; 8] = [
    "research",
    "decision",
    "implementation",
    "llm-implementation",
    "review",
    "document",
    "baseline",
    "other",
];

// Event names in Korean (and a few English variants) that the original tool accepted.
const EVENT_ALIASES: [(&str, &str); 24] = [
    ("시작", "start"),
    ("진행", "progress"),
    ("산출물", "artifact"),
    ("아티팩트", "artifact"),
    ("질문", "question"),
    ("결정", "decision"),
    ("동기화", "sync"),
    ("리베이스", "sync"),
    ("rebase", "sync"),
    ("완료", "done"),
    ("반영", "merged"),
    ("merge", "merged"),
    ("종료", "closed"),
    ("close", "closed"),
    ("폐기", "dropped"),
    ("drop", "dropped"),
    ("릴리스", "release"),
    ("이행", "applied"),
    ("이행완료", "applied"),
    ("apply", "applied"),
    ("보관", "shelved"),
    ("shelve", "shelved"),
    ("메모", "note"),
    ("생존", "heartbeat"),
];

// Kind names in Korean that the original tool used, matched without spaces, `-`, `_` or `·`.
const KIND_ALIASES: [(&str, &str); 9] = [
    ("연구", "research"),
    ("판정", "decision"),
    ("구현", "implementation"),
    ("llm구현", "llm-implementation"),
    ("구현llm", "llm-implementation"),
    ("리뷰", "review"),
    ("문서", "document"),
    ("정본", "baseline"),
    ("기타", "other"),
];

// Words that mean "the newest baseline" in a `base` or `version` field.
const LATEST_WORDS: [&str; 5] = ["latest", "head", "최신", "최신본", "최신파생"];

pub fn is_latest_word(text: &str) -> bool {
    let lower = text.to_lowercase();
    LATEST_WORDS.contains(&lower.as_str())
}

/// The English event name for what an agent sent, if it is one.
pub fn agent_event(raw: &str) -> Option<&'static str> {
    let lower = raw.to_lowercase();
    for candidate in [raw, lower.as_str()] {
        if let Some((_, name)) = EVENT_ALIASES.iter().find(|(alias, _)| *alias == candidate) {
            return Some(name);
        }
        if let Some(name) = AGENT_EVENTS.iter().find(|name| **name == candidate) {
            return Some(name);
        }
    }
    None
}

fn kind_key(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_whitespace() && !matches!(c, '-' | '_' | '·'))
        .flat_map(char::to_lowercase)
        .collect()
}

/// A kind as stored: a known kind or alias in its canonical spelling, anything else as typed.
pub fn kind(raw: &str) -> String {
    let key = kind_key(raw);
    if let Some((_, name)) = KIND_ALIASES.iter().find(|(alias, _)| *alias == key) {
        return (*name).to_string();
    }
    if let Some(name) = DEFAULT_KINDS.iter().find(|name| kind_key(name) == key) {
        return (*name).to_string();
    }
    raw.to_string()
}

pub fn is_terminal(status: &str) -> bool {
    TERMINAL.contains(&status)
}

/// Not finished, not shelved: what counts as concurrent work.
pub fn is_live_status(status: &str) -> bool {
    !is_terminal(status) && status != "shelved"
}

/// What a session is for, which decides hand-offs, streams and shelving.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Decision,
    Implementation,
    Research,
    Document,
    Other,
}

impl Role {
    pub fn parse(text: &str) -> Option<Role> {
        Some(match text {
            "decision" => Role::Decision,
            "implementation" => Role::Implementation,
            "research" => Role::Research,
            "document" => Role::Document,
            "other" => Role::Other,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Role::Decision => "decision",
            Role::Implementation => "implementation",
            Role::Research => "research",
            Role::Document => "document",
            Role::Other => "other",
        }
    }

    /// Research and documents may be shelved: paused without a merge, kept for later.
    pub fn may_shelve(self) -> bool {
        matches!(self, Role::Research | Role::Document)
    }
}

/// What a person should do with a session, computed on read and never stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Archived,
    NeedsHuman,
    Expirable,
    Confirm,
    Shelved,
    PendingMerge,
    Stale,
    Active,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Archived => "archived",
            Verdict::NeedsHuman => "needs_human",
            Verdict::Expirable => "expirable",
            Verdict::Confirm => "confirm",
            Verdict::Shelved => "shelved",
            Verdict::PendingMerge => "pending_merge",
            Verdict::Stale => "stale",
            Verdict::Active => "active",
        }
    }

    /// The label agents read in text replies (the apps translate their own).
    pub fn label(self) -> &'static str {
        match self {
            Verdict::Archived => "Archived",
            Verdict::NeedsHuman => "Needs a person",
            Verdict::Expirable => "Ready to archive",
            Verdict::Confirm => "Waiting for confirmation",
            Verdict::Shelved => "Shelved",
            Verdict::PendingMerge => "Merge undecided",
            Verdict::Stale => "Possibly abandoned",
            Verdict::Active => "Active",
        }
    }
}

pub fn status_label(status: &str) -> &str {
    match status {
        "active" => "active",
        "done" => "done (not merged)",
        "merged" => "merged",
        "closed" => "closed (no merge needed)",
        "dropped" => "dropped",
        "shelved" => "shelved",
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_and_aliases() {
        assert_eq!(agent_event("start"), Some("start"));
        assert_eq!(agent_event("START"), Some("start"));
        assert_eq!(agent_event("이행"), Some("applied"));
        assert_eq!(agent_event("Rebase"), Some("sync"));
        assert_eq!(agent_event("보관"), Some("shelved"));
        assert_eq!(agent_event("ack"), None);
        assert_eq!(agent_event("frobnicate"), None);
        for (alias, name) in EVENT_ALIASES {
            assert_eq!(agent_event(alias), Some(name), "{alias}");
            assert!(AGENT_EVENTS.contains(&name));
        }
    }

    #[test]
    fn kinds_are_canonical_or_kept() {
        assert_eq!(kind("연구"), "research");
        assert_eq!(kind("LLM 구현"), "llm-implementation");
        assert_eq!(kind("구현-LLM"), "llm-implementation");
        assert_eq!(kind("구현"), "implementation");
        assert_eq!(kind("Implementation"), "implementation");
        assert_eq!(kind("LLM_Implementation"), "llm-implementation");
        assert_eq!(kind("spike"), "spike");
        assert_eq!(kind(""), "");
    }
}
