//! Trusting flow files. A flow file is code, so it runs unattended only when its hash matches one a person reviewed and approved.
//! The records live outside the repository in `~/.config/gitsw/flow/trust/`, where gitch guard keeps AI agents from editing.

use crate::spec::Spec;
use crate::util;
use serde_json::{json, Value};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

/// Identifies the actor by the same rules as gitch.
pub fn actor() -> String {
    if let Ok(a) = std::env::var("GITSW_ACTOR") {
        if !a.is_empty() {
            return a;
        }
    }
    if std::io::stdin().is_terminal() || std::io::stderr().is_terminal() {
        return "human".into();
    }
    let set = |k: &str| std::env::var(k).map(|v| !v.is_empty()).unwrap_or(false);
    if set("CLAUDECODE") {
        "claude".into()
    } else if [
        "CODEX_SANDBOX",
        "CODEX_SANDBOX_NETWORK_DISABLED",
        "CODEX_THREAD_ID",
        "CODEX_CI",
    ]
    .iter()
    .any(|k| set(k))
    {
        "codex".into()
    } else if set("CURSOR_AGENT") || set("CURSOR_TRACE_ID") {
        "cursor".into()
    } else if set("GEMINI_CLI") {
        "gemini".into()
    } else if set("AI_AGENT") {
        "ai".into()
    } else {
        "script".into()
    }
}

pub fn is_ai(actor: &str) -> bool {
    matches!(actor, "claude" | "codex" | "cursor" | "gemini" | "ai")
}

/// A fixed ID per repository (from the absolute path of the common .git folder).
pub fn repo_id(root: &Path) -> String {
    let base = crate::git::common_dir(root).unwrap_or_else(|| root.to_path_buf());
    let canonical = base.canonicalize().unwrap_or(base);
    util::sha256_hex(canonical.to_string_lossy().as_bytes())[..16].to_string()
}

pub fn trust_path(root: &Path) -> PathBuf {
    util::gitsw_dir()
        .join("flow")
        .join("trust")
        .join(format!("{}.json", repo_id(root)))
}

#[derive(Debug, Clone)]
pub struct Status {
    pub trusted: bool,
    /// Files that changed or appeared since the approval.
    pub changed: Vec<String>,
    pub approved_at: Option<String>,
    pub ever: bool,
}

pub fn status(spec: &Spec) -> Status {
    let rec: Option<Value> = std::fs::read_to_string(trust_path(&spec.root))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());
    let Some(rec) = rec else {
        return Status {
            trusted: false,
            changed: spec.files.iter().map(|f| f.rel.clone()).collect(),
            approved_at: None,
            ever: false,
        };
    };
    let trusted = rec["filesHash"].as_str() == Some(spec.files_hash().as_str());
    let mut changed = Vec::new();
    if !trusted {
        let old: Vec<(String, String)> = rec["files"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|f| {
                        (
                            f["rel"].as_str().unwrap_or("").to_string(),
                            f["sha256"].as_str().unwrap_or("").to_string(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        for f in &spec.files {
            if !old.iter().any(|(r, h)| r == &f.rel && h == &f.sha256) {
                changed.push(f.rel.clone());
            }
        }
        for (r, _) in &old {
            if !spec.files.iter().any(|f| &f.rel == r) {
                changed.push(format!("{r} (removed)"));
            }
        }
    }
    Status {
        trusted,
        changed,
        approved_at: rec["approvedAt"].as_str().map(|s| s.to_string()),
        ever: true,
    }
}

pub fn approve(spec: &Spec, outward: &[String], by: &str) -> std::io::Result<PathBuf> {
    let p = trust_path(&spec.root);
    let rec = json!({
        "schemaVersion": 1,
        "repo": spec.root.to_string_lossy(),
        "approvedAt": util::rfc3339(util::now_ms()),
        "approvedBy": by,
        "engineVersion": env!("CARGO_PKG_VERSION"),
        "filesHash": spec.files_hash(),
        "files": spec.files.iter().map(|f| json!({"rel": f.rel, "sha256": f.sha256})).collect::<Vec<_>>(),
        "outward": outward,
    });
    util::write_atomic(
        &p,
        serde_json::to_string_pretty(&rec)
            .unwrap_or_default()
            .as_bytes(),
    )?;
    Ok(p)
}

pub fn revoke(root: &Path) -> bool {
    std::fs::remove_file(trust_path(root)).is_ok()
}
