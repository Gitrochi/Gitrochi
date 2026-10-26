//! Verdict rules: pure functions that decide PASS, FAIL or INDETERMINATE from observations only.
//! INDETERMINATE counts as a failure. The exit code is just one observation among several.

use crate::report::{CaseStatus, TestReport};
use crate::spec::FlakyPolicy;
use crate::util::tr;
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Pass,
    Fail,
    Indeterminate,
}

impl Outcome {
    pub fn as_str(&self) -> &'static str {
        match self {
            Outcome::Pass => "PASS",
            Outcome::Fail => "FAIL",
            Outcome::Indeterminate => "INDETERMINATE",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Verdict {
    pub rule: &'static str,
    pub title: String,
    pub observed: String,
    pub expected: String,
    pub result: Outcome,
    pub code: Option<&'static str>,
    pub phase: &'static str,
}

impl Verdict {
    pub fn new(
        rule: &'static str,
        title: String,
        observed: String,
        expected: String,
        result: Outcome,
        code: Option<&'static str>,
    ) -> Verdict {
        Verdict {
            rule,
            title,
            observed,
            expected,
            result,
            code: if result == Outcome::Pass { None } else { code },
            phase: "main",
        }
    }
    pub fn to_json(&self) -> Value {
        json!({"rule": self.rule, "title": self.title, "observed": self.observed, "expected": self.expected,
               "result": self.result.as_str(), "code": self.code, "phase": self.phase})
    }
}

/// Combines verdicts: FAIL > INDETERMINATE > PASS, with the code of the first verdict that is not PASS.
pub fn combine(vs: &[Verdict]) -> (Outcome, Option<&'static str>) {
    let mut out = Outcome::Pass;
    let mut code = None;
    for v in vs {
        if v.result != Outcome::Pass && code.is_none() {
            code = v.code;
        }
        out = match (out, v.result) {
            (Outcome::Fail, _) | (_, Outcome::Fail) => Outcome::Fail,
            (Outcome::Indeterminate, _) | (_, Outcome::Indeterminate) => Outcome::Indeterminate,
            _ => Outcome::Pass,
        };
    }
    if vs.is_empty() {
        // No evidence at all is not a pass.
        return (Outcome::Indeterminate, Some("VERIFY-03"));
    }
    (out, code)
}

/// E1: the command's exit code (the main observation for plain command blocks).
pub fn exit_code(
    exit: Option<i32>,
    allowed: &[i64],
    timed_out: bool,
    cancelled: bool,
    spawn_error: Option<&str>,
) -> Verdict {
    let expected = allowed
        .iter()
        .map(|c| c.to_string())
        .collect::<Vec<_>>()
        .join(" | ");
    let title = tr("종료 코드", "exit code");
    if let Some(e) = spawn_error {
        return Verdict::new(
            "E1",
            title,
            e.to_string(),
            expected,
            Outcome::Fail,
            Some("EXEC-04"),
        );
    }
    if cancelled {
        return Verdict::new(
            "E1",
            title,
            tr("취소됨", "cancelled"),
            expected,
            Outcome::Fail,
            Some("EXEC-05"),
        );
    }
    if timed_out {
        return Verdict::new(
            "E1",
            title,
            tr("시간 초과", "timed out"),
            expected,
            Outcome::Fail,
            Some("EXEC-02"),
        );
    }
    match exit {
        Some(c) if allowed.contains(&(c as i64)) => {
            Verdict::new("E1", title, c.to_string(), expected, Outcome::Pass, None)
        }
        Some(c) => Verdict::new(
            "E1",
            title,
            c.to_string(),
            expected,
            Outcome::Fail,
            Some("EXEC-01"),
        ),
        None => Verdict::new(
            "E1",
            title,
            tr("신호로 끝남", "killed by a signal"),
            expected,
            Outcome::Fail,
            Some("EXEC-01"),
        ),
    }
}

/// T2: the report exists and parses. A failure outside the tests (build, load) is a failure.
pub fn report_present(report: Option<&TestReport>) -> Verdict {
    let title = tr("테스트 보고서", "test report");
    let expected = tr("읽을 수 있는 보고서", "a readable report");
    match report {
        None => Verdict::new(
            "T2",
            title,
            tr("없음", "missing"),
            expected,
            Outcome::Indeterminate,
            Some("TEST-02"),
        ),
        Some(r) if r.cases.is_empty() && !r.problems.is_empty() && !r.harness_failed => {
            Verdict::new(
                "T2",
                title,
                r.problems.join("; "),
                expected,
                Outcome::Indeterminate,
                Some("TEST-02"),
            )
        }
        Some(r) if r.harness_failed => Verdict::new(
            "T2",
            title,
            if r.problems.is_empty() {
                tr("테스트 밖 오류", "error outside tests")
            } else {
                r.problems.join("; ")
            },
            expected,
            Outcome::Fail,
            Some("TEST-06"),
        ),
        Some(r) => Verdict::new(
            "T2",
            title,
            format!("{} ({})", r.format, r.sources.join(", ")),
            expected,
            Outcome::Pass,
            None,
        ),
    }
}

/// T3: the number of tests that actually ran. Zero is not a pass.
pub fn min_tests(report: &TestReport, min: u64) -> Verdict {
    let n = report.executed();
    let title = tr("실행된 테스트 수", "tests executed");
    if n >= min.max(1) {
        Verdict::new(
            "T3",
            title,
            n.to_string(),
            format!("≥ {}", min.max(1)),
            Outcome::Pass,
            None,
        )
    } else {
        Verdict::new(
            "T3",
            title,
            n.to_string(),
            format!("≥ {}", min.max(1)),
            Outcome::Fail,
            Some("TEST-03"),
        )
    }
}

/// Whether a failure is on the quarantine list (and not expired).
pub struct Quarantined<'a> {
    pub entries: &'a [crate::spec::Quarantine],
    pub today: String,
}

impl Quarantined<'_> {
    pub fn covers(&self, id: &str, name: &str) -> bool {
        self.entries.iter().any(|q| {
            q.until.as_str() >= self.today.as_str()
                && (id == q.test || name == q.test || id.ends_with(&format!("::{}", q.test)))
        })
    }
}

/// T1: the pass rate. The default threshold is 1.0, compared in integers (rounded down) to avoid floating-point error.
pub fn pass_rate(report: &TestReport, rate: f64, flaky: FlakyPolicy, q: &Quarantined) -> Verdict {
    let title = tr("통과율", "pass rate");
    let mut executed = 0u64;
    let mut passed = 0u64;
    let mut quarantined = 0u64;
    let mut flaky_n = 0u64;
    for c in &report.cases {
        match c.status {
            CaseStatus::Skipped => continue,
            CaseStatus::Passed => passed += 1,
            CaseStatus::Flaky => {
                flaky_n += 1;
                if flaky == FlakyPolicy::Warn || q.covers(&c.id, &c.name) {
                    passed += 1;
                }
            }
            CaseStatus::Failed => {
                if q.covers(&c.id, &c.name) {
                    quarantined += 1;
                    executed += 1;
                    passed += 1;
                    continue;
                }
            }
        }
        executed += 1;
    }
    let required = ((rate * executed as f64) - 1e-9).ceil().max(0.0) as u64;
    let mut observed = format!("{passed}/{executed}");
    if flaky_n > 0 {
        observed.push_str(&tr(
            &format!(" (불안정 {flaky_n})"),
            &format!(" ({flaky_n} flaky)"),
        ));
    }
    if quarantined > 0 {
        observed.push_str(&tr(
            &format!(" (격리 {quarantined})"),
            &format!(" ({quarantined} quarantined)"),
        ));
    }
    let expected = format!("≥ {:.0}%", rate * 100.0);
    if executed == 0 {
        return Verdict::new(
            "T1",
            title,
            observed,
            expected,
            Outcome::Indeterminate,
            Some("TEST-03"),
        );
    }
    if passed >= required {
        Verdict::new("T1", title, observed, expected, Outcome::Pass, None)
    } else {
        let code = if flaky_n > 0 && report.failed() == 0 {
            "TEST-05"
        } else {
            "TEST-01"
        };
        Verdict::new("T1", title, observed, expected, Outcome::Fail, Some(code))
    }
}

/// X1: the exit code and the report tell the same story. When they disagree, the runner's setup cannot be trusted.
pub fn consistency(exit: Option<i32>, report: &TestReport, _flaky: FlakyPolicy) -> Verdict {
    let title = tr("종료 코드와 보고서", "exit code vs report");
    // FLAKY cases that passed on retry don't count as failures (compared with the last attempt's exit code).
    let failing = report.failed();
    let says_fail = failing > 0 || report.harness_failed;
    let exit_fail = exit != Some(0);
    let observed = format!(
        "exit={} failed={}",
        exit.map(|c| c.to_string()).unwrap_or_else(|| "-".into()),
        failing
    );
    let expected = tr("둘 다 성공이거나 둘 다 실패", "both succeed or both fail");
    if says_fail == exit_fail {
        Verdict::new("X1", title, observed, expected, Outcome::Pass, None)
    } else if !says_fail && exit_fail && report.flaky() > 0 {
        // Failed on the first attempt, passed on the retry: consistent with the retry.
        Verdict::new("X1", title, observed, expected, Outcome::Pass, None)
    } else {
        Verdict::new(
            "X1",
            title,
            observed,
            expected,
            Outcome::Indeterminate,
            Some("TEST-04"),
        )
    }
}

/// Expected HTTP status: 200 · [200, 204] · "2xx" · "200-299".
pub fn status_matches(expect: &Value, status: u16) -> bool {
    match expect {
        Value::Null => (200..400).contains(&status),
        Value::Number(n) => n.as_u64() == Some(status as u64),
        Value::Array(a) => a.iter().any(|x| status_matches(x, status)),
        Value::String(s) => {
            let s = s.trim();
            if s.len() == 3 && s.ends_with("xx") {
                return s.as_bytes()[0] == b'0' + (status / 100) as u8;
            }
            if let Some((a, b)) = s.split_once('-') {
                if let (Ok(a), Ok(b)) = (a.trim().parse::<u16>(), b.trim().parse::<u16>()) {
                    return (a..=b).contains(&status);
                }
            }
            s.parse::<u16>().map(|c| c == status).unwrap_or(false)
        }
        _ => false,
    }
}

pub fn status_text(expect: &Value) -> String {
    match expect {
        Value::Null => "2xx-3xx".into(),
        other => crate::expr::to_text(other),
    }
}

/// S1: the expected response was reached (within retries × interval).
pub fn reach(status: Option<u16>, attempts: u32, expect: &Value, error: Option<&str>) -> Verdict {
    let title = tr("응답", "response");
    let expected = status_text(expect);
    match status {
        Some(s) if status_matches(expect, s) => Verdict::new(
            "S1",
            title,
            format!("{s} ×{attempts}"),
            expected,
            Outcome::Pass,
            None,
        ),
        Some(s) => Verdict::new(
            "S1",
            title,
            format!("{s} ×{attempts}"),
            expected,
            Outcome::Fail,
            Some("VERIFY-01"),
        ),
        None => Verdict::new(
            "S1",
            title,
            error.unwrap_or("no response").to_string(),
            expected,
            Outcome::Indeterminate,
            Some("VERIFY-01"),
        ),
    }
}

/// S2: the build identity the app reports matches the expected one (a short SHA matches when the prefix does).
pub fn identity(observed: Option<&str>, expected: &str) -> Verdict {
    let title = tr("빌드 식별자", "build identifier");
    match observed {
        None => Verdict::new(
            "S2",
            title,
            tr("읽지 못함", "unreadable"),
            expected.into(),
            Outcome::Indeterminate,
            Some("VERIFY-03"),
        ),
        Some(o) => {
            let (a, b) = (
                o.trim().to_ascii_lowercase(),
                expected.trim().to_ascii_lowercase(),
            );
            let same = !a.is_empty()
                && !b.is_empty()
                && (a == b
                    || (a.len() >= 7 && b.starts_with(&a))
                    || (b.len() >= 7 && a.starts_with(&b)));
            if same {
                Verdict::new("S2", title, o.into(), expected.into(), Outcome::Pass, None)
            } else {
                Verdict::new(
                    "S2",
                    title,
                    o.into(),
                    expected.into(),
                    Outcome::Fail,
                    Some("VERIFY-02"),
                )
            }
        }
    }
}

/// O1: the output contains the expected text (a regular expression).
pub fn output(text: &str, pattern: &str) -> Verdict {
    let title = tr("출력", "output");
    let ok = regex::Regex::new(pattern)
        .map(|re| re.is_match(text))
        .unwrap_or_else(|_| text.contains(pattern));
    Verdict::new(
        "O1",
        title,
        if ok {
            tr("일치", "matched")
        } else {
            tr("없음", "not found")
        },
        pattern.into(),
        if ok { Outcome::Pass } else { Outcome::Fail },
        Some("VERIFY-04"),
    )
}

/// C1: the remote run's result contract. CI's conclusion is only a hint; without a contract or report the verdict is INDETERMINATE.
pub fn remote_result(contract: Option<Outcome>, conclusion: &str) -> Verdict {
    let title = tr("원격 결과 계약", "remote result contract");
    match contract {
        Some(Outcome::Pass) => Verdict::new(
            "C1",
            title,
            format!("PASS ({conclusion})"),
            "PASS".into(),
            Outcome::Pass,
            None,
        ),
        Some(o) => Verdict::new(
            "C1",
            title,
            format!("{} ({conclusion})", o.as_str()),
            "PASS".into(),
            Outcome::Fail,
            Some("CI-02"),
        ),
        None => Verdict::new(
            "C1",
            title,
            tr(
                &format!("없음 (CI 결론: {conclusion})"),
                &format!("missing (CI conclusion: {conclusion})"),
            ),
            "PASS".into(),
            Outcome::Indeterminate,
            Some("CI-03"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::{parse_junit, Case};

    fn report(pass: usize, fail: usize, skip: usize) -> TestReport {
        let mut r = TestReport {
            format: "junit".into(),
            sources: vec!["x".into()],
            ..Default::default()
        };
        let mut push = |n: usize, s: CaseStatus, tag: &str| {
            for i in 0..n {
                r.cases.push(Case {
                    id: format!("{tag}{i}"),
                    name: format!("{tag}{i}"),
                    file: None,
                    line: None,
                    status: s,
                    duration_ms: 1,
                    message: None,
                });
            }
        };
        push(pass, CaseStatus::Passed, "p");
        push(fail, CaseStatus::Failed, "f");
        push(skip, CaseStatus::Skipped, "s");
        r
    }

    fn noq() -> Quarantined<'static> {
        Quarantined {
            entries: &[],
            today: "2026-10-26".into(),
        }
    }

    #[test]
    fn zero_tests_is_not_a_pass() {
        let r = report(0, 0, 3);
        assert_eq!(min_tests(&r, 1).result, Outcome::Fail);
        assert_eq!(min_tests(&r, 1).code, Some("TEST-03"));
        assert_eq!(
            pass_rate(&r, 1.0, FlakyPolicy::Fail, &noq()).result,
            Outcome::Indeterminate
        );
    }

    #[test]
    fn exit_zero_with_failures_is_indeterminate() {
        let r = report(3, 1, 0);
        let v = consistency(Some(0), &r, FlakyPolicy::Fail);
        assert_eq!(v.result, Outcome::Indeterminate);
        assert_eq!(v.code, Some("TEST-04"));
        let all_pass = report(3, 0, 0);
        assert_eq!(
            consistency(Some(1), &all_pass, FlakyPolicy::Fail).result,
            Outcome::Indeterminate
        );
        assert_eq!(
            consistency(Some(1), &r, FlakyPolicy::Fail).result,
            Outcome::Pass
        );
        assert_eq!(
            consistency(Some(0), &all_pass, FlakyPolicy::Fail).result,
            Outcome::Pass
        );
    }

    #[test]
    fn pass_rate_threshold_uses_integers() {
        let r = report(19, 1, 0);
        assert_eq!(
            pass_rate(&r, 0.95, FlakyPolicy::Fail, &noq()).result,
            Outcome::Pass
        );
        assert_eq!(
            pass_rate(&r, 1.0, FlakyPolicy::Fail, &noq()).result,
            Outcome::Fail
        );
        let r2 = report(18, 2, 0);
        assert_eq!(
            pass_rate(&r2, 0.95, FlakyPolicy::Fail, &noq()).result,
            Outcome::Fail
        );
    }

    #[test]
    fn flaky_policy_and_quarantine() {
        let mut r = report(2, 1, 0);
        r.cases[2].status = CaseStatus::Flaky;
        assert_eq!(
            pass_rate(&r, 1.0, FlakyPolicy::Fail, &noq()).code,
            Some("TEST-05")
        );
        assert_eq!(
            pass_rate(&r, 1.0, FlakyPolicy::Warn, &noq()).result,
            Outcome::Pass
        );
        let failing = report(2, 1, 0);
        let entries = vec![crate::spec::Quarantine {
            test: "f0".into(),
            owner: "me".into(),
            until: "2026-12-31".into(),
            reason: None,
        }];
        let q = Quarantined {
            entries: &entries,
            today: "2026-10-26".into(),
        };
        assert_eq!(
            pass_rate(&failing, 1.0, FlakyPolicy::Fail, &q).result,
            Outcome::Pass
        );
        let expired = Quarantined {
            entries: &entries,
            today: "2027-01-01".into(),
        };
        assert_eq!(
            pass_rate(&failing, 1.0, FlakyPolicy::Fail, &expired).result,
            Outcome::Fail
        );
    }

    #[test]
    fn missing_or_broken_report() {
        assert_eq!(report_present(None).result, Outcome::Indeterminate);
        let broken = parse_junit("garbage", "x.xml");
        assert_eq!(report_present(Some(&broken)).result, Outcome::Indeterminate);
        let mut harness = report(1, 0, 0);
        harness.harness_failed = true;
        assert_eq!(report_present(Some(&harness)).result, Outcome::Fail);
    }

    #[test]
    fn http_status_and_identity() {
        assert!(status_matches(&json!("2xx"), 204));
        assert!(!status_matches(&json!("2xx"), 301));
        assert!(status_matches(&json!("200-299"), 250));
        assert!(status_matches(&json!([200, 204]), 204));
        assert!(status_matches(&Value::Null, 302));
        assert_eq!(
            reach(Some(503), 12, &json!("2xx"), None).result,
            Outcome::Fail
        );
        assert_eq!(
            reach(None, 12, &json!("2xx"), Some("connection refused")).result,
            Outcome::Indeterminate
        );
        assert_eq!(
            identity(Some("abc1234"), "abc1234def5678").result,
            Outcome::Pass
        );
        assert_eq!(
            identity(Some("ffff000"), "abc1234def5678").result,
            Outcome::Fail
        );
        assert_eq!(identity(None, "abc").result, Outcome::Indeterminate);
    }

    #[test]
    fn combine_order_and_empty() {
        let p = exit_code(Some(0), &[0], false, false, None);
        let f = exit_code(Some(2), &[0], false, false, None);
        let i = report_present(None);
        assert_eq!(
            combine(&[p.clone(), i.clone(), f.clone()]),
            (Outcome::Fail, Some("TEST-02"))
        );
        assert_eq!(combine(std::slice::from_ref(&p)).0, Outcome::Pass);
        assert_eq!(combine(&[]), (Outcome::Indeterminate, Some("VERIFY-03")));
        assert_eq!(
            exit_code(None, &[0], true, false, None).code,
            Some("EXEC-02")
        );
    }
}
