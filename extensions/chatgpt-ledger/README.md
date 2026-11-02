# ChatGPT browser → Ledger

An opt-in Chrome Manifest V3 extension for the selected ChatGPT web conversation. It adds the latest complete assistant question and its explicit choices to a Ledger session. Answers remain in Ledger: the extension does not send messages to ChatGPT or mark an answer delivered there.

## Setup

Installation and pairing are separate, explicit actions:

1. In Gitrochi, open Ledger → **ChatGPT browser extension**, then **Open extension folder**.
2. In Chrome, open `chrome://extensions`, enable Developer mode and choose **Load unpacked** with that folder. Review the requested permissions first.
3. Copy the extension's 32-letter ID into Gitrochi's setup sheet. Choose **Allow browser connection** and review its confirmation. This registers only that extension ID with the local `com.gitrochi.ledger` native host.
4. Open a supported ChatGPT conversation. In the extension popup, choose or enter a project, then choose an active session in that project or **New session**. Choose **Connect** to pair this tab and conversation. A new session is created only by that explicit connection.
5. Optionally enable **Sync drafts accepted with Tab** before connecting. This setting is off by default.

**Pause** unbinds the conversation. Switching tabs, navigating, reloading, closing the tab or losing the native connection also ends the binding. Reconnect explicitly to resume; bindings and the draft setting are memory-only and never automatically restored. Remove the browser connection in Gitrochi's setup sheet to revoke the native host registration.

The popup supports English and Korean, follows the browser's language and system light/dark appearance, and shows host availability separately from an active conversation binding.

## Supported page contract

The first adapter supports only the layout verified in a live page:

- `https://chatgpt.com/uc/<conversation UUID>` or `https://chatgpt.com/c/<conversation UUID>`, with the same document contract below. The `/uc/` route was verified live; `/c/` is a routing variant tested with the same fixture and has not been verified in a signed-in live page.
- One `section[data-web-mobile-conversation][data-conversation-id]` matching that UUID, with one `ol[data-conversation-transcript]`.
- The **last** `li[data-message-role]` is an assistant message, has a UUID `id` and `data-message-complete`, and has an idle `aria-busy="false"` subtree.
- One `div[data-assistant-markdown-root]` with one `section[aria-label="DIL content"]` contains a question paragraph ending in `?` or `？`, immediately followed by one list of 2–12 distinct choices. Code, nested lists, multiple lists and ambiguous questions are rejected.

Full option labels are preserved. An explicit `(Recommended)`, `[Recommended]` or equivalent Korean `추천`/`권장` suffix marks a recommendation; the first option is never implicitly recommended. No choices, suggestions or multiple-choice semantics are invented. Other routes and layouts are unsupported and fail closed. Accepting the `/c/` URL does not enable an older desktop DOM layout; that route must still match the fully verified mobile DOM above.

`extractor.js` exports the self-contained pure `extractQuestion(document, href)` used by the content bundle. Its source can also be run read-only in a live browser to verify a layout without installing or activating this extension.

### Accepted Tab drafts

The verified composer is `textarea#mobile-composer-prompt[data-mobile-composer-prompt]`. When the user opts in, a trusted, unmodified Tab keydown in that **exactly empty** textarea arms one animation-frame check. Only nonempty text that actually appears in its value is copied as a browser draft for the current captured question. Another key, pointer event, route change, unsupported composer or newer message cancels capture. Shift+Tab, IME composition, ordinary typing and input events do not capture a draft. The extension never intercepts or submits the key.

The observed ChatGPT web page does **not** expose composer prediction events. The host reports `composerPredictions: false`. A draft accepted with Tab is browser text after that gesture; it is not evidence that the extension read an unaccepted prediction or a native application's composer.

## Permissions and boundaries

Only `activeTab`, `scripting` and `nativeMessaging` are requested. There are no blanket content scripts, host permissions, cookies, network calls, debugger access, persistent storage or page `window.postMessage` handlers. The observer is injected into the selected top-level document only after **Connect**.

Content scripts send whitelisted capture/draft messages to the extension worker. The worker checks extension ID, HTTPS origin, top-level frame, selected tab, exact document ID, canonical conversation and a per-binding nonce. Only the trusted popup selects projects and sessions. Content-supplied host operations, database paths or destinations are never forwarded.

The native port uses versioned request/reply IDs, a 65,536-byte UTF-8 request limit including the envelope, and the host's `hello`, `targets`, `bind`, `capture`, `draft` and `unbind` operations. Capture deduplication uses the stable conversation URL and assistant message UUID. Changed and already answered questions have distinct status text. A closed or missing draft target is not reported as synced. Idle target-list requests and paused connections close the native port.

The extension contains no private ChatGPT API calls, account credentials, private application access or automatic delivery claims. The native host's own allowlist and database checks remain authoritative.

## Development and verification

Node.js 22 or later; no package dependencies:

```sh
cd extensions/chatgpt-ledger
npm run build
npm run check
npm test
```

The separate cross-language check uses the test-only Cargo example and an existing Ledger CLI binary:

```sh
cargo build --locked --manifest-path crates/Cargo.toml -p gitrochi-ledger --example browser_fixture --bin gitrochi-ledger
node extensions/chatgpt-ledger/tests/native-roundtrip.mjs "$PWD/crates/target/debug/examples/browser_fixture" "$PWD/crates/target/debug/gitrochi-ledger"
```

Run those commands from the repository root, adding `.exe` to binary names on Windows. The script passes the production extractor's fixture through the production JavaScript native client and Rust framed host, reads it through the CLI, and verifies choice metadata, deduplication, exact Unicode draft spacing, rejected operations and clean EOF. All database files are temporary; no browser host is registered and no user browser is opened.

For a local UI preview without installing an extension or host, run `node tests/preview.mjs` and open the printed loopback URL. Add `?lang=ko&theme=dark` for the Korean dark preview, or `?state=connected` for a simulated connection. This preview uses a local mock and makes no browser or native calls.

`content-bundle.js` is committed so the unpacked folder works directly. Change `extractor.js`, `protocol.js` or `content.js`, then rebuild it. Tests cover DOM fixtures, streaming/history rejection, recommendations, ambiguous lists, sender/document isolation, host contracts and EOF, Unicode frame limits, binding races, accepted Tab drafts and cancellation. The fixture DOM is a narrow dependency-free test model; a live read-only Chrome check separately verified the extractor on the observed page. Browser installation and real activation require the user's explicit final approval.
