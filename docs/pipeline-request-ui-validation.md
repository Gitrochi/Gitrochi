# Pipeline and request workspace validation

Validated on October 29, 2026 with synthetic repository data and isolated account/settings state.

## Behavior

Both platforms now present pull/merge request details as Conversation, Changed files and Checks. The conversation uses a vertical activity rail, author initials, readable messages and explicit review states. Metadata edits, comment drafts and loaded checks survive tab switches. The header keeps the selected request identifiable while the title and summary scroll with the content.

Pipeline lists show explicit status text. Run details summarize loaded jobs by status, organize jobs by stage and keep the selected job and its log connected. Short and narrow panels retain scrolling space for both jobs and logs. Provider-specific commands, deployment approvals, redaction and confirmation handlers are reused.

The activity rail uses the review comments and system notes already returned by the hosting APIs, in their existing order. It does not add GitHub commit, merge or ready-for-review event APIs, infer a complete activity history, or invent job totals or progress. New text is translated in all 19 existing localization catalogs on both platforms.

## Checks

| Check | Result |
| --- | --- |
| `macos/build.sh` | Passed on arm64; existing `SecKeychainGetUserInteractionAllowed` / `SecKeychainSetUserInteractionAllowed` deprecation warnings in unchanged account code remain |
| Windows `npm run build` | Passed; existing Vite bundle-size advisory remains |
| Windows `npm test` | 88 files, 716 tests passed |
| Windows UI self-test routines in Chrome | Request activity, timestamp units, keyboard tabs, retained comment/metadata drafts and diff round trips passed; active-tab line editors, draft removal and batch review submission passed; workspace pipeline selection and redacted logs passed |
| `bash macos/Tools/test-request-checks.sh` | Passed |
| `bash macos/Tools/test-pull-request-review.sh` | Passed |
| `bash macos/Tools/test-adaptive-workbench-identity.sh` | Passed |
| Native request/pipeline layout renderer | 12 captures passed OCR content checks at 1440×1000, 1080×800 and 700×800 in light/dark themes |
| Windows React renderer in Chrome | 12 layout captures passed document/detail overflow checks at the same sizes; two additional Checks captures verified log retention across tab switches; no page errors |

Rust was unchanged, so the optional Tauri `cargo check` and shared Rust source-change checks were not run. The npm commands built the required WASM and native helpers with the prepared project Rust toolchain. Chrome UI coverage does not replace the native Windows runner. No real hosting writes, deployments, account changes or installation were performed.

Native captures can be reproduced after building with:

```sh
GITROCHI_REQUEST_LAYOUT_SCENARIOS=activity,pipeline bash macos/Tools/test-request-layout.sh /tmp/gitrochi-request-ui
```

The expanded Windows UI routines remain registered in `windows/src/app/selftest.ts`. Screenshot harnesses use fake HTTP/process entry points and in-memory settings. Results are recorded in [native captures](screenshots/pipeline-requests/native-result.json) and [browser captures](screenshots/pipeline-requests/browser-result.json).

The first Windows CI run exposed a legacy self-test that counted editors in both mounted tabs. Its selector now targets the active tab, and it verifies the edited draft survives switching to Files and back to Conversation before submitting. The updated routine and the existing request/workspace routines passed together in Chrome; the Windows runner verifies the same registered steps.

## Screenshots

| Screen | Light | Dark |
| --- | --- | --- |
| macOS request activity | [1440px](screenshots/pipeline-requests/request-activity-1440-light.png) | [1440px](screenshots/pipeline-requests/request-activity-1440-dark.png) |
| macOS pipeline | [1440px](screenshots/pipeline-requests/request-pipeline-1440-light.png) | [1440px](screenshots/pipeline-requests/request-pipeline-1440-dark.png) |
| Windows request activity | [1440px](screenshots/pipeline-requests/windows-activity-1440-light.png) | [1440px](screenshots/pipeline-requests/windows-activity-1440-dark.png) |
| Windows pipeline | [1440px](screenshots/pipeline-requests/windows-pipeline-1440-light.png) | [1440px](screenshots/pipeline-requests/windows-pipeline-1440-dark.png) |
| Windows checks and retained log | [1440px](screenshots/pipeline-requests/windows-checks-1440-light.png) | [1440px](screenshots/pipeline-requests/windows-checks-1440-dark.png) |
| macOS narrow request | [700px](screenshots/pipeline-requests/request-activity-700-light.png) | [700px](screenshots/pipeline-requests/request-activity-700-dark.png) |
| Windows narrow pipeline | [700px](screenshots/pipeline-requests/windows-pipeline-700-light.png) | [700px](screenshots/pipeline-requests/windows-pipeline-700-dark.png) |
