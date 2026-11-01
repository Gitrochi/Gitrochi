use serde_json::Value;

/// The hook events this crate decides on; every other event passes through untouched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookEvent {
    Stop,
    PreToolUse,
    PermissionRequest,
    UserPromptSubmit,
    Other(String),
}

impl HookEvent {
    pub fn parse(name: &str) -> Self {
        match name {
            "Stop" => Self::Stop,
            "PreToolUse" => Self::PreToolUse,
            "PermissionRequest" => Self::PermissionRequest,
            "UserPromptSubmit" => Self::UserPromptSubmit,
            other => Self::Other(other.to_string()),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Stop => "Stop",
            Self::PreToolUse => "PreToolUse",
            Self::PermissionRequest => "PermissionRequest",
            Self::UserPromptSubmit => "UserPromptSubmit",
            Self::Other(name) => name,
        }
    }
}

/// Claude Code's hook input, read leniently: unknown fields are ignored and a missing or
/// mistyped field reads as empty, so newer and older Claude Code versions still parse.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HookInput {
    pub session_id: String,
    pub transcript_path: String,
    pub cwd: String,
    pub permission_mode: String,
    pub hook_event_name: String,
    /// Set when the hook fires inside a subagent.
    pub agent_id: Option<String>,
    /// The session's scratch folder (Claude Code 2.1.257+), where writes are allowed too.
    pub scratchpad_dir: Option<String>,
    /// Stop: Claude is already continuing because a stop hook said so.
    pub stop_hook_active: bool,
    /// Stop: the text of Claude's final response.
    pub last_assistant_message: String,
    /// PreToolUse and PermissionRequest.
    pub tool_name: String,
    pub tool_input: Value,
    /// UserPromptSubmit.
    pub prompt: String,
}

impl HookInput {
    pub fn parse(text: &str) -> Result<Self, serde_json::Error> {
        let value: Value = serde_json::from_str(text)?;
        Ok(Self::from_value(&value))
    }

    pub fn from_value(value: &Value) -> Self {
        let text = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        };
        let optional = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let stop_hook_active = match value.get("stop_hook_active") {
            Some(Value::Bool(flag)) => *flag,
            Some(Value::String(flag)) => flag.eq_ignore_ascii_case("true"),
            _ => false,
        };
        Self {
            session_id: text("session_id"),
            transcript_path: text("transcript_path"),
            cwd: text("cwd"),
            permission_mode: text("permission_mode"),
            hook_event_name: text("hook_event_name"),
            agent_id: optional("agent_id"),
            scratchpad_dir: optional("scratchpad_dir"),
            stop_hook_active,
            last_assistant_message: text("last_assistant_message"),
            tool_name: text("tool_name"),
            tool_input: value.get("tool_input").cloned().unwrap_or(Value::Null),
            prompt: text("prompt"),
        }
    }

    pub fn event(&self) -> HookEvent {
        HookEvent::parse(&self.hook_event_name)
    }
}
