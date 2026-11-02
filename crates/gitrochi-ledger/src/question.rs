//! Optional choice metadata for questions reported through MCP, CLI and pasted reports.

use crate::error::{Error, Result};
use crate::util::clean;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A choice retains its exact label for the answer, separate from its explanation.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionOption {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default)]
    pub recommended: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuestionForm {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<QuestionOption>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub multi_select: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggested_answer: Option<String>,
}

pub struct ReportedQuestion {
    pub text: String,
    pub form: QuestionForm,
}

fn optional_text(value: &Value, field: &str) -> Result<Option<String>> {
    match value.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(clean(text)),
        _ => Err(Error::invalid(format!("Question {field} must be text"))),
    }
}

impl ReportedQuestion {
    pub fn plain(text: String) -> Self {
        Self {
            text,
            form: QuestionForm::default(),
        }
    }

    pub fn parse(value: &Value) -> Result<Self> {
        if let Value::String(text) = value {
            return clean(text)
                .map(Self::plain)
                .ok_or_else(|| Error::invalid("Question text is empty"));
        }
        if !value.is_object() {
            return Err(Error::invalid(
                "A question must be text or an object with text",
            ));
        }
        let text = optional_text(value, "text")?
            .ok_or_else(|| Error::invalid("Question text is empty"))?;
        let multi_select = match value.get("multiSelect") {
            None => false,
            Some(Value::Bool(multiple)) => *multiple,
            _ => return Err(Error::invalid("Question multiSelect must be true or false")),
        };
        let mut options = Vec::new();
        match value.get("options") {
            None => {}
            Some(Value::Array(values)) => {
                for option in values {
                    let (label, description) = match option {
                        Value::String(text) => (clean(text), None),
                        Value::Object(_) => (
                            optional_text(option, "label")?,
                            optional_text(option, "description")?,
                        ),
                        _ => return Err(Error::invalid("Question options must have a label")),
                    };
                    let label =
                        label.ok_or_else(|| Error::invalid("Question option label is empty"))?;
                    if options
                        .iter()
                        .any(|previous: &QuestionOption| previous.label == label)
                    {
                        return Err(Error::invalid("Question option labels must be distinct"));
                    }
                    let recommended = match option.get("recommended") {
                        None => {
                            gitrochi_autocontinue::is_recommended(&label)
                                || description
                                    .as_deref()
                                    .is_some_and(gitrochi_autocontinue::is_recommended)
                        }
                        Some(Value::Bool(flag)) => *flag,
                        _ => {
                            return Err(Error::invalid(
                                "Question recommended must be true or false",
                            ))
                        }
                    };
                    options.push(QuestionOption {
                        label,
                        description,
                        recommended,
                    });
                }
            }
            _ => return Err(Error::invalid("Question options must be an array")),
        }
        Ok(Self {
            text,
            form: QuestionForm {
                options,
                multi_select,
                suggested_answer: optional_text(value, "suggestedAnswer")?,
            },
        })
    }
}

/// Existing text lists remain valid; structured entries are validated before the report commits.
pub fn list(value: &Value) -> Result<Vec<ReportedQuestion>> {
    match value {
        Value::Null => Ok(Vec::new()),
        Value::String(text) => Ok(clean(text)
            .map(ReportedQuestion::plain)
            .into_iter()
            .collect()),
        Value::Object(_) => Ok(vec![ReportedQuestion::parse(value)?]),
        Value::Array(items) => items
            .iter()
            .filter(|v| !matches!(v, Value::String(s) if clean(s).is_none()))
            .map(|value| {
                if let Value::Number(number) = value {
                    Ok(ReportedQuestion::plain(number.to_string()))
                } else {
                    ReportedQuestion::parse(value)
                }
            })
            .collect(),
        _ => Err(Error::invalid(
            "Questions must be text, a question object, or an array",
        )),
    }
}
