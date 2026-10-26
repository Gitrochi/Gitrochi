//! 마스킹. 이벤트 · 로그 · 보고서 · 오류는 모두 여기를 지난 뒤에만 기록 · 출력한다.
//! 순서가 중요하다: 알고 있는 비밀값(사전)을 먼저 참조 이름으로 바꾸고, 그다음 모양으로 찾는다.

use regex::{Captures, Regex};
use std::sync::{OnceLock, RwLock};

pub struct Masker {
    dict: RwLock<Vec<(String, String)>>,
    home: Option<String>,
    extra_domains: Vec<String>,
}

struct Patterns {
    url_cred: Regex,
    auth_header: Regex,
    bearer: Regex,
    key_value: Regex,
    tokens: Vec<Regex>,
    private_key: Regex,
    jwt: Regex,
    entropy: Regex,
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| Patterns {
        url_cred: Regex::new(r"(?i)\b([a-z][a-z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@").unwrap(),
        auth_header: Regex::new(r"(?i)\b(authorization|proxy-authorization|private-token|x-api-key|x-auth-token)(\s*[:=]\s*)(bearer\s+|basic\s+|token\s+)?([^\s,;]+)").unwrap(),
        bearer: Regex::new(r"(?i)\b(bearer|basic)\s+([A-Za-z0-9._~+/=\-]{12,})").unwrap(),
        key_value: Regex::new(r#"(?i)\b([A-Z0-9_.\-]*(?:token|secret|password|passwd|pwd|api[_-]?key|private[_-]?key|access[_-]?key|credential)s?)(\s*[=:]\s*)("?)([^\s"',;]{3,})"#).unwrap(),
        tokens: vec![
            Regex::new(r"\bgh[pousr]_[A-Za-z0-9]{20,}").unwrap(),
            Regex::new(r"\bgithub_pat_[A-Za-z0-9_]{20,}").unwrap(),
            Regex::new(r"\bglpat-[A-Za-z0-9_\-]{16,}").unwrap(),
            Regex::new(r"\bgl(?:dt|rt|cbt|ptt|ft|imt|agent)-[A-Za-z0-9_\-]{16,}").unwrap(),
            Regex::new(r"\bxox[abposr]-[A-Za-z0-9\-]{10,}").unwrap(),
            Regex::new(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b").unwrap(),
            Regex::new(r"\bsk-ant-[A-Za-z0-9_\-]{20,}").unwrap(),
            Regex::new(r"\bsk-[A-Za-z0-9]{20,}").unwrap(),
            Regex::new(r"\bAIza[0-9A-Za-z_\-]{30,}").unwrap(),
            Regex::new(r"\bnpm_[A-Za-z0-9]{30,}").unwrap(),
        ],
        private_key: Regex::new(r"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----").unwrap(),
        jwt: Regex::new(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}").unwrap(),
        entropy: Regex::new(r"[A-Za-z0-9+/_\-]{40,}={0,2}").unwrap(),
    })
}

const MASK: &str = "***";

fn looks_random(s: &str) -> bool {
    let core = s.trim_end_matches('=');
    if core.chars().all(|c| c.is_ascii_hexdigit()) {
        return false; // 커밋 SHA · 다이제스트는 남긴다
    }
    if core.contains('/') && core.split('/').filter(|p| !p.is_empty()).count() > 2 {
        return false; // 경로처럼 보이면 남긴다
    }
    let upper = core.chars().any(|c| c.is_ascii_uppercase());
    let lower = core.chars().any(|c| c.is_ascii_lowercase());
    let digit = core.chars().any(|c| c.is_ascii_digit());
    upper && lower && digit
}

impl Masker {
    pub fn new() -> Masker {
        let home = crate::util::home_dir()
            .map(|h| h.to_string_lossy().to_string())
            .filter(|h| h.len() > 3);
        Masker {
            dict: RwLock::new(Vec::new()),
            home,
            extra_domains: Vec::new(),
        }
    }

    /// 사용자 설정의 내부 도메인(예: corp.example)을 가린다.
    pub fn with_domains(mut self, domains: Vec<String>) -> Masker {
        self.extra_domains = domains.into_iter().filter(|d| d.contains('.')).collect();
        self
    }

    /// 실행 중 알게 된 비밀값을 사전에 넣는다. 4글자 미만은 일반 글자와 겹쳐 넣지 않는다.
    pub fn add_secret(&self, name: &str, value: &str) {
        if value.len() < 4 {
            return;
        }
        let mut d = self.dict.write().unwrap_or_else(|e| e.into_inner());
        if d.iter().any(|(v, _)| v == value) {
            return;
        }
        d.push((value.to_string(), format!("${{secrets.{name}}}")));
        // 긴 값부터 바꿔야 한 비밀이 다른 비밀의 일부일 때도 맞게 가린다.
        d.sort_by_key(|x| std::cmp::Reverse(x.0.len()));
    }

    pub fn mask(&self, input: &str) -> String {
        let p = patterns();
        let mut s = input.to_string();
        {
            let d = self.dict.read().unwrap_or_else(|e| e.into_inner());
            for (value, name) in d.iter() {
                if s.contains(value.as_str()) {
                    s = s.replace(value.as_str(), name);
                }
            }
        }
        s = p
            .private_key
            .replace_all(&s, "-----PRIVATE KEY ***-----")
            .into_owned();
        s = p
            .url_cred
            .replace_all(&s, |c: &Captures| format!("{}{}:{MASK}@", &c[1], &c[2]))
            .into_owned();
        s = p
            .auth_header
            .replace_all(&s, |c: &Captures| {
                let scheme = c.get(3).map(|m| m.as_str()).unwrap_or("");
                format!("{}{}{}{MASK}", &c[1], &c[2], scheme)
            })
            .into_owned();
        s = p
            .bearer
            .replace_all(&s, |c: &Captures| {
                if c[2].starts_with("***") || c[2].starts_with("${") {
                    c[0].to_string()
                } else {
                    format!("{} {MASK}", &c[1])
                }
            })
            .into_owned();
        s = p
            .key_value
            .replace_all(&s, |c: &Captures| {
                let v = &c[4];
                if v.starts_with("***")
                    || v.starts_with("${")
                    || v.eq_ignore_ascii_case("true")
                    || v.eq_ignore_ascii_case("false")
                    || v.eq_ignore_ascii_case("null")
                {
                    c[0].to_string()
                } else {
                    format!("{}{}{}{MASK}", &c[1], &c[2], &c[3])
                }
            })
            .into_owned();
        for re in &p.tokens {
            s = re.replace_all(&s, MASK).into_owned();
        }
        s = p.jwt.replace_all(&s, MASK).into_owned();
        s = p
            .entropy
            .replace_all(&s, |c: &Captures| {
                if looks_random(&c[0]) {
                    MASK.to_string()
                } else {
                    c[0].to_string()
                }
            })
            .into_owned();
        if let Some(h) = &self.home {
            if s.contains(h.as_str()) {
                s = s.replace(h.as_str(), "~");
            }
        }
        for dom in &self.extra_domains {
            if s.contains(dom.as_str()) {
                s = mask_domain(&s, dom);
            }
        }
        s
    }

    /// JSON 값 안의 모든 글자를 가린다.
    pub fn mask_value(&self, v: &serde_json::Value) -> serde_json::Value {
        use serde_json::Value;
        match v {
            Value::String(s) => Value::String(self.mask(s)),
            Value::Array(a) => Value::Array(a.iter().map(|x| self.mask_value(x)).collect()),
            Value::Object(o) => Value::Object(
                o.iter()
                    .map(|(k, x)| (k.clone(), self.mask_value(x)))
                    .collect(),
            ),
            other => other.clone(),
        }
    }
}

impl Default for Masker {
    fn default() -> Self {
        Masker::new()
    }
}

/// `host.corp.example` 처럼 지정 도메인으로 끝나는 호스트 이름을 `***.corp.example` 로.
fn mask_domain(s: &str, dom: &str) -> String {
    let re = Regex::new(&format!(r"(?i)\b[a-z0-9\-.]*{}\b", regex::escape(dom))).unwrap();
    re.replace_all(s, format!("***.{dom}").as_str())
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m() -> Masker {
        Masker {
            dict: RwLock::new(Vec::new()),
            home: Some("/Users/me".into()),
            extra_domains: vec!["corp.example".into()],
        }
    }

    #[test]
    fn masks_known_shapes() {
        let k = m();
        assert_eq!(
            k.mask("https://bob:hunter2@git.example.com/x"),
            "https://bob:***@git.example.com/x"
        );
        assert_eq!(
            k.mask("Authorization: Bearer abcdefghijklmnop"),
            "Authorization: Bearer ***"
        );
        // 저장소 검사(.githooks)가 진짜 토큰으로 보지 않게 시험 값은 실행 중에 이어 붙인다.
        let gl = format!("PRIVATE-TOKEN: {}{}", "glpat", "-abcdefghijklmnopqrst");
        assert_eq!(k.mask(&gl), "PRIVATE-TOKEN: ***");
        assert_eq!(
            k.mask("token ghp_abcdefghijklmnopqrstuvwxyz0123"),
            "token ***"
        );
        assert_eq!(k.mask("DB_PASSWORD=supersecret"), "DB_PASSWORD=***");
        assert_eq!(k.mask("api_key: \"abc123xyz\""), "api_key: \"***\"");
        assert_eq!(
            k.mask("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop"),
            "***"
        );
        assert_eq!(k.mask(&format!("{}{}", "AKIA", "ABCDEFGHIJKLMNOP")), "***");
        assert_eq!(
            k.mask("open /Users/me/project/a.txt"),
            "open ~/project/a.txt"
        );
        assert_eq!(k.mask("db.corp.example:5432"), "***.corp.example:5432");
    }

    #[test]
    fn keeps_hashes_and_paths() {
        let k = m();
        let sha = "3f1c0a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a";
        assert_eq!(k.mask(sha), sha);
        let digest = format!("sha256:{sha}");
        assert_eq!(k.mask(&digest), digest);
        assert_eq!(
            k.mask("src/components/flow/canvas/model/routing/table/index.ts"),
            "src/components/flow/canvas/model/routing/table/index.ts"
        );
        assert_eq!(k.mask("verbose=true"), "verbose=true");
        assert_eq!(k.mask("PASSWORD=true"), "PASSWORD=true");
    }

    #[test]
    fn dictionary_wins_and_is_idempotent() {
        let k = m();
        k.add_secret("DEPLOY_TOKEN", "s3cr3t-value-123");
        let once = k.mask("using s3cr3t-value-123 now");
        assert_eq!(once, "using ${secrets.DEPLOY_TOKEN} now");
        assert_eq!(k.mask(&once), once);
        let kv = k.mask("TOKEN=s3cr3t-value-123");
        assert_eq!(kv, "TOKEN=${secrets.DEPLOY_TOKEN}");
        assert_eq!(k.mask(&kv), kv);
        for sample in [
            "Authorization: Bearer abcdefghijklmnop",
            "https://bob:hunter2@x.example/",
            "DB_PASSWORD=supersecret",
        ] {
            let a = k.mask(sample);
            assert_eq!(k.mask(&a), a, "not idempotent for {sample}");
        }
    }

    #[test]
    fn random_looking_tokens() {
        let k = m();
        assert_eq!(
            k.mask("x Zx81Kq2LmPq9RtYv3WnB7cD4eF5gH6iJ0kL1mN2oP3 y"),
            "x *** y"
        );
    }
}
