//! 결과 보여 주기: 사람용 요약, AI 용 짧은 요약(--summary), 보고서 형식(text · md · json · junit · html).

use crate::cli::{resolve_run, Args, Out};
use crate::store::{self, Store};
use crate::util::{self, tr};
use serde_json::Value;

fn mark(state: &str) -> &'static str {
    match state {
        "PASSED" | "SUCCEEDED" => "✔",
        "CACHED" => "↺",
        "SKIPPED" => "−",
        "CANCELLED" => "◌",
        "RUNNING" | "PENDING" => "…",
        _ => "✘",
    }
}

fn state_word(s: &str) -> String {
    match s {
        "SUCCEEDED" => tr("성공", "succeeded"),
        "FAILED" => tr("실패", "failed"),
        "REJECTED" => tr("실행 전 거부", "rejected before running"),
        "CANCELLED" => tr("취소", "cancelled"),
        "RUNNING" => tr("실행 중", "running"),
        "ROLLED_BACK" => tr("되돌림 완료", "rolled back"),
        "ROLLBACK_FAILED" => tr("되돌림 실패", "rollback failed"),
        other => other.to_string(),
    }
}

/// 실행 요약 글. `ai` 면 색 · 장식 없이 짧고 결정적으로(같은 실패 = 같은 글).
pub fn digest(r: &Value, st: &Store, ai: bool) -> String {
    let mut s = String::new();
    let state = r["state"].as_str().unwrap_or("");
    let c = &r["counts"];
    let dur = util::human_duration(r["durationMs"].as_u64().unwrap_or(0));
    if ai {
        s.push_str(&format!(
            "FLOW={} flow={} env={} run={} nodes={} passed={} failed={} skipped={} cached={} duration={}\n",
            state,
            r["flow"].as_str().unwrap_or(""),
            r["env"].as_str().unwrap_or(""),
            r["runId"].as_str().unwrap_or(""),
            c["total"],
            c["passed"],
            c["failed"].as_u64().unwrap_or(0) + c["indeterminate"].as_u64().unwrap_or(0) + c["rejected"].as_u64().unwrap_or(0),
            c["skipped"],
            c["cached"],
            dur
        ));
    } else {
        s.push_str(&format!(
            "\n{} {} · {} · {} · {}\n",
            mark(state),
            r["flow"].as_str().unwrap_or(""),
            r["env"].as_str().unwrap_or(""),
            state_word(state),
            dur
        ));
    }
    if let Some(code) = r["code"].as_str() {
        if state != "SUCCEEDED" {
            s.push_str(&format!("{}\n", crate::codes::line(code)));
        }
    }
    let run_dir = st.run_dir(r["runId"].as_str().unwrap_or(""));
    let mut shown = 0;
    for n in r["nodes"].as_array().cloned().unwrap_or_default() {
        let ns = n["state"].as_str().unwrap_or("");
        if !matches!(ns, "FAILED" | "INDETERMINATE" | "REJECTED") {
            continue;
        }
        shown += 1;
        if shown > 8 {
            s.push_str(&tr(
                "  … (더 있음: gitch flow report last)\n",
                "  … (more: gitch flow report last)\n",
            ));
            break;
        }
        let tests = n["tests"]
            .as_object()
            .map(|t| format!(" {}/{}", t["passed"], t["executed"]))
            .unwrap_or_default();
        let code = n["code"]
            .as_str()
            .map(|c| format!(" [{c}] {}", crate::codes::describe(c)))
            .unwrap_or_default();
        s.push_str(&format!(
            "{} {}{tests}{code}\n",
            if ai { "x" } else { "✘" },
            n["id"].as_str().unwrap_or("")
        ));
        if let Some(d) = n["failure"]["detail"].as_str().filter(|d| !d.is_empty()) {
            for l in d.lines().take(4) {
                s.push_str(&format!("    {l}\n"));
            }
        }
        let failures = n["failures"].as_array().cloned().unwrap_or_default();
        for f in failures.iter().take(5) {
            let loc = match (f["file"].as_str(), f["line"].as_u64()) {
                (Some(file), Some(line)) => format!("{file}:{line} "),
                (Some(file), None) => format!("{file} "),
                _ => String::new(),
            };
            let msg = f["message"].as_str().unwrap_or("");
            s.push_str(&format!(
                "    {loc}{} — {msg}\n",
                f["name"].as_str().unwrap_or("")
            ));
        }
        if failures.is_empty() {
            // 테스트가 아닌 노드: 어긋난 판정과 로그 끝.
            for v in n["verdicts"].as_array().cloned().unwrap_or_default() {
                if v["result"] != "PASS" {
                    s.push_str(&format!(
                        "    {}: {} ({} {})\n",
                        v["title"].as_str().unwrap_or(""),
                        v["observed"].as_str().unwrap_or(""),
                        tr("기대", "expected"),
                        v["expected"].as_str().unwrap_or("")
                    ));
                }
            }
            let tail = n["observations"]["outputTail"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for l in tail
                .iter()
                .rev()
                .take(if ai { 8 } else { 12 })
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
            {
                s.push_str(&format!("    | {}\n", l.as_str().unwrap_or("")));
            }
        }
        if let Some(log) = n["log"].as_str() {
            s.push_str(&format!(
                "    {}: {}\n",
                tr("로그", "log"),
                run_dir.join(log).to_string_lossy()
            ));
        }
    }
    if !ai {
        let skipped: Vec<String> = r["nodes"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .iter()
            .filter(|n| n["state"] == "SKIPPED")
            .filter_map(|n| n["id"].as_str().map(|s| s.to_string()))
            .collect();
        if !skipped.is_empty() && state != "SUCCEEDED" {
            s.push_str(&format!(
                "{} {}\n",
                tr("건너뜀:", "skipped:"),
                skipped.join(", ")
            ));
        }
        s.push_str(&format!(
            "{} gitch flow report {}\n",
            tr("자세히:", "details:"),
            r["runId"].as_str().unwrap_or("")
        ));
    }
    if r["signature"].is_null() && !ai {
        s.push_str(&tr(
            "⚠ 서명 키를 만들지 못해 이 결과는 게이트에서 쓰이지 않습니다.\n",
            "⚠ no signing key, so this result cannot be used by gates.\n",
        ));
    }
    s
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// 실행의 모든 노드 보고서를 JUnit 하나로 합친다(CI 업로드용).
pub fn junit(r: &Value, st: &Store) -> String {
    let dir = st.run_dir(r["runId"].as_str().unwrap_or(""));
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites name=\"gitch-flow\">\n",
    );
    for n in r["nodes"].as_array().cloned().unwrap_or_default() {
        let id = n["id"].as_str().unwrap_or("");
        let rep: Option<Value> = n["report"]
            .as_str()
            .and_then(|p| std::fs::read_to_string(dir.join(p)).ok())
            .and_then(|t| serde_json::from_str(&t).ok());
        match rep {
            Some(rep) => {
                let cases = rep["cases"].as_array().cloned().unwrap_or_default();
                let failures = cases.iter().filter(|c| c["status"] == "failed").count();
                let skipped = cases.iter().filter(|c| c["status"] == "skipped").count();
                out.push_str(&format!(
                    "  <testsuite name=\"{}\" tests=\"{}\" failures=\"{failures}\" skipped=\"{skipped}\" time=\"{:.3}\">\n",
                    esc(id),
                    cases.len(),
                    rep["durationMs"].as_u64().unwrap_or(0) as f64 / 1000.0
                ));
                for c in cases {
                    let name = esc(c["name"].as_str().unwrap_or(""));
                    let file = c["file"]
                        .as_str()
                        .map(|f| format!(" file=\"{}\"", esc(f)))
                        .unwrap_or_default();
                    let line = c["line"]
                        .as_u64()
                        .map(|l| format!(" line=\"{l}\""))
                        .unwrap_or_default();
                    let t = c["durationMs"].as_u64().unwrap_or(0) as f64 / 1000.0;
                    match c["status"].as_str() {
                        Some("failed") => out.push_str(&format!("    <testcase classname=\"{}\" name=\"{name}\" time=\"{t:.3}\"{file}{line}><failure message=\"{}\"/></testcase>\n", esc(id), esc(c["message"].as_str().unwrap_or("")))),
                        Some("skipped") => out.push_str(&format!("    <testcase classname=\"{}\" name=\"{name}\" time=\"{t:.3}\"{file}{line}><skipped/></testcase>\n", esc(id))),
                        Some("flaky") => out.push_str(&format!("    <testcase classname=\"{}\" name=\"{name}\" time=\"{t:.3}\"{file}{line}><system-out>flaky: passed on retry</system-out></testcase>\n", esc(id))),
                        _ => out.push_str(&format!("    <testcase classname=\"{}\" name=\"{name}\" time=\"{t:.3}\"{file}{line}/>\n", esc(id))),
                    }
                }
                out.push_str("  </testsuite>\n");
            }
            None => {
                // 테스트가 아닌 노드는 케이스 하나로(판정이 실패면 실패).
                let state = n["state"].as_str().unwrap_or("");
                out.push_str(&format!(
                    "  <testsuite name=\"{}\" tests=\"1\" failures=\"{}\">\n",
                    esc(id),
                    if matches!(state, "FAILED" | "INDETERMINATE" | "REJECTED") {
                        1
                    } else {
                        0
                    }
                ));
                let t = n["durationMs"].as_u64().unwrap_or(0) as f64 / 1000.0;
                match state {
                    "FAILED" | "INDETERMINATE" | "REJECTED" => out.push_str(&format!("    <testcase classname=\"gitch-flow\" name=\"{}\" time=\"{t:.3}\"><failure message=\"{}\"/></testcase>\n", esc(id), esc(n["code"].as_str().unwrap_or("")))),
                    "SKIPPED" | "CANCELLED" => out.push_str(&format!("    <testcase classname=\"gitch-flow\" name=\"{}\"><skipped/></testcase>\n", esc(id))),
                    _ => out.push_str(&format!("    <testcase classname=\"gitch-flow\" name=\"{}\" time=\"{t:.3}\"/>\n", esc(id))),
                }
                out.push_str("  </testsuite>\n");
            }
        }
    }
    out.push_str("</testsuites>\n");
    out
}

/// Markdown 요약(PR 댓글 · CI 요약 칸용).
pub fn markdown(r: &Value) -> String {
    let mut s = format!(
        "### {} gitch flow `{}` · {} · {}\n\n| {} | {} | {} | {} |\n|---|---|---|---|\n",
        mark(r["state"].as_str().unwrap_or("")),
        r["flow"].as_str().unwrap_or(""),
        r["env"].as_str().unwrap_or(""),
        state_word(r["state"].as_str().unwrap_or("")),
        tr("노드", "Node"),
        tr("상태", "State"),
        tr("테스트", "Tests"),
        tr("시간", "Time")
    );
    for n in r["nodes"].as_array().cloned().unwrap_or_default() {
        let tests = n["tests"]
            .as_object()
            .map(|t| format!("{}/{}", t["passed"], t["executed"]))
            .unwrap_or_default();
        let code = n["code"]
            .as_str()
            .filter(|_| n["state"] != "PASSED")
            .map(|c| format!(" `{c}`"))
            .unwrap_or_default();
        s.push_str(&format!(
            "| {} | {} {}{code} | {tests} | {} |\n",
            n["id"].as_str().unwrap_or(""),
            mark(n["state"].as_str().unwrap_or("")),
            n["state"].as_str().unwrap_or(""),
            util::human_duration(n["durationMs"].as_u64().unwrap_or(0))
        ));
    }
    s
}

fn html(r: &Value) -> String {
    let rows: String = r["nodes"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|n| {
            let fails: String = n["failures"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .map(|f| {
                    format!(
                        "<li><code>{}:{}</code> {} — {}</li>",
                        esc(f["file"].as_str().unwrap_or("")),
                        f["line"],
                        esc(f["name"].as_str().unwrap_or("")),
                        esc(f["message"].as_str().unwrap_or(""))
                    )
                })
                .collect();
            format!(
                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>{}",
                esc(n["id"].as_str().unwrap_or("")),
                esc(n["state"].as_str().unwrap_or("")),
                esc(n["code"].as_str().unwrap_or("")),
                util::human_duration(n["durationMs"].as_u64().unwrap_or(0)),
                if fails.is_empty() {
                    String::new()
                } else {
                    format!("<tr><td colspan=4><ul>{fails}</ul></td></tr>")
                }
            )
        })
        .collect();
    format!(
        "<!doctype html><meta charset=utf-8><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>gitch flow {}</title><style>body{{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#222;background:#fff}}@media(prefers-color-scheme:dark){{body{{color:#ddd;background:#1e1e1e}}}}table{{border-collapse:collapse}}td,th{{padding:4px 10px;border-bottom:1px solid #8884}}code{{font-size:12px}}</style><h1>{} · {} · {}</h1><table><tr><th>node</th><th>state</th><th>code</th><th>time</th></tr>{rows}</table>",
        esc(r["runId"].as_str().unwrap_or("")),
        esc(r["flow"].as_str().unwrap_or("")),
        esc(r["env"].as_str().unwrap_or("")),
        esc(r["state"].as_str().unwrap_or(""))
    )
}

pub fn cmd_report(out: &Out, args: &Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return out_fail(out);
    };
    let Some(st) = Store::open(&root) else {
        return out_fail(out);
    };
    let id = match resolve_run(out, &st, args.pos.first()) {
        Ok(i) => i,
        Err(c) => return c,
    };
    let Some(mut r) = st.read_run(&id) else {
        return out_fail(out);
    };
    r["signed"] = Value::Bool(store::verify(&r));
    let format = args.val("--format").unwrap_or_else(|| {
        if out.json {
            "json".into()
        } else {
            "text".into()
        }
    });
    let text = match format.as_str() {
        "json" => serde_json::to_string_pretty(&r).unwrap_or_default(),
        "junit" => junit(&r, &st),
        "md" | "markdown" => markdown(&r),
        "html" => html(&r),
        _ => digest(&r, &st, false),
    };
    match args.val("--out") {
        Some(p) => match util::write_atomic(std::path::Path::new(&p), text.as_bytes()) {
            Ok(_) => {
                println!("{p}");
                0
            }
            Err(e) => {
                eprintln!("{e}");
                1
            }
        },
        None => {
            print!("{text}");
            if !text.ends_with('\n') {
                println!();
            }
            0
        }
    }
}

fn out_fail(out: &Out) -> i32 {
    if out.json {
        eprintln!(
            "{}",
            serde_json::json!({"schemaVersion": 1, "error": {"code": "GITCH_ERROR", "flowCode": "ENGINE-02", "message": crate::codes::describe("ENGINE-02"), "exitCode": 1}})
        );
    } else {
        eprintln!("{}", crate::codes::line("ENGINE-02"));
    }
    1
}
