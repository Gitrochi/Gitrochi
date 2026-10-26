# Code style and structure

The rules every change to Gitrochi follows, for people and for coding agents alike. Branches, commit messages and pull requests are in [git-workflow.md](git-workflow.md); getting started is in [CONTRIBUTING.md](../CONTRIBUTING.md) and the release process in [release.md](release.md).

## Layout

```
macos/Sources/
  App/       app, windows, tabs, updates, theme
  Core/      running git (Git.swift), parsing its output (Parsers), graph layout (Graph), models, file watching
  Store/     RepoStore (one tab's state) + extensions per feature: RepoStore+Actions, +Selection, +CI …
  Services/  GitHub and GitLab (Hosting), CI/CD, AI, accounts, agents, tools, avatars, terminal sessions
  Views/     Graph · Sidebar · Inspector · Settings · Sheets · Shared
windows/src/            Feature-Sliced Design — a layer imports only the layers below it
  app/       start-up (main, start), tab shell, shortcuts, global styles, self-test
  pages/     repo (repository screen) · welcome
  widgets/   commit-graph · diff-viewer · inspector · sidebar · toolbar · tab-bar · terminal-panel · settings · dialog-host · update-dialog
  features/  one user action each: create-branch · create-tag · stash-changes · clone-repo · add-worktree · create-pull-request ·
             interactive-rebase · split-commits · resolve-conflict · run-pipeline · start-agent · git-menus (context menus)
  entities/  git (models, parsers, graph, diff) · repo (RepoStore) · hosting · ci · ai · agent · terminal · avatar · workspace
  shared/    api (ipc) · config (env, settings) · platform (git, tools, WSL, updates) · i18n · lib · ui (base parts, theme) · assets
windows/src-tauri/src/  processes, pty, file watching, HTTP, credentials (Rust)
```

Windows folder rules (`windows/tests/architecture.test.ts` fails when they are broken):

- Layers go `app → pages → widgets → features → entities → shared`. Import **only from below**, never from another slice of the same layer (entities may import entities; `shared` segments may import each other).
- Import another slice **through its public API** (`index.ts`): `import { Sidebar } from "@/widgets/sidebar"`. Inside a slice use relative paths.
- An `index.ts` re-exports by name only what other slices use. No `export *`.
- Files in a slice sit in a segment folder: `ui/` (screens, CSS) · `model/` (state) · `api/` (external calls) · `lib/` (pure functions) · `config/`.
- No cycles between slices. When a lower slice needs something from a higher one, put a small interface in the lower slice (`CIHost`, `AgentHost`).
- Styles live in the slice's `ui/*.css` (`import "./x.css"` from the component). Color and font tokens and layout helpers are in `app/styles/global.css`.

## Both platforms, together

- **A feature goes into both the macOS and the Windows app.** If it can only work on one, say why in the pull request.
- Mirror names and the way things are split: `RepoStore+CI.swift` ↔ `entities/ci/model/store.ts`, `Views/Sheets/NewBranchSheet.swift` ↔ `features/create-branch/ui/NewBranchSheet.tsx`. Reading one side should lead you to the other. When a pure piece of logic is shared in shape, say so in a comment on both sides (`// macOS: …`, `// Windows: …`).
- Don't reimplement Git. **Call the system `git`** (macOS `Git.run`, Windows `git()` / `this.g()`), ask for machine-readable output (`--porcelain=v2 -z`, `--format=…%x1f…`) and parse it in `Parsers`.

## Code

- **Indentation**: Swift and Rust 4 spaces; TypeScript, JSON, CSS and YAML 2 spaces. LF line endings, a newline at the end of every file ([`.editorconfig`](../.editorconfig)).
- **Swift**
  - State is a `@MainActor @Observable final class`. View state uses `@ViewState` instead of `@State` (an alias, because the macro is broken in some Command Line Tools).
  - Heavy work (graph layout and the like) runs off the main thread in `Task.detached`.
  - `private` by default; widen only when an extension in another file needs it.
  - The app is built with `swiftc` directly, without SwiftPM. A new file anywhere under `macos/Sources/` is picked up automatically.
- **TypeScript**
  - `strict`; no unused variables or imports (`tsc` rejects them). Exact types instead of `any`.
  - State is a class extending `Observable` that calls `this.emit()` after a change; views subscribe with `useObserve(store)`.
  - Backend calls go through `shared/api` (`ipc`). Components never call `invoke` directly.
  - Double quotes, semicolons, arrow functions. A file past 400 lines is a sign to split it.
- **Rust**: `cargo fmt`. Processes started on Windows must not open a console window (`CREATE_NO_WINDOW`).
- **Comments** are in English, short, and say **why** — what the code does, the code says. Public types and functions get a one-line `///` (Swift) or `/** */` (TypeScript). Older comments are in Korean and are being converted; don't translate them in an unrelated pull request.
- **Performance**: code that runs on file-system events must cope with large repositories (tens of thousands of commits). Don't re-assign an unchanged value and make the view redraw; keep the number of git processes down. On macOS, `GITROCHI_TRACE=1` prints refresh timings.

## Screen text and translations

- **UI text is written in English in the code**, and that English is the translation key. Keep it short, in sentence case; menus and buttons are verbs (`Stage`, `Create branch…`).
  - macOS: SwiftUI's `Text("…")`, `Button("…")` and friends are translated as they are; other strings (error messages …) use `String(localized: "…")`.
  - Windows: `t("…")`, with values as `t("Commit {0} files", n)`.
  - Translations: macOS `macos/Resources/Localizations/<lang>.lproj/Localizable.strings`, Windows `windows/src/shared/i18n/locales/<lang>.json`. When you add a string, add Korean (`ko`) in the same pull request and as many of the other 18 languages as you can; a missing translation shows the English.
  - The default language is English; the user changes it in Settings › Appearance.
- **An icon button explains itself on hover** (macOS `.help(…)`, Windows `tip=` / `data-tip`), not with a label.
- Actions that are hard to undo (delete, force push, reset --hard, running a deployment, ending a session) ask once.
- Check both the light and the dark theme. Use only system colors on macOS and the CSS variables on Windows (`--text`, `--accent` …).
- macOS views are readable and operable with VoiceOver (`accessibilityElement`, `accessibilityAction`).

## Privacy and secrets

- **Tokens live only in the macOS Keychain or the Windows Credential Manager.** Never in settings files, logs or error messages.
- No real company or person names, internal hostnames or personal emails in code, tests or screenshots. Use `example.com` and the demo repository (`docs/make-demo-repo.sh <folder>`).
- Outgoing requests (GitHub, GitLab, AI, Gravatar) go only to what the user connected or chose.

## Tests and verification

| | macOS | Windows |
|---|---|---|
| Build | `macos/build.sh` — no errors, no warnings | `cd windows && npm ci && npx tauri build` |
| Check | | `npx tsc --noEmit -p .` · `npx vitest run` · `cargo check` |

- Pure logic (parsers, graph, YAML, layout maths) gets a unit test in `windows/tests/*.test.ts`. The macOS side has no test target; keep such logic in a pure function so it mirrors the tested one.
- A new screen or behaviour on Windows gets a step in `windows/src/app/selftest.ts`, which drives the real app on GitHub Actions' Windows runner.
- Features that need a server are checked against `windows/tests/mock-ai-server.mjs`.
- The macOS app can be exercised without installing it: `macos/build.sh` writes `macos/build/Gitrochi.app`, and a SwiftUI harness in an off-screen window is a good way to check layout code.
- The Windows app runs on a Mac too: `npx tauri dev` (its data folder is separate, `Gitrochi (Tauri)`).
- Changed [gitch](../tools/gitch/README.md) (bash 3.2 + git, bundled with the macOS app)? Run `tools/gitch/tests/run.sh` (about three minutes, touches no real configuration). Changed the precise-reference or auto-refresh helpers? Also `python3 tools/gitch/tests/test_scip.py` and `python3 tools/gitch/tests/test_watch.py`; app URL routing is checked with `bash macos/Tools/test-app-route.sh`. CI also validates the JSON Schema contracts (test dependency `jsonschema==4.25.1`; the shipped helpers use only the Python standard library).
- Changed [gitch-swift-index](../tools/gitch-swift-index/README.md) (Swift, the Xcode index helper next to gitch)? Run `tools/gitch-swift-index/tests/run.sh` (about 30 seconds).
- The apps and gitch share one release version: `bash tools/check-versions.sh` checks macOS, Windows and the CLI at once (the macOS build and CI run it too).
- Changed a screen? Check it with the demo repository and attach light and dark screenshots to the pull request.
