//! Extra rules from the settings, in Claude Code's permission-rule style:
//! `Bash(npm run e2e*)` matches a shell command, `Edit(docs/**)` a file a tool writes,
//! `Read(~/secrets/*)` a file it reads, `WebFetch(*example.org*)` any text field of the
//! tool input, and a bare `ToolName` or `mcp__server__*` a whole tool. `*` matches any run
//! of characters; a trailing `:*` matches the command and anything after it.

use super::paths::AbsPath;
use super::{Env, Hold, Rule};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DenyRule {
    Tool(String),
    Command(String),
    WritePath(String),
    ReadPath(String),
    Field { tool: String, pattern: String },
}

impl DenyRule {
    pub(crate) fn parse(rule: &str) -> Option<Self> {
        let rule = rule.trim();
        if rule.is_empty() {
            return None;
        }
        let Some((tool, rest)) = rule.split_once('(') else {
            return Some(Self::Tool(rule.to_string()));
        };
        let Some(pattern) = rest.strip_suffix(')') else {
            return Some(Self::Tool(rule.to_string()));
        };
        let pattern = pattern.trim().to_string();
        Some(match tool.trim() {
            "Bash" | "PowerShell" => Self::Command(pattern),
            "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => Self::WritePath(pattern),
            "Read" | "Glob" | "Grep" => Self::ReadPath(pattern),
            other => Self::Field {
                tool: other.to_string(),
                pattern,
            },
        })
    }
}

/// `*` matches any run of characters, everything else itself.
pub(crate) fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while ti < t.len() {
        if pi < p.len() && p[pi] == '*' {
            star = Some((pi, ti));
            pi += 1;
        } else if pi < p.len() && p[pi] == t[ti] {
            pi += 1;
            ti += 1;
        } else if let Some((sp, st)) = star {
            pi = sp + 1;
            ti = st + 1;
            star = Some((sp, st + 1));
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
}

fn command_match(pattern: &str, command: &str) -> bool {
    if let Some(prefix) = pattern.strip_suffix(":*") {
        return command == prefix || command.starts_with(&format!("{prefix} "));
    }
    glob_match(pattern, command)
}

/// Rules on the tool and its input, checked before the built-in rules.
pub(crate) fn check_tool(
    rules: &[DenyRule],
    tool: &str,
    input: &Value,
    env: &Env,
) -> Result<(), Hold> {
    let path = ["file_path", "notebook_path", "path"]
        .iter()
        .find_map(|k| input.get(*k).and_then(Value::as_str));
    let writes = matches!(tool, "Edit" | "Write" | "MultiEdit" | "NotebookEdit");
    let reads = matches!(tool, "Read" | "Glob" | "Grep" | "NotebookRead");
    for rule in rules {
        let hit = match rule {
            DenyRule::Tool(pattern) => glob_match(pattern, tool),
            DenyRule::WritePath(pattern) => {
                writes && path.is_some_and(|p| path_match(pattern, p, env))
            }
            DenyRule::ReadPath(pattern) => {
                reads && path.is_some_and(|p| path_match(pattern, p, env))
            }
            DenyRule::Field { tool: t, pattern } => {
                glob_match(t, tool) && strings(input).iter().any(|s| glob_match(pattern, s))
            }
            DenyRule::Command(_) => false,
        };
        if hit {
            return Err(Hold::new(
                Rule::ExtraDeny,
                format!("matches the rule `{}`", describe(rule)),
            ));
        }
    }
    Ok(())
}

/// Rules on one simple shell command, given as its words joined by spaces.
pub(crate) fn check_command(rules: &[DenyRule], command: &str) -> Result<(), Hold> {
    for rule in rules {
        if let DenyRule::Command(pattern) = rule {
            if command_match(pattern, command) {
                return Err(Hold::new(
                    Rule::ExtraDeny,
                    format!("`{command}` matches the rule `Bash({pattern})`"),
                ));
            }
        }
    }
    Ok(())
}

fn describe(rule: &DenyRule) -> String {
    match rule {
        DenyRule::Tool(p) => p.clone(),
        DenyRule::Command(p) => format!("Bash({p})"),
        DenyRule::WritePath(p) => format!("Edit({p})"),
        DenyRule::ReadPath(p) => format!("Read({p})"),
        DenyRule::Field { tool, pattern } => format!("{tool}({pattern})"),
    }
}

/// A path pattern is relative to the repository unless it starts at `/`, a drive or `~/`.
fn path_match(pattern: &str, path: &str, env: &Env) -> bool {
    let full = if let Some(rest) = pattern.strip_prefix("~/") {
        env.home.as_ref().map(|h| join_pattern(h, rest))
    } else if AbsPath::parse(pattern).is_some() {
        Some(pattern.replace('\\', "/"))
    } else {
        env.repo.as_ref().map(|r| join_pattern(r, pattern))
    };
    let Some(full) = full else { return false };
    let target = AbsPath::parse(path)
        .map(|p| p.display())
        .unwrap_or_else(|| path.to_string());
    let target = target.replace('\\', "/");
    if env.windows {
        glob_match(&full.to_lowercase(), &target.to_lowercase())
    } else {
        glob_match(&full, &target)
    }
}

fn join_pattern(base: &AbsPath, rest: &str) -> String {
    let base = base.display().replace('\\', "/");
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        rest.trim_start_matches(['/', '\\'])
    )
}

fn strings(value: &Value) -> Vec<&str> {
    match value {
        Value::String(s) => vec![s.as_str()],
        Value::Array(list) => list.iter().flat_map(strings).collect(),
        Value::Object(map) => map.values().flat_map(strings).collect(),
        _ => Vec::new(),
    }
}
