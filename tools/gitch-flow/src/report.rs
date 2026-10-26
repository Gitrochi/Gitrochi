//! 테스트 보고서를 한 모델(TestReport)로 읽는다. 실행 수는 형식마다 정한 규칙으로 센다.
//! JUnit XML(surefire · pytest · jest-junit · vitest · swift xunit) · `go test -json` · Jest/Vitest JSON · TAP · cargo libtest.

use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaseStatus {
    Passed,
    Failed,
    Skipped,
    /// 재시도해서 통과(처음엔 실패).
    Flaky,
}

impl CaseStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            CaseStatus::Passed => "passed",
            CaseStatus::Failed => "failed",
            CaseStatus::Skipped => "skipped",
            CaseStatus::Flaky => "flaky",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Case {
    pub id: String,
    pub name: String,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub status: CaseStatus,
    pub duration_ms: u64,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct TestReport {
    pub format: String,
    pub cases: Vec<Case>,
    pub duration_ms: u64,
    /// 읽은 보고서 파일(저장소 기준 경로).
    pub sources: Vec<String>,
    /// 해석하지 못한 부분 · 경고.
    pub problems: Vec<String>,
    /// 보고서에 테스트 단위가 아닌 실패(빌드 실패 등)가 있었는지.
    pub harness_failed: bool,
}

impl TestReport {
    pub fn executed(&self) -> u64 {
        self.cases
            .iter()
            .filter(|c| c.status != CaseStatus::Skipped)
            .count() as u64
    }
    pub fn passed(&self) -> u64 {
        self.cases
            .iter()
            .filter(|c| c.status == CaseStatus::Passed)
            .count() as u64
    }
    pub fn failed(&self) -> u64 {
        self.cases
            .iter()
            .filter(|c| c.status == CaseStatus::Failed)
            .count() as u64
    }
    pub fn skipped(&self) -> u64 {
        self.cases
            .iter()
            .filter(|c| c.status == CaseStatus::Skipped)
            .count() as u64
    }
    pub fn flaky(&self) -> u64 {
        self.cases
            .iter()
            .filter(|c| c.status == CaseStatus::Flaky)
            .count() as u64
    }
    pub fn merge(&mut self, other: TestReport) {
        if self.format.is_empty() {
            self.format = other.format.clone();
        }
        self.cases.extend(other.cases);
        self.duration_ms += other.duration_ms;
        self.sources.extend(other.sources);
        self.problems.extend(other.problems);
        self.harness_failed |= other.harness_failed;
    }

    /// 재시도 결과를 합친다: 처음 실패하고 다시 통과한 케이스는 FLAKY.
    pub fn apply_retry(&mut self, retry: &TestReport) {
        for c in self
            .cases
            .iter_mut()
            .filter(|c| c.status == CaseStatus::Failed)
        {
            if let Some(r) = retry.cases.iter().find(|r| r.id == c.id) {
                if r.status == CaseStatus::Passed {
                    c.status = CaseStatus::Flaky;
                }
            }
        }
        self.harness_failed = self.harness_failed && retry.harness_failed;
    }

    pub fn to_json(&self, suite: &str, limit: usize) -> Value {
        let failures: Vec<Value> = self
            .cases
            .iter()
            .filter(|c| matches!(c.status, CaseStatus::Failed | CaseStatus::Flaky))
            .take(limit)
            .map(case_json)
            .collect();
        let total_fail = self
            .cases
            .iter()
            .filter(|c| matches!(c.status, CaseStatus::Failed | CaseStatus::Flaky))
            .count();
        json!({
            "schemaVersion": 1,
            "suite": suite,
            "format": self.format,
            "executed": self.executed(),
            "passed": self.passed(),
            "failed": self.failed(),
            "skipped": self.skipped(),
            "flaky": self.flaky(),
            "durationMs": self.duration_ms,
            "failures": failures,
            "failuresTotal": total_fail,
            "sources": self.sources,
            "problems": self.problems,
            "cases": self.cases.iter().map(case_json).collect::<Vec<_>>(),
        })
    }
}

fn case_json(c: &Case) -> Value {
    json!({"id": c.id, "name": c.name, "file": c.file, "line": c.line, "status": c.status.as_str(), "durationMs": c.duration_ms, "message": c.message})
}

fn secs_to_ms(s: Option<&str>) -> u64 {
    s.and_then(|t| t.trim().replace(',', "").parse::<f64>().ok())
        .map(|f| (f * 1000.0) as u64)
        .unwrap_or(0)
}

fn short(msg: &str) -> String {
    let first: String = msg.lines().take(6).collect::<Vec<_>>().join("\n");
    if first.len() > 600 {
        let mut cut = 600;
        while !first.is_char_boundary(cut) {
            cut -= 1;
        }
        format!("{}…", &first[..cut])
    } else {
        first
    }
}

/// 실패 메시지에서 `파일:줄` 을 찾아낸다(스택에 나오는 첫 위치).
pub fn locate(msg: &str) -> Option<(String, u32)> {
    let re = regex::Regex::new(r"((?:[A-Za-z]:)?[\w./\\-]+\.(?:ts|tsx|js|jsx|mjs|cjs|py|go|rs|swift|java|kt|rb|php|cs|vue|svelte)):(\d+)").ok()?;
    for c in re.captures_iter(msg) {
        let file = c[1].replace('\\', "/");
        if file.contains("node_modules/") || file.starts_with("internal/") {
            continue;
        }
        if let Ok(line) = c[2].parse() {
            return Some((file, line));
        }
    }
    None
}

// ---------- JUnit XML ----------

pub fn parse_junit(xml: &str, source: &str) -> TestReport {
    let mut rep = TestReport {
        format: "junit".into(),
        sources: vec![source.into()],
        ..Default::default()
    };
    let doc = match roxmltree::Document::parse(xml) {
        Ok(d) => d,
        Err(e) => {
            rep.problems.push(format!("{source}: {e}"));
            return rep;
        }
    };
    let root = doc.root_element();
    if root.tag_name().name() != "testsuites" && root.tag_name().name() != "testsuite" {
        rep.problems.push(format!(
            "{source}: <{}> is not a JUnit report",
            root.tag_name().name()
        ));
        return rep;
    }
    let mut suite_time = 0u64;
    for suite in root.descendants().filter(|n| n.has_tag_name("testsuite")) {
        if suite
            .descendants()
            .filter(|n| n.has_tag_name("testsuite"))
            .count()
            == 1
        {
            suite_time += secs_to_ms(suite.attribute("time"));
        }
        // 테스트 밖에서 난 오류(모듈을 못 읽음 등)는 <testsuite errors=…> 에만 남는 실행기가 있다.
        let errors_attr = suite
            .attribute("errors")
            .and_then(|e| e.parse::<u64>().ok())
            .unwrap_or(0);
        let direct_cases = suite
            .children()
            .filter(|n| n.has_tag_name("testcase"))
            .count();
        if errors_attr > 0 && direct_cases == 0 {
            rep.harness_failed = true;
        }
    }
    for tc in root.descendants().filter(|n| n.has_tag_name("testcase")) {
        let name = tc.attribute("name").unwrap_or("").to_string();
        let class = tc.attribute("classname").unwrap_or("").to_string();
        let mut file = tc.attribute("file").map(|s| s.replace('\\', "/"));
        let mut line = tc.attribute("line").and_then(|l| l.parse().ok());
        let mut status = CaseStatus::Passed;
        let mut message = None;
        for ch in tc.children().filter(|n| n.is_element()) {
            match ch.tag_name().name() {
                "failure" | "error" => {
                    status = CaseStatus::Failed;
                    let m = ch
                        .attribute("message")
                        .map(|s| s.to_string())
                        .unwrap_or_default();
                    let body = ch.text().unwrap_or("").to_string();
                    let full = if body.trim().is_empty() {
                        m.clone()
                    } else if m.is_empty() {
                        body.clone()
                    } else {
                        format!("{m}\n{body}")
                    };
                    if file.is_none() || line.is_none() {
                        if let Some((f, l)) = locate(&full) {
                            file.get_or_insert(f);
                            line.get_or_insert(l);
                        }
                    }
                    message = Some(short(&full));
                }
                "skipped" if status != CaseStatus::Failed => status = CaseStatus::Skipped,
                _ => {}
            }
        }
        let id = if class.is_empty() {
            name.clone()
        } else {
            format!("{class}::{name}")
        };
        rep.cases.push(Case {
            id,
            name,
            file,
            line,
            status,
            duration_ms: secs_to_ms(tc.attribute("time")),
            message,
        });
    }
    rep.duration_ms = suite_time.max(rep.cases.iter().map(|c| c.duration_ms).sum());
    rep
}

// ---------- TRX (.NET) ----------

pub fn parse_trx(xml: &str, source: &str) -> TestReport {
    let mut rep = TestReport {
        format: "trx".into(),
        sources: vec![source.into()],
        ..Default::default()
    };
    let doc = match roxmltree::Document::parse(xml) {
        Ok(d) => d,
        Err(e) => {
            rep.problems.push(format!("{source}: {e}"));
            return rep;
        }
    };
    for r in doc
        .descendants()
        .filter(|n| n.has_tag_name("UnitTestResult"))
    {
        let name = r.attribute("testName").unwrap_or("").to_string();
        let status = match r.attribute("outcome").unwrap_or("") {
            "Passed" => CaseStatus::Passed,
            "NotExecuted" | "Inconclusive" | "Pending" => CaseStatus::Skipped,
            _ => CaseStatus::Failed,
        };
        let message = r
            .descendants()
            .find(|n| n.has_tag_name("Message"))
            .and_then(|n| n.text())
            .map(|m| {
                let stack = r
                    .descendants()
                    .find(|n| n.has_tag_name("StackTrace"))
                    .and_then(|n| n.text())
                    .unwrap_or("");
                format!("{m}\n{stack}")
            });
        let loc = message.as_deref().and_then(locate);
        let dur = r.attribute("duration").map(|d| {
            let parts: Vec<f64> = d.split(':').filter_map(|x| x.parse().ok()).collect();
            if parts.len() == 3 {
                ((parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]) * 1000.0) as u64
            } else {
                0
            }
        });
        rep.cases.push(Case {
            id: name.clone(),
            name,
            file: loc.as_ref().map(|l| l.0.clone()),
            line: loc.map(|l| l.1),
            status,
            duration_ms: dur.unwrap_or(0),
            message: if status == CaseStatus::Failed {
                message.map(|m| short(&m))
            } else {
                None
            },
        });
    }
    if rep.cases.is_empty() && !doc.root_element().has_tag_name("TestRun") {
        rep.problems.push(format!("{source}: not a TRX report"));
    }
    rep.duration_ms = rep.cases.iter().map(|c| c.duration_ms).sum();
    rep
}

// ---------- go test -json ----------

pub fn parse_gotest(text: &str, source: &str) -> TestReport {
    let mut rep = TestReport {
        format: "gotest".into(),
        sources: vec![source.into()],
        ..Default::default()
    };
    let mut outputs: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut seen_json = false;
    for raw in text.lines() {
        let Ok(ev) = serde_json::from_str::<Value>(raw.trim()) else {
            continue;
        };
        seen_json = true;
        let action = ev["Action"].as_str().unwrap_or("");
        let pkg = ev["Package"].as_str().unwrap_or("").to_string();
        let test = ev["Test"].as_str();
        match (action, test) {
            ("output", Some(t)) => {
                let key = format!("{pkg}::{t}");
                let o = outputs.entry(key).or_default();
                if o.len() < 4000 {
                    o.push_str(ev["Output"].as_str().unwrap_or(""));
                }
            }
            ("pass" | "fail" | "skip", Some(t)) => {
                let key = format!("{pkg}::{t}");
                let out = outputs.remove(&key).unwrap_or_default();
                let status = match action {
                    "pass" => CaseStatus::Passed,
                    "skip" => CaseStatus::Skipped,
                    _ => CaseStatus::Failed,
                };
                let (file, line) = match locate(&out) {
                    Some((f, l)) if status == CaseStatus::Failed => (Some(f), Some(l)),
                    _ => (None, None),
                };
                rep.cases.push(Case {
                    id: key,
                    name: t.to_string(),
                    file,
                    line,
                    status,
                    duration_ms: ev["Elapsed"]
                        .as_f64()
                        .map(|f| (f * 1000.0) as u64)
                        .unwrap_or(0),
                    message: if status == CaseStatus::Failed {
                        Some(short(&out))
                    } else {
                        None
                    },
                });
            }
            ("fail", None) => {
                // 패키지 단위 실패. 테스트가 하나도 없으면 빌드 실패로 본다.
                if !rep
                    .cases
                    .iter()
                    .any(|c| c.id.starts_with(&format!("{pkg}::")))
                {
                    rep.harness_failed = true;
                    rep.problems
                        .push(format!("{pkg}: package failed (build error?)"));
                }
                rep.duration_ms += ev["Elapsed"]
                    .as_f64()
                    .map(|f| (f * 1000.0) as u64)
                    .unwrap_or(0);
            }
            ("pass", None) => {
                rep.duration_ms += ev["Elapsed"]
                    .as_f64()
                    .map(|f| (f * 1000.0) as u64)
                    .unwrap_or(0);
            }
            _ => {}
        }
    }
    if !seen_json {
        rep.problems
            .push(format!("{source}: no go test -json events"));
    }
    rep
}

// ---------- Jest / Vitest JSON ----------

pub fn parse_jest_json(text: &str, source: &str, root: &str) -> TestReport {
    let mut rep = TestReport {
        format: "jest-json".into(),
        sources: vec![source.into()],
        ..Default::default()
    };
    let v: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => {
            rep.problems.push(format!("{source}: {e}"));
            return rep;
        }
    };
    let Some(results) = v["testResults"].as_array() else {
        rep.problems.push(format!("{source}: no testResults"));
        return rep;
    };
    for file in results {
        let fname = file["name"]
            .as_str()
            .or(file["testFilePath"].as_str())
            .unwrap_or("")
            .replace('\\', "/");
        let rel = fname
            .strip_prefix(root)
            .map(|s| s.trim_start_matches('/').to_string())
            .unwrap_or(fname.clone());
        let asserts = file["assertionResults"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        if asserts.is_empty() && file["status"].as_str() == Some("failed") {
            // 파일을 읽지 못해 테스트가 하나도 돌지 않은 경우(문법 오류 등).
            rep.harness_failed = true;
            let msg = file["message"]
                .as_str()
                .or(file["failureMessage"].as_str())
                .unwrap_or("test file failed to run");
            rep.cases.push(Case {
                id: format!("{rel}::<load>"),
                name: format!("{rel} (load)"),
                file: Some(rel.clone()),
                line: None,
                status: CaseStatus::Failed,
                duration_ms: 0,
                message: Some(short(msg)),
            });
            continue;
        }
        for a in asserts {
            let status = match a["status"].as_str().unwrap_or("") {
                "passed" => CaseStatus::Passed,
                "failed" => CaseStatus::Failed,
                _ => CaseStatus::Skipped,
            };
            let name = a["fullName"]
                .as_str()
                .or(a["title"].as_str())
                .unwrap_or("")
                .to_string();
            let msgs: Vec<String> = a["failureMessages"]
                .as_array()
                .map(|m| {
                    m.iter()
                        .filter_map(|x| x.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            let full = msgs.join("\n");
            let line = a["location"]["line"]
                .as_u64()
                .map(|l| l as u32)
                .or_else(|| locate(&full).map(|x| x.1));
            rep.cases.push(Case {
                id: format!("{rel}::{name}"),
                name,
                file: Some(rel.clone()),
                line,
                status,
                duration_ms: a["duration"].as_f64().map(|f| f as u64).unwrap_or(0),
                message: if status == CaseStatus::Failed {
                    Some(short(&full))
                } else {
                    None
                },
            });
        }
    }
    let start = v["startTime"].as_u64().unwrap_or(0);
    let end = results
        .iter()
        .filter_map(|f| f["endTime"].as_u64())
        .max()
        .unwrap_or(start);
    rep.duration_ms = end.saturating_sub(start);
    rep
}

// ---------- TAP ----------

pub fn parse_tap(text: &str, source: &str) -> TestReport {
    let mut rep = TestReport {
        format: "tap".into(),
        sources: vec![source.into()],
        ..Default::default()
    };
    let re = regex::Regex::new(r"^\s*(not ok|ok)\b\s*(\d+)?\s*(?:-\s*)?([^#]*)(?:#\s*(\w+)(.*))?$")
        .unwrap();
    let mut planned: Option<u64> = None;
    let mut pending_fail: Option<usize> = None;
    for line in text.lines() {
        if let Some(p) = line.trim().strip_prefix("1..") {
            planned = p.split_whitespace().next().and_then(|n| n.parse().ok());
            continue;
        }
        if line.trim_start().starts_with("Bail out!") {
            rep.harness_failed = true;
            rep.problems.push(line.trim().to_string());
            continue;
        }
        if let Some(c) = re.captures(line) {
            let ok = &c[1] == "ok";
            let num = c
                .get(2)
                .map(|m| m.as_str().to_string())
                .unwrap_or_else(|| (rep.cases.len() + 1).to_string());
            let desc = c
                .get(3)
                .map(|m| m.as_str().trim().to_string())
                .unwrap_or_default();
            let directive = c
                .get(4)
                .map(|m| m.as_str().to_ascii_uppercase())
                .unwrap_or_default();
            let status = if directive == "SKIP" || directive == "TODO" {
                CaseStatus::Skipped
            } else if ok {
                CaseStatus::Passed
            } else {
                CaseStatus::Failed
            };
            rep.cases.push(Case {
                id: format!("{num} {desc}"),
                name: desc,
                file: None,
                line: None,
                status,
                duration_ms: 0,
                message: None,
            });
            pending_fail = if status == CaseStatus::Failed {
                Some(rep.cases.len() - 1)
            } else {
                None
            };
        } else if let Some(i) = pending_fail {
            // 실패 뒤의 YAML 진단 블록을 메시지로.
            let t = line.trim();
            if !t.is_empty() && t != "---" && t != "..." {
                let m = rep.cases[i].message.get_or_insert_with(String::new);
                if m.len() < 600 {
                    if !m.is_empty() {
                        m.push('\n');
                    }
                    m.push_str(t);
                }
            }
        }
    }
    if let Some(p) = planned {
        if (rep.cases.len() as u64) < p {
            rep.harness_failed = true;
            rep.problems
                .push(format!("plan 1..{p} but only {} results", rep.cases.len()));
        }
    }
    rep
}

// ---------- cargo test (libtest 사람용 출력) ----------

pub fn parse_libtest(text: &str, source: &str) -> TestReport {
    let mut rep = TestReport {
        format: "libtest".into(),
        sources: vec![source.into()],
        ..Default::default()
    };
    let re =
        regex::Regex::new(r"^test (\S+)(?: - should panic)? \.\.\. (ok|FAILED|ignored)").unwrap();
    let mut saw_summary = false;
    for line in text.lines() {
        if let Some(c) = re.captures(line.trim()) {
            let status = match &c[2] {
                "ok" => CaseStatus::Passed,
                "ignored" => CaseStatus::Skipped,
                _ => CaseStatus::Failed,
            };
            rep.cases.push(Case {
                id: c[1].to_string(),
                name: c[1].to_string(),
                file: None,
                line: None,
                status,
                duration_ms: 0,
                message: None,
            });
        } else if line.trim_start().starts_with("test result:") {
            saw_summary = true;
        } else if line.contains("error: could not compile") || line.contains("error[E") {
            rep.harness_failed = true;
        }
    }
    // 실패 상세 블록("---- name stdout ----")을 붙인다.
    let mut current: Option<String> = None;
    let mut buf = String::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("---- ") {
            if let Some(name) = rest.strip_suffix(" stdout ----") {
                if let Some(n) = current.take() {
                    attach(&mut rep, &n, &buf);
                }
                current = Some(name.to_string());
                buf.clear();
                continue;
            }
        }
        if current.is_some() {
            if line.starts_with("failures:") || line.starts_with("test result:") {
                if let Some(n) = current.take() {
                    attach(&mut rep, &n, &buf);
                }
                buf.clear();
            } else if buf.len() < 2000 {
                buf.push_str(line);
                buf.push('\n');
            }
        }
    }
    if let Some(n) = current {
        attach(&mut rep, &n, &buf);
    }
    if !saw_summary && rep.cases.is_empty() {
        rep.problems.push(format!("{source}: no libtest output"));
    }
    rep
}

fn attach(rep: &mut TestReport, name: &str, text: &str) {
    if let Some(c) = rep.cases.iter_mut().find(|c| c.id == name) {
        if let Some((f, l)) = locate(text) {
            c.file = Some(f);
            c.line = Some(l);
        }
        c.message = Some(short(text.trim()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const JUNIT: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="math" tests="4" failures="1" errors="0" skipped="1" time="0.120">
    <testcase classname="math" name="adds" time="0.010"/>
    <testcase classname="math" name="subtracts" time="0.020">
      <failure message="expected 1 to be 2">AssertionError: expected 1 to be 2
    at Object.&lt;anonymous&gt; (src/math.test.ts:14:5)</failure>
    </testcase>
    <testcase classname="math" name="later" time="0"><skipped/></testcase>
    <testcase classname="math" name="multiplies" time="0.030" file="src/math.test.ts" line="20"/>
  </testsuite>
</testsuites>"#;

    #[test]
    fn junit_counts_and_locations() {
        let r = parse_junit(JUNIT, "junit.xml");
        assert_eq!(
            (r.executed(), r.passed(), r.failed(), r.skipped()),
            (3, 2, 1, 1)
        );
        let f = r
            .cases
            .iter()
            .find(|c| c.status == CaseStatus::Failed)
            .unwrap();
        assert_eq!(f.file.as_deref(), Some("src/math.test.ts"));
        assert_eq!(f.line, Some(14));
        assert!(f.message.as_ref().unwrap().contains("expected 1 to be 2"));
        assert_eq!(r.duration_ms, 120);
        assert!(!r.harness_failed);
    }

    #[test]
    fn junit_bad_xml_and_empty() {
        let r = parse_junit("<html></html>", "x.xml");
        assert_eq!(r.executed(), 0);
        assert!(!r.problems.is_empty());
        let e = parse_junit("not xml at all", "y.xml");
        assert!(!e.problems.is_empty());
        let suite_error = parse_junit(
            r#"<testsuite name="a" tests="0" errors="1"></testsuite>"#,
            "z.xml",
        );
        assert!(suite_error.harness_failed);
    }

    #[test]
    fn gotest_events() {
        let text = r#"{"Action":"run","Package":"ex/a","Test":"TestOk"}
{"Action":"pass","Package":"ex/a","Test":"TestOk","Elapsed":0.01}
{"Action":"run","Package":"ex/a","Test":"TestBad"}
{"Action":"output","Package":"ex/a","Test":"TestBad","Output":"    a_test.go:12: boom\n"}
{"Action":"fail","Package":"ex/a","Test":"TestBad","Elapsed":0.02}
{"Action":"skip","Package":"ex/a","Test":"TestSkip","Elapsed":0}
{"Action":"fail","Package":"ex/a","Elapsed":0.5}
{"Action":"fail","Package":"ex/broken","Elapsed":0}
"#;
        let r = parse_gotest(text, "stdout");
        assert_eq!(
            (r.executed(), r.passed(), r.failed(), r.skipped()),
            (2, 1, 1, 1)
        );
        let bad = r.cases.iter().find(|c| c.name == "TestBad").unwrap();
        assert_eq!(bad.file.as_deref(), Some("a_test.go"));
        assert_eq!(bad.line, Some(12));
        assert!(r.harness_failed, "ex/broken had no tests and failed");
    }

    #[test]
    fn jest_json() {
        let text = r#"{"numTotalTests":3,"startTime":1000,"testResults":[
 {"name":"/repo/src/a.test.ts","endTime":1800,"status":"failed","assertionResults":[
   {"fullName":"a works","status":"passed","duration":5},
   {"fullName":"a fails","status":"failed","duration":7,"failureMessages":["Error: nope\n    at /repo/src/a.test.ts:9:3"]},
   {"fullName":"a todo","status":"todo"}]},
 {"name":"/repo/src/b.test.ts","status":"failed","message":"SyntaxError: Unexpected token","assertionResults":[]}]}"#;
        let r = parse_jest_json(text, "jest.json", "/repo");
        assert_eq!(r.passed(), 1);
        assert_eq!(r.failed(), 2);
        assert_eq!(r.skipped(), 1);
        assert!(r.harness_failed);
        let f = r.cases.iter().find(|c| c.name == "a fails").unwrap();
        assert_eq!(f.file.as_deref(), Some("src/a.test.ts"));
        assert_eq!(f.line, Some(9));
        assert_eq!(r.duration_ms, 800);
    }

    #[test]
    fn tap_stream() {
        let text = "TAP version 13\n1..4\nok 1 - first\nnot ok 2 - second\n  ---\n  message: boom\n  ...\nok 3 - third # SKIP not today\nok 4 - fourth\n";
        let r = parse_tap(text, "stdout");
        assert_eq!(
            (r.executed(), r.passed(), r.failed(), r.skipped()),
            (3, 2, 1, 1)
        );
        assert!(r.cases[1].message.as_ref().unwrap().contains("boom"));
        let short_plan = parse_tap("1..3\nok 1 - a\n", "stdout");
        assert!(short_plan.harness_failed);
    }

    #[test]
    fn libtest_output() {
        let text = "running 3 tests\ntest a::works ... ok\ntest a::fails ... FAILED\ntest a::slow ... ignored\n\nfailures:\n\n---- a::fails stdout ----\nthread 'a::fails' panicked at src/a.rs:10:5:\nassertion failed\n\nfailures:\n    a::fails\n\ntest result: FAILED. 1 passed; 1 failed; 1 ignored; 0 measured; 0 filtered out\n";
        let r = parse_libtest(text, "stdout");
        assert_eq!(
            (r.executed(), r.passed(), r.failed(), r.skipped()),
            (2, 1, 1, 1)
        );
        let f = r.cases.iter().find(|c| c.id == "a::fails").unwrap();
        assert_eq!(f.file.as_deref(), Some("src/a.rs"));
        assert_eq!(f.line, Some(10));
    }

    #[test]
    fn trx_results() {
        let xml = r#"<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><Results>
<UnitTestResult testName="A.Ok" outcome="Passed" duration="00:00:00.0100000"/>
<UnitTestResult testName="A.Bad" outcome="Failed" duration="00:00:01.5"><Output><ErrorInfo><Message>boom</Message><StackTrace>at A.Bad() in /src/ATests.cs:line 12</StackTrace></ErrorInfo></Output></UnitTestResult>
<UnitTestResult testName="A.Skip" outcome="NotExecuted"/></Results></TestRun>"#;
        let r = parse_trx(xml, "r.trx");
        assert_eq!(
            (r.executed(), r.passed(), r.failed(), r.skipped()),
            (2, 1, 1, 1)
        );
        assert!(r.cases[1].message.as_ref().unwrap().contains("boom"));
    }

    #[test]
    fn retry_marks_flaky() {
        let mut first = parse_junit(JUNIT, "a.xml");
        let retry = parse_junit(
            r#"<testsuite><testcase classname="math" name="subtracts"/></testsuite>"#,
            "b.xml",
        );
        first.apply_retry(&retry);
        assert_eq!(first.failed(), 0);
        assert_eq!(first.flaky(), 1);
    }
}
