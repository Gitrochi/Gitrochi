//! 감시 모드: 파일을 저장하면 영향받은 노드만 다시 돌린다. 파일 상태를 짧은 간격으로 비교하는 방식이라
//! 운영체제별 감시 API 에 기대지 않는다(큰 저장소는 추적 파일의 크기 · 시각만 본다).

use crate::cli::{Args, Out};
use crate::spec::Spec;
use crate::util::tr;
use std::collections::HashMap;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

fn snapshot(root: &Path) -> HashMap<String, (u64, SystemTime)> {
    let mut m = HashMap::new();
    for f in crate::git::ls_files(root) {
        if f.starts_with(".git/") {
            continue;
        }
        if let Ok(md) = std::fs::metadata(root.join(&f)) {
            m.insert(
                f,
                (md.len(), md.modified().unwrap_or(SystemTime::UNIX_EPOCH)),
            );
        }
    }
    m
}

fn changed(
    a: &HashMap<String, (u64, SystemTime)>,
    b: &HashMap<String, (u64, SystemTime)>,
) -> Vec<String> {
    let mut out: Vec<String> = b
        .iter()
        .filter(|(k, v)| a.get(*k) != Some(v))
        .map(|(k, _)| k.clone())
        .collect();
    out.extend(a.keys().filter(|k| !b.contains_key(*k)).cloned());
    out.sort();
    out
}

fn loop_runs(out: &Out, args: &Args, root: &Path, mut once: impl FnMut(&Args) -> i32) -> i32 {
    let interval = Duration::from_millis(400);
    let mut last = snapshot(root);
    println!(
        "{}",
        tr(
            "감시 중 — 파일을 저장하면 다시 돌립니다(Ctrl-C 로 끝).",
            "watching — saving a file runs it again (Ctrl-C to stop)."
        )
    );
    let _ = once(args);
    loop {
        std::thread::sleep(interval);
        let now = snapshot(root);
        let diff = changed(&last, &now);
        if diff.is_empty() {
            continue;
        }
        // 저장이 몇 번 이어지는 동안 기다렸다가 한 번만 돌린다.
        let settle = Instant::now();
        let mut cur = now;
        while settle.elapsed() < Duration::from_millis(300) {
            std::thread::sleep(Duration::from_millis(100));
            let n = snapshot(root);
            if !changed(&cur, &n).is_empty() {
                cur = n;
            }
        }
        last = cur;
        if diff
            .iter()
            .all(|f| f.starts_with(".gitch/") && !f.ends_with(".yml"))
        {
            continue;
        }
        println!(
            "\n{} {}",
            tr("바뀜:", "changed:"),
            diff.iter().take(5).cloned().collect::<Vec<_>>().join(", ")
        );
        let mut a = Args {
            pos: args.pos.clone(),
            flags: args.flags.clone(),
        };
        a.flags.remove("--watch");
        a.flags
            .entry("--affected".into())
            .or_insert(Some("worktree".into()));
        let _ = once(&a);
        if out.json {
            break;
        }
    }
    0
}

pub fn cmd_watch(out: &Out, args: &Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return 1;
    };
    loop_runs(out, args, &root, |a| crate::cli::cmd_run(out, a, None))
}

pub fn watch_tests(out: &Out, args: &Args, spec: Spec) -> i32 {
    let root = spec.root.clone();
    loop_runs(out, args, &root, |a| {
        let mut b = Args {
            pos: a.pos.clone(),
            flags: a.flags.clone(),
        };
        b.flags.remove("--watch");
        // 즉석 흐름은 cmd_test 가 매번 새로 만든다.
        crate::cli::main(
            std::iter::once("test".to_string())
                .chain(b.pos.clone())
                .chain(
                    b.flags
                        .iter()
                        .flat_map(|(k, v)| std::iter::once(k.clone()).chain(v.clone())),
                )
                .collect(),
        )
    })
}
