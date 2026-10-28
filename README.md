<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Gitrochi icon">
</p>

<h1 align="center">Gitrochi</h1>

<p align="center">
  <b>A Git client that shows your history as a graph and works by clicking.</b><br>
  macOS · Windows
</p>

<p align="center">
  English · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <a href="https://github.com/Gitrochi/Gitrochi/releases/latest"><img src="https://img.shields.io/github/v/release/Gitrochi/Gitrochi?label=latest&color=2f6fec" alt="Latest release"></a>
  <a href="https://github.com/Gitrochi/Gitrochi/releases"><img src="https://img.shields.io/github/downloads/Gitrochi/Gitrochi/total?label=downloads&color=2a9a55" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Windows-10%20%C2%B7%2011-0078d4?logo=windows&logoColor=white" alt="Windows 10 · 11">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Community%20Use%20v1.0%20proposed-6b6b72" alt="Community Use v1.0 proposed"></a>
</p>

<p align="center">
  <a href="https://github.com/Gitrochi/Gitrochi/releases/latest"><b>⬇&nbsp; Download</b></a>
  &nbsp;·&nbsp; <a href="docs/features.md">Usage and features</a>
  &nbsp;·&nbsp; <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" alt="Gitrochi main window — branches and tags on the left, the commit graph in the middle, uncommitted changes and the commit box on the right">
  </picture>
</p>

Gitrochi is a native Git client for macOS and Windows. It draws your history as a readable commit graph and lets you stage, commit, branch, merge and review by clicking, with GitHub and GitLab, CI/CD, AI-written commit messages, coding agents and a terminal built in. Git itself does the work: Gitrochi calls your system `git`.

## Features

- **Commit graph** — every branch in its lane color, branches and tags in their own column, author pictures, CI status, and the uncommitted changes of every worktree at the top
- **Stage and commit** — by file, hunk or line; unified or side-by-side diff with word-level highlighting and image comparison; conflict resolution; tidy commits (squash, reorder, reword); undo the last operation
- **Branches by drag and drop** — drop a branch on a commit to merge, rebase or fast-forward; drop a commit on a branch to cherry-pick
- **GitHub and GitLab** — pull and merge requests reviewed, approved and created in the app, with Markdown; self-hosted GitLab too
- **CI/CD** — GitLab pipelines and GitHub Actions: run manual jobs, rerun, cancel, approve deployments, trigger workflows
- **AI** — Claude Code, Codex, Gemini CLI or an API key writes commit messages and pull request text by your team's rules, and splits changes into commits by topic
- **Coding agents** — Claude Code, Codex and Gemini CLI sessions per worktree, running in the built-in terminal, with their state in the sidebar
- **Terminal** — shells in the repository folder below the graph, in tabs and split panes; the graph refreshes as you run git commands
- **gitch** — the bundled CLI keeps several Git accounts apart per repository and blocks the wrong author, secrets and force pushes in hooks
- **Flows** — assemble a repository's tests, checks, services and deploy steps in `.gitch/flow.yml` and run them the same way from the app, `gitch flow`, before a push or in CI: on this machine, in Docker, or through GitLab CI, GitHub Actions and Jenkins, rolled back when a step fails

- **Repository screen** — branches, the graph with the terminal underneath and the changes or commit details side by side; Compare, Rebase and Code as pages; the page list folds into an icon rail
- **Review and advanced Git tools** — review the account, destination and outgoing changes before pushing; draft line comments and batch reviews; compare revisions, select several commits, edit three-way conflicts, browse recovery history, LFS, submodules and bisect
- **Connected work** — PR/MR management, issues, actions and one Account page for the inbox, releases, projects and organizations; the account control in the toolbar; AI questions about selected changes, repository reading tools and a local read-only MCP server
- **Shared Rust core** — parsing, diff, patches, conflicts and graph calculations shared by both apps, with cancellable background calculations; commit searches ignore spacing
- **Repository index** — the whole history, each commit's file changes and which files change together, kept in SQLite by the shared Rust code with a C++ tokenizer for code identifiers and Korean, Japanese and Chinese text; the search bar answers from it, and the Python tools (AI review, analysis, test planning, runtimes) and the Go team hub and monitor build on it

The full list, with usage and shortcuts: [docs/features.md](docs/features.md).

## Implementation and verification

[Which language does what](docs/architecture.md) explains the parts and their contracts. [Review workflows](docs/review-workflows-validation.md), [extended workflows](docs/complete-workflows-validation.md), [workspace navigation](docs/navigation-workspace-validation.md) (Korean), the [shared core](crates/README.md) and the [repository index](crates/gitrochi-index/README.md) document the implementation and checks. Local fixtures and simulated services cover these flows; Windows installation on a real device, live LFS locks and real-server writes still need environment-specific verification. Repository AI and MCP require Node.js 22+; LFS operations require Git LFS.

## Install

**macOS 15 or later** (Apple Silicon and Intel): download the `.dmg` from the [latest release](https://github.com/Gitrochi/Gitrochi/releases/latest) and move `Gitrochi.app` to Applications. The build is not notarized yet, so allow it under **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Gitrochi.app`. Needs `git` (Xcode or `xcode-select --install`).

**Windows 10 (1809) or later, x64**: download `Gitrochi_<version>_x64-setup.exe` from the [latest release](https://github.com/Gitrochi/Gitrochi/releases/latest) and run it (`_portable.zip` needs no install). If SmartScreen blocks it: **More info → Run anyway**. Needs [Git for Windows](https://git-scm.com/download/win).

Both apps update themselves: they check for a new version at launch and once a day, and install it only when its signature and hash match.

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md) — getting started, building, pull requests
- [docs/code-style.md](docs/code-style.md) and [docs/git-workflow.md](docs/git-workflow.md) — the rules for code, commits and branches
- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — the same rules for coding agents

## Feedback

- 🐞 [Report a bug](https://github.com/Gitrochi/Gitrochi/issues/new?template=bug_report.yml) · ✨ [Request a feature](https://github.com/Gitrochi/Gitrochi/issues/new?template=feature_request.yml) · 💬 [Ask a question](https://github.com/Gitrochi/Gitrochi/issues/new?template=question.yml)
- Security problems go [privately](SECURITY.md), not into an issue

## License

[Gitrochi Community Use License v1.0](LICENSE) is **proposed and not yet in effect**. It would allow free personal and business use, restrict unauthorized resale and the distribution of independent derivative projects, and take contributions through pull requests to the official repository. The rights-holder consents and legal details it needs are tracked in the [licensing review](docs/licensing-review.md) (Korean).

© 2026 ChoMnSeong, [jjunhaa0211](https://github.com/jjunhaa0211). The standalone MIT license file and the MIT labels have been removed; the rights already granted for code provided under MIT, and the [notice that material requires](THIRD_PARTY_NOTICES.md#prior-mit-covered-gitrochi-material), remain. Even once adopted, the policy is source-available with distribution restrictions, not an open-source license.

Bundled: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). The Windows app builds on [Tauri](https://tauri.app), [React](https://react.dev), [xterm.js](https://xtermjs.org), [portable-pty](https://github.com/wezterm/wezterm) and [Lucide](https://lucide.dev), each under its own license, which the proposal does not restrict — see the [third-party notices and dependency review](THIRD_PARTY_NOTICES.md). The full notice review of the Rust dependencies per release target is not finished.
