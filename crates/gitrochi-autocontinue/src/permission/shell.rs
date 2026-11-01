//! A tokenizer for the commands agents run: POSIX shell (the Bash tool) and a strict
//! subset of PowerShell. It splits a command line into simple commands joined by `&&`,
//! `||`, `;`, `|` and newlines, with quotes, escapes, redirections and here-documents
//! resolved. Anything whose meaning depends on running code first — command substitution,
//! backticks, process substitution, functions, PowerShell expressions — is `Unclear`, and
//! the caller holds the request for the person.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Dialect {
    Posix,
    PowerShell,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Word {
    /// The text with quotes removed; expansions stay as written (`$HOME/x`).
    pub text: String,
    /// Holds a variable or another value only known when the command runs.
    pub dynamic: bool,
    /// Holds an unquoted `*`, `?`, `[` or brace expansion.
    pub glob: bool,
    /// Starts with an unquoted `~`.
    pub tilde: bool,
    pub quoted: bool,
    /// Byte offset of the `=` of a leading `NAME=` assignment.
    assign: Option<usize>,
}

impl Word {
    pub(crate) fn plain(text: &str) -> Self {
        Self {
            text: text.to_string(),
            ..Self::default()
        }
    }

    /// The same kind of word with other text, such as the value part of `--out=FILE`.
    pub(crate) fn with_text(&self, text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            assign: None,
            ..self.clone()
        }
    }

    pub(crate) fn literal(&self) -> Option<&str> {
        (!self.dynamic).then_some(self.text.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Link {
    First,
    And,
    Or,
    Then,
    Pipe,
    Background,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Redirect {
    /// `>`, `>>`, `&>`, `2>`, `<>` …: the command writes the target.
    Write(Word),
    Read(Word),
    /// `<<`: the command reads this text.
    Heredoc {
        body: String,
        literal: bool,
    },
    HereString(Word),
    /// `2>&1`, `>&2` …
    Dup,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Command {
    pub link: Link,
    pub assigns: Vec<(String, Word)>,
    pub words: Vec<Word>,
    pub redirects: Vec<Redirect>,
    /// A `for x in …` or `select` header: its words are not a command.
    pub header: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Item {
    Command(Command),
    /// `(` … `)`: a subshell, whose `cd` does not outlive it.
    Open,
    Close,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Unclear {
    CommandSubstitution,
    Backtick,
    ProcessSubstitution,
    Arithmetic,
    AnsiQuote,
    Unclosed,
    Heredoc,
    Function,
    Case,
    /// PowerShell expressions, script blocks, the call operator and the like.
    Expression,
    /// PowerShell's backtick escape.
    Escape,
}

impl Unclear {
    pub(crate) fn describe(self) -> &'static str {
        match self {
            Self::CommandSubstitution => "uses command substitution `$( )`",
            Self::Backtick => "uses backtick command substitution",
            Self::ProcessSubstitution => "uses process substitution `<( )`",
            Self::Arithmetic => "uses arithmetic expansion",
            Self::AnsiQuote => "uses `$'…'` quoting",
            Self::Unclosed => "has an unclosed quote or bracket",
            Self::Heredoc => "has a here-document that is not closed or expands commands",
            Self::Function => "defines a function",
            Self::Case => "uses a `case` statement",
            Self::Expression => "uses a PowerShell expression or script block",
            Self::Escape => "uses PowerShell's backtick escape",
        }
    }
}

pub(crate) fn parse(source: &str, dialect: Dialect) -> Result<Vec<Item>, Unclear> {
    let chars: Vec<char> = source.chars().collect();
    let mut parser = Parser::new(&chars, 0, dialect, false);
    parser.run()?;
    Ok(parser.items)
}

#[derive(Default)]
struct Builder {
    assigns: Vec<(String, Word)>,
    words: Vec<Word>,
    redirects: Vec<Redirect>,
    header: bool,
}

impl Builder {
    fn is_empty(&self) -> bool {
        self.assigns.is_empty()
            && self.words.is_empty()
            && self.redirects.is_empty()
            && !self.header
    }
}

struct Pending {
    delimiter: String,
    literal: bool,
    strip_tabs: bool,
    item: usize,
    redirect: usize,
}

struct Parser<'a> {
    s: &'a [char],
    i: usize,
    dialect: Dialect,
    /// Inside `$( )`: an unmatched `)` ends the parse.
    nested: bool,
    items: Vec<Item>,
    cur: Builder,
    link: Link,
    /// Here-documents of the current line, read at the next newline. Before that they
    /// point at the builder (item == usize::MAX).
    pending: Vec<Pending>,
    depth: usize,
}

const CURRENT: usize = usize::MAX;

impl<'a> Parser<'a> {
    fn new(s: &'a [char], start: usize, dialect: Dialect, nested: bool) -> Self {
        Self {
            s,
            i: start,
            dialect,
            nested,
            items: Vec::new(),
            cur: Builder::default(),
            link: Link::First,
            pending: Vec::new(),
            depth: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.s.get(self.i).copied()
    }

    fn at(&self, offset: usize) -> Option<char> {
        self.s.get(self.i + offset).copied()
    }

    fn posix(&self) -> bool {
        self.dialect == Dialect::Posix
    }

    fn run(&mut self) -> Result<(), Unclear> {
        loop {
            self.skip_blanks();
            let Some(c) = self.peek() else { break };
            match c {
                '\n' => {
                    self.i += 1;
                    self.end_command(Link::Then);
                    self.read_heredocs()?;
                }
                ';' => {
                    if self.posix() && self.at(1) == Some(';') {
                        return Err(Unclear::Case);
                    }
                    self.i += 1;
                    self.end_command(Link::Then);
                }
                '&' => {
                    if self.at(1) == Some('&') {
                        self.i += 2;
                        self.end_command(Link::And);
                    } else if self.posix() && self.at(1) == Some('>') {
                        self.redirect(false)?;
                    } else if self.posix() {
                        self.i += 1;
                        self.end_command(Link::Background);
                    } else {
                        // the call operator and background jobs run what we cannot see
                        return Err(Unclear::Expression);
                    }
                }
                '|' => {
                    if self.at(1) == Some('|') {
                        self.i += 2;
                        self.end_command(Link::Or);
                    } else {
                        self.i += if self.posix() && self.at(1) == Some('&') {
                            2
                        } else {
                            1
                        };
                        self.end_command(Link::Pipe);
                    }
                }
                '(' => {
                    if !self.posix() {
                        return Err(Unclear::Expression);
                    }
                    if !self.cur.words.is_empty() || !self.cur.assigns.is_empty() {
                        // `name()` or `name (`: a function definition
                        return Err(Unclear::Function);
                    }
                    self.i += 1;
                    self.depth += 1;
                    self.items.push(Item::Open);
                }
                ')' => {
                    if !self.posix() {
                        return Err(Unclear::Expression);
                    }
                    self.end_command(Link::Then);
                    if self.depth == 0 {
                        if self.nested {
                            return if self.pending.is_empty() {
                                Ok(())
                            } else {
                                Err(Unclear::Heredoc)
                            };
                        }
                        return Err(Unclear::Unclosed);
                    }
                    self.depth -= 1;
                    self.i += 1;
                    self.items.push(Item::Close);
                }
                '{' | '}' | '@' if !self.posix() => return Err(Unclear::Expression),
                '<' | '>' => self.redirect(false)?,
                '#' => {
                    if !self.posix() && self.at(1) == Some('>') {
                        return Err(Unclear::Expression);
                    }
                    while self.peek().is_some_and(|c| c != '\n') {
                        self.i += 1;
                    }
                }
                '*' if !self.posix() && self.at(1) == Some('>') => self.redirect(true)?,
                _ => {
                    if c.is_ascii_digit() {
                        let digits = self.s[self.i..]
                            .iter()
                            .take_while(|c| c.is_ascii_digit())
                            .count();
                        if matches!(self.at(digits), Some('<' | '>')) {
                            self.i += digits;
                            self.redirect(true)?;
                            continue;
                        }
                    }
                    let word = self.word()?;
                    self.add_word(word)?;
                }
            }
        }
        if self.nested {
            return Err(Unclear::Unclosed);
        }
        self.end_command(Link::Then);
        if !self.pending.is_empty() {
            return Err(Unclear::Heredoc);
        }
        if self.depth != 0 {
            return Err(Unclear::Unclosed);
        }
        Ok(())
    }

    fn skip_blanks(&mut self) {
        while let Some(c) = self.peek() {
            if c == ' ' || c == '\t' || c == '\r' {
                self.i += 1;
            } else if self.posix() && c == '\\' && self.at(1) == Some('\n') {
                self.i += 2;
            } else {
                break;
            }
        }
    }

    fn end_command(&mut self, next: Link) {
        if self.cur.is_empty() {
            // a newline after `a &&` keeps the `&&`
            if next != Link::Then {
                self.link = next;
            }
            return;
        }
        let built = std::mem::take(&mut self.cur);
        let index = self.items.len();
        for p in &mut self.pending {
            if p.item == CURRENT {
                p.item = index;
            }
        }
        self.items.push(Item::Command(Command {
            link: self.link,
            assigns: built.assigns,
            words: built.words,
            redirects: built.redirects,
            header: built.header,
        }));
        self.link = next;
    }

    fn add_word(&mut self, word: Word) -> Result<(), Unclear> {
        let first = self.cur.words.is_empty() && self.cur.assigns.is_empty();
        if self.posix() {
            // assignments continue until the command name: `A=1 B=2 cmd`
            if self.cur.words.is_empty() && !self.cur.header {
                if let Some(eq) = word.assign {
                    let name = word.text[..eq].trim_end_matches('+').to_string();
                    let value = Word {
                        text: word.text[eq + 1..].to_string(),
                        assign: None,
                        ..word
                    };
                    self.cur.assigns.push((name, value));
                    return Ok(());
                }
            }
            if first && !word.quoted && !word.dynamic {
                match word.text.as_str() {
                    "if" | "then" | "else" | "elif" | "fi" | "do" | "done" | "while" | "until"
                    | "!" | "{" | "}" | "time" => return Ok(()),
                    "for" | "select" => {
                        self.cur.header = true;
                        return Ok(());
                    }
                    "case" | "esac" => return Err(Unclear::Case),
                    "function" => return Err(Unclear::Function),
                    _ => {}
                }
            }
        } else if first {
            if word.text.starts_with('$') || word.text == "." {
                // assignments, expressions and dot-sourcing
                return Err(Unclear::Expression);
            }
            if !word.quoted {
                const KEYWORDS: &[&str] = &[
                    "if", "elseif", "else", "foreach", "for", "while", "do", "until", "switch",
                    "function", "filter", "try", "catch", "finally", "trap", "param", "begin",
                    "process", "end", "class", "enum", "workflow", "data", "return", "throw",
                    "break", "continue", "exit",
                ];
                if KEYWORDS.contains(&word.text.to_lowercase().as_str()) {
                    return Err(Unclear::Expression);
                }
            }
        }
        if !self.posix() && word.text == "--%" {
            return Err(Unclear::Expression);
        }
        self.cur.words.push(word);
        Ok(())
    }

    fn word(&mut self) -> Result<Word, Unclear> {
        if self.posix() {
            self.posix_word()
        } else {
            self.powershell_word()
        }
    }

    fn posix_word(&mut self) -> Result<Word, Unclear> {
        let mut w = Word::default();
        // a leading NAME= is an assignment while every char so far is a name char
        let mut name_ok = true;
        let mut brace = false;
        while let Some(c) = self.peek() {
            match c {
                ' ' | '\t' | '\r' | '\n' | ';' | '&' | '|' | '<' | '>' | '(' | ')' => break,
                '\\' => {
                    match self.at(1) {
                        Some('\n') => {}
                        Some(n) => {
                            w.text.push(n);
                            w.quoted = true;
                        }
                        None => {}
                    }
                    self.i += 2;
                    name_ok = false;
                }
                '\'' => {
                    self.i += 1;
                    loop {
                        match self.peek() {
                            None => return Err(Unclear::Unclosed),
                            Some('\'') => {
                                self.i += 1;
                                break;
                            }
                            Some(ch) => {
                                w.text.push(ch);
                                self.i += 1;
                            }
                        }
                    }
                    w.quoted = true;
                    name_ok = false;
                }
                '"' => {
                    self.i += 1;
                    self.double_quoted(&mut w)?;
                    w.quoted = true;
                    name_ok = false;
                }
                '`' => return Err(Unclear::Backtick),
                '$' => {
                    self.dollar(&mut w, false)?;
                    name_ok = false;
                }
                '=' if name_ok && w.assign.is_none() && valid_name(&w.text) => {
                    w.assign = Some(w.text.len());
                    w.text.push('=');
                    self.i += 1;
                }
                _ => {
                    match c {
                        '*' | '?' | '[' => w.glob = true,
                        '{' => brace = true,
                        '~' if w.text.is_empty() && !w.quoted => w.tilde = true,
                        _ => {}
                    }
                    if w.assign.is_none() && !(c.is_ascii_alphanumeric() || c == '_' || c == '+') {
                        name_ok = false;
                    }
                    w.text.push(c);
                    self.i += 1;
                }
            }
        }
        if brace && (w.text.contains(',') || w.text.contains("..")) {
            w.glob = true;
        }
        Ok(w)
    }

    fn double_quoted(&mut self, w: &mut Word) -> Result<(), Unclear> {
        loop {
            match self.peek() {
                None => return Err(Unclear::Unclosed),
                Some('"') => {
                    self.i += 1;
                    return Ok(());
                }
                Some('\\') => {
                    match self.at(1) {
                        Some(c @ ('"' | '\\' | '$' | '`')) => w.text.push(c),
                        Some('\n') => {}
                        Some(c) => {
                            w.text.push('\\');
                            w.text.push(c);
                        }
                        None => return Err(Unclear::Unclosed),
                    }
                    self.i += 2;
                }
                Some('`') => return Err(Unclear::Backtick),
                Some('$') => self.dollar(w, true)?,
                Some(c) => {
                    w.text.push(c);
                    self.i += 1;
                }
            }
        }
    }

    /// `$…` in POSIX: parameters make the word dynamic; a command substitution is allowed
    /// only when it is a literal here-document (`"$(cat <<'EOF' … EOF)"`, the usual way
    /// agents pass commit messages), whose value is known.
    fn dollar(&mut self, w: &mut Word, in_double: bool) -> Result<(), Unclear> {
        match self.at(1) {
            Some('(') => {
                if self.at(2) == Some('(') {
                    return Err(Unclear::Arithmetic);
                }
                let mut inner = Parser::new(self.s, self.i + 2, self.dialect, true);
                inner.run()?;
                let value =
                    literal_substitution(&inner.items).ok_or(Unclear::CommandSubstitution)?;
                self.i = inner.i + 1;
                w.text.push_str(&value);
            }
            Some('{') => {
                let start = self.i;
                let mut j = self.i + 2;
                while j < self.s.len() && self.s[j] != '}' {
                    if self.s[j] == '`' || (self.s[j] == '$' && self.s.get(j + 1) == Some(&'(')) {
                        return Err(Unclear::CommandSubstitution);
                    }
                    j += 1;
                }
                if j >= self.s.len() {
                    return Err(Unclear::Unclosed);
                }
                w.text.extend(&self.s[start..=j]);
                w.dynamic = true;
                self.i = j + 1;
            }
            Some('\'') if !in_double => return Err(Unclear::AnsiQuote),
            Some('"') if !in_double => {
                self.i += 2;
                self.double_quoted(w)?;
                w.quoted = true;
            }
            Some(c) if c.is_ascii_alphabetic() || c == '_' => {
                let start = self.i;
                self.i += 1;
                while self
                    .peek()
                    .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    self.i += 1;
                }
                w.text.extend(&self.s[start..self.i]);
                w.dynamic = true;
            }
            Some(c) if c.is_ascii_digit() || "@*#?$!-".contains(c) => {
                w.text.push('$');
                w.text.push(c);
                w.dynamic = true;
                self.i += 2;
            }
            _ => {
                w.text.push('$');
                self.i += 1;
            }
        }
        Ok(())
    }

    fn powershell_word(&mut self) -> Result<Word, Unclear> {
        let mut w = Word::default();
        if self.peek() == Some('@') {
            return Err(Unclear::Expression);
        }
        while let Some(c) = self.peek() {
            match c {
                ' ' | '\t' | '\r' | '\n' | ';' | '|' | '>' => break,
                '&' if self.at(1) == Some('&') => break,
                '<' | '(' | ')' | '{' | '}' => return Err(Unclear::Expression),
                '`' => return Err(Unclear::Escape),
                '\'' => {
                    self.i += 1;
                    loop {
                        match self.peek() {
                            None => return Err(Unclear::Unclosed),
                            Some('\'') if self.at(1) == Some('\'') => {
                                w.text.push('\'');
                                self.i += 2;
                            }
                            Some('\'') => {
                                self.i += 1;
                                break;
                            }
                            Some(ch) => {
                                w.text.push(ch);
                                self.i += 1;
                            }
                        }
                    }
                    w.quoted = true;
                }
                '"' => {
                    self.i += 1;
                    loop {
                        match self.peek() {
                            None => return Err(Unclear::Unclosed),
                            Some('"') if self.at(1) == Some('"') => {
                                w.text.push('"');
                                self.i += 2;
                            }
                            Some('"') => {
                                self.i += 1;
                                break;
                            }
                            Some('`') => return Err(Unclear::Escape),
                            Some('$') => self.powershell_variable(&mut w)?,
                            Some(ch) => {
                                w.text.push(ch);
                                self.i += 1;
                            }
                        }
                    }
                    w.quoted = true;
                }
                '$' => self.powershell_variable(&mut w)?,
                _ => {
                    match c {
                        '*' | '?' | '[' => w.glob = true,
                        '~' if w.text.is_empty() => w.tilde = true,
                        _ => {}
                    }
                    w.text.push(c);
                    self.i += 1;
                }
            }
        }
        Ok(w)
    }

    fn powershell_variable(&mut self, w: &mut Word) -> Result<(), Unclear> {
        match self.at(1) {
            Some('(') => Err(Unclear::Expression),
            Some('{') => {
                let start = self.i;
                let mut j = self.i + 2;
                while j < self.s.len() && self.s[j] != '}' {
                    j += 1;
                }
                if j >= self.s.len() {
                    return Err(Unclear::Unclosed);
                }
                w.text.extend(&self.s[start..=j]);
                w.dynamic = true;
                self.i = j + 1;
                Ok(())
            }
            Some(c) if c.is_ascii_alphanumeric() || c == '_' || c == '?' => {
                let start = self.i;
                self.i += 1;
                while self
                    .peek()
                    .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_' || c == ':')
                {
                    self.i += 1;
                }
                w.text.extend(&self.s[start..self.i]);
                w.dynamic = true;
                Ok(())
            }
            _ => {
                w.text.push('$');
                self.i += 1;
                Ok(())
            }
        }
    }

    /// At `<`, `>`, `&>` or after an fd number (`2>`, PowerShell `*>`).
    fn redirect(&mut self, numbered: bool) -> Result<(), Unclear> {
        if numbered && self.peek() == Some('*') {
            self.i += 1;
        }
        let c = self.peek().unwrap_or(' ');
        if c == '&' {
            // &> and &>>
            self.i += 2;
            if self.peek() == Some('>') {
                self.i += 1;
            }
            let target = self.target()?;
            self.cur.redirects.push(Redirect::Write(target));
            return Ok(());
        }
        if c == '<' {
            if !self.posix() {
                return Err(Unclear::Expression);
            }
            match (self.at(1), self.at(2)) {
                (Some('<'), Some('<')) => {
                    self.i += 3;
                    let word = self.target()?;
                    self.cur.redirects.push(Redirect::HereString(word));
                }
                (Some('<'), _) => {
                    self.i += 2;
                    let strip_tabs = self.peek() == Some('-');
                    if strip_tabs {
                        self.i += 1;
                    }
                    let delimiter = self.target()?;
                    if delimiter.dynamic {
                        return Err(Unclear::Heredoc);
                    }
                    self.pending.push(Pending {
                        delimiter: delimiter.text,
                        literal: delimiter.quoted,
                        strip_tabs,
                        item: CURRENT,
                        redirect: self.cur.redirects.len(),
                    });
                    self.cur.redirects.push(Redirect::Heredoc {
                        body: String::new(),
                        literal: delimiter.quoted,
                    });
                }
                (Some('('), _) => return Err(Unclear::ProcessSubstitution),
                (Some('&'), _) => {
                    self.i += 2;
                    self.target()?;
                    self.cur.redirects.push(Redirect::Dup);
                }
                (Some('>'), _) => {
                    self.i += 2;
                    let target = self.target()?;
                    self.cur.redirects.push(Redirect::Write(target));
                }
                _ => {
                    self.i += 1;
                    let target = self.target()?;
                    self.cur.redirects.push(Redirect::Read(target));
                }
            }
            return Ok(());
        }
        // '>'
        self.i += 1;
        if self.posix() && self.peek() == Some('(') {
            return Err(Unclear::ProcessSubstitution);
        }
        if self.peek() == Some('>') || (self.posix() && self.peek() == Some('|')) {
            self.i += 1;
        }
        if self.peek() == Some('&') {
            self.i += 1;
            let target = self.target()?;
            let fd = target.text == "-" || target.text.chars().all(|c| c.is_ascii_digit());
            self.cur.redirects.push(if fd && !target.dynamic {
                Redirect::Dup
            } else {
                Redirect::Write(target)
            });
            return Ok(());
        }
        let target = self.target()?;
        self.cur.redirects.push(Redirect::Write(target));
        Ok(())
    }

    fn target(&mut self) -> Result<Word, Unclear> {
        self.skip_blanks();
        match self.peek() {
            None | Some('\n' | ';' | '&' | '|' | '<' | '>' | '(' | ')') => Err(Unclear::Unclosed),
            _ => self.word(),
        }
    }

    /// Reads the bodies of this line's here-documents, starting at the line after it.
    fn read_heredocs(&mut self) -> Result<(), Unclear> {
        let pending = std::mem::take(&mut self.pending);
        for p in pending {
            let mut body = String::new();
            let mut closed = false;
            while self.i < self.s.len() {
                let start = self.i;
                while self.i < self.s.len() && self.s[self.i] != '\n' {
                    self.i += 1;
                }
                let line: String = self.s[start..self.i].iter().collect();
                if self.i < self.s.len() {
                    self.i += 1;
                }
                let check = if p.strip_tabs {
                    line.trim_start_matches('\t')
                } else {
                    line.as_str()
                };
                if check.trim_end_matches('\r') == p.delimiter {
                    closed = true;
                    break;
                }
                body.push_str(check);
                body.push('\n');
            }
            if !closed {
                return Err(Unclear::Heredoc);
            }
            if !p.literal && (body.contains("$(") || body.contains('`')) {
                // an unquoted here-document runs these when the command starts
                return Err(Unclear::CommandSubstitution);
            }
            if let Some(Item::Command(cmd)) = self.items.get_mut(p.item) {
                if let Some(Redirect::Heredoc { body: slot, .. }) =
                    cmd.redirects.get_mut(p.redirect)
                {
                    *slot = body;
                }
            }
        }
        Ok(())
    }
}

fn valid_name(text: &str) -> bool {
    let name = text.strip_suffix('+').unwrap_or(text);
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// The value of `$(cat <<'EOF' … EOF)`, or None for any other substitution.
fn literal_substitution(items: &[Item]) -> Option<String> {
    let [Item::Command(cmd)] = items else {
        return None;
    };
    let [word] = cmd.words.as_slice() else {
        return None;
    };
    if word.text != "cat" || word.dynamic || !cmd.assigns.is_empty() {
        return None;
    }
    match cmd.redirects.as_slice() {
        [Redirect::Heredoc {
            body,
            literal: true,
        }] => Some(body.trim_end_matches('\n').to_string()),
        _ => None,
    }
}
