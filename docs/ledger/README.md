# Using the Ledger

The Ledger brings agent reports, questions and finished work into one place in Gitrochi. It keeps a record of what each session started from and what needs your attention. Its page is available on macOS and Windows without a preview flag; the existing Agents panel and terminal continue to work as before.

<a id="open-the-preview"></a>

## Open the Ledger

Open **Ledger** under **Tools**, or use **⌘7** on macOS / **Ctrl+7** on Windows. No environment flag is needed to show the page. Its settings appear in **Settings › Ledger**. Opening it does not import existing conversations, connect a reporting client or enable tracking.

Optional launched-agent tracking, background notifications and the Dock/taskbar count each follow their own switch in **Settings › Ledger**, and all of them start off. No environment variable is needed: `GITROCHI_LEDGER_PREVIEW` is no longer read. The app's waiting-prompt heartbeat, which tells auto-continue's hooks that you can answer in Gitrochi, runs only while **Track agents I start** is on. Reading reports and using the Ledger's local tools need none of these switches.

The Ledger normally reads your local database. `GITROCHI_LEDGER_DEMO=standard`, `large` or `empty` selects example data instead; the page identifies it as **Demo data**. Remove that variable before tracking real work. `GITROCHI_LEDGER=0` disables the core, and `GITROCHI_LEDGER_DB` selects another database file for an isolated trial.

## Learn the Ledger in the app

Choose **Learn Ledger** in the Ledger toolbar or its empty state. The **Tutorial** has five steps:

1. **Sessions and baselines:** see how an agent's unit of work relates to the version it started from.
2. **Choose a view:** explore Inbox, Board, Graph and Streams.
3. **Try answering a question:** select a choice or focus the empty answer and press Tab, edit the draft, then choose **Send answer**. Filling or selecting never sends it.
4. **Follow an answer to completion:** practise **Mark delivered → Confirm → Clean up**. A saved answer has not necessarily reached the agent yet.
5. **Connect your agent:** open agent instructions or set up the ChatGPT browser extension.

Practice uses local example data. It never creates a real session, sends an answer to an agent, changes tracking or archives your actual work. Only the tutorial step and completion flags are remembered; practice answer text is not saved. Close and reopen to resume, choose **Back** to revisit a step, or **Restart** to practise again. The answer and delivery steps require you to try their actions before continuing.

The **Guide** tab is a searchable reference for setup, sessions, views, answering, delivery, review and cleanup, shortcuts, troubleshooting and privacy. Use it whenever you need help; completing the tutorial is optional. Korean and Japanese include the full tutorial and guide text. [Preview screenshots and validation](../screenshots/ledger-learning/README.md) show the practice screens on both platforms.

## Choose how sessions get into the Ledger

For Claude Code agents you start in Gitrochi:

1. Open **Settings › Ledger** and turn on **Track agents I start**. It starts off.
2. Leave **Give them the Ledger tools** on if you want those agents to send reports. Gitrochi adds its bundled MCP server to each launch unless Claude Code already has one named `gitrochi-ledger`.
3. Start a new Claude Code agent through Gitrochi. It gets a Ledger session before it launches, linked to its repository, branch, folder and agent terminal. The setting applies to new launches, not agents already running.

Tracking records activity times and session IDs through launch-specific hooks. Those activity hooks do not store what you type or the agent's tool input. Reports and auto-continue prompts do store the text they need to show. Turning tracking off leaves subsequent launches on the existing behavior. Codex and Gemini launches are unchanged.

For Claude Code outside Gitrochi:

1. Choose **Connect agents…** on the Ledger page or in its settings, then select **Claude Code**. Copy the command and run it yourself in a terminal.
2. Start or restart a Claude Code conversation so it can load the registered tools.
3. Choose **Copy reporting instruction** in the sheet and give that instruction to the agent. Ask it to call `ledger_report` with a start report for its current work, including the project and a short title. It can then send progress, question and done reports as the work changes.

**Test Ledger** checks this app's Ledger and bundled MCP command. It does not check Claude Code's MCP registration or prove that a client has loaded the tools. Registration makes the tools available; the first agent report creates a reported session. Existing conversations are not imported automatically.

The sheet also supplies configuration for other MCP clients and instructions you can add to a project. In **Connections**, Set up, Repair and Remove change only Gitrochi's own entries in that client's hook settings, after backing up the file; nothing in the sheet edits a client's MCP settings, whose commands are only shown for you to copy. MCP reports and launch tracking are separate: connecting a server alone does not add activity hooks to an outside agent.

**Paste reports…** accepts pasted `ledger` blocks or JSON reports. **Import from claude-ledger…** previews and then copies a standalone claude-ledger database without writing to the source file. Existing session IDs are skipped and listed, and duplicate pasted blocks are recognized.

Existing Claude Ledger users can also retain their work records and personal notes. See [Moving from Claude Ledger](MIGRATION.md) for import conflicts, agent reconnection, the feature map and the optional local HTTP bridge. Importing does not keep the two databases synchronized.

## See and repair your connections

**Connections** lists Claude Code, Codex and the ChatGPT browser extension side by side, at the top of the **Connect agents** sheet and in **Settings › Ledger**. On macOS, **Connect Claude Code…** in the Ledger's **More ledger actions** menu opens it; on Windows, the Claude Code button in the Ledger toolbar does. Each row shows one status:

| Status | Meaning |
|---|---|
| **Not set up** | Nothing connects this client yet. **Set up** installs its activity hooks. |
| **Connected · last data 5m ago** | Data from this client is arriving. With only an MCP registration, it shows **Connected**, because reports do not say which client sent them. |
| **Connected · no data yet** | Hooks are installed but nothing has arrived. Start or restart the client; Codex also needs its hooks trusted in `/hooks`. |
| **Needs repair** | The command the hooks or MCP entry run is older than your Ledger (it would silently refuse to write), writes to another database, or some hooks are missing. |
| **Command missing** | That command was moved or deleted, for example with an old copy of the app. |

**Repair** installs the hooks again with the stable command, which Gitrochi keeps current. When the MCP entry is the problem, Repair also copies an MCP command that replaces the registration; run it in a terminal. **Copy MCP command** does the same at any time. Gitrochi never edits a client's MCP settings itself. **Remove** removes only Gitrochi's hooks for that client. For the browser extension, **Set up…** and **Repair…** open its own setup, which asks before it allows a connection.

Opening Connections changes no client setting and never creates the stable command; at most it refreshes an existing one, as opening the Ledger does. [Screenshots](../screenshots/ledger-connection/README.md) show the list on both platforms.

## Track local Claude Code and Codex activity automatically

Passive hooks can put local conversations in the Ledger even when you start them outside Gitrochi. Use the setup command for the client you want to observe:

```sh
gitrochi-ledger integrate claude --install
gitrochi-ledger integrate codex --install
```

Use the stable installed Ledger command shown by Gitrochi. `--cli FILE` selects that executable explicitly. That command lives at `~/Library/Application Support/Gitrochi/bin/gitrochi-ledger` on macOS and `%APPDATA%\Gitrochi\bin\gitrochi-ledger.exe` on Windows. Once it exists, Gitrochi replaces it with its own bundled command whenever the two differ, each time the Ledger opens, so hooks and MCP entries that name it keep working after the app moves or updates. Gitrochi creates it only when you set up or repair a connection in the app. Installation preserves existing callbacks and settings and makes a private backup before updating the client's user-level hooks. To inspect or remove this connection:

```sh
gitrochi-ledger --json integrate claude --status
gitrochi-ledger integrate claude --remove
gitrochi-ledger --json integrate codex --status
gitrochi-ledger integrate codex --remove
```

Start or restart the client after installing. Codex asks you to review non-managed hooks in its own `/hooks` flow; Gitrochi does not grant that trust or change permission settings. The status command confirms configuration only. A conversation appearing in Board or Streams confirms that its activity reached this Ledger. Cloud-orchestrated Codex tasks do not run these local hooks.

The status also tells you whether the connection still works. Its `health` is `outdated_command` when the hooks or the client's MCP entry run a Ledger command older than your database (an older command refuses to write a newer database and stays silent), `missing_command` when that command was moved or deleted, `other_database` when it writes to a different database, `no_data_yet` before the first activity arrives, and `ok` with `lastObservedAt` and `lastReportAt` once it does. Reinstall with a current command to repair the hooks; re-register the MCP server yourself.

Activity shows starts, tool use and turn boundaries. It does not read conversation transcripts, prompts, tool arguments/results or assistant output. A stopped turn does not mark its task done. New external sessions are titled by the client and the branch they started on, such as **Claude Code · feature/login** (the worktree folder for a detached checkout), use a generic kind and have auto-continue off. Sessions observed before keep their titles, and the agent's first start report replaces the title as before. Existing Gitrochi-tracked sessions keep their own kind and policy.

MCP registration remains separate. When the tools are available, session-start context asks the agent to send real reports with the observed Ledger session ID explicitly. Those reports supply task titles, progress and outcomes; observed activity alone remains **Unreported**.

These global hooks are independent of **Track agents I start** and observe local sessions wherever they start, including Gitrochi. The app's switch still controls its own per-launch tracking. Remove the passive hooks to stop this separate observation; the existing launch commands and off behavior are unchanged.

## Connect ChatGPT web without copying messages

Open **Ledger → ChatGPT browser extension** (also in Settings and Learn Ledger). Use **Open extension folder**, then load that folder in Chrome's `chrome://extensions` with Developer mode and **Load unpacked**. Enter Chrome's extension ID in Gitrochi and review **Allow browser connection**. Installation registers the local host; it does not start collecting a conversation.

Open the intended ChatGPT conversation and the extension popup. Choose or enter a Ledger project, then an active session or **New session**, and choose **Connect**. A completed choice question now appears in Ledger automatically. Its complete option labels and explicit recommendation are preserved. The source link opens the original conversation. The extension never chooses an answer or sends a ChatGPT message.

**Sync drafts accepted with Tab** is a separate option, off by default. If text appears in the verified empty browser editor immediately after a trusted Tab gesture, it is offered in Ledger as **Browser draft accepted with Tab**. Use the suggestion or press Tab in the empty Ledger answer, edit it and choose **Save answer**. Existing edits are preserved. These browser answers remain local; they are not queued for an agent or sent back to ChatGPT.

The current adapter was verified on ChatGPT's anonymous `/uc/<UUID>` page. Signed-in `/c/<UUID>` routes require the same page structure and are fixture-tested; other layouts are explicitly unsupported. It reads only the last completed assistant message with one unambiguous question/list of choices. Streaming output, earlier history, code and ambiguous forms are ignored.

This does **not** capture the desktop application's unaccepted composer predictions. The browser host reports that capability as unavailable. An accepted browser draft is distinct from a model recommendation and from an unread prediction. See the [extension guide](../../extensions/chatgpt-ledger/README.md) for the exact supported layout and limits.

Choose **Pause** to stop. Switching tabs, changing conversations, reloading, closing the tab or losing the local connection also pauses capture; reconnect explicitly. **Remove browser connection** in Gitrochi revokes the host registration. No cookies, account credentials, background history scan or external server is used.

Use the updated Gitrochi app and bundled Ledger command together before enabling the extension. Storage schema 8 adds browser provenance and drafts; an older Ledger writer can read it but refuses to write.

## Answer questions and use suggestions

Question forms keep every question and its choices together. Select one option, select several when allowed, or type a custom answer. A choice fills an editable draft; it does not send anything. **Send answer** confirms the complete form. Every question needs an answer before a multi-question form can be sent.

**Use suggestion** fills the draft from the question's explicit suggestion, its proposed answer, or its recommended choice. In an empty answer field, **Tab** does the same. You can edit the result before sending. Tab keeps its normal navigation behavior when the field already contains text; Shift+Tab always moves backward. Return adds a line, and **⌘Return** / **Ctrl+Enter** sends a complete form.

A live Claude Code question can receive the saved answer through its waiting hook. When no automatic answer is available, **Time left** is the time remaining to answer here; the hook releases the question to the terminal when it expires. Questions marked **Answer in terminal** have no live reply route from the Ledger. If a live prompt is answered elsewhere first, your draft stays visible and is not silently sent to a later question. Drafts of reported questions remain available in the session inspector if the question closes elsewhere.

The browser extension brings supported ChatGPT web questions and accepted Tab drafts into Ledger automatically. Browser answers stay local and use **Save answer**. A conversation using connected Ledger tools can also supply structured questions; those tool-reported answers wait for that conversation's next Ledger report or read, with a separate delivered state. Neither route reads private composer predictions.

### Optional manual import

For sources that the browser extension does not support, **Bring a ChatGPT draft…** remains available in the toolbar as a separate manual utility. It does not read another app's input box, clipboard or conversation automatically, and it does not send to ChatGPT. The automatic browser connection above does not require this step.

For an answer draft:

1. If your client offers a composer prediction, accept it with Tab there without sending it. Copy the resulting draft, or copy text you wrote yourself.
2. Open **Bring a ChatGPT draft… → Answer a question**. Select the intended open Ledger question and paste into **Copied text**.
3. Choose **Use draft**. The Ledger opens that question with your exact pasted text as an editable draft. Review it and choose **Send answer** in the question form when ready.

For a question with choices:

1. Copy one complete question, including its choices. Choose **Add a question**.
2. Choose the project and an active session, or **New session**. These controls determine the destination; pasted project and session IDs are ignored.
3. Paste and choose **Preview**. Check the question, choices, recommendation and suggested answer. Editing the text clears the preview.
4. Choose **Save question** to add it to Inbox. Select or edit an answer there, then send it explicitly.

Plain questions, a single contiguous Markdown bullet/numbered choice list and structured Ledger question JSON are supported. An explicit `(Recommended)` or `(추천)` suffix is recognized; the first choice is never assumed to be recommended. Use structured JSON to preserve option descriptions, multiple selection or a custom `suggestedAnswer`. For example:

```text
Which release channel should we use?
- Stable (Recommended)
- Nightly
```

Use **Paste reports…** for several questions or complete reports. Text over 64 KiB and ambiguous or malformed structured questions are rejected without importing anything. If the chosen question closes or the session becomes inactive while you work, your text stays in the sheet and you must choose the destination again.

**Pasted by you** records the actual source of the handoff. The Ledger cannot verify which app produced pasted text. OpenAI documents [composer predictions](https://learn.chatgpt.com/docs/features/composer-predictions) for eligible Codex desktop conversations; this feature does not claim that every ChatGPT web/app has them or offer a direct prediction-reading integration.

For example, the `questions` field of a report can contain both plain text and structured questions:

```json
{
  "event": "question",
  "session": "cache-review",
  "project": "Example app",
  "summary": "Choose the cache behavior",
  "questions": [{
    "text": "Which cache should be used?",
    "options": [
      {"label": "Memory", "description": "Keep entries locally", "recommended": true},
      {"label": "Disk", "description": "Keep entries across restarts"}
    ],
    "multiSelect": false,
    "suggestedAnswer": "Memory with a short expiry"
  }]
}
```

Existing string questions remain supported. After updating the bundled Ledger command, reconnect or restart a connected client if it still offers the old text-only tool schema.

## Read the views

Use the upper **Inbox**, **Board**, **Graph** and **Streams** tabs to switch views. The compact filter row below them holds the project picker, session text filter and verdict menu. Choose **This repository** to focus on the open repository's project, or **All projects** to see the whole local Ledger.

A session is a unit of agent work. A **baseline** is a version it started from, usually a Git tag; **base → current** shows which baseline it started on and which it last reported using.

| View | Use it for |
|---|---|
| **Inbox** | Attention only: answer reported questions, review automatic answers, confirm finished outcomes and decide what to close or merge. Waiting prompts also appear in the strip above the views. |
| **Board** | Filter sessions by verdict, inspect them and select several for clean-up. **Show archived** (macOS) / **Show cleaned up** (Windows) reveals archived work. **Unreported** finds sessions with no agent report yet. |
| **Graph** | Follow baseline versions and session events over 7 days, 30 days or all time. Select a node to inspect the session; **Key events only** hides routine progress and notes. |
| **Streams** | Follow long-running implementation sessions by their cycles of sync and applied reports. |

Routine progress appears in **Board** and **Streams**. When the Inbox has nothing that needs attention, **View progress** opens the Board, or Streams when only streams remain.

The inspector shows the session's questions, timeline, touched files and available branch, worktree, request, chat and terminal links. The timeline starts with reports and decisions; **Show activity** also reveals passive observations and agent heartbeats. The hidden activity count tells you when those records are folded away. Opening an activity event from search still reveals that event.

When the session belongs to the open repository and that repository has a GitHub or GitLab account connected, its linked pull or merge request also shows where it stands: **Open**, **Draft**, **Merged** or **Closed**, and its checks on the latest commit as **N passing**, **N failing** or **N pending**. Gitrochi reads them with the repository's existing account, the same way the request pages do; nothing is read for other repositories or without an account, and the chip then looks as before. A value is reused for a minute. While the inspector shows the request it is read again every 20 seconds while checks run, every two minutes while it is open, and not at all once it is merged or closed.

If the request was merged but the session is not finished, the inspector and the Inbox's **To decide** group suggest **Request merged — mark merged?**. It opens the usual **Mark merged…** version picker with the newest version marked. The Ledger never changes a session's status by itself; only the version you pick does.

When the session's branch belongs to the open repository and a Flow run was recorded for the commit that branch points at, the inspector adds a read-only **Checks** section: the latest result of each flow on that commit (**Passed**, **Failed**, **Held** or **Canceled**), when it finished, and **Open in Flows** to go to the Flows workspace. Held means the run was refused before running or its rollback failed and the environment is on hold. The section reads the same run records as the Flows workspace, in the repository and in worktrees that have the branch checked out, and refreshes every 30 seconds while shown. It never starts a run or changes flow files, trust or records, and it is hidden when there is no repository, no branch or no run for that commit.

**Last report** is the latest agent report. **Last activity** also includes observed activity, so an active but unreported conversation does not appear to have sent a report. Quiet sessions are checked again at least once a minute while the Ledger is being followed, and a **Still active** snooze is checked at its expiry on the next poll. Search ranks an exact session ID ahead of sessions that only mention it. On macOS, the workspace command palette includes Ledger results. On Windows, search stays inside the Ledger page.

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

Live sessions with the implementation role are **streams**. They appear in Streams and Graph, and stay out of the Board, overlap warnings and ordinary clean-up counts. Look in Streams if such a session is absent from the Board.

Agents Gitrochi starts with **Track agents I start** appear on the Board as the kind `task`, even when they report implementation work, so they count for clean-up and overlap warnings. To follow one as a stream instead, give it an implementation kind in **Manage records…**. To put every new launch in Streams, set the `task` kind's role to **Implementation** under **Settings › Ledger › Roles and stream lines**. Sessions launched before this change keep their kind.

In the Inbox, **↑/↓** moves through items, **Return** opens the inspector, **A** answers, **C** confirms, **E** archives, **S** marks a stale session still active, and **M** opens the merged-version picker. These shortcuts do not act while you type in a field. In an answer field, Return adds a line; **⌘Return** / **Ctrl+Enter** saves. Confirm, archive and status changes offer **Undo**.

Your Ledger answers and messages wait for the agent's next report or read. Writing one does not type into its terminal or immediately resume it.

To deliver them sooner to Claude Code agents Gitrochi starts with **Track agents I start**, turn on **Settings › Ledger › Delivering answers › Wake waiting agents with my answers** (off by default) and choose the wait. After such an agent ends its turn, it keeps listening in the background for that long. An answer to one of its Ledger questions, a dismissal or a message you send its session then reaches it at once, and the question shows as delivered. **Answer wakes the agent** marks its Inbox rows and inspector while it listens. A newer prompt, a restart or the end of the conversation stops the listening; after the wait, answers again wait for the next report. The agent receives your words as a notice from Gitrochi; nothing is typed into its terminal. The setting applies to running tracked agents too, but not to sessions tracked only through the passive hooks.

## Turn on auto-continue deliberately

Auto-continue is off by default and currently works through Claude Code hooks on agents Gitrochi starts with tracking enabled.

1. Open a repository, then open **Settings › Ledger › Auto-continue**.
2. Enable it for that repository and choose the wait, normally 30 seconds. The repository policy applies to agents started afterwards.
3. For an existing tracked session, use the inspector's auto-continue switch and wait to set that session's policy.

When a supported question or permission request waits past the countdown, Gitrochi sends a default answer through the hook. Choice questions use the recommended option, or the first option when none is recommended. Free-text questions get a careful continuation message. The person can answer during the wait instead; use **Answer…**, **Allow**, **Deny**, **Answer in terminal** or **Not this time**, as offered by that prompt.

The terminal's permission dialog may remain visible during the countdown. An answer there counts too. Permission answers are recorded as confirmed only when the handler can tell the automatic answer applied; an unknown outcome is shown for review rather than assumed to have succeeded.

Auto-continue never answers sessions with the decision role, never answers Ledger questions, and never confirms or archives work. Requests that are hard to undo are held for you, as are risky questions, questions with no selectable answer, and waits past the three-in-a-row limit. It does not approve Gitrochi's or gitch's own confirmation dialogs. Plan approval stays off by default. A non-interactive check with Claude Code 2.1.316 showed that an automatic approval goes through, but the hook does not receive the plan, so the Ledger cannot show what it would approve; interactive mode has not been checked.

A **held wait** has a reason and no countdown. Choose **Answer in terminal** to bring forward the terminal Gitrochi started, then answer there. If that terminal is no longer available, answer wherever the agent runs. An answer entered into the Ledger cannot reach a held prompt because no hook is waiting on it.

Every automatic answer appears in the Inbox for review. **Confirm** marks that answer reviewed. **Send correction…** queues a correction for the next agent report or read; open the terminal to say it immediately when needed. Reviewing an automatic answer is separate from confirming a session's outcome.

If Gitrochi is not running, or **Track agents I start** has been turned off since the agent started, synchronous hooks return without a decision so Claude Code can ask in its terminal. A free-text stop-question continuation runs in the background and can still work without the app. Hook behavior depends on the installed Claude Code version; it was checked against 2.1.309. Tracking does not depend on every auto-continue path working.


## Notifications and terminal quick launches

In **Settings › Ledger**, **Show notifications** and the Dock/taskbar count are separate switches, both off by default. macOS asks for notification permission when you enable notifications; if denied, enable them in System Settings. Windows notifications also depend on the operating system's notification settings.

Notifications cover new questions, sessions to clean up, applied reports, waiting prompts and automatic answers. Clicking one opens the Ledger at its session. Existing items are not announced again when Gitrochi starts.

The count includes open questions, clean-up and decision items, automatic answers awaiting review, and held waits that need you in the terminal. Prompts with a countdown do not add to it because they resolve themselves.

With a repository open, the Ledger's terminal button offers **Ledger overview** and **Claude Code**. Both open tabs in the existing terminal panel. The overview prints the current project context for agents; the Claude Code option uses the existing agent-launch path, so tracking applies when enabled. The overview is unavailable on demo data. Open a repository to use the terminal quick launches.

## Share sessions with the team hub

Sharing is off by default, and nothing leaves this computer until you turn it on. It uses the team hub Gitrochi already reads under **Work validation › Team overlap evidence**: connect there first (the hub's URL, and its token, which stays in the Keychain or the Credential Manager). Then open **Settings › Ledger › Team hub** and turn on **Share this computer's Ledger sessions with the team hub**.

**What is shared**, for each active session (not archived, not a stream), under its repository's remote: the session ID, project, title, kind and role, branch, verdict, the touches that are repository-relative paths or identifiers, and the last activity time to the minute. **Never shared**: questions, answers, report summaries and bodies, messages, notes, the notebook, work and document records, chat links, agent IDs and folder paths. A session whose repository has no remote stays on this computer; the status line counts them. Demo data is never shared.

- Gitrochi sends what changed when the Ledger changes, checking every 15 seconds, and everything again every four minutes so the hub keeps it. Closing or archiving a session withdraws it; turning sharing off withdraws all of them, and whatever could not be withdrawn expires on the hub within its presence lifetime (10 minutes by default).
- When another member's session on another computer touches the same thing, the inspector's **Touches** shows **Also touched on another computer by S… · member** with the touches you share. The hub never compares one member's own entries, so your other computers do not appear there.
- An unreachable hub only changes the status line; Gitrochi waits longer after each failure (up to ten minutes) and never shows a dialog. A refused or unreadable token stops sharing until you connect again.
- A hub older than this feature does not keep titles and verdicts; Gitrochi then shares branches and touches only and says so.

The hub's side is described in [services/hub](../../services/hub/README.md#presence-and-overlaps), and the exact contents in the [core contract](../../crates/gitrochi-ledger/CONTRACT.md#sharing-with-the-team-hub).

## Storage, settings and backups

The Ledger's database stays on this computer. An explicitly started [experimental loopback bridge](MIGRATION.md#optional-local-http-bridge) can connect existing reporting clients; direct LAN binding is not available. Only the opt-in [team hub sharing](#share-sessions-with-the-team-hub) sends a summary of active sessions elsewhere. The default database is:

- macOS: `~/Library/Application Support/Gitrochi/ledger/ledger.sqlite3`
- Windows: `%APPDATA%\Gitrochi\ledger\ledger.sqlite3`

Settings › Ledger shows the database location. Global rules, project baseline settings and auto-continue policies live in the database; the app's tracking and notification preferences are separate. Baselines default to Git tags. Projects can instead use matching folder names or registered versions; set their source and pattern in Settings › Ledger.

Use **Back up now** to create a consistent SQLite snapshot in `backups/` beside the database. The default retention is 14 copies, adjustable in settings. **Show in Finder** / **Show in Explorer** opens the location. The CLI also supports `backup --daily` to avoid a second backup on the same day; see the [CLI guide](../../crates/gitrochi-ledger/README.md#command-line).

Gitrochi also checks for a daily snapshot while it follows the Ledger, through an open Ledger view or its active notification polling. Successful checks are at most hourly; a failed attempt retries after five minutes without interrupting the page. Demo data is excluded. The optional HTTP bridge makes the same daily check while its process runs. No daily backup runs while both the app's Ledger polling and the bridge are stopped. Concurrent app, bridge and CLI snapshots use separate temporary files.

Restore is manual. Close Gitrochi and stop agents and other processes using that Ledger first. Preserve the current database and any matching `-wal` and `-shm` files together, then restore a backup as `ledger.sqlite3` with no old sidecar files beside it. Reopen the Ledger and check its sessions before resuming agents. Keep the preserved files until you are satisfied with the restore.

For the exact API and unresolved design points, see the [core contract](../../crates/gitrochi-ledger/CONTRACT.md) and [Ledger design](DESIGN.md). Page availability is independent of the optional tracking and background-integration switches. The design records the remaining integration decisions.

## Work, document evidence and personal notes

The **More ledger actions** menu adds four tools without changing the session views:

- **Work log…** groups dated work across conversations. Create an item, append progress or outcomes, retain correction history, and build a Markdown report. Work records can reference session events; they do not change a session's cleanup state.
- **Document tracker…** reads selected Markdown/text folders for IDs, definitions, tasks, notices and feedback. Evidence includes source lines and held-checksum comparisons. AI summaries use the configured provider only when requested; ordinary lookup stays local.
- **Notebook…** keeps personal Markdown notes with pinning, search, preview and conflict protection. Notes are never returned by agent tools or reporting endpoints.
- **Manage records…** edits session titles, kinds, touched IDs/paths and links, or a baseline's note. Deleting a session asks first and removes its own reports, questions and waiting prompts while keeping baseline and work records; a running agent can report again.

The [migration and usage guide](MIGRATION.md#work-log) gives steps, CLI examples and compatibility limits for these tools.
