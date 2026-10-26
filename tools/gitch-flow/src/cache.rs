//! Result cache. Stores only the passing results of pure nodes that declare their inputs (`cache: { inputs: [...] }`),
//! and replays the earlier verdict and reports for the same inputs. Nodes with services, network, remote calls or changes are never cached.

use crate::plan::{Decision, PNode, Plan};
use crate::spec::Spec;
use crate::util::{self, glob_match, tr};
use serde_json::Value;
use std::path::PathBuf;

fn dir() -> PathBuf {
    util::cache_dir().join("results")
}

/// Whether the node may be cached.
pub fn cacheable(n: &PNode) -> bool {
    n.def.cache.is_some()
        && n.services.is_empty()
        && !n.outward
        && !n.destructive
        && !n
            .capabilities
            .iter()
            .any(|c| c == "network" || c == "docker" || c == "ci-api" || c == "ssh")
        && n.branch_of.is_none()
        && n.block != "gate.manual"
}

/// Cache key: block, inputs, environment, expectations, selection, declared input file contents, engine version and OS.
pub fn key(spec: &Spec, n: &PNode, files: &[String]) -> Option<String> {
    let c = n.def.cache.as_ref()?;
    let mut s = String::new();
    s.push_str(&format!(
        "v1\n{}\n{}\n",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS
    ));
    s.push_str(&format!(
        "{}@{}\n",
        n.block,
        crate::blocks::get(&n.block)
            .map(|b| b.meta().version)
            .unwrap_or("?")
    ));
    s.push_str(&format!(
        "with={}\nexpect={}\nenv={:?}\nselection={:?}\nscope={}\nmatrix={}\nexecutor={}\n",
        n.with,
        n.expect.raw,
        n.def.env,
        n.selection,
        n.scope_inputs,
        n.matrix,
        n.executor.as_str()
    ));
    for k in &c.key {
        s.push_str(&format!("key={k}\n"));
    }
    let globs = if c.inputs.is_empty() {
        vec!["**".to_string()]
    } else {
        c.inputs.clone()
    };
    let mut matched: Vec<&String> = files
        .iter()
        .filter(|f| globs.iter().any(|g| glob_match(g, f)))
        .collect();
    matched.sort();
    if matched.len() > 20_000 {
        return None;
    }
    for f in matched {
        let data = std::fs::read(spec.root.join(f)).unwrap_or_default();
        s.push_str(&format!("{f}\0{}\n", util::sha256_hex(&data)));
    }
    Some(util::sha256_hex(s.as_bytes())[..32].to_string())
}

pub fn load(key: &str) -> Option<Value> {
    let t = std::fs::read_to_string(dir().join(format!("{key}.json"))).ok()?;
    serde_json::from_str(&t).ok()
}

pub fn store(key: &str, node: &Value) {
    let _ = util::write_atomic(
        &dir().join(format!("{key}.json")),
        node.to_string().as_bytes(),
    );
}

/// Puts cache keys on the plan and skips a node as "cached" when a matching result exists.
pub fn annotate(spec: &Spec, plan: &mut Plan) {
    if !plan.nodes.iter().any(cacheable) {
        return;
    }
    let files = crate::git::ls_files(&spec.root);
    for n in plan.nodes.iter_mut() {
        if n.decision != Decision::Run || !cacheable(n) {
            continue;
        }
        let Some(k) = key(spec, n, &files) else {
            continue;
        };
        if load(&k).map(|v| v["state"] == "PASSED").unwrap_or(false) {
            n.decision = Decision::Skip(
                "cached",
                tr(
                    &format!("같은 입력으로 통과한 결과가 있음({})", &k[..12]),
                    &format!("passed before with the same inputs ({})", &k[..12]),
                ),
            );
        }
        n.cache_key = Some(k);
    }
}

/// Removes old cache entries (by modification time).
pub fn gc(older_than_ms: u64, dry_run: bool) -> usize {
    let now = util::now_ms();
    let mut n = 0;
    if let Ok(rd) = std::fs::read_dir(dir()) {
        for e in rd.flatten() {
            let old = e
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| now.saturating_sub(d.as_millis() as u64) > older_than_ms)
                .unwrap_or(false);
            if old {
                n += 1;
                if !dry_run {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
    }
    n
}
