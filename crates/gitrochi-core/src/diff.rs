use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Line {
    pub kind: String,
    pub text: String,
    pub old_no: Option<i64>,
    pub new_no: Option<i64>,
    pub raw: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hunk: Option<usize>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub changes: Vec<[usize; 2]>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Hunk {
    pub line: usize,
    old_start: i64,
    old_count: i64,
    new_start: i64,
    new_count: i64,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Info {
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    new_file: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    deleted_file: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    old_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    new_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rename_from: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rename_to: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    similarity: Option<i64>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Document {
    pub lines: Vec<Line>,
    pub is_binary: bool,
    pub truncated: bool,
    pub header: Vec<String>,
    pub hunks: Vec<Hunk>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub combined: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub multiple_files: bool,
    pub info: Info,
}

// Swift Character와 JS 코드포인트의 차이로 강조 위치가 어긋나지 않게 경계를 명시한다.
// 내부는 확장 자소를 사용하고 Windows 응답에서만 코드포인트 위치로 변환한다.
pub fn tokens(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut last_kind = 3;
    for (i, g) in s.grapheme_indices(true) {
        let c = g.chars().next().unwrap();
        let kind = if c.is_alphanumeric() || c == '_' {
            0
        } else if c.is_whitespace() {
            1
        } else {
            2
        };
        if i > start && (kind != last_kind || kind == 2) {
            out.push(&s[start..i]);
            start = i;
        }
        last_kind = kind;
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

pub fn ranges(a: &str, b: &str, scalar: bool) -> [Vec<[usize; 2]>; 2] {
    let ta = tokens(a);
    let tb = tokens(b);
    let n = ta.len();
    let m = tb.len();
    if n == 0 || m == 0 || n > 400 || m > 400 {
        return [vec![], vec![]];
    }
    // 400토큰 상한이므로 연속 u16 배열로 충분하며 행마다 메모리를 따로 할당하지 않는다.
    let stride = m + 1;
    let mut dp = vec![0u16; (n + 1) * stride];
    for x in (0..n).rev() {
        for y in (0..m).rev() {
            dp[x * stride + y] = if ta[x] == tb[y] {
                dp[(x + 1) * stride + y + 1] + 1
            } else {
                dp[(x + 1) * stride + y].max(dp[x * stride + y + 1])
            };
        }
    }
    let mut ka = vec![false; n];
    let mut kb = vec![false; m];
    let (mut x, mut y) = (0, 0);
    while x < n && y < m {
        if ta[x] == tb[y] {
            ka[x] = true;
            kb[y] = true;
            x += 1;
            y += 1;
        } else if dp[(x + 1) * stride + y] >= dp[x * stride + y + 1] {
            x += 1;
        } else {
            y += 1;
        }
    }
    fn spans(t: &[&str], keep: &[bool], scalar: bool) -> (Vec<[usize; 2]>, usize, usize) {
        let (mut out, mut pos, mut changed, mut total): (Vec<[usize; 2]>, usize, usize, usize) =
            (vec![], 0, 0, 0);
        for (tok, keep) in t.iter().zip(keep) {
            let len = if scalar {
                tok.chars().count()
            } else {
                tok.graphemes(true).count()
            };
            let blank = tok.trim().is_empty();
            if !keep {
                if !blank {
                    changed += len;
                }
                if let Some(last) = out.last_mut().filter(|last| last[1] == pos) {
                    last[1] = pos + len;
                } else {
                    out.push([pos, pos + len]);
                }
            }
            if !blank {
                total += len;
            }
            pos += len;
        }
        (out, changed, total)
    }
    let (sa, ca, na) = spans(&ta, &ka, scalar);
    let (sb, cb, nb) = spans(&tb, &kb, scalar);
    if (ca + cb) as f64 / (na + nb).max(1) as f64 > 0.7 {
        [vec![], vec![]]
    } else {
        [sa, sb]
    }
}

pub fn mark(lines: &mut [Line], scalar: bool) {
    let mut i = 0;
    while i < lines.len() {
        if lines[i].kind != "removed" {
            i += 1;
            continue;
        }
        let mut r = i;
        while r < lines.len() && lines[r].kind == "removed" {
            r += 1;
        }
        let mut a = r;
        while a < lines.len() && lines[a].kind == "added" {
            a += 1;
        }
        for k in 0..(r - i).min(a - r) {
            let [old, new] = ranges(&lines[i + k].text, &lines[r + k].text, scalar);
            lines[i + k].changes = old;
            lines[r + k].changes = new;
        }
        i = a.max(i + 1);
    }
}

fn position(s: &str, sign: char) -> (i64, i64) {
    let Some((_, rest)) = s.split_once(&format!(" {sign}")) else {
        return (0, 0);
    };
    let field = rest
        .split(|c: char| !c.is_ascii_digit() && c != ',')
        .next()
        .unwrap_or("");
    let mut parts = field.split(',');
    (
        parts.next().and_then(|n| n.parse().ok()).unwrap_or(0),
        parts.next().map_or(1, |n| n.parse().unwrap_or(0)),
    )
}

pub fn parse(text: &str, max_lines: usize, scalar: bool) -> Document {
    let mut doc = Document::default();
    let body = text.strip_suffix('\n').unwrap_or(text);
    if body.is_empty() {
        return doc;
    }
    let (mut old_no, mut new_no, mut in_hunk, mut cols, mut files) = (0, 0, false, 1, 0);
    for line in body.split('\n') {
        if doc.lines.len() >= max_lines {
            doc.truncated = true;
            break;
        }
        let s = line.strip_suffix('\r').unwrap_or(line);
        let mut kind = "context";
        let (mut old, mut new) = (None, None);
        let (mut display, mut raw) = (s.to_owned(), String::new());
        if s.starts_with("@@") {
            in_hunk = true;
            cols = s
                .bytes()
                .take_while(|c| *c == b'@')
                .count()
                .saturating_sub(1)
                .max(1);
            doc.combined |= cols > 1;
            let (os, oc) = position(s, '-');
            let (ns, nc) = position(s, '+');
            old_no = os;
            new_no = ns;
            doc.hunks.push(Hunk {
                line: doc.lines.len(),
                old_start: os,
                old_count: oc,
                new_start: ns,
                new_count: nc,
            });
            kind = "hunk";
        } else {
            if s.starts_with("diff ") {
                in_hunk = false;
                files += 1;
                doc.multiple_files |= files > 1;
            }
            if !in_hunk {
                if files <= 1 {
                    doc.header.push(s.to_owned());
                    read_info(s, &mut doc.info);
                }
                doc.is_binary |= s.starts_with("Binary files") || s.starts_with("GIT binary patch");
                continue;
            }
            if s.starts_with('\\') {
                kind = "meta";
                raw = s.to_owned();
                display = "No newline at end of file".to_owned();
            } else {
                // 접두사는 ASCII지만 손상된 입력도 UTF-8 경계를 잘라 패닉을 내지 않는다.
                let boundary = s.char_indices().nth(cols).map_or(s.len(), |(i, _)| i);
                let marker = &s[..boundary];
                raw = line[boundary..].to_owned();
                display = s[boundary..].replace('\t', "    ");
                if marker.contains('+') && !marker.contains('-') {
                    kind = "added";
                    new = Some(new_no);
                    new_no += 1;
                } else if marker.contains('-') {
                    kind = "removed";
                    old = Some(old_no);
                    old_no += 1;
                } else {
                    old = Some(old_no);
                    new = Some(new_no);
                    old_no += 1;
                    new_no += 1;
                }
            }
        }
        doc.lines.push(Line {
            kind: kind.into(),
            text: display,
            old_no: old,
            new_no: new,
            raw,
            hunk: doc.hunks.len().checked_sub(1),
            changes: vec![],
        });
    }
    mark(&mut doc.lines, scalar);
    doc
}

fn read_info(s: &str, info: &mut Info) {
    if let Some(v) = s.strip_prefix("new file mode ") {
        info.new_file = true;
        info.new_mode = Some(v.into());
    } else if let Some(v) = s.strip_prefix("deleted file mode ") {
        info.deleted_file = true;
        info.old_mode = Some(v.into());
    } else if let Some(v) = s.strip_prefix("old mode ") {
        info.old_mode = Some(v.into());
    } else if let Some(v) = s.strip_prefix("new mode ") {
        info.new_mode = Some(v.into());
    } else if let Some(v) = s.strip_prefix("rename from ") {
        info.rename_from = Some(v.into());
    } else if let Some(v) = s.strip_prefix("rename to ") {
        info.rename_to = Some(v.into());
    } else if let Some(v) = s.strip_prefix("similarity index ") {
        info.similarity = v.trim_end_matches('%').parse().ok();
    }
}

pub fn new_file(text: &str, truncated: bool, max_lines: usize) -> Document {
    let mut doc = Document {
        truncated,
        info: Info {
            new_file: true,
            ..Info::default()
        },
        ..Document::default()
    };
    if text.is_empty() {
        return doc;
    }
    let body = text.replace("\r\n", "\n");
    let body = body.strip_suffix('\n').unwrap_or(&body);
    let count = body.split('\n').count();
    doc.lines.push(Line {
        kind: "hunk".into(),
        text: format!("@@ -0,0 +1,{count} @@"),
        ..Line::default()
    });
    for (i, s) in body.split('\n').take(max_lines).enumerate() {
        doc.lines.push(Line {
            kind: "added".into(),
            text: s.replace('\t', "    "),
            new_no: Some((i + 1) as i64),
            ..Line::default()
        });
    }
    doc.truncated |= count > max_lines;
    doc
}

#[derive(Serialize)]
pub struct SplitRow {
    #[serde(skip_serializing_if = "Option::is_none")]
    full: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    left: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    right: Option<usize>,
}

pub fn split_rows(lines: &[Line]) -> Vec<SplitRow> {
    let mut out = Vec::with_capacity(lines.len());
    let mut i = 0;
    while i < lines.len() {
        match lines[i].kind.as_str() {
            "hunk" | "meta" => {
                out.push(SplitRow {
                    full: Some(i),
                    left: None,
                    right: None,
                });
                i += 1;
            }
            "context" => {
                out.push(SplitRow {
                    full: None,
                    left: Some(i),
                    right: Some(i),
                });
                i += 1;
            }
            "removed" | "added" => {
                let start = i;
                while i < lines.len() && lines[i].kind == "removed" {
                    i += 1;
                }
                let r = i;
                while i < lines.len() && lines[i].kind == "added" {
                    i += 1;
                }
                for k in 0..(r - start).max(i - r) {
                    out.push(SplitRow {
                        full: None,
                        left: (k < r - start).then_some(start + k),
                        right: (k < i - r).then_some(r + k),
                    });
                }
            }
            _ => {
                i += 1;
            }
        }
    }
    out
}

pub fn can_edit(doc: &Document) -> bool {
    !doc.is_binary
        && !doc.combined
        && !doc.multiple_files
        && !doc.hunks.is_empty()
        && !doc.truncated
        && doc
            .header
            .iter()
            .any(|l| l.starts_with("--- a/") || l.starts_with("--- \"a/"))
        && doc
            .header
            .iter()
            .any(|l| l.starts_with("+++ b/") || l.starts_with("+++ \"b/"))
        && !doc.header.iter().any(|l| {
            [
                "new file mode",
                "deleted file mode",
                "rename ",
                "similarity",
            ]
            .iter()
            .any(|p| l.starts_with(p))
        })
}

pub fn patch(
    doc: &Document,
    hunks: &[usize],
    selected: Option<&[usize]>,
    reverse: bool,
) -> Option<String> {
    if !can_edit(doc) {
        return None;
    }
    let selected: Option<HashSet<usize>> = selected.map(|s| s.iter().copied().collect());
    let hunks: HashSet<usize> = hunks.iter().copied().collect();
    let mut out: Vec<String> = doc
        .header
        .iter()
        .filter(|l| {
            !["index ", "old mode ", "new mode "]
                .iter()
                .any(|p| l.starts_with(p))
        })
        .cloned()
        .collect();
    let (mut delta, mut any) = (0, false);
    for (n, h) in doc.hunks.iter().enumerate() {
        if !hunks.contains(&n) {
            continue;
        }
        let end = doc.hunks.get(n + 1).map_or(doc.lines.len(), |h| h.line);
        if h.line >= end || end > doc.lines.len() {
            return None;
        }
        let (mut body, mut oc, mut nc, mut changed, mut last_kept) =
            (Vec::new(), 0, 0, false, false);
        for (i, l) in doc.lines.iter().enumerate().take(end).skip(h.line + 1) {
            let pick = selected.as_ref().is_none_or(|s| s.contains(&i));
            match l.kind.as_str() {
                "context" => {
                    body.push(format!(" {}", l.raw));
                    oc += 1;
                    nc += 1;
                    last_kept = true;
                }
                "removed" if pick => {
                    body.push(format!("-{}", l.raw));
                    oc += 1;
                    changed = true;
                    last_kept = true;
                }
                "added" if pick => {
                    body.push(format!("+{}", l.raw));
                    nc += 1;
                    changed = true;
                    last_kept = true;
                }
                "removed" if !reverse => {
                    body.push(format!(" {}", l.raw));
                    oc += 1;
                    nc += 1;
                    last_kept = true;
                }
                "added" if reverse => {
                    body.push(format!(" {}", l.raw));
                    oc += 1;
                    nc += 1;
                    last_kept = true;
                }
                "meta" => {
                    if last_kept {
                        body.push(l.raw.clone());
                    }
                }
                _ => last_kept = false,
            }
        }
        if !changed {
            continue;
        }
        any = true;
        let anchor = if reverse {
            h.new_start + i64::from(h.new_count == 0)
        } else {
            h.old_start + i64::from(h.old_count == 0)
        };
        let os = (anchor + if reverse { -delta } else { 0 } - i64::from(oc == 0)).max(0);
        let ns = (anchor + if reverse { 0 } else { delta } - i64::from(nc == 0)).max(0);
        out.push(format!("@@ -{os},{oc} +{ns},{nc} @@"));
        out.extend(body);
        delta += nc - oc;
    }
    any.then(|| out.join("\n") + "\n")
}
