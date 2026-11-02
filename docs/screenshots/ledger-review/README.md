# Ledger report review

The screenshots use synthetic data only. The default timeline keeps reports and decisions visible while passive tool observations are folded away. The activity screenshots show the same session with **Show activity** enabled. The report and activity timestamps intentionally differ.

Windows screenshots come from the existing browser preview:

```sh
cd windows
npm run dev -- --host 127.0.0.1 --port 5198
```

Open `/tests/ledger-preview.html?theme=light&view=board&select=pending_merge&activity=1` (or `theme=dark`) at 1440 × 1000. Toggle **Show activity** for the activity images. `/tests/ledger-preview.html?mode=selftest` runs the app's Ledger self-test against the demo backend.

The macOS images are selected outputs of `bash macos/Tools/test-ledger-layout.sh`, which renders the native workspace on synthetic data in both themes without installing or relaunching Gitrochi.
