//! `${{ … }}` expressions and `if:` conditions: value references and a few functions, never arbitrary code.
//! Values placed in a command (`run:`) are shell-quoted, so they cannot inject.

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct ExprError(pub String);

/// Values an expression can read. A path is a dotted name like `git.sha` split into words.
pub trait Ctx {
    fn lookup(&self, path: &[String]) -> Option<Value>;
    /// `hashFiles('glob', …)`: hash of the matching tracked files' contents; None when unknown.
    fn hash_files(&self, _globs: &[String]) -> Option<String> {
        None
    }
}

/// An empty context, for checking syntax without values.
pub struct NoCtx;
impl Ctx for NoCtx {
    fn lookup(&self, _path: &[String]) -> Option<Value> {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Quote {
    None,
    Shell,
    Pwsh,
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Ident(String),
    Str(String),
    Num(f64),
    Dot,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Comma,
    And,
    Or,
    Not,
    Eq,
    Ne,
}

fn lex(src: &str) -> Result<Vec<Tok>, ExprError> {
    let c: Vec<char> = src.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while i < c.len() {
        let ch = c[i];
        if ch.is_whitespace() {
            i += 1;
            continue;
        }
        match ch {
            '.' => out.push(Tok::Dot),
            '(' => out.push(Tok::LParen),
            ')' => out.push(Tok::RParen),
            '[' => out.push(Tok::LBracket),
            ']' => out.push(Tok::RBracket),
            ',' => out.push(Tok::Comma),
            '&' if c.get(i + 1) == Some(&'&') => {
                out.push(Tok::And);
                i += 1;
            }
            '|' if c.get(i + 1) == Some(&'|') => {
                out.push(Tok::Or);
                i += 1;
            }
            '=' if c.get(i + 1) == Some(&'=') => {
                out.push(Tok::Eq);
                i += 1;
            }
            '!' if c.get(i + 1) == Some(&'=') => {
                out.push(Tok::Ne);
                i += 1;
            }
            '!' => out.push(Tok::Not),
            '\'' => {
                let mut s = String::new();
                i += 1;
                loop {
                    if i >= c.len() {
                        return Err(ExprError("unterminated string".into()));
                    }
                    if c[i] == '\'' {
                        if c.get(i + 1) == Some(&'\'') {
                            s.push('\'');
                            i += 2;
                            continue;
                        }
                        break;
                    }
                    s.push(c[i]);
                    i += 1;
                }
                out.push(Tok::Str(s));
            }
            _ if ch.is_ascii_digit() => {
                let start = i;
                while i < c.len() && (c[i].is_ascii_digit() || c[i] == '.') {
                    i += 1;
                }
                let t: String = c[start..i].iter().collect();
                out.push(Tok::Num(
                    t.parse()
                        .map_err(|_| ExprError(format!("bad number {t}")))?,
                ));
                continue;
            }
            _ if ch.is_ascii_alphabetic() || ch == '_' => {
                let start = i;
                while i < c.len() && (c[i].is_ascii_alphanumeric() || c[i] == '_' || c[i] == '-') {
                    i += 1;
                }
                out.push(Tok::Ident(c[start..i].iter().collect()));
                continue;
            }
            _ => return Err(ExprError(format!("unexpected character '{ch}'"))),
        }
        i += 1;
    }
    Ok(out)
}

/// Expression tree.
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    Lit(Value),
    Path(Vec<String>),
    Call(String, Vec<Node>),
    Not(Box<Node>),
    And(Box<Node>, Box<Node>),
    Or(Box<Node>, Box<Node>),
    Eq(Box<Node>, Box<Node>, bool),
}

struct P {
    t: Vec<Tok>,
    i: usize,
}

impl P {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    fn next(&mut self) -> Option<Tok> {
        let v = self.t.get(self.i).cloned();
        self.i += 1;
        v
    }
    fn expect(&mut self, want: Tok) -> Result<(), ExprError> {
        match self.next() {
            Some(t) if t == want => Ok(()),
            other => Err(ExprError(format!("expected {want:?}, found {other:?}"))),
        }
    }
    fn or(&mut self) -> Result<Node, ExprError> {
        let mut l = self.and()?;
        while self.peek() == Some(&Tok::Or) {
            self.i += 1;
            let r = self.and()?;
            l = Node::Or(Box::new(l), Box::new(r));
        }
        Ok(l)
    }
    fn and(&mut self) -> Result<Node, ExprError> {
        let mut l = self.cmp()?;
        while self.peek() == Some(&Tok::And) {
            self.i += 1;
            let r = self.cmp()?;
            l = Node::And(Box::new(l), Box::new(r));
        }
        Ok(l)
    }
    fn cmp(&mut self) -> Result<Node, ExprError> {
        let l = self.unary()?;
        match self.peek() {
            Some(Tok::Eq) => {
                self.i += 1;
                let r = self.unary()?;
                Ok(Node::Eq(Box::new(l), Box::new(r), true))
            }
            Some(Tok::Ne) => {
                self.i += 1;
                let r = self.unary()?;
                Ok(Node::Eq(Box::new(l), Box::new(r), false))
            }
            _ => Ok(l),
        }
    }
    fn unary(&mut self) -> Result<Node, ExprError> {
        if self.peek() == Some(&Tok::Not) {
            self.i += 1;
            return Ok(Node::Not(Box::new(self.unary()?)));
        }
        self.primary()
    }
    fn primary(&mut self) -> Result<Node, ExprError> {
        match self.next() {
            Some(Tok::LParen) => {
                let e = self.or()?;
                self.expect(Tok::RParen)?;
                Ok(e)
            }
            Some(Tok::Str(s)) => Ok(Node::Lit(Value::String(s))),
            Some(Tok::Num(n)) => Ok(Node::Lit(
                serde_json::Number::from_f64(n)
                    .map(|x| {
                        if n.fract() == 0.0 && n.abs() < 9e15 {
                            Value::Number((n as i64).into())
                        } else {
                            Value::Number(x)
                        }
                    })
                    .unwrap_or(Value::Null),
            )),
            Some(Tok::Ident(id)) => {
                match id.as_str() {
                    "true" => return Ok(Node::Lit(Value::Bool(true))),
                    "false" => return Ok(Node::Lit(Value::Bool(false))),
                    "null" => return Ok(Node::Lit(Value::Null)),
                    _ => {}
                }
                if self.peek() == Some(&Tok::LParen) {
                    self.i += 1;
                    let mut args = Vec::new();
                    if self.peek() != Some(&Tok::RParen) {
                        loop {
                            args.push(self.or()?);
                            if self.peek() == Some(&Tok::Comma) {
                                self.i += 1;
                                continue;
                            }
                            break;
                        }
                    }
                    self.expect(Tok::RParen)?;
                    return Ok(Node::Call(id, args));
                }
                let mut path = vec![id];
                loop {
                    match self.peek() {
                        Some(Tok::Dot) => {
                            self.i += 1;
                            match self.next() {
                                Some(Tok::Ident(s)) => path.push(s),
                                Some(Tok::Num(n)) => path.push(format!("{}", n as i64)),
                                other => {
                                    return Err(ExprError(format!(
                                        "expected a name after '.', found {other:?}"
                                    )))
                                }
                            }
                        }
                        Some(Tok::LBracket) => {
                            self.i += 1;
                            match self.next() {
                                Some(Tok::Num(n)) => path.push(format!("{}", n as i64)),
                                Some(Tok::Str(s)) => path.push(s),
                                other => {
                                    return Err(ExprError(format!(
                                        "expected an index, found {other:?}"
                                    )))
                                }
                            }
                            self.expect(Tok::RBracket)?;
                        }
                        _ => break,
                    }
                }
                Ok(Node::Path(path))
            }
            other => Err(ExprError(format!("unexpected {other:?}"))),
        }
    }
}

pub fn parse(src: &str) -> Result<Node, ExprError> {
    let mut p = P { t: lex(src)?, i: 0 };
    if p.t.is_empty() {
        return Err(ExprError("empty expression".into()));
    }
    let n = p.or()?;
    if p.i != p.t.len() {
        return Err(ExprError(format!("unexpected trailing {:?}", p.t[p.i])));
    }
    Ok(n)
}

const FUNCS: &[&str] = &[
    "default",
    "hashFiles",
    "toJSON",
    "contains",
    "startsWith",
    "format",
];
/// Status functions, only for `if:`.
pub const STATUS_FUNCS: &[&str] = &["success", "failure", "always", "cancelled", "changed"];
/// The top-level names an expression may read.
pub const ROOTS: &[&str] = &[
    "git", "run", "node", "inputs", "services", "env", "matrix", "nodes", "secrets", "flow",
    "project",
];

/// Checks syntax and names and returns the referenced paths (for validation).
pub fn references(
    n: &Node,
    out: &mut Vec<Vec<String>>,
    allow_status: bool,
) -> Result<(), ExprError> {
    match n {
        Node::Lit(_) => Ok(()),
        Node::Path(p) => {
            if !ROOTS.contains(&p[0].as_str()) {
                return Err(ExprError(format!("unknown name '{}'", p[0])));
            }
            out.push(p.clone());
            Ok(())
        }
        Node::Call(f, args) => {
            let ok =
                FUNCS.contains(&f.as_str()) || (allow_status && STATUS_FUNCS.contains(&f.as_str()));
            if !ok {
                return Err(ExprError(format!("unknown function '{f}'")));
            }
            for a in args {
                references(a, out, allow_status)?;
            }
            Ok(())
        }
        Node::Not(a) => references(a, out, allow_status),
        Node::And(a, b) | Node::Or(a, b) | Node::Eq(a, b, _) => {
            references(a, out, allow_status)?;
            references(b, out, allow_status)
        }
    }
}

pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

pub fn to_text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        other => other.to_string(),
    }
}

/// Status functions are answered by the context (only when evaluating conditions).
pub trait StatusCtx {
    fn status(&self, func: &str, args: &[String]) -> Option<bool>;
}

struct NoStatus;
impl StatusCtx for NoStatus {
    fn status(&self, _f: &str, _a: &[String]) -> Option<bool> {
        None
    }
}

pub fn eval_node(n: &Node, ctx: &dyn Ctx, st: &dyn StatusCtx) -> Result<Value, ExprError> {
    match n {
        Node::Lit(v) => Ok(v.clone()),
        Node::Path(p) => Ok(ctx.lookup(p).unwrap_or(Value::Null)),
        Node::Not(a) => Ok(Value::Bool(!truthy(&eval_node(a, ctx, st)?))),
        Node::And(a, b) => {
            let l = eval_node(a, ctx, st)?;
            if !truthy(&l) {
                return Ok(l);
            }
            eval_node(b, ctx, st)
        }
        Node::Or(a, b) => {
            let l = eval_node(a, ctx, st)?;
            if truthy(&l) {
                return Ok(l);
            }
            eval_node(b, ctx, st)
        }
        Node::Eq(a, b, want) => {
            let l = eval_node(a, ctx, st)?;
            let r = eval_node(b, ctx, st)?;
            let same = l == r || to_text(&l) == to_text(&r);
            Ok(Value::Bool(same == *want))
        }
        Node::Call(f, args) => {
            if STATUS_FUNCS.contains(&f.as_str()) {
                let texts: Vec<String> = args
                    .iter()
                    .map(|a| eval_node(a, ctx, st).map(|v| to_text(&v)))
                    .collect::<Result<_, _>>()?;
                return st
                    .status(f, &texts)
                    .map(Value::Bool)
                    .ok_or_else(|| ExprError(format!("{f}() can only be used in if:")));
            }
            let vals: Vec<Value> = args
                .iter()
                .map(|a| eval_node(a, ctx, st))
                .collect::<Result<_, _>>()?;
            match f.as_str() {
                "default" => Ok(vals
                    .iter()
                    .find(|v| !v.is_null() && !to_text(v).is_empty())
                    .cloned()
                    .unwrap_or(Value::Null)),
                "toJSON" => Ok(Value::String(
                    vals.first().cloned().unwrap_or(Value::Null).to_string(),
                )),
                "contains" => {
                    let hay = vals.first().cloned().unwrap_or(Value::Null);
                    let needle = to_text(vals.get(1).unwrap_or(&Value::Null));
                    Ok(Value::Bool(match hay {
                        Value::Array(a) => a.iter().any(|x| to_text(x) == needle),
                        other => to_text(&other).contains(&needle),
                    }))
                }
                "startsWith" => Ok(Value::Bool(
                    to_text(vals.first().unwrap_or(&Value::Null))
                        .starts_with(&to_text(vals.get(1).unwrap_or(&Value::Null))),
                )),
                "format" => {
                    let mut s = to_text(vals.first().unwrap_or(&Value::Null));
                    for (i, v) in vals.iter().skip(1).enumerate() {
                        s = s.replace(&format!("{{{i}}}"), &to_text(v));
                    }
                    Ok(Value::String(s))
                }
                "hashFiles" => {
                    let globs: Vec<String> = vals.iter().map(to_text).collect();
                    Ok(ctx
                        .hash_files(&globs)
                        .map(Value::String)
                        .unwrap_or(Value::Null))
                }
                _ => Err(ExprError(format!("unknown function '{f}'"))),
            }
        }
    }
}

pub fn eval(src: &str, ctx: &dyn Ctx) -> Result<Value, ExprError> {
    eval_node(&parse(src)?, ctx, &NoStatus)
}

/// Positions of `${{ … }}` in text (start, end, inner text).
pub fn find(s: &str) -> Result<Vec<(usize, usize, String)>, ExprError> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(off) = s[i..].find("${{") {
        let start = i + off;
        let Some(end_off) = s[start + 3..].find("}}") else {
            return Err(ExprError("missing '}}'".into()));
        };
        let end = start + 3 + end_off + 2;
        out.push((start, end, s[start + 3..end - 2].trim().to_string()));
        i = end;
    }
    Ok(out)
}

/// Replaces the expressions in text with their values. For a shell or PowerShell each value is quoted as one argument.
pub fn render(s: &str, ctx: &dyn Ctx, quote: Quote) -> Result<String, ExprError> {
    let spans = find(s)?;
    if spans.is_empty() {
        return Ok(s.to_string());
    }
    let mut out = String::new();
    let mut last = 0;
    for (a, b, inner) in spans {
        out.push_str(&s[last..a]);
        let text = to_text(&eval(&inner, ctx)?);
        out.push_str(&match quote {
            Quote::None => text,
            Quote::Shell => crate::util::shell_quote(&text),
            Quote::Pwsh => crate::util::pwsh_quote(&text),
        });
        last = b;
    }
    out.push_str(&s[last..]);
    Ok(out)
}

/// Renders the text inside a JSON value. When the whole text is one expression, its value keeps its type (number and so on).
pub fn render_value(v: &Value, ctx: &dyn Ctx) -> Result<Value, ExprError> {
    match v {
        Value::String(s) => {
            let spans = find(s)?;
            if spans.len() == 1 && spans[0].0 == 0 && spans[0].1 == s.len() {
                return eval(&spans[0].2, ctx);
            }
            Ok(Value::String(render(s, ctx, Quote::None)?))
        }
        Value::Array(a) => Ok(Value::Array(
            a.iter()
                .map(|x| render_value(x, ctx))
                .collect::<Result<_, _>>()?,
        )),
        Value::Object(o) => {
            let mut m = serde_json::Map::new();
            for (k, x) in o {
                m.insert(k.clone(), render_value(x, ctx)?);
            }
            Ok(Value::Object(m))
        }
        other => Ok(other.clone()),
    }
}

/// An `if:` condition. Without a status function it reads as `success() && …`, as in GitHub Actions.
#[derive(Debug, Clone)]
pub struct Cond {
    pub node: Node,
    pub has_status: bool,
}

fn has_status(n: &Node) -> bool {
    match n {
        Node::Call(f, args) => {
            (STATUS_FUNCS.contains(&f.as_str()) && f != "changed") || args.iter().any(has_status)
        }
        Node::Not(a) => has_status(a),
        Node::And(a, b) | Node::Or(a, b) | Node::Eq(a, b, _) => has_status(a) || has_status(b),
        _ => false,
    }
}

pub fn parse_cond(src: &str) -> Result<Cond, ExprError> {
    let s = src.trim();
    let s = s
        .strip_prefix("${{")
        .and_then(|x| x.strip_suffix("}}"))
        .unwrap_or(s);
    let node = parse(s)?;
    let mut refs = Vec::new();
    references(&node, &mut refs, true)?;
    Ok(Cond {
        has_status: has_status(&node),
        node,
    })
}

pub fn eval_cond(c: &Cond, ctx: &dyn Ctx, st: &dyn StatusCtx) -> Result<bool, ExprError> {
    let v = truthy(&eval_node(&c.node, ctx, st)?);
    if c.has_status {
        Ok(v)
    } else {
        Ok(v && st.status("success", &[]).unwrap_or(true))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct C(Value);
    impl Ctx for C {
        fn lookup(&self, path: &[String]) -> Option<Value> {
            let mut v = &self.0;
            for p in path {
                v = match v {
                    Value::Object(o) => o.get(p)?,
                    Value::Array(a) => a.get(p.parse::<usize>().ok()?)?,
                    _ => return None,
                };
            }
            Some(v.clone())
        }
    }

    fn ctx() -> C {
        C(
            json!({"git": {"sha": "abc123", "branch": "feat/x"}, "inputs": {"port": 8080, "name": "a b"}, "services": {"api": {"port": 4100}}}),
        )
    }

    #[test]
    fn renders_plain_and_quoted() {
        let c = ctx();
        assert_eq!(
            render("v=${{ git.sha }}", &c, Quote::None).unwrap(),
            "v=abc123"
        );
        assert_eq!(
            render("echo ${{ inputs.name }}", &c, Quote::Shell).unwrap(),
            "echo 'a b'"
        );
        assert_eq!(
            render("${{ inputs.port }}", &c, Quote::None).unwrap(),
            "8080"
        );
        assert_eq!(
            render_value(&json!("${{ inputs.port }}"), &c).unwrap(),
            json!(8080)
        );
        assert_eq!(
            render_value(
                &json!({"u": "http://127.0.0.1:${{ services.api.port }}/h"}),
                &c
            )
            .unwrap(),
            json!({"u": "http://127.0.0.1:4100/h"})
        );
        assert_eq!(
            render(
                "x ${{ default(inputs.missing, 'fallback') }}",
                &c,
                Quote::None
            )
            .unwrap(),
            "x fallback"
        );
    }

    #[test]
    fn injection_is_quoted() {
        let c = C(json!({"inputs": {"evil": "x; rm -rf / #"}}));
        assert_eq!(
            render("echo ${{ inputs.evil }}", &c, Quote::Shell).unwrap(),
            "echo 'x; rm -rf / #'"
        );
        let c2 = C(json!({"inputs": {"evil": "a'b"}}));
        assert_eq!(
            render("echo ${{ inputs.evil }}", &c2, Quote::Shell).unwrap(),
            "echo 'a'\\''b'"
        );
    }

    #[test]
    fn syntax_errors() {
        assert!(parse("git.").is_err());
        assert!(parse("foo bar").is_err());
        assert!(find("${{ git.sha").is_err());
        let mut refs = Vec::new();
        assert!(references(&parse("bogus.x").unwrap(), &mut refs, false).is_err());
        assert!(references(&parse("system('x')").unwrap(), &mut refs, false).is_err());
        assert!(references(&parse("success()").unwrap(), &mut refs, false).is_err());
        assert!(references(&parse("success()").unwrap(), &mut refs, true).is_ok());
    }

    struct S {
        failed: bool,
    }
    impl StatusCtx for S {
        fn status(&self, f: &str, _a: &[String]) -> Option<bool> {
            Some(match f {
                "success" => !self.failed,
                "failure" => self.failed,
                "always" => true,
                "cancelled" => false,
                "changed" => true,
                _ => return None,
            })
        }
    }

    #[test]
    fn conditions() {
        let c = ctx();
        let ok = S { failed: false };
        let bad = S { failed: true };
        let always = parse_cond("always()").unwrap();
        assert!(eval_cond(&always, &c, &bad).unwrap());
        let fail = parse_cond("${{ failure() }}").unwrap();
        assert!(eval_cond(&fail, &c, &bad).unwrap());
        assert!(!eval_cond(&fail, &c, &ok).unwrap());
        // a condition without a status function gets success()
        let br = parse_cond("git.branch == 'feat/x'").unwrap();
        assert!(eval_cond(&br, &c, &ok).unwrap());
        assert!(!eval_cond(&br, &c, &bad).unwrap());
        let changed = parse_cond("changed('src/**')").unwrap();
        assert!(!changed.has_status);
        assert!(eval_cond(&changed, &c, &ok).unwrap());
        let not = parse_cond("!cancelled() && (success() || failure())").unwrap();
        assert!(eval_cond(&not, &c, &bad).unwrap());
    }
}
