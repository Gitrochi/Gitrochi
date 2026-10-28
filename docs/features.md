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
5. **Push and pull requests** — review the account, destination and outgoing changes before confirming Push, then create a PR/MR from the requests view. A required Push during PR creation uses the same review. Connect GitHub or self-hosted GitLab from the account controls or Settings (⌘,) › Accounts.
6. **CI/CD** — in the sidebar's **CI/CD** tab, expand a pipeline and run a manual job with ▶, or press **Run…** for a new pipeline or workflow.
7. **Flows** — open **Flows** under Workspace tools in the sidebar, press **Set up flows…** to have the tests found and a `.gitch/flow.yml` proposed, approve its commands once, then run a flow with ▶ and follow it node by node. Details: [flow/README.md](flow/README.md).

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
  - **Structure graph workspace** (toolbar or repository menu): pick file imports, module dependencies, files that change together or the folder structure, and `gitch graph` opens an embedded offline snapshot (no account needed). The browser remains available. **Dependencies changed on this branch** compares with the fork point from the default (or a chosen) branch or tag and shows added and removed dependencies and cycles; **Check dependency rules** shows the dependencies that break `.gitch/graph.rules`. Coverage, revision and provenance explain the snapshot's scope; keyboard navigation and relationship lists accompany the graph.
- **Tabs**: native window tabs on macOS (drag a tab out into its own window), tabs inside the window on Windows. Tabs are restored on the next launch
- **Theme**: system · light · dark
- **Auto refresh**: saving a file refreshes the status only; a branch or commit change refreshes the graph too (light even on large repositories)

</details>

<details>
<summary><b>Flows · tests · CI automation</b></summary>

- **Flows** (`.gitch/flow.yml`): a repository's tests, checks, services, remote CI and deployment steps assembled as blocks into a graph (`needs`), with composite blocks, sub-flows and `matrix`. The flow engine `gitch-flow` makes every verdict; the apps and gitch send the actions you take and show the results. `gitch flow init` proposes a flow file from the test tools, package managers and runtime versions it finds by reading the files only
- **No false passes**: a test node passes only with a report written by this run, at least one executed test and an exit code that agrees with the report; a verdict that cannot be made counts as a failure
- **Same everywhere**: the **Flows** page (Workspace tools), `gitch flow run` and `gitch test` in a terminal, the pre-push gate (`gitch flow gate on`, off by default) and CI (`gitch flow run <flow> --ci`, with CI files from `gitch flow export github|gitlab|jenkins`)
- **Efficient**: only the tests a change affects (`--affected`), cached results for unchanged inputs, installs skipped while the lock file is unchanged, parallel nodes, a one-line summary for AI agents (`--summary`)
- **Docker and remote CI**: run nodes in containers (`executor: docker:<image>`), service containers and compose, fake HTTP servers with fault switches (`mock.http`); drive GitLab pipelines and manual jobs, GitHub Actions workflows, Jenkins jobs and plain HTTP CI without ever resending a trigger whose response was lost
- **Rollback and safety**: undo steps are registered before anything changes and run in reverse on failure or cancel; a failed rollback puts the environment on hold until a person releases it. A flow file runs only after a person approves its commands (AI agents cannot), records are signed, and secrets are masked
- The full guide: [flow/README.md](flow/README.md); the design and decisions: [flow/DESIGN.md](flow/DESIGN.md); what is verified: [flow-validation.md](flow-validation.md)

</details>

## Repository workspace and extended workflows

These additions are implemented in both clients. Earlier fixture-based checks and screenshots are recorded in the [review workflows](review-workflows-validation.md), [extended workflows](complete-workflows-validation.md) and [navigation workspace](navigation-workspace-validation.md) reports (Korean). They do not replace validation against your server, permissions and operating system.

### Navigation and account access

The page list on the left has **Home**, **Repository**, the workspace pages **Compare**, **Rebase** and **Code**, the hosting pages **Pull requests**, **Issues**, **Actions** and **Account**, and **Flows**. Home opens, clones or creates a repository, lists recent ones and searches repositories on a connected server. Repository is the three-column screen: branches, tags, stashes and worktrees on the left; the graph, a diff or a file history with the terminal underneath in the middle; the uncommitted changes with the commit form, or the details of the selected commit, on the right. While it is open the page list folds into an icon rail, which expands it again. Quick navigation (⌘K / Ctrl+K) reaches every page, branch and request, and each repository reopens on the page it was last on. Account gathers the inbox, your work, releases, projects and organizations (groups on GitLab) in one page. Settings keep account, SSH, AI, executable, appearance and update preferences, and open the Git account guide and the gitch setup check.

The account control at the right end of the toolbar shows the selected hosting account and Git identity and allows account selection or reconnection without leaving the window. GitHub browser sign-in displays queued, preparing and approval states. Project access is a separate permission request for the selected account. On macOS, credential reads run away from the main thread and background reads do not display authorization prompts; explicit authorization remains a user action.

### Git and review tools

| Tool | Entry point and behaviour |
|---|---|
| Push review | Push, branch Push and a Push required for PR/MR creation show the account, credentials, actual destination URL, branch, outgoing commits/files and gitch checks. Confirmation binds the reviewed source and destination, then verifies them again. A changed context requires a new review. Force Push uses the reviewed remote SHA as its lease. |
| Line comments and batch reviews | Draft comments beside diff lines, edit or delete them, and submit them together. Drafts are tied to the repository, request and head SHA. Changed heads require a fresh review; partial failures keep unsent drafts. GitHub sends a review, while GitLab publishes discussions before the approval. |
| Two-revision comparison | Compare commits, branches or tags directly or through their common ancestor. Type a revision or pick a branch or tag from the list next to each field; revisions are resolved to SHAs; reverse the direction and inspect the changed files and diff. |
| Multiple commits | Select with ⌘/Ctrl or Shift, review the order, then cherry-pick, revert or prepare squash/drop plans. The app checks the operation state, current HEAD and worktree and creates recovery refs. |
| Three-way conflict editor | Inspect mine, the editable result, theirs and the available base, with synchronized scrolling and block choices. Unresolved markers, source changes and index changes are checked before writing. |
| Recovery | Browse reflog and create a branch from an earlier point. Discarded edits are stored locally before discard; restoring the worktree and index requires the original HEAD and a clean worktree. This is bounded local recovery, not a separate backup service. |
| LFS, submodules and bisect | Repository tools detect Git LFS, manage patterns and server locks, inspect or initialize submodules at their recorded commit, and guide good/bad/skip bisect steps and return to the starting branch. Git LFS must be installed for LFS commands. |
| Line or function history | Open line history from a diff or file view, select a line range or function and a revision, and inspect up to 200 history entries and patches. Deleted lines are followed from the earlier revision. |
| Search | Commit title/body searches ignore spacing, so `release1`, `release 1` and `re lease 1` match the same text; special characters are searched literally. |
| Code and rebase | Browse tracked files and their previews; inspect the rebase target and the commits that will move. Large change lists create only the displayed rows and preserve edited state when the layout changes. |

### Hosting workspaces

PR/MR lists support state, personal/review-request scope, search and pagination. Details offer title/body/base/reviewer changes, merge, close and reopen, with fresh SHA, CI, approvals, permissions and server policy checked before merging. Issues and mentions are scoped to the selected repository and connected account; supported comments, issue state and notification-read actions are available there.

The Account page provides releases and assets, organizations and project boards; Home searches repositories on the server. GitHub Projects v2 supports items, single-select status fields and adding existing issues. GitLab boards expose their scope and label columns. Advanced project fields, project administration and unsupported GitLab column types continue in the browser. Release creation, editing, publishing and deletion follow the server's capabilities; GitHub draft/prerelease behaviour differs from GitLab's immediate publication.

### AI and local MCP

**Ask AI about changes** previews the selected diff, lines, commit or staged changes before sending anything. Follow-up questions reuse that snapshot until refreshed. An available, current dependency-impact result may be attached as context; suggested tests are not presented as executed tests.

**Repository assistant** previews status, history and tracked files, then permits bounded read-only file, history, diff and search requests from the configured AI. The read log is visible. Cancellation, a repository change or a changed AI configuration invalidates late replies. Reading does not change repository files.

The assistant also previews revision-aware screen/selection context, offers editable repository-specific task prompts, links maintained screen implementations and can apply validated graph selections. **Work validation** connects staged test suggestions to actual configured Flow evidence, explicit team hub snapshots and agent handoff reports. Local project tasks support predecessor planning and dependency views. See [connected analysis, planning, verification and limits](connected-workbench.md).

**Connect an external AI with MCP** copies and tests the current repository's local stdio configuration. It exposes status, history, diff, tracked-file reads and preflight information with argument and size limits; it does not expose arbitrary shell execution, Git writes or network tools. Repository AI and MCP need Node.js 22+. See the [MCP tool list, setup and limits](../tools/gitrochi-mcp/README.md).

### Verification limits

The checked-in reports use temporary repositories and simulated services for server-dependent behaviour. Windows installation on a real device, real-server writes and live LFS locks need environment-specific verification. Local builds and unit tests do not establish that every hosting-server version or account policy is supported. Rust measurement results in [the core notes](../crates/README.md) concern selected calculations and are not a claim that every Git operation becomes faster.

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
crates/    shared Rust calculations, native static library, WASM and gitch-core CLI
windows/   Windows app (Tauri 2 + React): src-tauri (Rust), src (Feature-Sliced Design: app · pages · widgets · features · entities · shared), tests
docs/      README images, the demo repository script, the contributor docs
tools/gitch  the shell tool for several Git accounts (bash 3.2 + git, Git Bash on Windows) — ships with both apps, tests/run.sh
tools/gitch-flow  the flow engine (Rust) — ships with both apps and the CLI installer, cargo test
```

**macOS** — Swift 6 or later (Xcode or Command Line Tools) and Rust 1.88+ are required. Cargo downloads the locked dependencies for the shared core; packaged-app users do not need a Rust installation.

```sh
macos/build.sh           # macos/build/Gitrochi.app (this Mac's architecture)
macos/build.sh install   # build, then install into /Applications
macos/build.sh release   # dmg, zip and sha256 for distribution in macos/dist/ (arm64 + x86_64 universal, ad-hoc signed, update signature)
```

- Compiled directly with `swiftc`, without SwiftPM (SwiftPM does not work with some Command Line Tools). For the same reason the `ViewState` alias (`Views/Shared/Theme.swift`) stands in for the `@State` macro
- SwiftTerm is compiled once per architecture into a static library (`macos/.build/swiftterm/<arch>/`, about a minute the first time)
- `tools/gitch/gitch` goes into the app as `Contents/Resources/gitch`. Changed gitch? Run `tools/gitch/tests/run.sh`
- The flow engine `tools/gitch-flow` goes into the app as `Contents/MacOS/gitch-flow` when cargo is installed (a development build goes without it; a release needs it). Changed the engine? Run `cd tools/gitch-flow && cargo test`; the Flows screen's contract with the engine is checked by `macos/Tools/test-flow.sh`
- An Apple Development certificate on this Mac is used for signing when present (so the keychain does not ask again after every build; change it with `GITROCHI_SIGN_IDENTITY`)
- `GITROCHI_TRACE=1` prints each refresh and how long it took to standard error
- **Update signature**: `macos/Tools/updatekey.sh new` creates an Ed25519 key pair — the private key goes into the login keychain, the public key into `Info.plist` (`GitrochiUpdatePublicKey`). From then on `build.sh release` signs the zip (`<zip>.sig`, private key from `GITROCHI_UPDATE_KEY` or the keychain), and the app installs an update only when the SHA-256 and this signature match
- **Distribution**: pushing a `v*` tag makes Actions (`.github/workflows/macos.yml`) check that the tag matches the `Info.plist` version, build and sign a universal app and upload it to that tag's release (a draft if there is none), together with the standalone `gitch` and `gitch.sha256`. The app ignores drafts, so write the notes and publish to reach users

**Windows** — Node.js 22+, Rust 1.88+ and the `wasm32-unknown-unknown` target. `npm ci` prepares the shared core; run `npm run core` before invoking TypeScript or Vitest directly.

```sh
cd windows
npm ci
npx tauri build      # src-tauri/target/release/bundle/nsis/*-setup.exe
npm test            # generates the core and runs unit, Git integration and flow tests
```

- **Self-test**: run with `GITROCHI_SELFTEST=<test repository>` and the real app opens, stages, commits, branches, merges, searches, stashes, uses the terminal, credentials, tools, AI, split commits, the update signature, CI/CD, WSL, diffs, line staging, conflict resolution, commit tidying, undo, PR review, the tab menu and the theme one after another and writes down the results (fake server: `tests/mock-ai-server.mjs`). It runs on GitHub Actions' Windows runner for pull requests affecting the app, tags and manual runs; screenshot and signed-release checks are limited to tag/manual release runs (`.github/workflows/windows.yml`)
- On Windows, `tauri build` and `tauri dev` first build the flow engine (`npm run engine`, a release build of `tools/gitch-flow`) and put it in the install folder as `gitch-flow.exe`, through the Windows-only `src-tauri/tauri.windows.conf.json`. So on Windows `cargo check` also needs the engine built once (like `dist`); on other systems the app builds without it
- **Update signature**: release builds are signed with `TAURI_SIGNING_PRIVATE_KEY` (an Actions secret), and the app installs an update only after checking it against the public key in `tauri.conf.json`. The release carries `latest.json` (`windows/scripts/latest-json.mjs`)

</details>
