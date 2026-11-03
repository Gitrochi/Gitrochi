# Project scheduling

Home and Projects use the same GitHub Projects items and date-field settings. Schedules are all-day dates stored in the selected project's fields; no second task database is created.

## Home

Choose a connected GitHub account, a personal, organization or repository-owner scope, and the projects to include. Organization projects work without opening a repository: select an organization from **Project scope** to load its accessible projects. Use **Load more organizations** when the account belongs to more organizations than the first page shows. The selection is remembered on this device for that account and scope. Home initially loads three projects; add others with **Choose projects** and **Load more projects**.

The agenda groups attention around overdue, today, next seven days, unscheduled and completed work. Search titles, projects, repositories and assignees, or limit the agenda to work assigned to you. Use **Show more tasks** to expand the agenda beyond its initial rows. Week and Projects views show dated work and each project's loaded progress. Opening a task takes you to its project inspector and local development actions.

An issue or pull request included in several selected projects is counted once. An active membership takes precedence over completed memberships, and the earliest valid active date determines the displayed schedule. Drafts remain separate project tasks. GitHub item queries read every page before publishing a project's snapshot, so initial loads and refreshes include later issues and drafts. A failed refresh preserves previously loaded work and marks it as potentially out of date. Project catalogs remain paginated independently of their items.

## Complete project lists

A GitHub project with no saved view opens in Table/List, including closed issues, completed work and undated drafts. Existing saved view choices remain available. The scheduling Overview is a focused summary; **View all tasks** opens the complete list and clears its task filters, including the archive filter. Restricted content remains a placeholder when GitHub does not permit the account to read it.

Initial reads, edits, item creation and Home refreshes use the same complete item loader. It follows item cursors without a fixed page limit, keeps server ordering, deduplicates project-item IDs and checks the captured account/project context on every page. A missing, repeated or cyclic cursor is an error rather than a successful partial result. No live project items are changed while reading.

## Project overview and calendar

Overview combines attention filters, an agenda, status distribution, upcoming deadlines and task counts by assignee. Workload is a count of actual tasks, not estimated effort or capacity; tasks with several assignees count for each person.

Use **Schedule settings** to select the project's start date, due date and status fields. Completion options are explicit: choose the status values that mean completed for this project. Closed issues and merged pull requests are also complete. Changing a project status does not close its linked issue.

Calendar has month and week views, an undated-task drawer, date-range display, date editing and day agendas. Move a task to a day to set its due date. If both start and due dates exist, the whole range shifts by the same number of days. A task with only a start field uses that field. Invalid dates and reversed ranges are surfaced for correction.

Review the proposed field changes before saving. The app checks the current server dates before a move; concurrent changes require a refresh. If a multi-field save may have partly succeeded, further writes wait for a successful refresh.

Board, Table, Roadmap, shared views, custom fields and local branch/PR actions remain available alongside scheduling. GitLab issue boards retain their existing Board, Table and Roadmap views; this scheduling integration uses GitHub Projects date fields.

## Preview

These captures use synthetic project and account data.

| Screen | macOS | Windows |
| --- | --- | --- |
| Home | [Light](screenshots/project-scheduling/macos-home-light.png) · [Dark](screenshots/project-scheduling/macos-home-dark.png) | [Light](screenshots/project-scheduling/windows-home-light.png) · [Dark](screenshots/project-scheduling/windows-home-dark.png) |
| Overview | [Light](screenshots/project-scheduling/macos-overview-light.png) · [Dark](screenshots/project-scheduling/macos-overview-dark.png) | [Light](screenshots/project-scheduling/windows-overview-light.png) · [Dark](screenshots/project-scheduling/windows-overview-dark.png) |
| Calendar | [Light](screenshots/project-scheduling/macos-calendar-light.png) · [Dark](screenshots/project-scheduling/macos-calendar-dark.png) | [Light](screenshots/project-scheduling/windows-calendar-light.png) · [Dark](screenshots/project-scheduling/windows-calendar-dark.png) |

## Validation

- Windows: `npm run build`; `npm test` (521 tests in 60 files); real React browser self-tests for portfolio navigation, scheduling and existing project operations.
- macOS: `macos/build.sh`; `test-project-schedule.sh`, `test-project-portfolio.sh` and `test-project-scheduling.sh`; 50 synthetic native layout and navigation scenarios, including light/dark, narrow windows, empty projects, explicit field settings and requested-task inspectors.
- Synthetic native scenarios made no unexpected network requests. Date editor captures were checked in both appearances.
- Rust was unchanged in this scheduling change, so `cargo check` was skipped.
- The local macOS build succeeds with 13 existing warnings: two legacy Keychain API deprecations and eleven Rust standard-library deployment-target linker warnings. It is not a warning-free build.
- The final macOS app was launched and its live account/project catalog, Home-to-project navigation, localized labels and accessibility names were checked. Live task data was not modified.

### Complete-item loading

The item-completeness regression checks cover more than two pages of mixed issues, drafts, archived items and restricted placeholders; sparse and duplicate-only pages; cursor failures; account changes; and edits/creation followed by complete refresh. The Windows suite passed 945 tests, and 63 targeted integration regressions passed in the existing workspace. The real browser fixture read 203 synthetic items through the production loader and verified full-list navigation and the expandable Home agenda. The macOS transport, hosting and portfolio scripts passed; the production query was also checked read-only against a connected project without saving its content or changing its items.

Both application builds passed with the existing warnings. The macOS native fixture passed 104 English/Korean scenarios with no unexpected network requests.

The `gitch test --affected --summary` wrapper still requires human flow approval (`TRUST-01`) and is not counted as a pass. Rust is unchanged, so `cargo check` is skipped. Existing build warnings remain documented above.

Synthetic full-list captures: [Light](screenshots/project-item-completeness/windows-list-light.jpg) · [Dark](screenshots/project-item-completeness/windows-list-dark.jpg).
