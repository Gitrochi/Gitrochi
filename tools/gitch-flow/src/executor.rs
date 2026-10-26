//! Executors: where a node's shell command runs. `local` (default) or `docker:<image>`.
//! Docker runs one labelled `--rm` container per node. The repository and the run folder are mounted at **the same path**,
//! so report paths and `GITCH_FLOW_OUT` are the same inside and out; environment values pass by name (`-e NAME`), so secrets never appear on a command line.
//! With the same image as CI, local equals CI. A Windows host mounts `C:\a` as `/c/a` (see the validation record).

use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Executor {
    Local,
    Docker { image: String },
}

impl Executor {
    pub fn parse(s: &str) -> Result<Executor, String> {
        let t = s.trim();
        if t.is_empty() || t == "local" {
            return Ok(Executor::Local);
        }
        if let Some(img) = t.strip_prefix("docker:") {
            let img = img.trim();
            if img.is_empty() || img.contains(char::is_whitespace) || img.starts_with('-') {
                return Err(crate::util::tr(
                    "docker: 뒤에 이미지 이름이 필요합니다(예: docker:node:22).",
                    "docker: needs an image name (for example docker:node:22).",
                ));
            }
            return Ok(Executor::Docker {
                image: img.to_string(),
            });
        }
        Err(crate::util::tr(
            &format!("executor '{t}' 대신 local 또는 docker:<이미지>."),
            &format!("use local or docker:<image> instead of executor '{t}'."),
        ))
    }
    pub fn as_str(&self) -> String {
        match self {
            Executor::Local => "local".into(),
            Executor::Docker { image } => format!("docker:{image}"),
        }
    }
    pub fn is_docker(&self) -> bool {
        matches!(self, Executor::Docker { .. })
    }
}

/// The path inside the container: the same path on Unix, `C:\a\b` → `/c/a/b` on Windows.
pub fn container_path(host: &Path) -> String {
    let s = host.to_string_lossy().replace('\\', "/");
    let b = s.as_bytes();
    if b.len() >= 2 && b[1] == b':' && b[0].is_ascii_alphabetic() {
        let rest = s[2..].trim_start_matches('/');
        return format!("/{}/{rest}", (b[0] as char).to_ascii_lowercase());
    }
    s
}

/// Host folders to mount; of nested ones only the outermost.
pub fn mounts(dirs: &[PathBuf]) -> Vec<PathBuf> {
    let mut list: Vec<PathBuf> = dirs
        .iter()
        .filter(|d| !d.as_os_str().is_empty())
        .cloned()
        .collect();
    list.sort_by_key(|d| d.as_os_str().len());
    let mut out: Vec<PathBuf> = Vec::new();
    for d in list {
        if !out.iter().any(|o| d.starts_with(o)) {
            out.push(d);
        }
    }
    out
}

/// Rewrites host paths in text to container paths (only matters on a Windows host).
pub fn rewrite_paths(text: &str, mounts: &[PathBuf]) -> String {
    let mut s = text.to_string();
    for m in mounts {
        let host = m.to_string_lossy().to_string();
        if !host.contains(':') {
            continue;
        }
        let inside = container_path(m);
        for variant in [host.clone(), host.replace('\\', "/")] {
            // Backslashes in the rest of the path become `/` too.
            while let Some(i) = s.find(&variant) {
                let tail_start = i + variant.len();
                let tail_end = s[tail_start..]
                    .find(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == ';')
                    .map(|j| tail_start + j)
                    .unwrap_or(s.len());
                let tail = s[tail_start..tail_end].replace('\\', "/");
                s = format!("{}{inside}{tail}{}", &s[..i], &s[tail_end..]);
            }
        }
    }
    s
}

/// Host-only environment names that are not passed into containers.
fn host_only(k: &str) -> bool {
    matches!(
        k,
        "PATH"
            | "HOME"
            | "USER"
            | "LOGNAME"
            | "SHELL"
            | "PWD"
            | "OLDPWD"
            | "SHLVL"
            | "TMPDIR"
            | "TMP"
            | "TEMP"
            | "PATHEXT"
            | "SYSTEMROOT"
            | "COMSPEC"
            | "APPDATA"
            | "LOCALAPPDATA"
            | "USERPROFILE"
            | "PROGRAMDATA"
            | "SSH_AUTH_SOCK"
            | "DISPLAY"
            | "TERM_PROGRAM"
            | "TERM_PROGRAM_VERSION"
            | "TERM_SESSION_ID"
            | "_"
    ) || k.starts_with("DOCKER_")
        || k.starts_with("XPC_")
        || k.starts_with("__CF")
        || k.starts_with("MSYS")
        || k.starts_with("GITCH_FLOW_INTERNAL")
}

/// `docker run` arguments. `forward` names the environment variables to pass in (docker reads their values from its own environment).
pub struct RunArgs<'a> {
    pub image: &'a str,
    pub name: &'a str,
    pub run_id: &'a str,
    pub node: &'a str,
    pub repo_id: &'a str,
    pub mounts: &'a [PathBuf],
    pub workdir: &'a Path,
    pub forward: Vec<String>,
    /// The run's own network, shared with the service containers.
    pub network: Option<String>,
    pub host_gateway: bool,
    pub pull: &'a str,
    pub command: Vec<String>,
}

pub fn docker_args(a: &RunArgs) -> Vec<String> {
    let mut v: Vec<String> = vec![
        "run".into(),
        "--rm".into(),
        "-i".into(),
        "--name".into(),
        a.name.into(),
    ];
    for l in [
        format!("gitch.flow.run={}", a.run_id),
        format!("gitch.flow.node={}", a.node),
        format!("gitch.repo={}", a.repo_id),
    ] {
        v.push("--label".into());
        v.push(l);
    }
    v.push(format!("--pull={}", a.pull));
    for m in a.mounts {
        v.push("-v".into());
        v.push(format!("{}:{}", m.to_string_lossy(), container_path(m)));
    }
    v.push("-w".into());
    v.push(container_path(a.workdir));
    if let Some(n) = &a.network {
        v.push("--network".into());
        v.push(n.clone());
    }
    if a.host_gateway {
        v.push("--add-host".into());
        v.push("host.docker.internal:host-gateway".into());
    }
    #[cfg(target_os = "linux")]
    {
        // Run as the host user so files written to the repository are not owned by root.
        let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
        v.push("--user".into());
        v.push(format!("{uid}:{gid}"));
        v.push("-e".into());
        v.push("HOME=/tmp".into());
    }
    let mut names: Vec<&String> = a.forward.iter().filter(|k| !host_only(k)).collect();
    names.sort();
    names.dedup();
    for k in names {
        v.push("-e".into());
        v.push(k.clone());
    }
    v.push(a.image.into());
    v.extend(a.command.iter().cloned());
    v
}

/// The command that runs a shell script inside the container. The script goes in through an environment variable to avoid quoting problems,
/// and it falls back to sh when the image has no bash.
pub fn shell_command(shell: &str, explicit: bool) -> Vec<String> {
    match shell {
        "pwsh" | "powershell" => vec!["pwsh".into(), "-NoProfile".into(), "-Command".into(), "$env:GITCH_FLOW_SCRIPT | Invoke-Expression".into()],
        "sh" => vec!["sh".into(), "-c".into(), "eval \"$GITCH_FLOW_SCRIPT\"".into()],
        "bash" if explicit => vec!["bash".into(), "-c".into(), "eval \"$GITCH_FLOW_SCRIPT\"".into()],
        _ => vec![
            "sh".into(),
            "-c".into(),
            "if command -v bash >/dev/null 2>&1; then exec bash -c 'eval \"$GITCH_FLOW_SCRIPT\"'; else eval \"$GITCH_FLOW_SCRIPT\"; fi".into(),
        ],
    }
}

/// Service addresses as seen from a container: network alias and container port for docker services, host.docker.internal for host processes.
pub fn services_inside(services: &Value) -> (Value, bool) {
    let mut gateway = false;
    let Some(o) = services.as_object() else {
        return (services.clone(), false);
    };
    let mut out = serde_json::Map::new();
    for (name, info) in o {
        let mut i = info.clone();
        if let (Some(alias), Some(ports)) = (info["alias"].as_str(), info["ports"].as_object()) {
            if let Some(p) = ports.keys().next() {
                let port: Value = p.parse::<u64>().map(Value::from).unwrap_or(json!(p));
                i["host"] = json!(alias);
                i["port"] = port.clone();
                i["url"] = json!(format!("http://{alias}:{}", crate::expr::to_text(&port)));
            } else {
                i["host"] = json!(alias);
            }
        } else if info["host"] == "127.0.0.1" {
            gateway = true;
            i["host"] = json!("host.docker.internal");
            if let Some(port) = info["port"].as_u64() {
                i["url"] = json!(format!("http://host.docker.internal:{port}"));
            }
        }
        out.insert(name.clone(), i);
    }
    (Value::Object(out), gateway)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_executors() {
        assert_eq!(Executor::parse("local").unwrap(), Executor::Local);
        assert_eq!(
            Executor::parse("docker:node:22-bookworm").unwrap(),
            Executor::Docker {
                image: "node:22-bookworm".into()
            }
        );
        assert!(Executor::parse("docker:").is_err());
        assert!(Executor::parse("docker:--privileged").is_err());
        assert!(Executor::parse("ssh:host").is_err());
    }

    #[test]
    fn windows_paths_map_to_drive_folders() {
        assert_eq!(
            container_path(Path::new("C:\\Users\\me\\repo")),
            "/c/Users/me/repo"
        );
        assert_eq!(container_path(Path::new("/home/me/repo")), "/home/me/repo");
        let m = vec![PathBuf::from("C:\\Users\\me\\repo")];
        assert_eq!(
            rewrite_paths(
                "cat C:\\Users\\me\\repo\\out\\a.txt && echo C:/Users/me/repo/x",
                &m
            ),
            "cat /c/Users/me/repo/out/a.txt && echo /c/Users/me/repo/x"
        );
        assert_eq!(
            rewrite_paths("/home/me/repo/x", &[PathBuf::from("/home/me/repo")]),
            "/home/me/repo/x"
        );
    }

    #[test]
    fn nested_mounts_collapse() {
        let m = mounts(&[
            PathBuf::from("/r/.git/gitch"),
            PathBuf::from("/r"),
            PathBuf::from("/x"),
        ]);
        assert_eq!(m, vec![PathBuf::from("/r"), PathBuf::from("/x")]);
    }

    #[test]
    fn docker_args_pass_env_by_name_only() {
        let mounts = vec![PathBuf::from("/r")];
        let a = RunArgs {
            image: "node:22",
            name: "gitch-flow-run1-unit-1",
            run_id: "run1",
            node: "unit",
            repo_id: "abc",
            mounts: &mounts,
            workdir: Path::new("/r/app"),
            forward: vec![
                "API_TOKEN".into(),
                "PATH".into(),
                "CI".into(),
                "DOCKER_HOST".into(),
            ],
            network: Some("gitch-flow-run1".into()),
            host_gateway: false,
            pull: "missing",
            command: vec!["sh".into(), "-c".into(), "x".into()],
        };
        let v = docker_args(&a);
        let joined = v.join(" ");
        assert!(joined.contains("-v /r:/r -w /r/app"));
        assert!(joined.contains("--label gitch.flow.run=run1"));
        assert!(joined.contains("-e API_TOKEN"));
        assert!(joined.contains("-e CI"));
        assert!(!joined.contains("-e PATH"));
        assert!(!joined.contains("DOCKER_HOST"));
        assert!(joined.contains("--network gitch-flow-run1"));
        assert!(joined.ends_with("node:22 sh -c x"));
    }

    #[test]
    fn services_seen_from_a_container() {
        let s = json!({"db": {"host": "127.0.0.1", "port": 55001, "alias": "db", "ports": {"5432": 55001}},
                        "api": {"host": "127.0.0.1", "port": 4100, "url": "http://127.0.0.1:4100"}});
        let (v, gw) = services_inside(&s);
        assert_eq!(v["db"]["host"], "db");
        assert_eq!(v["db"]["port"], 5432);
        assert_eq!(v["api"]["url"], "http://host.docker.internal:4100");
        assert!(gw);
    }
}
