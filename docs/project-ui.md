# Project workspace layout

The project workspace uses a consistent hierarchy: source and account, project title and primary task action, view navigation, then search and filters. The branch remains in the repository chrome. Local projects show task counts without empty issue or pull-request metrics.

Projects retains its own page in the three-column workspace. Home combines the planning dashboard with repository welcome actions, recent repositories and remote repository search. Opening local changes or a linked pull request uses the current repository and review routes. Local planning loads from device storage without waiting for saved account access.

Table headers and rows start at the top of the work surface, even with one task. Local tables omit the repository column. Board columns use neutral backgrounds and a compact empty state; cards display actual status, priority, dates and assignees when available. The roadmap keeps date-field configuration in a settings menu and places Schedule beside each undated task.

Normal task, date, field and project metadata edits save once. Editors show progress, prevent duplicate submissions and keep inputs when saving fails. Consequential operations retain a review with the captured project, affected items and an explicit action. Local task removal explains that the task is permanently deleted from the device. Public project creation reviews the destination and visibility inside the creation sheet.

Compact inspector actions wait for the inspector to close before presenting another editor or review, avoiding competing sheets. Existing account, context, stale-edit and uncertain-write guards remain in place.

Board columns include a focused task-title form. Return submits once, Escape cancels, and failed saves retain the title and show an inline error. Creating inside a column assigns the captured grouping option: local creation is atomic; remote creation uses the returned item ID, with uncertain results requiring refresh. Changing projects or grouping resets the form. The overview also offers direct New task and Open calendar actions.

The inspector groups assignees, status, priority, labels and dates. Status and priority can be changed directly in the inspector and table; local required fields cannot be cleared. Cards display available author and creation metadata, and merged pull requests retain their Merged badge.

Linked issues and pull requests show their opening description and a GitHub-style conversation, with actual author names, timestamps, Markdown and pagination. Refresh failures preserve the loaded discussion. The composer submits once with Command+Return on macOS or Control+Enter on Windows, retains failed input, and shows a factual posted notice after success. It never fabricates an appended server comment. A delayed result cannot clear a different task's draft. Local tasks do not expose a remote comment composer.

## Saved account access

On macOS, an offline verification, rate limit, permission error or server failure no longer discards a token that was successfully read from Keychain. Temporary Keychain denials preserve an already restored session. Saved accounts awaiting access are identified as connected accounts with an explicit restore action, rather than being presented as signed out. App activation silently retries eligible temporary failures with a minimum interval; missing, removed and rejected credentials are not automatically restored.

Development builds without a stable signing identity use ad-hoc signing. Replacing one of those builds may still require macOS Keychain approval. The session fix does not weaken Keychain access controls or store credentials outside Keychain. See [Apple's code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Native previews

These screenshots use isolated synthetic projects; they contain no user data.

![Korean table with a single task](screenshots/project-ui/mac-table-ko-light-1080.png)

![Compact board in dark mode](screenshots/project-ui/mac-board-ko-dark-1080.png)

![Undated task with an inline scheduling action](screenshots/project-ui/mac-roadmap-ko-light-1080.png)

![Task removal review](screenshots/project-ui/mac-remove-review-dark.png)

![Public project creation review](screenshots/project-ui/macos-public-review-light.png)

![Inline task creation inside its board column](screenshots/project-ui/mac-inline-add-light.png)

![Issue description and conversation in dark mode](screenshots/project-ui/mac-conversation-dark.png)

## Windows previews

![Korean project table](screenshots/project-ui/windows-table-ko-light.png)

![Contextual removal review](screenshots/project-ui/windows-remove-review-ko-light.png)

![Inline task creation in the selected board column](screenshots/project-ui/windows-quick-add-ko-dark.png)

![Markdown conversation and comment composer](screenshots/project-ui/windows-conversation-ko-light.png)

## Verification

- `npm run build` and `npm test` in `windows/`.
- Five real Korean browser selftests: hosting projects, scheduling, Home portfolio, local planning and complete workspace pages. The workspace fixture distinguishes GraphQL reads from writes, returns REST pull-request collections, and checks navigation using the complete Issues page and its header.
- `bash macos/Tools/test-window-content-layout.sh`: 37 normal-display and 37 constrained-display scenarios, including real repository tabs, sidebar changes and exact frame restoration.
- `bash macos/Tools/test-project-workspace-layout.sh`: production workspace, sparse table/board/roadmap, date editor, review and account-free local navigation in both themes and English/Korean.
- `bash macos/Tools/test-project-creation-layout.sh`: local, Free private, Pro public and unknown-plan creation forms/reviews in both themes, with remote writes blocked.
- `bash macos/Tools/test-project-task-creation.sh`: canonical field validation, atomic local creation and remote partial-write handling.
- `bash macos/Tools/test-credential-access.sh` and `bash macos/Tools/test-saved-account-verification.sh`: saved-access recovery, transient verification failures, token rotation and rejection/removal regressions.
- `bash macos/build.sh` and a read-only smoke check of the built application.

Native and browser fixtures use isolated preferences/storage and synthetic credentials. The window fixture also isolates the real Home view's local-project storage and blocks network access. Conversations use synthetic read responses and injected write callbacks. There are no shared Rust core changes. The native build retains two existing Keychain deprecation warnings.

The integrated workspace passed 104 native workspace/editor scenarios and 20 creation scenarios, including temporary Keychain denial and unavailable saved credentials in both themes. The window, workspace and creation fixtures compiled all 203 current Swift production sources, with source snapshots checked against the working files. Windows passed 584 tests in 70 files, five real Korean browser selftests and a locked Tauri check. Authentication regressions cover both automatic preparation and lifecycle retries, legacy fallback rejection, temporary Keychain failures, newer-token rotation and account removal. No real project or comment writes were used for validation.
