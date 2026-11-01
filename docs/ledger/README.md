# Using the Ledger preview

The Ledger brings agent reports, questions and finished work into one place in Gitrochi. It keeps a record of what each session started from and what needs your attention. It is available on macOS and Windows as a preview; the existing Agents tab and terminal continue to work as before.

## Open the preview

Start Gitrochi with `GITROCHI_LEDGER_PREVIEW=1` in its environment. The flag must reach the app process when it starts; setting it in an already-open app's terminal does not reveal the page. Open **Ledger** under **Tools**, or use **⌘7** on macOS / **Ctrl+7** on Windows. Its settings appear in **Settings › Ledger**. The preview remains hidden by default.

The normal preview reads your local Ledger database. `GITROCHI_LEDGER_DEMO=standard`, `large` or `empty` selects example data instead; the page identifies it as **Demo data**. Remove that variable before tracking real work. `GITROCHI_LEDGER=0` disables the core, and `GITROCHI_LEDGER_DB` selects another database file for an isolated trial.

## Choose how sessions get into the Ledger

For Claude Code agents you start in Gitrochi:

1. Open **Settings › Ledger** and turn on **Track agents I start**. It starts off.
2. Leave **Give them the Ledger tools** on if you want those agents to send reports. Gitrochi adds its bundled MCP server to each launch unless Claude Code already has one named `gitrochi-ledger`.
3. Start a new Claude Code agent through Gitrochi. It gets a Ledger session before it launches, linked to its repository, branch, folder and agent terminal. The setting applies to new launches, not agents already running.

Tracking records activity times and session IDs through launch-specific hooks. Those activity hooks do not store what you type or the agent's tool input. Reports and auto-continue prompts do store the text they need to show. Turning tracking off leaves subsequent launches on the existing behavior. Codex and Gemini launches are unchanged.

For Claude Code outside Gitrochi, choose **Connect Claude Code…** on the Ledger page or in its settings. Copy the command, run it yourself in a terminal, and use **Test connection** to check the MCP server. The sheet also supplies configuration for other MCP clients and instructions you can add to a project. Gitrochi does not edit a client's settings files from this sheet. MCP reports and launch tracking are separate: connecting a server alone does not add activity hooks to an outside agent.

**Import…** accepts pasted `ledger` blocks or JSON reports. **Import from claude-ledger…** previews and then copies a standalone claude-ledger database without writing to the source file. Existing session IDs are skipped and listed, and duplicate pasted blocks are recognized.

## Read the views

Choose **This repository** to focus on the open repository's project, or **All projects** to see the whole local Ledger. A session is a unit of agent work. A **baseline** is a version it started from, usually a Git tag; **base → current** shows which baseline it started on and which it last reported using.

| View | Use it for |
|---|---|
| **Inbox** | Answer reported questions, review automatic answers, confirm finished outcomes and decide what to close or merge. Waiting prompts also appear in the strip above the views. |
| **Board** | Filter sessions by verdict, inspect them and select several for clean-up. **Show archived** (macOS) / **Show cleaned up** (Windows) reveals archived work. **Unreported** finds sessions with no agent report yet. |
| **Graph** | Follow baseline versions and session events over 7 days, 30 days or all time. Select a node to inspect the session; **Key events only** hides routine progress and notes. |
| **Streams** | Follow long-running implementation sessions by their cycles of sync and applied reports. |

The inspector shows the session's questions, timeline, touched files and available branch, worktree, request, chat and terminal links. On macOS, the workspace command palette includes Ledger results. On Windows, search stays inside the Ledger page.

A session's verdict is computed from its state:

| Verdict | Next step |
|---|---|
| **Needs you** | Answer or dismiss an open Ledger question. |
| **To decide** | Review a done session, then mark it merged, close it or drop it. |
| **To confirm** | Confirm that a finished outcome is right. |
| **Ready to archive** | Archive the confirmed session when its conversation is cleaned up. |
| **Stale** | Check the agent's conversation, then close it or choose **Still active**. The default quiet period is 72 hours. |
| **Active** | No immediate clean-up action is needed. |
| **Shelved** | Paused research or documentation retained for later; it does not become stale. |
| **Archived** | Cleaned up and hidden by default. |

Confirming acknowledges an outcome. Archiving records that the conversation is cleaned up; it does not stop an agent or delete its branch. A later substantive agent report can reopen a session. **Mark merged…** records a Ledger status and version; merging the actual pull or merge request remains in Gitrochi's existing request workflow.

An unreported tracked launch stays active while its branch is still at the commit it launched from. Once the branch moves, the normal stale timer applies. If its Git context cannot be read, the normal stale rule applies too. **Unreported** uses the absence of an agent report, not the absence of hook activity.

Live sessions with the implementation role are **streams**. They appear in Streams and Graph, and stay out of the Board, overlap warnings and ordinary clean-up counts. This also applies to tracked launches of that kind; the default for launched implementation sessions remains an open design point. Look in Streams if such a session is absent from the Board.

In the Inbox, **↑/↓** moves through items, **Return** opens the inspector, **A** answers, **C** confirms, **E** archives, **S** marks a stale session still active, and **M** opens the merged-version picker. These shortcuts do not act while you type in a field. In an answer field, Return adds a line; **⌘Return** / **Ctrl+Enter** saves. Confirm, archive and status changes offer **Undo**.

Your Ledger answers and messages wait for the agent's next report or read. Writing one does not type into its terminal or immediately resume it.

## Turn on auto-continue deliberately

Auto-continue is off by default and currently works through Claude Code hooks on agents Gitrochi starts with tracking enabled.

1. Open a repository, then open **Settings › Ledger › Auto-continue**.
2. Enable it for that repository and choose the wait, normally 30 seconds. The repository policy applies to agents started afterwards.
3. For an existing tracked session, use the inspector's auto-continue switch and wait to set that session's policy.

When a supported question or permission request waits past the countdown, Gitrochi sends a default answer through the hook. Choice questions use the recommended option, or the first option when none is recommended. Free-text questions get a careful continuation message. The person can answer during the wait instead; use **Answer…**, **Allow**, **Deny**, **Answer in terminal** or **Not this time**, as offered by that prompt.

The terminal's permission dialog may remain visible during the countdown. An answer there counts too. Permission answers are recorded as confirmed only when the handler can tell the automatic answer applied; an unknown outcome is shown for review rather than assumed to have succeeded.

Auto-continue never answers sessions with the decision role, never answers Ledger questions, and never confirms or archives work. Requests that are hard to undo are held for you, as are risky questions, questions with no selectable answer, and waits past the three-in-a-row limit. It does not approve Gitrochi's or gitch's own confirmation dialogs. Plan approval is not enabled by default and has not been checked live.

A **held wait** has a reason and no countdown. Choose **Answer in terminal** to bring forward the terminal Gitrochi started, then answer there. If that terminal is no longer available, answer wherever the agent runs. An answer entered into the Ledger cannot reach a held prompt because no hook is waiting on it.

Every automatic answer appears in the Inbox for review. **Confirm** marks that answer reviewed. **Send correction…** queues a correction for the next agent report or read; open the terminal to say it immediately when needed. Reviewing an automatic answer is separate from confirming a session's outcome.

If Gitrochi is not running, synchronous hooks return without a decision so Claude Code can ask in its terminal. A free-text stop-question continuation runs in the background and can still work without the app. Hook behavior depends on the installed Claude Code version; it was checked against 2.1.309. Tracking does not depend on every auto-continue path working.

## Notifications and terminal quick launches

In **Settings › Ledger**, **Show notifications** and the Dock/taskbar count are separate switches, both off by default. macOS asks for notification permission when you enable notifications; if denied, enable them in System Settings. Windows notifications also depend on the operating system's notification settings.

Notifications cover new questions, sessions to clean up, applied reports, waiting prompts and automatic answers. Clicking one opens the Ledger at its session. Existing items are not announced again when Gitrochi starts.

The count includes open questions, clean-up and decision items, automatic answers awaiting review, and held waits that need you in the terminal. Prompts with a countdown do not add to it because they resolve themselves.

With a repository open, the Ledger's terminal button offers **Ledger overview** and **Claude Code**. Both open tabs in the existing terminal panel. The overview prints the current project context for agents; the Claude Code option uses the existing agent-launch path, so tracking applies when enabled. The overview is unavailable on demo data. Open a repository to use the terminal quick launches.

## Storage, settings and backups

The Ledger stays on this computer; this preview does not share it between PCs. The default database is:

- macOS: `~/Library/Application Support/Gitrochi/ledger/ledger.sqlite3`
- Windows: `%APPDATA%\Gitrochi\ledger\ledger.sqlite3`

Settings › Ledger shows the database location. Global rules, project baseline settings and auto-continue policies live in the database; the app's tracking and notification preferences are separate. Baselines default to Git tags. Projects can instead use matching folder names or registered versions; set their source and pattern in Settings › Ledger.

Use **Back up now** to create a consistent SQLite snapshot in `backups/` beside the database. The default retention is 14 copies, adjustable in settings. **Show in Finder** / **Show in Explorer** opens the location. The CLI also supports `backup --daily` to avoid a second backup on the same day; see the [CLI guide](../../crates/gitrochi-ledger/README.md#command-line).

Restore is manual. Close Gitrochi and stop agents and other processes using that Ledger first. Preserve the current database and any matching `-wal` and `-shm` files together, then restore a backup as `ledger.sqlite3` with no old sidecar files beside it. Reopen the preview and check its sessions before resuming agents. Keep the preserved files until you are satisfied with the restore.

For the exact API and unresolved design points, see the [core contract](../../crates/gitrochi-ledger/CONTRACT.md) and [Ledger design](DESIGN.md). The preview gate, launched implementation-session default and pre-prompt Claude session-ID linkage remain maintainer decisions.
