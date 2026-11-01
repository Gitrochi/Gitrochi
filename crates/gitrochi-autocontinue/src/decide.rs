//! One decision per hook call: pass through now, or wait and then send a prepared answer.
//! The Ledger hook handler stores the payload, waits `delay_sec`, and sends `output` only
//! if nobody answered in the meantime.

use crate::answers::{approve_plan, pick_answers};
use crate::input::{HookEvent, HookInput};
use crate::output::{permission_allow, pre_tool_use_allow, stop_wake, HookOutput};
use crate::permission::{evaluate_permission, PermissionContext, Rule, Verdict};
use crate::policy::{Policy, Triggers};
use crate::question::classify_stop;
use crate::record::{
    AutoReply, OptionView, PromptPayload, Proposed, QuestionView, ToolView, RECORD_SCHEMA_VERSION,
};
use crate::reply::{
    compose_answer_note, compose_plan_note, compose_reply, reply_language, Lang, REPLY_TAG,
};
use crate::risk::risky;
use crate::text::one_line;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// The `kind` of a pending prompt in the Ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PromptKind {
    StopQuestion,
    AskUserQuestion,
    ExitPlanMode,
    Permission,
}

impl PromptKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::StopQuestion => "stop_question",
            Self::AskUserQuestion => "ask_user_question",
            Self::ExitPlanMode => "exit_plan_mode",
            Self::Permission => "permission",
        }
    }

    /// Synchronous hooks hide Claude Code's own prompt while they wait, so they need the
    /// app's countdown to be answerable. The Stop hook runs in the background: the person
    /// can still type in the terminal.
    pub fn requires_app(self) -> bool {
        !matches!(self, Self::StopQuestion)
    }

    fn enabled(self, triggers: &Triggers) -> bool {
        match self {
            Self::StopQuestion => triggers.stop_question,
            Self::AskUserQuestion => triggers.ask_user_question,
            Self::ExitPlanMode => triggers.exit_plan_mode,
            Self::Permission => triggers.permission,
        }
    }
}

/// Per-session state the handler keeps between calls.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SessionState {
    /// Automatic answers of any kind since the person's last input (design §9.4: the
    /// session's `auto_reply` events since the person last answered or typed).
    pub consecutive: u32,
}

impl SessionState {
    /// After a UserPromptSubmit: the person's own prompt starts the count again.
    pub fn after_prompt(self, prompt: &str) -> Self {
        if is_person_prompt(prompt) {
            Self { consecutive: 0 }
        } else {
            self
        }
    }

    /// After the person answered a pending prompt in the app.
    pub fn after_person(self) -> Self {
        Self { consecutive: 0 }
    }

    /// After Gitrochi sent an automatic answer.
    pub fn after_auto_reply(self) -> Self {
        Self {
            consecutive: self.consecutive.saturating_add(1),
        }
    }
}

/// Whether a submitted prompt came from the person. Claude Code also submits prompts for
/// scheduled tasks, background agents and other sessions, wrapped in one XML-like element;
/// those, and anything quoting Gitrochi's own reply, do not reset the count. The wake-up of
/// an `asyncRewake` Stop hook (Gitrochi's own answer) arrives as a task notification, so a
/// prompt that starts with one never counts either, whatever follows (issue #171).
pub fn is_person_prompt(prompt: &str) -> bool {
    let text = prompt.trim();
    if text.is_empty() || text.contains(REPLY_TAG) {
        return false;
    }
    if let Some(rest) = text.strip_prefix("<task-notification") {
        if rest.starts_with(|c: char| c == '>' || c.is_whitespace()) {
            return false;
        }
    }
    match envelope(text) {
        Some(tag) => tag == "pasted_content",
        None => true,
    }
}

/// The tag of a prompt that is one element from start to end: `<tag …>…</tag …>`.
fn envelope(text: &str) -> Option<&str> {
    let rest = text.strip_prefix('<')?;
    let end = rest.find(|c: char| c == '>' || c.is_whitespace())?;
    let tag = &rest[..end];
    let valid = !tag.is_empty()
        && tag
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !valid {
        return None;
    }
    let close = format!("</{tag}");
    let last = text.rfind(&close)?;
    text[last..].trim_end().ends_with('>').then_some(tag)
}

/// The app touches `ledger/app.alive` every 5 seconds; it counts as running while the file
/// is younger than this (design §9.1).
pub const HEARTBEAT_MAX_AGE_SEC: u64 = 15;

/// Whether the app's last heartbeat (Unix seconds) is recent enough to count it running.
pub fn app_alive(last_heartbeat: Option<u64>, now: u64) -> bool {
    // a beat a second ahead is clock skew; further ahead it is not to be trusted
    last_heartbeat
        .is_some_and(|beat| beat <= now + 1 && now.saturating_sub(beat) < HEARTBEAT_MAX_AGE_SEC)
}

/// D10: with the app closed nobody sees the countdown, so a synchronous hook ends at once
/// without a decision and Claude Code shows its own prompt.
pub fn should_wait(kind: PromptKind, app_alive: bool) -> bool {
    app_alive || !kind.requires_app()
}

#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    /// End the hook now without output.
    Pass(Pass),
    /// Store the prompt, wait, then send the output unless someone answered.
    Wait(Box<Wait>),
}

impl Decision {
    pub fn output(&self) -> HookOutput {
        match self {
            Self::Pass(_) => HookOutput::Silent,
            Self::Wait(wait) => wait.output.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Wait {
    pub kind: PromptKind,
    pub delay_sec: u32,
    pub output: HookOutput,
    pub payload: PromptPayload,
    pub reply: AutoReply,
}

/// Why nothing is answered automatically.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum Pass {
    Disabled,
    TriggerOff {
        kind: PromptKind,
    },
    AppClosed {
        kind: PromptKind,
    },
    #[serde(rename_all = "camelCase")]
    LimitReached {
        consecutive: u32,
        max: u32,
    },
    /// Another stop hook is already continuing the turn.
    StopHookActive,
    NotAQuestion,
    /// The question, chosen answer or plan is about something hard to reverse.
    Risky {
        kind: PromptKind,
        reason: String,
    },
    /// An `AskUserQuestion` without options to choose from.
    NoAnswer,
    Held {
        rule: Rule,
        detail: String,
    },
    NotHandled {
        event: String,
        tool: String,
    },
}

impl Pass {
    pub fn message(&self) -> String {
        match self {
            Self::Disabled => "auto-continue is off".into(),
            Self::TriggerOff { kind } => format!("auto-continue is off for {}", kind.as_str()),
            Self::AppClosed { kind } => format!(
                "the app is closed, so {} waits for the person",
                kind.as_str()
            ),
            Self::LimitReached { consecutive, max } => {
                format!("{consecutive} automatic answers in a row (limit {max})")
            }
            Self::StopHookActive => "another stop hook is already continuing the turn".into(),
            Self::NotAQuestion => "the turn did not end with a question".into(),
            Self::Risky { reason, .. } => {
                format!("the prompt is about something hard to reverse ({reason})")
            }
            Self::NoAnswer => "the question has no options to choose from".into(),
            Self::Held { rule, detail } => format!("held by {}: {detail}", rule.id()),
            Self::NotHandled { event, tool } => {
                if tool.is_empty() {
                    format!("{event} is not handled")
                } else {
                    format!("{event} for {tool} is not handled")
                }
            }
        }
    }
}

/// Decides one hook call. `state` is the session's count of automatic answers, `ctx` the
/// permission context, `app_alive` whether the app can show the countdown (D10).
pub fn decide(
    input: &HookInput,
    policy: &Policy,
    state: SessionState,
    ctx: &PermissionContext,
    app_alive: bool,
) -> Decision {
    let kind = match (input.event(), input.tool_name.as_str()) {
        (HookEvent::Stop, _) => PromptKind::StopQuestion,
        (HookEvent::PreToolUse, "AskUserQuestion") => PromptKind::AskUserQuestion,
        (HookEvent::PreToolUse, "ExitPlanMode") => PromptKind::ExitPlanMode,
        (HookEvent::PermissionRequest, _) => PromptKind::Permission,
        (event, tool) => {
            return Decision::Pass(Pass::NotHandled {
                event: event.name().to_string(),
                tool: tool.to_string(),
            })
        }
    };
    if !policy.enabled {
        return Decision::Pass(Pass::Disabled);
    }
    if !kind.enabled(&policy.triggers) {
        return Decision::Pass(Pass::TriggerOff { kind });
    }
    if !should_wait(kind, app_alive) {
        return Decision::Pass(Pass::AppClosed { kind });
    }
    let max = policy
        .max_consecutive
        .min(crate::policy::MAX_CONSECUTIVE_LIMIT);
    if state.consecutive >= max {
        return Decision::Pass(Pass::LimitReached {
            consecutive: state.consecutive,
            max,
        });
    }
    let consecutive = state.consecutive + 1;
    let result = match kind {
        PromptKind::StopQuestion => stop(input, policy, state),
        PromptKind::AskUserQuestion => ask(input, policy),
        PromptKind::ExitPlanMode => plan(input, policy),
        PromptKind::Permission => permission(input, policy, ctx),
    };
    match result {
        Ok((payload, output, sent, rule, options)) => {
            let reply = AutoReply {
                schema_version: RECORD_SCHEMA_VERSION,
                kind,
                question: payload.question.clone(),
                options,
                sent,
                rule,
                delay_sec: policy.delay(),
                language: payload.language,
                consecutive,
            };
            Decision::Wait(Box::new(Wait {
                kind,
                delay_sec: policy.delay(),
                output,
                payload,
                reply,
            }))
        }
        Err(pass) => Decision::Pass(pass),
    }
}

type Prepared = (PromptPayload, HookOutput, Proposed, String, Vec<String>);

fn payload(
    kind: PromptKind,
    question: String,
    language: Lang,
    policy: &Policy,
    proposed: Proposed,
) -> PromptPayload {
    PromptPayload {
        schema_version: RECORD_SCHEMA_VERSION,
        kind,
        question,
        text: String::new(),
        options: Vec::new(),
        questions: Vec::new(),
        tool: None,
        language,
        delay_sec: policy.delay(),
        proposed,
    }
}

fn stop(input: &HookInput, policy: &Policy, state: SessionState) -> Result<Prepared, Pass> {
    // a stop hook that is already continuing the turn is someone else's loop unless the
    // continuation is ours
    if input.stop_hook_active && state.consecutive == 0 {
        return Err(Pass::StopHookActive);
    }
    let question = classify_stop(&input.last_assistant_message).ok_or(Pass::NotAQuestion)?;
    if let Some(reason) = risky(&question.text, &policy.protected()) {
        return Err(Pass::Risky {
            kind: PromptKind::StopQuestion,
            reason: reason.into(),
        });
    }
    let lang = reply_language(&question.text, policy);
    let text = compose_reply(&question.summary, lang, policy);
    let sent = Proposed::Reply { text: text.clone() };
    let mut p = payload(
        PromptKind::StopQuestion,
        question.summary.clone(),
        lang,
        policy,
        sent.clone(),
    );
    p.text = question.text.clone();
    p.options = question
        .options
        .iter()
        .map(|c| OptionView {
            label: c.label.clone(),
            description: String::new(),
            recommended: c.recommended,
        })
        .collect();
    let labels = question.options.iter().map(|c| c.label.clone()).collect();
    Ok((
        p,
        stop_wake(&text),
        sent,
        format!("question:{}", question.cue),
        labels,
    ))
}

fn ask(input: &HookInput, policy: &Policy) -> Result<Prepared, Pass> {
    let picked = pick_answers(&input.tool_input).ok_or(Pass::NoAnswer)?;
    let protected = policy.protected();
    for (q, a) in picked.questions.iter().zip(&picked.answers) {
        let descriptions: Vec<&str> = q
            .options
            .iter()
            .filter(|o| a.answer.split(", ").any(|l| l == o.label))
            .map(|o| o.description.as_str())
            .collect();
        let chosen = format!("{} {}", a.answer, descriptions.join(" "));
        if let Some(reason) = risky(&chosen, &protected) {
            return Err(Pass::Risky {
                kind: PromptKind::AskUserQuestion,
                reason: reason.into(),
            });
        }
    }
    let first = picked.questions[0].question.clone();
    let lang = reply_language(&first, policy);
    let note = compose_answer_note(&picked.answers, lang, policy);
    let answers: BTreeMap<String, String> = picked
        .answers
        .iter()
        .map(|a| (a.question.clone(), a.answer.clone()))
        .collect();
    let sent = Proposed::Answers {
        answers,
        note: note.clone(),
    };
    let summary = if picked.questions.len() == 1 {
        one_line(&first, 160)
    } else {
        one_line(
            &picked
                .questions
                .iter()
                .map(|q| q.question.as_str())
                .collect::<Vec<_>>()
                .join(" / "),
            160,
        )
    };
    let mut p = payload(
        PromptKind::AskUserQuestion,
        summary,
        lang,
        policy,
        sent.clone(),
    );
    p.questions = picked
        .questions
        .iter()
        .map(|q| QuestionView {
            question: q.question.clone(),
            header: q.header.clone(),
            multi_select: q.multi_select,
            options: q
                .options
                .iter()
                .map(|o| OptionView {
                    label: o.label.clone(),
                    description: o.description.clone(),
                    recommended: crate::answers::is_recommended(&o.label)
                        || crate::answers::is_recommended(&o.description),
                })
                .collect(),
        })
        .collect();
    let rule = match (
        picked.answers.iter().all(|a| a.recommended),
        picked.answers.iter().any(|a| a.recommended),
    ) {
        (true, _) => "answers:recommended",
        (false, false) => "answers:first-option",
        (false, true) => "answers:mixed",
    };
    let labels = picked.answers.iter().map(|a| a.answer.clone()).collect();
    let output = pre_tool_use_allow(picked.updated_input, Some(&note));
    Ok((p, output, sent, rule.to_string(), labels))
}

fn plan(input: &HookInput, policy: &Policy) -> Result<Prepared, Pass> {
    let text = input
        .tool_input
        .get("plan")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if let Some(reason) = risky(&text, &policy.protected()) {
        return Err(Pass::Risky {
            kind: PromptKind::ExitPlanMode,
            reason: reason.into(),
        });
    }
    let lang = reply_language(&text, policy);
    let note = compose_plan_note(lang, policy);
    let title = text
        .lines()
        .map(|l| l.trim().trim_start_matches('#').trim())
        .find(|l| !l.is_empty())
        .unwrap_or("Plan")
        .to_string();
    let sent = Proposed::ApprovePlan { note: note.clone() };
    let mut p = payload(
        PromptKind::ExitPlanMode,
        one_line(&title, 160),
        lang,
        policy,
        sent.clone(),
    );
    p.text = if text.chars().count() > 4000 {
        format!("{}…", text.chars().take(3999).collect::<String>())
    } else {
        text
    };
    let file = input
        .tool_input
        .get("planFilePath")
        .and_then(Value::as_str)
        .unwrap_or("");
    p.tool = Some(ToolView {
        name: "ExitPlanMode".into(),
        summary: file.to_string(),
    });
    let output = pre_tool_use_allow(approve_plan(&input.tool_input), Some(&note));
    Ok((p, output, sent, "plan:approve".into(), Vec::new()))
}

fn permission(
    input: &HookInput,
    policy: &Policy,
    ctx: &PermissionContext,
) -> Result<Prepared, Pass> {
    match evaluate_permission(&input.tool_name, &input.tool_input, ctx) {
        Verdict::Hold(hold) => Err(Pass::Held {
            rule: hold.rule,
            detail: hold.detail,
        }),
        Verdict::Allow => {
            let summary = tool_summary(&input.tool_name, &input.tool_input);
            let lang = match policy.language {
                crate::policy::Language::Auto => Lang::En,
                _ => reply_language("", policy),
            };
            let mut p = payload(
                PromptKind::Permission,
                one_line(&format!("{}: {summary}", input.tool_name), 160),
                lang,
                policy,
                Proposed::Allow,
            );
            p.tool = Some(ToolView {
                name: input.tool_name.clone(),
                summary,
            });
            Ok((
                p,
                permission_allow(),
                Proposed::Allow,
                "permission:no-rule".into(),
                Vec::new(),
            ))
        }
    }
}

/// One line about a tool call: the command, the file, the URL or the query.
fn tool_summary(tool: &str, input: &Value) -> String {
    let field = |k: &str| input.get(k).and_then(Value::as_str);
    let text = match tool {
        "Bash" | "PowerShell" => field("command"),
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        _ => field("file_path")
            .or_else(|| field("notebook_path"))
            .or_else(|| field("path"))
            .or_else(|| field("pattern")),
    };
    match text {
        Some(t) => one_line(t.lines().next().unwrap_or(t), 200),
        None => String::new(),
    }
}
