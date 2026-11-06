# Ledger connections

All screenshots use synthetic demo data. The demo's connections are fixed: Claude Code delivering activity without an MCP entry (**Connected · last data 5 min. ago**, and its row offers **Set up**), Codex running a hook command older than the Ledger (**Needs repair**), and the ChatGPT browser extension **Not set up**. Rendering them reads no client settings and installs nothing.

`ledger-connect-*` and `ledger-empty-*` (macOS) and `windows-connect-success-*` and `windows-empty-*` show the earlier Connect agents sheet and first-report guidance. `macos-connections-*` and `windows-connections-*` show the **Connections** list at the top of the Connect agents sheet and in **Settings › Ledger**. `windows-connect-toolbar-*` shows the Claude Code button beside the ChatGPT entries in the Ledger toolbar, with its tooltip. `macos-connect-entry-*` shows **Connect Claude Code…** next to the ChatGPT browser extension on the empty Ledger; on macOS the same entry sits in the **More ledger actions** menu, which an offscreen render cannot open.

Windows preview:

```sh
cd windows
npm run dev -- --host 127.0.0.1 --port 5198
```

Open `/tests/ledger-preview.html?theme=light&click=[data-connect-claude]` (or `theme=dark`) for the sheet, `?mode=settings&theme=light&scroll=[data-ledger-section="connections"]` for Settings › Ledger, and `?theme=light&hover=[data-connect-claude]` for the toolbar tooltip. `/tests/ledger-preview.html?mode=selftest` checks that reading the rows changes nothing, that Repair and Remove each call the core once, and that browser setup opens its own confirmation.

macOS native preview:

```sh
bash macos/Tools/test-ledger-layout.sh --connections-only
```

It renders the production sheet, Settings › Ledger and the empty Ledger off screen on the demo backend in light and dark, and checks with text recognition that each row, its status and its actions are drawn.
