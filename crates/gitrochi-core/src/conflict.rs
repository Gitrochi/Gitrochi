use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Block {
    id: usize,
    ours_label: String,
    theirs_label: String,
    ours: Vec<String>,
    base: Option<Vec<String>>,
    theirs: Vec<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Segment {
    Text { lines: Vec<String> },
    Conflict { block: usize },
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    source_text: String,
    pub segments: Vec<Segment>,
    pub blocks: Vec<Block>,
    newline: String,
    trailing_newline: bool,
}

fn label(line: &str, marker: char, width: usize) -> Option<&str> {
    let rest = line.strip_prefix(&marker.to_string().repeat(width))?;
    (rest.is_empty() || rest.starts_with([' ', '\t'])).then(|| rest.trim())
}

pub fn parse(text: &str) -> Document {
    let body = text.replace("\r\n", "\n");
    let trailing = body.ends_with('\n');
    let body = body.strip_suffix('\n').unwrap_or(&body);
    let mut doc = Document {
        source_text: text.into(),
        segments: vec![],
        blocks: vec![],
        newline: if text.contains("\r\n") { "\r\n" } else { "\n" }.into(),
        trailing_newline: trailing,
    };
    let (mut state, mut width) = (0, 7);
    let (mut plain, mut ours, mut base, mut theirs, mut pending) =
        (vec![], vec![], None::<Vec<String>>, vec![], vec![]);
    let mut ours_label = String::new();
    for line in body.split('\n') {
        if state != 0 {
            pending.push(line.to_owned());
        }
        match state {
            0 => {
                let w = line.bytes().take_while(|c| *c == b'<').count();
                if let Some(l) = if w >= 7 { label(line, '<', w) } else { None } {
                    if !plain.is_empty() {
                        doc.segments.push(Segment::Text {
                            lines: std::mem::take(&mut plain),
                        });
                    }
                    width = w;
                    ours_label = l.into();
                    pending = vec![line.into()];
                    ours.clear();
                    base = None;
                    theirs.clear();
                    state = 1;
                } else {
                    plain.push(line.into());
                }
            }
            1 => {
                if label(line, '|', width).is_some() {
                    base = Some(vec![]);
                    state = 2;
                } else if line == "=".repeat(width) {
                    state = 3;
                } else {
                    ours.push(line.into());
                }
            }
            2 => {
                if line == "=".repeat(width) {
                    state = 3;
                } else {
                    base.as_mut().unwrap().push(line.into());
                }
            }
            _ => {
                if let Some(l) = label(line, '>', width) {
                    let id = doc.blocks.len();
                    doc.blocks.push(Block {
                        id,
                        ours_label: ours_label.clone(),
                        theirs_label: l.into(),
                        ours: std::mem::take(&mut ours),
                        base: base.take(),
                        theirs: std::mem::take(&mut theirs),
                    });
                    doc.segments.push(Segment::Conflict { block: id });
                    state = 0;
                    pending.clear();
                } else {
                    theirs.push(line.into());
                }
            }
        }
    }
    if state != 0 {
        plain.extend(pending);
    }
    if !plain.is_empty() {
        doc.segments.push(Segment::Text { lines: plain });
    }
    doc
}

#[derive(Deserialize)]
pub struct Choice {
    kind: String,
    #[serde(default)]
    text: String,
}
pub fn resolve(doc: &Document, choices: &HashMap<usize, Choice>) -> Option<String> {
    if !doc.blocks.iter().all(|b| choices.contains_key(&b.id)) {
        return None;
    }
    let mut out = vec![];
    for s in &doc.segments {
        match s {
            Segment::Text { lines } => out.extend(lines.clone()),
            Segment::Conflict { block } => {
                let b = doc.blocks.get(*block)?;
                let c = choices.get(&b.id)?;
                match c.kind.as_str() {
                    "ours" => out.extend(b.ours.clone()),
                    "theirs" => out.extend(b.theirs.clone()),
                    "oursThenTheirs" => {
                        out.extend(b.ours.clone());
                        out.extend(b.theirs.clone());
                    }
                    "theirsThenOurs" => {
                        out.extend(b.theirs.clone());
                        out.extend(b.ours.clone());
                    }
                    "custom" => {
                        if !c.text.is_empty() {
                            out.extend(c.text.replace("\r\n", "\n").split('\n').map(String::from));
                        }
                    }
                    _ => return None,
                }
            }
        }
    }
    Some(
        out.join(&doc.newline)
            + if doc.trailing_newline {
                &doc.newline
            } else {
                ""
            },
    )
}
