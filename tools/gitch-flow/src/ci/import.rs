//! `gitch flow import`: reads existing CI configuration (GitHub workflows, .gitlab-ci.yml, declarative Jenkinsfile) and proposes a flow.
//! `run`/`script` steps that can run locally become local nodes; jobs that only make sense remotely (deploys, manual jobs) become ci.* node comments.
//! What it cannot read (include, matrices, plugin steps) is reported as diagnostics rather than pretended to be understood.

use crate::cli::{Args, Out};
use crate::util::tr;
use serde_json::{json, Map, Value};
use std::path::Path;
use yaml_rust2::{Yaml, YamlLoader};

/// Loose YAML → JSON (import only: anchors, aliases and merge keys are resolved).
fn loose(y: &Yaml) -> Value {
    match y {
        Yaml::Real(s) => s
            .parse::<f64>()
            .ok()
            .and_then(serde_json::Number::from_f64)
            .map(Value::Number)
            .unwrap_or(Value::String(s.clone())),
        Yaml::Integer(i) => json!(i),
        Yaml::String(s) => json!(s),
        Yaml::Boolean(b) => json!(b),
        Yaml::Array(a) => Value::Array(a.iter().map(loose).collect()),
        Yaml::Hash(h) => {
            let mut m = Map::new();
            for (k, v) in h {
                let key = match k {
                    Yaml::String(s) => s.clone(),
                    Yaml::Integer(i) => i.to_string(),
                    Yaml::Boolean(b) => b.to_string(),
                    _ => continue,
                };
                if key == "<<" {
                    let merged = loose(v);
                    let list = if let Value::Array(a) = merged {
                        a
                    } else {
                        vec![merged]
                    };
                    for item in list {
                        if let Value::Object(o) = item {
                            for (mk, mv) in o {
                                m.entry(mk).or_insert(mv);
                            }
                        }
                    }
                    continue;
                }
                m.insert(key, loose(v));
            }
            Value::Object(m)
        }
        _ => Value::Null,
    }
}

fn load_loose(text: &str) -> Option<Value> {
    YamlLoader::load_from_str(text).ok()?.first().map(loose)
}

struct Node {
    id: String,
    run: Vec<String>,
    needs: Vec<String>,
    remote: Option<String>,
    notes: Vec<String>,
}

fn slug(s: &str) -> String {
    let mut out: String = s
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    while out.contains("--") {
        out = out.replace("--", "-");
    }
    let t = out.trim_matches('-').to_string();
    if t.is_empty() || !t.chars().next().unwrap().is_ascii_alphanumeric() {
        format!("job-{t}")
    } else {
        t
    }
}

fn lines_of(v: &Value) -> Vec<String> {
    match v {
        Value::String(s) => vec![s.clone()],
        Value::Array(a) => a
            .iter()
            .filter_map(|x| x.as_str().map(|s| s.to_string()))
            .collect(),
        _ => Vec::new(),
    }
}

fn is_remote_only(name: &str, job: &Value) -> bool {
    let n = name.to_ascii_lowercase();
    job.get("environment").is_some()
        || n.contains("deploy")
        || n.contains("release")
        || n.contains("publish")
}

fn from_github(root: &Path, diags: &mut Vec<String>) -> Vec<(String, Vec<Node>)> {
    let mut out = Vec::new();
    let dir = root.join(".github/workflows");
    let mut files: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| n.ends_with(".yml") || n.ends_with(".yaml"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    for f in files {
        if f.starts_with("gitch-") {
            continue;
        }
        let Some(v) = std::fs::read_to_string(dir.join(&f))
            .ok()
            .and_then(|t| load_loose(&t))
        else {
            diags.push(format!(
                ".github/workflows/{f}: {}",
                tr("읽지 못함", "could not be read")
            ));
            continue;
        };
        let mut nodes = Vec::new();
        for (jid, job) in v["jobs"].as_object().cloned().unwrap_or_default() {
            let mut n = Node {
                id: slug(&jid),
                run: Vec::new(),
                needs: lines_of(&job["needs"]).iter().map(|x| slug(x)).collect(),
                remote: None,
                notes: Vec::new(),
            };
            if job.get("strategy").and_then(|s| s.get("matrix")).is_some() {
                n.notes.push(tr(
                    "행렬(matrix)은 가져오지 않음 — 한 조합만",
                    "matrix not imported — one combination only",
                ));
            }
            if job.get("services").is_some() {
                n.notes.push(tr(
                    "services 는 docker.service 로 옮기세요",
                    "move services to docker.service",
                ));
            }
            if job.get("uses").is_some() {
                n.notes.push(tr(
                    "재사용 워크플로 호출은 가져오지 않음",
                    "reusable workflow calls are not imported",
                ));
            }
            for st in job["steps"].as_array().cloned().unwrap_or_default() {
                if let Some(r) = st["run"].as_str() {
                    let wd = st["working-directory"]
                        .as_str()
                        .map(|w| format!("cd {} && ", crate::util::shell_quote(w)))
                        .unwrap_or_default();
                    n.run.push(format!("{wd}{}", r.trim_end()));
                } else if let Some(u) = st["uses"].as_str() {
                    if !u.starts_with("actions/checkout")
                        && !u.starts_with("actions/upload-artifact")
                        && !u.starts_with("actions/cache")
                    {
                        n.notes.push(format!(
                            "uses: {u} — {}",
                            tr("로컬에선 건너뜀", "skipped locally")
                        ));
                    }
                }
            }
            if is_remote_only(&jid, &job) {
                n.remote = Some(format!(
                    "ci.github.workflow  # with: {{ connection: github, workflow: {f} }}"
                ));
            }
            nodes.push(n);
        }
        if !nodes.is_empty() {
            out.push((
                format!(
                    "imported-{}",
                    slug(f.trim_end_matches(".yml").trim_end_matches(".yaml"))
                ),
                nodes,
            ));
        }
    }
    out
}

const GITLAB_RESERVED: &[&str] = &[
    "stages",
    "variables",
    "include",
    "default",
    "workflow",
    "image",
    "services",
    "before_script",
    "after_script",
    "cache",
    "pages",
];

fn from_gitlab(root: &Path, diags: &mut Vec<String>) -> Vec<(String, Vec<Node>)> {
    let Some(text) = std::fs::read_to_string(root.join(".gitlab-ci.yml")).ok() else {
        return Vec::new();
    };
    let Some(v) = load_loose(&text) else {
        diags.push(format!(
            ".gitlab-ci.yml: {}",
            tr("읽지 못함", "could not be read")
        ));
        return Vec::new();
    };
    if v.get("include").is_some() {
        diags.push(tr(
            ".gitlab-ci.yml: include 는 풀지 않았습니다(원격 · 다른 파일).",
            ".gitlab-ci.yml: include was not resolved (remote or other files).",
        ));
    }
    let stages: Vec<String> = v["stages"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(|x| x.to_string()))
                .collect()
        })
        .unwrap_or_else(|| vec!["build".into(), "test".into(), "deploy".into()]);
    let global_before = lines_of(&v["before_script"])
        .into_iter()
        .chain(lines_of(&v["default"]["before_script"]))
        .collect::<Vec<_>>();
    let obj = v.as_object().cloned().unwrap_or_default();
    let hidden: Map<String, Value> = obj
        .iter()
        .filter(|(k, _)| k.starts_with('.'))
        .map(|(k, x)| (k.clone(), x.clone()))
        .collect();
    let mut jobs: Vec<(String, Value, usize)> = Vec::new();
    for (name, job) in &obj {
        if name.starts_with('.') || GITLAB_RESERVED.contains(&name.as_str()) || !job.is_object() {
            continue;
        }
        let mut j = job.clone();
        if let Some(ext) = j.get("extends").cloned() {
            for e in lines_of(&ext) {
                match hidden.get(&e) {
                    Some(base) => {
                        let mut b = base.clone();
                        crate::spec::deep_merge(&mut b, &j);
                        j = b;
                    }
                    None => diags.push(format!(
                        ".gitlab-ci.yml {name}: extends {e} {}",
                        tr("을(를) 찾지 못함", "not found")
                    )),
                }
            }
        }
        if j.get("script").is_none() && j.get("trigger").is_none() {
            continue;
        }
        let stage = j["stage"].as_str().unwrap_or("test");
        let idx = stages.iter().position(|s| s == stage).unwrap_or(1);
        jobs.push((name.clone(), j, idx));
    }
    jobs.sort_by_key(|x| x.2);
    let mut nodes = Vec::new();
    for (name, j, idx) in &jobs {
        let explicit: Vec<String> = match &j["needs"] {
            Value::Array(a) => a
                .iter()
                .filter_map(|x| {
                    x.as_str()
                        .map(|s| s.to_string())
                        .or_else(|| x["job"].as_str().map(|s| s.to_string()))
                })
                .collect(),
            _ => Vec::new(),
        };
        let needs: Vec<String> = if j.get("needs").is_some() {
            explicit
        } else {
            jobs.iter()
                .filter(|(_, _, i)| *i + 1 == *idx)
                .map(|(n, _, _)| n.clone())
                .collect()
        };
        let mut n = Node {
            id: slug(name),
            run: Vec::new(),
            needs: needs.iter().map(|x| slug(x)).collect(),
            remote: None,
            notes: Vec::new(),
        };
        let before = if j.get("before_script").is_some() {
            lines_of(&j["before_script"])
        } else {
            global_before.clone()
        };
        n.run.extend(before);
        n.run.extend(lines_of(&j["script"]));
        if j["when"] == "manual" {
            n.remote = Some(format!(
                "ci.gitlab.job  # with: {{ connection: gitlab, job: {name} }}"
            ));
        } else if is_remote_only(name, j) || j.get("trigger").is_some() {
            n.remote = Some("ci.gitlab.pipeline  # with: { connection: gitlab }".into());
        }
        if j.get("parallel").is_some() {
            n.notes.push(tr(
                "parallel/matrix 는 가져오지 않음",
                "parallel/matrix not imported",
            ));
        }
        if j.get("services").is_some() || v.get("services").is_some() {
            n.notes.push(tr(
                "services 는 docker.service 로 옮기세요",
                "move services to docker.service",
            ));
        }
        if let Some(img) = j["image"].as_str().or(v["image"].as_str()) {
            n.notes.push(format!(
                "image: {img} — {}",
                tr(
                    "executor: docker 로 같은 이미지를 쓸 수 있음",
                    "executor: docker can use the same image"
                )
            ));
        }
        nodes.push(n);
    }
    if nodes.is_empty() {
        Vec::new()
    } else {
        vec![("imported-gitlab".into(), nodes)]
    }
}

fn from_jenkins(root: &Path, diags: &mut Vec<String>) -> Vec<(String, Vec<Node>)> {
    let Some(text) = std::fs::read_to_string(root.join("Jenkinsfile")).ok() else {
        return Vec::new();
    };
    if !text.contains("pipeline") {
        diags.push(tr(
            "Jenkinsfile: 선언형(pipeline {})이 아니어서 가져오지 않았습니다.",
            "Jenkinsfile: not declarative (pipeline {}), not imported.",
        ));
        return Vec::new();
    }
    let stage_re = regex::Regex::new(r#"stage\s*\(\s*['"]([^'"]+)['"]\s*\)"#).unwrap();
    let sh_re = regex::Regex::new(r#"(?s)\bsh\s*(?:\(\s*)?(?:script:\s*)?(?:'''(.*?)'''|"""(.*?)"""|'([^'\n]*)'|"([^"\n]*)")"#).unwrap();
    let starts: Vec<(usize, String)> = stage_re
        .captures_iter(&text)
        .map(|c| (c.get(0).unwrap().start(), c[1].to_string()))
        .collect();
    let mut nodes: Vec<Node> = Vec::new();
    for (i, (pos, name)) in starts.iter().enumerate() {
        let end = starts.get(i + 1).map(|x| x.0).unwrap_or(text.len());
        let body = &text[*pos..end];
        let mut n = Node {
            id: slug(name),
            run: Vec::new(),
            needs: nodes.last().map(|p| vec![p.id.clone()]).unwrap_or_default(),
            remote: None,
            notes: Vec::new(),
        };
        for c in sh_re.captures_iter(body) {
            let cmd = c
                .get(1)
                .or(c.get(2))
                .or(c.get(3))
                .or(c.get(4))
                .map(|m| m.as_str().trim().to_string())
                .unwrap_or_default();
            if !cmd.is_empty() {
                n.run.push(cmd);
            }
        }
        if body.contains("input ") || body.contains("input(") {
            n.notes.push(tr(
                "input(사람 승인)은 gate.manual 로 옮기세요",
                "move input (approval) to gate.manual",
            ));
        }
        if n.run.is_empty() {
            n.notes.push(tr(
                "sh 단계를 찾지 못함(플러그인 단계는 가져오지 않음)",
                "no sh step found (plugin steps are not imported)",
            ));
        }
        if is_remote_only(name, &Value::Null) {
            n.remote =
                Some("ci.jenkins.job  # with: { connection: jenkins, job: <job path> }".into());
        }
        nodes.push(n);
    }
    if nodes.is_empty() {
        Vec::new()
    } else {
        vec![("imported-jenkins".into(), nodes)]
    }
}

fn render(flows: &[(String, Vec<Node>)]) -> String {
    let mut y = format!("# {}\nflows:\n", tr("gitch flow import 가 기존 CI 설정에서 만든 제안입니다. 확인한 뒤 .gitch/flow.yml 로 옮기세요.", "Proposed by gitch flow import from existing CI settings. Review it, then move it into .gitch/flow.yml."));
    for (name, nodes) in flows {
        y.push_str(&format!("  {name}:\n    trigger: [manual]\n    nodes:\n"));
        let ids: Vec<&str> = nodes.iter().map(|n| n.id.as_str()).collect();
        for n in nodes {
            for note in &n.notes {
                y.push_str(&format!("      # {}: {note}\n", n.id));
            }
            if let Some(r) = &n.remote {
                y.push_str(&format!(
                    "      # {}: {} — {}\n      #   use: {r}\n",
                    n.id,
                    tr("원격에서만 의미 있는 작업", "remote-only job"),
                    tr("로컬로 돌리지 않음", "not run locally")
                ));
                continue;
            }
            if n.run.is_empty() {
                continue;
            }
            let needs: Vec<&String> = n
                .needs
                .iter()
                .filter(|x| ids.contains(&x.as_str()))
                .collect();
            y.push_str(&format!("      {}:\n", n.id));
            if !needs.is_empty() {
                y.push_str(&format!(
                    "        needs: [{}]\n",
                    needs
                        .iter()
                        .map(|s| s.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
            y.push_str("        run: |\n");
            for l in n.run.join("\n").lines() {
                y.push_str(&format!("          {l}\n"));
            }
        }
    }
    y
}

pub fn cmd_import(out: &Out, args: &Args) -> i32 {
    let Some(root) = crate::cli::repo_root(args) else {
        return 1;
    };
    let which = args.pos.first().map(|s| s.as_str());
    let mut diags = Vec::new();
    let mut flows = Vec::new();
    if which.is_none() || which == Some("github") {
        flows.extend(from_github(&root, &mut diags));
    }
    if which.is_none() || which == Some("gitlab") {
        flows.extend(from_gitlab(&root, &mut diags));
    }
    if which.is_none() || which == Some("jenkins") {
        flows.extend(from_jenkins(&root, &mut diags));
    }
    if flows.is_empty() {
        let msg = tr(
            "가져올 CI 설정을 찾지 못했습니다(.github/workflows · .gitlab-ci.yml · Jenkinsfile).",
            "no CI settings to import (.github/workflows, .gitlab-ci.yml, Jenkinsfile).",
        );
        if out.json {
            println!(
                "{}",
                json!({"schemaVersion": 1, "flows": [], "diagnostics": diags, "message": msg})
            );
        } else {
            println!("{msg}");
            for d in &diags {
                println!("  ⚠ {d}");
            }
        }
        return 0;
    }
    let yaml = render(&flows);
    let valid = crate::yaml::parse(&yaml).is_ok();
    let target = root.join(".gitch/flows/imported.yml");
    let mut written = false;
    if args.has("--yes") && !args.has("--dry-run") {
        if target.exists() && !args.has("--force") {
            eprintln!(
                "{}",
                tr(
                    ".gitch/flows/imported.yml 이 이미 있습니다(--force 로 바꾸기).",
                    ".gitch/flows/imported.yml already exists (replace with --force)."
                )
            );
            return 1;
        }
        if crate::util::write_atomic(&target, yaml.as_bytes()).is_ok() {
            written = true;
        }
    }
    if out.json {
        println!("{}", serde_json::to_string_pretty(&json!({"schemaVersion": 1, "flows": flows.iter().map(|(n, ns)| json!({"name": n, "nodes": ns.len()})).collect::<Vec<_>>(), "diagnostics": diags, "valid": valid, "written": written, "path": ".gitch/flows/imported.yml", "yaml": yaml})).unwrap_or_default());
    } else {
        print!("{yaml}");
        for d in &diags {
            println!("# ⚠ {d}");
        }
        if written {
            println!(
                "{}",
                tr(
                    "✔ .gitch/flows/imported.yml 에 썼습니다.",
                    "✔ wrote .gitch/flows/imported.yml."
                )
            );
        } else {
            println!(
                "{}",
                tr(
                    "# 파일로 쓰려면: gitch flow import --yes",
                    "# to write it: gitch flow import --yes"
                )
            );
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(files: &[(&str, &str)]) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("gf-import-{}", crate::util::random_hex(4)));
        for (p, c) in files {
            let path = d.join(p);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, c).unwrap();
        }
        d
    }

    #[test]
    fn imports_all_three() {
        let d = tmp(&[
            (".github/workflows/ci.yml", "on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm ci\n      - run: npm test\n  deploy:\n    needs: test\n    environment: prod\n    steps:\n      - run: ./deploy.sh\n"),
            (".gitlab-ci.yml", ".base: &base\n  before_script: [echo hi]\nstages: [build, test]\nbuild:\n  <<: *base\n  stage: build\n  script: make\nunit:\n  stage: test\n  script: [make test]\nship:\n  stage: test\n  when: manual\n  script: ./ship\n"),
            ("Jenkinsfile", "pipeline { agent any\n stages {\n  stage('Build') { steps { sh 'make' } }\n  stage('Test') { steps { sh '''make test''' } }\n }\n}\n"),
        ]);
        let mut diags = Vec::new();
        let gh = from_github(&d, &mut diags);
        assert_eq!(gh[0].1.len(), 2);
        assert!(gh[0]
            .1
            .iter()
            .find(|n| n.id == "deploy")
            .unwrap()
            .remote
            .is_some());
        let gl = from_gitlab(&d, &mut diags);
        let unit = gl[0].1.iter().find(|n| n.id == "unit").unwrap();
        assert_eq!(unit.needs, vec!["build"]);
        let build = gl[0].1.iter().find(|n| n.id == "build").unwrap();
        assert_eq!(build.run[0], "echo hi");
        assert!(gl[0]
            .1
            .iter()
            .find(|n| n.id == "ship")
            .unwrap()
            .remote
            .is_some());
        let jk = from_jenkins(&d, &mut diags);
        assert_eq!(jk[0].1[1].needs, vec!["build"]);
        let mut all = gh;
        all.extend(gl);
        all.extend(jk);
        let yaml = render(&all);
        let parsed = crate::yaml::parse(&yaml).expect("valid yaml");
        assert!(parsed.value["flows"]["imported-ci"]["nodes"]["test"]["run"]
            .as_str()
            .unwrap()
            .contains("npm test"));
        let _ = std::fs::remove_dir_all(&d);
    }
}
