//! An explicitly started loopback bridge for existing HTTP reporting clients.
mod legacy;
mod request;

use request::parse;

use crate::api::{self, Caller};
use crate::db::{self, Db};
use crate::error::{Error, Result};
use crate::util::now_ms;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{BufReader, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

const MAX_HEADER: usize = 32 * 1024;
const MAX_BODY: usize = 2 * 1024 * 1024;

struct Request {
    method: String,
    path: String,
    args: Value,
    headers: BTreeMap<String, String>,
    body: Value,
}

struct Response {
    status: u16,
    body: Vec<u8>,
    text: bool,
}

impl Response {
    fn json(status: u16, value: Value) -> Self {
        Self {
            status,
            body: value.to_string().into_bytes(),
            text: false,
        }
    }

    fn failure(status: u16, message: impl Into<String>) -> Self {
        Self::json(status, json!({"error":message.into()}))
    }
}

fn guard(request: &Request, port: u16) -> std::result::Result<(), Response> {
    let host = request
        .headers
        .get("host")
        .map(String::as_str)
        .unwrap_or("");
    let hosts = [
        format!("127.0.0.1:{port}"),
        format!("localhost:{port}"),
        format!("[::1]:{port}"),
    ];
    if !hosts
        .iter()
        .any(|allowed| allowed.eq_ignore_ascii_case(host))
    {
        return Err(Response::failure(
            403,
            "Host must be the loopback bridge address",
        ));
    }
    if let Some(origin) = request.headers.get("origin") {
        if !hosts
            .iter()
            .any(|host| origin.eq_ignore_ascii_case(&format!("http://{host}")))
        {
            return Err(Response::failure(
                403,
                "Origin must match the loopback bridge",
            ));
        }
    }
    if request
        .headers
        .get("sec-fetch-site")
        .is_some_and(|v| !matches!(v.as_str(), "same-origin" | "none"))
    {
        return Err(Response::failure(
            403,
            "Cross-site requests are not allowed",
        ));
    }
    Ok(())
}

fn route(db: &Arc<Db>, request: &Request) -> Result<(Value, Option<String>)> {
    let mut args = request.args.clone();
    let text = args["format"] == "text";
    let delivered = args["deliver"] == "1";
    let client = request
        .headers
        .get("x-ledger-client")
        .is_some_and(|v| !v.is_empty());
    args["deliver"] = json!(delivered && client);
    args["refs"] = json!(args["refs"] == "1");
    let dispatch = |method: &str, args: &Value| api::dispatch(db, Caller::Agent, method, args);
    let result = match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/api/health" | "/api/version") => {
            json!({"ok":true,"app":"gitrochi-ledger","version":env!("CARGO_PKG_VERSION"),"compatibility":"experimental","loopbackOnly":true})
        }
        ("GET", "/api/rev") => dispatch("rev", &args)?,
        ("GET", "/api/projects") => dispatch("projects", &json!({}))?,
        ("GET", "/api/state") => legacy::state(dispatch("state", &args)?),
        ("GET", "/api/attention") => legacy::attention(dispatch("state", &args)?),
        ("GET", "/api/overview") => {
            let (plain, data) = api::overview(db, &args, now_ms())?;
            return Ok((legacy::overview(data), text.then_some(plain)));
        }
        ("GET", path) if path.starts_with("/api/session/") => {
            let (plain, data) = api::session_text(db, &path[13..], delivered && client)?;
            return Ok((legacy::detail(data), text.then_some(plain)));
        }
        ("GET", "/api/work" | "/api/work/report" | "/api/work/unassigned") => {
            args["action"] = json!(match request.path.as_str() {
                "/api/work/report" => "report",
                "/api/work/unassigned" => "unassigned",
                _ => "list",
            });
            args["deliver"] = json!(false);
            legacy::work(dispatch("work", &args)?, &args)
        }
        ("GET", "/api/id" | "/api/ids" | "/api/worklist" | "/api/backflow") => {
            if !args["project"].is_string() {
                args["project"] = api::overview(db, &json!({}), now_ms())?.1["project"].clone();
            }
            args["action"] = json!(match request.path.as_str() {
                "/api/id" => "lookup",
                "/api/worklist" => "worklist",
                "/api/backflow" => "backflow",
                _ => "list",
            });
            legacy::documents(
                dispatch("documents", &args)?,
                &request.path,
                &args,
                now_ms(),
            )
        }
        ("POST", "/api/report") => {
            let result = api::report(db, &request.body, "http")?;
            let plain = crate::text::report(&result);
            return Ok((
                legacy::report(serde_json::to_value(result)?),
                text.then_some(plain),
            ));
        }
        ("POST", "/api/version") => dispatch("register_baseline", &request.body)?,
        ("POST", "/api/import") => dispatch("import", &request.body)?,
        ("POST", "/api/scan") => dispatch("scan", &request.body)?,
        ("POST", "/api/work") => {
            let mut body = request.body.clone();
            body["deliver"] = json!(body["deliver"] == true && client);
            legacy::work(dispatch("work", &body)?, &body)
        }
        _ => {
            return Err(Error::not_found(
                "This endpoint is not available in the reporting bridge",
            ))
        }
    };
    let plain = if text {
        Some(
            result["markdown"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| serde_json::to_string_pretty(&result).unwrap_or_default()),
        )
    } else {
        None
    };
    Ok((result, plain))
}

fn write(stream: &mut TcpStream, response: Response) {
    let reason = match response.status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        408 => "Request Timeout",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        _ => "Internal Server Error",
    };
    let kind = if response.text {
        "text/plain; charset=utf-8"
    } else {
        "application/json; charset=utf-8"
    };
    let headers=format!("HTTP/1.1 {} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",response.status,response.body.len());
    if stream.write_all(headers.as_bytes()).is_ok() {
        let _ = stream.write_all(&response.body);
    }
}

fn handle(stream: TcpStream, db: &Arc<Db>, port: u16) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let mut reader = BufReader::new(stream);
    let response = match parse(&mut reader).and_then(|request| {
        guard(&request, port)?;
        Ok(request)
    }) {
        Err(response) => response,
        Ok(request) => match route(db, &request) {
            Ok((value, plain)) => match plain {
                Some(plain) => Response {
                    status: 200,
                    body: plain.into_bytes(),
                    text: true,
                },
                None => Response::json(200, value),
            },
            Err(error) => Response::json(
                match error.code {
                    "NOT_FOUND" => 404,
                    "NOT_ALLOWED" => 403,
                    "CONFLICT" => 409,
                    "INVALID_ARGUMENT" => 400,
                    _ => 500,
                },
                json!({"error":error.message,"code":error.code}),
            ),
        },
    };
    write(reader.get_mut(), response);
}

/// Runs the opt-in reporting bridge; only literal loopback addresses can be bound.
pub fn serve(path: PathBuf, address: &str) -> Result<()> {
    let address: SocketAddr = address
        .parse()
        .map_err(|_| Error::invalid("Use a literal loopback address, such as 127.0.0.1:8765"))?;
    if !address.ip().is_loopback() {
        return Err(Error::not_allowed(
            "The reporting bridge listens on loopback only; use an SSH tunnel for another computer",
        ));
    }
    if !db::enabled() {
        return Err(Error::new("DISABLED", "The ledger is turned off"));
    }
    let db = db::shared(&path)?;
    let listener = TcpListener::bind(address)
        .map_err(|e| Error::new("HTTP", format!("Could not start reporting bridge: {e}")))?;
    let port = listener
        .local_addr()
        .map_err(|e| Error::new("HTTP", e.to_string()))?
        .port();
    let (sender, receiver) = mpsc::sync_channel::<TcpStream>(16);
    let receiver = Arc::new(Mutex::new(receiver));
    for _ in 0..4 {
        let receiver = receiver.clone();
        let db = db.clone();
        std::thread::spawn(move || loop {
            let stream = match receiver.lock() {
                Ok(receiver) => receiver.recv(),
                Err(_) => return,
            };
            match stream {
                Ok(stream) => handle(stream, &db, port),
                Err(_) => return,
            }
        });
    }
    eprintln!(
        "Gitrochi Ledger reporting bridge: http://{} (experimental, loopback only)",
        listener
            .local_addr()
            .map_err(|e| Error::new("HTTP", e.to_string()))?
    );
    let backup_db = db.clone();
    std::thread::spawn(move || loop {
        let result = backup_db
            .read(crate::settings::Settings::load)
            .and_then(|settings| {
                crate::backup::run(&backup_db, now_ms(), settings.backup_keep, true)
            });
        std::thread::sleep(Duration::from_secs(if result.is_ok() { 3600 } else { 300 }));
    });
    for stream in listener.incoming() {
        let mut stream = stream.map_err(|e| Error::new("HTTP", e.to_string()))?;
        if !stream
            .peer_addr()
            .map(|a| a.ip().is_loopback())
            .unwrap_or(false)
        {
            write(&mut stream, Response::failure(403, "Loopback clients only"));
            continue;
        }
        if let Err(mpsc::TrySendError::Full(mut stream)) = sender.try_send(stream) {
            let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
            write(
                &mut stream,
                Response::failure(503, "The reporting bridge is busy"),
            );
        }
    }
    Ok(())
}
