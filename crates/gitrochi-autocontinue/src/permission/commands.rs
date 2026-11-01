//! Rules for shell commands. Each simple command is unwrapped (`env`, `nice`, `xargs`,
//! `npx` …) and checked by program; files it writes must be inside the repository; a
//! download piped into an interpreter is caught; and a command that is not read-only must
//! run inside the repository.

use super::deny;
use super::git::{gh, glab};
use super::paths::{self, AbsPath};
use super::shell::{self, Dialect, Item, Link, Redirect, Word};
use super::tools::{
    cargo, deploy_tool, gem, go, gpg, package_manager, pip, system_packages, system_tool,
    toolchains,
};
use super::{Env, Hold, Rule};

pub(super) type Check<T = ()> = Result<T, Hold>;

pub(crate) fn check(source: &str, dialect: Dialect, env: &Env) -> Check {
    let items = shell::parse(source, dialect).map_err(|u| {
        Hold::new(
            Rule::AmbiguousShell,
            format!("the command {}", u.describe()),
        )
    })?;
    let mut state = State {
        env,
        dialect,
        cwd: env.cwd.clone(),
        stack: Vec::new(),
        pipeline: Vec::new(),
        downloads: Vec::new(),
    };
    for item in &items {
        match item {
            Item::Open => state.stack.push(state.cwd.clone()),
            Item::Close => {
                if let Some(cwd) = state.stack.pop() {
                    state.cwd = cwd;
                }
            }
            Item::Command(cmd) => state.command(cmd)?,
        }
    }
    Ok(())
}

pub(super) fn hold<T>(rule: Rule, detail: impl Into<String>) -> Check<T> {
    Err(Hold::new(rule, detail))
}

/// Where a write lands, for the checks on writes.
pub(super) enum Target {
    Word(Word),
    /// The working folder (`wget URL`, `tar -x`).
    Cwd,
}

#[derive(Default)]
pub(super) struct Effect {
    pub(super) writes: Vec<Target>,
    /// Only reads, so it may run outside the repository.
    pub(super) read_only: bool,
    /// Downloads from the network; files it writes are remembered as downloads.
    pub(super) downloads: bool,
    /// Runs code read from its input (an interpreter given no script).
    pub(super) runs_stdin: bool,
    /// Runs this script file.
    pub(super) runs_file: Option<Word>,
    /// Moves the working folder (`None` inside: to a place we cannot tell).
    pub(super) chdir: Option<Option<AbsPath>>,
}

impl Effect {
    pub(super) fn read_only() -> Self {
        Self {
            read_only: true,
            ..Self::default()
        }
    }

    pub(super) fn writes(words: impl IntoIterator<Item = Word>) -> Self {
        Self {
            writes: words.into_iter().map(Target::Word).collect(),
            ..Self::default()
        }
    }

    pub(super) fn cwd() -> Self {
        Self {
            writes: vec![Target::Cwd],
            ..Self::default()
        }
    }
}

pub(super) struct State<'a> {
    pub(super) env: &'a Env,
    dialect: Dialect,
    pub(super) cwd: Option<AbsPath>,
    stack: Vec<Option<AbsPath>>,
    /// For each stage of the current pipeline: whether it downloads.
    pipeline: Vec<bool>,
    /// Files a downloader wrote earlier in this command line.
    downloads: Vec<AbsPath>,
}

impl State<'_> {
    fn command(&mut self, cmd: &shell::Command) -> Check {
        if cmd.link != Link::Pipe {
            self.pipeline.clear();
        }
        if cmd.header {
            self.pipeline.push(false);
            return Ok(());
        }
        if let Some(cwd) = &self.cwd {
            if paths::credential_parts(cwd.parts()) {
                return hold(
                    Rule::Credentials,
                    "runs inside a folder that holds credentials",
                );
            }
        }
        for (name, value) in &cmd.assigns {
            assignment(name, value)?;
        }
        for redirect in &cmd.redirects {
            match redirect {
                Redirect::Write(target) => self.write(target)?,
                Redirect::Read(source) => credentials_in(source)?,
                Redirect::Heredoc { .. } | Redirect::HereString(_) | Redirect::Dup => {}
            }
        }
        let downloads = self.words(&cmd.words, cmd.link == Link::Pipe)?;
        self.pipeline.push(downloads);
        Ok(())
    }

    /// Checks one simple command given as words; returns whether it downloads.
    fn words(&mut self, words: &[Word], piped: bool) -> Check<bool> {
        for w in words {
            credentials_in(w)?;
        }
        let (start, xargs) = self.unwrap(words)?;
        let Some(start) = start else {
            return Ok(false);
        };
        let program = &words[start];
        if program.dynamic {
            return hold(
                Rule::AmbiguousShell,
                format!(
                    "the command name `{}` is only known when it runs",
                    program.text
                ),
            );
        }
        let line = words[start..]
            .iter()
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        deny::check_command(&self.env.extra, &line)?;
        let name = program_name(&program.text);
        let args = &words[start + 1..];
        let mut effect = self.program(&name, program, args)?;
        // xargs adds operands we cannot see, so a program that writes its operands is held
        if xargs
            && !effect.read_only
            && (!effect.writes.is_empty() || OPERAND_WRITERS.contains(&name.as_str()))
        {
            return hold(
                Rule::OutsideRepoWrite,
                format!("`{name}` writes files that xargs passes in, which cannot be checked"),
            );
        }
        if effect.runs_stdin {
            if piped && self.pipeline.iter().any(|d| *d) {
                return hold(Rule::PipeToShell, format!("pipes a download into `{name}`"));
            }
            return hold(
                Rule::AmbiguousShell,
                format!("`{name}` runs code it reads from its input"),
            );
        }
        if effect.runs_file.is_none() && program.text.contains(['/', '\\']) {
            effect.runs_file = Some(program.clone());
        }
        if let Some(file) = &effect.runs_file {
            self.script(file)?;
        }
        for target in &effect.writes {
            match target {
                Target::Word(w) => {
                    self.write(w)?;
                    if effect.downloads {
                        if let Resolved::Path(p) = resolve(w, self.cwd.as_ref(), self.env) {
                            self.downloads.push(p);
                        }
                    }
                }
                Target::Cwd => self.write_cwd(&name)?,
            }
        }
        if let Some(dir) = effect.chdir.take() {
            self.cwd = dir;
        } else if !effect.read_only && !self.cwd_inside() {
            return hold(
                Rule::OutsideRepoWrite,
                format!("runs `{name}` outside the repository"),
            );
        }
        Ok(effect.downloads)
    }

    fn cwd_inside(&self) -> bool {
        self.cwd.as_ref().is_some_and(|c| self.env.inside(c))
    }

    fn write(&self, word: &Word) -> Check {
        check_path_write(word, self.cwd.as_ref(), self.env)
    }

    fn write_cwd(&self, name: &str) -> Check {
        if self.cwd_inside() {
            Ok(())
        } else {
            hold(
                Rule::OutsideRepoWrite,
                format!("`{name}` writes into a folder outside the repository"),
            )
        }
    }

    fn script(&self, file: &Word) -> Check {
        if deploy_named(&file.text) {
            return hold(Rule::Deploy, format!("runs `{}`", file.text));
        }
        if let Resolved::Path(p) = resolve(file, self.cwd.as_ref(), self.env) {
            if self.downloads.contains(&p) {
                return hold(
                    Rule::PipeToShell,
                    format!("runs `{}` right after downloading it", file.text),
                );
            }
        }
        Ok(())
    }

    /// Skips wrappers that run the next word as the command. Returns the index of the
    /// real command and whether xargs adds arguments to it.
    fn unwrap(&self, words: &[Word]) -> Check<(Option<usize>, bool)> {
        let mut i = 0;
        let mut xargs = false;
        loop {
            let Some(w) = words.get(i) else {
                return Ok((None, xargs));
            };
            if w.dynamic {
                return Ok((Some(i), xargs));
            }
            let name = program_name(&w.text);
            let rest = &words[i + 1..];
            let skip = match name.as_str() {
                "sudo" | "doas" | "su" | "pkexec" | "run0" | "gsudo" | "runas" => {
                    return hold(Rule::Sudo, format!("runs `{}` as another user", w.text));
                }
                "env" => {
                    let mut j = 0;
                    while let Some(a) = rest.get(j) {
                        let t = a.text.as_str();
                        if t == "-S" || t.starts_with("--split-string") {
                            return hold(
                                Rule::AmbiguousShell,
                                "`env -S` splits a string into a command",
                            );
                        }
                        if matches!(t, "-u" | "--unset" | "-C" | "--chdir" | "-P") {
                            j += 2;
                        } else if t.starts_with('-') {
                            j += 1;
                        } else if let Some((n, v)) = t.split_once('=') {
                            assignment(n, &Word::plain(v))?;
                            j += 1;
                        } else {
                            break;
                        }
                    }
                    1 + j
                }
                "nice" => 1 + skip_options(rest, &["-n", "--adjustment"]),
                "nohup" | "time" | "builtin" | "chronic" | "unbuffer" => 1,
                "command" => {
                    if rest
                        .first()
                        .is_some_and(|a| a.text == "-v" || a.text == "-V")
                    {
                        return Ok((Some(i), xargs));
                    }
                    1 + skip_options(rest, &[])
                }
                "exec" => 1 + skip_options(rest, &["-a"]),
                "caffeinate" => 1 + skip_options(rest, &["-t", "-w"]),
                "stdbuf" => 1 + skip_options(rest, &["-i", "-o", "-e"]),
                "ionice" => 1 + skip_options(rest, &["-c", "-n", "-p"]),
                "timeout" | "gtimeout" => {
                    let j = skip_options(rest, &["-s", "--signal", "-k", "--kill-after"]);
                    // then the duration
                    1 + j + 1
                }
                "xargs" => {
                    xargs = true;
                    1 + skip_options(
                        rest,
                        &[
                            "-I",
                            "-L",
                            "-n",
                            "-P",
                            "-s",
                            "-d",
                            "-E",
                            "-a",
                            "--max-args",
                            "--max-procs",
                            "--delimiter",
                            "--arg-file",
                            "--replace",
                            "--max-lines",
                        ],
                    )
                }
                "npx" | "bunx" | "pnpx" | "uvx" => {
                    if rest.iter().any(|a| a.text == "-c" || a.text == "--call") {
                        return hold(
                            Rule::AmbiguousShell,
                            format!("`{name} -c` runs a command string"),
                        );
                    }
                    1 + skip_options(rest, &["-p", "--package", "--from", "--with"])
                }
                "pnpm" | "yarn" | "npm" | "bun"
                    if rest
                        .first()
                        .is_some_and(|a| matches!(a.text.as_str(), "dlx" | "exec" | "x")) =>
                {
                    let j = skip_options(&rest[1..], &["-p", "--package", "-c", "--call"]);
                    if rest[1..]
                        .iter()
                        .take(j)
                        .any(|a| a.text == "-c" || a.text == "--call")
                    {
                        return hold(
                            Rule::AmbiguousShell,
                            format!("`{name} exec -c` runs a command string"),
                        );
                    }
                    2 + j
                }
                "pipx" if rest.first().is_some_and(|a| a.text == "run") => {
                    2 + skip_options(&rest[1..], &["--spec", "--python"])
                }
                _ => return Ok((Some(i), xargs)),
            };
            i += skip;
            if i >= words.len() {
                // a wrapper with nothing to run (`xargs` alone echoes)
                return Ok((None, xargs));
            }
        }
    }

    fn program(&mut self, name: &str, program: &Word, args: &[Word]) -> Check<Effect> {
        if self.dialect == Dialect::PowerShell {
            if let Some(effect) = self.powershell(name, args)? {
                return Ok(effect);
            }
        }
        if READ_ONLY.contains(&name) {
            return Ok(Effect::read_only());
        }
        if name.starts_with("python") || name == "py" || name.starts_with("pypy") {
            return self.python(program, args);
        }
        match name {
            "cd" | "pushd" | "chdir" => Ok(self.cd(args)),
            "popd" => Ok(Effect {
                read_only: true,
                chdir: Some(None),
                ..Effect::default()
            }),
            "export" | "declare" | "typeset" | "local" | "readonly" => {
                for a in args {
                    if let Some((n, v)) = a.text.split_once('=') {
                        if !n.starts_with('-') {
                            assignment(n, &a.with_text(v))?;
                        }
                    }
                }
                Ok(Effect::read_only())
            }
            "eval" | "trap" | "alias" | "watch" | "script" | "expect" | "parallel" | "at"
            | "batch" | "tmux" | "screen" => hold(
                Rule::AmbiguousShell,
                format!("`{name}` runs commands given as text"),
            ),
            "source" | "." => Ok(Effect {
                runs_file: args.first().cloned(),
                ..Effect::default()
            }),
            "sh" | "bash" | "zsh" | "dash" | "ksh" | "mksh" | "fish" | "csh" | "tcsh" | "ash"
            | "busybox" => shell_interpreter(name, args),
            "node" | "nodejs" => interpreter(
                name,
                args,
                &["-e", "--eval", "-p", "--print"],
                &["-r", "--require", "--import", "--input-type", "--loader"],
            ),
            "perl" => interpreter(name, args, &["-e", "-E"], &["-I", "-M", "-m"]),
            "ruby" => interpreter(name, args, &["-e"], &["-I", "-r"]),
            "php" => interpreter(name, args, &["-r"], &["-d", "-c", "-S", "-t"]),
            "lua" | "luajit" => interpreter(name, args, &["-e"], &["-l"]),
            "rscript" => interpreter(name, args, &["-e"], &[]),
            "osascript" => interpreter(name, args, &["-e"], &["-l"]),
            "deno" => deno(args),
            "pwsh" | "powershell" => powershell_interpreter(args),
            "cmd" => hold(Rule::AmbiguousShell, "`cmd` runs a command string"),
            "rm" | "unlink" => rm(args),
            "shred" | "srm" | "wipe" => {
                hold(Rule::RecursiveDelete, format!("`{name}` destroys files"))
            }
            "rmdir" | "mkdir" | "touch" | "mkfifo" | "mknod" => {
                Ok(Effect::writes(operands(args, &["-m", "--mode"])))
            }
            "truncate" => Ok(Effect::writes(operands(
                args,
                &["-s", "--size", "-r", "--reference"],
            ))),
            "chmod" | "chown" | "chgrp" | "chflags" | "setfacl" => {
                let ops = operands(args, &["--reference"]);
                Ok(Effect::writes(ops.into_iter().skip(1)))
            }
            "cp" | "ln" | "install" => Ok(copy_like(name, args)),
            "mv" => {
                let a = parse_args(args, "tS", &["--target-directory", "--suffix"]);
                let mut writes: Vec<Word> = a.operands.clone();
                writes.extend(a.value_of("-t").cloned());
                writes.extend(a.value_of("--target-directory").cloned());
                Ok(Effect::writes(writes))
            }
            "rsync" => rsync(args),
            "scp" => {
                if args.iter().any(|a| is_remote_spec(&a.text)) {
                    hold(Rule::RemoteShell, "`scp` copies to or from another machine")
                } else {
                    Ok(copy_like("cp", args))
                }
            }
            "ssh" | "mosh" | "sftp" | "telnet" => hold(
                Rule::RemoteShell,
                format!("`{name}` works on another machine"),
            ),
            "tee" => Ok(Effect::writes(operands(args, &[]))),
            "dd" => Ok(Effect::writes(args.iter().filter_map(|a| {
                a.text.strip_prefix("of=").map(|t| a.with_text(t))
            }))),
            "sed" | "gsed" => Ok(sed(args)),
            "sort" => {
                let a = parse_args(
                    args,
                    "oSTtk",
                    &[
                        "--output",
                        "--buffer-size",
                        "--temporary-directory",
                        "--field-separator",
                        "--key",
                    ],
                );
                let mut writes: Vec<Word> = a.value_of("-o").cloned().into_iter().collect();
                writes.extend(a.value_of("--output").cloned());
                Ok(if writes.is_empty() {
                    Effect::read_only()
                } else {
                    Effect::writes(writes)
                })
            }
            "uniq" => {
                let ops = operands(args, &["-f", "-s", "-w"]);
                Ok(match ops.get(1) {
                    Some(out) => Effect::writes([out.clone()]),
                    None => Effect::read_only(),
                })
            }
            "yq" => {
                let a = parse_args(args, "", &[]);
                if a.has("-i") || a.has("--inplace") {
                    Ok(Effect::writes(a.operands.into_iter().skip(1)))
                } else {
                    Ok(Effect::read_only())
                }
            }
            "tar" | "bsdtar" | "gtar" => Ok(tar(args)),
            "unzip" => {
                let a = parse_args(args, "dx", &[]);
                if a.has("-l") || a.has("-t") || a.has("-v") || a.has("-Z") {
                    return Ok(Effect::read_only());
                }
                Ok(match a.value_of("-d") {
                    Some(dir) => Effect::writes([dir.clone()]),
                    None => Effect::cwd(),
                })
            }
            "zip" => Ok(Effect::writes(
                operands(args, &["-b", "-n", "-t", "-x", "-i"])
                    .into_iter()
                    .take(1),
            )),
            "gzip" | "gunzip" | "bzip2" | "bunzip2" | "xz" | "unxz" | "zstd" | "unzstd" | "lz4" => {
                let a = parse_args(args, "", &[]);
                if a.has("-c") || a.has("--stdout") || a.has("-l") || a.has("-t") {
                    Ok(Effect::read_only())
                } else {
                    Ok(Effect::writes(a.operands))
                }
            }
            "patch" => {
                let a = parse_args(
                    args,
                    "opdiFrBDVYzg",
                    &["--output", "--directory", "--input"],
                );
                let mut writes: Vec<Word> = a.value_of("-o").cloned().into_iter().collect();
                writes.extend(a.value_of("-d").cloned());
                writes.extend(a.value_of("--directory").cloned());
                Ok(if writes.is_empty() {
                    Effect::cwd()
                } else {
                    Effect::writes(writes)
                })
            }
            "split" | "csplit" => Ok(Effect::cwd()),
            "curl" => Ok(curl(args)),
            "wget" => Ok(wget(args)),
            "fetch" | "aria2c" | "http" | "https" | "xh" | "lwp-request" => Ok(Effect {
                downloads: true,
                writes: vec![Target::Cwd],
                ..Effect::default()
            }),
            "find" | "gfind" => self.find(args),
            "git" => self.git(args),
            "gitch" | "gitsw" => self.gitch(args),
            "gh" => gh(args),
            "glab" => glab(args),
            "npm" | "pnpm" | "yarn" | "bun" => package_manager(name, args),
            "cargo" => cargo(args),
            "go" => go(args),
            "gem" => gem(args),
            "brew" | "port" | "apt" | "apt-get" | "yum" | "dnf" | "pacman" | "zypper" | "apk"
            | "snap" | "flatpak" | "choco" | "winget" | "scoop" | "nix-env" => {
                system_packages(name, args)
            }
            "pipx" | "rustup" | "nvm" | "fnm" | "pyenv" | "rbenv" | "asdf" | "mise" | "sdk"
            | "volta" | "corepack" => toolchains(name, args),
            "make" | "gmake" | "just" | "task" | "rake" | "mage" => self.make(name, args),
            "docker" | "podman" | "nerdctl" => self.docker(name, args),
            "security" | "ssh-keygen" | "ssh-add" | "ssh-copy-id" | "ssh-agent" | "op" | "bw"
            | "pass" | "keyring" | "cmdkey" | "vault" | "secret-tool" => hold(
                Rule::Credentials,
                format!("`{name}` reads or changes keys and passwords"),
            ),
            "gpg" | "gpg2" => gpg(args),
            _ if name.starts_with("git-credential") => hold(
                Rule::Credentials,
                format!("`{name}` reads or stores git credentials"),
            ),
            _ if name.starts_with("pip") => pip(program, args, self.env, self.cwd.as_ref()),
            _ => {
                if let Some(result) = deploy_tool(name, args) {
                    return result;
                }
                if let Some(result) = system_tool(name, args) {
                    return result;
                }
                Ok(Effect::default())
            }
        }
    }

    fn cd(&self, args: &[Word]) -> Effect {
        let target = args
            .iter()
            .find(|a| !(a.text.starts_with('-') && a.text.len() > 1 && !a.dynamic));
        let dir = match target {
            None => self.env.home.clone(),
            Some(w) if w.text == "-" => None,
            Some(w) => match resolve(w, self.cwd.as_ref(), self.env) {
                Resolved::Path(p) => Some(p),
                _ => None,
            },
        };
        Effect {
            read_only: true,
            chdir: Some(dir),
            ..Effect::default()
        }
    }

    fn python(&mut self, program: &Word, args: &[Word]) -> Check<Effect> {
        let mut i = 0;
        while let Some(a) = args.get(i) {
            let t = a.text.as_str();
            if t == "-c"
                || (t.starts_with('-')
                    && !t.starts_with("--")
                    && t[1..].ends_with('c')
                    && t.len() <= 4)
            {
                return hold(Rule::AmbiguousShell, "`python -c` runs inline code");
            }
            if t == "-m" || (t.starts_with("-m") && t.len() > 2 && !t.starts_with("--")) {
                let (module, rest) = if t == "-m" {
                    (
                        args.get(i + 1).map(|w| w.text.as_str()).unwrap_or(""),
                        &args[(i + 2).min(args.len())..],
                    )
                } else {
                    (&t[2..], &args[i + 1..])
                };
                return match module {
                    "pip" | "pip3" => pip(program, rest, self.env, self.cwd.as_ref()),
                    "twine" => {
                        if rest
                            .iter()
                            .any(|w| matches!(w.text.as_str(), "upload" | "register"))
                        {
                            hold(Rule::Deploy, "`twine upload` publishes a package")
                        } else {
                            Ok(Effect::default())
                        }
                    }
                    "venv" | "virtualenv" => Ok(Effect::writes(operands(
                        rest,
                        &["--prompt", "-p", "--python"],
                    ))),
                    _ => Ok(Effect::default()),
                };
            }
            if matches!(t, "-W" | "-X" | "-Q") {
                i += 2;
                continue;
            }
            if t == "-" {
                break;
            }
            if t.starts_with('-') && t.len() > 1 {
                i += 1;
                continue;
            }
            // the script and its own arguments
            return Ok(Effect {
                runs_file: Some(a.clone()),
                ..Effect::default()
            });
        }
        Ok(Effect {
            runs_stdin: true,
            ..Effect::default()
        })
    }

    fn find(&mut self, args: &[Word]) -> Check<Effect> {
        let root = args
            .iter()
            .take_while(|a| !(a.text.starts_with('-') || a.text == "(" || a.text == "!"))
            .last()
            .cloned()
            .unwrap_or_else(|| Word::plain("."));
        let mut effect = Effect::read_only();
        let mut i = 0;
        while let Some(a) = args.get(i) {
            match a.text.as_str() {
                "-delete" => {
                    return hold(
                        Rule::RecursiveDelete,
                        "`find -delete` deletes what it finds",
                    )
                }
                "-exec" | "-execdir" | "-ok" | "-okdir" => {
                    let end = args[i + 1..]
                        .iter()
                        .position(|w| w.text == ";" || w.text == "+")
                        .map_or(args.len(), |p| i + 1 + p);
                    let nested: Vec<Word> = args[i + 1..end]
                        .iter()
                        .map(|w| {
                            if w.text == "{}" {
                                {
                                    let mut w = root.with_text(format!("{}/*", root.text));
                                    w.glob = true;
                                    w
                                }
                            } else {
                                w.clone()
                            }
                        })
                        .collect();
                    self.words(&nested, false)?;
                    i = end + 1;
                    continue;
                }
                "-fprint" | "-fprint0" | "-fprintf" | "-fls" => {
                    if let Some(file) = args.get(i + 1) {
                        effect.read_only = false;
                        effect.writes.push(Target::Word(file.clone()));
                    }
                    i += 2;
                    continue;
                }
                _ => {}
            }
            i += 1;
        }
        Ok(effect)
    }

    fn make(&mut self, name: &str, args: &[Word]) -> Check<Effect> {
        let a = parse_args(
            args,
            "CfjloWI",
            &["--directory", "--file", "--jobs", "--makefile"],
        );
        for dir in a
            .value_of("-C")
            .into_iter()
            .chain(a.value_of("--directory"))
        {
            match resolve(dir, self.cwd.as_ref(), self.env) {
                Resolved::Path(p) if self.env.inside(&p) => {}
                _ => {
                    return hold(
                        Rule::OutsideRepoWrite,
                        format!("runs `{name}` in `{}`", dir.text),
                    )
                }
            }
        }
        for target in a.operands.iter().filter(|w| !w.text.contains('=')) {
            let t = target.text.to_lowercase();
            if matches!(t.as_str(), "install" | "uninstall") {
                return hold(
                    Rule::SystemInstall,
                    format!("`{name} {t}` installs outside the repository"),
                );
            }
            if matches!(t.as_str(), "push" | "ship" | "upload" | "promote") || deploy_named(&t) {
                return hold(
                    Rule::Deploy,
                    format!("`{name} {t}` looks like a deploy or release"),
                );
            }
        }
        Ok(Effect::default())
    }

    fn docker(&mut self, name: &str, args: &[Word]) -> Check<Effect> {
        let ops: Vec<&str> = args
            .iter()
            .filter(|a| !a.text.starts_with('-'))
            .map(|a| a.text.as_str())
            .collect();
        let sub = ops.first().copied().unwrap_or("");
        let second = ops.get(1).copied().unwrap_or("");
        let has = |f: &str| {
            args.iter()
                .any(|a| a.text == f || a.text.starts_with(&format!("{f}=")))
        };
        match sub {
            "login" | "logout" => {
                return hold(
                    Rule::Credentials,
                    format!("`{name} {sub}` changes registry credentials"),
                )
            }
            "push" => return hold(Rule::Deploy, format!("`{name} push` publishes an image")),
            "manifest" | "image" | "compose" if second == "push" || ops.contains(&"push") => {
                return hold(
                    Rule::Deploy,
                    format!("`{name} {sub} push` publishes images"),
                );
            }
            "buildx" | "build" if has("--push") => {
                return hold(
                    Rule::Deploy,
                    format!("`{name} {sub} --push` publishes an image"),
                );
            }
            "volume" if matches!(second, "rm" | "remove" | "prune") => {
                return hold(
                    Rule::RecursiveDelete,
                    "deletes Docker volumes and their data",
                );
            }
            "system" if second == "prune" => {
                return hold(
                    Rule::RecursiveDelete,
                    "`docker system prune` deletes containers, images and volumes",
                );
            }
            _ => {}
        }
        // host folders mounted into a container can be written from inside it
        let mut i = 0;
        while let Some(a) = args.get(i) {
            let t = a.text.as_str();
            let spec = if t == "-v" || t == "--volume" || t == "--mount" {
                i += 1;
                args.get(i).cloned()
            } else {
                t.strip_prefix("--volume=")
                    .or_else(|| t.strip_prefix("--mount="))
                    .map(|v| a.with_text(v))
            };
            if let Some(spec) = spec {
                let host = mount_source(&spec.text);
                if let Some(host) = host.filter(|h| {
                    h.contains(['/', '\\'])
                        || h.starts_with('.')
                        || h.starts_with('~')
                        || h.starts_with('$')
                }) {
                    let mut w = spec.with_text(host.clone());
                    w.tilde = host.starts_with('~');
                    self.write(&w)?;
                }
            }
            i += 1;
        }
        Ok(Effect::default())
    }
}

/// A file-name stem that says deploy, release or publish (`scripts/deploy.sh`).
pub(super) fn deploy_named(text: &str) -> bool {
    let file = text
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(text)
        .to_lowercase();
    let stem = file.split('.').next().unwrap_or(&file);
    stem.split(|c: char| !c.is_ascii_alphanumeric())
        .any(|part| {
            part.contains("deploy")
                || part.contains("release")
                || part.contains("publish")
                || part.contains("rollout")
                || matches!(part, "ship" | "upload" | "promote")
        })
}

/// The program's name without its folder or `.exe`, lower-cased.
fn program_name(text: &str) -> String {
    let base = text
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(text)
        .to_lowercase();
    base.strip_suffix(".exe")
        .map(str::to_string)
        .unwrap_or(base)
}

fn skip_options(words: &[Word], with_value: &[&str]) -> usize {
    let mut j = 0;
    while let Some(a) = words.get(j) {
        let t = a.text.as_str();
        if t == "--" {
            return j + 1;
        }
        if !t.starts_with('-') || t == "-" {
            break;
        }
        if with_value.contains(&t) {
            j += 2;
        } else {
            j += 1;
        }
    }
    j
}

/// Options and operands of a command. `short` lists short options that take a value,
/// `long` long ones; `--` ends the options.
pub(super) struct Args {
    pub(super) flags: Vec<String>,
    pub(super) values: Vec<(String, Word)>,
    pub(super) operands: Vec<Word>,
}

impl Args {
    pub(super) fn has(&self, flag: &str) -> bool {
        self.flags.iter().any(|f| f == flag)
    }

    pub(super) fn value_of(&self, flag: &str) -> Option<&Word> {
        self.values.iter().find(|(f, _)| f == flag).map(|(_, w)| w)
    }
}

pub(super) fn parse_args(args: &[Word], short: &str, long: &[&str]) -> Args {
    let mut out = Args {
        flags: Vec::new(),
        values: Vec::new(),
        operands: Vec::new(),
    };
    let mut i = 0;
    let mut done = false;
    while let Some(a) = args.get(i) {
        i += 1;
        let t = a.text.as_str();
        if done || a.dynamic || !t.starts_with('-') || t == "-" {
            out.operands.push(a.clone());
            continue;
        }
        if t == "--" {
            done = true;
            continue;
        }
        if let Some(long_name) = t.strip_prefix("--") {
            let (name, inline) = match long_name.split_once('=') {
                Some((n, v)) => (format!("--{n}"), Some(v.to_string())),
                None => (t.to_string(), None),
            };
            if let Some(v) = inline {
                out.values.push((name, a.with_text(v)));
            } else if long.contains(&name.as_str()) {
                if let Some(v) = args.get(i) {
                    out.values.push((name, v.clone()));
                    i += 1;
                }
            } else {
                out.flags.push(name);
            }
            continue;
        }
        let letters: Vec<char> = t[1..].chars().collect();
        for (k, c) in letters.iter().enumerate() {
            let flag = format!("-{c}");
            if short.contains(*c) {
                let rest: String = letters[k + 1..].iter().collect();
                if !rest.is_empty() {
                    out.values.push((flag, a.with_text(rest)));
                } else if let Some(v) = args.get(i) {
                    out.values.push((flag, v.clone()));
                    i += 1;
                }
                break;
            }
            out.flags.push(flag);
        }
    }
    out
}

fn operands(args: &[Word], with_value: &[&str]) -> Vec<Word> {
    let mut out = Vec::new();
    let mut i = 0;
    let mut done = false;
    while let Some(a) = args.get(i) {
        let t = a.text.as_str();
        if !done && t == "--" {
            done = true;
        } else if !done && !a.dynamic && t.starts_with('-') && t != "-" {
            if with_value.contains(&t) {
                i += 1;
            }
        } else {
            out.push(a.clone());
        }
        i += 1;
    }
    out
}

/// A `NAME=value` before a command, or exported.
fn assignment(name: &str, value: &Word) -> Check {
    let upper = name.to_ascii_uppercase();
    const SKIPS: &[&str] = &[
        "GITSW_SKIP",
        "GITCH_SKIP",
        "HUSKY",
        "HUSKY_SKIP_HOOKS",
        "SKIP",
        "LEFTHOOK",
        "LEFTHOOK_EXCLUDE",
        "OVERCOMMIT_DISABLE",
        "PRE_COMMIT_ALLOW_NO_CONFIG",
    ];
    if SKIPS.contains(&upper.as_str()) || upper.starts_with("GITSW_") {
        return hold(
            Rule::SkipChecks,
            format!("`{name}=` turns commit checks off"),
        );
    }
    if upper.starts_with("GIT_AUTHOR_") || upper.starts_with("GIT_COMMITTER_") {
        return hold(
            Rule::Credentials,
            format!("`{name}=` changes the commit author"),
        );
    }
    if upper.starts_with("GIT_CONFIG") {
        return hold(
            Rule::SkipChecks,
            format!("`{name}=` overrides git configuration"),
        );
    }
    if matches!(
        upper.as_str(),
        "GIT_SSH" | "GIT_SSH_COMMAND" | "GIT_ASKPASS" | "SSH_ASKPASS" | "SSH_AUTH_SOCK"
    ) {
        return hold(
            Rule::Credentials,
            format!("`{name}=` changes how git authenticates"),
        );
    }
    if matches!(
        upper.as_str(),
        "GIT_DIR" | "GIT_WORK_TREE" | "GIT_INDEX_FILE" | "GIT_OBJECT_DIRECTORY" | "GIT_COMMON_DIR"
    ) {
        return hold(
            Rule::AmbiguousShell,
            format!("`{name}=` points git at another repository"),
        );
    }
    if matches!(
        upper.as_str(),
        "GIT_EDITOR" | "GIT_SEQUENCE_EDITOR" | "EDITOR" | "VISUAL"
    ) && !matches!(value.literal(), Some("true" | ":" | "cat"))
    {
        return hold(
            Rule::AmbiguousShell,
            format!("`{name}=` runs `{}` as the editor", value.text),
        );
    }
    if matches!(
        upper.as_str(),
        "PATH"
            | "LD_PRELOAD"
            | "LD_LIBRARY_PATH"
            | "DYLD_INSERT_LIBRARIES"
            | "DYLD_LIBRARY_PATH"
            | "DYLD_FRAMEWORK_PATH"
            | "BASH_ENV"
            | "ENV"
            | "PROMPT_COMMAND"
            | "IFS"
            | "HOME"
            | "ZDOTDIR"
    ) {
        return hold(
            Rule::AmbiguousShell,
            format!("`{name}=` changes how commands are found or started"),
        );
    }
    Ok(())
}

/// A word naming a credential file, read or written.
fn credentials_in(word: &Word) -> Check {
    if paths::credential_parts(&paths::split_text(&word.text)) {
        return hold(
            Rule::Credentials,
            format!("`{}` holds credentials", word.text),
        );
    }
    Ok(())
}

/// Checks that a write lands inside the repository and not on credentials, agent settings
/// or git's own files.
pub(crate) fn check_path_write(word: &Word, cwd: Option<&AbsPath>, env: &Env) -> Check {
    let parts = paths::split_text(&word.text);
    if paths::credential_parts(&parts) {
        return hold(
            Rule::Credentials,
            format!("writes `{}`, which holds credentials", word.text),
        );
    }
    if paths::agent_settings_parts(&parts) {
        return hold(
            Rule::AgentSettings,
            format!("writes `{}`, which configures the agent", word.text),
        );
    }
    let path = match resolve(word, cwd, env) {
        Resolved::Null => return Ok(()),
        Resolved::Unknown(why) => {
            return hold(
                Rule::OutsideRepoWrite,
                format!("cannot tell where `{}` is ({why})", word.text),
            )
        }
        Resolved::Path(p) => p,
    };
    if paths::credential_parts(path.parts()) {
        return hold(
            Rule::Credentials,
            format!("writes `{}`, which holds credentials", path.display()),
        );
    }
    if paths::agent_settings_parts(path.parts()) {
        return hold(
            Rule::AgentSettings,
            format!("writes `{}`, which configures the agent", path.display()),
        );
    }
    let Some(root) = env.roots.iter().find(|root| path.starts_with(root)) else {
        return hold(
            Rule::OutsideRepoWrite,
            format!("writes `{}` outside the repository", path.display()),
        );
    };
    if paths::git_internal_parts(path.below(root).unwrap_or_default()) {
        return hold(
            Rule::GitInternals,
            format!("writes `{}` inside git's own folder", path.display()),
        );
    }
    Ok(())
}

pub(super) enum Resolved {
    Path(AbsPath),
    /// `/dev/null` and friends.
    Null,
    Unknown(&'static str),
}

pub(super) fn resolve(word: &Word, cwd: Option<&AbsPath>, env: &Env) -> Resolved {
    let raw = word.text.as_str();
    let lower = raw.to_lowercase();
    if matches!(
        lower.as_str(),
        "/dev/null" | "/dev/stdout" | "/dev/stderr" | "/dev/tty" | "nul" | "nul:" | "$null"
    ) || lower.starts_with("/dev/fd/")
    {
        return Resolved::Null;
    }
    let mut text = raw.to_string();
    if word.dynamic {
        // `$HOME`, `$PWD` and their PowerShell spellings name known folders; other values
        // are only known when the command runs
        let known = [
            ("${HOME}", env.home.as_ref()),
            ("$HOME", env.home.as_ref()),
            ("$env:USERPROFILE", env.home.as_ref()),
            ("$env:HOME", env.home.as_ref()),
            ("${PWD}", cwd),
            ("$PWD", cwd),
        ];
        for (var, base) in known {
            if let Some(rest) = text.strip_prefix(var) {
                let boundary = rest.is_empty() || rest.starts_with(['/', '\\']);
                if boundary && !rest.contains('$') {
                    return match base {
                        Some(b) => finish(b.join(&glob_prefix(rest, word.glob))),
                        None => Resolved::Unknown("the folder is unknown"),
                    };
                }
            }
        }
        return Resolved::Unknown("its value is only known when the command runs");
    }
    if word.glob {
        text = glob_prefix(&text, true);
    }
    if word.tilde {
        if text == "~" || text.starts_with("~/") || text.starts_with("~\\") {
            return match &env.home {
                Some(home) => finish(home.join(&text[1..])),
                None => Resolved::Unknown("the home folder is unknown"),
            };
        }
        return Resolved::Unknown("another user's home folder");
    }
    if env.windows {
        if let Some(p) = git_bash_drive(&text) {
            return Resolved::Path(p);
        }
    }
    if let Some(p) = AbsPath::parse(&text) {
        return Resolved::Path(p);
    }
    match cwd {
        Some(c) => Resolved::Path(c.join(if text.is_empty() { "." } else { &text })),
        None => Resolved::Unknown("the working folder is unknown"),
    }
}

fn finish(p: AbsPath) -> Resolved {
    Resolved::Path(p)
}

/// The folder part before the first wildcard: `src/*.rs` → `src/`.
fn glob_prefix(text: &str, glob: bool) -> String {
    if !glob {
        return text.to_string();
    }
    let cut = text.find(['*', '?', '[', '{']).unwrap_or(text.len());
    let head = &text[..cut];
    match head.rfind(['/', '\\']) {
        Some(sep) => head[..=sep].to_string(),
        None => String::new(),
    }
}

/// Git Bash spells `C:\x` as `/c/x`.
fn git_bash_drive(text: &str) -> Option<AbsPath> {
    let b = text.as_bytes();
    if b.len() >= 2 && b[0] == b'/' && b[1].is_ascii_alphabetic() && (b.len() == 2 || b[2] == b'/')
    {
        return AbsPath::parse(&format!(
            "{}:/{}",
            b[1] as char,
            text.get(3..).unwrap_or("")
        ));
    }
    None
}

fn is_remote_spec(text: &str) -> bool {
    if text.starts_with("rsync://") || text.starts_with("ssh://") {
        return true;
    }
    match text.find(':') {
        // `host:path`, not `C:\x` or `./a:b`
        Some(colon) => colon > 1 && !text[..colon].contains(['/', '\\']),
        None => false,
    }
}

fn mount_source(spec: &str) -> Option<String> {
    if spec.contains("source=") || spec.contains("src=") {
        return spec.split(',').find_map(|kv| {
            kv.strip_prefix("source=")
                .or_else(|| kv.strip_prefix("src="))
                .map(str::to_string)
        });
    }
    // `host:container[:mode]`; a Windows drive keeps its colon
    let b = spec.as_bytes();
    let start = if b.len() > 2 && b[1] == b':' && b[0].is_ascii_alphabetic() {
        2
    } else {
        0
    };
    spec[start..]
        .find(':')
        .map(|i| spec[..start + i].to_string())
}

fn rm(args: &[Word]) -> Check<Effect> {
    let a = parse_args(args, "", &[]);
    if a.has("-r") || a.has("-R") || a.has("--recursive") || a.has("-f") || a.has("--force") {
        return hold(
            Rule::RecursiveDelete,
            "`rm -r`/`rm -f` deletes without asking",
        );
    }
    Ok(Effect::writes(a.operands))
}

fn copy_like(name: &str, args: &[Word]) -> Effect {
    let a = parse_args(
        args,
        "tSmogC",
        &[
            "--target-directory",
            "--suffix",
            "--mode",
            "--owner",
            "--group",
        ],
    );
    if let Some(dir) = a
        .value_of("-t")
        .or_else(|| a.value_of("--target-directory"))
    {
        return Effect::writes([dir.clone()]);
    }
    if name == "install" && a.has("-d") {
        return Effect::writes(a.operands);
    }
    match a.operands.len() {
        0 => Effect::default(),
        1 => Effect::cwd(),
        _ => Effect::writes(a.operands.last().cloned()),
    }
}

fn rsync(args: &[Word]) -> Check<Effect> {
    let a = parse_args(
        args,
        "eTf",
        &[
            "--rsh",
            "--temp-dir",
            "--filter",
            "--exclude",
            "--include",
            "--exclude-from",
            "--include-from",
            "--files-from",
        ],
    );
    if a.flags
        .iter()
        .any(|f| f.starts_with("--delete") || f == "--remove-source-files")
    {
        return hold(
            Rule::RecursiveDelete,
            "`rsync --delete` deletes files at the destination",
        );
    }
    if a.operands.iter().any(|w| is_remote_spec(&w.text)) {
        return hold(
            Rule::RemoteShell,
            "`rsync` copies to or from another machine",
        );
    }
    Ok(match a.operands.len() {
        0 | 1 => Effect::default(),
        _ => Effect::writes(a.operands.last().cloned()),
    })
}

fn sed(args: &[Word]) -> Effect {
    let mut in_place = false;
    let mut script_given = false;
    let mut files: Vec<Word> = Vec::new();
    let mut i = 0;
    while let Some(a) = args.get(i) {
        let t = a.text.as_str();
        i += 1;
        if a.dynamic || !t.starts_with('-') || t == "-" {
            files.push(a.clone());
            continue;
        }
        if t.starts_with("--in-place") {
            in_place = true;
        } else if t == "-e" || t == "-f" || t == "--expression" || t == "--file" {
            script_given = true;
            i += 1;
        } else if t.starts_with("--expression=") || t.starts_with("--file=") {
            script_given = true;
        } else if !t.starts_with("--") {
            let letters = &t[1..];
            if let Some(pos) = letters.find('i') {
                in_place = true;
                // BSD sed takes the backup suffix as the next word (`-i ''`)
                if pos + 1 == letters.len()
                    && args
                        .get(i)
                        .is_some_and(|n| n.text.is_empty() || n.text.starts_with('.'))
                {
                    i += 1;
                }
            }
            if letters.contains('e') || letters.contains('f') {
                script_given = true;
                i += 1;
            }
        }
    }
    if !in_place {
        return Effect::read_only();
    }
    if !script_given && !files.is_empty() {
        files.remove(0);
    }
    Effect::writes(files)
}

fn tar(args: &[Word]) -> Effect {
    // the first word may bundle the mode without a dash: `tar xzf a.tgz`
    let mut words: Vec<Word> = args.to_vec();
    if let Some(first) = words.first_mut() {
        if !first.text.starts_with('-') && first.text.chars().all(|c| c.is_ascii_alphabetic()) {
            first.text = format!("-{}", first.text);
        }
    }
    let a = parse_args(
        &words,
        "fCbHT",
        &["--file", "--directory", "--exclude", "--files-from"],
    );
    let create = a.has("-c")
        || a.has("-r")
        || a.has("-u")
        || a.has("-A")
        || a.has("--create")
        || a.has("--append");
    let extract = a.has("-x") || a.has("--extract") || a.has("--get");
    let file = a.value_of("-f").or_else(|| a.value_of("--file")).cloned();
    if create {
        return match file.filter(|f| f.text != "-") {
            Some(f) => Effect::writes([f]),
            None => Effect::default(),
        };
    }
    if extract {
        return match a.value_of("-C").or_else(|| a.value_of("--directory")) {
            Some(dir) => Effect::writes([dir.clone()]),
            None => Effect::cwd(),
        };
    }
    Effect::read_only()
}

fn curl(args: &[Word]) -> Effect {
    let a = parse_args(
        args,
        "oDcdHXuTFeAxKwmryYzECbQUP",
        &[
            "--output",
            "--dump-header",
            "--cookie-jar",
            "--trace",
            "--trace-ascii",
            "--etag-save",
            "--libcurl",
            "--output-dir",
            "--data",
            "--data-raw",
            "--data-binary",
            "--data-urlencode",
            "--header",
            "--request",
            "--user",
            "--upload-file",
            "--form",
            "--referer",
            "--user-agent",
            "--proxy",
            "--config",
            "--write-out",
            "--max-time",
            "--range",
            "--cookie",
            "--cert",
            "--key",
            "--cacert",
            "--connect-timeout",
            "--retry",
            "--retry-delay",
            "--resolve",
            "--url",
        ],
    );
    let mut effect = Effect {
        downloads: true,
        ..Effect::default()
    };
    for flag in [
        "-o",
        "--output",
        "-D",
        "--dump-header",
        "-c",
        "--cookie-jar",
        "--trace",
        "--trace-ascii",
        "--etag-save",
        "--libcurl",
    ] {
        for (f, w) in &a.values {
            if f == flag && w.text != "-" {
                effect.writes.push(Target::Word(w.clone()));
            }
        }
    }
    if a.has("-O") || a.has("--remote-name") || a.has("--remote-name-all") || a.has("-J") {
        match a.value_of("--output-dir") {
            Some(dir) => effect.writes.push(Target::Word(dir.clone())),
            None => effect.writes.push(Target::Cwd),
        }
    }
    // without a file to write, curl only prints
    effect.read_only = effect.writes.is_empty();
    effect
}

fn wget(args: &[Word]) -> Effect {
    let a = parse_args(
        args,
        "OPoaeiBUtTwlA",
        &[
            "--output-document",
            "--directory-prefix",
            "--output-file",
            "--append-output",
        ],
    );
    let mut effect = Effect {
        downloads: true,
        ..Effect::default()
    };
    let document = a.value_of("-O").or_else(|| a.value_of("--output-document"));
    for flag in ["-o", "--output-file", "-a", "--append-output"] {
        if let Some(w) = a.value_of(flag) {
            effect.writes.push(Target::Word(w.clone()));
        }
    }
    match document {
        Some(w) if w.text == "-" => {}
        Some(w) => effect.writes.push(Target::Word(w.clone())),
        None => match a
            .value_of("-P")
            .or_else(|| a.value_of("--directory-prefix"))
        {
            Some(dir) => effect.writes.push(Target::Word(dir.clone())),
            None => effect.writes.push(Target::Cwd),
        },
    }
    effect.read_only = effect.writes.is_empty();
    effect
}

fn shell_interpreter(name: &str, args: &[Word]) -> Check<Effect> {
    let mut i = 0;
    while let Some(a) = args.get(i) {
        let t = a.text.as_str();
        if t == "--" {
            i += 1;
            break;
        }
        if t.starts_with("--") {
            i += if matches!(t, "--rcfile" | "--init-file") {
                2
            } else {
                1
            };
            continue;
        }
        if (t.starts_with('-') || t.starts_with('+')) && t.len() > 1 {
            let letters = &t[1..];
            if letters.contains('c') {
                return hold(
                    Rule::AmbiguousShell,
                    format!("`{name} -c` runs a command string"),
                );
            }
            if letters.contains('s') {
                return Ok(Effect {
                    runs_stdin: true,
                    ..Effect::default()
                });
            }
            i += if letters.ends_with('o') || letters.ends_with('O') {
                2
            } else {
                1
            };
            continue;
        }
        break;
    }
    match args.get(i) {
        Some(script) => Ok(Effect {
            runs_file: Some(script.clone()),
            ..Effect::default()
        }),
        None => Ok(Effect {
            runs_stdin: true,
            ..Effect::default()
        }),
    }
}

fn interpreter(name: &str, args: &[Word], inline: &[&str], with_value: &[&str]) -> Check<Effect> {
    let mut i = 0;
    while let Some(a) = args.get(i) {
        let t = a.text.as_str();
        if inline.contains(&t)
            || inline
                .iter()
                .any(|f| f.starts_with("--") && t.starts_with(&format!("{f}=")))
        {
            return hold(
                Rule::AmbiguousShell,
                format!("`{name} {t}` runs inline code"),
            );
        }
        if t == "-" {
            break;
        }
        if t.starts_with('-') && t.len() > 1 {
            // a cluster such as `perl -pe`
            if !t.starts_with("--")
                && inline
                    .iter()
                    .any(|f| f.len() == 2 && t[1..].contains(&f[1..]))
            {
                return hold(
                    Rule::AmbiguousShell,
                    format!("`{name} {t}` runs inline code"),
                );
            }
            i += if with_value.contains(&t) { 2 } else { 1 };
            continue;
        }
        return Ok(Effect {
            runs_file: Some(a.clone()),
            ..Effect::default()
        });
    }
    Ok(Effect {
        runs_stdin: true,
        ..Effect::default()
    })
}

fn deno(args: &[Word]) -> Check<Effect> {
    match args
        .iter()
        .find(|a| !a.text.starts_with('-'))
        .map(|a| a.text.as_str())
    {
        Some("eval") | None => hold(Rule::AmbiguousShell, "`deno eval` runs inline code"),
        Some("install") => hold(
            Rule::SystemInstall,
            "`deno install` installs outside the repository",
        ),
        Some("publish") => hold(Rule::Deploy, "`deno publish` publishes a package"),
        _ => Ok(Effect::default()),
    }
}

fn powershell_interpreter(args: &[Word]) -> Check<Effect> {
    let mut i = 0;
    while let Some(a) = args.get(i) {
        let t = a.text.to_lowercase();
        if matches!(
            t.as_str(),
            "-c" | "-command" | "-encodedcommand" | "-e" | "-ec" | "-enc"
        ) {
            return hold(Rule::AmbiguousShell, "PowerShell runs a command string");
        }
        if matches!(t.as_str(), "-file" | "-f") {
            return Ok(Effect {
                runs_file: args.get(i + 1).cloned(),
                ..Effect::default()
            });
        }
        if !t.starts_with('-') {
            return Ok(Effect {
                runs_file: Some(a.clone()),
                ..Effect::default()
            });
        }
        i += 1;
    }
    hold(Rule::AmbiguousShell, "PowerShell starts without a script")
}

/// Programs that change the files named in their operands.
const OPERAND_WRITERS: &[&str] = &[
    "rm", "unlink", "rmdir", "mv", "cp", "ln", "install", "touch", "mkdir", "chmod", "chown",
    "chgrp", "truncate", "tee", "sed", "gsed", "dd", "shred",
];

/// Programs that only read (or print), so they may run anywhere.
const READ_ONLY: &[&str] = &[
    "ls",
    "ll",
    "la",
    "cat",
    "bat",
    "head",
    "tail",
    "less",
    "more",
    "grep",
    "egrep",
    "fgrep",
    "rg",
    "ag",
    "ack",
    "fd",
    "pwd",
    "echo",
    "printf",
    "wc",
    "diff",
    "cmp",
    "comm",
    "file",
    "stat",
    "which",
    "whereis",
    "type",
    "du",
    "df",
    "tree",
    "jq",
    "date",
    "printenv",
    "uname",
    "whoami",
    "id",
    "groups",
    "hostname",
    "test",
    "[",
    "[[",
    "true",
    "false",
    ":",
    "sleep",
    "basename",
    "dirname",
    "realpath",
    "readlink",
    "cut",
    "tr",
    "xxd",
    "od",
    "hexdump",
    "strings",
    "md5",
    "md5sum",
    "shasum",
    "sha1sum",
    "sha256sum",
    "sha512sum",
    "b2sum",
    "cksum",
    "base64",
    "ps",
    "pgrep",
    "lsof",
    "uptime",
    "sw_vers",
    "system_profiler",
    "mdfind",
    "mdls",
    "cal",
    "seq",
    "column",
    "fold",
    "nl",
    "paste",
    "join",
    "tac",
    "rev",
    "expand",
    "unexpand",
    "fmt",
    "look",
    "nproc",
    "getconf",
    "locale",
    "tput",
    "man",
    "help",
    "info",
    "apropos",
    "whatis",
    "otool",
    "nm",
    "objdump",
    "ldd",
    "read",
    "set",
    "shopt",
    "unset",
    "hash",
    "ulimit",
    "umask",
    "wait",
    "jobs",
    "fg",
    "bg",
    "kill",
    "exit",
    "return",
    "shift",
    "getopts",
    "let",
    "expr",
    "bc",
    "dc",
    "zcat",
    "gzcat",
    "zgrep",
    "bzcat",
    "xzcat",
    "iconv",
    "pbpaste",
    "say",
    "env",
    "tty",
    "lsblk",
    "free",
    "vm_stat",
    "sw_vers",
    "arch",
    "uname",
    "logname",
    "users",
    "w",
    "who",
];
