//! YAML → JSON values. YAML features that are dangerous or confusing in a flow file (anchors, aliases, merge keys, tags, multiple documents)
//! are errors, and every value keeps its line number so errors show as `file:line`.

use serde_json::{Map, Number, Value};
use std::collections::HashMap;
use yaml_rust2::parser::{Event, MarkedEventReceiver, Parser};
use yaml_rust2::scanner::{Marker, TScalarStyle};

/// The parsed document and a line number per path. Paths look like `flows.pre-push.nodes.unit` or `suites.unit.with.args[0]`.
#[derive(Debug, Clone, Default)]
pub struct Doc {
    pub value: Value,
    pub lines: HashMap<String, usize>,
}

impl Doc {
    /// The line of a path, or of the nearest parent path when there is no exact value.
    pub fn line_of(&self, path: &str) -> Option<usize> {
        let mut p = path.to_string();
        loop {
            if let Some(l) = self.lines.get(&p) {
                return Some(*l);
            }
            match p.rfind(['.', '[']) {
                Some(i) => p.truncate(i),
                None => return self.lines.get("").copied(),
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct YamlError {
    pub line: usize,
    pub message: String,
}

enum Frame {
    Map {
        map: Map<String, Value>,
        key: Option<String>,
        path: String,
    },
    Seq {
        items: Vec<Value>,
        path: String,
    },
}

struct Builder {
    stack: Vec<Frame>,
    root: Option<Value>,
    lines: HashMap<String, usize>,
    error: Option<YamlError>,
    documents: usize,
}

fn join_key(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_string()
    } else {
        format!("{path}.{key}")
    }
}

impl Builder {
    fn fail(&mut self, line: usize, message: String) {
        if self.error.is_none() {
            self.error = Some(YamlError { line, message });
        }
    }

    /// The path the next value goes to; None while a map waits for a key.
    fn next_path(&self) -> Option<String> {
        match self.stack.last() {
            None => Some(String::new()),
            Some(Frame::Map { key, path, .. }) => key.as_ref().map(|k| join_key(path, k)),
            Some(Frame::Seq { items, path }) => Some(format!("{path}[{}]", items.len())),
        }
    }

    fn push_value(&mut self, v: Value, line: usize) {
        match self.stack.last_mut() {
            None => self.root = Some(v),
            Some(Frame::Seq { items, .. }) => items.push(v),
            Some(Frame::Map { map, key, path }) => {
                if let Some(k) = key.take() {
                    map.insert(k, v);
                } else {
                    // The key position. Keys are accepted only as strings.
                    let k = match v {
                        Value::String(s) => s,
                        Value::Number(n) => n.to_string(),
                        Value::Bool(b) => b.to_string(),
                        Value::Null => String::new(),
                        _ => {
                            let p = path.clone();
                            self.fail(
                                line,
                                crate::util::tr(
                                    &format!("{p}: 키는 글자여야 합니다."),
                                    &format!("{p}: keys must be plain text."),
                                ),
                            );
                            return;
                        }
                    };
                    if k == "<<" {
                        let p = path.clone();
                        self.fail(
                            line,
                            crate::util::tr(
                                &format!("{p}: 병합 키(<<)는 쓸 수 없습니다. 값을 직접 적으세요."),
                                &format!(
                                    "{p}: merge keys (<<) are not allowed. Write the values out."
                                ),
                            ),
                        );
                        return;
                    }
                    if map.contains_key(&k) {
                        let p = join_key(path, &k);
                        self.fail(
                            line,
                            crate::util::tr(
                                &format!("{p}: 같은 키가 두 번 있습니다."),
                                &format!("{p}: duplicate key."),
                            ),
                        );
                        return;
                    }
                    let p = join_key(path, &k);
                    self.lines.insert(p, line);
                    *key = Some(k);
                }
            }
        }
    }
}

fn scalar_value(text: &str, style: TScalarStyle) -> Value {
    if !matches!(style, TScalarStyle::Plain) {
        return Value::String(text.to_string());
    }
    match text {
        "" | "~" | "null" | "Null" | "NULL" => return Value::Null,
        "true" | "True" | "TRUE" => return Value::Bool(true),
        "false" | "False" | "FALSE" => return Value::Bool(false),
        _ => {}
    }
    let t = text.replace('_', "");
    if let Ok(i) = t.parse::<i64>() {
        if !text.starts_with('+') || text.len() > 1 {
            return Value::Number(i.into());
        }
    }
    if let Some(h) = t.strip_prefix("0x") {
        if let Ok(i) = i64::from_str_radix(h, 16) {
            return Value::Number(i.into());
        }
    }
    if let Some(o) = t.strip_prefix("0o") {
        if let Ok(i) = i64::from_str_radix(o, 8) {
            return Value::Number(i.into());
        }
    }
    // Only number-like strings become floats (1.0, 1e3); a version string like "1.2.3" stays a string.
    let looks_float = t.chars().all(|c| c.is_ascii_digit() || "+-.eE".contains(c))
        && t.chars().any(|c| c.is_ascii_digit());
    if looks_float {
        if let Ok(f) = t.parse::<f64>() {
            if let Some(n) = Number::from_f64(f) {
                return Value::Number(n);
            }
        }
    }
    Value::String(text.to_string())
}

impl MarkedEventReceiver for Builder {
    fn on_event(&mut self, ev: Event, mark: Marker) {
        if self.error.is_some() {
            return;
        }
        let line = mark.line();
        match ev {
            Event::DocumentStart => {
                self.documents += 1;
                if self.documents > 1 {
                    self.fail(
                        line,
                        crate::util::tr(
                            "한 파일에는 문서를 하나만 둡니다(--- 로 나누지 마세요).",
                            "Put one document per file (do not split with ---).",
                        ),
                    );
                }
            }
            Event::Alias(_) => self.fail(
                line,
                crate::util::tr(
                    "별칭(*)은 쓸 수 없습니다. 값을 직접 적으세요.",
                    "Aliases (*) are not allowed. Write the values out.",
                ),
            ),
            Event::Scalar(text, style, anchor, tag) => {
                if anchor != 0 {
                    self.fail(
                        line,
                        crate::util::tr(
                            "앵커(&)는 쓸 수 없습니다.",
                            "Anchors (&) are not allowed.",
                        ),
                    );
                    return;
                }
                if let Some(t) = tag {
                    self.fail(
                        line,
                        crate::util::tr(
                            &format!("태그({}{})는 쓸 수 없습니다.", t.handle, t.suffix),
                            &format!("Tags ({}{}) are not allowed.", t.handle, t.suffix),
                        ),
                    );
                    return;
                }
                if let Some(p) = self.next_path() {
                    self.lines.entry(p).or_insert(line);
                }
                self.push_value(scalar_value(&text, style), line);
            }
            Event::SequenceStart(anchor, tag) | Event::MappingStart(anchor, tag) => {
                if anchor != 0 {
                    self.fail(
                        line,
                        crate::util::tr(
                            "앵커(&)는 쓸 수 없습니다.",
                            "Anchors (&) are not allowed.",
                        ),
                    );
                    return;
                }
                if tag.is_some() {
                    self.fail(
                        line,
                        crate::util::tr("태그는 쓸 수 없습니다.", "Tags are not allowed."),
                    );
                    return;
                }
                let path = match self.next_path() {
                    Some(p) => p,
                    None => {
                        self.fail(
                            line,
                            crate::util::tr("키는 글자여야 합니다.", "Keys must be plain text."),
                        );
                        return;
                    }
                };
                self.lines.entry(path.clone()).or_insert(line);
                // Push maps and sequences separately (look at the event kind again).
                self.stack.push(Frame::Seq {
                    items: Vec::new(),
                    path,
                });
            }
            Event::SequenceEnd | Event::MappingEnd => {
                if let Some(frame) = self.stack.pop() {
                    let v = match frame {
                        Frame::Seq { items, .. } => Value::Array(items),
                        Frame::Map { map, .. } => Value::Object(map),
                    };
                    self.push_value(v, line);
                }
            }
            _ => {}
        }
    }
}

/// A thin receiver that filters events first, to tell a map start from a sequence start.
struct Router {
    inner: Builder,
}

impl MarkedEventReceiver for Router {
    fn on_event(&mut self, ev: Event, mark: Marker) {
        match ev {
            Event::MappingStart(anchor, tag) => {
                // After the Builder's common checks, turn the last frame into a map.
                let before = self.inner.stack.len();
                self.inner.on_event(Event::MappingStart(anchor, tag), mark);
                if self.inner.stack.len() == before + 1 {
                    if let Some(Frame::Seq { path, .. }) = self.inner.stack.pop() {
                        self.inner.stack.push(Frame::Map {
                            map: Map::new(),
                            key: None,
                            path,
                        });
                    }
                }
            }
            other => self.inner.on_event(other, mark),
        }
    }
}

/// Reads YAML text. An empty file is an empty map.
pub fn parse(src: &str) -> Result<Doc, YamlError> {
    let mut router = Router {
        inner: Builder {
            stack: Vec::new(),
            root: None,
            lines: HashMap::new(),
            error: None,
            documents: 0,
        },
    };
    let mut parser = Parser::new_from_str(src);
    if let Err(e) = parser.load(&mut router, true) {
        return Err(YamlError {
            line: e.marker().line(),
            message: crate::util::tr(
                &format!("YAML 형식 오류: {}", e.info()),
                &format!("YAML syntax error: {}", e.info()),
            ),
        });
    }
    let b = router.inner;
    if let Some(e) = b.error {
        return Err(e);
    }
    let mut lines = b.lines;
    lines.entry(String::new()).or_insert(1);
    Ok(Doc {
        value: b.root.unwrap_or(Value::Object(Map::new())),
        lines,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalars_and_structure() {
        let d = parse(
            "version: 1\nname: demo\nflag: true\nnothing: ~\nratio: 0.5\nver: 1.2.3\nquoted: \"42\"\nlist:\n  - a\n  - 2\nmap: { k: v }\n",
        )
        .unwrap();
        let v = &d.value;
        assert_eq!(v["version"], 1);
        assert_eq!(v["name"], "demo");
        assert_eq!(v["flag"], true);
        assert!(v["nothing"].is_null());
        assert_eq!(v["ratio"], 0.5);
        assert_eq!(v["ver"], "1.2.3");
        assert_eq!(v["quoted"], "42");
        assert_eq!(v["list"][1], 2);
        assert_eq!(v["map"]["k"], "v");
        assert_eq!(d.line_of("list[1]"), Some(10));
        assert_eq!(d.line_of("map.k"), Some(11));
        assert_eq!(d.line_of("name"), Some(2));
        assert_eq!(d.line_of("name.deeper.missing"), Some(2));
    }

    #[test]
    fn keeps_key_order() {
        let d = parse("nodes:\n  zeta: 1\n  alpha: 2\n  mid: 3\n").unwrap();
        let keys: Vec<&String> = d.value["nodes"].as_object().unwrap().keys().collect();
        assert_eq!(keys, ["zeta", "alpha", "mid"]);
    }

    #[test]
    fn rejects_dangerous_features() {
        assert!(parse("a: &x 1\nb: *x\n").is_err());
        assert!(parse("base: &b { k: 1 }\nother:\n  <<: *b\n").is_err());
        assert!(parse("a: !!str 1\n").is_err());
        assert!(parse("a: 1\n---\nb: 2\n").is_err());
        let e = parse("a: 1\na: 2\n").unwrap_err();
        assert_eq!(e.line, 2);
        assert!(parse("a: [1, 2\n").is_err());
    }

    #[test]
    fn empty_is_empty_map() {
        assert_eq!(parse("").unwrap().value, Value::Object(Map::new()));
        assert_eq!(
            parse("# only a comment\n").unwrap().value,
            Value::Object(Map::new())
        );
    }

    #[test]
    fn block_scalars() {
        let d = parse("run: |\n  echo one\n  echo two\n").unwrap();
        assert_eq!(d.value["run"], "echo one\necho two\n");
    }
}
