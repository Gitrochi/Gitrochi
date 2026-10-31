//! `gitrochi-ledger`: the session ledger for agents and scripts. Reports and reads print
//! short English text (`--json` for the data); `mcp` serves the MCP tools over stdio.

use gitrochi_ledger::api::{self, Caller};
use gitrochi_ledger::{backup, db, demo, mcp, text, util, Error};
use serde_json::{json, Map, Value};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "gitrochi-ledger [--db FILE] [--json] [--pretty] <command> [arguments]

  report [-p PROJECT] [-s SESSION] [-e EVENT] [-k KIND] [-t TITLE] [-b BASE] [-m SUMMARY]
         [--body TEXT | --body-file FILE] [--ask QUESTION]... [--question TEXT]
         [--touches A,B] [--related A,B] [-a NAME[@VERSION][#REVISION]]...
         [--version V] [--into V] [--absorbs A,B] [--targets A,B] [--resolves 1,2]
         [--chat-url URL] [--note TEXT] [--ssot V] [--work A,B]
  overview [-p PROJECT] [-s SESSION --deliver]
  session ID [--deliver]
  import FILE|- [-p PROJECT]
  import-legacy FILE [--dry-run]
  scan [-p PROJECT]
  register VERSION -p PROJECT [--note TEXT]
  backup [--daily] [--keep N] [--list]
  demo DB [--large] [--force]
  call METHOD [JSON]
  mcp

The database is GITROCHI_LEDGER_DB, else the per-user default (gitrochi-ledger call info).
GITROCHI_LEDGER_SESSION is the default session for report, overview and session.
Details: crates/gitrochi-ledger/README.md";

const FLAGS: [&str; 8] = [
    "json", "pretty", "deliver", "daily", "list", "large", "force", "dry-run",
];
const REPEATED: [&str; 2] = ["ask", "artifact"];

fn long_name(short: &str) -> Option<&'static str> {
    Some(match short {
        "p" => "project",
        "s" => "session",
        "e" => "event",
        "k" => "kind",
        "t" => "title",
        "b" => "base",
        "m" => "summary",
        "a" => "artifact",
        _ => return None,
    })
}

#[derive(Default)]
struct Invocation {
    command: String,
    positional: Vec<String>,
    options: Map<String, Value>,
}

impl Invocation {
    fn flag(&self, name: &str) -> bool {
        self.options.get(name) == Some(&Value::Bool(true))
    }

    fn text(&self, name: &str) -> Option<String> {
        self.options
            .get(name)
            .and_then(|v| v.as_str())
            .map(str::to_string)
    }
}

fn parse(raw: Vec<String>) -> Result<Invocation, String> {
    let mut invocation = Invocation::default();
    let mut items = raw.into_iter();
    let mut rest_positional = false;
    while let Some(item) = items.next() {
        let name = if rest_positional {
            None
        } else if item == "--" {
            rest_positional = true;
            continue;
        } else if let Some(long) = item.strip_prefix("--") {
            Some(long.to_string())
        } else if item.len() == 2 && item.starts_with('-') && item != "--" {
            if item == "-h" {
                return Err(String::new());
            }
            Some(
                long_name(&item[1..])
                    .ok_or_else(|| format!("Unknown option {item}"))?
                    .to_string(),
            )
        } else {
            None
        };
        let Some(name) = name else {
            if invocation.command.is_empty() {
                invocation.command = item;
            } else {
                invocation.positional.push(item);
            }
            continue;
        };
        let (name, inline) = match name.split_once('=') {
            Some((n, v)) => (n.to_string(), Some(v.to_string())),
            None => (name, None),
        };
        if name == "help" {
            return Err(String::new());
        }
        if FLAGS.contains(&name.as_str()) {
            invocation.options.insert(name, json!(true));
            continue;
        }
        let value = inline
            .or_else(|| items.next())
            .ok_or_else(|| format!("--{name} needs a value"))?;
        if REPEATED.contains(&name.as_str()) {
            let entry = invocation.options.entry(name).or_insert_with(|| json!([]));
            if let Value::Array(list) = entry {
                list.push(json!(value));
            }
        } else {
            invocation.options.insert(name, json!(value));
        }
    }
    if invocation.command.is_empty() {
        return Err(String::new());
    }
    Ok(invocation)
}

/// `NAME@VERSION#REVISION`; an `@` or `#` that does not start a version or revision stays
/// in the name (`PR #41@1.4.2` is the artifact `PR #41` at 1.4.2).
fn parse_artifact(text: &str) -> Value {
    let text = text.trim();
    let mut head = text;
    let mut ver = None;
    if let Some(at) = text.rfind('#') {
        let suffix = &text[at + 1..];
        let before = text[..at].chars().last();
        if !suffix.is_empty()
            && !suffix.contains(|c: char| c == '@' || c.is_whitespace())
            && before.is_some_and(|c| !c.is_whitespace())
        {
            head = &text[..at];
            ver = Some(suffix.to_string());
        }
    }
    let mut name = head;
    let mut ssot = None;
    if let Some(at) = head.rfind('@') {
        let candidate = &head[at + 1..];
        let numeric = candidate.strip_prefix(['v', 'V']).unwrap_or(candidate);
        let is_version = util::parse_version(numeric).as_deref() == Some(numeric)
            || gitrochi_ledger::vocab::is_latest_word(candidate);
        if at > 0 && is_version {
            name = &head[..at];
            ssot = Some(candidate.to_string());
        }
    }
    let mut artifact = json!({"name": name.trim()});
    if let Some(ssot) = ssot {
        artifact["ssot"] = json!(ssot);
    }
    if let Some(ver) = ver {
        artifact["ver"] = json!(ver);
    }
    artifact
}

fn read_input(path: &str) -> Result<String, Error> {
    let io = |e: io::Error| Error::invalid(format!("Could not read {path}: {e}"));
    if path == "-" {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text).map_err(io)?;
        Ok(text)
    } else {
        std::fs::read_to_string(path).map_err(io)
    }
}

fn report_args(invocation: &Invocation) -> Result<Value, Error> {
    let mut args = Map::new();
    for (option, key) in [
        ("project", "project"),
        ("session", "session"),
        ("event", "event"),
        ("kind", "kind"),
        ("title", "title"),
        ("base", "base"),
        ("summary", "summary"),
        ("version", "version"),
        ("into", "into"),
        ("note", "note"),
        ("ssot", "ssot"),
        ("chat-url", "chatUrl"),
        ("question", "question"),
        ("touches", "touches"),
        ("related", "related"),
        ("absorbs", "absorbs"),
        ("targets", "targets"),
        ("resolves", "resolves"),
        ("work", "work"),
        ("body", "body"),
    ] {
        if let Some(value) = invocation.text(option) {
            args.insert(key.into(), json!(value));
        }
    }
    if let Some(path) = invocation.text("body-file") {
        args.insert("body".into(), json!(read_input(&path)?));
    }
    if let Some(Value::Array(asks)) = invocation.options.get("ask") {
        args.insert("questions".into(), Value::Array(asks.clone()));
    }
    if let Some(Value::Array(items)) = invocation.options.get("artifact") {
        let artifacts: Vec<Value> = items
            .iter()
            .filter_map(Value::as_str)
            .map(parse_artifact)
            .collect();
        args.insert("artifacts".into(), Value::Array(artifacts));
    }
    if !args.contains_key("session") {
        if let Some(session) = std::env::var("GITROCHI_LEDGER_SESSION")
            .ok()
            .and_then(|v| util::clean(&v))
        {
            args.insert("session".into(), json!(session));
        }
    }
    Ok(Value::Object(args))
}

/// The legacy import's result in a few lines; long skip lists are shortened.
fn legacy_text(result: &Value) -> String {
    let counts = &result["counts"];
    let n = |key: &str| counts[key].as_u64().unwrap_or(0);
    let keys = [
        "projects",
        "baselines",
        "baselinesUpdated",
        "sessions",
        "events",
        "questions",
        "imports",
    ];
    let mut lines = vec![if keys.iter().all(|k| n(k) == 0) {
        "Nothing new to import from claude-ledger.".to_string()
    } else {
        format!(
            "{} from claude-ledger: {} session(s) · {} event(s) · {} question(s) · {} baseline(s), {} completed · {} project(s) · {} pasted-block hash(es)",
            if result["dryRun"] == json!(true) {
                "Would import"
            } else {
                "Imported"
            },
            n("sessions"),
            n("events"),
            n("questions"),
            n("baselines"),
            n("baselinesUpdated"),
            n("projects"),
            n("imports"),
        )
    }];
    let skipped: Vec<&str> = result["skipped"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !skipped.is_empty() {
        let shown = skipped
            .iter()
            .take(10)
            .copied()
            .collect::<Vec<_>>()
            .join(", ");
        let more = match skipped.len() {
            0..=10 => String::new(),
            count => format!(" and {} more", count - 10),
        };
        lines.push(format!(
            "Skipped {} session(s) the ledger already has: {shown}{more}",
            skipped.len()
        ));
    }
    for error in result["errors"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        lines.push(format!("  - {error}"));
    }
    lines.join("\n")
}

enum Output {
    Text(String, Value),
    Json(Value),
}

fn open(path: &Path) -> Result<std::sync::Arc<db::Db>, Error> {
    if !db::enabled() {
        return Err(Error::new(
            "DISABLED",
            "The ledger is turned off (GITROCHI_LEDGER=0)",
        ));
    }
    db::shared(path)
}

fn run(invocation: &Invocation, path: &Path) -> Result<Output, Error> {
    let positional = |index: usize, what: &str| -> Result<String, Error> {
        invocation
            .positional
            .get(index)
            .cloned()
            .ok_or_else(|| Error::invalid(format!("Missing {what}")))
    };
    match invocation.command.as_str() {
        "report" => {
            let db = open(path)?;
            let reply = api::report(&db, &report_args(invocation)?, "cli")?;
            Ok(Output::Text(
                text::report(&reply),
                api::report_json(&reply)?,
            ))
        }
        "overview" => {
            let db = open(path)?;
            let mut args = json!({"deliver": invocation.flag("deliver")});
            if let Some(project) = invocation.text("project") {
                args["project"] = json!(project);
            }
            if let Some(session) = invocation.text("session") {
                args["session"] = json!(session);
            }
            let (text, data) = api::overview(&db, &args, util::now_ms())?;
            Ok(Output::Text(text, data))
        }
        "session" => {
            let id = match invocation.positional.first() {
                Some(id) => id.clone(),
                None => std::env::var("GITROCHI_LEDGER_SESSION")
                    .ok()
                    .and_then(|v| util::clean(&v))
                    .ok_or_else(|| Error::invalid("Missing session ID"))?,
            };
            let db = open(path)?;
            let (text, data) = api::session_text(&db, &id, invocation.flag("deliver"))?;
            Ok(Output::Text(text, data))
        }
        "import" => {
            let text = read_input(&positional(
                0,
                "a file to import (or - for standard input)",
            )?)?;
            let mut args = json!({"text": text, "db": path.to_string_lossy()});
            if let Some(project) = invocation.text("project") {
                args["project"] = json!(project);
            }
            let result = api::call_as(Caller::Agent, "import", &args)?;
            let rows = result["results"].as_array().cloned().unwrap_or_default();
            let count = |f: &dyn Fn(&Value) -> bool| rows.iter().filter(|r| f(r)).count();
            let mut lines = vec![format!(
                "Imported {} block(s): {} recorded · {} duplicate · {} failed",
                rows.len(),
                count(&|r| r["ok"] == json!(true) && r["duplicate"] == json!(false)),
                count(&|r| r["duplicate"] == json!(true)),
                count(&|r| r["ok"] == json!(false)),
            )];
            for row in &rows {
                if let Some(error) = row["error"].as_str() {
                    lines.push(format!("  - block {}: {error}", row["index"]));
                }
            }
            Ok(Output::Text(lines.join("\n"), result))
        }
        "import-legacy" => {
            let args = json!({
                "db": path.to_string_lossy(),
                "path": positional(0, "the claude-ledger database file")?,
                "dryRun": invocation.flag("dry-run"),
            });
            let result = api::call_as(Caller::Agent, "import_legacy", &args)?;
            Ok(Output::Text(legacy_text(&result), result))
        }
        "scan" => {
            let mut args = json!({"db": path.to_string_lossy()});
            if let Some(project) = invocation.text("project") {
                args["project"] = json!(project);
            }
            let result = api::call_as(Caller::Agent, "scan", &args)?;
            let lines: Vec<String> = result["results"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|r| match r["error"].as_str() {
                    Some(error) => format!("{}: {error}", r["project"].as_str().unwrap_or("")),
                    None => format!(
                        "{}: {} found, {} added ({})",
                        r["project"].as_str().unwrap_or(""),
                        r["found"],
                        r["added"],
                        r["source"].as_str().unwrap_or("")
                    ),
                })
                .collect();
            let text = if lines.is_empty() {
                "No projects to scan.".to_string()
            } else {
                lines.join("\n")
            };
            Ok(Output::Text(text, result))
        }
        "register" => {
            let args = json!({
                "db": path.to_string_lossy(),
                "version": positional(0, "a version")?,
                "project": invocation.text("project").ok_or_else(|| Error::invalid("Missing --project"))?,
                "note": invocation.text("note"),
            });
            let result = api::call_as(Caller::Agent, "register_baseline", &args)?;
            Ok(Output::Text(
                format!(
                    "Registered {} {}",
                    result["project"].as_str().unwrap_or(""),
                    result["version"].as_str().unwrap_or("")
                ),
                result,
            ))
        }
        "backup" => {
            if invocation.flag("list") {
                let list: Vec<String> = backup::list(path)
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect();
                let text = if list.is_empty() {
                    "No backups yet.".to_string()
                } else {
                    list.join("\n")
                };
                return Ok(Output::Text(text, json!({"backups": list})));
            }
            let mut args = json!({"db": path.to_string_lossy(), "daily": invocation.flag("daily")});
            if let Some(keep) = invocation.text("keep") {
                args["keep"] = json!(keep);
            }
            let result = api::call_as(Caller::Agent, "backup", &args)?;
            let text = if result["created"] == json!(true) {
                format!("Backed up ✓ {}", result["path"].as_str().unwrap_or(""))
            } else {
                format!(
                    "Today's backup already exists: {}",
                    result["path"].as_str().unwrap_or("")
                )
            };
            Ok(Output::Text(text, result))
        }
        "demo" => {
            let target = PathBuf::from(positional(0, "a database path for the demo")?);
            if target.exists() {
                if !invocation.flag("force") {
                    return Err(Error::invalid(format!(
                        "{} exists; remove it or pass --force",
                        target.display()
                    )));
                }
                for suffix in ["", "-wal", "-shm"] {
                    let mut file = target.clone().into_os_string();
                    file.push(suffix);
                    let _ = std::fs::remove_file(file);
                }
            }
            let db = db::Db::open(&target)?;
            let summary = demo::seed(&db, util::now_ms(), invocation.flag("large"))?;
            Ok(Output::Text(
                format!(
                    "Demo written to {}: {} projects, {} sessions, {} events",
                    summary.path, summary.projects, summary.sessions, summary.events
                ),
                serde_json::to_value(&summary).unwrap_or_default(),
            ))
        }
        "call" => {
            let method = positional(0, "a method")?;
            let mut args = match invocation.positional.get(1) {
                Some(text) => serde_json::from_str::<Value>(text)
                    .map_err(|e| Error::invalid(format!("The arguments are not JSON: {e}")))?,
                None => json!({}),
            };
            if !args.is_object() {
                return Err(Error::invalid("The arguments are a JSON object"));
            }
            if args.get("db").is_none() {
                args["db"] = json!(path.to_string_lossy());
            }
            Ok(Output::Json(api::call_as(Caller::Agent, &method, &args)?))
        }
        other => Err(Error::invalid(format!("Unknown command: {other}"))),
    }
}

fn print_json(value: &Value, pretty: bool) {
    let text = if pretty {
        serde_json::to_string_pretty(value)
    } else {
        serde_json::to_string(value)
    };
    println!("{}", text.unwrap_or_else(|_| "{}".into()));
}

fn main() -> ExitCode {
    let invocation = match parse(std::env::args().skip(1).collect()) {
        Ok(invocation) => invocation,
        Err(message) if message.is_empty() => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(message) => {
            eprintln!("gitrochi-ledger: {message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let path = invocation
        .text("db")
        .map(PathBuf::from)
        .unwrap_or_else(db::default_db_path);
    if invocation.command == "mcp" {
        let stdin = io::stdin();
        return match mcp::serve(path, stdin.lock(), io::stdout().lock()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("gitrochi-ledger mcp: {error}");
                ExitCode::FAILURE
            }
        };
    }
    let json_out = invocation.flag("json") || invocation.flag("pretty");
    match run(&invocation, &path) {
        Ok(Output::Json(value)) | Ok(Output::Text(_, value)) if json_out => {
            print_json(&value, invocation.flag("pretty"));
            ExitCode::SUCCESS
        }
        Ok(Output::Json(value)) => {
            print_json(&value, false);
            ExitCode::SUCCESS
        }
        Ok(Output::Text(text, _)) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            if json_out || invocation.command == "call" {
                print_json(
                    &json!({"error": error.to_json()}),
                    invocation.flag("pretty"),
                );
            }
            eprintln!("gitrochi-ledger: {}", error.message);
            ExitCode::from(if error.code == "INVALID_ARGUMENT" {
                2
            } else {
                1
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifacts_keep_hash_and_at_in_names() {
        let cases = [
            (
                "PR #41@2.5.106",
                json!({"name": "PR #41", "ssot": "2.5.106"}),
            ),
            (
                "comparison table@2.5.100#r2",
                json!({"name": "comparison table", "ssot": "2.5.100", "ver": "r2"}),
            ),
            ("mapping", json!({"name": "mapping"})),
            (
                "mail@company#1",
                json!({"name": "mail@company", "ver": "1"}),
            ),
            ("PR #41", json!({"name": "PR #41"})),
            (
                "PR #41@2.5.106#r2",
                json!({"name": "PR #41", "ssot": "2.5.106", "ver": "r2"}),
            ),
            ("table@latest", json!({"name": "table", "ssot": "latest"})),
            ("table@v1.4.2", json!({"name": "table", "ssot": "v1.4.2"})),
            ("x#1@2.0", json!({"name": "x#1", "ssot": "2.0"})),
        ];
        for (input, expected) in cases {
            assert_eq!(parse_artifact(input), expected, "{input}");
        }
    }

    #[test]
    fn options_short_long_and_repeated() {
        let args = [
            "report",
            "-p",
            "P",
            "--event=start",
            "--ask",
            "a",
            "--ask",
            "b",
            "--json",
            "--",
            "-x",
        ];
        let invocation = parse(args.iter().map(|s| s.to_string()).collect()).unwrap();
        assert_eq!(invocation.command, "report");
        assert_eq!(invocation.text("project").as_deref(), Some("P"));
        assert_eq!(invocation.text("event").as_deref(), Some("start"));
        assert_eq!(invocation.options["ask"], json!(["a", "b"]));
        assert!(invocation.flag("json"));
        assert_eq!(invocation.positional, ["-x"]);
        assert!(parse(vec!["report".into(), "--title".into()]).is_err());
        assert!(parse(vec!["-z".into()]).is_err());
    }
}
