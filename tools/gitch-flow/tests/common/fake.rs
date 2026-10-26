//! 시험용 가짜 HTTP 서버. 요청마다 처리기를 부르고 모든 요청을 기록한다.
//! 처리기가 None 을 돌려주면 응답 없이 연결을 끊는다(응답을 잃은 트리거 흉내).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub struct Req {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Req {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    /// 질의 문자열 값(퍼센트 인코딩을 푼다).
    pub fn param(&self, key: &str) -> Option<String> {
        self.query.split('&').find_map(|kv| {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            (decode(k) == key).then(|| decode(v))
        })
    }
    pub fn is(&self, method: &str, path: &str) -> bool {
        self.method == method && self.path == path
    }
}

pub fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 3 <= b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz");
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub struct Resp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Resp {
    pub fn json(v: serde_json::Value) -> Resp {
        Resp {
            status: 200,
            headers: vec![("Content-Type".into(), "application/json".into())],
            body: v.to_string(),
        }
    }
    pub fn text(status: u16, body: &str) -> Resp {
        Resp {
            status,
            headers: vec![("Content-Type".into(), "text/plain".into())],
            body: body.into(),
        }
    }
    pub fn status(status: u16) -> Resp {
        Resp::text(status, "")
    }
    pub fn code(mut self, status: u16) -> Resp {
        self.status = status;
        self
    }
    pub fn header(mut self, k: &str, v: &str) -> Resp {
        self.headers.push((k.into(), v.into()));
        self
    }
}

type Handler = dyn Fn(&Req) -> Option<Resp> + Send + Sync;

pub struct Server {
    pub base: String,
    log: Arc<Mutex<Vec<Req>>>,
}

impl Server {
    pub fn start<F>(handler: F) -> Server
    where
        F: Fn(&Req) -> Option<Resp> + Send + Sync + 'static,
    {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let log: Arc<Mutex<Vec<Req>>> = Arc::new(Mutex::new(Vec::new()));
        let h: Arc<Handler> = Arc::new(handler);
        let log2 = log.clone();
        std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(s) = s else { continue };
                let (h, log) = (h.clone(), log2.clone());
                std::thread::spawn(move || serve(s, &*h, &log));
            }
        });
        Server { base, log }
    }
    pub fn requests(&self) -> Vec<Req> {
        self.log.lock().unwrap().clone()
    }
    /// 방법이 같고 경로에 `part` 가 들어간 요청 수.
    pub fn count(&self, method: &str, part: &str) -> usize {
        self.requests()
            .iter()
            .filter(|r| r.method == method && r.path.contains(part))
            .count()
    }
}

fn serve(s: TcpStream, h: &Handler, log: &Mutex<Vec<Req>>) {
    let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut first = String::new();
    if r.read_line(&mut first).unwrap_or(0) == 0 {
        return;
    }
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let target = parts.next().unwrap_or("").to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target.clone(), String::new()),
    };
    let mut headers = Vec::new();
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    let len = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok())
        .unwrap_or(0);
    let mut body = vec![0u8; len];
    let _ = r.read_exact(&mut body);
    let req = Req {
        method,
        path,
        query,
        headers,
        body: String::from_utf8_lossy(&body).into_owned(),
    };
    log.lock().unwrap().push(req.clone());
    let mut s = s;
    match h(&req) {
        Some(resp) => {
            let reason = match resp.status {
                200 => "OK",
                201 => "Created",
                204 => "No Content",
                302 => "Found",
                401 => "Unauthorized",
                403 => "Forbidden",
                404 => "Not Found",
                429 => "Too Many Requests",
                _ => "Status",
            };
            let mut out = format!("HTTP/1.1 {} {reason}\r\n", resp.status);
            for (k, v) in &resp.headers {
                out.push_str(&format!("{k}: {v}\r\n"));
            }
            out.push_str(&format!(
                "Content-Length: {}\r\nConnection: close\r\n\r\n",
                resp.body.len()
            ));
            out.push_str(&resp.body);
            let _ = s.write_all(out.as_bytes());
            let _ = s.flush();
        }
        None => {
            // 응답 없이 끊는다.
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
    }
}
