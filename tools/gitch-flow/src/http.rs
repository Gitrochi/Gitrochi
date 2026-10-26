//! 작은 HTTP 도구. 점검 블록과 원격 CI 어댑터가 함께 쓴다. 모든 호출은 시간 제한을 가진다.

use std::time::Duration;

#[derive(Debug, Clone)]
pub struct Resp {
    pub status: u16,
    pub body: String,
    pub headers: Vec<(String, String)>,
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

/// 요청을 보낸다. 4xx · 5xx 도 응답으로 돌려준다(오류는 연결 실패 같은 전송 문제만).
pub fn send(r: &Req) -> Result<Resp, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_millis(r.timeout_ms.min(10_000)))
        .timeout(Duration::from_millis(r.timeout_ms))
        .redirects(if r.follow_redirects { 5 } else { 0 })
        .user_agent(concat!("gitch-flow/", env!("CARGO_PKG_VERSION")))
        .build();
    let mut req = agent.request(r.method, r.url);
    for (k, v) in &r.headers {
        req = req.set(k, v);
    }
    let result = match &r.body {
        Some(b) => req.send_string(b),
        None => req.call(),
    };
    let resp = match result {
        Ok(resp) => resp,
        Err(ureq::Error::Status(_, resp)) => resp,
        Err(ureq::Error::Transport(t)) => return Err(t.to_string()),
    };
    let status = resp.status();
    let headers: Vec<(String, String)> = resp
        .headers_names()
        .into_iter()
        .filter_map(|n| resp.header(&n).map(|v| (n.clone(), v.to_string())))
        .collect();
    let body = resp.into_string().unwrap_or_default();
    Ok(Resp {
        status,
        body,
        headers,
    })
}
