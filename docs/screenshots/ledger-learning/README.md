# Ledger tutorial, guide and pasted drafts

All screenshots use synthetic local example data. Practice does not touch real Ledger records or tracking settings.

The five-step tutorial includes the production answer form and a separate saved → delivered → confirmed → archived exercise. Progress resumes locally; **Restart** resets practice. The searchable **Guide** has nine reference topics. **Bring a ChatGPT draft…** previews an explicit paste and its destination; it never reads or sends to another app automatically.

Windows preview:

```sh
cd windows
npm run dev -- --host 127.0.0.1 --port 5198
```

Open `/tests/ledger-preview.html?learn=tutorial&theme=light` and `theme=dark`. Add `step=2` for answer practice, `step=3` for delivery, or use `learn=guide` for the guide. Open **Bring a ChatGPT draft…** from the toolbar for its preview. `/tests/ledger-preview.html?mode=selftest` drives the tutorial, guide, paste capture and complete question forms against isolated demo data.

macOS native preview:

```sh
bash macos/Tools/test-ledger-layout.sh --tutorial-only
bash macos/Tools/test-ledger-layout.sh --chatgpt-only
```

The tutorial harness exercises real Tab, editing and Command+Return in its practice answer editor, delivery gates, resume and restart. The draft harness renders explicit-paste modes and reviewed previews against an isolated backend. Actual native TextEditor edits are checked for no automatic draft or backend writes. Its offscreen accessibility tree does not expose the SwiftUI Use draft / Save question buttons, so those native button presses are not automated here; the Windows demo UI selftest exercises the use/save behavior. Captures include light/dark themes and narrow layouts.
