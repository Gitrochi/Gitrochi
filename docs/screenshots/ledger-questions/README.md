# Ledger questions and editable answers

These screenshots use synthetic data. They cover a live form with three questions (single choice, multiple choice, and a custom answer), a reported question, a saved answer waiting for the conversation, and a narrow window.

Windows preview:

```sh
cd windows
npm run dev -- --host 127.0.0.1 --port 5198
```

Open `/tests/ledger-preview.html?mode=questions&theme=light` or `mode=reported`; use `theme=dark` for the other theme and `answered=1` for the queued answer. The wide captures are 1440 px wide; the narrow form is 620 px wide. `/tests/ledger-preview.html?mode=selftest` exercises the complete form and its keyboard behavior without a real client.

macOS native preview:

```sh
bash macos/Tools/test-ledger-layout.sh --questions-only
```

The native harness renders both live and reported forms in light and dark. It also sends actual Tab, Shift+Tab, Return and Command+Return events to the focused editor, including an input-method composition case. Tab fills an empty draft and never sends it; only the explicit Send action or a valid focused Command+Return sends the form.
