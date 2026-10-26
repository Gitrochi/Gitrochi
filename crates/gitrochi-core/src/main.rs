use std::collections::HashMap;
use std::io::{self, BufRead, Read, Write};

fn graph_json(args: impl Iterator<Item = String>) -> Result<(), Box<dyn std::error::Error>> {
    let mut args = args;
    let mut meta = HashMap::new();
    let mut files = vec![];
    while let Some(arg) = args.next() {
        if arg == "-v" {
            let pair = args.next().ok_or("Missing metadata")?;
            let (key, value) = pair.split_once('=').ok_or("Invalid metadata")?;
            meta.insert(key.to_owned(), value.to_owned());
        } else {
            files.push(arg);
        }
    }
    let mut text = String::new();
    if files.is_empty() {
        io::stdin().read_to_string(&mut text)?;
    } else {
        for file in files {
            text += &std::fs::read_to_string(file)?;
        }
    }
    let mut output = gitrochi_core::records::to_json(&text, &meta)?;
    if let Some(file) = meta.get("reviewfile").filter(|f| !f.is_empty()) {
        output["review"] = serde_json::from_str(&std::fs::read_to_string(file)?)?;
    }
    // 기존 공개 JSON·HTML의 항목별 인라인 표기를 유지한다.
    let fields = output.as_object().ok_or("Invalid graph object")?;
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    writeln!(stdout, "{{")?;
    for (i, (key, value)) in fields.iter().enumerate() {
        write!(stdout, "  {}: ", serde_json::to_string(key)?)?;
        if key == "nodes" || key == "edges" {
            writeln!(stdout, "[")?;
            let rows = value.as_array().ok_or("Invalid graph rows")?;
            for (n, row) in rows.iter().enumerate() {
                writeln!(
                    stdout,
                    "    {row}{}",
                    if n + 1 < rows.len() { "," } else { "" }
                )?;
            }
            write!(stdout, "  ]")?;
        } else if key == "diff" {
            write!(
                stdout,
                r#"{{"base": {}, "baseName": {}, "head": {}}}"#,
                value["base"], value["baseName"], value["head"]
            )?;
        } else {
            write!(stdout, "{value}")?;
        }
        writeln!(stdout, "{}", if i + 1 < fields.len() { "," } else { "" })?;
    }
    writeln!(stdout, "}}")?;
    stdout.flush()?;
    Ok(())
}

fn graph_affected(dir: &str, base: &str) -> io::Result<()> {
    let read = |file: &str| std::fs::read_to_string(std::path::Path::new(dir).join(file));
    let changed = read("changed")?;
    let untracked = read("untracked")?;
    let deleted = read("deleted")?;
    let before = read("affected-before")?;
    let before_modules = read("affected-modules-before")?;
    let now = read("affected-now")?;
    let modules = read("affected-modules")?;
    let out = gitrochi_core::records::affected(gitrochi_core::records::ImpactInput {
        changed: &changed,
        untracked: &untracked,
        deleted: &deleted,
        before: &before,
        before_modules: &before_modules,
        now: &now,
        modules: &modules,
        base,
    });
    io::stdout().lock().write_all(out.as_bytes())
}

// 한 프로세스에서 요청을 여러 개 받아 도구마다 새 런타임을 띄울 필요가 없다.
fn main() -> io::Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("graph-json") => return graph_json(args).map_err(|e| io::Error::other(e.to_string())),
        Some("graph-affected") => {
            return graph_affected(
                &args
                    .next()
                    .ok_or_else(|| io::Error::other("Missing graph directory"))?,
                &args
                    .next()
                    .ok_or_else(|| io::Error::other("Missing graph base"))?,
            )
        }
        Some(_) => return Err(io::Error::other("Unknown core command")),
        None => {}
    }
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line?;
        stdout.write_all(&gitrochi_core::process(line.as_bytes()))?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }
    Ok(())
}
