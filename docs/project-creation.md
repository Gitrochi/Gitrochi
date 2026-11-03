# Project sources and account capabilities

Home and Projects can work with a local planner or connected GitHub projects. The creation dialog offers Local, Private GitHub and Public GitHub projects, with a review of the destination and visibility before saving.

## Organization projects

Select a connected GitHub account and an organization in **Project scope** on Home or Projects. Opening a local repository is optional. The organization list comes from that account's GitHub memberships, and project lists include only projects the account can read. Organization and project lists have separate pagination. Use **Other organization…** to enter an organization login when a shared project belongs to an organization missing from the membership list. A failure to load organizations does not prevent using personal projects or opening an organization directly.

The selected organization stays with Home-to-Projects navigation and the project creation destination. Changing accounts clears the previous account's organization list. GitHub must grant the connected credential access to both the organization and Projects; use **Connect project access** when the app requests the additional Projects permission.

## Local planning

Local projects require no hosting account or token. Their tasks use the same Overview, Calendar, Board, Table and Roadmap as connected projects, including start/due dates, status, priority, assignees, descriptions, ordering, archive and bulk edits. Home can combine selected local projects into its agenda, week and project summaries. Completion and schedule preferences use a stable local namespace across account changes.

Local data stays in the application's private data directory. It is not uploaded to GitHub, converted into a repository, or synchronized between devices. The native macOS app and the Tauri app use separate application data directories. Current safeguards allow up to 1,000 projects, 10,000 tasks per project and a 50,000,000-byte document. These are local application limits, not GitHub subscription limits.

Storage uses a versioned JSON document, an operating-system file lock, compare-and-swap checks and atomic replacement. Stale edits fail with a refresh instruction. Corrupt or unreadable data does not become an empty document and cannot silently overwrite previous work. Multi-task changes and schedule range shifts save together. Local requests never enter the HTTP or account-credential path.

The local planner has built-in fields. GitHub-only functions—existing issue linking, draft-to-issue conversion, shared views, custom field management and browser links—are available for connected projects. This release does not add local collaboration, dependencies, recurring tasks or notifications.

## GitHub plans and permissions

The dialog reads the authenticated account's optional plan metadata and separately reads the selected project owner's plan when GitHub exposes it. Missing or unrecognized metadata is **Unknown**, never inferred as Free. An organization's project uses the organization's limits; a member's personal Pro subscription does not establish its organization's entitlement.

| Capability | Free | Pro | Team | Enterprise |
| --- | --- | --- | --- | --- |
| Public/private Projects | Available subject to owner and token permissions | Available subject to permissions | Available subject to permissions | Available subject to permissions |
| Total fields per project, including built-in fields | Up to 50 | Up to 50 | Up to 50 | Up to 50 |
| Auto-add item workflows per project | Up to 1 | Up to 5 | Up to 5 | Up to 20 |

The displayed numbers are documented ceilings, not remaining quota. The dialog does not claim to measure existing workflow usage. Creation and publishing permissions may remain unknown until GitHub validates the action. A paid plan does not grant a token access to Projects, organization membership, or permission to publish.

GitHub Free can use private projects. The app does not block private creation simply because an account is Free. It also does not use the deprecated classic Projects `viewerCanCreateProjects` field as a ProjectV2 entitlement.

GitHub creates projects privately. For Public creation the app explicitly publishes the returned project and checks the resulting visibility. If publication fails or the write outcome is uncertain, it preserves the created project reference when available and requires reconciliation. Pending creation attempts survive closing the dialog or restarting the app. A successful full project refresh clears the retry lock; a failed or incomplete refresh does not. The app never silently retries creation or upgrades an account.

Plan information checked against GitHub's official documentation on 2026-10-27:

- [Projects and the total-field limit](https://docs.github.com/en/issues/planning-and-tracking-with-projects/learning-about-projects/about-projects)
- [Auto-add workflow limits by plan](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/adding-items-automatically)
- [GitHub account types](https://docs.github.com/en/get-started/learning-about-github/types-of-github-accounts)

## Validation

The backend checks use isolated storage and synthetic transports. They cover local persistence and restart, corrupt-data preservation, stale revisions, atomic bulk/date changes, remote/local source boundaries, unknown plans, owner/account plan separation, Free private creation and uncertain publication recovery. UI fixtures exercise the production views in light and dark themes; remote project writes are blocked in these fixtures. Final validation passed 539 Windows tests, four browser selftests, 56 macOS workspace/navigation scenarios, eight macOS creation scenarios, three native storage tests and both application builds. The macOS build retains its existing Keychain deprecation and Rust deployment-target linker warnings.

Organization discovery checks cover repository-free organization queries, project and membership pagination, retry, stale account responses, explicit organization creation and the Home-to-Projects task handoff. Validation passed 934 Windows tests, 83 integration regression checks in the existing workspace, the organization browser self-test, both application builds, and 104 native English/Korean layout scenarios with no unexpected network requests. Existing macOS dependency/Keychain warnings and the Windows bundle-size warning remain. Rust was unchanged, so `cargo check` was skipped. The separate `gitch test --affected --summary` command stopped with `TRUST-01` because its flow requires human approval; it was not counted as a pass.

## Screenshots

Synthetic data, with no user accounts or projects:

Organization projects without an open repository: [Light](screenshots/organization-projects/windows-home-light.jpg) · [Dark](screenshots/organization-projects/windows-home-dark.jpg).

![macOS private project on GitHub Free](screenshots/project-creation/macos-private-free-light.png)

![macOS public project on GitHub Pro, dark theme](screenshots/project-creation/macos-public-pro-dark.png)

![macOS local planning dashboard](screenshots/project-creation/macos-local-home-light.png)

![Windows local planning dashboard](screenshots/project-creation/windows-local-home-light.png)
