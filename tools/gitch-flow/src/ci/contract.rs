//! Result contract v1: the files and marker line `gitch flow run --ci` leaves behind. The remote adapters judge by it (local = CI).
//! The marker line is small and holds no secrets. CI masking of short secrets can break the JSON, so the files are kept as well.

use crate::store::Store;
use crate::util::tr;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const MARKER: &str = "GITCH-FLOW-RESULT";

pub fn out_dir(root: &Path) -> PathBuf {
    std::env::var("GITCH_FLOW_OUT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("gitch-flow-out"))
}

/// A small summary (for the marker line and remote verdicts).
pub fn small(summary: &Value) -> Value {
    let failures: Vec<Value> = summary["nodes"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .flat_map(|n| {
            let id = n["id"].as_str().unwrap_or("").to_string();
            let code = n["code"].clone();
            let list = n["failures"].as_array().cloned().unwrap_or_default();
            if list.is_empty() && matches!(n["state"].as_str(), Some("FAILED" | "INDETERMINATE" | "REJECTED")) {
                vec![json!({"node": id, "code": code})]
            } else {
                list.into_iter().map(move |f| json!({"node": id, "name": f["name"], "file": f["file"], "line": f["line"]})).collect()
            }
        })
        .take(10)
        .collect();
    json!({"v": 1, "runId": summary["runId"], "flow": summary["flow"], "env": summary["env"], "state": summary["state"], "code": summary["code"],
           "sha": summary["git"]["sha"], "counts": summary["counts"], "failures": failures})
}

/// CI mode outputs: result JSON, merged JUnit, Markdown summary, marker line, GitHub annotations.
pub fn write(root: &Path, summary: &Value, st: &Store) {
    let dir = out_dir(root);
    let _ = std::fs::create_dir_all(&dir);
    let _ = crate::util::write_atomic(
        &dir.join("gitch-flow-result.json"),
        serde_json::to_string_pretty(summary)
            .unwrap_or_default()
            .as_bytes(),
    );
    let _ = crate::util::write_atomic(
        &dir.join("junit.xml"),
        crate::report_out::junit(summary, st).as_bytes(),
    );
    let md = crate::report_out::markdown(summary);
    let _ = crate::util::write_atomic(&dir.join("summary.md"), md.as_bytes());
    let run_dir = st.run_dir(summary["runId"].as_str().unwrap_or(""));
    let logs = run_dir.join("logs");
    if let Ok(rd) = std::fs::read_dir(&logs) {
        let _ = std::fs::create_dir_all(dir.join("logs"));
        for e in rd.flatten() {
            let _ = std::fs::copy(e.path(), dir.join("logs").join(e.file_name()));
        }
    }
    if std::env::var("GITHUB_ACTIONS")
        .map(|v| v == "true")
        .unwrap_or(false)
    {
        for n in summary["nodes"].as_array().cloned().unwrap_or_default() {
            for f in n["failures"].as_array().cloned().unwrap_or_default() {
                let file = f["file"].as_str().unwrap_or("");
                let line = f["line"].as_u64().unwrap_or(1);
                let msg = f["message"]
                    .as_str()
                    .unwrap_or("")
                    .replace('\n', " ")
                    .replace('%', "%25");
                let title = format!(
                    "{} · {}",
                    n["id"].as_str().unwrap_or(""),
                    f["name"].as_str().unwrap_or("")
                )
                .replace(',', ";");
                if file.is_empty() {
                    println!("::error title={title}::{msg}");
                } else {
                    println!("::error file={file},line={line},title={title}::{msg}");
                }
            }
        }
        if let Ok(p) = std::env::var("GITHUB_STEP_SUMMARY") {
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(p)
            {
                use std::io::Write;
                let _ = writeln!(f, "{md}");
            }
        }
    }
    println!("{MARKER} {}", small(summary));
    eprintln!(
        "{}",
        tr(
            &format!("결과 계약: {}", dir.display()),
            &format!("result contract: {}", dir.display())
        )
    );
}

/// Reads the last marker line from a log (skipping lines that are not JSON).
pub fn parse_marker(text: &str) -> Option<Value> {
    let mut last = None;
    for line in text.lines() {
        // CI logs may prefix lines with a timestamp or step name.
        if let Some(i) = line.find(MARKER) {
            let rest = line[i + MARKER.len()..].trim();
            if let Ok(v) = serde_json::from_str::<Value>(rest) {
                if v["v"].as_u64() == Some(1) {
                    last = Some(v);
                }
            }
        }
    }
    last
}

/// The contract's verdict: PASS when the run state is SUCCEEDED.
pub fn outcome(c: &Value) -> crate::verify::Outcome {
    match c["state"].as_str() {
        Some("SUCCEEDED") => crate::verify::Outcome::Pass,
        Some(_) => crate::verify::Outcome::Fail,
        None => crate::verify::Outcome::Indeterminate,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn last_valid_marker_wins() {
        let log = format!("noise\n2026-10-26T00:00:00Z {MARKER} {{\"v\":1,\"state\":\"FAILED\"}}\n{MARKER} not-json\n[step] {MARKER} {{\"v\":1,\"state\":\"SUCCEEDED\"}}\n");
        let m = parse_marker(&log).unwrap();
        assert_eq!(m["state"], "SUCCEEDED");
        assert_eq!(outcome(&m), crate::verify::Outcome::Pass);
        assert!(parse_marker("nothing here").is_none());
        assert!(parse_marker(&format!("{MARKER} {{\"v\":2,\"state\":\"SUCCEEDED\"}}")).is_none());
    }
}
