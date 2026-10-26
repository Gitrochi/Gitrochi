# Contributing

Thank you for your interest in Gitrochi. Report bugs and request features in [issues](https://github.com/Gitrochi/Gitrochi/issues/new/choose); send code as pull requests. Issues, pull requests and discussion are in English.

The rules live in `docs/`. Coding agents read the same rules from [AGENTS.md](AGENTS.md) (Codex and others) and [CLAUDE.md](CLAUDE.md) (Claude Code).

## Contributors

- [ChoMnSeong](https://github.com/ChoMnSeong)
- [jjunhaa0211](https://github.com/jjunhaa0211) — gitch CLI, multi-language structure analysis, app integration and verification

The copyright holders are named in the [MIT license](LICENSE).

## Getting started

| | macOS | Windows |
|---|---|---|
| Where | `macos/` (SwiftUI, macOS 15+) | `windows/` (Tauri 2: Rust + React/TypeScript) |
| Needs | Swift 6 or later (Xcode or Command Line Tools) | Node.js 22, Rust stable |
| Build | `macos/build.sh` | `cd windows && npm ci && npx tauri build` |
| Check | builds with no errors or warnings | `npx tsc --noEmit -p .` · `npx vitest run` · `cargo check` |

- After cloning, run `git config core.hooksPath .githooks` once: the hooks check the Git rules when you commit and push.
- The Windows app runs on a Mac too: `npx tauri dev` (its data folder is separate, `Gitrochi (Tauri)`).
- Changed a screen? Check it with the demo repository (`docs/make-demo-repo.sh <folder>`) and attach light and dark screenshots to the pull request.
- The tests for the bundled helpers (gitch, gitch-swift-index) and the version check are in [docs/code-style.md](docs/code-style.md#tests-and-verification).

## Rules

- [docs/code-style.md](docs/code-style.md) — layout, both platforms together, code rules (Swift · TypeScript · Rust · comments · performance), screen text and translations, privacy and secrets, tests
- [docs/git-workflow.md](docs/git-workflow.md) — branches, commit messages, pull requests, what never goes into a commit
- [AGENTS.md](AGENTS.md) · [CLAUDE.md](CLAUDE.md) — the same rules, summarized for coding agents

The ones to remember:

- **A feature goes into both the macOS and the Windows app.** If it can only work on one, say why in the pull request.
- **Commit subjects are `Area: Summary`** — English, imperative, and the area is required. Examples: `Graph: Show avatars in the inspector`, `Terminal: Type dropped files as paths`. A feature done on both sides takes its own area (`Graph`, `Sidebar` …); a fix for one platform takes `macOS` or `Windows`.
- **Screen text is English in the code.** A new string gets its Korean (`ko`) translation, and as many of the other languages as you can, in the same pull request.
- **Comments are English, short, and say why.** Older Korean comments are being converted over time.
- **Tokens live only in the Keychain or the Credential Manager.** No company or person names, internal hostnames or paths on your machine in a commit.

## Pull requests

1. Branch from `main` (`feature/…`, `fix/…`, `docs/…`). One topic per pull request.
2. Pass the checks above (build · `tsc` · `vitest` · `cargo check`). Changed a screen? Attach light and dark screenshots.
3. Fill in the pull request template's checklist. CI (the Windows self-test and the Git rules) must pass before merging.
4. Merge with a merge commit, so each pull request stays one unit in the history. `gh pr merge --auto --merge` merges as soon as the checks pass and deletes the branch.

The details — collaborator permissions, stacked pull requests, fixing a pull request the checks rejected, what the Windows CI does — are in [docs/git-workflow.md](docs/git-workflow.md).

## Releases

Maintainers only: [docs/release.md](docs/release.md).
