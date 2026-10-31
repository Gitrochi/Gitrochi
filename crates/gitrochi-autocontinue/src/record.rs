//! The JSON the Ledger stores: `PromptPayload` is the `payload` of a pending prompt row,
//! `AutoReply` the `data` of the `auto_reply` event recorded when Gitrochi answered.
//! Field names are camelCase; both carry `schemaVersion`.

use crate::decide::PromptKind;
use crate::reply::Lang;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const RECORD_SCHEMA_VERSION: u32 = 1;

/// What is being asked, for the Inbox and the countdown.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptPayload {
    pub schema_version: u32,
    pub kind: PromptKind,
    /// One line: the question, the first question asked, the plan's title or the tool call.
    pub question: String,
    /// The paragraphs that ask (stop questions) or the plan (plans).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    /// Choices listed next to a stop question.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<OptionView>,
    /// `AskUserQuestion` questions.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub questions: Vec<QuestionView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<ToolView>,
    pub language: Lang,
    pub delay_sec: u32,
    /// What Gitrochi will send when nobody answers in time.
    pub proposed: Proposed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OptionView {
    pub label: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    pub recommended: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionView {
    pub question: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub header: String,
    pub multi_select: bool,
    pub options: Vec<OptionView>,
}

/// The tool a permission request or plan is about, summarized in one line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolView {
    pub name: String,
    pub summary: String,
}

/// An answer Gitrochi sends or sent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Proposed {
    /// The text that wakes the agent after a stop question.
    Reply {
        text: String,
    },
    /// Question text → chosen label(s), with the note Claude gets alongside.
    Answers {
        answers: BTreeMap<String, String>,
        note: String,
    },
    ApprovePlan {
        note: String,
    },
    Allow,
}

/// `data` of the Ledger event `auto_reply` (actor `auto`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoReply {
    pub schema_version: u32,
    pub kind: PromptKind,
    pub question: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<String>,
    pub sent: Proposed,
    /// Why this answer: `question:<cue>`, `answers:recommended`, `answers:first-option`,
    /// `answers:mixed`, `plan:approve` or `permission:no-rule`.
    pub rule: String,
    pub delay_sec: u32,
    pub language: Lang,
    /// Automatic answers to questions in a row, this one included.
    pub consecutive: u32,
}
