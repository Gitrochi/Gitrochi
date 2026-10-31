//! The text Gitrochi sends to the agent. It is read by the agent, not shown as UI, so it
//! lives here as constants rather than in the apps' localization files; it follows the
//! language of the question (Korean, English, Japanese or Chinese, else English).

use crate::answers::Answer;
use crate::policy::{Language, Policy};
use crate::text::one_line;
use serde::{Deserialize, Serialize};

/// Starts every reply, so the agent knows who answered and a later prompt that quotes the
/// reply is not taken for the person's input.
pub const REPLY_TAG: &str = "[Gitrochi]";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lang {
    Ko,
    En,
    Ja,
    Zh,
}

struct Texts {
    auto: &'static str,
    question: &'static str,
    answered: &'static str,
    plan: &'static str,
    /// `{seconds}` is the real delay.
    guidance: &'static str,
}

const KO: Texts = Texts {
    auto: "자동 진행",
    question: "질문",
    answered: "고른 답",
    plan: "계획을 승인했습니다.",
    guidance: "{seconds}초 동안 답이 없어 자동으로 진행합니다. 당신이 추천한 안으로 진행하세요. 추천이 없었다면 되돌리기 쉬운 안을 고르세요. 되돌리기 어려운 작업(데이터 삭제, force push, main/보호 브랜치 push, 배포, 자격 증명·계정 설정 변경)은 하지 말고 멈춰서 다시 물어보세요. 고른 가정은 마지막 요약에 적으세요.",
};

const EN: Texts = Texts {
    auto: "Auto-continue",
    question: "Question",
    answered: "Chosen answer",
    plan: "The plan was approved.",
    // the wording of docs/ledger/DESIGN.md §9.2
    guidance: "No answer for {seconds} seconds, so this continues automatically. Go ahead with the option you recommended; if you recommended none, choose the one that is easiest to undo. Do not do anything hard to undo (deleting data, force-pushing, pushing to the main or a protected branch, deploying, changing credentials or account settings); stop and ask again instead. List the assumptions you made in your final summary.",
};

const JA: Texts = Texts {
    auto: "自動で続行",
    question: "質問",
    answered: "選んだ回答",
    plan: "計画を承認しました。",
    guidance: "{seconds}秒間回答がなかったため、自動で続行します。あなたが推奨した案で進めてください。推奨がなかった場合は、元に戻しやすい案を選んでください。元に戻しにくい作業（データの削除、force push、main や保護ブランチへの push、デプロイ、認証情報・アカウント設定の変更）は行わず、止まってもう一度質問してください。選んだ前提は最後の要約に書いてください。",
};

const ZH: Texts = Texts {
    auto: "自动继续",
    question: "问题",
    answered: "选择的答案",
    plan: "计划已批准。",
    guidance: "{seconds} 秒内没有回复，因此自动继续。请按你推荐的方案进行。如果没有推荐，请选择最容易撤销的方案。不要执行难以撤销的操作（删除数据、force push、推送到 main 或受保护分支、部署、更改凭据或账户设置），而是停下来再次询问。请在最后的总结中写明你所做的假设。",
};

fn texts(lang: Lang) -> &'static Texts {
    match lang {
        Lang::Ko => &KO,
        Lang::En => &EN,
        Lang::Ja => &JA,
        Lang::Zh => &ZH,
    }
}

/// The script most of the text is written in. Inline code and links are left out, and a
/// Latin word weighs about as much as two Hangul, kana or Han characters.
pub fn detect_language(text: &str) -> Lang {
    let mut latin_words = 0usize;
    let mut in_word = false;
    let (mut hangul, mut kana, mut han) = (0usize, 0usize, 0usize);
    let mut in_code = false;
    for c in text.chars() {
        if c == '`' {
            in_code = !in_code;
            in_word = false;
            continue;
        }
        if in_code {
            continue;
        }
        match c {
            '\u{AC00}'..='\u{D7A3}' | '\u{1100}'..='\u{11FF}' | '\u{3130}'..='\u{318F}' => {
                hangul += 1
            }
            '\u{3040}'..='\u{30FF}' => kana += 1,
            '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}' => han += 1,
            _ => {}
        }
        if c.is_ascii_alphabetic() {
            if !in_word {
                latin_words += 1;
            }
            in_word = true;
        } else {
            in_word = false;
        }
    }
    let cjk = hangul + kana + han;
    if cjk == 0 || cjk < latin_words * 2 {
        return Lang::En;
    }
    if hangul >= kana + han {
        Lang::Ko
    } else if kana > 0 {
        Lang::Ja
    } else {
        Lang::Zh
    }
}

/// The policy's language, or the question's when it is `auto`.
pub fn reply_language(question: &str, policy: &Policy) -> Lang {
    match policy.language {
        Language::Auto => detect_language(question),
        Language::Ko => Lang::Ko,
        Language::En => Lang::En,
        Language::Ja => Lang::Ja,
        Language::Zh => Lang::Zh,
    }
}

fn guidance(lang: Lang, policy: &Policy, question: &str) -> String {
    let template = policy.template.as_deref().unwrap_or(texts(lang).guidance);
    template
        .replace("{seconds}", &policy.delay().to_string())
        .replace("{question}", question)
}

/// The reply to a turn that ended with a question: its one-line summary, then the guidance.
pub fn compose_reply(question: &str, lang: Lang, policy: &Policy) -> String {
    let t = texts(lang);
    let summary = one_line(question, 160);
    format!(
        "{REPLY_TAG} {} — {}: {summary}\n{}",
        t.auto,
        t.question,
        guidance(lang, policy, &summary)
    )
}

/// The note that goes with automatic `AskUserQuestion` answers.
pub fn compose_answer_note(answers: &[Answer], lang: Lang, policy: &Policy) -> String {
    let t = texts(lang);
    let chosen = answers
        .iter()
        .map(|a| format!("{} → {}", one_line(&a.question, 120), a.answer))
        .collect::<Vec<_>>()
        .join("; ");
    format!(
        "{REPLY_TAG} {} — {}: {chosen}\n{}",
        t.auto,
        t.answered,
        guidance(lang, policy, &chosen)
    )
}

/// The note that goes with an automatic plan approval.
pub fn compose_plan_note(lang: Lang, policy: &Policy) -> String {
    let t = texts(lang);
    format!(
        "{REPLY_TAG} {} — {}\n{}",
        t.auto,
        t.plan,
        guidance(lang, policy, t.plan)
    )
}
