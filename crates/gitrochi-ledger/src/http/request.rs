//! Bounded HTTP/1 request decoding for the local reporting bridge.
use super::{Request, Response, MAX_BODY, MAX_HEADER};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read};
use std::net::TcpStream;
use std::time::{Duration, Instant};

fn decode(raw: &str) -> std::result::Result<String, Response> {
    let mut out = Vec::new();
    let mut bytes = raw.bytes();
    while let Some(byte) = bytes.next() {
        match byte {
            b'+' => out.push(b' '),
            b'%' => {
                let hex = |b: Option<u8>| b.and_then(|b| (b as char).to_digit(16));
                let (Some(a), Some(b)) = (hex(bytes.next()), hex(bytes.next())) else {
                    return Err(Response::failure(400, "Invalid URL encoding"));
                };
                out.push((a * 16 + b) as u8);
            }
            _ => out.push(byte),
        }
    }
    String::from_utf8(out).map_err(|_| Response::failure(400, "URL must be UTF-8"))
}

pub(super) fn parse(reader: &mut BufReader<TcpStream>) -> std::result::Result<Request, Response> {
    let started = Instant::now();
    let mut total = 0;
    let mut line = String::new();
    let mut read_line =
        |reader: &mut BufReader<TcpStream>| -> std::result::Result<String, Response> {
            line.clear();
            reader
                .take((MAX_HEADER - total + 1) as u64)
                .read_line(&mut line)
                .map_err(|_| Response::failure(400, "Could not read HTTP headers"))?;
            total += line.len();
            if total > MAX_HEADER || started.elapsed() > Duration::from_secs(5) {
                return Err(Response::failure(
                    431,
                    "HTTP headers are too large or too slow",
                ));
            }
            if !line.ends_with('\n') {
                return Err(Response::failure(400, "Incomplete HTTP headers"));
            }
            Ok(line.trim_end_matches(['\r', '\n']).to_string())
        };
    let first = read_line(reader)?;
    let parts: Vec<_> = first.split(' ').collect();
    if parts.len() != 3
        || !matches!(parts[2], "HTTP/1.0" | "HTTP/1.1")
        || !parts[1].starts_with('/')
        || parts[1].starts_with("//")
    {
        return Err(Response::failure(400, "Invalid HTTP request line"));
    }
    let method = parts[0].to_string();
    let (path, query) = parts[1].split_once('?').unwrap_or((parts[1], ""));
    let path = decode(path)?;
    if path.contains(['\0', '\r', '\n']) {
        return Err(Response::failure(400, "Invalid request path"));
    }
    let mut args = json!({});
    for part in query.split('&').filter(|part| !part.is_empty()) {
        let (key, value) = part.split_once('=').unwrap_or((part, ""));
        args[decode(key)?] = json!(decode(value)?);
    }
    let mut headers = BTreeMap::new();
    loop {
        let line = read_line(reader)?;
        if line.is_empty() {
            break;
        }
        let Some((key, value)) = line.split_once(':') else {
            return Err(Response::failure(400, "Invalid HTTP header"));
        };
        if key.is_empty()
            || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || value.contains(['\0', '\r', '\n'])
        {
            return Err(Response::failure(400, "Invalid HTTP header"));
        }
        if headers
            .insert(key.to_ascii_lowercase(), value.trim().to_string())
            .is_some()
        {
            return Err(Response::failure(400, "Duplicate HTTP header"));
        }
    }
    if headers.contains_key("transfer-encoding") {
        return Err(Response::failure(400, "Transfer-Encoding is not supported"));
    }
    let length = headers
        .get("content-length")
        .map(|n| n.parse::<usize>())
        .transpose()
        .map_err(|_| Response::failure(400, "Invalid Content-Length"))?
        .unwrap_or(0);
    if length > MAX_BODY {
        return Err(Response::failure(413, "Request body is too large"));
    }
    let mut raw = vec![0; length];
    let mut position = 0;
    while position < length {
        if started.elapsed() > Duration::from_secs(5) {
            return Err(Response::failure(408, "Request timed out"));
        }
        let end = (position + 8192).min(length);
        let size = reader
            .read(&mut raw[position..end])
            .map_err(|_| Response::failure(400, "Could not read request body"))?;
        if size == 0 {
            return Err(Response::failure(400, "Incomplete request body"));
        }
        position += size;
    }
    let body = if method == "POST" {
        if !headers.contains_key("content-length") {
            return Err(Response::failure(411, "Content-Length is required"));
        }
        let media = headers
            .get("content-type")
            .and_then(|v| v.split(';').next())
            .unwrap_or("")
            .trim();
        if !media.eq_ignore_ascii_case("application/json") {
            return Err(Response::failure(
                415,
                "Content-Type must be application/json",
            ));
        }
        let value = serde_json::from_slice::<Value>(&raw)
            .map_err(|_| Response::failure(400, "Request body must be JSON"))?;
        if !value.is_object() {
            return Err(Response::failure(400, "Request body must be a JSON object"));
        }
        value
    } else {
        json!({})
    };
    Ok(Request {
        method,
        path,
        args,
        headers,
        body,
    })
}
