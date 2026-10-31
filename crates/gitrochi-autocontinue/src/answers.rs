//! Answers for `AskUserQuestion` and approval for `ExitPlanMode`, as the `updatedInput`
//! a PreToolUse hook returns with `permissionDecision: "allow"`.

use serde_json::{Map, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskQuestion {
    pub question: String,
    pub header: String,
    pub multi_select: bool,
    pub options: Vec<AskOption>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskOption {
    pub label: String,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub question: String,
    /// The chosen label; several labels joined with ", " for a multi-select question.
    pub answer: String,
    /// False when no option was marked as recommended and the first one was taken.
    pub recommended: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AskAnswers {
    pub questions: Vec<AskQuestion>,
    pub answers: Vec<Answer>,
    /// The original input with `answers` added, ready for `updatedInput`.
    pub updated_input: Value,
}

/// Words that mark an option the agent recommends, when they stand in brackets at the end
/// or start of a label: `React (Recommended)`, `(추천) A`, `A（推奨）`.
const MARKS: &[&str] = &[
    "recommended",
    "recommend",
    "suggested",
    "추천",
    "권장",
    "추천안",
    "推奨",
    "おすすめ",
    "お勧め",
    "推荐",
    "建议",
    "建議",
];

pub fn is_recommended(label: &str) -> bool {
    bracketed(label).iter().any(|inner| {
        let inner = inner.trim().to_lowercase();
        MARKS
            .iter()
            .any(|m| inner == *m || inner.starts_with(&format!("{m}:")))
    })
}

/// The texts inside (), （）, [] and 【】 in a label.
fn bracketed(label: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current: Option<String> = None;
    for c in label.chars() {
        match c {
            '(' | '（' | '[' | '【' => current = Some(String::new()),
            ')' | '）' | ']' | '】' => {
                if let Some(text) = current.take() {
                    out.push(text);
                }
            }
            _ => {
                if let Some(text) = current.as_mut() {
                    text.push(c);
                }
            }
        }
    }
    out
}

/// The questions of an `AskUserQuestion` input; malformed entries are kept with empty fields.
pub fn parse_questions(tool_input: &Value) -> Vec<AskQuestion> {
    let Some(list) = tool_input.get("questions").and_then(Value::as_array) else {
        return Vec::new();
    };
    let text = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    list.iter()
        .map(|q| AskQuestion {
            question: text(q, "question"),
            header: text(q, "header"),
            multi_select: q
                .get("multiSelect")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            options: q
                .get("options")
                .and_then(Value::as_array)
                .map(|options| {
                    options
                        .iter()
                        .map(|o| match o {
                            // tolerate plain strings as options
                            Value::String(label) => AskOption {
                                label: label.clone(),
                                description: String::new(),
                            },
                            _ => AskOption {
                                label: text(o, "label"),
                                description: text(o, "description"),
                            },
                        })
                        .filter(|o| !o.label.trim().is_empty())
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect()
}

/// For each question the option marked as recommended (all of them for a multi-select
/// question), else the first option. None when a question has no text or no options, or
/// two questions share a text: the answers map is keyed by question text.
pub fn pick_answers(tool_input: &Value) -> Option<AskAnswers> {
    let questions = parse_questions(tool_input);
    if questions.is_empty() {
        return None;
    }
    let mut answers: Vec<Answer> = Vec::new();
    for q in &questions {
        if q.question.trim().is_empty()
            || q.options.is_empty()
            || answers.iter().any(|a| a.question == q.question)
        {
            return None;
        }
        let marked: Vec<&AskOption> = q
            .options
            .iter()
            .filter(|o| is_recommended(&o.label) || is_recommended(&o.description))
            .collect();
        let (labels, recommended): (Vec<&str>, bool) = match (marked.is_empty(), q.multi_select) {
            (true, _) => (vec![q.options[0].label.as_str()], false),
            (false, true) => (marked.iter().map(|o| o.label.as_str()).collect(), true),
            (false, false) => (vec![marked[0].label.as_str()], true),
        };
        answers.push(Answer {
            question: q.question.clone(),
            answer: labels.join(", "),
            recommended,
        });
    }
    let mut updated = match tool_input {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    let map: Map<String, Value> = answers
        .iter()
        .map(|a| (a.question.clone(), Value::String(a.answer.clone())))
        .collect();
    updated.insert("answers".into(), Value::Object(map));
    Some(AskAnswers {
        questions,
        answers,
        updated_input: Value::Object(updated),
    })
}

/// `updatedInput` for approving a plan: the input as Claude Code passed it (with the plan
/// it injected), since `allow` alone does not answer `ExitPlanMode`.
pub fn approve_plan(tool_input: &Value) -> Value {
    match tool_input {
        Value::Object(map) => Value::Object(map.clone()),
        _ => Value::Object(Map::new()),
    }
}
