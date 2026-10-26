//! A small HTTP client shared by the check blocks and the remote CI adapters. Every call has a time limit.
//! Redirects are followed by hand: when the origin (scheme, host, port) changes every credential header is dropped,
//! and a redirect from https to http is refused (ureq drops only Authorization and Cookie, which would leak headers like PRIVATE-TOKEN).

use std::io::Read;
use std::time::Duration;

/// Response body limit. Past it only the start is read and `truncated` is set.
pub const BODY_CAP: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Resp {
    pub status: u16,
    pub body: String,
    pub headers: Vec<(String, String)>,
    /// The final URL, after redirects.
    pub url: String,
    pub truncated: bool,
}

impl Resp {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_str(&self.body).ok()
    }
    /// How long to wait, from `Retry-After` (seconds) or `x-ratelimit-reset` (Unix time).
    pub fn retry_after_ms(&self) -> Option<u64> {
        if let Some(s) = self
            .header("retry-after")
            .and_then(|v| v.trim().parse::<u64>().ok())
        {
            return Some(s * 1000);
        }
        let reset = self
            .header("x-ratelimit-reset")
            .and_then(|v| v.trim().parse::<u64>().ok())?;
        let now = crate::util::now_ms() / 1000;
        Some(reset.saturating_sub(now) * 1000)
    }
}

#[derive(Debug, Clone)]
pub struct Req<'a> {
    pub method: &'a str,
    pub url: &'a str,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
    pub timeout_ms: u64,
    pub follow_redirects: bool,
}

impl<'a> Req<'a> {
    pub fn get(url: &'a str) -> Req<'a> {
        Req {
            method: "GET",
            url,
            headers: Vec::new(),
            body: None,
            timeout_ms: 15_000,
            follow_redirects: false,
        }
    }
    pub fn header(mut self, k: &str, v: &str) -> Req<'a> {
        self.headers.push((k.into(), v.into()));
        self
    }
}

/// Header names that may carry secrets.
pub fn credential_header(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n == "cookie"
        || n.contains("auth")
        || n.contains("token")
        || n.contains("secret")
        || n.contains("api-key")
        || n.contains("apikey")
}

/// The URL's host in lower case; None when it cannot be parsed.
pub fn host_of(url: &str) -> Option<String> {
    url::Url::parse(url)
        .ok()?
        .host_str()
        .map(|h| h.to_ascii_lowercase())
}

/// Whether the host equals a listed name or is its subdomain (a leading dot, `.example.com`, means subdomains only).
pub fn host_matches(host: &str, allowed: &[&str]) -> bool {
    let h = host.to_ascii_lowercase();
    allowed.iter().any(|a| {
        let a = a.to_ascii_lowercase();
        if let Some(suffix) = a.strip_prefix('.') {
            h.ends_with(&format!(".{suffix}"))
        } else {
            h == a
        }
    })
}

fn origin(u: &url::Url) -> (String, Option<String>, Option<u16>) {
    (
        u.scheme().to_string(),
        u.host_str().map(|h| h.to_ascii_lowercase()),
        u.port_or_known_default(),
    )
}

fn once(
    agent: &ureq::Agent,
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<&str>,
) -> Result<Resp, String> {
    let mut req = agent.request(method, url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    let result = match body {
        Some(b) => req.send_string(b),
        None => req.call(),
    };
    let resp = match result {
        Ok(resp) => resp,
        Err(ureq::Error::Status(_, resp)) => resp,
        Err(ureq::Error::Transport(t)) => return Err(t.to_string()),
    };
    let status = resp.status();
    let final_url = resp.get_url().to_string();
    let headers: Vec<(String, String)> = resp
        .headers_names()
        .into_iter()
        .filter_map(|n| resp.header(&n).map(|v| (n.clone(), v.to_string())))
        .collect();
    let mut buf = Vec::new();
    let read = resp
        .into_reader()
        .take(BODY_CAP + 1)
        .read_to_end(&mut buf)
        .map_err(|e| e.to_string())?;
    let truncated = read as u64 > BODY_CAP;
    if truncated {
        buf.truncate(BODY_CAP as usize);
    }
    Ok(Resp {
        status,
        body: String::from_utf8_lossy(&buf).into_owned(),
        headers,
        url: final_url,
        truncated,
    })
}

/// Sends a request. 4xx and 5xx come back as responses; errors are transport problems such as a failed connection.
pub fn send(r: &Req) -> Result<Resp, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_millis(r.timeout_ms.min(10_000)))
        .timeout(Duration::from_millis(r.timeout_ms))
        .redirects(0)
        .user_agent(concat!("gitch-flow/", env!("CARGO_PKG_VERSION")))
        .build();
    let first = url::Url::parse(r.url).map_err(|e| format!("{}: {e}", r.url))?;
    let mut url = first.clone();
    let mut method = r.method.to_string();
    let mut body = r.body.clone();
    let mut headers = r.headers.clone();
    let mut hops = 0;
    loop {
        let resp = once(&agent, &method, url.as_str(), &headers, body.as_deref())?;
        let redirect = r.follow_redirects && matches!(resp.status, 301 | 302 | 303 | 307 | 308);
        let Some(loc) = resp.header("location").filter(|_| redirect) else {
            return Ok(resp);
        };
        hops += 1;
        if hops > 5 {
            return Err("too many redirects".into());
        }
        let next = url.join(loc).map_err(|e| format!("bad redirect: {e}"))?;
        if !matches!(next.scheme(), "http" | "https") {
            return Err(format!("redirect to {} refused", next.scheme()));
        }
        if url.scheme() == "https" && next.scheme() == "http" {
            return Err("redirect from https to http refused".into());
        }
        if origin(&next) != origin(&first) {
            headers.retain(|(k, _)| !credential_header(k));
        }
        if matches!(resp.status, 301..=303) && method != "GET" && method != "HEAD" {
            method = "GET".into();
            body = None;
            headers.retain(|(k, _)| !k.eq_ignore_ascii_case("content-type"));
        }
        url = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;

    /// A server that takes one request at a time and answers with canned responses, recording each request line and headers.
    fn serve(replies: Vec<String>) -> (String, std::sync::mpsc::Receiver<Vec<String>>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for reply in replies {
                let Ok((mut s, _)) = l.accept() else { return };
                let mut r = BufReader::new(s.try_clone().unwrap());
                let mut lines = Vec::new();
                loop {
                    let mut line = String::new();
                    if r.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                    lines.push(line.trim_end().to_string());
                }
                let _ = tx.send(lines);
                let _ = s.write_all(reply.as_bytes());
            }
        });
        (base, rx)
    }

    fn reply(status: &str, headers: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {status}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    #[test]
    fn same_origin_redirect_keeps_credentials_cross_origin_drops_them() {
        let (other, other_rx) = serve(vec![reply("200 OK", "", "far")]);
        let (base, rx) = serve(vec![
            reply("302 Found", "Location: /second\r\n", ""),
            reply("302 Found", &format!("Location: {other}/third\r\n"), ""),
        ]);
        let url = format!("{base}/first");
        let r = send(&Req {
            follow_redirects: true,
            ..Req::get(&url)
                .header("PRIVATE-TOKEN", "t0k3n")
                .header("Accept", "application/json")
        })
        .unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body, "far");
        let first = rx.recv().unwrap();
        let second = rx.recv().unwrap();
        let third = other_rx.recv().unwrap();
        let has =
            |req: &[String], h: &str| req.iter().any(|l| l.to_ascii_lowercase().starts_with(h));
        assert!(has(&first, "private-token"));
        assert!(has(&second, "private-token"), "same origin keeps the token");
        assert!(
            !has(&third, "private-token"),
            "another origin must not get the token"
        );
        assert!(has(&third, "accept"));
    }

    #[test]
    fn redirects_are_not_followed_unless_asked() {
        let (base, _rx) = serve(vec![reply("302 Found", "Location: /x\r\n", "")]);
        let url = format!("{base}/a");
        let r = send(&Req::get(&url)).unwrap();
        assert_eq!(r.status, 302);
        assert_eq!(r.header("location"), Some("/x"));
    }

    #[test]
    fn hosts() {
        assert_eq!(
            host_of("https://Pipelines.Actions.GitHubUserContent.com/x").as_deref(),
            Some("pipelines.actions.githubusercontent.com")
        );
        assert!(host_matches(
            "a.blob.core.windows.net",
            &[".blob.core.windows.net"]
        ));
        assert!(!host_matches(
            "evil.com",
            &[".blob.core.windows.net", "github.com"]
        ));
        assert!(!host_matches(
            "blob.core.windows.net.evil.com",
            &[".blob.core.windows.net"]
        ));
        assert!(host_matches("github.com", &["github.com"]));
        assert!(!host_matches("notgithub.com", &["github.com"]));
        assert!(credential_header("PRIVATE-TOKEN"));
        assert!(credential_header("Authorization"));
        assert!(credential_header("X-Api-Key"));
        assert!(!credential_header("Accept"));
    }
}
