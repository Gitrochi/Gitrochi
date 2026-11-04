//! Enough TOML to read one table of Codex's `config.toml` into JSON: tables, array tables,
//! dotted and quoted keys, strings, arrays and inline tables. Other scalars are kept as their
//! raw text. Anything malformed ends the read with `None`; the caller then reports the entry
//! as unregistered rather than guessing.

use serde_json::{Map, Value};

struct Reader<'a> {
    text: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.get(self.at).copied()
    }

    fn starts_with(&self, prefix: &str) -> bool {
        self.text[self.at..].starts_with(prefix.as_bytes())
    }

    /// Spaces and tabs; with `lines`, also newlines and comments.
    fn skip(&mut self, lines: bool) {
        while let Some(c) = self.peek() {
            match c {
                b' ' | b'\t' | b'\r' => self.at += 1,
                b'\n' if lines => self.at += 1,
                b'#' => {
                    while self.peek().is_some_and(|c| c != b'\n') {
                        self.at += 1;
                    }
                }
                _ => break,
            }
        }
    }

    fn line_end(&mut self) -> Option<()> {
        self.skip(false);
        match self.peek() {
            None | Some(b'\n') => Some(()),
            _ => None,
        }
    }

    fn key(&mut self) -> Option<Vec<String>> {
        let mut parts = Vec::new();
        loop {
            self.skip(false);
            let part = match self.peek()? {
                b'"' | b'\'' => self.string()?,
                _ => {
                    let start = self.at;
                    while self
                        .peek()
                        .is_some_and(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
                    {
                        self.at += 1;
                    }
                    if start == self.at {
                        return None;
                    }
                    String::from_utf8(self.text[start..self.at].to_vec()).ok()?
                }
            };
            parts.push(part);
            self.skip(false);
            if self.peek() == Some(b'.') {
                self.at += 1;
            } else {
                return Some(parts);
            }
        }
    }

    fn string(&mut self) -> Option<String> {
        let quote = self.peek()?;
        let multi = if quote == b'"' {
            self.starts_with("\"\"\"")
        } else {
            self.starts_with("'''")
        };
        self.at += if multi { 3 } else { 1 };
        if multi && self.peek() == Some(b'\n') {
            self.at += 1;
        }
        let mut out = Vec::new();
        loop {
            let c = self.peek()?;
            if c == quote && (!multi || self.text[self.at..].starts_with(&[quote; 3])) {
                self.at += if multi { 3 } else { 1 };
                return String::from_utf8(out).ok();
            }
            if c == b'\n' && !multi {
                return None;
            }
            self.at += 1;
            if c == b'\\' && quote == b'"' {
                let escaped = self.peek()?;
                self.at += 1;
                match escaped {
                    b'n' => out.push(b'\n'),
                    b't' => out.push(b'\t'),
                    b'r' => out.push(b'\r'),
                    b'b' => out.push(8),
                    b'f' => out.push(12),
                    b'u' | b'U' => {
                        let width = if escaped == b'u' { 4 } else { 8 };
                        let digits =
                            std::str::from_utf8(self.text.get(self.at..self.at + width)?).ok()?;
                        let ch = char::from_u32(u32::from_str_radix(digits, 16).ok()?)?;
                        self.at += width;
                        out.extend_from_slice(ch.encode_utf8(&mut [0; 4]).as_bytes());
                    }
                    b'\n' | b' ' | b'\t' | b'\r' if multi => {
                        // A line-ending backslash trims the following whitespace.
                        while self.peek().is_some_and(|c| c.is_ascii_whitespace()) {
                            self.at += 1;
                        }
                    }
                    other => out.push(other),
                }
            } else {
                out.push(c);
            }
        }
    }

    fn value(&mut self) -> Option<Value> {
        self.skip(false);
        match self.peek()? {
            b'"' | b'\'' => self.string().map(Value::String),
            b'[' => {
                self.at += 1;
                let mut items = Vec::new();
                loop {
                    self.skip(true);
                    if self.peek()? == b']' {
                        self.at += 1;
                        return Some(Value::Array(items));
                    }
                    items.push(self.value()?);
                    self.skip(true);
                    match self.peek()? {
                        b',' => self.at += 1,
                        b']' => {}
                        _ => return None,
                    }
                }
            }
            b'{' => {
                self.at += 1;
                let mut table = Map::new();
                loop {
                    self.skip(false);
                    if self.peek()? == b'}' {
                        self.at += 1;
                        return Some(Value::Object(table));
                    }
                    let key = self.key()?;
                    self.skip(false);
                    if self.peek()? != b'=' {
                        return None;
                    }
                    self.at += 1;
                    let value = self.value()?;
                    insert(&mut table, &key, value)?;
                    self.skip(false);
                    match self.peek()? {
                        b',' => self.at += 1,
                        b'}' => {}
                        _ => return None,
                    }
                }
            }
            _ => {
                let start = self.at;
                while self
                    .peek()
                    .is_some_and(|c| !matches!(c, b',' | b']' | b'}' | b'\n' | b'#'))
                {
                    self.at += 1;
                }
                let raw = std::str::from_utf8(&self.text[start..self.at]).ok()?.trim();
                (!raw.is_empty()).then(|| Value::String(raw.to_string()))
            }
        }
    }
}

fn table<'a>(
    root: &'a mut Map<String, Value>,
    path: &[String],
) -> Option<&'a mut Map<String, Value>> {
    let mut current = root;
    for part in path {
        let next = current
            .entry(part.clone())
            .or_insert_with(|| Value::Object(Map::new()));
        // An array of tables continues in its newest element.
        let next = match next {
            Value::Array(items) => items.last_mut()?,
            other => other,
        };
        current = next.as_object_mut()?;
    }
    Some(current)
}

fn insert(target: &mut Map<String, Value>, key: &[String], value: Value) -> Option<()> {
    let (last, parents) = key.split_last()?;
    let target = table(target, parents)?;
    if target.contains_key(last) {
        return None;
    }
    target.insert(last.clone(), value);
    Some(())
}

/// The whole document as JSON, or `None` when any part of it cannot be read.
pub fn parse(text: &str) -> Option<Value> {
    let mut reader = Reader {
        text: text.as_bytes(),
        at: 0,
    };
    let mut root = Map::new();
    let mut current: Vec<String> = Vec::new();
    loop {
        reader.skip(true);
        let Some(c) = reader.peek() else {
            return Some(Value::Object(root));
        };
        if c == b'[' {
            let array = reader.starts_with("[[");
            reader.at += if array { 2 } else { 1 };
            let path = reader.key()?;
            reader.skip(false);
            if !reader.starts_with(if array { "]]" } else { "]" }) {
                return None;
            }
            reader.at += if array { 2 } else { 1 };
            reader.line_end()?;
            if array {
                let (last, parents) = path.split_last()?;
                let parent = table(&mut root, parents)?;
                let list = parent
                    .entry(last.clone())
                    .or_insert_with(|| Value::Array(Vec::new()));
                list.as_array_mut()?.push(Value::Object(Map::new()));
            } else {
                table(&mut root, &path)?;
            }
            current = path;
        } else {
            let key = reader.key()?;
            reader.skip(false);
            if reader.peek()? != b'=' {
                return None;
            }
            reader.at += 1;
            let value = reader.value()?;
            reader.line_end()?;
            insert(table(&mut root, &current)?, &key, value)?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_tables_strings_and_arrays_as_codex_writes_them() {
        let text = r#"
model = "example" # a comment
[projects."/Users/me/app"]
trust_level = "trusted"

[mcp_servers.gitrochi-ledger]
command = "/Users/me/Library/Application Support/Gitrochi/bin/gitrochi-ledger"
args = [
  "--db", '/tmp/a b.sqlite3', # the database
  "mcp",
]

[mcp_servers.gitrochi-ledger.env]
GITROCHI_LEDGER_DB = "C:\\Data\\ledger.sqlite3"

[[profiles.list]]
name = "one"
[[profiles.list]]
name = """two
lines"""
other = { a = 1, b = [true, false], c.d = "x" }
"#;
        let value = parse(text).unwrap();
        let server = &value["mcp_servers"]["gitrochi-ledger"];
        assert_eq!(
            server["command"],
            "/Users/me/Library/Application Support/Gitrochi/bin/gitrochi-ledger"
        );
        assert_eq!(server["args"], json!(["--db", "/tmp/a b.sqlite3", "mcp"]));
        assert_eq!(
            server["env"]["GITROCHI_LEDGER_DB"],
            "C:\\Data\\ledger.sqlite3"
        );
        assert_eq!(value["projects"]["/Users/me/app"]["trust_level"], "trusted");
        assert_eq!(value["profiles"]["list"][1]["name"], "two\nlines");
        assert_eq!(value["profiles"]["list"][1]["other"]["c"]["d"], "x");
        assert_eq!(value["model"], "example");
    }

    #[test]
    fn inline_and_dotted_entries_and_malformed_documents() {
        let value =
            parse("mcp_servers.gitrochi-ledger = { command = 'x', args = [\"mcp\"] }\n").unwrap();
        assert_eq!(value["mcp_servers"]["gitrochi-ledger"]["command"], "x");
        assert!(parse("[mcp_servers\ncommand = 1").is_none());
        assert!(parse("a = \"unterminated\n").is_none());
        assert!(parse("a = 1\na = 2\n").is_none());
    }
}
