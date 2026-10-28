//! `gitrochi-index`: the repository index for scripts, gitch, the Python tools and the
//! Go services. Every command prints one JSON object; `serve` answers JSON lines.

use serde_json::{json, Map, Value};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "gitrochi-index [--repo DIR] [--db FILE] [--pretty] <command> [arguments]

  version | path | status
  sync [--max-files N] [--no-renames] [--limit N]
  search QUERY [--scope commits|paths] [--limit N] [--offset N] [--sort rank|time]
  match QUERY [--scope commits|files] [--limit N]
  log [--path P] [--follow] [--author TEXT] [--since T] [--until T] [--limit N] [--offset N]
  show SHA | file PATH | coupled PATH [--min-commits N]
  hotspots [--since T] [--prefix P] | owners [PREFIX] [--since T]
  impact PATH... [--min-confidence F] [--min-commits N]
  cache grep PATTERN [--ignore-case] [--fixed] | cache pickaxe TEXT [--regex] | cache stats | cache clear
  tokenize TEXT [--query] | prune | serve

Details: crates/gitrochi-index/README.md";

const FLAGS: [&str; 6] = [
    "follow",
    "no-renames",
    "ignore-case",
    "fixed",
    "regex",
    "query",
];

fn camel(option: &str) -> String {
    let mut out = String::new();
    let mut upper = false;
    for c in option.chars() {
        if c == '-' {
            upper = true;
        } else if upper {
            out.extend(c.to_uppercase());
            upper = false;
        } else {
            out.push(c);
        }
    }
    out
}

struct Invocation {
    repo: Option<PathBuf>,
    db: Option<PathBuf>,
    pretty: bool,
    command: String,
    args: Value,
}

fn parse(raw: Vec<String>) -> Result<Invocation, String> {
    let mut repo = None;
    let mut db = None;
    let mut pretty = false;
    let mut command = None;
    let mut positional = Vec::new();
    let mut options = Map::new();
    let mut items = raw.into_iter();
    let mut options_done = false;
    while let Some(item) = items.next() {
        if options_done {
            if command.is_none() {
                command = Some(item);
            } else {
                positional.push(item);
            }
            continue;
        }
        // After `--` everything is an argument, so paths may start with dashes.
        if item == "--" {
            options_done = true;
            continue;
        }
        if let Some(name) = item.strip_prefix("--") {
            let (name, inline) = match name.split_once('=') {
                Some((n, v)) => (n.to_string(), Some(v.to_string())),
                None => (name.to_string(), None),
            };
            match name.as_str() {
                "pretty" => pretty = true,
                "help" => return Err(String::new()),
                _ if FLAGS.contains(&name.as_str()) => {
                    options.insert(camel(&name), json!(true));
                }
                _ => {
                    let value = inline
                        .or_else(|| items.next())
                        .ok_or_else(|| format!("--{name} needs a value"))?;
                    match name.as_str() {
                        "repo" => repo = Some(PathBuf::from(value)),
                        "db" => db = Some(PathBuf::from(value)),
                        _ => {
                            options.insert(camel(&name), json!(value));
                        }
                    }
                }
            }
        } else if item == "-h" {
            return Err(String::new());
        } else if command.is_none() {
            command = Some(item);
        } else {
            positional.push(item);
        }
    }
    let command = command.ok_or_else(String::new)?;
    let joined = positional.join(" ");
    match command.as_str() {
        "search" | "match" if !positional.is_empty() => {
            options.insert("query".into(), json!(joined));
        }
        "tokenize" if !positional.is_empty() => {
            options.insert("text".into(), json!(joined));
        }
        "show" if !positional.is_empty() => {
            options.insert("sha".into(), json!(positional[0]));
        }
        "file" | "coupled" if !positional.is_empty() => {
            options.insert("path".into(), json!(joined));
        }
        "owners" if !positional.is_empty() => {
            options.insert("prefix".into(), json!(joined));
        }
        "impact" => {
            options.insert("paths".into(), json!(positional));
        }
        "cache" => {
            let action = positional.first().cloned().unwrap_or_default();
            let rest = positional.get(1..).unwrap_or_default().join(" ");
            options.insert("action".into(), json!(action));
            match action.as_str() {
                "grep" => {
                    options.insert("pattern".into(), json!(rest));
                }
                "pickaxe" => {
                    options.insert("text".into(), json!(rest));
                }
                _ => {}
            }
        }
        _ => {}
    }
    Ok(Invocation {
        repo,
        db,
        pretty,
        command,
        args: Value::Object(options),
    })
}

fn print(value: &Value, pretty: bool) {
    let text = if pretty {
        serde_json::to_string_pretty(value)
    } else {
        serde_json::to_string(value)
    };
    println!("{}", text.unwrap_or_else(|_| "{}".into()));
}

fn serve(invocation: &Invocation) -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Value>(&line) {
            Ok(request) => {
                let id = request["id"].clone();
                let command = request["command"].as_str().unwrap_or("");
                match gitrochi_index::run(
                    invocation.repo.as_deref(),
                    invocation.db.as_deref(),
                    command,
                    &request["args"],
                ) {
                    Ok(result) => json!({"id": id, "result": result}),
                    Err(error) => json!({"id": id, "error": error.to_json()}),
                }
            }
            Err(error) => json!({
                "id": null,
                "error": {"code": "INVALID_ARGUMENT", "message": format!("Invalid request: {error}")},
            }),
        };
        writeln!(stdout, "{response}")?;
        stdout.flush()?;
    }
    Ok(())
}

fn main() -> ExitCode {
    let invocation = match parse(std::env::args().skip(1).collect()) {
        Ok(invocation) => invocation,
        Err(message) => {
            if message.is_empty() {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            eprintln!("gitrochi-index: {message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    if invocation.command == "serve" {
        return match serve(&invocation) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("gitrochi-index serve: {error}");
                ExitCode::FAILURE
            }
        };
    }
    match gitrochi_index::run(
        invocation.repo.as_deref(),
        invocation.db.as_deref(),
        &invocation.command,
        &invocation.args,
    ) {
        Ok(result) => {
            print(&result, invocation.pretty);
            ExitCode::SUCCESS
        }
        Err(error) => {
            print(&json!({"error": error.to_json()}), invocation.pretty);
            eprintln!("gitrochi-index: {}", error.message);
            ExitCode::from(if error.code == "INVALID_ARGUMENT" {
                2
            } else {
                1
            })
        }
    }
}
