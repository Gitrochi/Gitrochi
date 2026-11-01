//! `gitrochi-autocontinue`: shows what auto-continue would do with a hook input, without
//! waiting. `eval` prints the decision as JSON; with `--emit` it prints exactly what the
//! hook would (stdout, stderr, exit code) as if the delay had passed with no answer.

use gitrochi_autocontinue::{
    decide, hook_settings, is_person_prompt, Decision, HookEvent, HookInput, PermissionContext,
    Policy, SessionState,
};
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::process::ExitCode;

const USAGE: &str = "gitrochi-autocontinue <command>

  eval EVENT [options] < input.json   the decision for one hook input (Stop, PreToolUse,
                                      PermissionRequest, UserPromptSubmit)
      --policy FILE       policy JSON (default: the defaults with auto-continue on)
      --repo DIR          the repository root (default: the input's cwd)
      --home DIR          the home folder for ~ (default: HOME or USERPROFILE)
      --branch NAME       the checked-out branch, --upstream NAME its upstream branch
      --consecutive N     automatic answers so far (default 0)
      --app-closed        the app is not running (D10)
      --emit              print what the hook prints and exit with its code
      --pretty            indent the JSON
  settings COMMAND [--delay N]        the hooks entries that run COMMAND EVENT
  version

Details: crates/gitrochi-autocontinue/README.md";

struct Options {
    command: String,
    event: Option<String>,
    policy: Option<String>,
    repo: Option<String>,
    home: Option<String>,
    branch: Option<String>,
    upstream: Option<String>,
    consecutive: u32,
    app_closed: bool,
    emit: bool,
    pretty: bool,
    delay: Option<u32>,
}

fn parse(raw: Vec<String>) -> Result<Options, String> {
    let mut o = Options {
        command: String::new(),
        event: None,
        policy: None,
        repo: None,
        home: None,
        branch: None,
        upstream: None,
        consecutive: 0,
        app_closed: false,
        emit: false,
        pretty: false,
        delay: None,
    };
    let mut items = raw.into_iter();
    let mut positional = Vec::new();
    while let Some(item) = items.next() {
        let mut value = |name: &str| items.next().ok_or_else(|| format!("{name} needs a value"));
        match item.as_str() {
            "-h" | "--help" => return Err(String::new()),
            "--policy" => o.policy = Some(value("--policy")?),
            "--repo" => o.repo = Some(value("--repo")?),
            "--home" => o.home = Some(value("--home")?),
            "--branch" => o.branch = Some(value("--branch")?),
            "--upstream" => o.upstream = Some(value("--upstream")?),
            "--consecutive" => {
                o.consecutive = value("--consecutive")?
                    .parse()
                    .map_err(|_| "--consecutive needs a number".to_string())?
            }
            "--delay" => {
                o.delay = Some(
                    value("--delay")?
                        .parse()
                        .map_err(|_| "--delay needs a number".to_string())?,
                )
            }
            "--app-closed" => o.app_closed = true,
            "--emit" => o.emit = true,
            "--pretty" => o.pretty = true,
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            _ => positional.push(item),
        }
    }
    let mut positional = positional.into_iter();
    o.command = positional.next().ok_or_else(String::new)?;
    o.event = positional.next();
    Ok(o)
}

fn print(value: &Value, pretty: bool) {
    let text = if pretty {
        serde_json::to_string_pretty(value)
    } else {
        serde_json::to_string(value)
    };
    println!("{}", text.unwrap_or_else(|_| "{}".into()));
}

fn eval(o: &Options) -> Result<ExitCode, String> {
    let mut text = String::new();
    io::stdin()
        .read_to_string(&mut text)
        .map_err(|e| format!("cannot read the input: {e}"))?;
    let mut input = HookInput::parse(&text).map_err(|e| format!("the input is not JSON: {e}"))?;
    if let Some(event) = &o.event {
        // the event given on the command line wins, as with the hooks Gitrochi installs
        input.hook_event_name = HookEvent::parse(event).name().to_string();
    }
    let policy = match &o.policy {
        Some(path) => {
            let raw =
                std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
            Policy::from_json(&raw).map_err(|e| format!("{path} is not a policy: {e}"))?
        }
        None => Policy {
            enabled: true,
            ..Policy::default()
        },
    };
    let home = o
        .home
        .clone()
        .or_else(|| std::env::var("HOME").ok())
        .or_else(|| std::env::var("USERPROFILE").ok())
        .unwrap_or_default();
    let repo = o.repo.clone().unwrap_or_else(|| input.cwd.clone());
    let mut ctx = PermissionContext::new(&input, &policy, &repo, &home);
    ctx.current_branch = o.branch.clone();
    ctx.upstream_branch = o.upstream.clone();
    let state = SessionState {
        consecutive: o.consecutive,
    };
    if input.event() == HookEvent::UserPromptSubmit {
        // nothing to answer: report whether the prompt resets the count
        if !o.emit {
            let report = json!({
                "event": "UserPromptSubmit",
                "decision": "pass",
                "person": is_person_prompt(&input.prompt),
                "state": state.after_prompt(&input.prompt),
            });
            print(&report, o.pretty);
        }
        return Ok(ExitCode::SUCCESS);
    }
    let decision = decide(&input, &policy, state, &ctx, !o.app_closed);
    let output = decision.output();
    if o.emit {
        let stdout = output.stdout();
        if !stdout.is_empty() {
            println!("{stdout}");
        }
        let stderr = output.stderr();
        if !stderr.is_empty() {
            eprintln!("{stderr}");
        }
        return Ok(ExitCode::from(output.exit_code() as u8));
    }
    let report = match &decision {
        Decision::Pass(pass) => json!({
            "event": input.event().name(),
            "decision": "pass",
            "reason": pass,
            "message": pass.message(),
            "output": output.to_json(),
        }),
        Decision::Wait(wait) => json!({
            "event": input.event().name(),
            "decision": "wait",
            "kind": wait.kind,
            "delaySec": wait.delay_sec,
            "output": output.to_json(),
            "payload": wait.payload,
            "autoReply": wait.reply,
        }),
    };
    print(&report, o.pretty);
    Ok(ExitCode::SUCCESS)
}

fn main() -> ExitCode {
    let options = match parse(std::env::args().skip(1).collect()) {
        Ok(options) => options,
        Err(message) => {
            if message.is_empty() {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            eprintln!("gitrochi-autocontinue: {message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let result = match options.command.as_str() {
        "eval" => eval(&options),
        "settings" => match &options.event {
            Some(command) => {
                let delay = options
                    .delay
                    .unwrap_or(gitrochi_autocontinue::DEFAULT_DELAY_SEC);
                print(&hook_settings(command, delay), options.pretty);
                Ok(ExitCode::SUCCESS)
            }
            None => Err("settings needs the handler command".into()),
        },
        "version" => {
            println!("gitrochi-autocontinue {}", env!("CARGO_PKG_VERSION"));
            Ok(ExitCode::SUCCESS)
        }
        other => {
            eprintln!("gitrochi-autocontinue: unknown command {other}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(code) => code,
        Err(message) => {
            let _ = writeln!(io::stderr(), "gitrochi-autocontinue: {message}");
            ExitCode::FAILURE
        }
    }
}
