//! Whether a turn ended by asking the person to decide something. Only the end of the
//! message counts, and a polite closing or a plain report is not a question: a missed
//! question costs the person a reply, a false one makes the agent carry on unasked.

use crate::answers::is_recommended;
use crate::text::{
    any_phrase, ends_with_question_mark, first_phrase, one_line, plain_line, sentences, trim_tail,
};

/// The question a turn ended with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StopQuestion {
    /// One line for the reply and the Inbox.
    pub summary: String,
    /// The paragraphs that ask, as plain text.
    pub text: String,
    /// A list of choices next to the question.
    pub options: Vec<Choice>,
    /// Which cue made it a question (`question-mark`, `en:should i` …), for the Ledger.
    pub cue: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub label: String,
    pub recommended: bool,
}

/// Phrases that ask for a decision even without a question mark.
const ASKS: &[&str] = &[
    "should i",
    "shall i",
    "should we",
    "shall we",
    "do you want",
    "would you like",
    "would you prefer",
    "do you prefer",
    "want me to",
    "would you rather",
    "let me know which",
    "let me know whether",
    "let me know if you want",
    "let me know if you'd like",
    "let me know if you would like",
    "let me know if you prefer",
    "let me know how you",
    "let me know what you'd like",
    "let me know what you would like",
    "please choose",
    "please pick",
    "please select",
    "please confirm",
    "please decide",
    "please let me know",
    "can you confirm",
    "could you confirm",
    "your confirmation",
    "your approval",
    "your go-ahead",
    "your decision",
    "your call",
    "up to you",
    // Korean
    "알려 주세요",
    "알려주세요",
    "알려 주시면",
    "알려주시면",
    "말씀해 주세요",
    "말씀해주세요",
    "말씀해 주시면",
    "말씀해주시면",
    "선택해 주세요",
    "선택해주세요",
    "선택해 주시면",
    "골라 주세요",
    "골라주세요",
    "정해 주세요",
    "정해주세요",
    "결정해 주세요",
    "결정해주세요",
    "확인해 주시면",
    "확인해주시면",
    "확인 부탁",
    "승인해 주시면",
    "승인해주시면",
    "검토해 주시면",
    "의견 주시면",
    "의견을 주시면",
    "답변 주시면",
    "어떻게 할지",
    "진행할지",
    "할지 말지",
    // Japanese
    "教えてください",
    "お知らせください",
    "選んでください",
    "ご指示ください",
    "ご確認ください",
    "ご判断ください",
    "ご希望",
    // Chinese
    "请选择",
    "请确认",
    "请告诉我",
    "请决定",
    "要不要",
    "是否需要",
    "是否要",
    "您希望",
    "你希望",
    "您想",
    "你想要",
    "需要我",
    "可以吗",
    "好吗",
];

/// Sentence endings that are questions on their own (Korean, Japanese, Chinese). Endings
/// that also close statements ("에러가 나요") need a question mark instead.
const QUESTION_ENDINGS: &[&str] = &[
    "까요",
    "습니까",
    "합니까",
    "됩니까",
    "입니까",
    "십니까",
    "는지요",
    "을지요",
    "실래요",
    "ますか",
    "ですか",
    "でしょうか",
    "ましょうか",
    "ませんか",
    "吗",
];

/// An offer needs both a condition ("if you want") and something the agent would do.
const OFFER_IF: &[&str] = &[
    "if you want",
    "if you'd like",
    "if you would like",
    "if you prefer",
    "if that helps",
    "if it helps",
    "if useful",
    "if needed",
    "if you need",
    "원하시면",
    "원하신다면",
    "필요하시면",
    "필요하다면",
    "괜찮으시면",
    "괜찮다면",
    "좋으시면",
    "よろしければ",
    "必要であれば",
    "必要なら",
    "ご希望であれば",
    "如果需要",
    "如果你需要",
    "如果您需要",
    "如需",
    "如果你愿意",
    "如果您愿意",
    "如果你想",
    "如果您想",
];
const OFFER_DO: &[&str] = &[
    "i can",
    "i could",
    "i'll",
    "i will",
    "i'd be happy",
    "happy to",
    "me to",
    "겠습니다",
    "게요",
    "께요",
    "수 있습니다",
    "수 있어요",
    "드릴",
    "겠어요",
    "します",
    "できます",
    "いたします",
    "しましょう",
    "我可以",
    "我来",
    "我会",
];

/// Polite closings and offers of general help: not a decision to make.
const CLOSINGS: &[&str] = &[
    "any questions",
    "any other questions",
    "any further questions",
    "more questions",
    "other questions",
    "any changes",
    "any adjustments",
    "any issues",
    "any problems",
    "any feedback",
    "anything else",
    "anything further",
    "need anything",
    "need more help",
    "need any help",
    "further help",
    "further assistance",
    "hope this helps",
    "hope that helps",
    "feel free",
    "happy to help",
    "glad to help",
    "make sense",
    "let me know what you think",
    "let me know your thoughts",
    "let me know if anything",
    "if you run into",
    "if you hit",
    "if anything",
    "if something",
    "궁금",
    "문의",
    "다른 도움",
    "추가 도움",
    "도움이 필요",
    "더 필요한",
    "추가로 필요한",
    "필요한 게 있으면",
    "필요한 것이 있으면",
    "문제가 있으면",
    "문제가 생기면",
    "이상이 있으면",
    "불편",
    "피드백",
    "질문이 있으시면",
    "다른 요청",
    "ご不明",
    "ご質問",
    "何かあれば",
    "他に何か",
    "お気軽に",
    "質問があれば",
    "問題があれば",
    "任何问题",
    "其他问题",
    "疑问",
    "随时",
    "还有什么",
    "还有其他",
    "如有问题",
];

/// A recommendation after the question ("I recommend 2.") keeps the question in view.
const RECOMMENDS: &[&str] = &[
    "recommend",
    "suggest",
    "i'd go with",
    "i would go with",
    "i'd pick",
    "my pick",
    "i lean",
    "추천",
    "권장",
    "제안",
    "개인적으로",
    "おすすめ",
    "推奨",
    "勧め",
    "推荐",
    "建议",
];

const SIGN_OFFS: &[&str] = &[
    "thanks",
    "thank you",
    "감사합니다",
    "고맙습니다",
    "ありがとうございます",
    "谢谢",
];

#[derive(Debug)]
enum Unit {
    Sentence(String),
    List(Vec<String>),
}

pub fn classify_stop(message: &str) -> Option<StopQuestion> {
    let paragraphs = paragraphs(message);
    // The last three paragraphs hold the question and its options, if there is one.
    let tail = &paragraphs[paragraphs.len().saturating_sub(3)..];
    let mut units = Vec::new();
    let mut texts = Vec::new();
    for paragraph in tail {
        let plain: Vec<String> = paragraph.iter().map(|line| plain_line(line)).collect();
        if let Some(items) = list_items(paragraph) {
            units.push(Unit::List(items));
        } else {
            units.extend(
                plain
                    .iter()
                    .flat_map(|line| sentences(line))
                    .map(Unit::Sentence),
            );
        }
        texts.push(plain.join("\n"));
    }

    let mut i = units.len();
    let mut skipped = 0;
    while i > 0 && skipped <= 3 {
        i -= 1;
        match &units[i] {
            Unit::List(items) => {
                // A list of questions is a question too ("Open questions: …").
                if items.iter().all(|item| ends_with_question_mark(item)) {
                    let summary = one_line(&items.join(" / "), 160);
                    return Some(StopQuestion {
                        summary,
                        text: texts.join("\n\n"),
                        options: Vec::new(),
                        cue: "question-list".into(),
                    });
                }
                skipped += 1;
            }
            Unit::Sentence(sentence) => {
                if is_closing(sentence) || is_recommendation(sentence) {
                    skipped += 1;
                    continue;
                }
                let cue = question_cue(sentence)?;
                let options = neighbour_list(&units, i, sentence);
                let mut summary = sentence.clone();
                if !options.is_empty() {
                    let labels: Vec<&str> = options.iter().map(|o| o.label.as_str()).collect();
                    summary = format!("{summary} — {}", labels.join(" / "));
                }
                return Some(StopQuestion {
                    summary: one_line(&summary, 160),
                    text: bounded(&texts),
                    options,
                    cue,
                });
            }
        }
    }
    None
}

/// The asking paragraphs, cut to 1,000 characters for the Ledger.
fn bounded(texts: &[String]) -> String {
    let joined = texts.join("\n\n");
    if joined.chars().count() > 1000 {
        let cut: String = joined.chars().take(999).collect();
        return format!("{}…", cut.trim_end());
    }
    joined
}

/// The question's choices: a list right after it, or right before it when the question
/// asks to pick one ("Which do you prefer?"), since a list of changes often precedes an
/// unrelated question.
fn neighbour_list(units: &[Unit], i: usize, question: &str) -> Vec<Choice> {
    let after = units.get(i + 1);
    let before = i
        .checked_sub(1)
        .and_then(|j| units.get(j))
        .filter(|_| asks_to_choose(question));
    for unit in [after, before].into_iter().flatten() {
        if let Unit::List(items) = unit {
            return items
                .iter()
                .map(|label| Choice {
                    recommended: is_recommended(label),
                    label: label.clone(),
                })
                .collect();
        }
    }
    Vec::new()
}

fn asks_to_choose(question: &str) -> bool {
    const WORDS: &[&str] = &[
        "which",
        "option",
        "options",
        "approach",
        "one",
        "either",
        "or",
        "prefer",
        "어느",
        "어떤",
        "어떻게",
        "중",
        "방법",
        "옵션",
        "쪽",
        "どちら",
        "どの",
        "どれ",
        "どう",
        "哪",
        "选项",
        "方案",
        "还是",
    ];
    any_phrase(&question.to_lowercase(), WORDS)
}

fn question_cue(sentence: &str) -> Option<String> {
    let lower = sentence.to_lowercase();
    if let Some(phrase) = first_phrase(&lower, ASKS) {
        return Some(format!("{}:{phrase}", script_of(phrase)));
    }
    if any_phrase(&lower, OFFER_IF) && any_phrase(&lower, OFFER_DO) {
        return Some("offer".into());
    }
    let ending = trim_tail(sentence).trim_end_matches(['?', '？', '.', '。', '!', '！']);
    if let Some(end) = QUESTION_ENDINGS.iter().find(|e| ending.ends_with(*e)) {
        return Some(format!("{}:{end}", script_of(end)));
    }
    if ends_with_question_mark(sentence) {
        return Some("question-mark".into());
    }
    None
}

fn script_of(phrase: &str) -> &'static str {
    let c = phrase.chars().next().unwrap_or(' ');
    match c {
        '\u{AC00}'..='\u{D7A3}' | '\u{1100}'..='\u{11FF}' | '\u{3130}'..='\u{318F}' => "ko",
        '\u{3040}'..='\u{30FF}' => "ja",
        '\u{4E00}'..='\u{9FFF}' => {
            // Japanese phrases here start with kana; a leading ideograph is Chinese unless the
            // phrase carries kana later on.
            if phrase
                .chars()
                .any(|c| ('\u{3040}'..='\u{30FF}').contains(&c))
            {
                "ja"
            } else {
                "zh"
            }
        }
        _ => "en",
    }
}

fn is_closing(sentence: &str) -> bool {
    let lower = sentence.to_lowercase();
    if any_phrase(&lower, CLOSINGS) {
        return true;
    }
    let bare = trim_tail(&lower).trim_end_matches(['!', '.', '！', '。']);
    SIGN_OFFS
        .iter()
        .any(|s| bare == *s || bare.ends_with(&format!(" {s}")))
}

fn is_recommendation(sentence: &str) -> bool {
    !ends_with_question_mark(sentence) && any_phrase(&sentence.to_lowercase(), RECOMMENDS)
}

/// Paragraphs of plain lines, without fenced code: a question inside code is not one.
fn paragraphs(message: &str) -> Vec<Vec<String>> {
    let mut out: Vec<Vec<String>> = Vec::new();
    let mut current: Vec<String> = Vec::new();
    let mut fence: Option<&str> = None;
    for raw in message.lines() {
        let trimmed = raw.trim_start();
        if let Some(open) = fence {
            if trimmed.starts_with(open) {
                fence = None;
            }
            continue;
        }
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fence = Some(if trimmed.starts_with("```") {
                "```"
            } else {
                "~~~"
            });
            flush(&mut out, &mut current);
            continue;
        }
        if trimmed.is_empty() || is_rule(trimmed) {
            flush(&mut out, &mut current);
            continue;
        }
        // A heading starts a paragraph of its own.
        if trimmed.starts_with('#') {
            flush(&mut out, &mut current);
            current.push(plain_line(raw));
            flush(&mut out, &mut current);
            continue;
        }
        let indented = raw.starts_with(' ') || raw.starts_with('\t');
        let item = list_marker(trimmed).is_some();
        // A list and the line that leads into it are separate paragraphs, even without a
        // blank line between them.
        if let Some(first) = current.first() {
            let in_list = list_marker(first.trim_start()).is_some();
            if (in_list && !item && !indented) || (!in_list && item) {
                flush(&mut out, &mut current);
            }
        }
        let line = if item || !indented {
            raw.to_string()
        } else {
            // continuation of the previous list item
            format!("  {}", trimmed)
        };
        current.push(line);
    }
    flush(&mut out, &mut current);
    out
}

fn flush(out: &mut Vec<Vec<String>>, current: &mut Vec<String>) {
    if !current.is_empty() {
        out.push(std::mem::take(current));
    }
}

fn is_rule(line: &str) -> bool {
    line.len() >= 3 && line.chars().all(|c| matches!(c, '-' | '*' | '_' | ' '))
}

/// The items of a paragraph made only of list items (with continuation lines).
fn list_items(paragraph: &[String]) -> Option<Vec<String>> {
    let mut items: Vec<String> = Vec::new();
    for line in paragraph {
        let trimmed = line.trim_start();
        if let Some(rest) = list_marker(trimmed) {
            items.push(plain_line(rest));
        } else if line.starts_with(' ') || line.starts_with('\t') {
            let last = items.last_mut()?;
            last.push(' ');
            last.push_str(&plain_line(trimmed));
        } else {
            return None;
        }
    }
    (!items.is_empty()).then_some(items)
}

/// The text after a list marker: `-`, `*`, `+`, `•`, `1.`, `1)`, `(1)`, `A.`, `a)`, `①`.
fn list_marker(line: &str) -> Option<&str> {
    let mut chars = line.char_indices();
    let (_, first) = chars.next()?;
    let after = |index: usize| -> Option<&str> {
        let rest = &line[index..];
        rest.starts_with(' ').then(|| rest.trim_start())
    };
    if matches!(first, '-' | '*' | '+' | '•') {
        return after(first.len_utf8());
    }
    if ('①'..='⑳').contains(&first) {
        return after(first.len_utf8()).or(Some(line[first.len_utf8()..].trim_start()));
    }
    if first == '(' {
        let close = line.find(')')?;
        let inner = &line[1..close];
        let ok = (inner.len() <= 2 && inner.chars().all(|c| c.is_ascii_digit()))
            || (inner.len() == 1 && inner.chars().all(|c| c.is_ascii_alphabetic()));
        return if ok { after(close + 1) } else { None };
    }
    let digits = line.chars().take_while(|c| c.is_ascii_digit()).count();
    if (1..=2).contains(&digits) {
        let mark = line[digits..].chars().next()?;
        if matches!(mark, '.' | ')') {
            return after(digits + 1);
        }
        return None;
    }
    if first.is_ascii_alphabetic() {
        let mark = line[1..].chars().next()?;
        if matches!(mark, '.' | ')') {
            return after(2);
        }
    }
    None
}
