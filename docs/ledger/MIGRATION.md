# Moving from Claude Ledger

Existing Claude Ledger users can bring their records into Gitrochi and keep using the reporting workflow. Installing Gitrochi does not connect the two databases automatically. Choose a **one-time import** and connect agents to Gitrochi, or start the optional **local HTTP bridge** for clients that still use the original Python command.

Gitrochi's Ledger is available on macOS and Windows behind the [preview switch](README.md#open-the-preview). It implements the behavior independently in Rust, Swift and TypeScript. No Python source, interface styling or organization-specific document parser is copied from the supplied project, which has no license file.

## Import existing records

1. Find the original installation's `data/ledger.db`. If it is running, select that original file with its matching SQLite sidecars still beside it, or use the original tool's consistent backup command. Copying only the main file while its writer is running can omit committed WAL data.
2. In Gitrochi, choose **Paste reports… › Import from claude-ledger…** and select the database.
3. Review the preview: projects, baselines, sessions, events, questions, pasted-block hashes, work items, personal notes and preserved source rows. Read both the skipped-session and unreadable-row lists.
4. Choose **Import**. Check the Board, Streams, Work log and Notebook before changing an agent's connection.
5. Use **Connect agents…** to point the client at Gitrochi's bundled Ledger command, then start or restart the client so it loads the tools.

The source is opened read only. Its records, schema version and settings are not rewritten. Gitrochi reads a consistent source snapshot and copies the result in one destination transaction. A preview does not copy records or bump the destination revision. An unchanged repeat import adds nothing.

The equivalent commands are:

```sh
gitrochi-ledger import-legacy data/ledger.db --dry-run
gitrochi-ledger import-legacy data/ledger.db
```

Use `--db trial-ledger.sqlite3` before the command to try the import in a separate Gitrochi database first. Use **Back up now** in Settings before importing into a Ledger you already use.

### What is retained and how conflicts work

- Session IDs stay the same. When Gitrochi already has an ID, that incoming session and its events and questions are skipped together. Its existing history is never replaced or merged with a possibly different conversation. Later changes to that skipped source session are also not synchronized by another import.
- Session kinds and supported event aliases are normalized to Gitrochi's English identifiers. Original times, state, confirmation, shelving, archival and pending-delivery state are retained where the source supplies them. Report bodies and question references move into the corresponding Gitrochi fields.
- Baselines are added or complete missing information. An inferred baseline can be promoted using the source's registered or released record. An existing known value is not overwritten by a conflicting source value.
- Questions and events receive destination IDs. Import provenance maps original event IDs to their new IDs before rewriting work references such as `E12`. A reference whose source event was skipped or missing becomes a `legacy:…:E12` reference; it cannot accidentally point at an unrelated destination event numbered 12.
- Work bundles, items, dated events, plans, transfers, grouping, splits, carryovers, corrections, skipped-reference markers and work notes are projected into Work log. Conflicting work IDs receive imported IDs; existing work is not overwritten. Existing imported items keep later edits made in Gitrochi when the import is repeated.
- Personal notes receive new Notebook IDs. The original title, Markdown, pin state and available dates are retained. They remain outside agent-facing session search and tools.
- Every optional source work/note row is also preserved with source provenance, including fields with no native projection. This retained evidence is not a claim that every organization-specific field has the same meaning in Gitrochi.
- Duplicate hashes for pasted reports are retained. Re-pasting a report already imported by the old tool is recognized.

Source provenance is an import aid, not a database-wide identity service. It is derived from the oldest readable source session, falling back to the selected path when there is none. Keep imports associated with the same source lineage. Unrelated databases sharing that seed, or moved databases with no sessions, cannot be distinguished reliably by that fingerprint alone. Keep the original database and its backups as your independent record.

The import does not bring over `ledger.config.json`, client registrations, credentials, scheduled startup or document-folder choices. Choose baseline sources and document folders in Gitrochi. Importing is a migration, not live two-way synchronization: reports still sent to the Python server remain in its database.

## Connect existing agents

Use **Connect agents…** for the stable command and client-specific configuration. The stdio server exposes `ledger_overview`, `ledger_report`, `ledger_session`, `ledger_work` and `ledger_lookup`. Register that command in place of the old Python MCP server entry and restart the client. Keep your previous configuration if you want to return to it; Gitrochi does not replace it automatically.

Avoid keeping two servers with the same Ledger tool names enabled in one client: the client may otherwise report to the old database. With a client that supports Claude Code's registration command and an installed command on its path:

```sh
claude mcp add --scope user gitrochi-ledger -- gitrochi-ledger mcp
```

After connecting, ask the agent for `ledger_overview` and a report using the imported conversation's exact session ID. Read-only activity hooks and MCP reports are separate connections. [Passive activity setup](README.md#track-local-claude-code-and-codex-activity-automatically) can observe new local conversations; it does not import old chat transcripts or mark work complete.

## Work log

Open **More ledger actions › Work log…**. Choose a project, select **New work item**, give it an ID such as `W-app-01`, a title, a bundle, an expected output and a date. Work spans conversations; its status does not change a session's clean-up verdict.

Select an item to append progress, start, completion, issue, hold, resume, freeze, cancellation, plan or transfer records. Describe what was done. Prefix an uncertain date with `~`; planning dates are actual calendar dates. **Evidence references** can link reports using `E<number>` and document paths. **Unassigned reports** shows candidate session outcomes that have no work link; assigning them remains a deliberate choice.

The record menu also supports grouping, text/date corrections, moving a record, carrying an issue forward and completing or reopening a bundle. Corrections preserve the old value in history. **Split from item** establishes the source of a newly split item. A completed bundle refuses new work until reopened; complete, freeze, cancel or transfer its outstanding items first.

**Build report** generates Markdown for the chosen bundle and date range. **Copy report** copies it for a document or message. CLI reports additionally support a summary view and reference footnotes:

```sh
gitrochi-ledger work add_item '{"project":"Example App","item":"W-app-01","bundle":"Milestone","title":"Improve cache behavior","output":"Measured cache policy","date":"2026-11-02","text":"Registered the cache study"}'
gitrochi-ledger work event '{"project":"Example App","item":"W-app-01","event":"started","date":"2026-11-02","text":"Compared cache settings","refs":["E12"]}'
gitrochi-ledger work event '{"project":"Example App","item":"W-app-01","event":"plan","date":"2026-11-02","plan":{"conservative":"2026-11-05","slack":"2026-11-07"}}'
gitrochi-ledger work report '{"project":"Example App","bundle":"Milestone","from":"2026-11-01","to":"2026-11-30","view":"summary","refs":true}'
```

**Paste work records** accepts fenced `work` JSON lines. Each line has an independent success, error or duplicate result. Agents can use `ledger_work` for the same work records and reports. A person's work note is queued for work agents; a personal Notebook entry is never delivered this way.

## Document tracker

Open **More ledger actions › Document tracker…**, choose the project, add its Markdown/text folders and select **Save folders and scan**. Only the app can choose roots or hold a checksum. Agents can search or rescan folders the person already selected; they cannot turn a lookup into an arbitrary filesystem read.

**IDs and evidence** finds definitions and mentions; headings starting with an ID and first table cells define IDs. **Open tasks** collects unfinished checkboxes and definitions. **Feedback** focuses on open feedback/backflow sections; notices and instructions are identified from labelled sections. Evidence shows the source file and line, plus related sessions that declare the same touched ID. Code fences are excluded from evidence.

Select **Hold current checksum** for a document you want to compare later. After the next scan, **Changed since held** means its contents differ. This is an evidence checkpoint, not a claim that an implementation has applied that document.

This is a general tracker, not a reproduction of a team's directive, registry, reply or filename conventions. Select narrowly scoped folders. Scans skip hidden/build/dependency folders, symlinks, non-UTF-8 files and documents larger than 1 MiB; they stop at 5,000 files, 32 MiB total, 20,000 directory entries and bounded depth. The result shows warnings and limits; reduce the folder selection if a scan is too large. A lookup displays at most 2,000 evidence rows.

**Summarize evidence with AI** sends the selected evidence to the AI provider already configured in Gitrochi, only when requested. The generated summary stays separate from source excerpts; review it against those excerpts. Regeneration is explicit. Saved summaries are keyed to approved source hashes and carry provider/model labels; a later scan or revoked folder invalidates a mismatched cache. Monthly totals count successfully saved requests and evidence/response characters, not billed tokens, prices or failed network requests. Without a configured provider, scanning and lookup still work locally.

```sh
gitrochi-ledger lookup -p "Example App" --id C-12
gitrochi-ledger lookup worklist -p "Example App"
gitrochi-ledger lookup backflow -p "Example App"
gitrochi-ledger lookup scan -p "Example App"
```

## Notebook

Open **More ledger actions › Notebook…**. Create a note, give it a title, write Markdown, pin it if needed and choose **Save**. Search includes titles and body text. **Preview Markdown** shows the rendered draft. Switching or closing with an unsaved draft asks before discarding it; deletion asks once.

If another window changed the note, saving or deleting reports a conflict and leaves your draft intact. Copy it if needed, then use **Reload note** to load the latest saved version. Notes are local, person-only records: the MCP tools, reporting bridge, session reports and global session search never return them. Normal Ledger backups include them.

## Optional local HTTP bridge

The bridge is **experimental** and starts only when you run it. It does not install a service, change startup settings or enable a network listener when the app opens. Use it if an existing Python `RemoteLedger` client must report to Gitrochi's database:

```sh
gitrochi-ledger serve --listen 127.0.0.1:8765
```

In that client's environment, set `LEDGER_URL=http://127.0.0.1:8765`, or set its own configuration to:

```json
{"client_mode":"http","server_url":"http://127.0.0.1:8765"}
```

Keep the command running while the client needs it. Stop it with the terminal's normal interrupt. The original server cannot occupy the same port; use another loopback port and match the client URL if both must run. This changes the client's destination, not its original database. Another computer needs a user-managed SSH tunnel to this loopback port; direct LAN binding is refused.

| Method | Supported endpoints |
| --- | --- |
| GET | `/api/health`, `/api/version`, `/api/rev`, `/api/projects`, `/api/state`, `/api/attention`, `/api/overview`, `/api/session/<id>` |
| GET | `/api/work`, `/api/work/report`, `/api/work/unassigned`, `/api/id`, `/api/ids`, `/api/worklist`, `/api/backflow` |
| POST | `/api/report`, `/api/version`, `/api/import`, `/api/scan`, `/api/work` |

Overview, report and session responses include legacy aliases used by the old Python formatters. Work and document responses expose Gitrochi's general model with compatibility aliases; specialized directive/reply/registry structures and the original dashboard's full state contract are not reproduced. A document lookup's local excerpt is not labelled as a paid AI summary. `format=text` is available for human-readable output.

`GET` is non-delivering by default. An overview or session read consumes waiting messages only with both `deliver=1` and a nonempty `X-Ledger-Client` header. Report writes retain normal own-session delivery. The original `RemoteLedger` already sends that header. A person's note, answer, confirmation, archive operation and settings changes remain app-only.

Unavailable endpoints include `/api/human`, `/api/notes`, `/api/settings`, `/api/id/summary`, `/api/llm`, `/api/mr`, `/api/client`, all `/client/…` downloads and the original HTML frontend. Use Gitrochi's existing AI, request, notification and terminal interfaces for those native workflows. HTTP never exposes Notebook or document-root settings.

The server accepts literal loopback bind addresses and loopback peers only. Host must name localhost or a loopback address with the bound port; an Origin must name that local HTTP port. Cross-site browser requests are rejected, and no CORS permission is granted. POST requires a JSON object and an explicit content length. Limits are 32 KiB of request headers, 2 MiB of body, short socket timeouts, four workers and a queue of sixteen connections. Duplicate headers and transfer encoding are refused. Responses are uncached and connections close after one request. The bridge is a local adapter, not a remote authenticated service or a browser dashboard.

## Feature map

| Original capability | Gitrochi equivalent |
| --- | --- |
| Sessions, milestones, questions, verdicts and cleanup | Inbox, Board, Graph and session inspector; existing reporting tools and aliases |
| Baseline folders/files, release and application handoffs | Project baseline settings, tags/manual/folder sources, Streams and sync/applied rules |
| Stream cycles and overlaps | Native Streams, graph lanes and touched-file/coupling warnings |
| Pasted reports and duplicate tracking | Paste reports plus retained imported hashes; Work log adds pasted work records |
| Bundles, dated work, plans and reports | Work log, `ledger_work`, CLI work reports and correction history |
| Personal pinned Markdown notes | Private Notebook with conflict protection |
| ID dictionary, open directives, notices and feedback | General Document tracker with source lines, held checksums and explicit AI summaries |
| Claude Desktop/Code MCP | Bundled stdio server, Connect agents guidance and five Ledger tools |
| Original HTTP/WSL client | Opt-in experimental loopback bridge; direct LAN service and original frontend are unavailable |
| Tray attention notices | Existing macOS/Windows notifications and Dock/taskbar badge, each opt-in |
| Electron terminal and quick launches | Gitrochi's existing terminal and agent launch interfaces |
| GitLab MR viewing/merging | Existing Gitrochi pull/merge request pages and their confirmation flow |
| Daily online SQLite backup and retention | Automatic daily checks while the app follows Ledger or the bridge runs; consistent snapshots and `backup --daily`, including notes/work |
| Downloadable Python clients and automatic server startup | No bundled Python distribution or separate tray service; use the native app or manually started bridge |

The standalone configuration and organization-specific documents stay in the original installation. Keep its database until you have verified imported records and agent destinations. Future reports belong to whichever Ledger the client is actually configured to reach.
