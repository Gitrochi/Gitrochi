//! Validate human replies before closing a live wait; malformed replies must stay answerable.

use crate::error::{Error, Result};
use crate::util::clean;
use gitrochi_autocontinue::parse_questions;
use serde_json::{json, Map, Value};

fn text(value: &Value) -> Result<String> {
    value
        .as_str()
        .and_then(clean)
        .ok_or_else(|| Error::invalid("An answer must be nonempty text"))
}

fn keys(answer: &Map<String, Value>, allowed: &[&str]) -> Result<()> {
    if answer.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(Error::invalid("The answer contains an unsupported field"));
    }
    Ok(())
}

pub fn normalize(kind: &str, payload: &Value, answer: &Value) -> Result<Value> {
    let answer = answer
        .as_object()
        .ok_or_else(|| Error::invalid("answer must be an object"))?;
    for key in ["release", "hold"] {
        if answer.contains_key(key) {
            keys(answer, &[key])?;
            if answer[key] != true {
                return Err(Error::invalid("release and hold must be true"));
            }
            return Ok(json!({key: true}));
        }
    }
    if payload.get("hold").is_some_and(|hold| !hold.is_null()) {
        return Err(Error::invalid(
            "Answer this held prompt in the agent's terminal",
        ));
    }
    match kind {
        "stop_question" => {
            keys(answer, &["text"])?;
            Ok(json!({"text": text(answer.get("text").unwrap_or(&Value::Null))?}))
        }
        "ask_user_question" => {
            keys(answer, &["text", "answers"])?;
            let questions = parse_questions(payload);
            if questions.is_empty()
                || questions.iter().enumerate().any(|(i, q)| {
                    q.question.trim().is_empty()
                        || questions[..i]
                            .iter()
                            .any(|prior| prior.question == q.question)
                })
            {
                return Err(Error::invalid(
                    "The prompt has no unique questions to answer",
                ));
            }
            let chosen = if let Some(legacy) = answer.get("text") {
                if questions.len() != 1 || answer.contains_key("answers") {
                    return Err(Error::invalid("Answer each question separately"));
                }
                Map::from_iter([(questions[0].question.clone(), json!(text(legacy)?))])
            } else {
                answer
                    .get("answers")
                    .and_then(Value::as_object)
                    .cloned()
                    .ok_or_else(|| Error::invalid("Missing answers"))?
            };
            if chosen
                .keys()
                .any(|key| !questions.iter().any(|q| &q.question == key))
            {
                return Err(Error::invalid("The answer names an unknown question"));
            }
            let mut normalized = Map::new();
            for q in questions {
                let value = chosen
                    .get(&q.question)
                    .ok_or_else(|| Error::invalid("Answer every question before sending"))?;
                normalized.insert(q.question, json!(text(value)?));
            }
            Ok(json!({"answers": normalized}))
        }
        "permission" | "exit_plan_mode" => {
            keys(answer, &["decision", "message"])?;
            let decision = answer
                .get("decision")
                .and_then(Value::as_str)
                .filter(|decision| matches!(*decision, "allow" | "deny"))
                .ok_or_else(|| Error::invalid("decision must be allow or deny"))?;
            let mut normalized = json!({"decision": decision});
            if let Some(message) = answer.get("message") {
                normalized["message"] = json!(text(message)?);
            }
            Ok(normalized)
        }
        _ => Err(Error::invalid("Unknown prompt kind")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{prompts, tests::H, views::Range};

    #[test]
    fn structured_questions_accept_complete_custom_text_and_legacy_single_text() {
        let single = json!({"questions": [{"question": "Name?", "options": []}]});
        assert_eq!(
            normalize("ask_user_question", &single, &json!({"text": "  Cache  "})).unwrap(),
            json!({"answers": {"Name?": "Cache"}})
        );
        let multi = json!({"questions": [
            {"question": "Name?", "options": []},
            {"question": "Features?", "multiSelect": true, "options": [{"label": "A"}, {"label": "B"}]}
        ]});
        assert_eq!(
            normalize(
                "ask_user_question",
                &multi,
                &json!({"answers": {"Name?": "New name", "Features?": "A, B, custom detail"}})
            )
            .unwrap(),
            json!({"answers": {"Name?": "New name", "Features?": "A, B, custom detail"}})
        );
        for answer in [
            json!({}),
            json!({"text": "ambiguous"}),
            json!({"answers": {"Name?": "Cache"}}),
            json!({"answers": {"Name?": "Cache", "Features?": " "}}),
            json!({"answers": {"Name?": "Cache", "Features?": ["A", "B"]}}),
            json!({"answers": {"Name?": "Cache", "Features?": "A", "Unknown?": "B"}}),
            json!({"decision": "allow"}),
            json!({"release": false}),
            json!({"release": true, "answers": {"Name?": "Cache"}}),
        ] {
            assert!(
                normalize("ask_user_question", &multi, &answer).is_err(),
                "{answer}"
            );
        }
        assert_eq!(
            normalize("ask_user_question", &multi, &json!({"release": true})).unwrap(),
            json!({"release": true})
        );
        assert_eq!(
            normalize("ask_user_question", &multi, &json!({"hold": true})).unwrap(),
            json!({"hold": true})
        );
    }

    #[test]
    fn incompatible_permission_or_stop_answers_are_rejected() {
        assert!(normalize("permission", &json!({}), &json!({"text": "yes"})).is_err());
        assert!(normalize("permission", &json!({}), &json!({"decision": "maybe"})).is_err());
        assert!(normalize(
            "stop_question",
            &json!({}),
            &json!({"answers": {"Q": "yes"}})
        )
        .is_err());
        assert!(normalize("stop_question", &json!({}), &json!({"text": " "})).is_err());
        assert!(normalize(
            "permission",
            &json!({"hold": {"code": "held"}}),
            &json!({"decision": "allow"})
        )
        .is_err());
        assert_eq!(
            normalize(
                "exit_plan_mode",
                &json!({}),
                &json!({"decision": "deny", "message": "  Wait  "})
            )
            .unwrap(),
            json!({"decision": "deny", "message": "Wait"})
        );
    }

    #[test]
    fn invalid_answers_leave_the_prompt_and_revision_unchanged_and_late_answers_lose() {
        let h = H::new();
        let payload = json!({"questions": [{"question": "Name?", "options": []}, {"question": "Color?", "options": ["Blue"]}]});
        let (prompt, _) =
            h.db.write(|c| {
                prompts::create(
                    c,
                    &json!({"kind": "ask_user_question", "payload": payload}),
                    h.now(),
                )
            })
            .unwrap();
        let before = h.state(Range::All).rev;
        for answer in [
            json!({"text": "Cache"}),
            json!({"answers": {"Name?": "Cache"}}),
            json!({"answers": {"Name?": "Cache", "Color?": "Blue", "Other?": "x"}}),
        ] {
            assert!(h
                .db
                .write(|c| prompts::answer(c, &json!({"id": prompt.id, "answer": answer}), h.now()))
                .is_err());
            let unchanged = h.db.read(|c| prompts::get(c, prompt.id)).unwrap();
            assert_eq!(unchanged, prompt);
            assert_eq!(h.state(Range::All).rev, before);
        }
        h.db.write(|c| {
            prompts::resolve(c, &json!({"id": prompt.id, "state": "released"}), h.now())
        })
        .unwrap();
        let ((ok, late), _) = h.db.write(|c| prompts::answer(c,
            &json!({"id": prompt.id, "answer": {"answers": {"Name?": "Cache", "Color?": "Blue"}}}), h.now())).unwrap();
        assert!(!ok);
        assert_eq!(late.state, "released");
        assert!(late.answer.is_none());
    }

    #[test]
    fn a_human_answer_and_automatic_resolution_cannot_both_win() {
        let h = H::new();
        let now = h.now();
        let (prompt, _) =
            h.db.write(|c| {
                prompts::create(
                    c,
                    &json!({"kind": "stop_question", "payload": {"question": "Continue?"}}),
                    now,
                )
            })
            .unwrap();
        let barrier = std::sync::Barrier::new(3);
        let (human, automatic) = std::thread::scope(|scope| {
            let human = scope.spawn(|| {
                let db = crate::Db::open(&h.db.path).unwrap();
                barrier.wait();
                db.write(|c| {
                    prompts::answer(
                        c,
                        &json!({"id": prompt.id, "answer": {"text": "Human reply"}}),
                        now,
                    )
                })
                .unwrap()
                .0
                 .0
            });
            let automatic = scope.spawn(|| {
                let db = crate::Db::open(&h.db.path).unwrap();
                barrier.wait();
                db.write(|c| prompts::resolve(c, &json!({"id": prompt.id, "state": "auto", "answer": {"text": "Automatic reply"}}), now)).unwrap().0.0
            });
            barrier.wait();
            (human.join().unwrap(), automatic.join().unwrap())
        });
        assert_ne!(human, automatic);
        let stored = h.db.read(|c| prompts::get(c, prompt.id)).unwrap();
        assert_eq!(stored.state, if human { "answered" } else { "auto" });
        assert_eq!(
            stored.answer.unwrap()["text"],
            if human {
                "Human reply"
            } else {
                "Automatic reply"
            }
        );
    }
}
