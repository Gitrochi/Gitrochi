//! Whether a permission request may be allowed once nobody answered. Anything on the deny
//! list, or anything this module cannot read with certainty, is held for the person.

mod commands;
mod deny;
mod git;
pub(crate) mod paths;
mod powershell;
pub(crate) mod shell;
mod tools;

use crate::input::HookInput;
use crate::policy::Policy;
use deny::DenyRule;
use paths::AbsPath;
use serde::Serialize;
use serde_json::Value;

/// Why a request waits for the person. The ids are stable: the Ledger stores them and the
/// apps translate them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Rule {
    /// The command cannot be read with certainty: `$( )`, backticks, `eval`, `sh -c`,
    /// inline interpreter code, an unknown PowerShell command or git alias.
    AmbiguousShell,
    OutsideRepoWrite,
    GitInternals,
    AgentSettings,
    RecursiveDelete,
    GitClean,
    DiscardChanges,
    ForcePush,
    ProtectedBranchPush,
    PushTargetUnclear,
    RemoteDelete,
    SkipChecks,
    Sudo,
    Deploy,
    RemoteShell,
    PipeToShell,
    Credentials,
    GitchAccount,
    SystemChange,
    SystemInstall,
    RemoteApi,
    Mcp,
    UnknownTool,
    ExtraDeny,
}

impl Rule {
    pub fn id(self) -> &'static str {
        match self {
            Self::AmbiguousShell => "ambiguous-shell",
            Self::OutsideRepoWrite => "outside-repo-write",
            Self::GitInternals => "git-internals",
            Self::AgentSettings => "agent-settings",
            Self::RecursiveDelete => "recursive-delete",
            Self::GitClean => "git-clean",
            Self::DiscardChanges => "discard-changes",
            Self::ForcePush => "force-push",
            Self::ProtectedBranchPush => "protected-branch-push",
            Self::PushTargetUnclear => "push-target-unclear",
            Self::RemoteDelete => "remote-delete",
            Self::SkipChecks => "skip-checks",
            Self::Sudo => "sudo",
            Self::Deploy => "deploy",
            Self::RemoteShell => "remote-shell",
            Self::PipeToShell => "pipe-to-shell",
            Self::Credentials => "credentials",
            Self::GitchAccount => "gitch-account",
            Self::SystemChange => "system-change",
            Self::SystemInstall => "system-install",
            Self::RemoteApi => "remote-api",
            Self::Mcp => "mcp",
            Self::UnknownTool => "unknown-tool",
            Self::ExtraDeny => "extra-deny",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Hold {
    pub rule: Rule,
    /// For logs and the README: what was found, in English.
    pub detail: String,
}

impl Hold {
    pub(crate) fn new(rule: Rule, detail: impl Into<String>) -> Self {
        Self {
            rule,
            detail: detail.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Hold(Hold),
}

impl Verdict {
    pub fn is_allow(&self) -> bool {
        matches!(self, Self::Allow)
    }

    pub fn rule(&self) -> Option<Rule> {
        match self {
            Self::Allow => None,
            Self::Hold(hold) => Some(hold.rule),
        }
    }
}

/// What the permission check needs to know about the session.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PermissionContext {
    /// The repository or worktree the agent works in; writes elsewhere are held. Pass a
    /// canonical path: symlinks are not resolved.
    pub repo_root: String,
    /// Claude Code's working folder for the call (the hook input's `cwd`).
    pub cwd: String,
    /// The person's home folder, for `~` and `$HOME`.
    pub home: String,
    /// Other folders the agent may write to, such as the session's scratchpad.
    pub writable: Vec<String>,
    /// Branches protected in addition to main and master (`release/*` patterns work).
    pub protected_branches: Vec<String>,
    /// More rules that hold a request (README.md, "Extra rules").
    pub extra_deny: Vec<String>,
    /// MCP tools that may be allowed (`mcp__server__*` patterns work).
    pub allow_mcp: Vec<String>,
    /// The branch checked out in `cwd`, and its upstream's branch name on the remote
    /// (`main`, not `origin/main`), when known: they tell where a bare `git push` goes.
    pub current_branch: Option<String>,
    pub upstream_branch: Option<String>,
}

impl PermissionContext {
    /// The context for one hook call: the session's folders from the input, the rules from
    /// the policy.
    pub fn new(input: &HookInput, policy: &Policy, repo_root: &str, home: &str) -> Self {
        Self {
            repo_root: repo_root.to_string(),
            cwd: input.cwd.clone(),
            home: home.to_string(),
            writable: input.scratchpad_dir.iter().cloned().collect(),
            protected_branches: policy.protected_branches.clone(),
            extra_deny: policy.extra_deny.clone(),
            allow_mcp: policy.allow_mcp.clone(),
            current_branch: None,
            upstream_branch: None,
        }
    }
}

/// The context with its paths parsed and its rules compiled.
pub(crate) struct Env {
    pub repo: Option<AbsPath>,
    pub roots: Vec<AbsPath>,
    pub cwd: Option<AbsPath>,
    pub home: Option<AbsPath>,
    pub windows: bool,
    pub protected: Vec<String>,
    pub extra: Vec<DenyRule>,
    pub allow_mcp: Vec<String>,
    pub current_branch: Option<String>,
    pub upstream_branch: Option<String>,
}

impl Env {
    fn new(ctx: &PermissionContext) -> Self {
        let repo = AbsPath::parse(&ctx.repo_root);
        let mut roots: Vec<AbsPath> = repo.iter().cloned().collect();
        roots.extend(ctx.writable.iter().filter_map(|w| AbsPath::parse(w)));
        let cwd = AbsPath::parse(&ctx.cwd).or_else(|| repo.clone());
        let mut protected: Vec<String> = crate::policy::DEFAULT_PROTECTED_BRANCHES
            .iter()
            .map(|b| b.to_string())
            .collect();
        for b in &ctx.protected_branches {
            let b = b.trim();
            if !b.is_empty() && !protected.iter().any(|p| p == b) {
                protected.push(b.to_string());
            }
        }
        Self {
            windows: repo.as_ref().is_some_and(AbsPath::is_windows),
            repo,
            roots,
            cwd,
            home: AbsPath::parse(&ctx.home),
            protected,
            extra: ctx
                .extra_deny
                .iter()
                .filter_map(|r| DenyRule::parse(r))
                .collect(),
            allow_mcp: ctx.allow_mcp.clone(),
            current_branch: ctx.current_branch.clone().filter(|b| !b.is_empty()),
            upstream_branch: ctx.upstream_branch.clone().filter(|b| !b.is_empty()),
        }
    }

    pub(crate) fn inside(&self, path: &AbsPath) -> bool {
        self.roots.iter().any(|root| path.starts_with(root))
    }

    pub(crate) fn is_protected(&self, branch: &str) -> bool {
        self.protected.iter().any(|p| deny::glob_match(p, branch))
    }
}

/// Tools that only read, or only change Claude Code's own state.
const READ_ONLY_TOOLS: &[&str] = &[
    "Read",
    "Glob",
    "Grep",
    "LS",
    "NotebookRead",
    "WebFetch",
    "WebSearch",
    "TodoWrite",
    "TodoRead",
    "Task",
    "Agent",
    "ToolSearch",
    "BashOutput",
    "TaskOutput",
    "Skill",
    "ListMcpResourcesTool",
    "ReadMcpResourceTool",
];

pub fn evaluate_permission(
    tool_name: &str,
    tool_input: &Value,
    ctx: &PermissionContext,
) -> Verdict {
    let env = Env::new(ctx);
    match check(tool_name, tool_input, &env) {
        Ok(()) => Verdict::Allow,
        Err(hold) => Verdict::Hold(hold),
    }
}

fn check(tool: &str, input: &Value, env: &Env) -> Result<(), Hold> {
    deny::check_tool(&env.extra, tool, input, env)?;
    let field = |key: &str| input.get(key).and_then(Value::as_str);
    match tool {
        "Bash" => {
            let command = field("command").unwrap_or("");
            commands::check(command, shell::Dialect::Posix, env)
        }
        "PowerShell" => {
            let command = field("command").unwrap_or("");
            commands::check(command, shell::Dialect::PowerShell, env)
        }
        "Edit" | "Write" | "MultiEdit" => file_write(field("file_path"), env),
        "NotebookEdit" => file_write(field("notebook_path").or(field("file_path")), env),
        "Read" | "NotebookRead" => file_read(field("file_path").or(field("notebook_path"))),
        "Glob" | "Grep" | "LS" => file_read(field("path")),
        _ if READ_ONLY_TOOLS.contains(&tool) => Ok(()),
        "AskUserQuestion" | "ExitPlanMode" => Err(Hold::new(
            Rule::UnknownTool,
            format!("{tool} is answered through PreToolUse, not as a permission"),
        )),
        _ if tool.starts_with("mcp__") => {
            if env.allow_mcp.iter().any(|p| deny::glob_match(p, tool)) {
                Ok(())
            } else {
                Err(Hold::new(
                    Rule::Mcp,
                    format!("MCP tool `{tool}` is not on the allow list"),
                ))
            }
        }
        _ => Err(Hold::new(
            Rule::UnknownTool,
            format!("`{tool}` is not a tool this check knows"),
        )),
    }
}

fn file_read(path: Option<&str>) -> Result<(), Hold> {
    match path {
        Some(p) if paths::credential_parts(&paths::split_text(p)) => Err(Hold::new(
            Rule::Credentials,
            format!("reads `{p}`, which holds credentials"),
        )),
        _ => Ok(()),
    }
}

fn file_write(path: Option<&str>, env: &Env) -> Result<(), Hold> {
    let Some(path) = path.filter(|p| !p.trim().is_empty()) else {
        return Err(Hold::new(Rule::OutsideRepoWrite, "the edit names no file"));
    };
    commands::check_path_write(&shell::Word::plain(path), env.cwd.as_ref(), env)
}
