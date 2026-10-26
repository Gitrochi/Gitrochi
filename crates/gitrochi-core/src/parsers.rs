use serde_json::{json, Map, Value};
use std::collections::HashMap;
use unicode_segmentation::UnicodeSegmentation;

fn words(s: &str) -> Vec<&str> {
    s.split(' ').filter(|s| !s.is_empty()).collect()
}
fn number(s: &str) -> i64 {
    s.parse().unwrap_or(0)
}

pub fn body_preview(body: &str) -> String {
    for raw in body.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some((key, value)) = line.split_once(": ") {
            if key.starts_with(|c: char| c.is_ascii_alphabetic())
                && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                && value.starts_with(|c: char| !c.is_whitespace())
            {
                continue;
            }
        }
        return line
            .strip_prefix("- ")
            .or_else(|| line.strip_prefix("* "))
            .unwrap_or(line)
            .graphemes(true)
            .take(200)
            .collect();
    }
    String::new()
}

fn commit(fields: &[&str], body: bool) -> Value {
    let mut out = json!({"id":fields[0], "parents":words(fields[1]), "author":fields[2], "email":fields[3], "date":number(fields[4]), "subject":fields[5]});
    if body {
        out["body"] = json!(body_preview(&fields.get(6..).unwrap_or(&[]).join("\u{1f}")));
    }
    out
}

pub fn log(text: &str) -> Value {
    Value::Array(
        text.split('\u{1e}')
            .filter_map(|r| {
                let f: Vec<_> = r.trim_start_matches(['\r', '\n']).split('\u{1f}').collect();
                (f.len() >= 6).then(|| commit(&f, true))
            })
            .collect(),
    )
}

pub fn detail(text: &str) -> Value {
    let f: Vec<_> = text.split('\u{1f}').collect();
    if f.len() < 9 {
        return Value::Null;
    }
    let message = f[8..].join("\u{1f}");
    let message = message.trim();
    let (summary, body) = message.split_once('\n').unwrap_or((message, ""));
    json!({"sha":f[0],"parents":words(f[1]),"author":f[2],"email":f[3],"date":number(f[4]),"committer":f[5],"committerEmail":f[6],"commitDate":number(f[7]),"summary":summary,"body":body.trim()})
}

pub fn track(text: &str) -> Value {
    let (mut ahead, mut behind, mut gone) = (0, 0, false);
    for part in text.split(',') {
        let w = words(part.trim());
        if w.first() == Some(&"gone") {
            gone = true;
        }
        if w.len() == 2 {
            match w[0] {
                "ahead" => ahead = number(w[1]),
                "behind" => behind = number(w[1]),
                _ => {}
            }
        }
    }
    json!({"ahead":ahead,"behind":behind,"gone":gone})
}

pub fn refs(text: &str) -> Value {
    let (mut locals, mut remotes, mut tags) = (vec![], vec![], vec![]);
    for line in text.split('\n').filter(|s| !s.is_empty()) {
        let f: Vec<_> = line.split('\u{1f}').collect();
        if f.len() < 6 {
            continue;
        }
        if let Some(name) = f[0].strip_prefix("refs/heads/") {
            let t = track(f[4]);
            locals.push(json!({"name":name,"target":f[1],"upstream":if f[3].is_empty() {Value::Null} else {json!(f[3])},"ahead":t["ahead"],"behind":t["behind"],"upstreamGone":t["gone"],"isCurrent":f[5].trim()=="*","isRemote":false}));
        } else if let Some(name) = f[0].strip_prefix("refs/remotes/") {
            if !name.ends_with("/HEAD") {
                remotes.push(json!({"name":name,"target":f[1],"upstream":null,"ahead":0,"behind":0,"upstreamGone":false,"isCurrent":false,"isRemote":true}));
            }
        } else if let Some(name) = f[0].strip_prefix("refs/tags/") {
            tags.push(json!({"name":name,"target":if f[2].is_empty(){f[1]}else{f[2]}}));
        }
    }
    json!({"locals":locals,"remotes":remotes,"tags":tags})
}

pub fn stashes(text: &str) -> Value {
    json!(text
        .split('\n')
        .filter_map(|s| {
            let f: Vec<_> = s.split('\u{1f}').collect();
            (f.len() >= 3).then(|| json!({"ref":f[0],"hash":f[1],"message":f[2]}))
        })
        .collect::<Vec<_>>())
}

pub fn remotes(text: &str) -> Value {
    let mut names = Vec::new();
    let mut urls = Map::new();
    for line in text.split('\n') {
        let f: Vec<_> = line.split(['\t', ' ']).filter(|s| !s.is_empty()).collect();
        if f.len() < 2 {
            continue;
        }
        if !names.contains(&f[0]) {
            names.push(f[0]);
        }
        if f.len() < 3 || f[2] == "(fetch)" {
            urls.insert(f[0].into(), json!(f[1]));
        }
    }
    json!({"names":names,"urls":urls})
}

pub fn worktrees(text: &str) -> Value {
    let nul = text.contains('\0');
    let normalized;
    let text = if nul {
        text
    } else {
        normalized = text.replace("\r\n", "\n");
        &normalized
    };
    json!(text.split(if nul {"\0\0"} else {"\n\n"}).enumerate().filter_map(|(i, block)| {
        let (mut path, mut head, mut branch) = (None, None, None);
        let (mut bare, mut locked, mut prunable) = (false, false, false);
        for line in block.split(if nul {'\0'} else {'\n'}) {
            if let Some(v) = line.strip_prefix("worktree ") { path = Some(v); }
            else if let Some(v) = line.strip_prefix("HEAD ") { head = Some(v); }
            else if let Some(v) = line.strip_prefix("branch ") { branch = Some(v.strip_prefix("refs/heads/").unwrap_or(v)); }
            else if line == "bare" { bare=true; }
            else if line.starts_with("locked") { locked=true; }
            else if line.starts_with("prunable") { prunable=true; }
        }
        path.filter(|p| !p.is_empty() && !bare).map(|path| json!({"path":path,"head":head,"branch":branch,"isMain":i==0,"locked":locked,"prunable":prunable}))
    }).collect::<Vec<_>>())
}

fn kind(c: char) -> &'static str {
    match c {
        'A' => "added",
        'D' => "deleted",
        'R' => "renamed",
        'C' => "copied",
        'T' => "typeChanged",
        'U' => "conflicted",
        _ => "modified",
    }
}
fn change(path: &str, old: Option<&str>, kind: &str, staged: bool) -> Value {
    json!({"path":path,"oldPath":old,"kind":kind,"staged":staged})
}

pub fn status(text: &str) -> Value {
    let mut st = json!({"branch":null,"upstream":null,"ahead":0,"behind":0,"staged":[],"unstaged":[],"conflicted":[]});
    let tokens: Vec<_> = text.split('\0').filter(|t| !t.is_empty()).collect();
    let mut i = 0;
    while i < tokens.len() {
        let t = tokens[i];
        i += 1;
        if let Some(body) = t.strip_prefix("# ") {
            let Some((key, value)) = body.split_once(' ') else {
                continue;
            };
            match key {
                "branch.head" => {
                    st["branch"] = if value == "(detached)" {
                        Value::Null
                    } else {
                        json!(value)
                    }
                }
                "branch.upstream" => st["upstream"] = json!(value),
                "branch.ab" => {
                    for w in words(value) {
                        if let Some(v) = w.strip_prefix('+') {
                            st["ahead"] = json!(number(v));
                        } else if let Some(v) = w.strip_prefix('-') {
                            st["behind"] = json!(number(v));
                        }
                    }
                }
                _ => {}
            }
        } else if t.starts_with("1 ") || t.starts_with("2 ") {
            let rename = t.starts_with("2 ");
            let n = if rename { 10 } else { 9 };
            let f: Vec<_> = t.splitn(n, ' ').collect();
            let orig = if rename {
                let orig = tokens.get(i).copied();
                i += 1;
                orig
            } else {
                None
            };
            if f.len() != n || f[1].chars().count() != 2 {
                continue;
            }
            let mut xy = f[1].chars();
            let x = xy.next().unwrap();
            let y = xy.next().unwrap();
            if x != '.' {
                st["staged"]
                    .as_array_mut()
                    .unwrap()
                    .push(change(f[n - 1], orig, kind(x), true));
            }
            if y != '.' {
                st["unstaged"]
                    .as_array_mut()
                    .unwrap()
                    .push(change(f[n - 1], None, kind(y), false));
            }
        } else if t.starts_with("u ") {
            let f: Vec<_> = t.splitn(11, ' ').collect();
            if f.len() == 11 {
                st["conflicted"].as_array_mut().unwrap().push(change(
                    f[10],
                    None,
                    "conflicted",
                    false,
                ));
            }
        } else if let Some(path) = t.strip_prefix("? ") {
            st["unstaged"]
                .as_array_mut()
                .unwrap()
                .push(change(path, None, "untracked", false));
        }
    }
    st
}

pub fn name_status(text: &str) -> Value {
    let t: Vec<_> = text.split('\0').filter(|t| !t.is_empty()).collect();
    let (mut i, mut out) = (0, vec![]);
    while i < t.len() {
        let c = t[i].chars().next().unwrap();
        i += 1;
        if c == 'R' || c == 'C' {
            if i + 1 >= t.len() {
                break;
            }
            out.push(change(t[i + 1], Some(t[i]), kind(c), false));
            i += 2;
        } else {
            if i >= t.len() {
                break;
            }
            out.push(change(t[i], None, kind(c), false));
            i += 1;
        }
    }
    json!(out)
}

pub fn numstat(text: &str) -> Value {
    let t: Vec<_> = text.split('\0').collect();
    let (mut i, mut out) = (0, Map::new());
    while i < t.len() {
        let f: Vec<_> = t[i]
            .strip_prefix('\n')
            .unwrap_or(t[i])
            .splitn(3, '\t')
            .collect();
        i += 1;
        if f.len() != 3 {
            continue;
        }
        let stat = json!({"added":f[0].parse::<u64>().ok(),"deleted":f[1].parse::<u64>().ok()});
        if f[2].is_empty() {
            if i + 1 >= t.len() {
                break;
            }
            out.insert(t[i + 1].into(), stat);
            i += 2;
        } else {
            out.insert(f[2].into(), stat);
        }
    }
    Value::Object(out)
}

pub fn file_history(text: &str) -> Value {
    let mut records = vec![];
    if text.contains('\0') {
        let fields: Vec<_> = text.split('\0').collect();
        let mut i = 0;
        while i < fields.len() {
            let f = fields[i];
            i += 1;
            let Some(header) = f.strip_prefix('\u{1e}') else {
                continue;
            };
            let path = if let Some(path) = fields.get(i).and_then(|f| f.strip_prefix('\n')) {
                i += 1;
                path
            } else {
                ""
            };
            records.push((header, path));
        }
    } else {
        for r in text.split('\u{1e}').filter(|r| !r.trim().is_empty()) {
            let mut lines = r.lines().filter(|l| !l.is_empty());
            records.push((lines.next().unwrap_or(""), lines.next().unwrap_or("")));
        }
    }
    json!(records
        .into_iter()
        .filter_map(|(header, path)| {
            let mut f: Vec<_> = header.split('\u{1f}').collect();
            if f.len() < 6 {
                return None;
            }
            let subject = f[5..].join("\u{1f}");
            f[5] = &subject;
            Some(json!({"commit":commit(&f,false),"path":path}))
        })
        .collect::<Vec<_>>())
}

pub fn blame(text: &str) -> Value {
    #[derive(Default)]
    struct Info {
        author: String,
        email: String,
        time: i64,
        summary: String,
    }
    let mut infos: HashMap<&str, Info> = HashMap::new();
    let mut out = vec![];
    let (mut sha, mut line_no, mut prev) = ("", 0, "");
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some(code) = line.strip_prefix('\t') {
            let empty = Info::default();
            let info = infos.get(sha).unwrap_or(&empty);
            out.push(json!({"no":line_no,"sha":sha,"text":code.replace('\t',"    "),"author":info.author,"email":info.email,"date":info.time,"summary":info.summary,"startsBlock":sha!=prev}));
            prev = sha;
            continue;
        }
        let (key, value) = line.split_once(' ').unwrap_or((line, ""));
        if (key.len() == 40 || key.len() == 64) && key.bytes().all(|b| b.is_ascii_hexdigit()) {
            sha = key;
            line_no = value
                .split(' ')
                .nth(1)
                .and_then(|v| v.parse().ok())
                .unwrap_or(line_no + 1);
            infos.entry(sha).or_default();
            continue;
        }
        let Some(info) = infos.get_mut(sha) else {
            continue;
        };
        match key {
            "author" => info.author = value.into(),
            "author-mail" => info.email = value.trim_matches(['<', '>']).into(),
            "author-time" => info.time = number(value),
            "summary" => info.summary = value.into(),
            _ => {}
        }
    }
    json!(out)
}
