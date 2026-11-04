//! Release notes: a Markdown draft for one baseline, built from the sessions merged into it
//! or absorbed by its `release` report and from what their agents reported. Only the
//! baseline, sessions and agent events are read: never questions, answers, a person's
//! messages, notebook notes or work records.

use crate::baseline;
use crate::error::{Error, Result};
use crate::event::{self, EventView};
use crate::session::{self, SessionRow};
use crate::settings::Settings;
use crate::util::{self, Ms};
use crate::vocab::{self, Role};
use rusqlite::Connection;
use serde::Serialize;
use std::collections::BTreeSet;

/// Longest one-line summary, in characters; longer ones end with "…".
const SUMMARY_CHARS: usize = 160;

/// The roles in the order the draft lists them, with their headings.
const GROUPS: [(Role, &str); 5] = [
    (Role::Decision, "Decisions"),
    (Role::Implementation, "Implementation"),
    (Role::Research, "Research"),
    (Role::Document, "Documents"),
    (Role::Other, "Other"),
];

/// One artifact as the draft names it.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Artifact {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ver: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// One session in the draft.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub title: String,
    pub kind: String,
    /// `absorbed`: the release report absorbed it (it may have been reopened since);
    /// `merged`: otherwise merged into the version (its own report or a person's choice).
    pub how: &'static str,
    /// One line from its newest done, decision or merged report.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub artifacts: Vec<Artifact>,
}

/// Sessions of one role.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub role: Role,
    pub title: &'static str,
    pub sessions: Vec<Entry>,
}

/// The `release_notes` result.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseNotes {
    pub project: String,
    pub version: String,
    /// The baseline before it on the trunk.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous: Option<String>,
    /// When the baseline appeared (a tag's time, a release report's time …).
    pub released_at: Ms,
    /// The session whose release report made it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub released_by: Option<String>,
    /// The baseline's note: the release note, or what a person wrote for it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// Every version of the project's trunk, newest (HEAD) first, for choosing another one.
    pub versions: Vec<String>,
    /// Non-empty groups only, in the order decision, implementation, research, document, other.
    pub groups: Vec<Group>,
    pub markdown: String,
}

/// The first line of a report summary, with its spaces collapsed and cut to a readable length.
fn one_line(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() <= SUMMARY_CHARS {
        return Some(line);
    }
    let cut: String = line.chars().take(SUMMARY_CHARS - 1).collect();
    Some(format!("{}…", cut.trim_end()))
}

/// The newest summary its own agent wrote when it finished, decided or merged it, in that
/// order of preference. The merge another session's release writes is not the agent's own.
fn summary_of(events: &[EventView]) -> Option<String> {
    let own = |kind: &str| {
        events
            .iter()
            .rev()
            .filter(|e| e.actor == "agent" && e.kind == kind)
            .filter(|e| kind != "merged" || e.data.get("by").is_none())
            .find_map(|e| one_line(&e.summary))
    };
    own("done")
        .or_else(|| own("decision"))
        .or_else(|| own("merged"))
}

/// Every artifact its agent reported, newest version of each name, in the order first seen.
fn artifacts_of(events: &[EventView]) -> Vec<Artifact> {
    let mut out: Vec<Artifact> = Vec::new();
    for event in events.iter().filter(|e| e.actor == "agent") {
        for value in &event.artifacts {
            let Some(name) = value["name"].as_str().and_then(util::clean) else {
                continue;
            };
            let text = |key: &str| value[key].as_str().and_then(util::clean);
            let artifact = Artifact {
                name,
                ver: text("ver").or_else(|| text("ssot")),
                path: text("path"),
            };
            match out.iter_mut().find(|a| a.name == artifact.name) {
                Some(found) => *found = artifact,
                None => out.push(artifact),
            }
        }
    }
    out
}

/// Sessions the release reports of `version` absorbed.
fn absorbed(connection: &Connection, project: &str, version: &str) -> Result<BTreeSet<String>> {
    let mut statement = connection.prepare(
        "SELECT data FROM events WHERE project = ?1 AND type = 'release' AND version = ?2",
    )?;
    let mut out = BTreeSet::new();
    for data in statement.query_map([project, version], |r| r.get::<_, String>(0))? {
        let data: serde_json::Value = serde_json::from_str(&data?).unwrap_or_default();
        for id in data["absorbs"].as_array().into_iter().flatten() {
            if let Some(id) = id.as_str() {
                out.insert(id.to_string());
            }
        }
    }
    Ok(out)
}

fn local_date(connection: &Connection, ts: Ms) -> Result<String> {
    Ok(connection.query_row(
        "SELECT strftime('%Y-%m-%d', ?1 / 1000, 'unixepoch', 'localtime')",
        [ts],
        |r| r.get(0),
    )?)
}

fn artifact_text(a: &Artifact) -> String {
    let mut text = format!("`{}", a.name);
    if let Some(ver) = &a.ver {
        text.push('@');
        text.push_str(ver);
    }
    text.push('`');
    if let Some(path) = &a.path {
        text.push_str(&format!(" ({path})"));
    }
    text
}

fn markdown(notes: &ReleaseNotes, date: &str) -> String {
    let mut out = format!("# {} {}\n\n", notes.project, notes.version);
    let mut line = format!("Released {date}");
    if let Some(by) = &notes.released_by {
        line.push_str(&format!(" by {by}"));
    }
    if let Some(previous) = &notes.previous {
        line.push_str(&format!(" · changes since {previous}"));
    }
    out.push_str(&line);
    out.push_str(".\n");
    if let Some(note) = &notes.note {
        out.push('\n');
        for line in note.lines().map(str::trim_end) {
            if line.is_empty() {
                out.push_str(">\n");
            } else {
                out.push_str(&format!("> {line}\n"));
            }
        }
    }
    if notes.groups.is_empty() {
        out.push_str(&format!(
            "\nNo sessions were merged into {}.\n",
            notes.version
        ));
        return out;
    }
    for group in &notes.groups {
        out.push_str(&format!("\n## {}\n\n", group.title));
        for entry in &group.sessions {
            let role_kind = Role::parse(&entry.kind).is_some_and(|r| r == group.role);
            let label = if role_kind || entry.kind.is_empty() {
                format!("`{}`", entry.id)
            } else {
                format!("`{}` · {}", entry.id, entry.kind)
            };
            let title = if entry.title.is_empty() {
                entry.id.as_str()
            } else {
                entry.title.as_str()
            };
            out.push_str(&format!("- **{title}** ({label})"));
            if let Some(summary) = &entry.summary {
                out.push_str(&format!(" — {summary}"));
            }
            out.push('\n');
            if !entry.artifacts.is_empty() {
                let names: Vec<String> = entry.artifacts.iter().map(artifact_text).collect();
                out.push_str(&format!("  - Artifacts: {}\n", names.join(", ")));
            }
        }
    }
    out
}

/// The draft for `version` of `project` (HEAD when `version` is None or a word for latest).
pub fn build(
    connection: &Connection,
    settings: &Settings,
    project: &str,
    version: Option<&str>,
) -> Result<ReleaseNotes> {
    let trunk = baseline::trunk(connection, project)?;
    if trunk.is_empty() {
        let known = baseline::project(connection, project)?.is_some();
        return Err(Error::not_found(if known {
            format!("{project} has no baselines yet")
        } else {
            format!("No project {project}")
        }));
    }
    let head = trunk.last().map(|b| b.version.clone());
    let wanted = match version {
        None => head.clone(),
        Some(text) => util::resolve_version(Some(text), head.as_deref()),
    }
    .ok_or_else(|| Error::invalid("Give a version number (for example 1.4.2)"))?;
    let index = trunk
        .iter()
        .position(|b| b.version == wanted)
        .ok_or_else(|| Error::not_found(format!("No baseline {wanted} in {project}")))?;
    let found = &trunk[index];
    let previous = index.checked_sub(1).map(|i| trunk[i].version.clone());

    let absorbed = absorbed(connection, project, &wanted)?;
    let mut rows: Vec<(SessionRow, &'static str)> = session::list(connection, Some(project))?
        .into_iter()
        .filter_map(|row| {
            if absorbed.contains(&row.id) {
                Some((row, "absorbed"))
            } else if row.merged_into.as_deref() == Some(wanted.as_str()) {
                Some((row, "merged"))
            } else {
                None
            }
        })
        .collect();
    rows.sort_by(|(a, _), (b, _)| {
        vocab::kind(&a.kind)
            .cmp(&vocab::kind(&b.kind))
            .then(a.created_at.cmp(&b.created_at))
            .then(a.id.cmp(&b.id))
    });
    let mut groups: Vec<Group> = GROUPS
        .iter()
        .map(|(role, title)| Group {
            role: *role,
            title,
            sessions: Vec::new(),
        })
        .collect();
    for (row, how) in rows {
        let events = event::for_session(connection, &row.id)?;
        let role = settings.role(&row.kind);
        let entry = Entry {
            summary: summary_of(&events),
            artifacts: artifacts_of(&events),
            id: row.id,
            title: row.title,
            kind: row.kind,
            how,
        };
        if let Some(group) = groups.iter_mut().find(|g| g.role == role) {
            group.sessions.push(entry);
        }
    }
    groups.retain(|g| !g.sessions.is_empty());
    let mut notes = ReleaseNotes {
        project: project.to_string(),
        version: wanted,
        previous,
        released_at: found.ts,
        released_by: found.by_session.clone(),
        note: util::clean(&found.note),
        versions: trunk.iter().rev().map(|b| b.version.clone()).collect(),
        groups,
        markdown: String::new(),
    };
    let date = local_date(connection, found.ts)?;
    notes.markdown = markdown(&notes, &date);
    Ok(notes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(kind: &str, actor: &str, summary: &str, data: serde_json::Value) -> EventView {
        EventView {
            id: 0,
            session_id: "S1".into(),
            ts: 0,
            kind: kind.into(),
            actor: actor.into(),
            summary: summary.into(),
            body: Some("Never in the draft".into()),
            version: None,
            artifacts: Vec::new(),
            data,
            channel: String::new(),
            delivered_at: None,
        }
    }

    #[test]
    fn the_summary_is_the_agents_own_newest_outcome_on_one_line() {
        let events = vec![
            event("decision", "agent", "Keep the cache", json!({})),
            event(
                "done",
                "agent",
                "  Retry three times\n\nDetails below",
                json!({}),
            ),
            event("message", "human", "A person's note", json!({})),
            event(
                "merged",
                "agent",
                "Merged into 1.4.2 by S9's release",
                json!({"by": "S9"}),
            ),
        ];
        assert_eq!(summary_of(&events).as_deref(), Some("Retry three times"));
        assert_eq!(summary_of(&events[..1]).as_deref(), Some("Keep the cache"));
        // another session's release is not this agent's summary, and a person's text never is
        assert_eq!(summary_of(&events[2..]), None);
        let long = "word ".repeat(60);
        let line = one_line(&long).unwrap();
        assert_eq!(line.chars().count(), SUMMARY_CHARS);
        assert!(line.ends_with('…'));
    }

    #[test]
    fn artifacts_keep_the_newest_version_of_each_name() {
        let mut first = event("artifact", "agent", "", json!({}));
        first.artifacts = vec![
            json!({"name": "report.md"}),
            json!({"name": "bench", "ver": "1"}),
        ];
        let mut second = event("artifact", "agent", "", json!({}));
        second.artifacts = vec![json!({"name": "bench", "ssot": "2", "path": "out/bench.csv"})];
        let mut human = event("message", "human", "", json!({}));
        human.artifacts = vec![json!({"name": "private"})];
        let artifacts = artifacts_of(&[first, second, human]);
        assert_eq!(
            artifacts,
            vec![
                Artifact {
                    name: "report.md".into(),
                    ver: None,
                    path: None
                },
                Artifact {
                    name: "bench".into(),
                    ver: Some("2".into()),
                    path: Some("out/bench.csv".into())
                },
            ]
        );
        assert_eq!(artifact_text(&artifacts[1]), "`bench@2` (out/bench.csv)");
    }
}
