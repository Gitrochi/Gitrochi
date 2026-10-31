//! Rules for package managers, deploy and release tools, keys and system settings.

use super::commands::{deploy_named, hold, parse_args, resolve, Check, Effect, Resolved};
use super::paths::AbsPath;
use super::shell::Word;
use super::{Env, Rule};

pub(super) fn gpg(args: &[Word]) -> Check<Effect> {
    const KEY_WORK: &[&str] = &[
        "--export-secret-keys",
        "--export-secret-subkeys",
        "--delete-key",
        "--delete-keys",
        "--delete-secret-keys",
        "--delete-secret-and-public-key",
        "--gen-key",
        "--generate-key",
        "--full-generate-key",
        "--full-gen-key",
        "--quick-gen-key",
        "--quick-generate-key",
        "--import",
        "--edit-key",
        "--change-passphrase",
        "--passwd",
        "--sign-key",
        "--lsign-key",
        "--gen-revoke",
        "--generate-revocation",
    ];
    if args.iter().any(|a| KEY_WORK.contains(&a.text.as_str())) {
        return hold(Rule::Credentials, "`gpg` changes or exports keys");
    }
    Ok(Effect::default())
}

pub(super) fn package_manager(name: &str, args: &[Word]) -> Check<Effect> {
    let global = args
        .iter()
        .any(|a| matches!(a.text.as_str(), "-g" | "--global" | "--location=global"));
    let ops: Vec<&str> = {
        // skip values of options that take one
        let mut out = Vec::new();
        let mut i = 0;
        while let Some(a) = args.get(i) {
            let t = a.text.as_str();
            if matches!(
                t,
                "--prefix"
                    | "-C"
                    | "--dir"
                    | "--cwd"
                    | "-w"
                    | "--workspace"
                    | "--filter"
                    | "--location"
            ) {
                i += 2;
                continue;
            }
            if !t.starts_with('-') {
                out.push(t);
            }
            i += 1;
        }
        out
    };
    let sub = ops.first().copied().unwrap_or("");
    let second = ops.get(1).copied().unwrap_or("");
    match sub {
        "publish" | "unpublish" | "deprecate" | "dist-tag" | "owner" | "access" | "team" => hold(
            Rule::Deploy,
            format!("`{name} {sub}` changes a published package"),
        ),
        "npm" if name == "yarn" && second == "publish" => {
            hold(Rule::Deploy, "`yarn npm publish` publishes a package")
        }
        "login" | "logout" | "adduser" | "token" => hold(
            Rule::Credentials,
            format!("`{name} {sub}` changes registry credentials"),
        ),
        "config" if matches!(second, "set" | "delete" | "edit" | "rm") => hold(
            Rule::Credentials,
            format!("`{name} config {second}` changes the person's package settings"),
        ),
        "global" => hold(
            Rule::SystemInstall,
            format!("`{name} global` installs outside the repository"),
        ),
        "link" | "ln" if ops.len() == 1 => hold(
            Rule::SystemInstall,
            format!("`{name} link` links a package globally"),
        ),
        "install" | "i" | "add" | "remove" | "rm" | "uninstall" | "un" | "update" | "up"
        | "upgrade" | "link" | "unlink"
            if global =>
        {
            hold(
                Rule::SystemInstall,
                format!("`{name} {sub} -g` installs outside the repository"),
            )
        }
        "run" | "run-script" | "rs" => {
            if deploy_named(second) || matches!(second, "push" | "ship" | "upload" | "promote") {
                hold(
                    Rule::Deploy,
                    format!("`{name} run {second}` looks like a deploy or release"),
                )
            } else {
                Ok(Effect::default())
            }
        }
        _ if name != "npm"
            && !sub.is_empty()
            && !PACKAGE_BUILTINS.contains(&sub)
            && deploy_named(sub) =>
        {
            // `yarn deploy` runs the script of that name
            hold(
                Rule::Deploy,
                format!("`{name} {sub}` looks like a deploy or release"),
            )
        }
        _ => Ok(Effect::default()),
    }
}

const PACKAGE_BUILTINS: &[&str] = &[
    "install",
    "i",
    "add",
    "remove",
    "rm",
    "uninstall",
    "update",
    "up",
    "upgrade",
    "test",
    "t",
    "build",
    "ci",
    "start",
    "init",
    "create",
    "info",
    "list",
    "ls",
    "why",
    "outdated",
    "audit",
    "exec",
    "dlx",
    "x",
    "run",
    "link",
    "unlink",
    "pack",
    "version",
    "help",
    "config",
    "cache",
];

pub(super) fn pip(
    program: &Word,
    args: &[Word],
    env: &Env,
    cwd: Option<&AbsPath>,
) -> Check<Effect> {
    let sub = args
        .iter()
        .find(|a| !a.text.starts_with('-'))
        .map(|a| a.text.as_str())
        .unwrap_or("");
    if !matches!(sub, "install" | "uninstall") {
        return Ok(Effect::default());
    }
    let a = parse_args(
        args,
        "tr",
        &["--target", "--requirement", "--prefix", "--root"],
    );
    if let Some(target) = a
        .value_of("-t")
        .or_else(|| a.value_of("--target"))
        .or_else(|| a.value_of("--prefix"))
    {
        return Ok(Effect::writes([target.clone()]));
    }
    // a pip inside the repository (`.venv/bin/pip`) installs into that environment
    let local = program.text.contains(['/', '\\'])
        && matches!(resolve(program, cwd, env), Resolved::Path(p) if env.inside(&p));
    if local && !a.has("--user") {
        return Ok(Effect::default());
    }
    hold(
        Rule::SystemInstall,
        format!("`pip {sub}` installs outside the repository"),
    )
}

pub(super) fn cargo(args: &[Word]) -> Check<Effect> {
    let sub = args
        .iter()
        .find(|a| !a.text.starts_with('-') && !a.text.starts_with('+'))
        .map(|a| a.text.as_str())
        .unwrap_or("");
    match sub {
        "publish" | "yank" | "owner" => hold(
            Rule::Deploy,
            format!("`cargo {sub}` changes a published crate"),
        ),
        "login" | "logout" => hold(
            Rule::Credentials,
            format!("`cargo {sub}` changes registry credentials"),
        ),
        "install" | "uninstall" => {
            let a = parse_args(
                args,
                "",
                &[
                    "--root",
                    "--path",
                    "--git",
                    "--branch",
                    "--tag",
                    "--rev",
                    "--version",
                    "--registry",
                    "--index",
                    "--bin",
                    "--example",
                    "--features",
                    "--target",
                    "--target-dir",
                    "--profile",
                    "-j",
                    "--jobs",
                ],
            );
            match a.value_of("--root") {
                Some(root) => Ok(Effect::writes([root.clone()])),
                None => hold(
                    Rule::SystemInstall,
                    format!("`cargo {sub}` installs outside the repository"),
                ),
            }
        }
        _ => Ok(Effect::default()),
    }
}

pub(super) fn go(args: &[Word]) -> Check<Effect> {
    let ops: Vec<&str> = args.iter().map(|a| a.text.as_str()).collect();
    match ops.first().copied() {
        Some("install") => hold(
            Rule::SystemInstall,
            "`go install` installs outside the repository",
        ),
        Some("env") if ops.contains(&"-w") || ops.contains(&"-u") => hold(
            Rule::SystemChange,
            "`go env -w` changes the person's Go settings",
        ),
        _ => Ok(Effect::default()),
    }
}

pub(super) fn gem(args: &[Word]) -> Check<Effect> {
    match args
        .iter()
        .find(|a| !a.text.starts_with('-'))
        .map(|a| a.text.as_str())
    {
        Some("install" | "uninstall" | "update") => hold(
            Rule::SystemInstall,
            "`gem install` installs outside the repository",
        ),
        Some("push" | "yank" | "owner") => hold(Rule::Deploy, "`gem push` publishes a gem"),
        Some("signin" | "signout") => hold(
            Rule::Credentials,
            "`gem signin` changes registry credentials",
        ),
        _ => Ok(Effect::default()),
    }
}

pub(super) fn system_packages(name: &str, args: &[Word]) -> Check<Effect> {
    const CHANGES: &[&str] = &[
        "install",
        "uninstall",
        "remove",
        "reinstall",
        "upgrade",
        "update",
        "tap",
        "untap",
        "link",
        "unlink",
        "cleanup",
        "autoremove",
        "purge",
        "services",
        "pin",
        "unpin",
        "add",
        "del",
        "delete",
        "erase",
        "-S",
        "-R",
        "-U",
        "-i",
        "-e",
    ];
    match args
        .iter()
        .map(|a| a.text.as_str())
        .find(|t| !t.starts_with("--"))
    {
        Some(sub) if CHANGES.contains(&sub) || (name == "pacman" && sub.starts_with("-S")) => hold(
            Rule::SystemInstall,
            format!("`{name} {sub}` changes software outside the repository"),
        ),
        _ => Ok(Effect::read_only()),
    }
}

pub(super) fn toolchains(name: &str, args: &[Word]) -> Check<Effect> {
    let ops: Vec<&str> = args
        .iter()
        .filter(|a| !a.text.starts_with('-'))
        .map(|a| a.text.as_str())
        .collect();
    let sub = ops.first().copied().unwrap_or("");
    let reads = matches!(
        sub,
        "" | "show"
            | "which"
            | "list"
            | "ls"
            | "current"
            | "version"
            | "versions"
            | "help"
            | "doc"
            | "run"
            | "exec"
            | "where"
            | "info"
    ) || (matches!(sub, "toolchain" | "target" | "component" | "plugin")
        && ops.get(1) == Some(&"list"));
    if reads {
        return Ok(Effect::read_only());
    }
    hold(
        Rule::SystemInstall,
        format!("`{name} {sub}` changes tools outside the repository"),
    )
}

/// Deploy and release tools. None for any other program.
pub(super) fn deploy_tool(name: &str, args: &[Word]) -> Option<Check<Effect>> {
    let ops: Vec<String> = args
        .iter()
        .filter(|a| !a.text.starts_with('-'))
        .map(|a| a.text.to_lowercase())
        .collect();
    let flags: Vec<&str> = args
        .iter()
        .filter(|a| a.text.starts_with('-'))
        .map(|a| a.text.as_str())
        .collect();
    let sub = ops.first().map(String::as_str).unwrap_or("");
    let any = |list: &[&str]| ops.iter().any(|o| list.contains(&o.as_str()));
    let deploy = |what: String| Some(hold(Rule::Deploy, what));
    let credentials = |what: String| Some(hold(Rule::Credentials, what));
    let fine = || Some(Ok(Effect::default()));
    match name {
        "kubectl" | "oc" => match sub {
            "apply" | "create" | "delete" | "replace" | "patch" | "rollout" | "scale" | "set"
            | "edit" | "annotate" | "label" | "drain" | "cordon" | "uncordon" | "taint"
            | "expose" | "run" | "autoscale" => deploy(format!("`{name} {sub}` changes a cluster")),
            "exec" | "cp" | "attach" | "debug" => Some(hold(
                Rule::RemoteShell,
                format!("`{name} {sub}` works inside a cluster"),
            )),
            "config"
                if ops.get(1).is_some_and(|o| {
                    o.starts_with("use") || o.starts_with("set") || o.starts_with("delete")
                }) =>
            {
                credentials(format!("`{name} config` changes cluster credentials"))
            }
            _ => fine(),
        },
        "helm"
            if matches!(
                sub,
                "install" | "upgrade" | "uninstall" | "delete" | "rollback" | "push"
            ) =>
        {
            deploy(format!("`helm {sub}` changes a cluster"))
        }
        "terraform" | "tofu" => match sub {
            "apply" | "destroy" | "import" | "taint" | "untaint" | "state" | "workspace"
            | "force-unlock" => deploy(format!("`{name} {sub}` changes infrastructure")),
            "login" | "logout" => credentials(format!("`{name} {sub}` changes credentials")),
            _ => fine(),
        },
        "pulumi" => match sub {
            "up" | "update" | "destroy" | "refresh" | "import" | "cancel" | "stack" => {
                deploy(format!("`pulumi {sub}` changes infrastructure"))
            }
            "login" | "logout" => credentials(format!("`pulumi {sub}` changes credentials")),
            _ => fine(),
        },
        "cdk" if matches!(sub, "deploy" | "destroy" | "bootstrap") => {
            deploy(format!("`cdk {sub}` changes infrastructure"))
        }
        "sam" if matches!(sub, "deploy" | "delete" | "sync" | "publish") => {
            deploy(format!("`sam {sub}` deploys"))
        }
        "serverless" | "sls" if matches!(sub, "deploy" | "remove" | "rollback") => {
            deploy(format!("`{name} {sub}` deploys"))
        }
        "vercel" => match sub {
            "dev" | "build" | "ls" | "list" | "inspect" | "logs" | "whoami" | "help" | "pull" => {
                fine()
            }
            "login" | "logout" | "switch" => {
                credentials(format!("`vercel {sub}` changes credentials"))
            }
            _ if flags.contains(&"--version") || flags.contains(&"--help") => fine(),
            _ => deploy("`vercel` deploys".to_string()),
        },
        "netlify" => match sub {
            "login" | "logout" | "switch" => {
                credentials(format!("`netlify {sub}` changes credentials"))
            }
            s if s == "deploy"
                || s.contains("delete")
                || s.contains(":set")
                || s.contains("create") =>
            {
                deploy(format!("`netlify {s}` deploys or changes a site"))
            }
            _ => fine(),
        },
        "firebase" => match sub {
            "login" | "logout" => credentials(format!("`firebase {sub}` changes credentials")),
            _ if ops
                .iter()
                .any(|o| o.contains("deploy") || o.contains("delete") || o.contains(":set")) =>
            {
                deploy("`firebase deploy` deploys".to_string())
            }
            _ => fine(),
        },
        "fly" | "flyctl" => match sub {
            "auth" => credentials("`fly auth` changes credentials".to_string()),
            "secrets" => credentials("`fly secrets` changes secrets".to_string()),
            "deploy" | "launch" | "destroy" | "scale" | "apps" | "machine" | "machines"
            | "restart" | "volumes" | "certs" => deploy(format!("`{name} {sub}` changes an app")),
            _ => fine(),
        },
        "heroku" => match sub {
            "logs" | "info" | "apps" | "ps" | "help" | "status" | "releases" => fine(),
            "login" | "logout" | "auth" => {
                credentials(format!("`heroku {sub}` changes credentials"))
            }
            _ => deploy(format!("`heroku {sub}` changes an app")),
        },
        "wrangler" => match sub {
            "login" | "logout" => credentials(format!("`wrangler {sub}` changes credentials")),
            "secret" => credentials("`wrangler secret` changes secrets".to_string()),
            "deploy" | "publish" | "delete" | "rollback" | "versions" | "kv" | "kv:key" | "r2"
            | "d1" => deploy(format!("`wrangler {sub}` deploys or changes stored data")),
            _ => fine(),
        },
        "railway" => match sub {
            "login" | "logout" => credentials(format!("`railway {sub}` changes credentials")),
            "up" | "deploy" | "down" | "redeploy" | "delete" => {
                deploy(format!("`railway {sub}` deploys"))
            }
            _ => fine(),
        },
        "eb" if matches!(
            sub,
            "deploy" | "terminate" | "create" | "swap" | "restore" | "scale" | "setenv"
        ) =>
        {
            deploy(format!("`eb {sub}` changes an environment"))
        }
        "gcloud" | "az" | "doctl" => {
            if any(&["auth", "login", "logout", "account"]) {
                credentials(format!("`{name}` changes credentials"))
            } else if any(&["ssh", "scp"]) {
                Some(hold(
                    Rule::RemoteShell,
                    format!("`{name} ssh` works on another machine"),
                ))
            } else if any(&[
                "deploy",
                "delete",
                "create",
                "update",
                "apply",
                "set-iam-policy",
                "add-iam-policy-binding",
                "remove-iam-policy-binding",
                "up",
                "set",
                "swap",
                "restart",
                "stop",
                "start",
                "rollback",
                "scale",
            ]) {
                deploy(format!("`{name}` changes cloud resources"))
            } else {
                fine()
            }
        }
        "aws" => {
            let op = ops.get(1).map(String::as_str).unwrap_or("");
            if sub == "configure" || (sub == "sso" && op == "login") {
                return credentials("`aws configure` changes credentials".to_string());
            }
            if sub == "s3" {
                return match op {
                    "rm" | "rb" => Some(hold(
                        Rule::RemoteDelete,
                        "`aws s3 rm` deletes stored objects",
                    )),
                    "cp" | "mv" | "sync" if ops.last().is_some_and(|o| o.starts_with("s3://")) => {
                        deploy("`aws s3 cp` uploads to storage".to_string())
                    }
                    "cp" | "mv" | "sync" => Some(Ok(Effect::writes(
                        args.iter().rfind(|a| !a.text.starts_with('-')).cloned(),
                    ))),
                    "mb" => deploy("`aws s3 mb` creates a bucket".to_string()),
                    _ => fine(),
                };
            }
            const VERBS: &[&str] = &[
                "create-",
                "delete-",
                "put-",
                "update-",
                "terminate-",
                "run-",
                "start-",
                "stop-",
                "reboot-",
                "deploy",
                "invoke",
                "send-",
                "attach-",
                "detach-",
                "modify-",
                "register-",
                "deregister-",
                "associate-",
                "disassociate-",
                "import-",
                "restore-",
                "tag-",
                "untag-",
            ];
            if VERBS.iter().any(|v| op.starts_with(v)) {
                deploy(format!("`aws {sub} {op}` changes cloud resources"))
            } else {
                fine()
            }
        }
        "ansible" | "ansible-playbook" => deploy(format!("`{name}` changes other machines")),
        "cap" if any(&["deploy"]) => deploy("`cap deploy` deploys".to_string()),
        "fastlane" => {
            if ops.iter().any(|o| {
                deploy_named(o)
                    || matches!(
                        o.as_str(),
                        "beta" | "appstore" | "submit" | "testflight" | "production" | "upload"
                    )
            }) {
                deploy("`fastlane` uploads a build".to_string())
            } else {
                fine()
            }
        }
        "eas" if matches!(sub, "submit" | "update") => {
            deploy(format!("`eas {sub}` publishes an app"))
        }
        "expo" if sub == "publish" => deploy("`expo publish` publishes an app".to_string()),
        "vsce" | "ovsx" => match sub {
            "publish" | "unpublish" => deploy(format!("`{name} {sub}` publishes an extension")),
            "login" | "logout" => credentials(format!("`{name} {sub}` changes credentials")),
            _ => fine(),
        },
        "twine" if matches!(sub, "upload" | "register") => {
            deploy("`twine upload` publishes a package".to_string())
        }
        "poetry" => match sub {
            "publish" => deploy("`poetry publish` publishes a package".to_string()),
            "config"
                if ops
                    .iter()
                    .any(|o| o.starts_with("pypi-token") || o.starts_with("http-basic")) =>
            {
                credentials("`poetry config` stores registry credentials".to_string())
            }
            _ => fine(),
        },
        "flit" | "hatch" if sub == "publish" => {
            deploy(format!("`{name} publish` publishes a package"))
        }
        "uv" => match (sub, ops.get(1).map(String::as_str).unwrap_or("")) {
            ("publish", _) => deploy("`uv publish` publishes a package".to_string()),
            ("tool" | "python", "install" | "uninstall" | "upgrade") => Some(hold(
                Rule::SystemInstall,
                format!("`uv {sub} install` installs outside the repository"),
            )),
            _ => fine(),
        },
        "dotnet" => match (sub, ops.get(1).map(String::as_str).unwrap_or("")) {
            ("nuget", "push" | "delete") => {
                deploy("`dotnet nuget push` publishes a package".to_string())
            }
            ("tool", "install" | "update" | "uninstall")
                if flags.iter().any(|f| matches!(*f, "-g" | "--global")) =>
            {
                Some(hold(
                    Rule::SystemInstall,
                    "`dotnet tool install -g` installs outside the repository",
                ))
            }
            _ => fine(),
        },
        "nuget" if matches!(sub, "push" | "delete") => {
            deploy(format!("`nuget {sub}` changes a published package"))
        }
        "mvn" | "mvnw"
            if ops
                .iter()
                .any(|o| o == "deploy" || o.starts_with("release:")) =>
        {
            deploy("`mvn deploy` publishes artifacts".to_string())
        }
        "gradle" | "gradlew"
            if ops.iter().any(|o| {
                o.contains("publish") || o.contains("release") || o.contains("deploy")
            }) =>
        {
            deploy("the gradle task publishes or releases".to_string())
        }
        "xcrun" => {
            let joined = ops.join(" ");
            if joined.starts_with("notarytool submit")
                || flags.iter().any(|f| f.starts_with("--upload"))
            {
                deploy("`xcrun` uploads a build".to_string())
            } else {
                fine()
            }
        }
        _ => None,
    }
}

/// System settings and services. None for any other program.
pub(super) fn system_tool(name: &str, args: &[Word]) -> Option<Check<Effect>> {
    let first = args.first().map(|a| a.text.as_str()).unwrap_or("");
    let has = |f: &str| args.iter().any(|a| a.text == f);
    let change = || {
        Some(hold(
            Rule::SystemChange,
            format!("`{name}` changes system settings or services"),
        ))
    };
    let reads = || Some(Ok(Effect::read_only()));
    match name {
        "shutdown" | "reboot" | "halt" | "poweroff" | "csrutil" | "spctl" | "nvram" | "tccutil"
        | "softwareupdate" | "kextload" | "kextunload" | "chsh" | "passwd" | "dscl" | "useradd"
        | "userdel" | "usermod" | "groupadd" | "groupdel" | "iptables" | "ip6tables" | "ufw"
        | "pfctl" | "killall" | "pkill" | "fdisk" | "parted" | "netsh" | "bcdedit" | "wmic"
        | "taskkill" | "setx" | "mkfs" => change(),
        _ if name.starts_with("mkfs.") => change(),
        "launchctl" => {
            if matches!(first, "list" | "print" | "blame" | "help") {
                reads()
            } else {
                change()
            }
        }
        "systemctl" | "service" => {
            if matches!(
                first,
                "status"
                    | "list-units"
                    | "list-unit-files"
                    | "show"
                    | "is-active"
                    | "is-enabled"
                    | "cat"
            ) {
                reads()
            } else {
                change()
            }
        }
        "defaults" => {
            if matches!(first, "read" | "read-type" | "domains" | "find" | "export") {
                reads()
            } else {
                change()
            }
        }
        "networksetup" => {
            if first.starts_with("-get") || first.starts_with("-list") {
                reads()
            } else {
                change()
            }
        }
        "scutil" => {
            if has("--set") {
                change()
            } else {
                reads()
            }
        }
        "pmset" => {
            if first == "-g" {
                reads()
            } else {
                change()
            }
        }
        "diskutil" => {
            if matches!(first, "list" | "info" | "activity") {
                reads()
            } else {
                change()
            }
        }
        "mount" | "umount" => {
            if args.is_empty() {
                reads()
            } else {
                change()
            }
        }
        "crontab" => {
            if has("-l") {
                reads()
            } else {
                change()
            }
        }
        "sysctl" => {
            if has("-w") || args.iter().any(|a| a.text.contains('=')) {
                change()
            } else {
                reads()
            }
        }
        "reg" => {
            if first.eq_ignore_ascii_case("query") {
                reads()
            } else {
                change()
            }
        }
        "sc" => {
            if first.eq_ignore_ascii_case("query") || first.eq_ignore_ascii_case("qc") {
                reads()
            } else {
                change()
            }
        }
        "schtasks" => {
            if first.eq_ignore_ascii_case("/query") {
                reads()
            } else {
                change()
            }
        }
        _ => None,
    }
}
