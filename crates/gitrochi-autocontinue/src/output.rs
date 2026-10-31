//! What a hook prints, in the shapes Claude Code reads
//! (https://code.claude.com/docs/en/hooks), and the hook settings that install the handler.

use crate::policy::{HOOK_TIMEOUT_MARGIN_SEC, MAX_DELAY_SEC, MIN_DELAY_SEC};
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq)]
pub enum HookOutput {
    /// Exit 0 with no output: Claude Code carries on as if the hook were not there.
    Silent,
    /// Exit 2 with the text on stderr. For a Stop hook with `asyncRewake` this wakes Claude
    /// and hands it the text as a system reminder.
    Wake(String),
    /// Exit 0 with this JSON on stdout.
    Json(Value),
}

impl HookOutput {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Wake(_) => 2,
            _ => 0,
        }
    }

    pub fn stdout(&self) -> String {
        match self {
            Self::Json(value) => value.to_string(),
            _ => String::new(),
        }
    }

    pub fn stderr(&self) -> String {
        match self {
            Self::Wake(text) => text.clone(),
            _ => String::new(),
        }
    }

    pub fn to_json(&self) -> Value {
        json!({"exitCode": self.exit_code(), "stdout": self.stdout(), "stderr": self.stderr()})
    }
}

pub fn silent() -> HookOutput {
    HookOutput::Silent
}

/// Stop with `asyncRewake`: decision fields do nothing in a background hook, so the reply
/// travels as exit code 2 and stderr.
pub fn stop_wake(reply: &str) -> HookOutput {
    HookOutput::Wake(reply.to_string())
}

/// PreToolUse answer for `AskUserQuestion` or `ExitPlanMode`: `allow` alone does not answer
/// them, the tool needs `updatedInput`. `context` tells Claude the answer was automatic.
pub fn pre_tool_use_allow(updated_input: Value, context: Option<&str>) -> HookOutput {
    let mut specific = json!({
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "updatedInput": updated_input,
    });
    if let Some(text) = context.filter(|t| !t.is_empty()) {
        specific["additionalContext"] = Value::String(text.to_string());
    }
    HookOutput::Json(json!({ "hookSpecificOutput": specific }))
}

/// PreToolUse deny, when the person turned a plan down in the app; Claude is told why.
pub fn pre_tool_use_deny(reason: &str) -> HookOutput {
    HookOutput::Json(json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
}

/// SessionStart context for Claude (at most 10,000 characters reach it in full).
pub fn session_start_context(text: &str) -> HookOutput {
    HookOutput::Json(json!({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": text,
        }
    }))
}

/// PermissionRequest allow for this one call. `updatedPermissions` is never set, so no
/// rule outlives the call.
pub fn permission_allow() -> HookOutput {
    HookOutput::Json(json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": "allow"},
        }
    }))
}

/// PermissionRequest deny, with the reason Claude is told.
pub fn permission_deny(message: &str) -> HookOutput {
    HookOutput::Json(json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": "deny", "message": message},
        }
    }))
}

/// The `hooks` entries that run the handler: `command` followed by the event name. Each
/// timeout is the delay plus a margin; the Stop hook runs in the background and wakes
/// Claude (`asyncRewake`), the others hold Claude while they wait. UserPromptSubmit does
/// not wait: it only tells the handler that the person typed, which resets the count.
pub fn hook_settings(command: &str, delay_sec: u32) -> Value {
    let timeout = delay_sec.clamp(MIN_DELAY_SEC, MAX_DELAY_SEC) + HOOK_TIMEOUT_MARGIN_SEC;
    let entry = |event: &str| format!("{command} {event}");
    json!({
        "Stop": [{
            "matcher": "",
            "hooks": [{
                "type": "command",
                "command": entry("Stop"),
                "async": true,
                "asyncRewake": true,
                "timeout": timeout,
            }],
        }],
        "PreToolUse": [{
            "matcher": "AskUserQuestion|ExitPlanMode",
            "hooks": [{"type": "command", "command": entry("PreToolUse"), "timeout": timeout}],
        }],
        "PermissionRequest": [{
            "matcher": "",
            "hooks": [{"type": "command", "command": entry("PermissionRequest"), "timeout": timeout}],
        }],
        "UserPromptSubmit": [{
            "matcher": "",
            "hooks": [{"type": "command", "command": entry("UserPromptSubmit"), "timeout": 10}],
        }],
    })
}
