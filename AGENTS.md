# Rules for coding agents

For AI coding agents working in this repository — Codex, Claude Code, Gemini CLI and others. They are the same rules human contributors follow; the details are in `docs/`, read them before you change anything:

- [docs/code-style.md](docs/code-style.md) — layout, both platforms together, code rules, screen text and translations, privacy, tests
- [docs/git-workflow.md](docs/git-workflow.md) — branches, commit messages, pull requests, what never goes into a commit
- [CONTRIBUTING.md](CONTRIBUTING.md) — getting started; [docs/release.md](docs/release.md) — releases (maintainers only)

## The short version

1. **English in everything that goes into the repository.** Issues, pull requests, commit messages, code, comments and docs are English; only the app's translations are in other languages. Talk to the person running you in whatever language they use.
2. **Both platforms.** A feature goes into `macos/` (SwiftUI) and `windows/` (Tauri: Rust + React/TypeScript), with mirrored names. If it can only work on one, say why in the pull request.
3. **Branch from `main`**, named `feature/…`, `fix/…`, `refactor/…`, `docs/…` or `ci/…`. Never push to `main`; open a pull request with the template filled in. A change that depends on an open pull request is stacked on that branch.
4. **Commit subjects are `Area: Imperative summary`.** The area is required (`Graph`, `Sidebar`, `Terminal`, `Inspector`, `CI/CD`, `Agents`, `Settings`, `i18n`, `Docs`, `CI`, `gitch`; `macOS` or `Windows` only for a platform-specific change). Bullets in the body say why. One topic per commit, every commit builds. The hook in `.githooks` enforces this; run `git config core.hooksPath .githooks` once.
5. **Verify before you hand over, and say what you ran.** macOS: `macos/build.sh` with no errors or warnings. Windows: `npx tsc --noEmit -p .`, `npx vitest run`, `cargo check` (skip `cargo check` only when Rust is untouched, and say so). Pure logic gets a unit test in `windows/tests/`; new Windows UI gets a step in `windows/src/app/selftest.ts`.
6. **Screen text is English in the code** and is the translation key. Add every new string to `ko` and to as many of the other 18 locales as you can, in the same change (`macos/Resources/Localizations/*.lproj/Localizable.strings`, `windows/src/shared/i18n/locales/*.json`). Remove strings nobody uses any more.
7. **Comments are English, short, and about why.** Older Korean comments stay unless the file is being rewritten.
8. **Secrets and privacy.** Tokens only in the Keychain or the Credential Manager. No real names, internal hostnames, personal emails or home paths (`/Users/<name>`) in code, tests, docs or commit messages.
9. **Git is the system `git`.** Don't reimplement it; parse machine-readable output in `Parsers`.
10. **Don't widen the scope.** Do what was asked, in the smallest change that does it well; leave unrelated tidying for its own pull request.
11. **Your session may be running inside Gitrochi's own terminal** (`TERM_PROGRAM=Gitrochi`). Then never run `macos/build.sh install`, relaunch or quit the app — it ends your session. Build to `macos/build/Gitrochi.app`, and leave installing to the maintainer.

## Pull request text

Use `.github/PULL_REQUEST_TEMPLATE.md`, in English, whatever language you talk to your user in. Tick only the checklist items you actually did, and name the checks you could not run. End the description with the attribution line your tool gives you.
