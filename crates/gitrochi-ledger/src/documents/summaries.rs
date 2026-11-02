use crate::error::{Error, Result};
use crate::util::{arg_str, Ms};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

fn selected(c: &Connection, project: &str, args: &Value) -> Result<(String, String)> {
    let id = arg_str(args, "id");
    let (identity, evidence) = if let Some(id) = id {
        let state = super::snapshot(c, project, &json!({"action":"lookup","id":id}))?;
        (id, state["entries"].as_array().cloned().unwrap_or_default())
    } else {
        let root = args["root"]
            .as_str()
            .ok_or_else(|| Error::invalid("Missing document summary source"))?;
        let path = args["path"]
            .as_str()
            .ok_or_else(|| Error::invalid("Missing document summary path"))?;
        let line = args["line"]
            .as_i64()
            .filter(|n| *n > 0)
            .ok_or_else(|| Error::invalid("Missing document summary line"))?;
        let raw = c.query_row("SELECT f.entries,f.hash FROM document_files f JOIN document_roots r ON r.project=f.project AND r.path=f.root
            WHERE f.project=?1 AND f.root=?2 AND f.path=?3",params![project,root,path],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional()?;
        let mut evidence = Vec::new();
        if let Some((raw, hash)) = raw {
            let entries: Vec<Value> = serde_json::from_str(&raw)?;
            for mut entry in entries
                .into_iter()
                .filter(|e| e["line"] == line && e["id"].is_null())
            {
                entry["root"] = json!(root);
                entry["path"] = json!(path);
                entry["hash"] = json!(hash);
                evidence.push(entry);
            }
        }
        (format!("{path}:{line}"), evidence)
    };
    if evidence.is_empty() {
        return Err(Error::not_found(
            "No current document evidence for this summary",
        ));
    }
    let mut hashes: Vec<String> = evidence
        .iter()
        .map(|e| {
            format!(
                "{}/{}:{}",
                e["root"].as_str().unwrap_or(""),
                e["path"].as_str().unwrap_or(""),
                e["hash"].as_str().unwrap_or("")
            )
        })
        .collect();
    // JavaScript sorts strings as UTF-16; match the frontend cache key on every path.
    hashes.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    hashes.dedup();
    let key = json!([project, identity, hashes]).to_string();
    Ok((identity, key))
}

fn month(c: &Connection, now: Ms) -> Result<String> {
    Ok(c.query_row(
        "SELECT strftime('%Y-%m',?1/1000,'unixepoch','localtime')",
        [now],
        |r| r.get(0),
    )?)
}

pub(super) fn usage(c: &Connection, project: &str, now: Ms) -> Result<Value> {
    let month = month(c, now)?;
    let (requests,input,output)=c.query_row("SELECT requests,request_chars,response_chars FROM document_summary_usage WHERE project=?1 AND month=?2",params![project,month],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?,r.get::<_,i64>(2)?))).optional()?.unwrap_or((0,0,0));
    Ok(json!({"month":month,"requests":requests,"requestChars":input,"responseChars":output}))
}

pub(super) fn get(c: &Connection, project: &str, args: &Value, now: Ms) -> Result<Value> {
    let (_, key) = selected(c, project, args)?;
    let summary = c.query_row("SELECT text,provider,model,requested_at,created_at,request_chars,response_chars FROM document_summaries WHERE project=?1 AND source_key=?2",params![project,key],|r|Ok(json!({"text":r.get::<_,String>(0)?,"provider":r.get::<_,String>(1)?,"model":r.get::<_,String>(2)?,"requestedAt":r.get::<_,i64>(3)?,"createdAt":r.get::<_,i64>(4)?,"requestChars":r.get::<_,i64>(5)?,"responseChars":r.get::<_,i64>(6)?}))).optional()?;
    Ok(json!({"key":key,"summary":summary,"usage":usage(c,project,now)?}))
}

fn text(args: &Value, key: &str, max: usize) -> Result<String> {
    let text = args[key]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.chars().count() <= max)
        .ok_or_else(|| Error::invalid(format!("{key} must contain 1 to {max} characters")))?;
    Ok(text.to_owned())
}

pub(super) fn save(c: &Connection, project: &str, args: &Value, now: Ms) -> Result<Value> {
    let (identity, key) = selected(c, project, args)?;
    if args["key"].as_str() != Some(&key) {
        return Err(Error::conflict(
            "Document evidence changed; select it again before summarizing",
        ));
    }
    let body = text(args, "text", 60_000)?;
    let provider = text(args, "provider", 100)?;
    let model = text(args, "model", 200)?;
    let request = text(args, "requestId", 100)?;
    let started = args["requestedAt"]
        .as_i64()
        .filter(|n| *n > 0 && *n <= now + 300_000)
        .ok_or_else(|| Error::invalid("Invalid summary request time"))?;
    let input = args["requestChars"]
        .as_i64()
        .filter(|n| (0..=20_000).contains(n))
        .ok_or_else(|| Error::invalid("Invalid evidence character count"))?;
    let output = body.chars().count() as i64;
    if args
        .get("responseChars")
        .is_some_and(|v| v.as_i64() != Some(output))
    {
        return Err(Error::invalid(
            "Response character count does not match the summary",
        ));
    }
    let previous=c.query_row("SELECT requested_at,request_id FROM document_summaries WHERE project=?1 AND source_key=?2",params![project,key],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?))).optional()?;
    if previous.as_ref().is_some_and(|(_, id)| id == &request) {
        return get(c, project, args, now);
    }
    if previous.is_some_and(|(at, _)| at > started) {
        return Err(Error::conflict(
            "A newer summary was saved while this request was running",
        ));
    }
    c.execute("INSERT INTO document_summaries(project,source_key,identity,text,provider,model,requested_at,created_at,request_id,request_chars,response_chars)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT(project,source_key) DO UPDATE SET text=excluded.text,provider=excluded.provider,model=excluded.model,requested_at=excluded.requested_at,created_at=excluded.created_at,request_id=excluded.request_id,request_chars=excluded.request_chars,response_chars=excluded.response_chars",params![project,key,identity,body,provider,model,started,now,request,input,output])?;
    c.execute("INSERT INTO document_summary_usage(project,month,requests,request_chars,response_chars) VALUES (?1,?2,1,?3,?4)
        ON CONFLICT(project,month) DO UPDATE SET requests=requests+1,request_chars=request_chars+excluded.request_chars,response_chars=response_chars+excluded.response_chars",params![project,month(c,now)?,input,output])?;
    get(c, project, args, now)
}
