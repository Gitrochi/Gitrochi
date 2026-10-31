//! Small text helpers shared by the question, answer and risk checks.

/// Whether `haystack` (already lower-cased) contains `phrase` as whole words: an ASCII
/// phrase must not continue into a letter or digit on either side, so `should i` does not
/// match `should implement`. Phrases in other scripts match anywhere.
pub(crate) fn has_phrase(haystack: &str, phrase: &str) -> bool {
    let ascii_start = phrase
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric());
    let ascii_end = phrase
        .chars()
        .last()
        .is_some_and(|c| c.is_ascii_alphanumeric());
    let mut from = 0;
    while let Some(found) = haystack[from..].find(phrase) {
        let start = from + found;
        let end = start + phrase.len();
        let before_ok = !ascii_start
            || haystack[..start]
                .chars()
                .last()
                .is_none_or(|c| !c.is_ascii_alphanumeric());
        let after_ok = !ascii_end
            || haystack[end..]
                .chars()
                .next()
                .is_none_or(|c| !c.is_ascii_alphanumeric());
        if before_ok && after_ok {
            return true;
        }
        from = start + phrase.chars().next().map_or(1, char::len_utf8);
    }
    false
}

pub(crate) fn any_phrase(haystack: &str, phrases: &[&str]) -> bool {
    phrases.iter().any(|p| has_phrase(haystack, p))
}

/// The first phrase found, for reporting which cue matched.
pub(crate) fn first_phrase<'a>(haystack: &str, phrases: &[&'a str]) -> Option<&'a str> {
    phrases.iter().copied().find(|p| has_phrase(haystack, p))
}

/// Removes Markdown emphasis, inline-code ticks, link targets, headings and quote marks
/// from one line, keeping the words.
pub(crate) fn plain_line(line: &str) -> String {
    let mut s = line.trim_start();
    while let Some(rest) = s.strip_prefix('>') {
        s = rest.trim_start();
    }
    let s = s.trim_start_matches('#').trim_start();
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '*' | '`' => {}
            '_' if is_emphasis_underscore(&chars, i) => {}
            // [text](target) keeps only the text
            ']' if chars.get(i + 1) == Some(&'(') => {
                if let Some(close) = chars[i + 2..].iter().position(|&c| c == ')') {
                    i += close + 3;
                    continue;
                }
            }
            '[' => {}
            _ => out.push(c),
        }
        i += 1;
    }
    out.trim().to_string()
}

fn is_emphasis_underscore(chars: &[char], i: usize) -> bool {
    let before = i.checked_sub(1).map(|j| chars[j]);
    let after = chars.get(i + 1).copied();
    // snake_case words keep their underscores
    !(before.is_some_and(char::is_alphanumeric) && after.is_some_and(char::is_alphanumeric))
}

/// One line of at most `max` characters, whitespace collapsed.
pub(crate) fn one_line(text: &str, max: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= max {
        return collapsed;
    }
    let mut cut: String = collapsed.chars().take(max.saturating_sub(1)).collect();
    cut = cut.trim_end().to_string();
    cut.push('…');
    cut
}

/// The text without trailing brackets, quotes, emphasis or emoji, so `**Proceed?**` ends in `?`.
pub(crate) fn trim_tail(text: &str) -> &str {
    text.trim_end_matches(|c: char| !(c.is_alphanumeric() || is_sentence_end(c)))
}

pub(crate) fn is_sentence_end(c: char) -> bool {
    matches!(c, '?' | '？' | '!' | '！' | '.' | '。')
}

pub(crate) fn ends_with_question_mark(sentence: &str) -> bool {
    matches!(trim_tail(sentence).chars().last(), Some('?' | '？'))
}

/// Splits a paragraph into sentences. A full stop only ends a sentence before whitespace,
/// so file names and versions (`lib.rs`, `1.2`) stay whole.
pub(crate) fn sentences(paragraph: &str) -> Vec<String> {
    let chars: Vec<char> = paragraph.chars().collect();
    let mut out = Vec::new();
    let mut current = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\n' {
            push_sentence(&mut out, &mut current);
            i += 1;
            continue;
        }
        current.push(c);
        let next = chars.get(i + 1).copied();
        let ends = match c {
            '?' | '？' | '!' | '！' | '。' => next.is_none_or(|n| !is_sentence_end(n)),
            '.' => next.is_none_or(char::is_whitespace),
            _ => false,
        };
        if ends {
            // a closing bracket or quote right after the mark belongs to the sentence
            while let Some(&n) = chars.get(i + 1) {
                if matches!(n, ')' | '"' | '\'' | '”' | '’' | '」' | '）' | ']') {
                    current.push(n);
                    i += 1;
                } else {
                    break;
                }
            }
            push_sentence(&mut out, &mut current);
        }
        i += 1;
    }
    push_sentence(&mut out, &mut current);
    out
}

fn push_sentence(out: &mut Vec<String>, current: &mut String) {
    let s = current.trim();
    if !s.is_empty() {
        out.push(s.to_string());
    }
    current.clear();
}
