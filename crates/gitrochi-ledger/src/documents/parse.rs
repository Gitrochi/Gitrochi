use regex_lite::Regex;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::OnceLock;

fn ids() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\b(?:[A-Za-z][A-Za-z0-9_]{0,23}-[A-Za-z0-9][A-Za-z0-9._-]{0,35}|[A-Z]{1,8}[0-9]{1,8})\b").unwrap()
    })
}

fn status(text: &str) -> &'static str {
    let lower = text.to_lowercase();
    if ["[x]", "| done", "| closed", "| resolved", "| complete"]
        .iter()
        .any(|s| lower.contains(s))
    {
        "done"
    } else if ["blocked", "on hold", "waiting"]
        .iter()
        .any(|s| lower.contains(s))
    {
        "blocked"
    } else {
        "open"
    }
}

/// Headings and first table cells define IDs; checkboxes and labelled sections supply tasks.
pub(super) fn entries(text: &str) -> Vec<Value> {
    let mut entries = Vec::new();
    let mut heading = String::new();
    let mut fence = false;
    let mut seen = HashSet::new();
    let mut section_kind = "task";
    let mut section_depth = 0;
    for (index, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.starts_with("```") || line.starts_with("~~~") {
            fence = !fence;
            continue;
        }
        if fence || line.is_empty() {
            continue;
        }
        let is_heading = line.starts_with('#');
        if is_heading {
            heading = line.trim_start_matches('#').trim().to_owned();
        }
        let lower = line.to_lowercase();
        let explicit_kind = if lower.contains("backflow") || lower.contains("feedback") {
            Some("backflow")
        } else if lower.contains("notice") || lower.contains("notification") {
            Some("notice")
        } else if lower.contains("directive") || lower.contains("instruction") {
            Some("directive")
        } else {
            None
        };
        if is_heading {
            let depth = line.chars().take_while(|c| *c == '#').count();
            if let Some(kind) = explicit_kind {
                section_kind = kind;
                section_depth = depth;
            } else if depth <= section_depth {
                section_kind = "task";
                section_depth = 0;
            }
        }
        let kind = explicit_kind.unwrap_or(section_kind);
        let checkbox = ["- [ ]", "- [x]", "- [X]", "* [ ]", "* [x]", "* [X]"]
            .iter()
            .any(|p| line.starts_with(p));
        let mut line_ids = Vec::new();
        for found in ids().find_iter(line).take(64) {
            let id = found.as_str().trim_end_matches('.').to_owned();
            if !id.bytes().any(|b| b.is_ascii_digit()) {
                continue;
            }
            if !line_ids.contains(&id) {
                line_ids.push(id);
            }
        }
        if entries.len() >= 5_000 {
            break;
        }
        let first_cell = line
            .trim_start_matches('|')
            .split('|')
            .next()
            .unwrap_or("")
            .trim();
        for id in &line_ids {
            if entries.len() >= 5_000 {
                break;
            }
            let definition = (is_heading && heading.starts_with(id))
                || (line.starts_with('|') && first_cell.trim_matches('`') == id);
            let key = format!("{id}:{}", index + 1);
            if seen.insert(key) {
                entries.push(json!({"id":id,"line":index+1,"text":line.chars().take(1200).collect::<String>(),
                    "heading":heading,"definition":definition,"kind":kind,"status":status(line),"task":checkbox || definition}));
            }
        }
        if checkbox && line_ids.is_empty() {
            entries.push(json!({"line":index+1,"text":line.chars().take(1200).collect::<String>(),
                "heading":heading,"definition":false,"kind":kind,"status":status(line),"task":true}));
        }
    }
    entries
}
