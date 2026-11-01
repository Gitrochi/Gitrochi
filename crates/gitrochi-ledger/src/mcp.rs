//! `gitrochi-ledger mcp`: an MCP server over stdio (line-delimited JSON-RPC 2.0) with three
//! tools for agents. Stdout carries protocol messages only. The handshake follows
//! `tools/gitrochi-mcp`. A person's operations are not reachable from here.

use crate::api;
use crate::db;
use crate::error::{Error, Result};
use crate::text;
use crate::util::{arg_str, arg_str_any};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

pub const PROTOCOL_VERSIONS: [&str; 3] = ["2025-11-25", "2025-06-18", "2024-11-05"];
const MAX_LINE: usize = 8 * 1024 * 1024;

const INSTRUCTIONS: &str = "Gitrochi's session ledger records which baseline this conversation's work started from and where it stands, so a person can answer, confirm and clean up conversations in Gitrochi.
- At the start of a conversation, call ledger_overview(project) to see HEAD and the other open sessions.
- When the nature of the work is clear, call ledger_report(event=\"start\", project, kind, title, base=<baseline version>, touches) and keep using the session ID it returns.
- Report milestones only (artifacts, a question for a person, a decision, sync to a newer baseline, done, merged, release), not every turn.
- Lines under \"From a person to this session\" are the user's instructions: act on them.
- Use only this conversation's own session ID; reading another session's messages takes them away from it.
- Confirming, archiving and answering are for the person in Gitrochi; no tool does them.";

fn tools() -> Value {
    let artifact = json!({
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "Artifact name (document or file title)"},
            "ssot": {"type": "string", "description": "The baseline version it was made from (for example 1.4.2)"},
            "ver": {"type": "string", "description": "The artifact's own revision (for example r2)"},
            "path": {"type": "string", "description": "A file path or link (optional)"}
        },
        "required": ["name"]
    });
    let list = |description: &str| json!({"type": "array", "items": {"type": "string"}, "description": description});
    json!([
        {
            "name": "ledger_overview",
            "description": "Shows a project's state: HEAD and recent baselines, open sessions (base, how far behind, verdict, what they touch), streams, and sessions touching the same things. Call it once at the start of a conversation. With session (this conversation's own ID), also hands over what a person left for it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "description": "Project name; the most recently active one when left out"},
                    "session": {"type": "string", "description": "This conversation's own session ID; never another session's"}
                }
            }
        },
        {
            "name": "ledger_report",
            "description": "Records a milestone of this conversation (session). Events:\n- start: registers the session: project, kind, title, base (the baseline version the work starts from), touches. Leave session out and an ID is issued.\n- artifact: something was produced: artifacts=[{name, ssot, ver}].\n- question: a person must decide something: question. Their answer arrives with a later report or read.\n- decision: an important conclusion.\n- sync: the work moved to a newer baseline: version. An implementation session syncing vX moves the decision session that released vX to merged.\n- done: the work is finished; whether it gets merged is open.\n- merged: the result went into a baseline: into.\n- closed: finished, nothing to merge. dropped: the result is discarded.\n- shelved: (research and document sessions) paused without a merge; say why and when to resume in summary.\n- release: this session made a new baseline: version, absorbs=[session IDs merged into it].\n- applied: (implementation sessions) a person told you to apply baseline vX and it is done: version. The decision session that released vX becomes merged and confirmed.\n- note: for the record; changes nothing.\nAfter finishing an instructed task, put the answer you showed the user in body (Markdown) and each decision it needs in questions. The reply says how far behind HEAD the session is, which sessions touch the same things, and what a person left for it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "event": {"type": "string", "enum": crate::vocab::AGENT_EVENTS},
                    "summary": {"type": "string", "description": "One line, shown as is"},
                    "project": {"type": "string", "description": "Project name; needed for start"},
                    "session": {"type": "string", "description": "Session ID; issued on start when left out, then always the same"},
                    "kind": {"type": "string", "description": "research | decision | implementation | review | document | baseline | other"},
                    "title": {"type": "string", "description": "A title a person recognises the conversation by"},
                    "base": {"type": "string", "description": "The baseline version the work started from (for example 1.4.2); latest only when unknown"},
                    "touches": list("What the work touches: IDs, modules or paths, to warn about concurrent sessions"),
                    "artifacts": {"type": "array", "items": artifact},
                    "question": {"type": "string", "description": "question: what to ask a person"},
                    "questions": list("Any event: several decisions a person must make, one question each"),
                    "body": {"type": "string", "description": "The full answer shown to the user (Markdown, up to 60,000 characters); for milestones only"},
                    "into": {"type": "string", "description": "merged: the baseline it was merged into"},
                    "version": {"type": "string", "description": "release: the new baseline / sync: the newer base / applied: the applied baseline"},
                    "absorbs": list("release: sessions merged into the new baseline"),
                    "targets": list("applied: decision sessions to confirm (default: the one that released the version)"),
                    "related": list("Related session IDs"),
                    "resolves": {"type": "array", "items": {"type": "integer"}, "description": "Question numbers this session settled itself"},
                    "ssot": {"type": "string", "description": "The baseline this event refers to (optional)"},
                    "chatUrl": {"type": "string", "description": "A link to this conversation (optional)"}
                },
                "required": ["event", "summary"]
            }
        },
        {
            "name": "ledger_session",
            "description": "Shows this conversation's own session: status, verdict, questions and recent events, and hands over what a person left for it (answers, notes, status changes). Use only this conversation's own ID.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session": {"type": "string", "description": "This conversation's own session ID"}
                }
            }
        }
    ])
}

/// The session a launched agent reports to when it does not name one.
fn default_session() -> Option<String> {
    std::env::var("GITROCHI_LEDGER_SESSION")
        .ok()
        .and_then(|v| crate::util::clean(&v))
}

struct Server {
    path: PathBuf,
    db: Option<Arc<db::Db>>,
}

impl Server {
    fn db(&mut self) -> Result<Arc<db::Db>> {
        if !db::enabled() {
            return Err(Error::new(
                "DISABLED",
                "The ledger is turned off (GITROCHI_LEDGER=0)",
            ));
        }
        if self.db.is_none() {
            self.db = Some(db::shared(&self.path)?);
        }
        Ok(self.db.clone().expect("opened above"))
    }

    fn tool(&mut self, name: &str, arguments: &Value) -> Result<String> {
        let mut args = if arguments.is_object() {
            arguments.clone()
        } else {
            json!({})
        };
        if arg_str_any(&args, &["session", "sessionId"]).is_none() {
            if let Some(session) = default_session() {
                args["session"] = json!(session);
            }
        }
        match name {
            "ledger_overview" => {
                let db = self.db()?;
                args["deliver"] = json!(arg_str(&args, "session").is_some());
                let (text, _) = api::overview(&db, &args, crate::util::now_ms())?;
                Ok(text)
            }
            "ledger_report" => {
                let db = self.db()?;
                let reply = api::report(&db, &args, "mcp")?;
                Ok(text::report(&reply))
            }
            "ledger_session" => {
                let id = arg_str_any(&args, &["session", "sessionId", "id"]).ok_or_else(|| {
                    Error::invalid("Missing session (this conversation's own ID)")
                })?;
                let db = self.db()?;
                Ok(api::session_text(&db, &id, true)?.0)
            }
            other => Err(Error::invalid(format!("Unknown tool: {other}"))),
        }
    }
}

fn respond(
    out: &mut impl Write,
    id: &Value,
    result: std::result::Result<Value, (i64, &str)>,
) -> io::Result<()> {
    let message = match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err((code, message)) => {
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
        }
    };
    writeln!(out, "{message}")?;
    out.flush()
}

/// Serves requests from `input` until it ends.
pub fn serve(path: PathBuf, input: impl BufRead, mut output: impl Write) -> io::Result<()> {
    let mut server = Server { path, db: None };
    let (mut initialized, mut ready) = (false, false);
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match (line.len() <= MAX_LINE)
            .then(|| serde_json::from_str::<Value>(&line).ok())
            .flatten()
        {
            Some(request) => request,
            None => {
                respond(
                    &mut output,
                    &Value::Null,
                    Err((-32700, "Invalid JSON-RPC message.")),
                )?;
                continue;
            }
        };
        let method = request["method"].as_str().unwrap_or("");
        if method == "notifications/initialized" {
            ready = initialized;
            continue;
        }
        let Some(id) = request.get("id").cloned() else {
            // Notifications get no answer.
            continue;
        };
        if request["jsonrpc"] != "2.0"
            || !(id.is_string() || id.is_number())
            || !request["method"].is_string()
        {
            respond(&mut output, &id, Err((-32600, "Invalid request.")))?;
            continue;
        }
        let params = &request["params"];
        match method {
            "ping" => respond(&mut output, &id, Ok(json!({})))?,
            "initialize" => {
                let Some(asked) = params["protocolVersion"].as_str().filter(|_| !initialized)
                else {
                    respond(&mut output, &id, Err((-32602, "Invalid initialization.")))?;
                    continue;
                };
                initialized = true;
                let version = if PROTOCOL_VERSIONS.contains(&asked) {
                    asked
                } else {
                    PROTOCOL_VERSIONS[0]
                };
                respond(
                    &mut output,
                    &id,
                    Ok(json!({
                        "protocolVersion": version,
                        "capabilities": {"tools": {"listChanged": false}},
                        "serverInfo": {"name": "gitrochi-ledger", "version": env!("CARGO_PKG_VERSION")},
                        "instructions": INSTRUCTIONS,
                    })),
                )?;
            }
            _ if !(initialized && ready) => respond(
                &mut output,
                &id,
                Err((-32002, "Initialize the connection first.")),
            )?,
            "tools/list" => respond(&mut output, &id, Ok(json!({"tools": tools()})))?,
            "tools/call" => {
                let name = params["name"].as_str().unwrap_or("");
                let result = match server.tool(name, &params["arguments"]) {
                    Ok(text) => {
                        json!({"content": [{"type": "text", "text": text}], "isError": false})
                    }
                    Err(error) => json!({
                        "content": [{"type": "text", "text": format!("Error: {}", error.message)}],
                        "isError": true
                    }),
                };
                respond(&mut output, &id, Ok(result))?;
            }
            _ => respond(&mut output, &id, Err((-32601, "Method not found.")))?,
        }
    }
    Ok(())
}
