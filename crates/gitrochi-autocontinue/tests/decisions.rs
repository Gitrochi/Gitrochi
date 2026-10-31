//! Decisions, counting, replies, answer picking and the policy file.

use gitrochi_autocontinue::{
    app_alive, compose_answer_note, compose_plan_note, compose_reply, decide, detect_language,
    is_person_prompt, is_recommended, pick_answers, reply_language, risky, should_wait, Answer,
    Decision, HookInput, Lang, Language, Pass, PermissionContext, Policy, PromptKind, Rule,
    SessionState, Triggers, REPLY_TAG,
};
use serde_json::{json, Value};

fn on() -> Policy {
    Policy {
        enabled: true,
        ..Policy::default()
    }
}

fn ctx(input: &HookInput, policy: &Policy) -> PermissionContext {
    let mut c = PermissionContext::new(input, policy, "/Users/me/work/app", "/Users/me");
    c.current_branch = Some("feature/x".into());
    c
}

fn input(value: Value) -> HookInput {
    HookInput::from_value(&value)
}

fn stop(message: &str) -> HookInput {
    input(
        json!({"hook_event_name": "Stop", "cwd": "/Users/me/work/app", "last_assistant_message": message}),
    )
}

fn run(input: &HookInput, policy: &Policy, consecutive: u32, app: bool) -> Decision {
    decide(
        input,
        policy,
        SessionState { consecutive },
        &ctx(input, policy),
        app,
    )
}

fn pass(decision: &Decision) -> &Pass {
    match decision {
        Decision::Pass(p) => p,
        Decision::Wait(w) => panic!("expected a pass, got a wait for {:?}", w.kind),
    }
}

#[test]
fn nothing_happens_until_turned_on() {
    let q = stop("Should I go on?");
    assert_eq!(pass(&run(&q, &Policy::default(), 0, true)), &Pass::Disabled);
    assert!(matches!(run(&q, &on(), 0, true), Decision::Wait(_)));
    let mut off = on();
    off.triggers.stop_question = false;
    assert_eq!(
        pass(&run(&q, &off, 0, true)),
        &Pass::TriggerOff {
            kind: PromptKind::StopQuestion
        }
    );
}

#[test]
fn the_count_limits_answers_in_a_row() {
    let q = stop("Should I go on?");
    let policy = on();
    let mut state = SessionState::default();
    for n in 1..=3 {
        let Decision::Wait(wait) = decide(&q, &policy, state, &ctx(&q, &policy), true) else {
            panic!("answer {n} is sent");
        };
        assert_eq!(wait.reply.consecutive, n);
        state = state.after_auto_reply();
    }
    assert_eq!(state.consecutive, 3);
    assert_eq!(
        pass(&decide(&q, &policy, state, &ctx(&q, &policy), true)),
        &Pass::LimitReached {
            consecutive: 3,
            max: 3
        }
    );
    // the person's own prompt starts the count again; an automatic one does not
    assert_eq!(
        state.after_prompt("<task-notification>done</task-notification>"),
        state
    );
    assert_eq!(
        state.after_prompt(&format!("{REPLY_TAG} Auto-continue — Question: x")),
        state
    );
    assert_eq!(state.after_prompt("2번으로 해 줘").consecutive, 0);
    assert_eq!(state.after_person().consecutive, 0);
    // every kind counts, permissions included, and stops at the limit (design §9.4)
    let perm = input(
        json!({"hook_event_name": "PermissionRequest", "cwd": "/Users/me/work/app", "tool_name": "Bash", "tool_input": {"command": "npm test"}}),
    );
    assert_eq!(
        pass(&run(&perm, &policy, 3, true)),
        &Pass::LimitReached {
            consecutive: 3,
            max: 3
        }
    );
    let Decision::Wait(wait) = run(&perm, &policy, 1, true) else {
        panic!("a permission under the limit waits");
    };
    assert_eq!(wait.reply.consecutive, 2);
    assert_eq!(SessionState::default().after_auto_reply().consecutive, 1);
    let mut zero = on();
    zero.max_consecutive = 0;
    assert!(matches!(
        pass(&run(&q, &zero, 0, true)),
        Pass::LimitReached { .. }
    ));
}

#[test]
fn a_stop_hook_already_continuing_is_left_alone_unless_it_is_ours() {
    let q = input(
        json!({"hook_event_name": "Stop", "stop_hook_active": true, "last_assistant_message": "Should I go on?"}),
    );
    assert_eq!(pass(&run(&q, &on(), 0, true)), &Pass::StopHookActive);
    assert!(matches!(run(&q, &on(), 1, true), Decision::Wait(_)));
    // a string "true" counts too
    let q = input(
        json!({"hook_event_name": "Stop", "stop_hook_active": "true", "last_assistant_message": "Should I go on?"}),
    );
    assert!(q.stop_hook_active);
}

#[test]
fn risky_questions_and_choices_wait_for_the_person() {
    for message in [
        "Should I force push the rewritten history?",
        "Ready. Should I merge into main now?",
        "배포까지 진행할까요?",
        "Should I rotate the API key in the settings?",
        "이 브랜치를 main에 머지할까요?",
    ] {
        assert!(
            matches!(
                pass(&run(&stop(message), &on(), 0, true)),
                Pass::Risky { .. }
            ),
            "{message}"
        );
    }
    let ask = input(json!({
        "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
        "tool_input": {"questions": [{"question": "How to finish?", "header": "Finish", "multiSelect": false,
            "options": [{"label": "Deploy to production (Recommended)", "description": "Ship it"}, {"label": "Stop here", "description": ""}]}]}
    }));
    assert!(matches!(
        pass(&run(&ask, &on(), 0, true)),
        Pass::Risky {
            kind: PromptKind::AskUserQuestion,
            ..
        }
    ));
    // a configured protected branch counts too
    let mut policy = on();
    policy.protected_branches = vec!["develop".into()];
    assert!(matches!(
        pass(&run(&stop("Should I push to develop?"), &policy, 0, true)),
        Pass::Risky { .. }
    ));
    assert_eq!(risky("Should I update the tokenizer tokens?", &[]), None);
    assert_eq!(risky("Take the Windows paths into account?", &[]), None);
    assert_eq!(
        risky("Push to main?", &["main".into()]),
        Some("protected-branch")
    );
}

#[test]
fn synchronous_hooks_need_the_app() {
    assert!(should_wait(PromptKind::StopQuestion, false));
    assert!(!should_wait(PromptKind::AskUserQuestion, false));
    assert!(!should_wait(PromptKind::Permission, false));
    assert!(should_wait(PromptKind::Permission, true));
    let perm = input(
        json!({"hook_event_name": "PermissionRequest", "cwd": "/Users/me/work/app", "tool_name": "Bash", "tool_input": {"command": "npm test"}}),
    );
    assert_eq!(
        pass(&run(&perm, &on(), 0, false)),
        &Pass::AppClosed {
            kind: PromptKind::Permission
        }
    );
    assert!(app_alive(Some(100), 105));
    assert!(app_alive(Some(100), 114));
    assert!(!app_alive(Some(100), 115));
    assert!(app_alive(Some(101), 100));
    assert!(!app_alive(Some(130), 100));
    assert!(!app_alive(None, 100));
}

#[test]
fn held_permissions_pass_with_their_rule() {
    let perm = input(
        json!({"hook_event_name": "PermissionRequest", "cwd": "/Users/me/work/app", "tool_name": "Bash", "tool_input": {"command": "git push origin main"}}),
    );
    let decision = run(&perm, &on(), 0, true);
    let Pass::Held { rule, detail } = pass(&decision) else {
        panic!("held");
    };
    assert_eq!(*rule, Rule::ProtectedBranchPush);
    assert!(detail.contains("main"));
    assert!(pass(&run(&perm, &on(), 0, true))
        .message()
        .starts_with("held by protected-branch-push"));
}

#[test]
fn other_events_and_tools_pass_through() {
    let other = input(
        json!({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"}}),
    );
    assert_eq!(
        pass(&run(&other, &on(), 0, true)),
        &Pass::NotHandled {
            event: "PreToolUse".into(),
            tool: "Bash".into()
        }
    );
    let notification = input(json!({"hook_event_name": "Notification", "message": "x"}));
    assert!(matches!(
        pass(&run(&notification, &on(), 0, true)),
        Pass::NotHandled { .. }
    ));
    let empty = input(
        json!({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": {"questions": []}}),
    );
    assert_eq!(pass(&run(&empty, &on(), 0, true)), &Pass::NoAnswer);
    assert_eq!(pass(&run(&stop(""), &on(), 0, true)), &Pass::NotAQuestion);
}

#[test]
fn input_is_read_leniently() {
    let i = HookInput::parse(r#"{"hook_event_name": "Stop", "cwd": 5, "stop_hook_active": null, "extra": [1, 2], "agent_id": ""}"#).unwrap();
    assert_eq!(i.cwd, "");
    assert!(!i.stop_hook_active);
    assert_eq!(i.agent_id, None);
    assert!(HookInput::parse("[]").unwrap().hook_event_name.is_empty());
    assert!(HookInput::parse("{").is_err());
    let i = HookInput::parse(r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"scratchpad_dir":"/private/tmp/s"}"#).unwrap();
    assert_eq!(i.tool_input["command"], "ls");
    assert_eq!(i.scratchpad_dir.as_deref(), Some("/private/tmp/s"));
}

#[test]
fn scheduled_and_relayed_prompts_are_not_the_person() {
    assert!(is_person_prompt("continue with option 2"));
    assert!(is_person_prompt("<b>bold</b> is fine"));
    assert!(!is_person_prompt(""));
    assert!(!is_person_prompt("   "));
    assert!(!is_person_prompt(
        "<cross-session-message from=\"a\">hi</cross-session-message>"
    ));
    assert!(!is_person_prompt(
        "<scheduled-task id=\"1\">\ncheck the build\n</scheduled-task>\n"
    ));
    assert!(is_person_prompt(
        "<pasted_content id=\"1\">\nlog\n</pasted_content id=\"1\">"
    ));
    assert!(!is_person_prompt("[Gitrochi] 자동 진행 — 질문: x"));
}

#[test]
fn recommended_marks_in_several_languages() {
    for label in [
        "React (Recommended)",
        "(추천) A",
        "B (권장)",
        "C（推奨）",
        "D (推荐)",
        "E [recommended]",
        "F (Recommended: fastest)",
        "G【おすすめ】",
    ] {
        assert!(is_recommended(label), "{label}");
    }
    for label in ["Recommended reading", "A", "Not (yet) recommended", "(new)"] {
        assert!(!is_recommended(label), "{label}");
    }
}

#[test]
fn answers_take_the_recommended_option_else_the_first() {
    let questions = json!({"questions": [
        {"question": "Q1", "header": "a", "multiSelect": false, "options": [{"label": "A", "description": ""}, {"label": "B (Recommended)", "description": ""}]},
        {"question": "Q2", "header": "b", "multiSelect": false, "options": [{"label": "X", "description": ""}, {"label": "Y", "description": ""}]},
        {"question": "Q3", "header": "c", "multiSelect": true, "options": [{"label": "M (추천)", "description": ""}, {"label": "N", "description": ""}, {"label": "O (추천)", "description": ""}]},
        {"question": "Q4", "header": "d", "multiSelect": true, "options": [{"label": "P", "description": ""}, {"label": "R", "description": ""}]},
        {"question": "Q5", "header": "e", "options": [{"label": "S", "description": "the safe one (Recommended)"}, {"label": "T", "description": ""}]}
    ], "metadata": {"source": "x"}});
    let picked = pick_answers(&questions).unwrap();
    let got: Vec<(&str, &str, bool)> = picked
        .answers
        .iter()
        .map(|a| (a.question.as_str(), a.answer.as_str(), a.recommended))
        .collect();
    assert_eq!(
        got,
        [
            ("Q1", "B (Recommended)", true),
            ("Q2", "X", false),
            ("Q3", "M (추천), O (추천)", true),
            ("Q4", "P", false),
            ("Q5", "S", true),
        ]
    );
    // the input is echoed with every other field and the answers added
    assert_eq!(picked.updated_input["questions"], questions["questions"]);
    assert_eq!(picked.updated_input["metadata"], questions["metadata"]);
    assert_eq!(picked.updated_input["answers"]["Q3"], "M (추천), O (추천)");

    // nothing to pick from, or answers that cannot be keyed
    assert!(pick_answers(&json!({})).is_none());
    assert!(pick_answers(&json!({"questions": [{"question": "Q", "options": []}]})).is_none());
    assert!(
        pick_answers(&json!({"questions": [{"question": "", "options": [{"label": "A"}]}]}))
            .is_none()
    );
    assert!(pick_answers(&json!({"questions": [
        {"question": "Same", "options": [{"label": "A"}]},
        {"question": "Same", "options": [{"label": "B"}]}
    ]}))
    .is_none());
    // plain strings as options are tolerated
    let p =
        pick_answers(&json!({"questions": [{"question": "Q", "options": ["A", "B"]}]})).unwrap();
    assert_eq!(p.answers[0].answer, "A");
}

#[test]
fn replies_follow_the_question_language_and_delay() {
    assert_eq!(
        detect_language("Should I update the README for 로그인 flow?"),
        Lang::En
    );
    assert_eq!(detect_language("README를 업데이트할까요?"), Lang::Ko);
    assert_eq!(detect_language("どちらの方法で進めますか？"), Lang::Ja);
    assert_eq!(detect_language("変更を適用しますか"), Lang::Ja);
    assert_eq!(detect_language("你希望用哪种方案？"), Lang::Zh);
    assert_eq!(
        detect_language("`로그인` 함수를 Should I rename?"),
        Lang::En
    );
    assert_eq!(detect_language("Wie soll ich weitermachen?"), Lang::En);
    assert_eq!(detect_language(""), Lang::En);

    let mut policy = on();
    policy.delay_sec = 45;
    let ko = compose_reply("어떻게 할까요?", Lang::Ko, &policy);
    assert_eq!(
        ko.lines().next().unwrap(),
        "[Gitrochi] 자동 진행 — 질문: 어떻게 할까요?"
    );
    assert!(
        ko.contains("45초 동안 답이 없어 자동으로 진행합니다. 당신이 추천한 안으로 진행하세요.")
    );
    assert!(ko.contains("되돌리기 어려운 작업(데이터 삭제, force push, main/보호 브랜치 push, 배포, 자격 증명·계정 설정 변경)은 하지 말고 멈춰서 다시 물어보세요."));
    let en = compose_reply("Which one?", Lang::En, &policy);
    assert!(
        en.starts_with("[Gitrochi] Auto-continue — Question: Which one?\nNo answer for 45 seconds")
    );
    let ja = compose_reply("どちら？", Lang::Ja, &policy);
    assert!(ja.contains("45秒間回答がなかったため"));
    let zh = compose_reply("哪个？", Lang::Zh, &policy);
    assert!(zh.contains("45 秒内没有回复"));

    // the delay always lands in range
    policy.delay_sec = 3;
    assert!(compose_reply("x", Lang::En, &policy).contains("for 10 seconds"));
    policy.delay_sec = 900;
    assert!(compose_reply("x", Lang::En, &policy).contains("for 300 seconds"));

    // a fixed language wins over the question's
    policy.language = Language::Ja;
    assert_eq!(reply_language("Should I?", &policy), Lang::Ja);
    policy.language = Language::Auto;
    assert_eq!(reply_language("진행할까요?", &policy), Lang::Ko);

    // the template replaces the guidance, not the first line
    policy.delay_sec = 30;
    policy.template = Some("Wait {seconds}s passed on \"{question}\"; pick the safest.".into());
    let custom = compose_reply("Ship it?", Lang::En, &policy);
    assert_eq!(
        custom,
        "[Gitrochi] Auto-continue — Question: Ship it?\nWait 30s passed on \"Ship it?\"; pick the safest."
    );

    let answers = [Answer {
        question: "Which storage?".into(),
        answer: "SQLite (Recommended)".into(),
        recommended: true,
    }];
    let note = compose_answer_note(&answers, Lang::En, &on());
    assert!(note.starts_with(
        "[Gitrochi] Auto-continue — Chosen answer: Which storage? → SQLite (Recommended)\n"
    ));
    assert!(compose_plan_note(Lang::Ko, &on())
        .starts_with("[Gitrochi] 자동 진행 — 계획을 승인했습니다.\n30초"));
}

#[test]
fn the_policy_file_is_camel_case_and_clamped() {
    let p = Policy::from_json(r#"{"enabled": true, "delaySec": 5, "maxConsecutive": 99,
        "triggers": {"exitPlanMode": true}, "extraDeny": [" Bash(make ship) ", "", "Bash(make ship)"],
        "protectedBranches": ["develop", " "], "template": "  ", "language": "ko", "unknown": 1}"#)
    .unwrap();
    assert!(p.enabled);
    assert_eq!(p.delay_sec, 10);
    assert_eq!(p.max_consecutive, 20);
    assert_eq!(
        p.triggers,
        Triggers {
            exit_plan_mode: true,
            ..Triggers::default()
        }
    );
    assert!(p.triggers.stop_question && p.triggers.permission && p.triggers.ask_user_question);
    assert_eq!(p.extra_deny, ["Bash(make ship)"]);
    assert_eq!(p.protected(), ["main", "master", "develop"]);
    assert_eq!(p.template, None);
    assert_eq!(p.language, Language::Ko);
    assert_eq!(p.hook_timeout(), 20);

    let defaults = Policy::from_json("{}").unwrap();
    assert_eq!(defaults, Policy::default());
    assert!(!defaults.enabled);
    assert_eq!((defaults.delay(), defaults.max_consecutive), (30, 3));
    assert!(!defaults.triggers.exit_plan_mode);

    let round: Value = serde_json::to_value(Policy::default()).unwrap();
    assert_eq!(
        round,
        json!({"enabled": false, "delaySec": 30, "maxConsecutive": 3,
            "triggers": {"stopQuestion": true, "askUserQuestion": true, "exitPlanMode": false, "permission": true},
            "extraDeny": [], "protectedBranches": [], "allowMcp": [], "template": null, "language": "auto"})
    );
    assert!(Policy::from_json(r#"{"delaySec": "thirty"}"#).is_err());
}

#[test]
fn records_carry_a_schema_version_and_snake_case_kinds() {
    let q = stop("Should I go on?");
    let Decision::Wait(wait) = run(&q, &on(), 0, true) else {
        panic!("waits");
    };
    let payload = serde_json::to_value(&wait.payload).unwrap();
    assert_eq!(payload["schemaVersion"], 1);
    assert_eq!(payload["kind"], "stop_question");
    assert_eq!(payload["proposed"]["type"], "reply");
    let reply = serde_json::to_value(&wait.reply).unwrap();
    assert_eq!(reply["rule"], "question:en:should i");
    assert_eq!(reply["sent"], payload["proposed"]);
    // both read back
    let back: gitrochi_autocontinue::PromptPayload = serde_json::from_value(payload).unwrap();
    assert_eq!(back, wait.payload);
    for (kind, name) in [
        (PromptKind::StopQuestion, "stop_question"),
        (PromptKind::AskUserQuestion, "ask_user_question"),
        (PromptKind::ExitPlanMode, "exit_plan_mode"),
        (PromptKind::Permission, "permission"),
    ] {
        assert_eq!(serde_json::to_value(kind).unwrap(), json!(name));
        assert_eq!(kind.as_str(), name);
    }
}
