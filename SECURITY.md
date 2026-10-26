# Security policy

Gitrochi is a desktop Git client for macOS and Windows. It runs `git` on your machine, talks to GitHub and GitLab with tokens you connect, calls AI providers with keys you enter, and runs coding agents (Claude Code, Codex, Gemini) in its built-in terminal. This policy covers the macOS app, the Windows app and the `gitch` CLI that ships with them.

## Reporting a vulnerability

**Please don't report a security problem in a public issue, discussion or pull request.**

Report it privately through GitHub instead: open this repository's [Security tab](https://github.com/Gitrochi/Gitrochi/security) and click **Report a vulnerability** ([direct link](https://github.com/Gitrochi/Gitrochi/security/advisories/new)). Only you and the maintainers can see the report and what follows. If private reporting is not available to you, contact a maintainer through the contact details on their GitHub profile ([ChoMnSeong](https://github.com/ChoMnSeong)), and don't post exploit details anywhere public while you look for a channel.

It helps to include, as far as you can:

- what the problem is, and what an attacker could do with it;
- which product (macOS app, Windows app or `gitch`), its version, and your OS version;
- how to reproduce it: a small repository, a branch or file name, a remote, a pull request — whatever triggers it;
- a proof of concept, screenshots or logs, with tokens, hostnames and other personal data removed.

## What to expect

- We aim to acknowledge a report within 5 business days.
- After triage we keep you updated, agree with you on when the problem becomes public, and ship the fix in a new release.
- Confirmed vulnerabilities are published as GitHub Security Advisories. Valid reports are credited in the advisory and the release notes, unless you'd rather stay anonymous.
- Please keep the report confidential until the agreed disclosure date.

## Supported versions

Security fixes go into the **latest release** only, so please update before you report. Both apps check for updates on their own; keep that on.

| Product | Supported |
|---|---|
| macOS app | The latest [release](https://github.com/Gitrochi/Gitrochi/releases/latest) |
| Windows app | The latest release |
| `gitch` CLI | The one in the latest release (`gitch self-update`) |

Pre-release builds and the current `main` branch get best-effort support: if you can reproduce the problem there, please say so.

## Scope

We especially want to hear about:

- a token or key leaving your machine — GitHub and GitLab tokens, AI API keys, agent credentials belong in the macOS Keychain or the Windows Credential Manager and nowhere else (settings files, logs, error messages);
- commands or code running because of what is in a repository (branch, tag, file and remote names, file contents, commit messages, `.git/config`, hooks) or because of what comes from GitHub or GitLab (a pull request's or issue's title, body, comments, labels, CI logs);
- anything that escapes the Windows webview or the Tauri bridge to its Rust side, or that bypasses the macOS app's permission prompts;
- an update, download or install that can be made to fetch or run something else, including a way around the update signature check;
- a destructive Git operation (force push, reset, branch deletion, discarding changes) that runs without the confirmation the app promises;
- a coding agent started from the app with more access than the user chose.

Out of scope: problems that need a program already running as you, physical access to an unlocked computer, social engineering, and vulnerabilities in Git, the operating system, GitHub, GitLab, the AI providers or the agents themselves. Report those to them, and tell us if Gitrochi makes one easier to reach.

## Privacy

Gitrochi sends data only to services you connect or choose, and only what they need:

- GitHub and GitLab, with your token, for pull requests, CI and reviews;
- the AI provider you picked (Anthropic, OpenAI or Gemini), with your key, when you send a question, ask for a summary, commit message or explanation, or use repository assistance — the previewed snapshot and any permitted, bounded repository reads are sent;
- author pictures from GitHub or GitLab for connected accounts, otherwise from Gravatar by a hash of the author's email;
- GitHub Releases, without a token, to check for updates.

Tokens and keys are kept in the macOS Keychain or the Windows Credential Manager. There is no telemetry and no crash reporting.
