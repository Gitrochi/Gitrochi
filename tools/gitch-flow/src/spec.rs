//! 흐름 파일 규격 v1(`.gitch/flow.yml`). 읽고 · 겹치고 · 검사해서 형식 있는 모델로 만든다.
//! 오류는 모두 `파일:줄 경로: 설명` 과 실패 코드로 돌려준다(한 번에 여러 개).

use crate::expr;
use crate::util::tr;
use crate::yaml::{self, Doc};
use serde_json::{json, Map, Value};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default)]
pub struct Src {
    pub file: String,
    pub line: Option<usize>,
}

impl Src {
    pub fn show(&self) -> String {
        match self.line {
            Some(l) => format!("{}:{l}", self.file),
            None => self.file.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SpecError {
    pub code: &'static str,
    pub file: String,
    pub line: Option<usize>,
    pub path: String,
    pub message: String,
}

impl SpecError {
    pub fn human(&self) -> String {
        let loc = match self.line {
            Some(l) => format!("{}:{l}", self.file),
            None => self.file.clone(),
        };
        if self.path.is_empty() {
            format!("{loc}: [{}] {}", self.code, self.message)
        } else {
            format!("{loc}: {}: [{}] {}", self.path, self.code, self.message)
        }
    }
    pub fn to_json(&self) -> Value {
        json!({"code": self.code, "file": self.file, "line": self.line, "path": self.path, "message": self.message,
               "description": crate::codes::describe(self.code), "action": crate::codes::action(self.code)})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvClass {
    Dev,
    Sandbox,
    Staging,
    Prod,
}

impl EnvClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            EnvClass::Dev => "dev",
            EnvClass::Sandbox => "sandbox",
            EnvClass::Staging => "staging",
            EnvClass::Prod => "prod",
        }
    }
    pub fn parse(s: &str) -> Option<EnvClass> {
        match s {
            "dev" | "local" | "development" => Some(EnvClass::Dev),
            "sandbox" | "test" => Some(EnvClass::Sandbox),
            "staging" | "verify" | "stage" => Some(EnvClass::Staging),
            "prod" | "production" => Some(EnvClass::Prod),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Environment {
    pub name: String,
    pub class: EnvClass,
    pub executor: Option<String>,
    pub connection: Option<String>,
    pub vars: Vec<(String, String)>,
    pub src: Src,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlakyPolicy {
    Fail,
    Warn,
}

#[derive(Debug, Clone)]
pub struct Retry {
    pub max: u32,
    pub flaky: FlakyPolicy,
}

#[derive(Debug, Clone, Default)]
pub struct Expect {
    pub min_tests: Option<u64>,
    pub pass_rate: Option<f64>,
    pub result: Option<String>,
    pub output: Option<String>,
    pub exit: Option<Vec<i64>>,
    pub raw: Value,
}

#[derive(Debug, Clone, Default)]
pub struct Select {
    pub affected: bool,
    pub tags: Vec<String>,
    pub paths: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ServiceDef {
    pub name: String,
    pub uses: String,
    pub with: Value,
    pub needs: Vec<String>,
    pub src: Src,
}

#[derive(Debug, Clone)]
pub struct SuiteDef {
    pub name: String,
    pub uses: String,
    pub with: Value,
    pub select: Select,
    pub expect: Expect,
    pub retry: Option<Retry>,
    pub services: Vec<String>,
    pub tags: Vec<String>,
    pub paths: Vec<String>,
    pub timeout_ms: Option<u64>,
    pub always_run: bool,
    pub src: Src,
}

#[derive(Debug, Clone, PartialEq)]
pub enum NodeKind {
    Use(String),
    Run(String),
    Suite(String),
    Flow(String),
}

#[derive(Debug, Clone, Default)]
pub struct CacheDef {
    pub inputs: Vec<String>,
    pub key: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct NodeDef {
    pub id: String,
    pub kind: NodeKind,
    pub needs: Vec<String>,
    pub cond: Option<String>,
    pub with: Value,
    pub env: Vec<(String, String)>,
    pub secrets: Vec<(String, String)>,
    pub services: Vec<String>,
    pub executor: Option<String>,
    pub timeout_ms: Option<u64>,
    pub retry: Option<Retry>,
    pub cache: Option<CacheDef>,
    pub expect: Expect,
    pub outputs: Vec<(String, String)>,
    pub locks: Vec<String>,
    pub optional: bool,
    pub on_failure: Vec<NodeDef>,
    pub shell: Option<String>,
    pub cwd: Option<String>,
    pub weight: Option<u32>,
    pub description: Option<String>,
    /// 조합마다 노드 하나: `{ node: [18, 20, 22] }`.
    pub matrix: Vec<(String, Vec<Value>)>,
    pub src: Src,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RollbackScope {
    Node,
    Flow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Concurrency {
    Reject,
    Queue,
    CancelPrevious,
    Parallel,
}

#[derive(Debug, Clone)]
pub struct FlowDef {
    pub name: String,
    pub description: Option<String>,
    pub trigger: Vec<String>,
    pub env: Option<String>,
    pub fail_fast: bool,
    pub concurrency: Concurrency,
    pub rollback_scope: Option<RollbackScope>,
    pub rollback_on_check_failure: bool,
    /// 되돌림 전체 예산.
    pub rollback_timeout_ms: Option<u64>,
    /// 실행이 끝나면 보낼 알림.
    pub notify: Vec<NotifyDef>,
    pub timeout_ms: Option<u64>,
    pub nodes: Vec<NodeDef>,
    pub src: Src,
}

/// 흐름 끝 알림 하나.
#[derive(Debug, Clone)]
pub struct NotifyDef {
    /// success · failure · cancelled · always
    pub on: Vec<String>,
    pub webhook: Option<String>,
    pub desktop: bool,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvPolicy {
    /// 호스트 환경을 물려주되 비밀처럼 보이는 이름은 뺀다(기본).
    Inherit,
    /// 허용 목록 + 기본 목록만.
    Allowlist,
}

#[derive(Debug, Clone)]
pub struct Defaults {
    pub timeout_ms: Option<u64>,
    pub env: Vec<String>,
    pub env_policy: EnvPolicy,
    pub shell: Option<String>,
    pub jobs: Option<usize>,
}

impl Default for Defaults {
    fn default() -> Self {
        Defaults {
            timeout_ms: None,
            env: Vec::new(),
            env_policy: EnvPolicy::Inherit,
            shell: None,
            jobs: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct InputDef {
    pub name: String,
    pub ty: String,
    pub default: Option<Value>,
    pub required: bool,
    pub description: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CompositeDef {
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    pub inputs: Vec<InputDef>,
    pub outputs: Vec<(String, String)>,
    pub nodes: Vec<NodeDef>,
    pub src: Src,
}

#[derive(Debug, Clone)]
pub struct SpecFile {
    pub rel: String,
    pub sha256: String,
}

#[derive(Debug, Clone)]
pub struct Spec {
    pub root: PathBuf,
    pub files: Vec<SpecFile>,
    pub version: u32,
    pub project_name: Option<String>,
    pub defaults: Defaults,
    pub environments: Vec<Environment>,
    pub services: Vec<ServiceDef>,
    pub suites: Vec<SuiteDef>,
    pub flows: Vec<FlowDef>,
    pub blocks: Vec<CompositeDef>,
    pub flaky: Vec<Quarantine>,
}

/// `.gitch/flaky.yml` 의 격리 항목.
#[derive(Debug, Clone)]
pub struct Quarantine {
    pub test: String,
    pub owner: String,
    pub until: String,
    pub reason: Option<String>,
}

impl Spec {
    pub fn flow(&self, name: &str) -> Option<&FlowDef> {
        self.flows.iter().find(|f| f.name == name)
    }
    pub fn suite(&self, name: &str) -> Option<&SuiteDef> {
        self.suites.iter().find(|s| s.name == name)
    }
    pub fn service(&self, name: &str) -> Option<&ServiceDef> {
        self.services.iter().find(|s| s.name == name)
    }
    pub fn environment(&self, name: &str) -> Option<&Environment> {
        self.environments.iter().find(|e| e.name == name)
    }
    pub fn composite(&self, name: &str) -> Option<&CompositeDef> {
        self.blocks.iter().find(|b| b.name == name)
    }
    /// 신뢰 해시에 넣는 파일들의 해시.
    pub fn files_hash(&self) -> String {
        let mut s = String::new();
        for f in &self.files {
            s.push_str(&f.rel);
            s.push('\0');
            s.push_str(&f.sha256);
            s.push('\n');
        }
        crate::util::sha256_hex(s.as_bytes())
    }
}

// ---------- 검사 도구 ----------

struct V<'a> {
    file: String,
    doc: &'a Doc,
    errs: &'a mut Vec<SpecError>,
}

fn kind_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "list",
        Value::Object(_) => "map",
    }
}

fn join(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_string()
    } else {
        format!("{path}.{key}")
    }
}

impl<'a> V<'a> {
    fn src(&self, path: &str) -> Src {
        Src {
            file: self.file.clone(),
            line: self.doc.line_of(path),
        }
    }
    fn err(&mut self, code: &'static str, path: &str, message: String) {
        let line = self.doc.line_of(path);
        self.errs.push(SpecError {
            code,
            file: self.file.clone(),
            line,
            path: path.to_string(),
            message,
        });
    }
    fn obj<'v>(&mut self, v: &'v Value, path: &str) -> Option<&'v Map<String, Value>> {
        match v {
            Value::Object(m) => Some(m),
            Value::Null => None,
            other => {
                self.err(
                    "SPEC-03",
                    path,
                    tr(
                        &format!("맵이어야 하는데 {} 입니다.", kind_name(other)),
                        &format!("expected a map, found {}.", kind_name(other)),
                    ),
                );
                None
            }
        }
    }
    fn keys(&mut self, m: &Map<String, Value>, path: &str, allowed: &[&str]) {
        for k in m.keys() {
            if k.starts_with("x-") || allowed.contains(&k.as_str()) {
                continue;
            }
            let p = join(path, k);
            let hint = allowed
                .iter()
                .find(|a| similar(a, k))
                .map(|a| tr(&format!(" '{a}' 인가요?"), &format!(" Did you mean '{a}'?")))
                .unwrap_or_default();
            self.err(
                "SPEC-02",
                &p,
                tr(
                    &format!("알 수 없는 키 '{k}'.{hint}"),
                    &format!("unknown key '{k}'.{hint}"),
                ),
            );
        }
    }
    fn text(&mut self, v: &Value, path: &str) -> Option<String> {
        match v {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            Value::Bool(b) => Some(b.to_string()),
            Value::Null => None,
            other => {
                self.err(
                    "SPEC-03",
                    path,
                    tr(
                        &format!("글자여야 하는데 {} 입니다.", kind_name(other)),
                        &format!("expected text, found {}.", kind_name(other)),
                    ),
                );
                None
            }
        }
    }
    /// 글자 하나 또는 글자 목록.
    fn texts(&mut self, v: &Value, path: &str) -> Vec<String> {
        match v {
            Value::Null => Vec::new(),
            Value::Array(a) => {
                let mut out = Vec::new();
                for (i, x) in a.iter().enumerate() {
                    if let Some(s) = self.text(x, &format!("{path}[{i}]")) {
                        out.push(s);
                    }
                }
                out
            }
            other => self.text(other, path).into_iter().collect(),
        }
    }
    fn boolean(&mut self, v: &Value, path: &str) -> Option<bool> {
        match v {
            Value::Bool(b) => Some(*b),
            Value::Null => None,
            other => {
                self.err(
                    "SPEC-03",
                    path,
                    tr(
                        &format!("true 나 false 여야 하는데 {} 입니다.", kind_name(other)),
                        &format!("expected true or false, found {}.", kind_name(other)),
                    ),
                );
                None
            }
        }
    }
    fn number(&mut self, v: &Value, path: &str) -> Option<f64> {
        match v {
            Value::Number(n) => n.as_f64(),
            Value::Null => None,
            other => {
                self.err(
                    "SPEC-03",
                    path,
                    tr(
                        &format!("숫자여야 하는데 {} 입니다.", kind_name(other)),
                        &format!("expected a number, found {}.", kind_name(other)),
                    ),
                );
                None
            }
        }
    }
    fn duration(&mut self, v: &Value, path: &str) -> Option<u64> {
        let t = match v {
            Value::Null => return None,
            Value::Number(n) => return n.as_f64().map(|f| (f * 1000.0) as u64),
            Value::String(s) => s.clone(),
            other => {
                self.err(
                    "SPEC-03",
                    path,
                    tr(
                        &format!(
                            "시간(예: 90s, 10m)이어야 하는데 {} 입니다.",
                            kind_name(other)
                        ),
                        &format!(
                            "expected a duration such as 90s or 10m, found {}.",
                            kind_name(other)
                        ),
                    ),
                );
                return None;
            }
        };
        match crate::util::parse_duration(&t) {
            Some(ms) => Some(ms),
            None => {
                self.err(
                    "SPEC-03",
                    path,
                    tr(
                        &format!("'{t}' 은(는) 시간 형식이 아닙니다(예: 90s, 10m, 1h)."),
                        &format!("'{t}' is not a duration (for example 90s, 10m, 1h)."),
                    ),
                );
                None
            }
        }
    }
    fn string_map(&mut self, v: &Value, path: &str) -> Vec<(String, String)> {
        let mut out = Vec::new();
        if let Some(m) = self.obj(v, path) {
            for (k, x) in m {
                let p = join(path, k);
                match x {
                    Value::Object(_) | Value::Array(_) => self.err(
                        "SPEC-03",
                        &p,
                        tr("글자 값이어야 합니다.", "expected a text value."),
                    ),
                    Value::Null => out.push((k.clone(), String::new())),
                    other => out.push((k.clone(), expr::to_text(other))),
                }
            }
        }
        out
    }
    fn name_ok(&mut self, name: &str, path: &str) -> bool {
        let ok = !name.is_empty()
            && name
                .chars()
                .next()
                .map(|c| c.is_ascii_alphanumeric())
                .unwrap_or(false)
            && name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c));
        if !ok {
            self.err(
                "SPEC-03",
                path,
                tr(
                    &format!("이름 '{name}' 은(는) 영문 · 숫자 · . _ - 만 쓸 수 있습니다."),
                    &format!("name '{name}' may only use letters, digits, '.', '_' and '-'."),
                ),
            );
        }
        ok
    }
    /// 글자 안의 표현식 문법 · 이름 검사. `allow_secrets` 가 거짓이면 secrets 참조를 막는다.
    fn exprs_in(&mut self, v: &Value, path: &str, allow_secrets: bool) {
        match v {
            Value::String(s) => match expr::find(s) {
                Ok(spans) => {
                    for (_, _, inner) in spans {
                        match expr::parse(&inner) {
                            Ok(n) => {
                                let mut refs = Vec::new();
                                if let Err(e) = expr::references(&n, &mut refs, false) {
                                    self.err(
                                        "SPEC-06",
                                        path,
                                        format!("${{{{ {inner} }}}}: {}", e.0),
                                    );
                                } else if !allow_secrets && refs.iter().any(|r| r[0] == "secrets") {
                                    self.err(
                                        "SPEC-07",
                                        path,
                                        tr(
                                            "비밀값은 env: 로만 넘길 수 있습니다.",
                                            "secrets can only be passed through env:.",
                                        ),
                                    );
                                }
                            }
                            Err(e) => {
                                self.err("SPEC-06", path, format!("${{{{ {inner} }}}}: {}", e.0))
                            }
                        }
                    }
                }
                Err(e) => self.err("SPEC-06", path, e.0),
            },
            Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    self.exprs_in(x, &format!("{path}[{i}]"), allow_secrets);
                }
            }
            Value::Object(o) => {
                for (k, x) in o {
                    self.exprs_in(x, &join(path, k), allow_secrets);
                }
            }
            _ => {}
        }
    }
}

/// 철자 실수 힌트: 한 글자 차이까지.
fn similar(a: &str, b: &str) -> bool {
    if a == b {
        return false;
    }
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if (a.len() as i64 - b.len() as i64).abs() > 1 {
        return false;
    }
    let mut dp = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for (i, row) in dp.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in dp[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            dp[i][j] = (dp[i - 1][j] + 1)
                .min(dp[i][j - 1] + 1)
                .min(dp[i - 1][j - 1] + cost);
        }
    }
    dp[a.len()][b.len()] <= 1
}

const TOP_KEYS: &[&str] = &[
    "version",
    "project",
    "defaults",
    "environments",
    "services",
    "suites",
    "flows",
    "packs",
];
const NODE_KEYS: &[&str] = &[
    "use",
    "run",
    "suite",
    "flow",
    "needs",
    "if",
    "with",
    "env",
    "secrets",
    "services",
    "executor",
    "timeout",
    "retry",
    "cache",
    "expect",
    "outputs",
    "locks",
    "optional",
    "on-failure",
    "shell",
    "cwd",
    "weight",
    "description",
    "name",
    "undo",
    "matrix",
];

fn parse_retry(v: &mut V, val: &Value, path: &str) -> Option<Retry> {
    match val {
        Value::Null => None,
        Value::Number(n) => Some(Retry {
            max: n.as_u64().unwrap_or(0) as u32,
            flaky: FlakyPolicy::Fail,
        }),
        other => {
            let m = v.obj(other, path)?;
            v.keys(m, path, &["max", "flaky"]);
            let max = m
                .get("max")
                .and_then(|x| v.number(x, &join(path, "max")))
                .unwrap_or(1.0) as u32;
            let flaky = match m
                .get("flaky")
                .and_then(|x| v.text(x, &join(path, "flaky")))
                .as_deref()
            {
                None | Some("fail") => FlakyPolicy::Fail,
                Some("warn") => FlakyPolicy::Warn,
                Some(o) => {
                    v.err(
                        "SPEC-03",
                        &join(path, "flaky"),
                        tr(
                            &format!("'{o}' 대신 fail 또는 warn."),
                            &format!("use fail or warn instead of '{o}'."),
                        ),
                    );
                    FlakyPolicy::Fail
                }
            };
            if max > 5 {
                v.err(
                    "SPEC-03",
                    &join(path, "max"),
                    tr("재시도는 5번까지입니다.", "retry max is 5."),
                );
            }
            Some(Retry {
                max: max.min(5),
                flaky,
            })
        }
    }
}

fn parse_expect(v: &mut V, val: &Value, path: &str) -> Expect {
    let mut e = Expect {
        raw: val.clone(),
        ..Default::default()
    };
    if let Some(m) = v.obj(val, path) {
        // 블록마다 받는 키가 달라 여기서는 공통 키만 형식을 본다. 나머지는 블록이 검사한다.
        if let Some(x) = m.get("minTests") {
            e.min_tests = v.number(x, &join(path, "minTests")).map(|f| f as u64);
        }
        if let Some(x) = m.get("passRate") {
            e.pass_rate = v.number(x, &join(path, "passRate"));
            if let Some(r) = e.pass_rate {
                if !(0.0..=1.0).contains(&r) {
                    v.err(
                        "SPEC-03",
                        &join(path, "passRate"),
                        tr(
                            "passRate 는 0 과 1 사이입니다.",
                            "passRate must be between 0 and 1.",
                        ),
                    );
                }
            }
        }
        if let Some(x) = m.get("result") {
            e.result = v.text(x, &join(path, "result"));
        }
        if let Some(x) = m.get("output") {
            e.output = v.text(x, &join(path, "output"));
        }
        if let Some(x) = m.get("exit") {
            let p = join(path, "exit");
            e.exit = Some(match x {
                Value::Number(n) => vec![n.as_i64().unwrap_or(0)],
                Value::Array(a) => a.iter().filter_map(|y| y.as_i64()).collect(),
                _ => {
                    v.err(
                        "SPEC-03",
                        &p,
                        tr(
                            "숫자 또는 숫자 목록이어야 합니다.",
                            "expected a number or a list of numbers.",
                        ),
                    );
                    vec![0]
                }
            });
        }
    }
    e
}

fn parse_node(v: &mut V, id: &str, val: &Value, path: &str, depth: usize) -> Option<NodeDef> {
    v.name_ok(id, path);
    // 줄임: `lint: npm run lint` 는 run 노드.
    if let Value::String(s) = val {
        v.exprs_in(val, path, false);
        return Some(NodeDef {
            id: id.to_string(),
            kind: NodeKind::Run(s.clone()),
            needs: Vec::new(),
            cond: None,
            with: Value::Null,
            env: Vec::new(),
            secrets: Vec::new(),
            services: Vec::new(),
            executor: None,
            timeout_ms: None,
            retry: None,
            cache: None,
            expect: Expect::default(),
            outputs: Vec::new(),
            locks: Vec::new(),
            optional: false,
            on_failure: Vec::new(),
            shell: None,
            cwd: None,
            weight: None,
            description: None,
            matrix: Vec::new(),
            src: v.src(path),
        });
    }
    let m = v.obj(val, path)?;
    v.keys(m, path, NODE_KEYS);
    let kinds: Vec<&str> = ["use", "run", "suite", "flow"]
        .into_iter()
        .filter(|k| m.contains_key(*k))
        .collect();
    let kind = match kinds.as_slice() {
        [one] => {
            let p = join(path, one);
            let t = v.text(&m[*one], &p).unwrap_or_default();
            if t.is_empty() {
                v.err("SPEC-03", &p, tr("값이 비었습니다.", "value is empty."));
            }
            match *one {
                "use" => NodeKind::Use(t),
                "run" => {
                    v.exprs_in(&m["run"], &p, false);
                    NodeKind::Run(t)
                }
                "suite" => NodeKind::Suite(t),
                _ => NodeKind::Flow(t),
            }
        }
        [] => {
            v.err(
                "SPEC-03",
                path,
                tr(
                    "use · run · suite · flow 중 하나가 필요합니다.",
                    "needs one of use, run, suite or flow.",
                ),
            );
            NodeKind::Run(String::new())
        }
        _ => {
            v.err(
                "SPEC-03",
                path,
                tr(
                    &format!(
                        "{} 는 함께 쓸 수 없습니다. 하나만 고르세요.",
                        kinds.join(" · ")
                    ),
                    &format!("{} cannot be combined; pick one.", kinds.join(", ")),
                ),
            );
            NodeKind::Run(String::new())
        }
    };
    let get = |k: &str| m.get(k).cloned().unwrap_or(Value::Null);
    let needs = v.texts(&get("needs"), &join(path, "needs"));
    let cond = m.get("if").and_then(|x| v.text(x, &join(path, "if")));
    if let Some(c) = &cond {
        if let Err(e) = expr::parse_cond(c) {
            v.err("SPEC-06", &join(path, "if"), format!("if: {}", e.0));
        }
    }
    let mut with = get("with");
    if !with.is_null() && !with.is_object() {
        v.err(
            "SPEC-03",
            &join(path, "with"),
            tr("with 는 맵이어야 합니다.", "with must be a map."),
        );
    }
    v.exprs_in(&with, &join(path, "with"), false);
    // `undo:` 는 run 노드의 줄임(with.undo). 다른 블록은 그 블록의 되돌림 입력을 with 에 쓴다.
    if let Some(u) = m.get("undo") {
        let p = join(path, "undo");
        if !matches!(kind, NodeKind::Run(_)) {
            v.err(
                "SPEC-03",
                &p,
                tr(
                    "undo: 는 run 노드에만 씁니다. 다른 블록은 with 에 그 블록의 되돌림 입력을 쓰세요.",
                    "undo: is for run nodes only; other blocks take their undo input in with.",
                ),
            );
        } else if !(u.is_string() || u.get("run").map(|r| r.is_string()).unwrap_or(false)) {
            v.err(
                "SPEC-03",
                &p,
                tr(
                    "undo 는 명령 글이거나 { run, check, timeout, always } 입니다.",
                    "undo is a command string or { run, check, timeout, always }.",
                ),
            );
        } else {
            v.exprs_in(u, &p, false);
            let mut w = with.as_object().cloned().unwrap_or_default();
            w.insert("undo".into(), u.clone());
            with = Value::Object(w);
        }
    }
    let env_v = get("env");
    v.exprs_in(&env_v, &join(path, "env"), true);
    let env = v.string_map(&env_v, &join(path, "env"));
    let secrets = v.string_map(&get("secrets"), &join(path, "secrets"));
    let services = v.texts(&get("services"), &join(path, "services"));
    let executor = m
        .get("executor")
        .and_then(|x| v.text(x, &join(path, "executor")));
    if let Some(e) = &executor {
        // 조합 · 입력 값을 쓰는 실행 위치는 계획 때 풀어서 본다.
        if !e.contains("${{") {
            if let Err(msg) = crate::executor::Executor::parse(e) {
                v.err("SPEC-03", &join(path, "executor"), msg);
            }
        }
    }
    let mut matrix: Vec<(String, Vec<Value>)> = Vec::new();
    if let Some(mx) = m.get("matrix") {
        let p = join(path, "matrix");
        if let Some(mo) = v.obj(mx, &p) {
            let mut combos: usize = 1;
            for (k, vals) in mo {
                let kp = join(&p, k);
                if !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') || k.is_empty() {
                    v.err(
                        "SPEC-03",
                        &kp,
                        tr(
                            "조합 이름은 영문 · 숫자 · _ 만 씁니다.",
                            "matrix names use letters, digits and _ only.",
                        ),
                    );
                    continue;
                }
                match vals {
                    Value::Array(a)
                        if !a.is_empty()
                            && a.iter()
                                .all(|x| x.is_string() || x.is_number() || x.is_boolean()) =>
                    {
                        combos = combos.saturating_mul(a.len());
                        matrix.push((k.clone(), a.clone()));
                    }
                    _ => v.err(
                        "SPEC-03",
                        &kp,
                        tr(
                            "조합 값은 비지 않은 값 목록입니다.",
                            "matrix values are a non-empty list of scalars.",
                        ),
                    ),
                }
            }
            if combos > 64 {
                v.err(
                    "SPEC-03",
                    &p,
                    tr(
                        &format!("조합이 {combos}개입니다(최대 64)."),
                        &format!("{combos} combinations (at most 64)."),
                    ),
                );
            }
        }
    }
    let timeout_ms = m
        .get("timeout")
        .and_then(|x| v.duration(x, &join(path, "timeout")));
    let retry = m
        .get("retry")
        .and_then(|x| parse_retry(v, x, &join(path, "retry")));
    let cache = match m.get("cache") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(true)) => Some(CacheDef::default()),
        Some(Value::Bool(false)) => None,
        Some(x) => {
            let p = join(path, "cache");
            v.obj(x, &p).map(|cm| {
                v.keys(cm, &p, &["inputs", "key"]);
                CacheDef {
                    inputs: v.texts(
                        cm.get("inputs").unwrap_or(&Value::Null),
                        &join(&p, "inputs"),
                    ),
                    key: v.texts(cm.get("key").unwrap_or(&Value::Null), &join(&p, "key")),
                }
            })
        }
    };
    let expect = parse_expect(v, &get("expect"), &join(path, "expect"));
    let outputs = v.string_map(&get("outputs"), &join(path, "outputs"));
    let locks = v.texts(&get("locks"), &join(path, "locks"));
    let optional = m
        .get("optional")
        .and_then(|x| v.boolean(x, &join(path, "optional")))
        .unwrap_or(false);
    let shell = m.get("shell").and_then(|x| v.text(x, &join(path, "shell")));
    if let Some(s) = &shell {
        if !["bash", "sh", "pwsh", "powershell", "cmd"].contains(&s.as_str()) {
            v.err(
                "SPEC-03",
                &join(path, "shell"),
                tr(
                    &format!("shell '{s}' 대신 bash · sh · pwsh · cmd."),
                    &format!("use bash, sh, pwsh or cmd instead of '{s}'."),
                ),
            );
        }
    }
    let cwd = m.get("cwd").and_then(|x| v.text(x, &join(path, "cwd")));
    let weight = m
        .get("weight")
        .and_then(|x| v.number(x, &join(path, "weight")))
        .map(|f| f.max(1.0) as u32);
    let description = m
        .get("description")
        .or(m.get("name"))
        .and_then(|x| v.text(x, &join(path, "description")));
    let mut on_failure = Vec::new();
    if let Some(of) = m.get("on-failure") {
        let p = join(path, "on-failure");
        if depth > 0 {
            v.err(
                "SPEC-03",
                &p,
                tr(
                    "실패 갈래 안에 다시 실패 갈래를 둘 수 없습니다.",
                    "on-failure cannot be nested.",
                ),
            );
        } else if let Some(om) = v.obj(of, &p) {
            for (cid, cv) in om {
                if let Some(n) = parse_node(v, cid, cv, &join(&p, cid), depth + 1) {
                    on_failure.push(n);
                }
            }
        }
    }
    Some(NodeDef {
        id: id.to_string(),
        kind,
        needs,
        cond,
        with,
        env,
        secrets,
        services,
        executor,
        timeout_ms,
        retry,
        cache,
        expect,
        outputs,
        locks,
        optional,
        on_failure,
        shell,
        cwd,
        weight,
        description,
        matrix,
        src: v.src(path),
    })
}

fn parse_nodes(v: &mut V, val: &Value, path: &str) -> Vec<NodeDef> {
    let mut out = Vec::new();
    if let Some(m) = v.obj(val, path) {
        for (id, nv) in m {
            if let Some(n) = parse_node(v, id, nv, &join(path, id), 0) {
                out.push(n);
            }
        }
    }
    out
}

fn parse_flow(v: &mut V, name: &str, val: &Value, path: &str) -> Option<FlowDef> {
    v.name_ok(name, path);
    let m = v.obj(val, path)?;
    v.keys(
        m,
        path,
        &[
            "description",
            "trigger",
            "env",
            "failFast",
            "concurrency",
            "rollback",
            "timeout",
            "nodes",
            "notify",
        ],
    );
    let mut notify = Vec::new();
    if let Some(Value::Array(list)) = m.get("notify") {
        for (i, item) in list.iter().enumerate() {
            let p = format!("{}[{i}]", join(path, "notify"));
            let Some(o) = v.obj(item, &p) else { continue };
            v.keys(o, &p, &["on", "webhook", "desktop", "message"]);
            let on = match o.get("on") {
                Some(Value::String(s)) => vec![s.clone()],
                Some(x) => v.texts(x, &join(&p, "on")),
                None => vec!["failure".to_string()],
            };
            for w in &on {
                if !["success", "failure", "cancelled", "always"].contains(&w.as_str()) {
                    v.err(
                        "SPEC-03",
                        &join(&p, "on"),
                        tr(
                            &format!("'{w}' 대신 success · failure · cancelled · always."),
                            &format!("use success, failure, cancelled or always instead of '{w}'."),
                        ),
                    );
                }
            }
            let webhook = o
                .get("webhook")
                .and_then(|x| v.text(x, &join(&p, "webhook")));
            let desktop = o
                .get("desktop")
                .and_then(|x| v.boolean(x, &join(&p, "desktop")))
                .unwrap_or(false);
            if webhook.is_none() && !desktop {
                v.err(
                    "SPEC-03",
                    &p,
                    tr(
                        "webhook 또는 desktop: true 가 필요합니다.",
                        "needs webhook or desktop: true.",
                    ),
                );
            }
            notify.push(NotifyDef {
                on,
                webhook,
                desktop,
                message: o
                    .get("message")
                    .and_then(|x| v.text(x, &join(&p, "message"))),
            });
        }
    } else if m.get("notify").map(|x| !x.is_null()).unwrap_or(false) {
        v.err(
            "SPEC-03",
            &join(path, "notify"),
            tr("notify 는 목록입니다.", "notify is a list."),
        );
    }
    let trigger = v.texts(
        m.get("trigger").unwrap_or(&Value::Null),
        &join(path, "trigger"),
    );
    for (i, t) in trigger.iter().enumerate() {
        if ![
            "manual",
            "pre-push",
            "post-commit",
            "watch",
            "ci",
            "schedule",
        ]
        .contains(&t.as_str())
        {
            v.err(
                "SPEC-03",
                &format!("{}[{i}]", join(path, "trigger")),
                tr(
                    &format!(
                        "알 수 없는 trigger '{t}'(manual · pre-push · post-commit · watch · ci)."
                    ),
                    &format!("unknown trigger '{t}' (manual, pre-push, post-commit, watch, ci)."),
                ),
            );
        }
    }
    let concurrency = match m
        .get("concurrency")
        .and_then(|x| v.text(x, &join(path, "concurrency")))
        .as_deref()
    {
        None | Some("reject") => Concurrency::Reject,
        Some("queue") => Concurrency::Queue,
        Some("cancel-previous") => Concurrency::CancelPrevious,
        Some("parallel") => Concurrency::Parallel,
        Some(o) => {
            v.err(
                "SPEC-03",
                &join(path, "concurrency"),
                tr(
                    &format!("'{o}' 대신 reject · queue · cancel-previous · parallel."),
                    &format!("use reject, queue, cancel-previous or parallel instead of '{o}'."),
                ),
            );
            Concurrency::Reject
        }
    };
    let (mut scope, mut on_check, mut rb_timeout) = (None, false, None);
    if let Some(r) = m.get("rollback") {
        let p = join(path, "rollback");
        if let Some(rm) = v.obj(r, &p) {
            v.keys(rm, &p, &["scope", "onCheckFailure", "timeout"]);
            rb_timeout = rm
                .get("timeout")
                .and_then(|x| v.duration(x, &join(&p, "timeout")));
            scope = match rm
                .get("scope")
                .and_then(|x| v.text(x, &join(&p, "scope")))
                .as_deref()
            {
                None => None,
                Some("node") => Some(RollbackScope::Node),
                Some("flow") => Some(RollbackScope::Flow),
                Some(o) => {
                    v.err(
                        "SPEC-03",
                        &join(&p, "scope"),
                        tr(
                            &format!("'{o}' 대신 node 또는 flow."),
                            &format!("use node or flow instead of '{o}'."),
                        ),
                    );
                    None
                }
            };
            on_check = rm
                .get("onCheckFailure")
                .and_then(|x| v.boolean(x, &join(&p, "onCheckFailure")))
                .unwrap_or(false);
        }
    }
    let nodes = parse_nodes(
        v,
        m.get("nodes").unwrap_or(&Value::Null),
        &join(path, "nodes"),
    );
    if nodes.is_empty() {
        v.err(
            "SPEC-03",
            &join(path, "nodes"),
            tr(
                "노드가 하나는 있어야 합니다.",
                "a flow needs at least one node.",
            ),
        );
    }
    Some(FlowDef {
        name: name.to_string(),
        description: m
            .get("description")
            .and_then(|x| v.text(x, &join(path, "description"))),
        trigger,
        env: m.get("env").and_then(|x| v.text(x, &join(path, "env"))),
        fail_fast: m
            .get("failFast")
            .and_then(|x| v.boolean(x, &join(path, "failFast")))
            .unwrap_or(false),
        concurrency,
        rollback_scope: scope,
        rollback_on_check_failure: on_check,
        rollback_timeout_ms: rb_timeout,
        notify,
        timeout_ms: m
            .get("timeout")
            .and_then(|x| v.duration(x, &join(path, "timeout"))),
        nodes,
        src: v.src(path),
    })
}

fn parse_suite(v: &mut V, name: &str, val: &Value, path: &str) -> Option<SuiteDef> {
    v.name_ok(name, path);
    let m = v.obj(val, path)?;
    v.keys(
        m,
        path,
        &[
            "use",
            "with",
            "select",
            "expect",
            "retry",
            "services",
            "tags",
            "paths",
            "timeout",
            "alwaysRun",
            "description",
        ],
    );
    let uses = match m.get("use") {
        Some(x) => v.text(x, &join(path, "use")).unwrap_or_default(),
        None => {
            v.err(
                "SPEC-03",
                path,
                tr(
                    "스위트에는 use 가 필요합니다(예: test.vitest).",
                    "a suite needs use (for example test.vitest).",
                ),
            );
            String::new()
        }
    };
    let with = m.get("with").cloned().unwrap_or(Value::Null);
    v.exprs_in(&with, &join(path, "with"), false);
    let mut select = Select::default();
    if let Some(s) = m.get("select") {
        let p = join(path, "select");
        if let Some(sm) = v.obj(s, &p) {
            v.keys(sm, &p, &["affected", "tags", "paths"]);
            select.affected = sm
                .get("affected")
                .and_then(|x| v.boolean(x, &join(&p, "affected")))
                .unwrap_or(false);
            select.tags = v.texts(sm.get("tags").unwrap_or(&Value::Null), &join(&p, "tags"));
            select.paths = v.texts(sm.get("paths").unwrap_or(&Value::Null), &join(&p, "paths"));
        }
    }
    Some(SuiteDef {
        name: name.to_string(),
        uses,
        with,
        select,
        expect: parse_expect(
            v,
            m.get("expect").unwrap_or(&Value::Null),
            &join(path, "expect"),
        ),
        retry: m
            .get("retry")
            .and_then(|x| parse_retry(v, x, &join(path, "retry"))),
        services: v.texts(
            m.get("services").unwrap_or(&Value::Null),
            &join(path, "services"),
        ),
        tags: v.texts(m.get("tags").unwrap_or(&Value::Null), &join(path, "tags")),
        paths: v.texts(m.get("paths").unwrap_or(&Value::Null), &join(path, "paths")),
        timeout_ms: m
            .get("timeout")
            .and_then(|x| v.duration(x, &join(path, "timeout"))),
        always_run: m
            .get("alwaysRun")
            .and_then(|x| v.boolean(x, &join(path, "alwaysRun")))
            .unwrap_or(false),
        src: v.src(path),
    })
}

fn parse_service(v: &mut V, name: &str, val: &Value, path: &str) -> Option<ServiceDef> {
    v.name_ok(name, path);
    let m = v.obj(val, path)?;
    v.keys(m, path, &["use", "with", "needs", "description"]);
    let uses = match m.get("use") {
        Some(x) => v.text(x, &join(path, "use")).unwrap_or_default(),
        None => {
            v.err(
                "SPEC-03",
                path,
                tr(
                    "서비스에는 use 가 필요합니다(예: docker.service).",
                    "a service needs use (for example docker.service).",
                ),
            );
            String::new()
        }
    };
    let with = m.get("with").cloned().unwrap_or(Value::Null);
    v.exprs_in(&with, &join(path, "with"), true);
    Some(ServiceDef {
        name: name.to_string(),
        uses,
        with,
        needs: v.texts(m.get("needs").unwrap_or(&Value::Null), &join(path, "needs")),
        src: v.src(path),
    })
}

fn parse_env(v: &mut V, name: &str, val: &Value, path: &str) -> Option<Environment> {
    v.name_ok(name, path);
    let m = v.obj(val, path)?;
    v.keys(
        m,
        path,
        &["class", "executor", "connection", "vars", "description"],
    );
    let class_text = m.get("class").and_then(|x| v.text(x, &join(path, "class")));
    let class = match class_text.as_deref() {
        None => EnvClass::parse(name).unwrap_or(EnvClass::Dev),
        Some(c) => EnvClass::parse(c).unwrap_or_else(|| {
            v.err(
                "SPEC-03",
                &join(path, "class"),
                tr(
                    &format!("class '{c}' 대신 dev · sandbox · staging · prod."),
                    &format!("use dev, sandbox, staging or prod instead of '{c}'."),
                ),
            );
            EnvClass::Dev
        }),
    };
    Some(Environment {
        name: name.to_string(),
        class,
        executor: m
            .get("executor")
            .and_then(|x| v.text(x, &join(path, "executor")))
            .filter(|e| match crate::executor::Executor::parse(e) {
                Ok(_) => true,
                Err(msg) => {
                    v.err("SPEC-03", &join(path, "executor"), msg);
                    false
                }
            }),
        connection: m
            .get("connection")
            .and_then(|x| v.text(x, &join(path, "connection"))),
        vars: v.string_map(m.get("vars").unwrap_or(&Value::Null), &join(path, "vars")),
        src: v.src(path),
    })
}

fn parse_composite(v: &mut V, val: &Value, rel: &str) -> Option<CompositeDef> {
    let m = v.obj(val, "")?;
    v.keys(
        m,
        "",
        &[
            "block",
            "version",
            "description",
            "inputs",
            "outputs",
            "nodes",
        ],
    );
    let fallback = Path::new(rel)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let name = m
        .get("block")
        .and_then(|x| v.text(x, "block"))
        .unwrap_or(fallback);
    v.name_ok(&name, "block");
    let mut inputs = Vec::new();
    if let Some(iv) = m.get("inputs") {
        if let Some(im) = v.obj(iv, "inputs") {
            for (k, x) in im {
                let p = join("inputs", k);
                let (ty, default, required, description) = match x {
                    Value::Object(om) => {
                        v.keys(om, &p, &["type", "default", "required", "description"]);
                        let ty = om
                            .get("type")
                            .and_then(|t| v.text(t, &join(&p, "type")))
                            .unwrap_or_else(|| "string".into());
                        if !["string", "integer", "number", "boolean", "array", "object"]
                            .contains(&ty.as_str())
                        {
                            v.err("SPEC-03", &join(&p, "type"), tr("type 은 string · integer · number · boolean · array · object.", "type must be string, integer, number, boolean, array or object."));
                        }
                        (
                            ty,
                            om.get("default").cloned(),
                            om.get("required")
                                .and_then(|r| r.as_bool())
                                .unwrap_or(false),
                            om.get("description")
                                .and_then(|d| d.as_str())
                                .map(|s| s.to_string()),
                        )
                    }
                    other => ("string".to_string(), Some(other.clone()), false, None),
                };
                inputs.push(InputDef {
                    name: k.clone(),
                    ty,
                    default,
                    required,
                    description,
                });
            }
        }
    }
    Some(CompositeDef {
        name,
        version: m
            .get("version")
            .and_then(|x| v.text(x, "version"))
            .unwrap_or_else(|| "1.0.0".into()),
        description: m.get("description").and_then(|x| v.text(x, "description")),
        inputs,
        outputs: v.string_map(m.get("outputs").unwrap_or(&Value::Null), "outputs"),
        nodes: parse_nodes(v, m.get("nodes").unwrap_or(&Value::Null), "nodes"),
        src: v.src(""),
    })
}

/// 객체는 키별로 합치고, 배열 · 값은 위의 것으로 바꾼다.
pub fn deep_merge(base: &mut Value, over: &Value) {
    match (base, over) {
        (Value::Object(b), Value::Object(o)) => {
            for (k, v) in o {
                match b.get_mut(k) {
                    Some(bv) => deep_merge(bv, v),
                    None => {
                        b.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        (b, o) => *b = o.clone(),
    }
}

fn read(root: &Path, rel: &str, errs: &mut Vec<SpecError>) -> Option<(Doc, String)> {
    let path = root.join(rel);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            errs.push(SpecError {
                code: "SPEC-01",
                file: rel.into(),
                line: None,
                path: String::new(),
                message: e.to_string(),
            });
            return None;
        }
    };
    let sha = crate::util::sha256_hex(text.as_bytes());
    match yaml::parse(&text) {
        Ok(d) => Some((d, sha)),
        Err(e) => {
            errs.push(SpecError {
                code: "SPEC-01",
                file: rel.into(),
                line: Some(e.line),
                path: String::new(),
                message: e.message,
            });
            None
        }
    }
}

fn yaml_files(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| (n.ends_with(".yml") || n.ends_with(".yaml")) && !n.starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// 흐름 파일이 있는지(감지 · 안내용).
pub fn exists(root: &Path) -> bool {
    root.join(".gitch/flow.yml").is_file()
        || root.join(".gitch/flow.yaml").is_file()
        || !yaml_files(&root.join(".gitch/flows")).is_empty()
}

/// 흐름 파일들을 읽고 검사한다.
pub fn load(root: &Path) -> Result<Spec, Vec<SpecError>> {
    let mut errs = Vec::new();
    let mut files = Vec::new();
    let main_rel =
        if root.join(".gitch/flow.yaml").is_file() && !root.join(".gitch/flow.yml").is_file() {
            ".gitch/flow.yaml"
        } else {
            ".gitch/flow.yml"
        };
    let mut parts: Vec<(String, Doc)> = Vec::new();
    if root.join(main_rel).is_file() {
        if let Some((d, sha)) = read(root, main_rel, &mut errs) {
            files.push(SpecFile {
                rel: main_rel.into(),
                sha256: sha,
            });
            parts.push((main_rel.into(), d));
        }
    }
    for n in yaml_files(&root.join(".gitch/flows")) {
        let rel = format!(".gitch/flows/{n}");
        if let Some((d, sha)) = read(root, &rel, &mut errs) {
            files.push(SpecFile {
                rel: rel.clone(),
                sha256: sha,
            });
            parts.push((rel, d));
        }
    }
    if parts.is_empty() && errs.is_empty() {
        errs.push(SpecError {
            code: "SPEC-08",
            file: ".gitch/flow.yml".into(),
            line: None,
            path: String::new(),
            message: crate::codes::describe("SPEC-08"),
        });
        return Err(errs);
    }
    // 기계별 겹침(커밋하지 않는 파일)은 첫 파일 위에 합친다. 명령이 바뀔 수 있으니 신뢰 해시에 넣는다.
    for local in [".gitch/flow.local.yml", ".gitch/flow.local.yaml"] {
        if root.join(local).is_file() {
            if let Some((d, sha)) = read(root, local, &mut errs) {
                files.push(SpecFile {
                    rel: local.into(),
                    sha256: sha,
                });
                if let Some(first) = parts.first_mut() {
                    deep_merge(&mut first.1.value, &d.value);
                    for (k, l) in d.lines {
                        first.1.lines.entry(k).or_insert(l);
                    }
                } else {
                    parts.push((local.into(), d));
                }
            }
        }
    }
    let block_files = yaml_files(&root.join(".gitch/blocks"));
    let mut spec = Spec {
        root: root.to_path_buf(),
        files: Vec::new(),
        version: 1,
        project_name: None,
        defaults: Defaults::default(),
        environments: Vec::new(),
        services: Vec::new(),
        suites: Vec::new(),
        flows: Vec::new(),
        blocks: Vec::new(),
        flaky: Vec::new(),
    };
    let mut seen: HashMap<(String, String), String> = HashMap::new();
    for (i, (rel, doc)) in parts.iter().enumerate() {
        let mut v = V {
            file: rel.clone(),
            doc,
            errs: &mut errs,
        };
        let Some(top) = v.obj(&doc.value, "") else {
            continue;
        };
        v.keys(top, "", TOP_KEYS);
        if i == 0 {
            match top.get("version") {
                Some(Value::Number(n)) if n.as_u64() == Some(1) => {}
                Some(other) => v.err(
                    "SPEC-09",
                    "version",
                    tr(
                        &format!(
                            "version {} 은(는) 지원하지 않습니다. version: 1 을 쓰세요.",
                            expr::to_text(other)
                        ),
                        &format!(
                            "version {} is not supported; use version: 1.",
                            expr::to_text(other)
                        ),
                    ),
                ),
                None => v.err(
                    "SPEC-09",
                    "",
                    tr("version: 1 이 필요합니다.", "version: 1 is required."),
                ),
            }
            if let Some(p) = top.get("project") {
                if let Some(pm) = v.obj(p, "project") {
                    v.keys(pm, "project", &["name", "detected", "description"]);
                    spec.project_name = pm.get("name").and_then(|x| v.text(x, "project.name"));
                }
            }
            if let Some(d) = top.get("defaults") {
                if let Some(dm) = v.obj(d, "defaults") {
                    v.keys(
                        dm,
                        "defaults",
                        &["timeout", "env", "envPolicy", "shell", "jobs"],
                    );
                    spec.defaults.timeout_ms = dm
                        .get("timeout")
                        .and_then(|x| v.duration(x, "defaults.timeout"));
                    spec.defaults.env =
                        v.texts(dm.get("env").unwrap_or(&Value::Null), "defaults.env");
                    spec.defaults.env_policy = match dm
                        .get("envPolicy")
                        .and_then(|x| v.text(x, "defaults.envPolicy"))
                        .as_deref()
                    {
                        None | Some("inherit") => EnvPolicy::Inherit,
                        Some("allowlist") => EnvPolicy::Allowlist,
                        Some(o) => {
                            v.err(
                                "SPEC-03",
                                "defaults.envPolicy",
                                tr(
                                    &format!("'{o}' 대신 inherit 또는 allowlist."),
                                    &format!("use inherit or allowlist instead of '{o}'."),
                                ),
                            );
                            EnvPolicy::Inherit
                        }
                    };
                    spec.defaults.shell = dm.get("shell").and_then(|x| v.text(x, "defaults.shell"));
                    spec.defaults.jobs = dm
                        .get("jobs")
                        .and_then(|x| v.number(x, "defaults.jobs"))
                        .map(|f| f.max(1.0) as usize);
                }
            }
        } else if top.contains_key("project") || top.contains_key("defaults") {
            v.err(
                "SPEC-03",
                "",
                tr(
                    "project · defaults 는 .gitch/flow.yml 에만 둡니다.",
                    "project and defaults belong only in .gitch/flow.yml.",
                ),
            );
        }
        macro_rules! section {
            ($key:literal, $parse:ident, $dest:expr) => {
                if let Some(sec) = top.get($key) {
                    if let Some(sm) = v.obj(sec, $key) {
                        for (name, val) in sm {
                            let p = join($key, name);
                            if let Some(prev) = seen.get(&($key.to_string(), name.clone())) {
                                v.err("SPEC-03", &p, tr(&format!("'{name}' 이(가) {prev} 에도 있습니다. 이름을 바꾸세요."), &format!("'{name}' is also defined in {prev}; rename one.")));
                                continue;
                            }
                            seen.insert(($key.to_string(), name.clone()), rel.clone());
                            if let Some(x) = $parse(&mut v, name, val, &p) {
                                $dest.push(x);
                            }
                        }
                    }
                }
            };
        }
        section!("environments", parse_env, spec.environments);
        section!("services", parse_service, spec.services);
        section!("suites", parse_suite, spec.suites);
        section!("flows", parse_flow, spec.flows);
    }
    for n in &block_files {
        let rel = format!(".gitch/blocks/{n}");
        if let Some((d, sha)) = read(root, &rel, &mut errs) {
            files.push(SpecFile {
                rel: rel.clone(),
                sha256: sha,
            });
            let mut v = V {
                file: rel.clone(),
                doc: &d,
                errs: &mut errs,
            };
            if let Some(c) = parse_composite(&mut v, &d.value, &rel) {
                if spec.blocks.iter().any(|b| b.name == c.name) {
                    v.err(
                        "SPEC-03",
                        "block",
                        tr(
                            "같은 이름의 복합 블록이 또 있습니다.",
                            "another composite block has the same name.",
                        ),
                    );
                } else {
                    spec.blocks.push(c);
                }
            }
        }
    }
    if root.join(".gitch/flaky.yml").is_file() {
        if let Some((d, sha)) = read(root, ".gitch/flaky.yml", &mut errs) {
            files.push(SpecFile {
                rel: ".gitch/flaky.yml".into(),
                sha256: sha,
            });
            let mut v = V {
                file: ".gitch/flaky.yml".into(),
                doc: &d,
                errs: &mut errs,
            };
            if let Some(m) = v.obj(&d.value, "") {
                v.keys(m, "", &["version", "quarantine"]);
                if let Some(Value::Array(items)) = m.get("quarantine") {
                    for (i, it) in items.iter().enumerate() {
                        let p = format!("quarantine[{i}]");
                        if let Some(im) = v.obj(it, &p) {
                            v.keys(im, &p, &["test", "owner", "until", "reason"]);
                            let test = im
                                .get("test")
                                .and_then(|x| v.text(x, &join(&p, "test")))
                                .unwrap_or_default();
                            let owner = im
                                .get("owner")
                                .and_then(|x| v.text(x, &join(&p, "owner")))
                                .unwrap_or_default();
                            let until = im
                                .get("until")
                                .and_then(|x| v.text(x, &join(&p, "until")))
                                .unwrap_or_default();
                            if test.is_empty() || owner.is_empty() || until.len() != 10 {
                                v.err("SPEC-03", &p, tr("격리 항목에는 test · owner · until(YYYY-MM-DD)이 모두 필요합니다.", "a quarantine entry needs test, owner and until (YYYY-MM-DD)."));
                                continue;
                            }
                            let reason = im
                                .get("reason")
                                .and_then(|x| v.text(x, &join(&p, "reason")));
                            spec.flaky.push(Quarantine {
                                test,
                                owner,
                                until,
                                reason,
                            });
                        }
                    }
                }
            }
        }
    }
    files.sort_by(|a, b| a.rel.cmp(&b.rel));
    spec.files = files;
    check_references(&spec, &mut errs);
    if errs.is_empty() {
        Ok(spec)
    } else {
        Err(errs)
    }
}

fn ref_err(errs: &mut Vec<SpecError>, src: &Src, path: &str, message: String) {
    errs.push(SpecError {
        code: "SPEC-04",
        file: src.file.clone(),
        line: src.line,
        path: path.into(),
        message,
    });
}

/// 이름 참조 · 순환 검사(모든 파일을 합친 뒤에).
fn check_references(spec: &Spec, errs: &mut Vec<SpecError>) {
    for s in &spec.services {
        for n in &s.needs {
            if spec.service(n).is_none() {
                ref_err(
                    errs,
                    &s.src,
                    &format!("services.{}.needs", s.name),
                    tr(
                        &format!("서비스 '{n}' 이(가) 없습니다."),
                        &format!("service '{n}' does not exist."),
                    ),
                );
            }
        }
    }
    for s in &spec.suites {
        for n in &s.services {
            if spec.service(n).is_none() {
                ref_err(
                    errs,
                    &s.src,
                    &format!("suites.{}.services", s.name),
                    tr(
                        &format!("서비스 '{n}' 이(가) 없습니다."),
                        &format!("service '{n}' does not exist."),
                    ),
                );
            }
        }
    }
    let check_nodes = |errs: &mut Vec<SpecError>, owner: &str, nodes: &[NodeDef]| {
        let ids: BTreeSet<&str> = nodes.iter().map(|n| n.id.as_str()).collect();
        for n in nodes {
            let path = format!("{owner}.nodes.{}", n.id);
            for need in &n.needs {
                if !ids.contains(need.as_str()) {
                    ref_err(
                        errs,
                        &n.src,
                        &format!("{path}.needs"),
                        tr(
                            &format!("노드 '{need}' 이(가) 이 흐름에 없습니다."),
                            &format!("node '{need}' is not in this flow."),
                        ),
                    );
                } else if need == &n.id {
                    ref_err(
                        errs,
                        &n.src,
                        &format!("{path}.needs"),
                        tr(
                            "자기 자신을 needs 에 넣을 수 없습니다.",
                            "a node cannot need itself.",
                        ),
                    );
                }
            }
            for sv in &n.services {
                if spec.service(sv).is_none() {
                    ref_err(
                        errs,
                        &n.src,
                        &format!("{path}.services"),
                        tr(
                            &format!("서비스 '{sv}' 이(가) 없습니다."),
                            &format!("service '{sv}' does not exist."),
                        ),
                    );
                }
            }
            match &n.kind {
                NodeKind::Suite(s) if spec.suite(s).is_none() => {
                    ref_err(
                        errs,
                        &n.src,
                        &format!("{path}.suite"),
                        tr(
                            &format!("스위트 '{s}' 이(가) 없습니다."),
                            &format!("suite '{s}' does not exist."),
                        ),
                    );
                }
                NodeKind::Flow(f) if spec.flow(f).is_none() => {
                    ref_err(
                        errs,
                        &n.src,
                        &format!("{path}.flow"),
                        tr(
                            &format!("흐름 '{f}' 이(가) 없습니다."),
                            &format!("flow '{f}' does not exist."),
                        ),
                    );
                }
                NodeKind::Use(u) => {
                    if let Some(name) = composite_name(u) {
                        if spec.composite(name).is_none() {
                            ref_err(
                                errs,
                                &n.src,
                                &format!("{path}.use"),
                                tr(
                                    &format!(".gitch/blocks/{name}.yml 이(가) 없습니다."),
                                    &format!(".gitch/blocks/{name}.yml does not exist."),
                                ),
                            );
                        }
                    }
                }
                _ => {}
            }
            for f in &n.on_failure {
                for need in &f.needs {
                    if !n.on_failure.iter().any(|x| &x.id == need) {
                        ref_err(
                            errs,
                            &f.src,
                            &format!("{path}.on-failure.{}.needs", f.id),
                            tr(
                                "실패 갈래 노드는 같은 갈래의 노드만 needs 에 넣습니다.",
                                "on-failure nodes can only need nodes in the same branch.",
                            ),
                        );
                    }
                }
            }
        }
        if let Some(cycle) = find_cycle(nodes) {
            let n = nodes
                .iter()
                .find(|x| x.id == cycle[0])
                .map(|x| x.src.clone())
                .unwrap_or_default();
            errs.push(SpecError {
                code: "SPEC-05",
                file: n.file,
                line: n.line,
                path: format!("{owner}.nodes"),
                message: cycle.join(" → "),
            });
        }
    };
    for f in &spec.flows {
        if let Some(e) = &f.env {
            if spec.environment(e).is_none() && !["local", "dev"].contains(&e.as_str()) {
                ref_err(
                    errs,
                    &f.src,
                    &format!("flows.{}.env", f.name),
                    tr(
                        &format!("환경 '{e}' 이(가) 없습니다."),
                        &format!("environment '{e}' does not exist."),
                    ),
                );
            }
        }
        check_nodes(errs, &format!("flows.{}", f.name), &f.nodes);
    }
    for b in &spec.blocks {
        check_nodes(errs, &format!("block {}", b.name), &b.nodes);
    }
    // 흐름 · 복합 블록이 서로를 부르며 돌지 않는지.
    let mut graph: HashMap<String, Vec<String>> = HashMap::new();
    let collect = |nodes: &[NodeDef]| -> Vec<String> {
        let mut out = Vec::new();
        for n in nodes {
            match &n.kind {
                NodeKind::Flow(f) => out.push(format!("flow:{f}")),
                NodeKind::Use(u) => {
                    if let Some(c) = composite_name(u) {
                        out.push(format!("block:{c}"));
                    }
                }
                _ => {}
            }
        }
        out
    };
    for f in &spec.flows {
        graph.insert(format!("flow:{}", f.name), collect(&f.nodes));
    }
    for b in &spec.blocks {
        graph.insert(format!("block:{}", b.name), collect(&b.nodes));
    }
    fn visit(
        k: &str,
        g: &HashMap<String, Vec<String>>,
        stack: &mut Vec<String>,
        done: &mut BTreeSet<String>,
    ) -> Option<Vec<String>> {
        if let Some(pos) = stack.iter().position(|x| x == k) {
            let mut c = stack[pos..].to_vec();
            c.push(k.to_string());
            return Some(c);
        }
        if done.contains(k) {
            return None;
        }
        stack.push(k.to_string());
        for n in g.get(k).cloned().unwrap_or_default() {
            if let Some(c) = visit(&n, g, stack, done) {
                return Some(c);
            }
        }
        stack.pop();
        done.insert(k.to_string());
        None
    }
    let mut done = BTreeSet::new();
    let mut keys: Vec<&String> = graph.keys().collect();
    keys.sort();
    for k in keys {
        if let Some(c) = visit(k, &graph, &mut Vec::new(), &mut done) {
            errs.push(SpecError {
                code: "SPEC-05",
                file: ".gitch".into(),
                line: None,
                path: String::new(),
                message: tr(
                    &format!("흐름 · 블록이 서로를 부릅니다: {}", c.join(" → ")),
                    &format!("flows or blocks call each other: {}", c.join(" → ")),
                ),
            });
            break;
        }
    }
}

/// `./blocks/x` · `blocks/x` · `local:x` → 복합 블록 이름.
pub fn composite_name(u: &str) -> Option<&str> {
    u.strip_prefix("./blocks/")
        .or_else(|| u.strip_prefix("blocks/"))
        .or_else(|| u.strip_prefix("local:"))
        .map(|s| s.trim_end_matches(".yml").trim_end_matches(".yaml"))
}

/// needs 순환을 찾으면 그 경로.
pub fn find_cycle(nodes: &[NodeDef]) -> Option<Vec<String>> {
    let idx: HashMap<&str, usize> = nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.id.as_str(), i))
        .collect();
    let mut state = vec![0u8; nodes.len()];
    fn dfs(
        i: usize,
        nodes: &[NodeDef],
        idx: &HashMap<&str, usize>,
        state: &mut [u8],
        stack: &mut Vec<usize>,
    ) -> Option<Vec<String>> {
        state[i] = 1;
        stack.push(i);
        for need in &nodes[i].needs {
            if let Some(&j) = idx.get(need.as_str()) {
                if state[j] == 1 {
                    let pos = stack.iter().position(|&x| x == j).unwrap_or(0);
                    let mut c: Vec<String> =
                        stack[pos..].iter().map(|&k| nodes[k].id.clone()).collect();
                    c.push(nodes[j].id.clone());
                    return Some(c);
                }
                if state[j] == 0 {
                    if let Some(c) = dfs(j, nodes, idx, state, stack) {
                        return Some(c);
                    }
                }
            }
        }
        stack.pop();
        state[i] = 2;
        None
    }
    for i in 0..nodes.len() {
        if state[i] == 0 {
            if let Some(c) = dfs(i, nodes, &idx, &mut state, &mut Vec::new()) {
                return Some(c);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(files: &[(&str, &str)]) -> tempdir::Dir {
        let d = tempdir::Dir::new();
        for (p, c) in files {
            let path = d.path().join(p);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, c).unwrap();
        }
        d
    }

    pub mod tempdir {
        pub struct Dir(std::path::PathBuf);
        impl Dir {
            pub fn new() -> Dir {
                let p = std::env::temp_dir()
                    .join(format!("gitch-flow-test-{}", crate::util::random_hex(6)));
                std::fs::create_dir_all(&p).unwrap();
                Dir(p)
            }
            pub fn path(&self) -> &std::path::Path {
                &self.0
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    const GOOD: &str = r#"version: 1
project: { name: demo }
defaults: { timeout: 10m, env: [CI] }
environments:
  local: { class: dev }
  prod: { class: prod }
services:
  db: { use: docker.service, with: { image: "postgres:16" } }
suites:
  unit:
    use: test.vitest
    select: { affected: true }
    expect: { minTests: 1, passRate: 1.0 }
    retry: { max: 1, flaky: warn }
flows:
  pre-push:
    trigger: [manual, pre-push]
    failFast: true
    nodes:
      install: { use: setup.node, cache: { inputs: [package-lock.json] } }
      lint: npm run lint
      unit: { needs: [install], suite: unit }
      smoke:
        needs: [unit]
        use: check.http
        with: { url: "http://127.0.0.1:${{ inputs.port }}/health" }
        on-failure:
          dump: { run: "echo failed" }
"#;

    #[test]
    fn loads_a_good_file() {
        let d = repo(&[(".gitch/flow.yml", GOOD)]);
        let s = load(d.path())
            .unwrap_or_else(|e| panic!("{:?}", e.iter().map(|x| x.human()).collect::<Vec<_>>()));
        assert_eq!(s.project_name.as_deref(), Some("demo"));
        assert_eq!(s.defaults.timeout_ms, Some(600_000));
        let f = s.flow("pre-push").unwrap();
        assert!(f.fail_fast);
        assert_eq!(f.nodes.len(), 4);
        assert_eq!(f.nodes[1].kind, NodeKind::Run("npm run lint".into()));
        assert_eq!(f.nodes[3].on_failure.len(), 1);
        assert_eq!(
            s.suite("unit").unwrap().retry.as_ref().unwrap().flaky,
            FlakyPolicy::Warn
        );
        assert_eq!(s.environment("prod").unwrap().class, EnvClass::Prod);
        assert_eq!(f.nodes[2].src.line, Some(22));
    }

    #[test]
    fn reports_many_errors_with_lines() {
        let bad = "version: 1\nflows:\n  x:\n    nodes:\n      a: { suite: nope, needs: [ghost] }\n      b: { use: x, run: y }\n      c: { run: \"echo ${{ secrets.TOKEN }}\" }\n      d: { run: ok, timeot: 1m }\n";
        let d = repo(&[(".gitch/flow.yml", bad)]);
        let errs = load(d.path()).unwrap_err();
        let codes: Vec<&str> = errs.iter().map(|e| e.code).collect();
        assert!(codes.contains(&"SPEC-04"), "{codes:?}");
        assert!(codes.contains(&"SPEC-03"), "{codes:?}");
        assert!(codes.contains(&"SPEC-07"), "{codes:?}");
        let typo = errs.iter().find(|e| e.code == "SPEC-02").unwrap();
        assert_eq!(typo.line, Some(8));
        assert!(typo.message.contains("timeout"));
    }

    #[test]
    fn detects_cycles() {
        let d = repo(&[(".gitch/flow.yml", "version: 1\nflows:\n  x:\n    nodes:\n      a: { run: a, needs: [c] }\n      b: { run: b, needs: [a] }\n      c: { run: c, needs: [b] }\n")]);
        let errs = load(d.path()).unwrap_err();
        assert!(errs.iter().any(|e| e.code == "SPEC-05"));
        let d2 = repo(&[(".gitch/flow.yml", "version: 1\nflows:\n  a:\n    nodes: { x: { flow: b } }\n  b:\n    nodes: { y: { flow: a } }\n")]);
        assert!(load(d2.path())
            .unwrap_err()
            .iter()
            .any(|e| e.code == "SPEC-05"));
    }

    #[test]
    fn missing_file_and_version() {
        let d = repo(&[]);
        assert_eq!(load(d.path()).unwrap_err()[0].code, "SPEC-08");
        let d2 = repo(&[(
            ".gitch/flow.yml",
            "version: 2\nflows: { a: { nodes: { x: echo } } }\n",
        )]);
        assert_eq!(load(d2.path()).unwrap_err()[0].code, "SPEC-09");
    }

    #[test]
    fn split_files_overlay_and_blocks() {
        let d = repo(&[
            (".gitch/flow.yml", "version: 1\nflows:\n  main:\n    nodes:\n      smoke: { use: ./blocks/web-smoke, with: { port: 3000 } }\n"),
            (".gitch/flows/extra.yml", "flows:\n  nightly:\n    nodes:\n      all: { flow: main }\n"),
            (".gitch/flow.local.yml", "defaults: { jobs: 2 }\n"),
            (".gitch/blocks/web-smoke.yml", "block: web-smoke\nversion: 1.0.0\ninputs:\n  port: { type: integer, default: 8080 }\nnodes:\n  up: { run: \"echo up ${{ inputs.port }}\" }\n"),
        ]);
        let s = load(d.path())
            .unwrap_or_else(|e| panic!("{:?}", e.iter().map(|x| x.human()).collect::<Vec<_>>()));
        assert_eq!(s.flows.len(), 2);
        assert_eq!(s.defaults.jobs, Some(2));
        assert_eq!(s.blocks[0].inputs[0].default, Some(serde_json::json!(8080)));
        assert_eq!(s.files.len(), 4);
        let d2 = repo(&[
            (
                ".gitch/flow.yml",
                "version: 1\nflows: { a: { nodes: { x: echo } } }\n",
            ),
            (
                ".gitch/flows/dup.yml",
                "flows: { a: { nodes: { y: echo } } }\n",
            ),
        ]);
        assert!(load(d2.path()).is_err());
    }

    #[test]
    fn hint_for_typos() {
        assert!(similar("needs", "neds"));
        assert!(similar("timeout", "timeot"));
        assert!(!similar("needs", "services"));
    }
}
