//! Auto-continue for agents nobody is answering. When a Claude Code session that Gitrochi
//! launched stops to ask the person something — a turn that ends with a question, an
//! `AskUserQuestion` prompt, a plan to approve or a permission request — this crate decides
//! whether Gitrochi may answer on the person's behalf once the delay has passed, and builds
//! exactly what the hook then prints. Pure logic: no database, network or waiting; the
//! Ledger hook handler stores the pending prompt, waits and sends the output. README.md
//! describes the rules, the output formats and the shapes the Ledger stores.

mod answers;
mod decide;
mod input;
mod output;
mod permission;
mod policy;
mod question;
mod record;
mod reply;
mod risk;
mod text;

pub use answers::{approve_plan, is_recommended, parse_questions, pick_answers};
pub use answers::{Answer, AskAnswers, AskOption, AskQuestion};
pub use decide::{
    app_alive, decide, is_person_prompt, should_wait, Decision, Pass, PromptKind, SessionState,
    Wait, HEARTBEAT_MAX_AGE_SEC,
};
pub use input::{HookEvent, HookInput};
pub use output::{
    hook_settings, permission_allow, permission_deny, pre_tool_use_allow, pre_tool_use_deny,
    session_start_context, silent, stop_wake, HookOutput,
};
pub use permission::{evaluate_permission, Hold, PermissionContext, Rule, Verdict};
pub use policy::{
    Language, Policy, Triggers, DEFAULT_DELAY_SEC, DEFAULT_MAX_CONSECUTIVE,
    DEFAULT_PROTECTED_BRANCHES, HOOK_TIMEOUT_MARGIN_SEC, MAX_CONSECUTIVE_LIMIT, MAX_DELAY_SEC,
    MIN_DELAY_SEC,
};
pub use question::{classify_stop, Choice, StopQuestion};
pub use record::RECORD_SCHEMA_VERSION;
pub use record::{AutoReply, OptionView, PromptPayload, Proposed, QuestionView, ToolView};
pub use reply::{
    compose_answer_note, compose_plan_note, compose_reply, compose_session_context,
    detect_language, reply_language, Lang, REPLY_TAG,
};
pub use risk::risky;

#[cfg(test)]
mod tests;
