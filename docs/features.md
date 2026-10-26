# Usage, features and development

The long version of the [README](../README.md): how to get started, every feature, and how the apps are built.

## Screens

<table>
  <tr>
    <td width="50%"><img src="images/commit-diff-light.png" alt="Pick a commit for its details on the right; click a file for its diff in the middle"></td>
    <td width="50%"><img src="images/changes-light.png" alt="Uncommitted changes: a diff per file, staging and the commit box"></td>
  </tr>
  <tr>
    <td align="center"><b>Commit details and diff</b><br><sub>Pick a commit for its author, parents and changed files; click a file for its diff</sub></td>
    <td align="center"><b>Uncommitted changes</b><br><sub>See the diff before staging, stage per file, commit</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img src="images/commit-diff-dark.png" alt="Dark theme"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><b>Dark theme</b><br><sub>Settings › Appearance: system · light · dark</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="images/windows-light.png" alt="Windows — light"></td>
    <td width="50%"><img src="images/windows-dark.png" alt="Windows — dark"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><sub>Windows has the same screens and features: tabs inside the window, Ctrl shortcuts, PowerShell · WSL terminals, and a title bar that follows the theme</sub></td>
  </tr>
</table>

<sub>The repositories and authors in the screenshots are made up (reproduce them with <a href="make-demo-repo.sh"><code>docs/make-demo-repo.sh</code></a>).</sub>

## Usage

### First time

Open **Get started with a Git account** on the welcome screen (Windows: **Set up a Git account · Get started with gitch**) or **Settings › CLI**. gitch ships with the app; there is nothing extra to download.

1. **Sign in to GitHub in the browser** connects the account you approve in your default browser and fills in your user name and email. It needs the official [GitHub CLI](https://cli.github.com/); if it is missing, the app opens the download instructions. For a company GitLab, enter the server address and account details yourself.
2. Check and save the account details, then prepare an SSH key: create a dedicated key in the app or use an existing one. On GitHub, **Register the public key and connect** registers it and checks the connection in one go. The **?** next to the SSH port explains the default 22 and company server settings.
3. Open a repository and work. To use the commands in a terminal too, choose **Also use in the terminal**; the app shows which files it will touch before it changes global settings.

**Getting started · Command help** explains `gitch add` (add an account), `gitch g` (structure graph), `gitch app` (open the app) and the rest, and where to find each one in the app. The structure graph works before any account is set up. The result of the setup check and SSH connection problems are shown in the app as well.

1. **Open a repository** — the folder button (⌘O / Ctrl+O) or clone (⇧⌘O); several repositories open as tabs (⌘T).
2. **Look around the graph** — click a commit for its details on the right, a file for its diff. Click a branch on the left to jump to its commit, double-click to check it out.
3. **Commit** — pick **Uncommitted changes** at the top, stage files, write a summary or press **Write with AI**, then ⌘↩.
4. **Work with branches** — drag a branch label onto another commit or branch for the merge · rebase · fast-forward menu. Right-click a commit for cherry-pick · revert · reset · tag.
5. **Push and pull requests** — Push from the toolbar, then ＋ in the sidebar's Pull Requests to create a PR/MR. Connect GitHub and self-hosted GitLab tokens under Settings (⌘,) › Accounts.
6. **CI/CD** — in the sidebar's **CI/CD** tab, expand a pipeline and run a manual job with ▶, or press **Run…** for a new pipeline or workflow.

| Action | macOS | Windows |
|---|---|---|
| New tab · close tab | ⌘T · ⌘W | Ctrl+T · Ctrl+W (right-click a tab: close the others) |
| Search commits · next result | ⌘F · ⌘G | Ctrl+F · F3 |
| Commit | ⌘↩ | Ctrl+Enter |
| Undo the last operation | ⌥⌘Z | Ctrl+Z (outside a text field) |
| Refresh | ⌘R | F5 |
| Show terminal · new terminal | ⌃\` · ⌃⇧\` | Ctrl+\` · Ctrl+Shift+\` |
| Settings | ⌘, | Ctrl+, |

## Features in detail

<details>
<summary><b>Graph · branches · commits</b></summary>

- **Commit graph**: every branch in its lane color, merges and forks as curves, rows drawn as lane bands like GitKraken. The "Branch / Tag" column on the left (local and remote branches of the same name as one label, the current branch ✓), an "Uncommitted changes" row at the top and one for each other worktree, author pictures on the commit nodes (GitHub · self-hosted GitLab · Gravatar, initials otherwise), CI status per commit
- **Filtering**: hide branches, pin them to the top of the sidebar, show only the current branch (remembered per repository)
- **Sidebar**: local branches (↑/↓), remote branches per remote, tags, stashes. Click = jump to the commit, double-click = check out, right-click = merge · rebase · new branch · push · delete
- **Working copy**: stage and unstage (per file, per folder or all), discard, commit, amend, list or folder-tree view
- **Line and hunk staging**: stage, unstage or discard each hunk of a diff; click changed lines (Shift for a range) to take only those
- **Commit details · diff**: message (Markdown), author, jump to the parents, changed files → unified or side-by-side, word-level highlighting, ignore whitespace, wrap long lines, before/after image comparison, rename and mode changes, CRLF files as they are
- **File history · blame**: the commits that changed a file with their changes, and who changed each line when (older lines fade)
- **Right-click a commit**: create a branch or tag, check out (detached HEAD), cherry-pick, revert, reset (soft/mixed/hard), **Tidy commits from here** (interactive rebase: squash · reorder · reword · drop)
- **Drag and drop**: a branch onto a branch or commit → merge · rebase · fast-forward; a commit onto a branch → cherry-pick
- **Toolbar**: Fetch, Pull (default/ff-only/merge/rebase), Push (sets the upstream, force-with-lease), new branch, Stash/Pop
- **Operations in progress**: a banner for merge, rebase and cherry-pick conflicts (abort/continue), a **conflict-resolution screen** (per block: mine · theirs · both · edit by hand; a whole file from one side)
- **Undo**: the last operation — commit, merge, rebase, checkout, branch deletion … — in one step (refused if the repository changed since)
- **Commit search**: subject, author, SHA and branch, plus the message body, file paths and code changes (-G). Hits are highlighted, and results outside the loaded graph can be fetched
- **Worktrees**: list, new worktree (new or existing branch, default location `<repo>-worktrees/<branch>`), remove and prune, open a worktree in the same tab like GitKraken, see which branch another worktree uses

</details>

<details>
<summary><b>AI · rules · split commits</b></summary>

- **Writes**: commit messages, commit descriptions, PR/MR titles and bodies
- **Your choice of AI**: Claude Code · Codex (ChatGPT login) · Gemini CLI (this machine's login, tools off, text only), Claude API · ChatGPT API · Gemini API (keys), OpenAI-compatible servers (Ollama · LM Studio · OpenRouter …). APIs fetch the account's model list
- **Rules** (Settings › Rules): shared rules plus rules for commit messages, commit descriptions and PR descriptions (for example `the prefix is one of Feature, Fix, Hotfix`), buttons for frequent rules, a different AI per feature
- **Split commits**: the AI proposes a plan that groups the changed files by topic; edit the messages and files, then commit them one after another

</details>

<details>
<summary><b>GitHub · GitLab · CI/CD</b></summary>

- **Accounts**: tokens (macOS Keychain / Windows Credential Manager); GitHub can take over the `gh` login, GitLab takes a self-hosted address
- **PRs/MRs**: open list and details, review in the app (conversation · line comments · write comments · approve · request changes, diff of the changed files, Markdown), check out (forks as `pr/<number>` · `mr/<number>`), create from the current branch (pushes first if needed, draft, preview tab), search your repositories in the clone window
- **HTTPS auth**: push, pull and clone with the connected token (an existing keychain or credential helper wins). A credential prompt fails instead of hanging (`GIT_TERMINAL_PROMPT=0`)
- **CI/CD tab**: GitLab pipelines · GitHub Actions runs (current branch only), expanded into the jobs of each stage
  - run GitLab `when: manual` · `when: delayed` jobs with ▶ (the number of waiting manual jobs shows in the list)
  - rerun jobs and pipelines (GitHub: failed jobs only, too), cancel, open in the browser, show the commit
  - **Run…**: a new GitLab pipeline (branch and variables, with the described variables from `.gitlab-ci.yml` filled in) / GitHub `workflow_dispatch` (branch and inputs)
  - approve or reject deployments under GitHub environment protection rules
  - running needs the `api` scope on GitLab and Actions write access on GitHub (`repo` for classic tokens)

</details>

<details>
<summary><b>Agents · terminal · tools · more</b></summary>

- **Agents tab**: worktree cards (new, changed and deleted files, ↑↓ against the remote) with the Claude Code · Codex · Gemini CLI sessions in them and their state (working · asking permission · waiting for input · ended). Start a session (pick a worktree or create one, the task, the permission mode — up to skipping all permission checks). Sessions run in the terminal panel below the graph; their state comes from files written by hooks that Gitrochi adds with `--settings` to the sessions it starts, so your own settings and hooks stay as they are
- **Terminal**: shells in the repository folder in a panel below the graph (zsh on macOS · PowerShell/WSL on Windows). Several tabs, panes split right or down, adjustable height, keeps running while hidden; a tab whose agent is still running asks before closing. macOS uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), Windows [xterm.js](https://xtermjs.org)
- **Tools** (Settings › Tools): git · Claude Code · Codex · Gemini CLI · gh · the terminal shell are found automatically; point to one with **Browse** when they are not. Windows finds tools inside WSL too
- **gitch** (macOS · Windows, Settings › CLI): a shell tool for using several Git accounts without mixing them up ships with the app (formerly gitsw). Once installed it locks an account per repository, picks the account by folder or organization rules, and blocks the wrong author, secrets and force pushes in git hooks — in the terminal, in AI agents and in Gitrochi alike. Above the commit box you see this repository's account and the checks before committing and pushing; click the account name to switch. On Windows it runs in Git for Windows' Git Bash and can be called as `gitch` from PowerShell and cmd — [tools/gitch](../tools/gitch/README.md)
  - **CLI only** (without the app): `curl -fsSL https://raw.githubusercontent.com/Gitrochi/Gitrochi/main/tools/gitch/install.sh | bash` — verifies the release's gitch by SHA-256 and puts it in `~/.local/share/gitch/gitch`. Add accounts and run `gitch install` as the installer shows; update with `gitch self-update`
  - **Structure graph** (repository menu): pick file imports, module dependencies, files that change together or the folder structure, and `gitch graph` draws one page that opens in your browser (no account needed). **Dependencies changed on this branch** compares with the fork point from the default (or a chosen) branch or tag and shows added and removed dependencies and cycles; **Check dependency rules** shows the dependencies that break `.gitch/graph.rules`
- **Tabs**: native window tabs on macOS (drag a tab out into its own window), tabs inside the window on Windows. Tabs are restored on the next launch
- **Theme**: system · light · dark
- **Auto refresh**: saving a file refreshes the status only; a branch or commit change refreshes the graph too (light even on large repositories)

</details>

## Development

<details>
<summary><b>Repository layout · build · self-test</b></summary>

```
macos/     macOS app (SwiftUI)
  Sources/App       app, windows, tabs, updates, theme
  Sources/Core      running git, parsing its output, graph layout, models, file watching
  Sources/Store     the repository screen's state (RepoStore) and its extensions per feature
  Sources/Services  GitHub, GitLab, CI/CD, AI, accounts, agents, tools, avatars
  Sources/Views     screens
  Resources/ Tools/ Vendor/SwiftTerm/  build.sh
windows/   Windows app (Tauri 2 + React): src-tauri (Rust), src (Feature-Sliced Design: app · pages · widgets · features · entities · shared), tests
docs/      README images, the demo repository script, the contributor docs
tools/gitch  the shell tool for several Git accounts (bash 3.2 + git, Git Bash on Windows) — ships with both apps, tests/run.sh
```

**macOS** — Swift 6 or later (Xcode or Command Line Tools) is all you need. No packages are downloaded.

```sh
macos/build.sh           # macos/build/Gitrochi.app (this Mac's architecture)
macos/build.sh install   # build, then install into /Applications
macos/build.sh release   # dmg, zip and sha256 for distribution in macos/dist/ (arm64 + x86_64 universal, ad-hoc signed, update signature)
```

- Compiled directly with `swiftc`, without SwiftPM (SwiftPM does not work with some Command Line Tools). For the same reason the `ViewState` alias (`Views/Shared/Theme.swift`) stands in for the `@State` macro
- SwiftTerm is compiled once per architecture into a static library (`macos/.build/swiftterm/<arch>/`, about a minute the first time)
- `tools/gitch/gitch` goes into the app as `Contents/Resources/gitch`. Changed gitch? Run `tools/gitch/tests/run.sh`
- An Apple Development certificate on this Mac is used for signing when present (so the keychain does not ask again after every build; change it with `GITROCHI_SIGN_IDENTITY`)
- `GITROCHI_TRACE=1` prints each refresh and how long it took to standard error
- **Update signature**: `macos/Tools/updatekey.sh new` creates an Ed25519 key pair — the private key goes into the login keychain, the public key into `Info.plist` (`GitrochiUpdatePublicKey`). From then on `build.sh release` signs the zip (`<zip>.sig`, private key from `GITROCHI_UPDATE_KEY` or the keychain), and the app installs an update only when the SHA-256 and this signature match
- **Distribution**: pushing a `v*` tag makes Actions (`.github/workflows/macos.yml`) check that the tag matches the `Info.plist` version, build and sign a universal app and upload it to that tag's release (a draft if there is none), together with the standalone `gitch` and `gitch.sha256`. The app ignores drafts, so write the notes and publish to reach users

**Windows** — Node.js 22 and Rust (stable).

```sh
cd windows
npm ci
npx tauri build      # src-tauri/target/release/bundle/nsis/*-setup.exe
npx vitest run       # unit tests for the parsers, the graph and CI
```

- **Self-test**: run with `GITROCHI_SELFTEST=<test repository>` and the real app opens, stages, commits, branches, merges, searches, stashes, uses the terminal, credentials, tools, AI, split commits, the update signature, CI/CD, WSL, diffs, line staging, conflict resolution, commit tidying, undo, PR review, the tab menu and the theme one after another and writes down the results (fake server: `tests/mock-ai-server.mjs`). It runs on GitHub Actions' Windows runner on every push, which also takes the Windows screenshots for this README (`.github/workflows/windows.yml`)
- **Update signature**: release builds are signed with `TAURI_SIGNING_PRIVATE_KEY` (an Actions secret), and the app installs an update only after checking it against the public key in `tauri.conf.json`. The release carries `latest.json` (`windows/scripts/latest-json.mjs`)

</details>
