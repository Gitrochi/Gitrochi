# ChatGPT browser connection

Synthetic questions and temporary/demo Ledger data only. The native and Windows setup captures show explicit extension review, installation status, browser-draft provenance and local-only answer saving in light/dark; Korean Windows captures use the same production UI.

`chatgpt-web-fixture.png` is a real anonymous ChatGPT web conversation created solely for this integration check. The committed extractor was evaluated read-only against that visible DOM and preserved its question, complete labels, recommendation and source ID. No extension was installed for that check.

Windows preview: run Vite from `windows/`, then open `/tests/ledger-preview.html?mode=reported&browser=1&theme=light` or `theme=dark`. The browser setup sheet opens from its Ledger toolbar action. Add `lang=ko` for Korean. `mode=selftest` tests the actual setup confirmation, explicit revocation and browser draft editing against a demo backend; it never registers a real host.

Extension popup preview: `node extensions/chatgpt-ledger/tests/preview.mjs`; append `?lang=ko&theme=dark` for Korean/dark or `?state=connected` for a clearly simulated connection.

Native setup rendering uses an isolated backend that rejects registration calls. Actual Tab/edit tests verify that browser drafts fill only on explicit acceptance, preserve edits and do not send. The real Chrome installation/permission step is separate from code validation and requires the person's approval.
