//! Unit tests for the private pieces: the shell tokenizer, lexical paths and text helpers.

use crate::permission::paths::{credential_parts, split_text, AbsPath};
use crate::permission::shell::{parse, Command, Dialect, Item, Link, Redirect, Unclear};
use crate::text::{has_phrase, one_line, plain_line, sentences, trim_tail};

fn items(source: &str) -> Vec<Item> {
    parse(source, Dialect::Posix).unwrap_or_else(|e| panic!("{source:?}: {e:?}"))
}

fn commands(source: &str) -> Vec<Command> {
    items(source)
        .into_iter()
        .filter_map(|item| match item {
            Item::Command(c) => Some(c),
            _ => None,
        })
        .collect()
}

fn words(source: &str) -> Vec<Vec<String>> {
    commands(source)
        .into_iter()
        .map(|c| c.words.into_iter().map(|w| w.text).collect())
        .collect()
}

fn unclear(source: &str) -> Unclear {
    parse(source, Dialect::Posix).expect_err(source)
}

#[test]
fn quotes_and_escapes_join_into_words() {
    assert_eq!(
        words(r#"echo "a b" 'c d' e\ f "x\"y" 'it''s'"#),
        [vec!["echo", "a b", "c d", "e f", "x\"y", "its"]]
    );
    assert_eq!(words("echo a\"b\"'c'"), [vec!["echo", "abc"]]);
    assert_eq!(words("ls \\\n  -la"), [vec!["ls", "-la"]]);
    assert_eq!(words("ls # rm -rf /\npwd"), [vec!["ls"], vec!["pwd"]]);
    assert_eq!(words("echo a#b"), [vec!["echo", "a#b"]]);
}

#[test]
fn operators_link_commands() {
    let links: Vec<Link> = commands("a && b || c; d | e & f\ng |& h")
        .iter()
        .map(|c| c.link)
        .collect();
    assert_eq!(
        links,
        [
            Link::First,
            Link::And,
            Link::Or,
            Link::Then,
            Link::Pipe,
            Link::Background,
            Link::Then,
            Link::Pipe
        ]
    );
    // a newline after `&&` keeps the `&&`
    let links: Vec<Link> = commands("a &&\n  b").iter().map(|c| c.link).collect();
    assert_eq!(links, [Link::First, Link::And]);
}

#[test]
fn redirections_are_parsed() {
    let cmd = &commands("cmd > out 2>&1 < in >> log &> all 2>/dev/null >| clobber")[0];
    assert_eq!(cmd.words.len(), 1);
    let kinds: Vec<String> = cmd
        .redirects
        .iter()
        .map(|r| match r {
            Redirect::Write(w) => format!("w:{}", w.text),
            Redirect::Read(w) => format!("r:{}", w.text),
            Redirect::Dup => "dup".into(),
            Redirect::Heredoc { .. } => "heredoc".into(),
            Redirect::HereString(w) => format!("s:{}", w.text),
        })
        .collect();
    assert_eq!(
        kinds,
        [
            "w:out",
            "dup",
            "r:in",
            "w:log",
            "w:all",
            "w:/dev/null",
            "w:clobber"
        ]
    );
    // `echo 2 > x` writes "2"; `echo 2>x` redirects stderr
    assert_eq!(words("echo 2 > x"), [vec!["echo", "2"]]);
    assert_eq!(words("echo 2>x"), [vec!["echo"]]);
    let cmd = &commands("grep x <<< \"$text\"")[0];
    assert!(matches!(&cmd.redirects[0], Redirect::HereString(w) if w.dynamic));
}

#[test]
fn here_documents_are_read_after_their_line() {
    let cmds = commands("cat <<'EOF' > file\nbody $x `y`\nEOF\necho next");
    assert_eq!(cmds.len(), 2);
    assert!(matches!(
        &cmds[0].redirects[0],
        Redirect::Heredoc { body, literal: true } if body == "body $x `y`\n"
    ));
    assert!(matches!(&cmds[0].redirects[1], Redirect::Write(w) if w.text == "file"));
    assert_eq!(cmds[1].words[0].text, "echo");
    // <<- strips leading tabs, also from the delimiter line
    let cmds = commands("cat <<-END\n\tindented\n\tEND\nls");
    assert!(
        matches!(&cmds[0].redirects[0], Redirect::Heredoc { body, .. } if body == "indented\n")
    );
    assert_eq!(cmds.len(), 2);
    // two here-documents on one line, read in order
    let cmds = commands("cat <<A <<B\na\nA\nb\nB");
    assert_eq!(cmds[0].redirects.len(), 2);
    // the commit message idiom: a literal here-document inside $( )
    let cmds = commands("git commit -m \"$(cat <<'EOF'\nSubject\n\n- why\nEOF\n)\" && git log");
    assert_eq!(cmds[0].words[3].text, "Subject\n\n- why");
    assert!(!cmds[0].words[3].dynamic);
    assert_eq!(cmds[1].words[1].text, "log");
}

#[test]
fn what_cannot_be_read_is_unclear() {
    assert_eq!(unclear("echo $(ls)"), Unclear::CommandSubstitution);
    assert_eq!(
        unclear("echo \"$(cat file)\""),
        Unclear::CommandSubstitution
    );
    assert_eq!(unclear("echo `ls`"), Unclear::Backtick);
    assert_eq!(unclear("echo \"`ls`\""), Unclear::Backtick);
    assert_eq!(unclear("diff <(a) b"), Unclear::ProcessSubstitution);
    assert_eq!(unclear("tee >(gzip) < x"), Unclear::ProcessSubstitution);
    assert_eq!(unclear("echo $((1+2))"), Unclear::Arithmetic);
    assert_eq!(unclear("echo $'a\\n'"), Unclear::AnsiQuote);
    assert_eq!(unclear("echo 'open"), Unclear::Unclosed);
    assert_eq!(unclear("echo \"open"), Unclear::Unclosed);
    assert_eq!(unclear("(cd a && make"), Unclear::Unclosed);
    assert_eq!(unclear("echo )"), Unclear::Unclosed);
    assert_eq!(unclear("cat <<EOF\nno end"), Unclear::Heredoc);
    assert_eq!(
        unclear("cat <<EOF\n$(rm x)\nEOF"),
        Unclear::CommandSubstitution
    );
    assert_eq!(unclear("f() { ls; }"), Unclear::Function);
    assert_eq!(unclear("function f { ls; }"), Unclear::Function);
    assert_eq!(unclear("case $x in a) ls;; esac"), Unclear::Case);
    assert_eq!(
        unclear("echo $(cat <<EOF\nx\nEOF\n)"),
        Unclear::CommandSubstitution
    );
    assert_eq!(unclear("echo >"), Unclear::Unclosed);
}

#[test]
fn assignments_variables_globs_and_tildes_are_marked() {
    let cmd = &commands("A=1 B=\"x y\" C+=z cmd ~/x *.rs $HOME/y ${PWD} 'q*' a=b")[0];
    let assigns: Vec<(&str, &str)> = cmd
        .assigns
        .iter()
        .map(|(n, v)| (n.as_str(), v.text.as_str()))
        .collect();
    assert_eq!(assigns, [("A", "1"), ("B", "x y"), ("C", "z")]);
    let w = &cmd.words;
    assert_eq!(w[0].text, "cmd");
    assert!(w[1].tilde && !w[1].glob);
    assert!(w[2].glob);
    assert!(w[3].dynamic && w[3].text == "$HOME/y");
    assert!(w[4].dynamic);
    assert!(!w[5].glob && w[5].quoted);
    // after the command name, NAME=value is an ordinary argument
    assert_eq!(w[6].text, "a=b");
    assert!(commands("cp a{,.bak}")[0].words[1].glob);
}

#[test]
fn keywords_and_subshells_open_up() {
    assert_eq!(
        words("if test -f x; then cat x; else ls; fi"),
        [vec!["test", "-f", "x"], vec!["cat", "x"], vec!["ls"]]
    );
    let cmds = commands("for f in a b; do rm \"$f\"; done");
    assert!(cmds[0].header);
    assert_eq!(cmds[1].words[0].text, "rm");
    assert!(cmds[1].words[1].dynamic);
    let kinds: Vec<&str> = items("(cd a && make) && b")
        .iter()
        .map(|i| match i {
            Item::Open => "(",
            Item::Close => ")",
            Item::Command(_) => "cmd",
        })
        .collect();
    assert_eq!(kinds, ["(", "cmd", "cmd", ")", "cmd"]);
    assert_eq!(words("{ ls; pwd; }"), [vec!["ls"], vec!["pwd"]]);
    assert_eq!(words("! grep -q x f"), [vec!["grep", "-q", "x", "f"]]);
}

#[test]
fn powershell_tokens() {
    let ps = |s: &str| parse(s, Dialect::PowerShell);
    let Ok(items) = ps("Get-Item 'it''s' \"a\"\"b\" $env:HOME 2>&1 | Out-Null; git status && ls")
    else {
        panic!("parses");
    };
    let cmds: Vec<&Command> = items
        .iter()
        .filter_map(|i| match i {
            Item::Command(c) => Some(c),
            _ => None,
        })
        .collect();
    assert_eq!(cmds.len(), 4);
    assert_eq!(cmds[0].words[1].text, "it's");
    assert_eq!(cmds[0].words[2].text, "a\"b");
    assert!(cmds[0].words[3].dynamic);
    assert!(matches!(cmds[0].redirects[0], Redirect::Dup));
    assert_eq!(cmds[3].link, Link::And);
    assert_eq!(ps("Write-Output `n").unwrap_err(), Unclear::Escape);
    assert_eq!(ps("Write-Output \"`n\"").unwrap_err(), Unclear::Escape);
    assert_eq!(
        ps("Write-Output $(Get-Date)").unwrap_err(),
        Unclear::Expression
    );
    assert_eq!(ps("ls | % { $_ }").unwrap_err(), Unclear::Expression);
    assert_eq!(ps("(Get-Item x).Name").unwrap_err(), Unclear::Expression);
    assert_eq!(ps("@(1, 2)").unwrap_err(), Unclear::Expression);
    assert_eq!(ps("& $cmd").unwrap_err(), Unclear::Expression);
    assert_eq!(
        ps("foreach ($x in $y) {}").unwrap_err(),
        Unclear::Expression
    );
    assert_eq!(ps("Get-Content < x").unwrap_err(), Unclear::Expression);
    assert_eq!(ps("cmd --% raw").unwrap_err(), Unclear::Expression);
}

#[test]
fn absolute_paths_fold_dots() {
    let p = AbsPath::parse("/Users/me/work/app/./src/../lib.rs").unwrap();
    assert_eq!(p.display(), "/Users/me/work/app/lib.rs");
    let root = AbsPath::parse("/Users/me/work/app").unwrap();
    assert!(p.starts_with(&root));
    assert!(!AbsPath::parse("/Users/me/work/application")
        .unwrap()
        .starts_with(&root));
    assert!(!AbsPath::parse("/Users/me/work/App/x")
        .unwrap()
        .starts_with(&root));
    assert_eq!(AbsPath::parse("/../../etc").unwrap().display(), "/etc");
    assert!(AbsPath::parse("relative/x").is_none());
    assert!(AbsPath::parse("C:relative").is_none());

    let w = AbsPath::parse(r"C:\Users\me\work\app").unwrap();
    assert!(w.is_windows());
    assert!(AbsPath::parse("c:/USERS/me/Work/app/x")
        .unwrap()
        .starts_with(&w));
    assert!(!AbsPath::parse(r"D:\Users\me\work\app")
        .unwrap()
        .starts_with(&w));
    assert_eq!(w.join(r"..\other").display(), r"c:\Users\me\work\other");
    let unc = AbsPath::parse(r"\\server\share\dir\f").unwrap();
    assert_eq!(unc.display(), "//server/share/dir/f");
    assert!(unc.starts_with(&AbsPath::parse(r"\\SERVER\Share").unwrap()));
    // on POSIX `//x` is just `/x`
    assert!(!AbsPath::parse("//server/share").unwrap().is_windows());
}

#[test]
fn credential_paths_match_anywhere() {
    let cred = |p: &str| credential_parts(&split_text(p));
    assert!(cred("~/.ssh/id_ed25519"));
    assert!(cred("/Users/me/.SSH/config"));
    assert!(cred("$HOME/.config/gitsw/config"));
    assert!(cred(r"C:\Users\me\.gitconfig"));
    assert!(cred("--identity-file=~/.ssh/key"));
    assert!(cred(".aws/credentials"));
    assert!(!cred("src/ssh.rs"));
    assert!(!cred("docs/.sshrc"));
    assert!(!cred("Ignore .ssh folders"));
}

#[test]
fn phrases_match_whole_words() {
    assert!(has_phrase("should i go?", "should i"));
    assert!(!has_phrase("i should implement it", "should i"));
    assert!(has_phrase("ok, should i?", "should i"));
    assert!(!has_phrase("tokenizer", "token"));
    assert!(has_phrase("진행할까요", "까요"));
    assert!(has_phrase(
        "push --force-with-lease now",
        "--force-with-lease"
    ));
}

#[test]
fn sentences_keep_file_names_and_versions() {
    assert_eq!(
        sentences("Edit lib.rs and bump to 1.2.0. Then ship? Yes!"),
        ["Edit lib.rs and bump to 1.2.0.", "Then ship?", "Yes!"]
    );
    assert_eq!(
        sentences("진행할까요? 저는 1번을 추천합니다."),
        ["진행할까요?", "저는 1번을 추천합니다."]
    );
    assert_eq!(sentences("続けますか？はい。"), ["続けますか？", "はい。"]);
    assert_eq!(
        sentences("He said \"go?\" then left."),
        ["He said \"go?\"", "then left."]
    );
    assert_eq!(trim_tail("**Proceed?** 🙂"), "**Proceed?");
    assert_eq!(
        plain_line("> **Use** `x` [docs](https://example.com) now_ok _it_"),
        "Use x docs now_ok it"
    );
    assert_eq!(one_line("a\n  b\tc", 10), "a b c");
    assert_eq!(one_line("abcdefghijk", 5), "abcd…");
}
