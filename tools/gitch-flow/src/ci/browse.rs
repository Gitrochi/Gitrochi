//! Read-only Jenkins discovery. Execution continues through reviewed ci.* flow nodes.

use crate::cli::{Args, Out};
use crate::connect::{self, Connection};
use crate::http::{self, Req};
use crate::mask::Masker;
use serde_json::{json, Value};

fn permitted(c: &Connection, path: &str) -> bool {
    connect::allowed(c, path) || c.allow.iter().any(|p| p.starts_with(&format!("{path}/")))
}

fn status(v: &Value) -> &'static str {
    if v["building"] == true {
        return "running";
    }
    match v["result"].as_str() {
        Some("SUCCESS") => "success",
        Some("FAILURE" | "UNSTABLE") => "failed",
        Some("ABORTED" | "NOT_BUILT") => "canceled",
        _ => "pending",
    }
}

fn get(c: &Connection, suffix: &str, masker: &Masker) -> Result<http::Resp, String> {
    let mut headers = Vec::new();
    if let Some(token) = connect::secret(c, true) {
        masker.add_secret("connection", &token);
        let auth = match &c.user {
            Some(user) => format!("Basic {}", super::b64(&format!("{user}:{token}"))),
            None => format!("Bearer {token}"),
        };
        masker.add_secret("authorization", &auth);
        headers.push(("Authorization".into(), auth));
    }
    let url = format!("{}/{}", c.url.trim_end_matches('/'), suffix);
    let response = http::send(&Req {
        method: "GET",
        url: &url,
        headers,
        body: None,
        timeout_ms: 15_000,
        follow_redirects: true,
    })
    .map_err(|e| masker.mask(&e))?;
    if response.status >= 300 {
        return Err(format!("HTTP {}", response.status));
    }
    Ok(response)
}

fn browse(c: &Connection, path: &str, run: Option<&str>, masker: &Masker) -> Result<Value, String> {
    if c.kind != "jenkins" {
        return Err("History browsing here supports Jenkins. Use the repository CI panel for GitHub Actions and GitLab, or a ci.http module for other providers.".into());
    }
    if path.split('/').any(|s| matches!(s, "." | "..")) {
        return Err("A job path cannot contain . or .. segments.".into());
    }
    if !path.is_empty() && !permitted(c, path) {
        return Err("This job is outside the connection allow list.".into());
    }
    let job_path = super::jenkins::job_path(path);
    let prefix = if job_path.is_empty() {
        String::new()
    } else {
        format!("{job_path}/")
    };
    let mut value = json!({"schemaVersion":1,"provider":"jenkins","connection":c.name,"jobs":[],"runs":[],"log":null,"truncated":false});
    if let Some(run) = run {
        if path.is_empty() || !run.chars().all(|ch| ch.is_ascii_digit()) || run.is_empty() {
            return Err("Choose a job and a numeric build number.".into());
        }
        if !connect::allowed(c, path) {
            return Err("This job is outside the connection allow list.".into());
        }
        let response = get(c, &format!("{prefix}{run}/consoleText"), masker)?;
        // The transport limit remains bounded; the UI receives at most 256 KiB of text.
        let log = masker.mask(&response.body);
        let end = log
            .char_indices()
            .map(|(i, _)| i)
            .take_while(|i| *i <= 256 * 1024)
            .last()
            .unwrap_or(0);
        let limited = log.len() > 256 * 1024;
        value["log"] = json!(if limited { &log[..end] } else { &log });
        value["truncated"] = json!(response.truncated || limited);
        return Ok(value);
    }
    let response = get(c, &format!("{prefix}api/json?tree=jobs[name,_class],builds[number,displayName,building,result,timestamp,duration]{{0,30}}"), masker)?;
    let doc: Value = serde_json::from_str(&response.body)
        .map_err(|_| "The server did not return Jenkins JSON.".to_string())?;
    let jobs = doc["jobs"].as_array().into_iter().flatten().filter_map(|job| {
        let name = job["name"].as_str()?;
        let full = if path.is_empty() { name.to_string() } else { format!("{path}/{name}") };
        if !permitted(c, &full) { return None; }
        Some(json!({"name":name,"path":full,"url":format!("{}/{}/",c.url.trim_end_matches('/'),super::jenkins::job_path(&full)),"folder":job["_class"].as_str().is_some_and(|s|s.contains("Folder") || s.contains("MultiBranch"))}))
    }).collect::<Vec<_>>();
    let runs = if connect::allowed(c, path) {
        doc["builds"].as_array().into_iter().flatten().filter_map(|build| {
            let id = build["number"].as_u64()?.to_string();
            Some(json!({"id":id,"title":build["displayName"].as_str().unwrap_or(&id),"status":status(build),"url":format!("{}/{prefix}{id}/",c.url.trim_end_matches('/')),"startedAt":build["timestamp"].as_u64().unwrap_or(0),"durationMs":build["duration"].as_u64().unwrap_or(0)}))
        }).collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    value["jobs"] = json!(jobs);
    value["runs"] = json!(runs);
    value["truncated"] = json!(response.truncated);
    Ok(value)
}

pub fn command(out: &Out, args: &Args) -> i32 {
    let masker = Masker::new();
    let result = args
        .val("--connection")
        .and_then(|name| connect::find(&name))
        .ok_or_else(|| "Choose an existing CI connection.".to_string())
        .and_then(|c| {
            browse(
                &c,
                args.pos.get(1).map(String::as_str).unwrap_or(""),
                args.pos.get(2).map(String::as_str),
                &masker,
            )
        });
    match result {
        Ok(mut value) => {
            mask_value(&mut value, &masker);
            println!("{value}");
            0
        }
        Err(message) => {
            let message = masker.mask(&message);
            if out.json {
                eprintln!(
                    "{}",
                    json!({"schemaVersion":1,"error":{"code":"GITCH_ERROR","flowCode":"CONN-05","message":message,"exitCode":1}})
                );
            } else {
                eprintln!("{message}");
            }
            1
        }
    }
}

fn mask_value(value: &mut Value, masker: &Masker) {
    match value {
        Value::String(text) => *text = masker.mask(text),
        Value::Array(values) => values.iter_mut().for_each(|v| mask_value(v, masker)),
        Value::Object(values) => values.values_mut().for_each(|v| mask_value(v, masker)),
        _ => {}
    }
}
