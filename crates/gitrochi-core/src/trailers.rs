//! The commit trailers the inspector draws as rows: the issues a commit closes and its co-authors.
use serde_json::{json, Value};

/// One verb for every form GitHub and GitLab close an issue on
fn keyword(word: &str) -> Option<&'static str> {
    match word.to_ascii_lowercase().as_str() {
        "close" | "closes" | "closed" => Some("closes"),
        "fix" | "fixes" | "fixed" => Some("fixes"),
        "resolve" | "resolves" | "resolved" => Some("resolves"),
        _ => None,
    }
}

/// `#42`, or the issue's address in this repository (`base` is its web address, empty when unknown)
fn issue_number(token: &str, base: &str) -> Option<u64> {
    let digits = match token.strip_prefix('#') {
        Some(digits) => digits,
        None => {
            if base.is_empty() || token.len() <= base.len() || !token.is_char_boundary(base.len()) {
                return None;
            }
            let (head, tail) = token.split_at(base.len());
            if !head.eq_ignore_ascii_case(base) {
                return None;
            }
            tail.strip_prefix("/issues/")
                .or_else(|| tail.strip_prefix("/-/issues/"))?
        }
    };
    if digits.is_empty() || digits.len() > 18 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok().filter(|n| *n > 0)
}

/// A line that is nothing but closing references: `Closes #1, #2 and fixes #3`, with or without a colon
fn closing(line: &str, base: &str) -> Option<Vec<(&'static str, u64)>> {
    let mut out = Vec::new();
    let mut verb = None;
    // a verb or an "and" that no reference has followed yet
    let mut open = false;
    for token in line
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|s| !s.is_empty())
    {
        if let Some(found) = keyword(token.strip_suffix(':').unwrap_or(token)) {
            if open && verb.is_some() && out.is_empty() {
                return None;
            }
            verb = Some(found);
            open = true;
        } else if token.eq_ignore_ascii_case("and") && !open && !out.is_empty() {
            open = true;
        } else {
            out.push((verb?, issue_number(token, base)?));
            open = false;
        }
    }
    (!out.is_empty() && !open).then_some(out)
}

/// `Co-authored-by: Name <email>`
fn co_author(line: &str) -> Option<(&str, &str)> {
    let (key, value) = line.split_once(':')?;
    if !key.trim_end().eq_ignore_ascii_case("co-authored-by") {
        return None;
    }
    let (name, email) = value.trim().strip_suffix('>')?.rsplit_once('<')?;
    let (name, email) = (name.trim(), email.trim());
    (!name.is_empty()
        && !email.is_empty()
        && !email.contains(char::is_whitespace)
        && !name.contains(['<', '>']))
    .then_some((name, email))
}

/// git's `token: value`: letters, digits and hyphens before the colon
fn is_trailer(line: &str) -> bool {
    line.split_once(':').is_some_and(|(key, _)| {
        let key = key.trim_end();
        !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    })
}

/// The trailers of a message body (the message without its subject) and the body without the lines
/// that became rows. As git reads them, trailers are the last paragraph, and only when every line
/// of it is one (or a quarter are, beside a line git wrote itself); a closing reference anywhere
/// else stays prose. A line this does not recognise is never dropped.
pub fn parse(body: &str, issue_base: &str) -> (Value, String) {
    let base = issue_base.trim_end_matches('/');
    let lines: Vec<&str> = body.lines().collect();
    let end = lines
        .iter()
        .rposition(|l| !l.trim().is_empty())
        .map_or(0, |i| i + 1);
    let start = lines[..end]
        .iter()
        .rposition(|l| l.trim().is_empty())
        .map_or(0, |i| i + 1);
    let mut issues: Vec<(&'static str, u64)> = Vec::new();
    let mut authors: Vec<(&str, &str, &str)> = Vec::new();
    let mut taken = vec![false; lines.len()];
    let (mut trailers, mut others, mut generated, mut in_trailer) = (0usize, 0usize, false, false);
    for i in start..end {
        let line = lines[i];
        if line.starts_with([' ', '\t']) {
            // a folded value belongs to the trailer above it
            if !in_trailer {
                others += 1;
            }
            continue;
        }
        let closes = closing(line, base);
        let author = co_author(line.trim_end());
        in_trailer = true;
        if line.starts_with("Signed-off-by: ") || line.starts_with("(cherry picked from commit ") {
            generated = true;
            trailers += 1;
        } else if closes.is_some() || is_trailer(line) {
            trailers += 1;
        } else {
            others += 1;
            in_trailer = false;
        }
        // a line whose value goes on below is left as text, whole
        if i + 1 < end && lines[i + 1].starts_with([' ', '\t']) {
            continue;
        }
        if let Some(found) = closes {
            taken[i] = true;
            for (verb, number) in found {
                if !issues.iter().any(|(_, n)| *n == number) {
                    issues.push((verb, number));
                }
            }
        } else if let Some((name, email)) = author {
            taken[i] = true;
            if !authors
                .iter()
                .any(|(_, e, _)| e.eq_ignore_ascii_case(email))
            {
                authors.push((name, email, line.trim()));
            }
        }
    }
    let block = trailers > 0 && (others == 0 || (generated && trailers * 3 >= others));
    if !block || (issues.is_empty() && authors.is_empty()) {
        return (json!({"issues":[],"coAuthors":[]}), body.to_string());
    }
    let prose = lines
        .iter()
        .zip(&taken)
        .filter(|(_, taken)| !**taken)
        .map(|(line, _)| *line)
        .collect::<Vec<_>>()
        .join("\n");
    let issues: Vec<Value> = issues
        .into_iter()
        .map(|(verb, number)| json!({"keyword":verb,"number":number}))
        .collect();
    let authors: Vec<Value> = authors
        .into_iter()
        .map(|(name, email, line)| json!({"name":name,"email":email,"line":line}))
        .collect();
    (
        json!({"issues":issues,"coAuthors":authors}),
        prose.trim_end().to_string(),
    )
}
