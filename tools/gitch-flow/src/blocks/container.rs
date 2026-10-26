//! Docker 블록: `docker.run`(일회성 컨테이너) · `docker.build`(태그 = git sha) · `docker.push`(외부 동작).
//! docker CLI 를 셸 없이 인자 배열로 부르고, 만든 컨테이너 · 이미지에는 실행 라벨을 붙인다.
//! 환경 값과 빌드 인자는 이름만 넘겨(`-e NAME` · `--build-arg NAME`) 비밀값이 명령줄에 보이지 않는다.

use super::{exit_verdict, observe_outcome, schema, Block, Meta, NodeCx, NodeResult};
use crate::process::ProcSpec;
use crate::util::tr;
use crate::verify::{self, Outcome, Verdict};
use serde_json::{json, Value};

pub struct Run;
pub struct Build;
pub struct Push;

fn str_map(v: Option<&Value>) -> Vec<(String, String)> {
    v.and_then(|x| x.as_object())
        .map(|o| {
            o.iter()
                .map(|(k, x)| (k.clone(), crate::expr::to_text(x)))
                .collect()
        })
        .unwrap_or_default()
}

fn docker_spec(cx: &NodeCx, args: Vec<String>, env: Vec<(String, String)>) -> ProcSpec {
    let mut e = cx.env.clone();
    e.extend(env);
    ProcSpec {
        program: crate::docker::bin(),
        args,
        cwd: cx.cwd.clone(),
        env: e,
        clear_env: true,
        timeout_ms: cx.timeout_ms,
        settle_ms: 5000,
    }
}

/// `docker image inspect` 의 한 값(형식 문자열). 실패하면 None.
fn inspect(cx: &mut NodeCx, image: &str, format: &str) -> Option<String> {
    let spec = docker_spec(
        cx,
        vec![
            "image".into(),
            "inspect".into(),
            "--format".into(),
            format.into(),
            image.into(),
        ],
        vec![],
    );
    let c = cx.run_proc(&ProcSpec {
        timeout_ms: Some(30_000),
        ..spec
    });
    if c.outcome.exit_code == Some(0) {
        let t = c.stdout.trim().to_string();
        (!t.is_empty()).then_some(t)
    } else {
        None
    }
}

/// docker CLI 오류 글 → 실패 코드. "Error response from daemon" 은 모든 데몬 오류의 머리말이라 닿지 못함이 아니다.
pub fn docker_error_code(text: &str) -> &'static str {
    let t = text.to_ascii_lowercase();
    if t.contains("cannot connect to the docker daemon")
        || t.contains("is the docker daemon running")
    {
        "DOCKER-01"
    } else if t.contains("pull access denied")
        || t.contains("manifest unknown")
        || t.contains("manifest for")
        || t.contains("repository does not exist")
        || t.contains("unable to find image")
    {
        "DOCKER-02"
    } else {
        "DOCKER-03"
    }
}

fn image_verdict(id: Option<&str>, code: &'static str) -> Verdict {
    Verdict::new(
        "O1",
        tr("이미지", "image"),
        id.unwrap_or("-").to_string(),
        tr("있음", "present"),
        if id.is_some() {
            Outcome::Pass
        } else {
            Outcome::Fail
        },
        Some(code),
    )
}

const fn docker_meta(
    id: &'static str,
    title: (&'static str, &'static str),
    outward: bool,
    inputs: fn() -> Value,
    caps: &'static [&'static str],
    est: u64,
) -> Meta {
    Meta {
        id,
        version: "1.0.0",
        title,
        category: "docker",
        capabilities: caps,
        env_classes: &[],
        destructive: false,
        outward,
        codes: &[
            "DOCKER-01",
            "DOCKER-02",
            "DOCKER-03",
            "EXEC-01",
            "EXEC-02",
            "EXEC-05",
            "VERIFY-04",
        ],
        inputs,
        selects_files: false,
        estimate_ms: est,
    }
}

// ---------- docker.run ----------

fn run_inputs() -> Value {
    schema(
        json!({
            "image": {"type": "string"},
            "command": {"description": "Array = exec form; string = run with sh -c inside the container.", "oneOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]},
            "entrypoint": {"type": "string"},
            "env": {"type": "object", "description": "Values are passed by name, never on the command line."},
            "mountRepo": {"type": "boolean", "default": true, "description": "Mount the repository at the same path and work in the node's folder."},
            "workdir": {"type": "string"},
            "network": {"enum": ["run", "none", "bridge", "host"], "default": "run", "description": "run = the flow's network when services are up, else the default bridge."},
            "pull": {"enum": ["missing", "always", "never"], "default": "missing"},
            "user": {"type": "string"},
        }),
        &["image"],
    )
}

static RUN_META: Meta = docker_meta(
    "docker.run",
    ("Docker 컨테이너 실행", "Run a Docker container"),
    false,
    run_inputs,
    &["docker", "process"],
    60_000,
);

impl Block for Run {
    fn meta(&self) -> &Meta {
        &RUN_META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let mut e = Vec::new();
        match with.get("image").and_then(|i| i.as_str()) {
            Some(i) if !i.trim().is_empty() && !i.starts_with('-') => {}
            _ => e.push(tr("image 가 필요합니다.", "image is required.")),
        }
        if let Some(n) = with.get("network").and_then(|n| n.as_str()) {
            if !["run", "none", "bridge", "host"].contains(&n) {
                e.push(tr(
                    "network 는 run · none · bridge · host 중 하나입니다.",
                    "network is one of run, none, bridge, host.",
                ));
            }
        }
        e
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let image = cx.input_str("image").unwrap_or_default();
        let name = format!(
            "gitch-flow-{}-{}",
            crate::store::safe(&cx.run_id),
            crate::store::safe(&cx.id)
        )
        .to_ascii_lowercase();
        let mount = cx
            .with
            .get("mountRepo")
            .and_then(|m| m.as_bool())
            .unwrap_or(true);
        let common = crate::git::common_dir(&cx.root).unwrap_or_default();
        let run_dir = cx.run_dir.clone();
        let mounts = if mount {
            crate::executor::mounts(&[cx.root.clone(), run_dir, common])
        } else {
            Vec::new()
        };
        let env = str_map(cx.with.get("env"));
        for (k, v) in &env {
            if crate::secret::looks_secret(k) {
                cx.masker.add_secret(k, v);
            }
        }
        let network = match cx.input_str("network").as_deref() {
            Some("none") => Some("none".to_string()),
            Some("bridge") => Some("bridge".to_string()),
            Some("host") => Some("host".to_string()),
            _ => cx.services.as_object().and_then(|o| {
                o.values()
                    .find_map(|v| v["network"].as_str().map(|s| s.to_string()))
            }),
        };
        let command: Vec<String> = match cx.with.get("command") {
            Some(Value::Array(a)) => a.iter().map(crate::expr::to_text).collect(),
            Some(Value::String(s)) if !s.trim().is_empty() => {
                vec!["sh".into(), "-c".into(), s.clone()]
            }
            _ => Vec::new(),
        };
        let workdir = cx
            .input_str("workdir")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| cx.cwd.clone());
        let mut args = crate::executor::docker_args(&crate::executor::RunArgs {
            image: &image,
            name: &name,
            run_id: &cx.run_id,
            node: &cx.id,
            repo_id: &crate::trust::repo_id(&cx.root),
            mounts: &mounts,
            workdir: &workdir,
            forward: env.iter().map(|(k, _)| k.clone()).collect(),
            network,
            // 호스트 프로세스 서비스(별칭 없음)에 닿게.
            host_gateway: cx
                .services
                .as_object()
                .map(|o| o.values().any(|v| v["alias"].is_null()))
                .unwrap_or(false),
            pull: match cx.input_str("pull").as_deref() {
                Some("always") => "always",
                Some("never") => "never",
                _ => "missing",
            },
            command,
        });
        // 이미지 바로 앞에 넣을 선택 인자.
        let at = args.iter().position(|a| a == &image).unwrap_or(args.len());
        let mut extra = Vec::new();
        if let Some(ep) = cx.input_str("entrypoint") {
            extra.extend(["--entrypoint".to_string(), ep]);
        }
        if let Some(u) = cx.input_str("user") {
            extra.extend(["--user".to_string(), u]);
        }
        for (i, a) in extra.into_iter().enumerate() {
            args.insert(at + i, a);
        }
        r.observe("image", json!(image));
        r.observe("container", json!(name));
        let c = cx.run_proc(&docker_spec(cx, args, env));
        if c.outcome.cancelled || c.outcome.timed_out || c.outcome.hung {
            crate::docker::remove_container(&name);
        }
        observe_outcome(&mut r, &c);
        let tail = c.tail.join("\n");
        // docker 자체의 실패(125: 데몬 · 이미지 · 인자)는 명령 실패와 구분한다.
        if c.outcome.exit_code == Some(125) {
            let code = docker_error_code(&tail);
            r.verdicts.push(Verdict::new(
                "E1",
                tr("컨테이너 실행", "container run"),
                "exit 125".into(),
                tr("컨테이너가 뜸", "container starts"),
                Outcome::Fail,
                Some(code),
            ));
            return r;
        }
        let allowed = cx.expect.exit.clone().unwrap_or_else(|| vec![0]);
        r.verdicts.push(exit_verdict(&c, &allowed));
        if let Some(p) = cx.expect.output.clone() {
            r.verdicts
                .push(verify::output(&format!("{}\n{tail}", c.stdout), &p));
        }
        r
    }
}

// ---------- docker.build ----------

fn build_inputs() -> Value {
    schema(
        json!({
            "context": {"type": "string", "default": "."},
            "file": {"type": "string", "description": "Dockerfile path (default: <context>/Dockerfile)."},
            "tag": {"type": "string", "description": "Default <project>:<short git sha>."},
            "tags": {"type": "array", "items": {"type": "string"}},
            "target": {"type": "string"},
            "args": {"type": "object", "description": "Build arguments, passed by name (never on the command line). A null value takes the value from the node environment, for example a secret mapped with secrets:."},
            "platform": {"type": "string"},
            "pull": {"type": "boolean", "default": false},
            "noCache": {"type": "boolean", "default": false},
            "labels": {"type": "object"},
        }),
        &[],
    )
}

static BUILD_META: Meta = docker_meta(
    "docker.build",
    ("Docker 이미지 빌드", "Build a Docker image"),
    false,
    build_inputs,
    &["docker", "process"],
    180_000,
);

/// 기본 태그: 프로젝트 이름(없으면 폴더 이름)을 docker 규칙에 맞게 + 짧은 sha.
pub fn default_tag(project: Option<&str>, root: &std::path::Path, sha: &str) -> String {
    let base = project
        .map(|s| s.to_string())
        .or_else(|| root.file_name().map(|n| n.to_string_lossy().to_string()))
        .unwrap_or_else(|| "app".into());
    let mut name: String = base
        .to_ascii_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '-'
            }
        })
        .collect();
    name = name
        .trim_matches(|c| c == '-' || c == '.' || c == '_')
        .to_string();
    if name.is_empty() {
        name = "app".into();
    }
    let short: String = sha.chars().take(12).collect();
    format!("{name}:{}", if short.is_empty() { "dev" } else { &short })
}

impl Block for Build {
    fn meta(&self) -> &Meta {
        &BUILD_META
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let tag = cx
            .input_str("tag")
            .unwrap_or_else(|| default_tag(cx.project.as_deref(), &cx.root, &cx.git_sha));
        let mut args: Vec<String> = vec!["build".into()];
        let mut labels = vec![
            format!("gitch.flow.run={}", cx.run_id),
            format!("gitch.flow.node={}", cx.id),
            format!("org.opencontainers.image.revision={}", cx.git_sha),
        ];
        labels.extend(
            str_map(cx.with.get("labels"))
                .into_iter()
                .map(|(k, v)| format!("{k}={v}")),
        );
        for l in labels {
            args.extend(["--label".to_string(), l]);
        }
        args.extend(["-t".to_string(), tag.clone()]);
        for t in cx
            .with
            .get("tags")
            .and_then(|t| t.as_array())
            .cloned()
            .unwrap_or_default()
        {
            args.extend(["-t".to_string(), crate::expr::to_text(&t)]);
        }
        if let Some(f) = cx.input_str("file") {
            args.extend(["-f".to_string(), f]);
        }
        if let Some(t) = cx.input_str("target") {
            args.extend(["--target".to_string(), t]);
        }
        if let Some(p) = cx.input_str("platform") {
            args.extend(["--platform".to_string(), p]);
        }
        if cx
            .with
            .get("pull")
            .and_then(|p| p.as_bool())
            .unwrap_or(false)
        {
            args.push("--pull".into());
        }
        if cx
            .with
            .get("noCache")
            .and_then(|p| p.as_bool())
            .unwrap_or(false)
        {
            args.push("--no-cache".into());
        }
        // 값이 null 인 빌드 인자는 노드 환경(secrets: 로 넘긴 값 등)에서 그대로 읽힌다.
        let mut build_args = Vec::new();
        for (k, v) in cx
            .with
            .get("args")
            .and_then(|a| a.as_object())
            .cloned()
            .unwrap_or_default()
        {
            args.extend(["--build-arg".to_string(), k.clone()]);
            if !v.is_null() {
                let text = crate::expr::to_text(&v);
                if crate::secret::looks_secret(&k) {
                    cx.masker.add_secret(&k, &text);
                }
                build_args.push((k, text));
            }
        }
        args.push(cx.input_str("context").unwrap_or_else(|| ".".into()));
        let mut env = build_args;
        env.push(("DOCKER_BUILDKIT".into(), "1".into()));
        r.observe("tag", json!(tag));
        let c = cx.run_proc(&docker_spec(cx, args, env));
        observe_outcome(&mut r, &c);
        let mut v = exit_verdict(&c, &[0]);
        if v.result != Outcome::Pass {
            let code = docker_error_code(&c.tail.join("\n"));
            if code != "DOCKER-03" {
                v.code = Some(code);
            }
        }
        let ok = v.result == Outcome::Pass;
        r.verdicts.push(v);
        if ok {
            let id = inspect(cx, &tag, "{{.Id}}");
            r.verdicts.push(image_verdict(id.as_deref(), "DOCKER-03"));
            if let Some(id) = id {
                r.observe("id", json!(id));
                r.outputs.insert("id".into(), json!(id));
            }
            r.outputs.insert("image".into(), json!(tag));
        }
        r
    }
}

// ---------- docker.push ----------

fn push_inputs() -> Value {
    schema(
        json!({"image": {"type": "string", "description": "Tag to push, usually ${{ nodes.build.outputs.image }}."}}),
        &["image"],
    )
}

static PUSH_META: Meta = docker_meta(
    "docker.push",
    ("Docker 이미지 올리기", "Push a Docker image"),
    true,
    push_inputs,
    &["docker", "network", "outward"],
    120_000,
);

impl Block for Push {
    fn meta(&self) -> &Meta {
        &PUSH_META
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        match with.get("image").and_then(|i| i.as_str()) {
            Some(i) if !i.trim().is_empty() && !i.starts_with('-') => Vec::new(),
            _ => vec![tr("image 가 필요합니다.", "image is required.")],
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let image = cx.input_str("image").unwrap_or_default();
        let c = cx.run_proc(&docker_spec(cx, vec!["push".into(), image.clone()], vec![]));
        observe_outcome(&mut r, &c);
        let mut v = exit_verdict(&c, &[0]);
        if v.result != Outcome::Pass && c.tail.join("\n").contains("denied") {
            v.code = Some("CONN-02");
        }
        let ok = v.result == Outcome::Pass;
        r.verdicts.push(v);
        if ok {
            let digest = inspect(cx, &image, "{{range .RepoDigests}}{{println .}}{{end}}")
                .and_then(|d| d.lines().next().map(|s| s.trim().to_string()));
            r.verdicts
                .push(image_verdict(digest.as_deref(), "DOCKER-03"));
            if let Some(d) = digest {
                r.outputs.insert("digest".into(), json!(d));
            }
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_errors_are_told_apart() {
        assert_eq!(
            docker_error_code("docker: Error response from daemon: invalid mount config"),
            "DOCKER-03"
        );
        assert_eq!(docker_error_code("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"), "DOCKER-01");
        assert_eq!(docker_error_code("Unable to find image 'nope:1' locally\ndocker: Error response from daemon: pull access denied for nope"), "DOCKER-02");
    }

    #[test]
    fn default_tags_follow_docker_rules() {
        let root = std::path::Path::new("/w/My App");
        assert_eq!(
            default_tag(None, root, "0123456789abcdef"),
            "my-app:0123456789ab"
        );
        assert_eq!(default_tag(Some("Shop_UI"), root, ""), "shop_ui:dev");
        assert_eq!(default_tag(Some("***"), root, "abc"), "app:abc");
    }
}
