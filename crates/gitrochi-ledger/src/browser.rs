//! A narrow native-messaging observer. Browser data never invokes agent delivery or app commands.
use crate::browser_install::{HostConfig, HOST_NAME};
use crate::{db, event, question::ReportedQuestion, session, sha1, util, Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use unicode_normalization::UnicodeNormalization;

pub const MAX_FRAME: usize = 65_536;
const MAX_REPLY: usize = 1_048_576;
static NEXT: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
struct Binding {
    db: PathBuf,
    origin: String,
    conversation: String,
    session: String,
    project: String,
    generation: i64,
}

#[derive(Default)]
pub struct Host {
    bindings: HashMap<String, Binding>,
}

fn text<'a>(value: &'a Value, name: &str, max: usize) -> Result<&'a str> {
    value[name]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= max)
        .ok_or_else(|| {
            Error::invalid(format!(
                "{name} must be nonempty text (at most {max} bytes)"
            ))
        })
}

fn fields(value: &Value, allowed: &[&str]) -> Result<()> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::invalid("A browser request must be an object"))?;
    if object.keys().any(|key| {
        !["version", "id", "op"].contains(&key.as_str()) && !allowed.contains(&key.as_str())
    }) {
        return Err(Error::invalid("Unknown browser request field"));
    }
    Ok(())
}

/// Only public conversation URLs are accepted; query strings and fragments are never stored.
pub fn canonical_conversation(raw: &str) -> Result<String> {
    let path = raw
        .strip_prefix("https://chatgpt.com/")
        .ok_or_else(|| Error::invalid("Choose a ChatGPT conversation at https://chatgpt.com"))?
        .split(['?', '#'])
        .next()
        .unwrap_or("");
    let parts: Vec<&str> = path.split('/').collect();
    let (kind, id) = match parts.as_slice() {
        [kind @ ("c" | "uc"), id] => (*kind, *id),
        ["g", slug, "c", id]
            if !slug.is_empty()
                && slug.len() <= 160
                && slug
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') =>
        {
            ("c", *id)
        }
        _ => {
            return Err(Error::invalid(
                "Open a ChatGPT conversation before connecting",
            ))
        }
    };
    if id.len() != 36
        || !id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return Err(Error::invalid("The ChatGPT conversation URL needs a UUID"));
    }
    Ok(format!(
        "https://chatgpt.com/{kind}/{}",
        id.to_ascii_lowercase()
    ))
}

fn generation(connection: &Connection, id: &str) -> Result<i64> {
    Ok(connection.query_row(
        "SELECT generation FROM browser_session_generations WHERE session_id=?1",
        [id],
        |row| row.get(0),
    )?)
}

fn active(connection: &Connection, binding: &Binding) -> Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sessions s JOIN browser_session_generations g ON g.session_id=s.id
         WHERE s.id=?1 AND s.project=?2 AND s.status='active' AND s.archived_at IS NULL AND g.generation=?3)",
        params![binding.session, binding.project, binding.generation],
        |row| row.get(0),
    )?)
}

impl Host {
    pub fn handle(&mut self, origin: &str, config: &HostConfig, request: &Value) -> Result<Value> {
        if origin != config.allowed_origin || !db::enabled() {
            self.bindings.clear();
            return Err(Error::not_allowed(
                "The browser connection is not enabled for this extension",
            ));
        }
        self.bindings
            .retain(|_, binding| binding.origin == origin && binding.db == config.db_path);
        if request["version"] != json!(1) {
            return Err(Error::invalid("Unsupported browser protocol version"));
        }
        text(request, "id", 128)?;
        let op = text(request, "op", 32)?;
        let db = db::shared(&config.db_path)?;
        match op {
            "hello" => {
                fields(request, &[])?;
                Ok(
                    json!({"hostName": HOST_NAME,"questionCapture": true,"composerPredictions": false}),
                )
            }
            "targets" => {
                fields(request, &[])?;
                db.read(|c| {
                    let projects = c.prepare("SELECT key,name FROM projects ORDER BY key LIMIT 100")?.query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<std::result::Result<Vec<_>,_>>()?;
                    let sessions = c.prepare("SELECT id,title,project FROM sessions WHERE status='active' AND archived_at IS NULL ORDER BY last_at DESC,id LIMIT 200")?.query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?)))?.collect::<std::result::Result<Vec<_>,_>>()?;
                    Ok(json!({"projects":projects.into_iter().map(|(key,name)|json!({"key":key,"name":util::truncate(&name,120)})).collect::<Vec<_>>(),"sessions":sessions.into_iter().map(|(id,title,project)|json!({"id":id,"title":util::truncate(&title,120),"project":project})).collect::<Vec<_>>() }))
                })
            }
            "bind" => {
                fields(request, &["conversationUrl", "project", "sessionId"])?;
                if self.bindings.len() >= 16 {
                    return Err(Error::invalid(
                        "Too many browser bindings on this connection",
                    ));
                }
                let conversation = canonical_conversation(text(request, "conversationUrl", 2048)?)?;
                let project = text(request, "project", 256)?.trim().to_string();
                let now = util::now_ms();
                let (session, generation) = if request.get("sessionId").is_some() {
                    let id = text(request, "sessionId", 48)?.to_string();
                    db.read(|c| {
                        let row = session::require(c, &id)?;
                        if row.project != project
                            || row.status != "active"
                            || row.archived_at.is_some()
                        {
                            return Err(Error::conflict(
                                "Choose an active session in the selected project",
                            ));
                        }
                        let generation = generation(c, &id)?;
                        Ok((id.clone(), generation))
                    })?
                } else {
                    db.write(|c| {
                        c.execute("INSERT OR IGNORE INTO projects(key,name,baseline_source,created_at) VALUES(?1,?1,'manual',?2)",params![project,now])?;
                        let id = crate::report::new_id(c,now)?;
                        c.execute("INSERT INTO sessions(id,project,title,kind,status,chat_url,channel,created_at,last_at) VALUES(?1,?2,'ChatGPT browser conversation','other','active',?3,'browser',?4,?4)",params![id,project,conversation,now])?;
                        let generation = generation(c, &id)?;
                        Ok((id, generation))
                    })?.0
                };
                let seed = format!(
                    "{}:{}:{}:{}",
                    std::process::id(),
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_nanos(),
                    NEXT.fetch_add(1, Ordering::Relaxed),
                    origin
                );
                let binding_id = sha1::hex(seed.as_bytes());
                self.bindings.insert(
                    binding_id.clone(),
                    Binding {
                        db: config.db_path.clone(),
                        origin: origin.into(),
                        conversation,
                        session: session.clone(),
                        project,
                        generation,
                    },
                );
                Ok(json!({"bindingId":binding_id,"sessionId":session}))
            }
            "capture" | "draft" | "unbind" => {
                fields(
                    request,
                    match op {
                        "capture" => &["bindingId", "sourceKey", "question"],
                        "draft" => &["bindingId", "sourceKey", "text"],
                        _ => &["bindingId"],
                    },
                )?;
                let binding_id = text(request, "bindingId", 128)?;
                let binding = self
                    .bindings
                    .get(binding_id)
                    .filter(|b| b.origin == origin && b.db == config.db_path)
                    .cloned()
                    .ok_or_else(|| {
                        Error::not_allowed("Connect this conversation again before capturing")
                    })?;
                if op == "unbind" {
                    self.bindings.remove(binding_id);
                    return Ok(json!({}));
                }
                let source = text(request, "sourceKey", 256)?;
                if op == "draft" {
                    let draft = request["text"]
                        .as_str()
                        .filter(|s| s.len() <= MAX_FRAME)
                        .ok_or_else(|| Error::invalid("Browser draft must be text"))?;
                    return db.write_changed(|c| {
                        let found: Option<(i64,String,Option<String>)> = c.query_row("SELECT q.id,q.state,q.browser_draft FROM browser_captures b JOIN questions q ON q.id=b.question_id WHERE b.origin=?1 AND b.conversation=?2 AND b.session_id=?3 AND b.source_key=?4",params![origin,binding.conversation,binding.session,source],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
                        let Some((id,state,old)) = found else { return Ok((json!({"questionId":null,"status":"missing"}),false)); };
                        if state != "open" || !active(c,&binding)? { return Ok((json!({"questionId":id,"status":"closed"}),false)); }
                        let value = (!draft.is_empty()).then_some(draft);
                        if old.as_deref() == value { return Ok((json!({"questionId":id,"status":"unchanged"}),false)); }
                        c.execute("UPDATE questions SET browser_draft=?2 WHERE id=?1",params![id,value])?;
                        Ok((json!({"questionId":id,"status":"updated"}),true))
                    }).map(|(value,_)|value);
                }
                let supplied = &request["question"];
                let allowed = ["text", "options", "multiSelect", "suggestedAnswer"];
                if supplied
                    .as_object()
                    .is_none_or(|v| v.keys().any(|k| !allowed.contains(&k.as_str())))
                {
                    return Err(Error::invalid(
                        "A captured question needs text and optional choice metadata",
                    ));
                }
                let question = ReportedQuestion::parse(supplied)?;
                if supplied
                    .get("suggestedAnswer")
                    .is_some_and(|value| !value.is_string())
                {
                    return Err(Error::invalid("Question suggestions must be text"));
                }
                if let Some(options) = supplied.get("options") {
                    let options = options
                        .as_array()
                        .ok_or_else(|| Error::invalid("Question options must be an array"))?;
                    for option in options {
                        let object = option.as_object().ok_or_else(|| {
                            Error::invalid("Question options must be objects with labels")
                        })?;
                        if object.keys().any(|key| {
                            !["label", "description", "recommended"].contains(&key.as_str())
                        }) || object
                            .get("description")
                            .is_some_and(|value| !value.is_string())
                        {
                            return Err(Error::invalid("Question descriptions must be text"));
                        }
                    }
                }
                let mut labels = std::collections::HashSet::new();
                if question
                    .form
                    .options
                    .iter()
                    .any(|o| !labels.insert(o.label.nfc().collect::<String>()))
                {
                    return Err(Error::invalid("Question option labels must be distinct"));
                }
                let digest = sha1::hex(
                    serde_json::to_string(&json!({"text":question.text,"form":question.form}))?
                        .as_bytes(),
                );
                db.write_changed(|c| {
                    if !active(c,&binding)? { return Err(Error::conflict("The connected session is no longer active")); }
                    let found: Option<(i64,String,String)> = c.query_row("SELECT b.question_id,b.digest,q.state FROM browser_captures b JOIN questions q ON q.id=b.question_id WHERE b.origin=?1 AND b.conversation=?2 AND b.session_id=?3 AND b.source_key=?4",params![origin,binding.conversation,binding.session,source],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
                    if let Some((id,original,state)) = found {
                        return Ok((json!({"questionId":id,"status":if state != "open" {"answered"} else if original == digest {"unchanged"} else {"changed"}}),false));
                    }
                    let id = event::add_reported_question(c,&binding.session,&question,util::now_ms())?;
                    c.execute("UPDATE questions SET browser_source_url=?2 WHERE id=?1",params![id,binding.conversation])?;
                    c.execute("INSERT INTO browser_captures(origin,conversation,session_id,source_key,digest,question_id) VALUES(?1,?2,?3,?4,?5,?6)",params![origin,binding.conversation,binding.session,source,digest,id])?;
                    Ok((json!({"questionId":id,"status":"created"}),true))
                }).map(|(value,_)|value)
            }
            _ => Err(Error::not_allowed("Unknown browser operation")),
        }
    }
}

/// Native messaging frames use a byte count, not character count or JSON lines.
pub fn serve(
    origin: &str,
    mut input: impl Read,
    mut output: impl Write,
    mut load: impl FnMut() -> Result<HostConfig>,
) -> io::Result<()> {
    let mut host = Host::default();
    loop {
        let mut header = [0u8; 4];
        match input.read(&mut header[..1]) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
        input.read_exact(&mut header[1..])?;
        let length = u32::from_ne_bytes(header) as usize;
        if length == 0 || length > MAX_FRAME {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid browser frame length",
            ));
        }
        let mut data = vec![0; length];
        input.read_exact(&mut data)?;
        let request = serde_json::from_slice::<Value>(&data);
        let id = request
            .as_ref()
            .ok()
            .and_then(|v| v["id"].as_str())
            .filter(|s| s.len() <= 128)
            .unwrap_or("");
        let result = match load() {
            Ok(config) => request
                .as_ref()
                .map_err(|_| Error::invalid("Browser frame must contain JSON"))
                .and_then(|value| host.handle(origin, &config, value)),
            Err(error) => {
                host.bindings.clear();
                Err(error)
            }
        };
        let response = match result {
            Ok(data) => json!({"version":1,"id":id,"ok":true,"data":data}),
            Err(error) => json!({"version":1,"id":id,"ok":false,"error":error.message}),
        };
        let bytes = serde_json::to_vec(&response)?;
        if bytes.len() > MAX_REPLY {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Browser response is too large",
            ));
        }
        output.write_all(&(bytes.len() as u32).to_ne_bytes())?;
        output.write_all(&bytes)?;
        output.flush()?;
    }
}
