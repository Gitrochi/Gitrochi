//! GitHub·GitLab·Anthropic API 요청(사내 GitLab 은 CORS 가 없어 웹뷰 대신 여기서 보낸다)

use serde::Serialize;
use std::collections::HashMap;
use std::net::ToSocketAddrs;
use std::sync::OnceLock;
use std::time::Duration;

#[derive(Serialize)]
pub struct HttpResponse {
    status: u16,
    body: String,
}

fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent("Gitrochi")
            .connect_timeout(Duration::from_secs(15))
            .build()
            .expect("HTTP client")
    })
}

#[tauri::command]
pub async fn http_request(
    method: String,
    url: String,
    headers: HashMap<String, String>,
    body: Option<String>,
    timeout_ms: Option<u64>,
) -> Result<HttpResponse, String> {
    let m = reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| e.to_string())?;
    let mut req = client()
        .request(m, &url)
        .timeout(Duration::from_millis(timeout_ms.unwrap_or(30_000)));
    for (k, v) in headers {
        req = req.header(k, v);
    }
    if let Some(b) = body {
        req = req.body(b);
    }
    let resp = req.send().await.map_err(|e| {
        if e.is_timeout() {
            format!("Request timed out: {url}")
        } else if e.is_connect() {
            format!("Couldn't connect to the server: {url}")
        } else {
            e.to_string()
        }
    })?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;
    Ok(HttpResponse { status, body })
}

fn team_hub_url(value: &str) -> Result<url::Url, String> {
    let url = url::Url::parse(value).map_err(|_| "Invalid team hub URL.")?;
    let loopback = matches!(
        url.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
    );
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !(url.scheme() == "https" || url.scheme() == "http" && loopback)
        || !url.path().contains("/api/v1/repos/")
        || !(url.path().ends_with("/presence") || url.path().ends_with("/overlaps"))
    {
        return Err("Unsupported team hub read URL.".into());
    }
    Ok(url)
}

/// Team credentials stay on the configured origin, with bounded read-only responses.
#[tauri::command]
pub async fn team_hub_read(url: String, token: String) -> Result<HttpResponse, String> {
    let url = team_hub_url(&url)?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| "Could not prepare the team hub request.")?;
    let mut response = client
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| "The team hub is unavailable. Check the connection and try again.")?;
    let status = response.status().as_u16();
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Could not read the team hub response.")?
    {
        if bytes.len() + chunk.len() > 2_000_000 {
            return Err("The team hub response is too large.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let body = String::from_utf8(bytes).map_err(|_| "The team hub response is not text.")?;
    Ok(HttpResponse { status, body })
}

/// 이미지를 받아 data: 주소로(사내 GitLab 의 프로필 사진은 토큰이 있어야 열리기도 해서 웹뷰 대신 여기서 받는다)
#[tauri::command]
pub async fn http_image(url: String, headers: HashMap<String, String>) -> Option<String> {
    let mut req = client().get(&url).timeout(Duration::from_secs(15));
    for (k, v) in headers {
        req = req.header(k, v);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let kind = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_string();
    if !kind.starts_with("image/") {
        return None;
    }
    let bytes = resp.bytes().await.ok()?;
    if bytes.is_empty() || bytes.len() > 2_000_000 {
        return None;
    }
    Some(format!("data:{kind};base64,{}", base64(&bytes)))
}

pub(crate) fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// 호스트 이름이 가리키는 IP 주소들(같은 서버의 다른 도메인인지 볼 때)
#[tauri::command]
pub async fn resolve_host(host: String) -> Vec<String> {
    tauri::async_runtime::spawn_blocking(move || {
        (host.as_str(), 443)
            .to_socket_addrs()
            .map(|it| it.map(|a| a.ip().to_string()).collect())
            .unwrap_or_default()
    })
    .await
    .unwrap_or_default()
}

#[derive(Serialize)]
pub struct CILogResponse {
    body: String,
    truncated: bool,
}

fn ci_log_redirect_allowed(url: &url::Url) -> bool {
    if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() {
        return false;
    }
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    host == "api.github.com"
        || host == "github.com"
        || host.ends_with(".githubusercontent.com")
        || host.ends_with(".blob.core.windows.net")
}

/// Job logs use a separate bounded client. Tokens never follow redirects.
#[tauri::command]
pub async fn ci_job_log(
    provider: String,
    api_base: String,
    repo_path: String,
    job_id: u64,
    token: String,
) -> Result<CILogResponse, String> {
    if job_id == 0
        || !["github", "gitlab"].contains(&provider.as_str())
        || repo_path
            .split('/')
            .any(|s| s.is_empty() || s == "." || s == "..")
    {
        return Err("Invalid CI log request.".into());
    }
    let base = url::Url::parse(&api_base).map_err(|_| "Invalid CI server.")?;
    if base.scheme() != "https"
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
    {
        return Err("CI logs require an HTTPS server address.".into());
    }
    if provider == "github"
        && (base.host_str() != Some("api.github.com")
            || base.port_or_known_default() != Some(443)
            || base.path() != "/")
    {
        return Err("Invalid GitHub API server.".into());
    }
    if provider == "gitlab" && !base.path().trim_end_matches('/').ends_with("/api/v4") {
        return Err("Invalid GitLab API server.".into());
    }
    let mut endpoint = base.clone();
    {
        let mut parts = endpoint
            .path_segments_mut()
            .map_err(|_| "Invalid CI server.")?;
        parts.pop_if_empty();
        if provider == "github" {
            parts.push("repos");
            for s in repo_path.split('/') {
                parts.push(s);
            }
            parts
                .push("actions")
                .push("jobs")
                .push(&job_id.to_string())
                .push("logs");
        } else {
            parts
                .push("projects")
                .push(&repo_path)
                .push("jobs")
                .push(&job_id.to_string())
                .push("trace");
        }
    }
    let bounded = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("Gitrochi")
        .connect_timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| "Could not create the log client.")?;
    let mut next = endpoint;
    for hop in 0..5 {
        let mut req = bounded.get(next.clone()).timeout(Duration::from_secs(30));
        if hop == 0 {
            req = if provider == "github" {
                req.bearer_auth(&token)
            } else {
                req.header("PRIVATE-TOKEN", &token)
            };
        }
        let mut response = req.send().await.map_err(|_| {
            "Could not load the CI log. Check the connection or open it in the browser."
        })?;
        if response.status().is_redirection() {
            if provider != "github" {
                return Err("The GitLab log redirected. Open the job in the browser.".into());
            }
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or("The log redirect had no address.")?;
            let destination = next.join(location).map_err(|_| "Invalid log redirect.")?;
            if !ci_log_redirect_allowed(&destination) {
                return Err("The log server redirected to an unsupported address. Open the job in the browser.".into());
            }
            next = destination;
            continue;
        }
        if !response.status().is_success() {
            return Err(format!("CI log request failed ({}). Open the job in the browser if the log is not available yet.", response.status().as_u16()));
        }
        const LIMIT: usize = 2_000_000;
        let mut data = Vec::new();
        let mut truncated = false;
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "The log download was interrupted.")?
        {
            if data.len() + chunk.len() > LIMIT {
                data.extend_from_slice(&chunk[..LIMIT - data.len()]);
                truncated = true;
                break;
            }
            data.extend_from_slice(&chunk);
        }
        let mut body = String::from_utf8_lossy(&data).into_owned();
        if !token.is_empty() {
            body = body.replace(&token, "[redacted]");
        }
        return Ok(CILogResponse { body, truncated });
    }
    Err("The log server redirected too many times.".into())
}

#[cfg(test)]
mod ci_log_tests {
    use super::*;
    #[test]
    fn team_hub_read_boundaries() {
        for value in [
            "https://hub.example.com/api/v1/repos/example.com/team/app/presence",
            "http://127.0.0.1:7420/api/v1/repos/example.com/team/app/overlaps",
        ] {
            assert!(team_hub_url(value).is_ok());
        }
        for value in [
            "http://hub.example.com/api/v1/repos/example.com/a/b/presence",
            "https://token@hub.example.com/api/v1/repos/a/b/overlaps",
            "https://hub.example.com/api/v1/tokens",
            "https://hub.example.com/api/v1/repos/a/b/overlaps?token=secret",
        ] {
            assert!(team_hub_url(value).is_err());
        }
    }
    #[test]
    fn redirect_boundaries() {
        for s in [
            "https://api.github.com/a",
            "https://logs.actions.githubusercontent.com/a",
            "https://results.blob.core.windows.net/a",
        ] {
            assert!(ci_log_redirect_allowed(&url::Url::parse(s).unwrap()));
        }
        for s in [
            "http://logs.actions.githubusercontent.com/a",
            "https://api.github.com.evil.test/a",
            "https://evilgithubusercontent.com/a",
            "https://githubusercontent.com@evil.test/a",
            "https://u:p@api.github.com/a",
        ] {
            assert!(!ci_log_redirect_allowed(&url::Url::parse(s).unwrap()));
        }
    }
}
