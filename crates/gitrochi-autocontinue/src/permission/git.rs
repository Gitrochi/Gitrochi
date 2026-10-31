//! Rules for git, gitch and the hosting command-line tools (gh, glab).

use super::commands::{hold, parse_args, resolve, Check, Effect, Resolved, State};
use super::shell::Word;
use super::{Env, Rule};

impl State<'_> {
    pub(super) fn git(&mut self, args: &[Word]) -> Check<Effect> {
        let mut i = 0;
        let mut dir: Option<Word> = None;
        while let Some(a) = args.get(i) {
            let t = a.text.as_str();
            if a.dynamic && t.starts_with('-') {
                return hold(
                    Rule::AmbiguousShell,
                    "git gets options only known when it runs",
                );
            }
            match t {
                "-C" => {
                    dir = args.get(i + 1).cloned();
                    i += 2;
                }
                "-c" => {
                    if let Some(kv) = args.get(i + 1) {
                        git_config_pair(&kv.text)?;
                    }
                    i += 2;
                }
                "--git-dir" | "--work-tree" | "--namespace" | "--super-prefix" | "--exec-path"
                | "--list-cmds" => {
                    if matches!(t, "--git-dir" | "--work-tree") {
                        dir = args.get(i + 1).cloned();
                    }
                    i += 2;
                }
                _ if t.starts_with("--git-dir=") || t.starts_with("--work-tree=") => {
                    let value = t.split_once('=').map(|(_, v)| v).unwrap_or("");
                    dir = Some(a.with_text(value));
                    i += 1;
                }
                _ if t.starts_with("--config-env") => {
                    return hold(
                        Rule::SkipChecks,
                        "`git --config-env` sets configuration from the environment",
                    );
                }
                "--version" | "--help" | "-h" | "help" | "version" => {
                    return Ok(Effect::read_only())
                }
                _ if t.starts_with('-') => i += 1,
                _ => break,
            }
        }
        let Some(sub) = args.get(i) else {
            return Ok(Effect::read_only());
        };
        if sub.dynamic {
            return hold(
                Rule::AmbiguousShell,
                "the git command is only known when it runs",
            );
        }
        let sub_name = sub.text.as_str();
        let rest = &args[i + 1..];
        let read_only = git_read_only(sub_name, rest);
        // `-C`, `--git-dir` and `--work-tree` move git to another folder
        let place = match &dir {
            Some(d) => match resolve(d, self.cwd.as_ref(), self.env) {
                Resolved::Path(p) => Some(p),
                _ => None,
            },
            None => self.cwd.clone(),
        };
        if !read_only && !place.as_ref().is_some_and(|p| self.env.inside(p)) {
            return hold(
                Rule::OutsideRepoWrite,
                format!("runs `git {sub_name}` in a repository outside the working folder"),
            );
        }
        let mut effect = git_subcommand(sub_name, rest, self.env)?;
        effect.read_only = true; // where it runs was checked above
                                 // targets such as `git clone URL DIR` stay to be checked
        Ok(effect)
    }

    pub(super) fn gitch(&mut self, args: &[Word]) -> Check<Effect> {
        let ops: Vec<&Word> = args.iter().filter(|a| !a.text.starts_with('-')).collect();
        let flags: Vec<&str> = args
            .iter()
            .filter(|a| a.text.starts_with('-'))
            .map(|a| a.text.as_str())
            .collect();
        let has = |f: &str| flags.contains(&f);
        if has("--no-verify") {
            return hold(Rule::SkipChecks, "`--no-verify` skips the commit checks");
        }
        let Some(sub) = ops.first().map(|w| w.text.as_str()) else {
            return Ok(Effect::read_only());
        };
        let second = ops.get(1).map(|w| w.text.as_str()).unwrap_or("");
        match sub {
            "use" | "unlock" | "undo" | "amend" | "remove" | "abort" | "add" | "setup"
            | "login" | "org" | "sign" | "import" | "migrate" | "install" | "uninstall"
            | "self-update" | "ai" | "auto" | "ssh" => hold(
                Rule::GitchAccount,
                format!("`gitch {sub}` changes accounts, settings or history; the person runs it"),
            ),
            "ignore" => hold(Rule::SkipChecks, "`gitch ignore` turns gitch's checks off"),
            "config" if !matches!(second, "" | "show" | "path" | "get") => hold(
                Rule::GitchAccount,
                "`gitch config` changes gitch's settings",
            ),
            "protect" if has("--rm") => hold(
                Rule::GitchAccount,
                "`gitch protect --rm` removes a branch protection",
            ),
            "rescue" if has("--restore") => hold(
                Rule::GitchAccount,
                "`gitch rescue --restore` replaces the work tree from a backup",
            ),
            "fix" if has("--yes") || has("-y") => hold(
                Rule::GitchAccount,
                "`gitch fix --yes` rewrites commit authors",
            ),
            "p" | "push" | "cp" => {
                if has("--force") || has("-f") {
                    return hold(
                        Rule::ForcePush,
                        format!("`gitch {sub} --force` rewrites the remote branch"),
                    );
                }
                implicit_push(self.env, &format!("gitch {sub}"))?;
                Ok(Effect::default())
            }
            "publish" => hold(
                Rule::Deploy,
                "`gitch publish` creates a remote repository and pushes to it",
            ),
            "sync" => hold(
                Rule::ProtectedBranchPush,
                "`gitch sync` updates the fork's default branch",
            ),
            "prune" if has("--yes") => {
                hold(Rule::DiscardChanges, "`gitch prune --yes` deletes branches")
            }
            "wt" if matches!(second, "rm" | "remove") => hold(
                Rule::DiscardChanges,
                "`gitch wt rm` removes a worktree folder",
            ),
            "wt" if matches!(second, "" | "ls" | "list") => Ok(Effect::read_only()),
            "wt" => hold(
                Rule::OutsideRepoWrite,
                "`gitch wt` creates a worktree where gitch decides",
            ),
            "clone" | "fork" => hold(
                Rule::OutsideRepoWrite,
                format!("`gitch {sub}` clones into the account folder"),
            ),
            "work" | "workspace" | "ws" | "w" => {
                if has("--dry-run") || matches!(second, "" | "list" | "info" | "show" | "status") {
                    Ok(Effect::read_only())
                } else if second == "end" && has("--delete-branch") {
                    hold(
                        Rule::DiscardChanges,
                        "`gitch work end --delete-branch` deletes branches",
                    )
                } else if second == "push" {
                    hold(
                        Rule::PushTargetUnclear,
                        "`gitch work push` pushes branches in several repositories",
                    )
                } else {
                    hold(
                        Rule::OutsideRepoWrite,
                        format!("`gitch {sub} {second}` changes other repositories"),
                    )
                }
            }
            "scan" if has("--fix") => hold(
                Rule::OutsideRepoWrite,
                "`gitch scan --fix` changes every repository in the folder",
            ),
            "flow" if second == "trust" => hold(
                Rule::GitchAccount,
                "trusting a flow file is the person's decision",
            ),
            "flow" if second == "connect" => hold(
                Rule::Credentials,
                "`gitch flow connect` stores CI credentials",
            ),
            "preflight" | "ck" | "status" | "list" | "doctor" | "version" | "graph" | "g"
            | "overlap" | "move" | "module" | "report" | "scan" | "audit" | "schema"
            | "completion" | "issue" | "ci" | "l" | "d" | "git" | "help" | "logo" | "o" | "app"
            | "export" => Ok(Effect::read_only()),
            "c" | "pl" | "up" | "b" | "continue" | "pr" | "test" | "flow" => Ok(Effect::default()),
            _ => hold(
                Rule::AmbiguousShell,
                format!("`gitch {sub}` is not a gitch command this check knows"),
            ),
        }
    }
}

/// `-c name=value` for git.
fn git_config_pair(pair: &str) -> Check {
    let key = pair.split('=').next().unwrap_or("").to_lowercase();
    if key == "core.hookspath" {
        return hold(
            Rule::SkipChecks,
            "`core.hooksPath` replaces the commit checks",
        );
    }
    if key.starts_with("user.")
        || key.starts_with("author.")
        || key.starts_with("committer.")
        || key.starts_with("credential")
        || key == "core.sshcommand"
        || key.starts_with("gpg.")
        || key == "user.signingkey"
    {
        return hold(
            Rule::Credentials,
            format!("`{key}` changes the account or credentials"),
        );
    }
    Ok(())
}

const GIT_READ_ONLY: &[&str] = &[
    "status",
    "log",
    "diff",
    "show",
    "rev-parse",
    "rev-list",
    "ls-files",
    "ls-tree",
    "ls-remote",
    "cat-file",
    "blame",
    "annotate",
    "describe",
    "shortlog",
    "grep",
    "show-ref",
    "for-each-ref",
    "merge-base",
    "name-rev",
    "var",
    "count-objects",
    "check-ignore",
    "check-attr",
    "check-ref-format",
    "cherry",
    "range-diff",
    "whatchanged",
    "show-branch",
    "diff-tree",
    "diff-files",
    "diff-index",
    "verify-commit",
    "verify-tag",
    "fsck",
    "help",
    "version",
];

fn git_read_only(sub: &str, rest: &[Word]) -> bool {
    if GIT_READ_ONLY.contains(&sub) {
        return true;
    }
    let first = rest
        .iter()
        .find(|w| !w.text.starts_with('-'))
        .map(|w| w.text.as_str());
    let flags = |list: &[&str]| rest.iter().any(|w| list.contains(&w.text.as_str()));
    match sub {
        "branch" => {
            rest.is_empty()
                || flags(&[
                    "-l",
                    "--list",
                    "-a",
                    "-r",
                    "--all",
                    "--remotes",
                    "-v",
                    "-vv",
                    "--show-current",
                    "--contains",
                    "--merged",
                    "--no-merged",
                ])
        }
        "tag" => rest.is_empty() || flags(&["-l", "--list", "--contains", "--points-at"]),
        "remote" => matches!(first, None | Some("show" | "get-url")) || flags(&["-v"]),
        "stash" => matches!(first, Some("list" | "show")),
        "worktree" => first == Some("list"),
        "reflog" => matches!(first, None | Some("show")),
        "config" => {
            flags(&[
                "--get",
                "--get-all",
                "--get-regexp",
                "-l",
                "--list",
                "--show-origin",
                "--show-scope",
            ]) || (rest.len() == 1 && !rest[0].text.starts_with('-'))
        }
        "notes" => matches!(first, None | Some("list" | "show")),
        "submodule" => matches!(first, None | Some("status" | "summary")),
        _ => false,
    }
}

fn git_subcommand(sub: &str, rest: &[Word], env: &Env) -> Check<Effect> {
    let has = |list: &[&str]| rest.iter().any(|w| list.contains(&w.text.as_str()));
    let short = |c: char| {
        rest.iter().any(|w| {
            let t = w.text.as_str();
            t.starts_with('-') && !t.starts_with("--") && t[1..].contains(c)
        })
    };
    match sub {
        "push" => {
            push(rest, env)?;
            Ok(Effect::default())
        }
        "commit" => {
            if has(&["--no-verify"]) || commit_short_no_verify(rest) {
                return hold(
                    Rule::SkipChecks,
                    "`git commit --no-verify` skips the commit checks",
                );
            }
            Ok(Effect::default())
        }
        "merge" | "pull" | "am" | "cherry-pick" | "revert" => {
            if has(&["--no-verify"]) {
                return hold(
                    Rule::SkipChecks,
                    format!("`git {sub} --no-verify` skips the checks"),
                );
            }
            Ok(Effect::default())
        }
        "rebase" => {
            if has(&["--no-verify"]) {
                return hold(
                    Rule::SkipChecks,
                    "`git rebase --no-verify` skips the checks",
                );
            }
            if has(&["-x", "--exec"]) || rest.iter().any(|w| w.text.starts_with("--exec=")) {
                return hold(
                    Rule::AmbiguousShell,
                    "`git rebase --exec` runs a command string",
                );
            }
            Ok(Effect::default())
        }
        "reset" => {
            if has(&["--hard"]) {
                return hold(
                    Rule::DiscardChanges,
                    "`git reset --hard` discards uncommitted changes",
                );
            }
            Ok(Effect::default())
        }
        "checkout" => {
            let ops: Vec<&Word> = rest.iter().filter(|w| !w.text.starts_with('-')).collect();
            let creates = has(&["-b", "-B", "--orphan"]);
            if has(&["-f", "--force", "--ours", "--theirs", "-p", "--patch", "--"])
                || ops.iter().any(|w| w.text == "." || w.glob)
                || (!creates && ops.len() > 1)
                || (!creates && ops.first().is_some_and(|w| looks_like_file(&w.text)))
            {
                return hold(
                    Rule::DiscardChanges,
                    "`git checkout` of files discards their changes",
                );
            }
            Ok(Effect::default())
        }
        "switch" => {
            if has(&["--discard-changes", "-f", "--force"]) {
                return hold(
                    Rule::DiscardChanges,
                    "`git switch --discard-changes` throws changes away",
                );
            }
            Ok(Effect::default())
        }
        "restore" => {
            let staged_only = has(&["--staged", "-S"]) && !has(&["--worktree", "-W"]);
            if !staged_only {
                return hold(
                    Rule::DiscardChanges,
                    "`git restore` discards changes in the work tree",
                );
            }
            Ok(Effect::default())
        }
        "clean" => {
            if has(&["-n", "--dry-run"]) || short('n') {
                return Ok(Effect::read_only());
            }
            hold(Rule::GitClean, "`git clean` deletes untracked files")
        }
        "stash" => {
            if rest
                .iter()
                .any(|w| matches!(w.text.as_str(), "drop" | "clear"))
            {
                return hold(
                    Rule::DiscardChanges,
                    "`git stash drop`/`clear` deletes stashed changes",
                );
            }
            Ok(Effect::default())
        }
        "branch" => {
            let delete = has(&["-d", "--delete"]) || short('d');
            if has(&["-D"]) || short('D') || (delete && (has(&["-f", "--force"]) || short('f'))) {
                return hold(
                    Rule::DiscardChanges,
                    "`git branch -D` deletes a branch that may not be merged",
                );
            }
            Ok(Effect::default())
        }
        "tag" => {
            if has(&["-d", "--delete"]) {
                return hold(Rule::DiscardChanges, "`git tag -d` deletes a tag");
            }
            Ok(Effect::default())
        }
        "reflog" => {
            if rest
                .iter()
                .any(|w| matches!(w.text.as_str(), "expire" | "delete"))
            {
                return hold(
                    Rule::DiscardChanges,
                    "`git reflog expire` drops recovery points",
                );
            }
            Ok(Effect::default())
        }
        "gc" => {
            if rest
                .iter()
                .any(|w| matches!(w.text.as_str(), "--prune=now" | "--prune=all"))
            {
                return hold(
                    Rule::DiscardChanges,
                    "`git gc --prune=now` deletes unreachable commits",
                );
            }
            Ok(Effect::default())
        }
        "prune" => {
            if has(&["-n", "--dry-run"]) {
                return Ok(Effect::read_only());
            }
            hold(
                Rule::DiscardChanges,
                "`git prune` deletes unreachable objects",
            )
        }
        "update-ref" | "filter-branch" | "filter-repo" | "replace" => hold(
            Rule::DiscardChanges,
            format!("`git {sub}` rewrites refs or history"),
        ),
        "worktree" => {
            let ops: Vec<&Word> = rest.iter().filter(|w| !w.text.starts_with('-')).collect();
            match ops.first().map(|w| w.text.as_str()) {
                Some("remove") if has(&["-f", "--force"]) => hold(
                    Rule::DiscardChanges,
                    "`git worktree remove --force` deletes a worktree with changes",
                ),
                Some("add") => {
                    let a = parse_args(&rest[1..], "bB", &["--reason"]);
                    Ok(Effect::writes(a.operands.first().cloned()))
                }
                Some("move") => Ok(Effect::writes(ops.get(2).map(|w| (*w).clone()))),
                _ => Ok(Effect::default()),
            }
        }
        "clone" => {
            let a = parse_args(
                rest,
                "bojcu",
                &[
                    "--branch",
                    "--origin",
                    "--depth",
                    "--reference",
                    "--config",
                    "--template",
                    "--separate-git-dir",
                    "--jobs",
                    "--filter",
                    "--server-option",
                    "--upload-pack",
                ],
            );
            if a.value_of("-u").is_some() || a.value_of("--upload-pack").is_some() {
                return hold(
                    Rule::AmbiguousShell,
                    "`git clone --upload-pack` runs a command",
                );
            }
            for (flag, value) in &a.values {
                if flag == "-c" || flag == "--config" {
                    git_config_pair(&value.text)?;
                }
            }
            Ok(match a.operands.get(1) {
                Some(dir) => Effect::writes([dir.clone()]),
                None => Effect::cwd(),
            })
        }
        "init" => {
            let a = parse_args(
                rest,
                "",
                &[
                    "--separate-git-dir",
                    "--template",
                    "--initial-branch",
                    "--object-format",
                    "--shared",
                ],
            );
            Ok(match a.operands.first() {
                Some(dir) => Effect::writes([dir.clone()]),
                None => Effect::cwd(),
            })
        }
        "config" => git_config(rest),
        "submodule" => {
            if rest.iter().any(|w| w.text == "foreach") {
                return hold(
                    Rule::AmbiguousShell,
                    "`git submodule foreach` runs a command string",
                );
            }
            if rest.iter().any(|w| w.text == "deinit") && has(&["-f", "--force"]) {
                return hold(
                    Rule::DiscardChanges,
                    "`git submodule deinit -f` discards submodule changes",
                );
            }
            Ok(Effect::default())
        }
        "bisect" => {
            if rest.first().is_some_and(|w| w.text == "run") {
                return hold(
                    Rule::AmbiguousShell,
                    "`git bisect run` runs a command repeatedly",
                );
            }
            Ok(Effect::default())
        }
        "credential"
        | "credential-cache"
        | "credential-store"
        | "credential-osxkeychain"
        | "credential-manager" => hold(
            Rule::Credentials,
            "`git credential` reads or stores credentials",
        ),
        "send-email" | "request-pull" if sub == "send-email" => {
            hold(Rule::Deploy, "`git send-email` sends patches by email")
        }
        "maintenance" => {
            if rest.iter().any(|w| {
                matches!(
                    w.text.as_str(),
                    "start" | "register" | "unregister" | "stop"
                )
            }) {
                return hold(
                    Rule::SystemChange,
                    "`git maintenance start` schedules background tasks",
                );
            }
            Ok(Effect::default())
        }
        "archive" => {
            let a = parse_args(
                rest,
                "o",
                &["--output", "--remote", "--exec", "--prefix", "--format"],
            );
            if a.value_of("--remote").is_some() || a.value_of("--exec").is_some() {
                return hold(
                    Rule::RemoteShell,
                    "`git archive --remote` asks another machine",
                );
            }
            Ok(Effect::writes(
                a.value_of("-o").or_else(|| a.value_of("--output")).cloned(),
            ))
        }
        "format-patch" => {
            let a = parse_args(rest, "o", &["--output-directory", "--output"]);
            Ok(
                match a
                    .value_of("-o")
                    .or_else(|| a.value_of("--output-directory"))
                {
                    Some(dir) => Effect::writes([dir.clone()]),
                    None => Effect::cwd(),
                },
            )
        }
        "add" | "mv" | "rm" | "fetch" | "notes" | "apply" | "sparse-checkout" | "rerere"
        | "repack" | "pack-refs" | "commit-graph" | "multi-pack-index" | "symbolic-ref"
        | "read-tree" | "write-tree" | "commit-tree" | "hash-object" | "mktree" | "mktag"
        | "merge-file" | "merge-tree" | "lfs" | "remote" | "describe" | "request-pull"
        | "bundle" | "mergetool" | "difftool" | "unpack-objects" | "index-pack"
        | "update-index" | "checkout-index" | "stripspace" | "interpret-trailers" | "column"
        | "fmt-merge-msg" | "mailinfo" | "mailsplit" | "patch-id" | "get-tar-commit-id" => {
            Ok(Effect::default())
        }
        _ if GIT_READ_ONLY.contains(&sub) => Ok(Effect::read_only()),
        _ => hold(
            Rule::AmbiguousShell,
            format!("`git {sub}` is not a git command this check knows (possibly an alias)"),
        ),
    }
}

/// `git commit -n` is `--no-verify`; in a cluster such as `-anm msg` the letters before a
/// value-taking option still count.
fn commit_short_no_verify(rest: &[Word]) -> bool {
    for w in rest {
        let t = w.text.as_str();
        if !t.starts_with('-') || t.starts_with("--") || t == "-" {
            continue;
        }
        for c in t[1..].chars() {
            if c == 'n' {
                return true;
            }
            if matches!(c, 'm' | 'F' | 'C' | 'c' | 't' | 'S' | 'u') {
                break;
            }
        }
    }
    false
}

fn looks_like_file(text: &str) -> bool {
    let last = text.rsplit('/').next().unwrap_or(text);
    last.contains('.') && !last.starts_with('.') && !last.ends_with('.')
}

fn git_config(rest: &[Word]) -> Check<Effect> {
    let flags: Vec<&str> = rest
        .iter()
        .filter(|w| w.text.starts_with('-'))
        .map(|w| w.text.as_str())
        .collect();
    let read = flags.iter().any(|f| {
        matches!(
            *f,
            "--get"
                | "--get-all"
                | "--get-regexp"
                | "-l"
                | "--list"
                | "--get-urlmatch"
                | "--show-origin"
                | "--show-scope"
        )
    });
    let ops: Vec<&Word> = rest.iter().filter(|w| !w.text.starts_with('-')).collect();
    if read
        || ops.len() <= 1
            && !flags.iter().any(|f| {
                matches!(
                    *f,
                    "--unset"
                        | "--unset-all"
                        | "--add"
                        | "--replace-all"
                        | "-e"
                        | "--edit"
                        | "--remove-section"
                        | "--rename-section"
                )
            })
    {
        return Ok(Effect::read_only());
    }
    if flags
        .iter()
        .any(|f| matches!(*f, "--global" | "--system" | "--file" | "-f"))
    {
        return hold(
            Rule::Credentials,
            "`git config --global` changes the person's git settings",
        );
    }
    if flags.iter().any(|f| matches!(*f, "-e" | "--edit")) {
        return hold(Rule::AmbiguousShell, "`git config --edit` opens an editor");
    }
    if let Some(key) = ops.first() {
        git_config_pair(&key.text)?;
    }
    Ok(Effect::default())
}

/// A bare `git push` (or `gitch p`) updates the current branch or its upstream, depending
/// on `push.default`, so neither may be protected. Unknown means held.
fn implicit_push(env: &Env, what: &str) -> Check {
    let targets: Vec<&str> = [
        env.current_branch.as_deref(),
        env.upstream_branch.as_deref(),
    ]
    .into_iter()
    .flatten()
    .collect();
    if targets.is_empty() {
        return hold(
            Rule::PushTargetUnclear,
            format!("cannot tell which branch `{what}` updates"),
        );
    }
    if let Some(target) = targets.iter().find(|t| env.is_protected(t)) {
        return hold(
            Rule::ProtectedBranchPush,
            format!("`{what}` pushes to `{target}`"),
        );
    }
    Ok(())
}

fn push(rest: &[Word], env: &Env) -> Check {
    let mut positional: Vec<&Word> = Vec::new();
    let (mut force, mut delete, mut all, mut tags, mut prune, mut dry_run) =
        (false, false, false, false, false, false);
    let mut i = 0;
    while let Some(w) = rest.get(i) {
        i += 1;
        let t = w.text.as_str();
        if w.dynamic && t.starts_with('-') {
            return hold(
                Rule::PushTargetUnclear,
                "`git push` gets options only known when it runs",
            );
        }
        match t {
            "--" => {
                positional.extend(rest[i..].iter());
                break;
            }
            "-f" | "--force" | "--force-if-includes" => force = true,
            _ if t.starts_with("--force-with-lease") => force = true,
            "-d" | "--delete" => delete = true,
            "--all" | "--branches" | "--mirror" => all = true,
            "--tags" | "--follow-tags" => tags = true,
            "--prune" => prune = true,
            "-n" | "--dry-run" => dry_run = true,
            "--no-verify" => {
                return hold(
                    Rule::SkipChecks,
                    "`git push --no-verify` skips the push checks",
                )
            }
            "-o" | "--push-option" | "--repo" => i += 1,
            _ if t.starts_with("--receive-pack") || t.starts_with("--exec") => {
                return hold(
                    Rule::AmbiguousShell,
                    "`git push --receive-pack` runs a command",
                );
            }
            _ if t.starts_with("--") => {}
            _ if t.starts_with('-') && t.len() > 1 => {
                for c in t[1..].chars() {
                    match c {
                        'f' => force = true,
                        'd' => delete = true,
                        'n' => dry_run = true,
                        'o' => {
                            i += 1;
                            break;
                        }
                        _ => {}
                    }
                }
            }
            _ => positional.push(w),
        }
    }
    if dry_run {
        return Ok(());
    }
    if force {
        return hold(
            Rule::ForcePush,
            "`git push --force` rewrites the remote branch",
        );
    }
    if delete || positional.iter().skip(1).any(|w| w.text.starts_with(':')) {
        return hold(
            Rule::RemoteDelete,
            "`git push --delete` deletes a remote branch",
        );
    }
    if prune {
        return hold(
            Rule::RemoteDelete,
            "`git push --prune` deletes remote branches",
        );
    }
    if all {
        return hold(
            Rule::ProtectedBranchPush,
            "pushes every branch, protected ones included",
        );
    }
    if tags {
        return hold(Rule::Deploy, "pushes tags, which can start a release");
    }
    if positional.first().is_some_and(|remote| remote.dynamic) {
        return hold(
            Rule::PushTargetUnclear,
            "the remote is only known when it runs",
        );
    }
    let refspecs = positional.get(1..).unwrap_or_default();
    if refspecs.is_empty() {
        return implicit_push(env, "git push");
    }
    for spec in refspecs {
        if spec.dynamic {
            return hold(
                Rule::PushTargetUnclear,
                format!("the refspec `{}` is only known when it runs", spec.text),
            );
        }
        let text = spec.text.as_str();
        if let Some(forced) = text.strip_prefix('+') {
            return hold(Rule::ForcePush, format!("`+{forced}` force-pushes"));
        }
        let destination = text.rsplit_once(':').map(|(_, d)| d).unwrap_or(text);
        if destination.contains('*') {
            return hold(
                Rule::ProtectedBranchPush,
                format!("the pattern `{text}` can update protected branches"),
            );
        }
        if destination.starts_with("refs/tags/")
            || (!text.contains(':') && is_version_tag(destination))
        {
            return hold(
                Rule::Deploy,
                format!("pushes the tag `{destination}`, which can start a release"),
            );
        }
        let branch = destination
            .strip_prefix("refs/heads/")
            .or_else(|| destination.strip_prefix("refs/for/"))
            .or_else(|| destination.strip_prefix("refs/publish/"))
            .or_else(|| destination.strip_prefix("refs/drafts/"))
            .unwrap_or(destination);
        if matches!(branch, "HEAD" | "@" | "") {
            implicit_push(env, &format!("git push {text}"))?;
            continue;
        }
        if env.is_protected(branch) {
            return hold(
                Rule::ProtectedBranchPush,
                format!("pushes to the protected branch `{branch}`"),
            );
        }
    }
    Ok(())
}

fn is_version_tag(name: &str) -> bool {
    let rest = name.strip_prefix('v').unwrap_or(name);
    let mut parts = rest.split('.');
    let first_numeric = parts
        .next()
        .is_some_and(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()));
    first_numeric && rest.contains('.')
}

pub(super) fn gh(args: &[Word]) -> Check<Effect> {
    let ops: Vec<&str> = args
        .iter()
        .filter(|a| !a.text.starts_with('-'))
        .map(|a| a.text.as_str())
        .collect();
    let group = ops.first().copied().unwrap_or("");
    let action = ops.get(1).copied().unwrap_or("");
    match (group, action) {
        ("pr", "merge") => hold(
            Rule::ProtectedBranchPush,
            "`gh pr merge` merges into the base branch",
        ),
        ("release", a) if !matches!(a, "list" | "view" | "download" | "") => {
            hold(Rule::Deploy, format!("`gh release {a}` changes a release"))
        }
        ("workflow", "run" | "enable" | "disable") | ("run", "rerun") => {
            hold(Rule::Deploy, "`gh workflow run` starts CI that may deploy")
        }
        ("repo", "delete") => hold(
            Rule::RemoteDelete,
            "`gh repo delete` deletes the repository",
        ),
        ("repo", "archive" | "rename" | "edit" | "unarchive") => hold(
            Rule::RemoteApi,
            format!("`gh repo {action}` changes repository settings"),
        ),
        ("repo", "create") => hold(Rule::Deploy, "`gh repo create` creates a remote repository"),
        ("auth" | "ssh-key" | "gpg-key" | "secret" | "variable", _) => hold(
            Rule::Credentials,
            format!("`gh {group}` changes credentials or secrets"),
        ),
        ("config", "set") => hold(
            Rule::Credentials,
            "`gh config set` changes the person's gh settings",
        ),
        ("extension" | "ext", "install" | "upgrade" | "remove") => hold(
            Rule::SystemInstall,
            "`gh extension install` installs outside the repository",
        ),
        ("codespace" | "cs", "ssh" | "cp") => hold(
            Rule::RemoteShell,
            "`gh codespace ssh` works on another machine",
        ),
        ("api", _) => api_call("gh", args),
        _ => Ok(Effect::default()),
    }
}

pub(super) fn glab(args: &[Word]) -> Check<Effect> {
    let ops: Vec<&str> = args
        .iter()
        .filter(|a| !a.text.starts_with('-'))
        .map(|a| a.text.as_str())
        .collect();
    let group = ops.first().copied().unwrap_or("");
    let action = ops.get(1).copied().unwrap_or("");
    match (group, action) {
        ("mr", "merge") => hold(
            Rule::ProtectedBranchPush,
            "`glab mr merge` merges into the target branch",
        ),
        ("release", a) if !matches!(a, "list" | "view" | "download" | "") => hold(
            Rule::Deploy,
            format!("`glab release {a}` changes a release"),
        ),
        ("ci" | "pipeline", "run" | "retry" | "trigger") => {
            hold(Rule::Deploy, "`glab ci run` starts CI that may deploy")
        }
        ("repo", "delete") => hold(
            Rule::RemoteDelete,
            "`glab repo delete` deletes the repository",
        ),
        ("auth" | "ssh-key" | "variable" | "token", _) => hold(
            Rule::Credentials,
            format!("`glab {group}` changes credentials or secrets"),
        ),
        ("api", _) => api_call("glab", args),
        _ => Ok(Effect::default()),
    }
}

/// An API call changes things unless it is a GET (a GraphQL query without `mutation`).
fn api_call(tool: &str, args: &[Word]) -> Check<Effect> {
    let a = parse_args(
        args,
        "XfFHpqt",
        &[
            "--method",
            "--field",
            "--raw-field",
            "--header",
            "--input",
            "--jq",
            "--template",
            "--preview",
            "--hostname",
        ],
    );
    let method = a
        .value_of("-X")
        .or_else(|| a.value_of("--method"))
        .map(|w| w.text.to_uppercase());
    let fields: Vec<&Word> = a
        .values
        .iter()
        .filter(|(f, _)| {
            matches!(
                f.as_str(),
                "-f" | "-F" | "--field" | "--raw-field" | "--input"
            )
        })
        .map(|(_, w)| w)
        .collect();
    let graphql = a.operands.iter().any(|w| w.text == "graphql");
    let reads = match method.as_deref() {
        Some("GET") | Some("HEAD") => true,
        Some(_) => false,
        None if graphql => !fields
            .iter()
            .any(|w| w.dynamic || w.text.to_lowercase().contains("mutation")),
        None => fields.is_empty(),
    };
    if reads {
        Ok(Effect::default())
    } else {
        hold(
            Rule::RemoteApi,
            format!("`{tool} api` sends a request that changes things"),
        )
    }
}
