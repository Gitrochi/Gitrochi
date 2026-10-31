//! Whether a turn ended by asking the person something.

use gitrochi_autocontinue::classify_stop;

/// Turns that end by asking the person to decide.
const QUESTIONS: &[&str] = &[
    // Korean
    "테스트를 모두 통과했습니다.\n\n이대로 PR을 열까요?",
    "두 가지 방법이 있습니다.\n\n1. 캐시를 지우고 다시 빌드\n2. 의존성만 업데이트\n\n어떻게 할까요?",
    "어느 방식으로 진행할까요? 저는 1번을 추천합니다.",
    "원하시면 README에도 사용법을 추가하겠습니다.",
    "변경 사항을 커밋해도 될까요?",
    "다음 중 하나를 선택해 주세요:\n- A안: 기존 API 유지\n- B안: 새 API로 교체 (추천)",
    "마이그레이션 스크립트를 지금 실행할지 알려 주세요.",
    "이 함수 이름을 `parseRef`로 바꾸는 게 괜찮을까요?",
    "확인해 주시면 다음 단계로 넘어가겠습니다.",
    "Windows 쪽도 같이 고칠까요, 아니면 macOS만 먼저 할까요?",
    "테스트를 더 추가하시겠습니까?",
    "필요하시면 벤치마크도 돌려 보겠습니다.",
    "A와 B 중 어느 쪽이 좋을까요?",
    "현재 브랜치에서 계속 작업할까요",
    "질문이 있습니다: 기존 설정 파일을 자동으로 옮길까요?",
    "구현은 끝났습니다.\n\n남은 일은 문서뿐인데, 문서도 지금 정리할까요?",
    "**이 방향으로 계속 진행해도 괜찮을까요?**",
    // English
    "Should I go ahead and open the pull request?",
    "I found two ways to fix this:\n\n1. Patch the parser\n2. Rewrite the tokenizer (Recommended)\n\nWhich one do you prefer?",
    "Do you want me to update the Windows side as well?",
    "Would you like me to add a migration for existing settings?",
    "Let me know which option you'd like.",
    "Want me to also add tests for the edge cases?",
    "Shall I proceed with the rename?",
    "If you'd like, I can also add a changelog entry.",
    "The fix is ready. Commit it now?",
    "Please confirm before I run the migration.",
    "Option A keeps the old API; option B replaces it. Which would you prefer?",
    "I can split this into two commits if you want.",
    "Let me know if you want me to push the branch.",
    "Is it okay to bump the dependency to 2.0?",
    "**Should I continue with the Windows implementation?**",
    "I'll wait for your confirmation before running the full test suite.",
    "Ready to merge the two helpers into one file. Go ahead?",
    "Summary of changes:\n- Added the parser\n- Fixed the tests\n\nShould I also update the docs?",
    "The build passes. Do you prefer a single squashed commit or separate commits?",
    "Should I open the PR? Let me know if you have any questions.",
    "Open questions:\n- Should the cache survive restarts?\n- Should we keep the old flag?",
    // Japanese
    "どちらの方法で進めますか？",
    "このまま続けてもよろしいでしょうか？",
    "テストも追加しましょうか？",
    // Chinese
    "要继续实现 Windows 部分吗？",
    "你希望用哪种方案？",
    "请确认是否需要更新文档。",
];

/// Reports, closings and statements: nothing to decide.
const NOT_QUESTIONS: &[&str] = &[
    "",
    "모든 테스트를 통과했습니다. 변경 사항은 `src/lib.rs`에 있습니다.",
    "구현을 마쳤습니다.\n\n- 파서 추가\n- 테스트 12개 추가",
    "궁금한 점이 있으면 말씀해 주세요.",
    "커밋하고 push까지 끝냈습니다. PR은 #12입니다.",
    "이 PR은 다음을 해결합니다: 로그인 오류, 느린 검색.",
    "작업을 완료했습니다. 문제가 있으면 알려 주세요.",
    "다음으로 Windows 쪽을 고치겠습니다.",
    "변경 내용은 다음과 같습니다:\n1. A\n2. B",
    "이제 빌드가 됩니다. 다른 도움이 필요하시면 말씀해 주세요.",
    "1. 파서 수정\n2. 테스트 추가\n\n모두 완료했습니다.",
    "README의 \"어떻게 할까요?\" 문구를 고쳤습니다.",
    "원하시면 `npm test`로 직접 확인해 보세요.",
    "이제 에러가 안 나요.",
    "원하시는 대로 진행했습니다.",
    "Done. All 42 tests pass.",
    "I've updated the parser and added tests. Let me know if you have any questions!",
    "Why did the test fail? The fixture was stale, so I regenerated it. Everything passes now.",
    "Here's what I changed:\n\n1. Added the parser\n2. Fixed the tests",
    "The build succeeded, which means the cache is warm.",
    "I fixed the bug. Hope this helps!",
    "```\nShould I ignore this?\n```\nThe code above is the old prompt; I removed it.",
    "Let me know if you run into any issues.",
    "The question was whether to keep the flag; I kept it because tests depend on it.",
    "I asked myself: should we cache this? No — the data changes too often, so I left it uncached.",
    "Next, I'll update the Windows side.",
    "Would you believe it, the bug was a missing semicolon.",
    "If you want to try it, run `npm test`.",
    "Should you need more details, the README has them.",
    "Let me know what you think.",
    "Let me know if you'd like any changes.",
    "Tests pass on both platforms. Feel free to review when you have time.",
    "I opened the PR. Anything else?",
    "Is there anything else you'd like me to do?",
    "I wondered whether I should implement caching, and decided it was not worth it.",
    "Pushed to `feature/x`. CI is green.",
    "変更をコミットしました。何かあればお知らせください。",
    "どうしてテストが失敗したのか調べました。原因はキャッシュでした。",
    "修复已完成，所有测试都通过了。如有任何问题，请告诉我。",
    "为什么会失败？因为缓存过期了。现在已经修复。",
];

#[test]
fn turns_that_ask_are_questions() {
    let missed: Vec<&str> = QUESTIONS
        .iter()
        .copied()
        .filter(|m| classify_stop(m).is_none())
        .collect();
    assert!(missed.is_empty(), "not seen as questions: {missed:#?}");
    assert!(QUESTIONS.len() >= 30);
}

#[test]
fn reports_and_closings_are_not_questions() {
    let wrong: Vec<(&str, String)> = NOT_QUESTIONS
        .iter()
        .filter_map(|m| classify_stop(m).map(|q| (*m, q.cue)))
        .collect();
    assert!(wrong.is_empty(), "taken for questions: {wrong:#?}");
    assert!(NOT_QUESTIONS.len() >= 30);
}

#[test]
fn the_cue_says_why() {
    let cue = |m: &str| classify_stop(m).unwrap().cue;
    assert_eq!(cue("Should I go ahead?"), "en:should i");
    assert_eq!(cue("진행할까요?"), "ko:까요");
    assert_eq!(cue("I can add tests if you want."), "offer");
    assert_eq!(cue("Merge now?"), "question-mark");
    assert_eq!(cue("要继续吗"), "zh:吗");
    assert_eq!(cue("進めますか"), "ja:ますか");
}

#[test]
fn options_next_to_the_question_are_choices() {
    let q = classify_stop(
        "두 가지 방법이 있습니다.\n\n1. 캐시를 지우고 다시 빌드\n2. 의존성만 업데이트 (추천)\n\n어떻게 할까요?",
    )
    .unwrap();
    let labels: Vec<&str> = q.options.iter().map(|o| o.label.as_str()).collect();
    assert_eq!(
        labels,
        ["캐시를 지우고 다시 빌드", "의존성만 업데이트 (추천)"]
    );
    assert_eq!(
        q.options.iter().map(|o| o.recommended).collect::<Vec<_>>(),
        [false, true]
    );
    assert_eq!(
        q.summary,
        "어떻게 할까요? — 캐시를 지우고 다시 빌드 / 의존성만 업데이트 (추천)"
    );

    // a list of changes before an unrelated question is not a set of choices
    let q = classify_stop(
        "Changes:\n- Added the parser\n- Fixed the tests\n\nShould I also update the docs?",
    )
    .unwrap();
    assert!(q.options.is_empty());
    assert_eq!(q.summary, "Should I also update the docs?");

    // a list after the question is
    let q = classify_stop("다음 중 하나를 선택해 주세요:\n- A안\n- B안 (권장)").unwrap();
    assert_eq!(q.options.len(), 2);
    assert!(q.options[1].recommended);
}

#[test]
fn summaries_are_one_short_line() {
    let long = format!("Should I {}?", "really ".repeat(60));
    let q = classify_stop(&long).unwrap();
    assert!(q.summary.chars().count() <= 160);
    assert!(q.summary.ends_with('…'));
    assert!(!q.summary.contains('\n'));
    let q = classify_stop("**Should I** use `RepoStore`\nhere?").unwrap();
    assert_eq!(q.summary, "here?");
    let q = classify_stop("> **Should I use `RepoStore` here?**").unwrap();
    assert_eq!(q.summary, "Should I use RepoStore here?");
}
