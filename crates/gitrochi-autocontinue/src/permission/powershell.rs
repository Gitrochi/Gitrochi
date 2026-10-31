//! PowerShell cmdlets and their aliases, for the PowerShell tool.

use super::commands::{hold, resolve, Check, Effect, Resolved, State, Target};
use super::shell::Word;
use super::Rule;

impl State<'_> {
    /// PowerShell cmdlets and their aliases. None for an external program.
    pub(super) fn powershell(&mut self, name: &str, args: &[Word]) -> Check<Option<Effect>> {
        let ps = ps_args(args);
        let paths = || -> Vec<Word> {
            let mut out: Vec<Word> = ps.named(&["path", "literalpath", "lp", "pspath", "filepath"]);
            out.extend(ps.positional.first().cloned());
            out
        };
        let effect = match name {
            "remove-item" | "rm" | "del" | "erase" | "ri" | "rd" | "rmdir" => {
                if ps.switch(&["whatif"], 2) {
                    Effect::read_only()
                } else if ps.switch(&["recurse"], 1) || ps.switch(&["force"], 1) {
                    return hold(
                        Rule::RecursiveDelete,
                        "`Remove-Item -Recurse/-Force` deletes without asking",
                    );
                } else {
                    let mut targets = ps.named(&["path", "literalpath", "lp"]);
                    targets.extend(ps.positional.iter().cloned());
                    Effect::writes(targets)
                }
            }
            "copy-item" | "cp" | "copy" | "cpi" => {
                let mut dest = ps.named(&["destination"]);
                if dest.is_empty() {
                    dest.extend(ps.positional.get(1).cloned());
                }
                if dest.is_empty() {
                    Effect::cwd()
                } else {
                    Effect::writes(dest)
                }
            }
            "move-item" | "mv" | "move" | "mi" => {
                let mut targets = ps.named(&["path", "literalpath", "destination"]);
                targets.extend(ps.positional.iter().cloned());
                Effect::writes(targets)
            }
            "rename-item" | "ren" | "rni" | "new-item" | "ni" | "mkdir" | "md" | "set-content"
            | "sc" | "add-content" | "ac" | "out-file" | "clear-content" | "clc" | "tee-object"
            | "tee" | "export-csv" | "export-clixml" => Effect::writes(paths()),
            "set-location" | "cd" | "sl" | "chdir" | "push-location" | "pushd" => {
                let target = ps
                    .named(&["path", "literalpath"])
                    .into_iter()
                    .chain(ps.positional.first().cloned())
                    .next();
                let dir = target.and_then(|w| match resolve(&w, self.cwd.as_ref(), self.env) {
                    Resolved::Path(p) => Some(p),
                    _ => None,
                });
                Effect {
                    read_only: true,
                    chdir: Some(dir),
                    ..Effect::default()
                }
            }
            "pop-location" | "popd" => Effect {
                read_only: true,
                chdir: Some(None),
                ..Effect::default()
            },
            "invoke-expression" | "iex" | "invoke-command" | "icm" | "start-job" | "sajb"
            | "start-threadjob" | "invoke-item" | "ii" | "foreach-object" | "where-object"
            | "%" | "?" => {
                return hold(
                    Rule::AmbiguousShell,
                    format!("`{name}` runs code given as text"),
                );
            }
            "start-process" | "saps" | "start" => {
                if ps
                    .named(&["verb"])
                    .iter()
                    .any(|v| v.text.eq_ignore_ascii_case("runas"))
                {
                    return hold(
                        Rule::Sudo,
                        "`Start-Process -Verb RunAs` runs as administrator",
                    );
                }
                return hold(
                    Rule::AmbiguousShell,
                    "`Start-Process` starts another program",
                );
            }
            "invoke-webrequest" | "iwr" | "invoke-restmethod" | "irm" | "curl" | "wget" => Effect {
                downloads: true,
                writes: ps
                    .named(&["outfile"])
                    .into_iter()
                    .map(Target::Word)
                    .collect(),
                read_only: false,
                ..Effect::default()
            },
            "install-module" | "install-package" | "install-script" | "update-module"
            | "uninstall-module" | "uninstall-package" => {
                return hold(
                    Rule::SystemInstall,
                    format!("`{name}` installs outside the repository"),
                );
            }
            "get-credential" | "get-storedcredential" | "new-storedcredential" => {
                return hold(
                    Rule::Credentials,
                    format!("`{name}` reads or stores credentials"),
                );
            }
            _ if PS_READ_ONLY.contains(&name) => Effect::read_only(),
            _ if PS_SYSTEM.contains(&name) => {
                return hold(
                    Rule::SystemChange,
                    format!("`{name}` changes system settings"),
                );
            }
            _ if is_cmdlet(name) => {
                return hold(
                    Rule::AmbiguousShell,
                    format!("`{name}` is not a PowerShell command this check knows"),
                );
            }
            _ => return Ok(None),
        };
        Ok(Some(effect))
    }
}

const PS_READ_ONLY: &[&str] = &[
    "get-childitem",
    "gci",
    "ls",
    "dir",
    "get-content",
    "gc",
    "cat",
    "type",
    "select-string",
    "sls",
    "get-location",
    "gl",
    "pwd",
    "test-path",
    "get-item",
    "gi",
    "get-itemproperty",
    "gp",
    "measure-object",
    "measure",
    "write-output",
    "echo",
    "write",
    "write-host",
    "write-verbose",
    "write-warning",
    "write-information",
    "get-command",
    "gcm",
    "resolve-path",
    "rvpa",
    "split-path",
    "join-path",
    "get-date",
    "sort-object",
    "sort",
    "select-object",
    "select",
    "format-list",
    "fl",
    "format-table",
    "ft",
    "format-wide",
    "fw",
    "out-string",
    "out-null",
    "out-host",
    "oh",
    "convertfrom-json",
    "convertto-json",
    "convertfrom-csv",
    "convertto-csv",
    "get-process",
    "gps",
    "ps",
    "get-service",
    "gsv",
    "get-filehash",
    "compare-object",
    "compare",
    "diff",
    "get-help",
    "help",
    "man",
    "get-member",
    "gm",
    "get-variable",
    "gv",
    "get-alias",
    "gal",
    "get-psdrive",
    "gdr",
    "get-random",
    "get-unique",
    "group-object",
    "group",
    "get-host",
    "get-culture",
    "get-uiculture",
    "get-acl",
    "get-history",
    "h",
    "history",
    "get-module",
    "gmo",
    "get-executionpolicy",
    "test-json",
    "get-error",
    "start-sleep",
    "sleep",
    "clear-host",
    "cls",
    "clear",
];

const PS_SYSTEM: &[&str] = &[
    "set-executionpolicy",
    "set-itemproperty",
    "sp",
    "new-itemproperty",
    "remove-itemproperty",
    "rp",
    "stop-process",
    "spps",
    "kill",
    "stop-computer",
    "restart-computer",
    "stop-service",
    "spsv",
    "start-service",
    "sasv",
    "restart-service",
    "set-service",
    "new-service",
    "remove-service",
    "set-date",
    "set-timezone",
    "register-scheduledtask",
    "unregister-scheduledtask",
    "set-mppreference",
    "add-mppreference",
    "new-netfirewallrule",
    "set-netfirewallrule",
    "set-dnsclientserveraddress",
    "set-netipaddress",
    "set-culture",
    "set-winsystemlocale",
    "set-localuser",
    "new-localuser",
    "remove-localuser",
    "add-localgroupmember",
    "set-variable",
    "sv",
];

/// A Verb-Noun name with a PowerShell verb.
fn is_cmdlet(name: &str) -> bool {
    const VERBS: &[&str] = &[
        "get",
        "set",
        "new",
        "remove",
        "add",
        "clear",
        "copy",
        "move",
        "rename",
        "start",
        "stop",
        "restart",
        "invoke",
        "import",
        "export",
        "install",
        "uninstall",
        "update",
        "enable",
        "disable",
        "register",
        "unregister",
        "test",
        "write",
        "read",
        "out",
        "format",
        "select",
        "where",
        "foreach",
        "sort",
        "group",
        "measure",
        "compare",
        "convert",
        "convertto",
        "convertfrom",
        "join",
        "split",
        "resolve",
        "push",
        "pop",
        "wait",
        "use",
        "show",
        "hide",
        "find",
        "save",
        "send",
        "receive",
        "connect",
        "disconnect",
        "mount",
        "dismount",
        "publish",
        "unpublish",
        "grant",
        "revoke",
        "protect",
        "unprotect",
        "block",
        "unblock",
        "lock",
        "unlock",
        "suspend",
        "resume",
        "approve",
        "deny",
        "request",
        "confirm",
        "initialize",
        "reset",
        "repair",
        "backup",
        "restore",
        "checkpoint",
        "debug",
        "trace",
        "limit",
        "edit",
        "expand",
        "compress",
        "optimize",
        "merge",
        "sync",
        "submit",
        "close",
        "open",
        "enter",
        "exit",
        "step",
        "undo",
        "redo",
        "search",
        "skip",
        "watch",
        "deploy",
        "build",
        "complete",
    ];
    match name.split_once('-') {
        Some((verb, noun)) => !noun.is_empty() && VERBS.contains(&verb),
        None => false,
    }
}

/// PowerShell parameters: `-Name value`, `-Name:value` and switches.
struct PsArgs {
    positional: Vec<Word>,
    named: Vec<(String, Option<Word>)>,
}

impl PsArgs {
    fn named(&self, names: &[&str]) -> Vec<Word> {
        self.named
            .iter()
            .filter(|(n, _)| names.contains(&n.as_str()))
            .filter_map(|(_, v)| v.clone())
            .collect()
    }

    /// A switch given by a prefix of at least `min` letters (`-r`, `-Rec`, `-Recurse`).
    fn switch(&self, full: &[&str], min: usize) -> bool {
        self.named
            .iter()
            .any(|(n, _)| n.len() >= min && full.iter().any(|f| f.starts_with(n.as_str())))
    }
}

fn ps_args(args: &[Word]) -> PsArgs {
    const WITH_VALUE: &[&str] = &[
        "path",
        "literalpath",
        "lp",
        "pspath",
        "destination",
        "filepath",
        "value",
        "filter",
        "include",
        "exclude",
        "itemtype",
        "type",
        "name",
        "newname",
        "encoding",
        "credential",
        "stream",
        "outfile",
        "uri",
        "method",
        "body",
        "headers",
        "verb",
        "argumentlist",
        "args",
        "workingdirectory",
    ];
    let mut out = PsArgs {
        positional: Vec::new(),
        named: Vec::new(),
    };
    let mut i = 0;
    while let Some(a) = args.get(i) {
        i += 1;
        let t = a.text.as_str();
        if a.quoted || a.dynamic || !t.starts_with('-') || t.len() == 1 {
            out.positional.push(a.clone());
            continue;
        }
        let body = t[1..].to_lowercase();
        if let Some((name, value)) = body.split_once(':') {
            out.named.push((
                name.to_string(),
                Some(a.with_text(&t[1 + name.len() + 1..])),
            ));
            let _ = value;
            continue;
        }
        if WITH_VALUE.contains(&body.as_str()) {
            out.named.push((body, args.get(i).cloned()));
            i += 1;
        } else {
            out.named.push((body, None));
        }
    }
    out
}
