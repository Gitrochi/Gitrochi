# Contributing

Thank you for your interest in Gitrochi. Report bugs and request features in [issues](https://github.com/Gitrochi/Gitrochi/issues/new/choose); send code as pull requests. Issues, pull requests and discussion are in English.

The rules live in `docs/`. Coding agents read the same rules from [AGENTS.md](AGENTS.md) (Codex and others) and [CLAUDE.md](CLAUDE.md) (Claude Code).

## Contributors

- [ChoMnSeong](https://github.com/ChoMnSeong)
- [jjunhaa0211](https://github.com/jjunhaa0211) — gitch CLI, multi-language structure analysis, app integration and verification

The existing copyright notices are preserved in [LICENSE](LICENSE); the notice that applies to earlier code is in the [combined notices](THIRD_PARTY_NOTICES.md#prior-mit-covered-gitrochi-material). The licensing contacts on record are ChoMnSeong <chemins60217@gmail.com> and jjunhaa0211 <goodjunha@gmail.com>. A contact having been provided does not by itself confirm the rights to every contribution or consent to a license change.

## Use, distribution and the official contribution path

**Current status: Gitrochi Community Use License v1.0 and CLA v1.0 are proposals and are not yet in effect.** Until the rights holders, consents and scope in the [licensing review](docs/licensing-review.md) (Korean) are confirmed and the adoption record is complete, the existing MIT permissions stay as they are. The policy and the CLA process below are a proposal for material confirmed as covered after that adoption. Past contributors are not treated as having agreed automatically.

- Individuals and businesses may install, run and use Gitrochi for internal business free of charge. The Gitrochi license does not spread to the ordinary results of commercial work done with it.
- You may modify and build Gitrochi privately, for yourself or inside your organization. Using it or modifying it privately does not oblige you to publish code or to open a pull request.
- Under the new policy, unauthorized resale or paid repackaging of Gitrochi itself and the outside distribution of independent derivative projects are restricted. That includes free derivative distribution; rights separately granted by the existing MIT license, third-party licenses, the law and GitHub's terms are kept.
- Sharing an unchanged official release for free follows the notice-preservation conditions in LICENSE. The new policy is a **source-available** policy, not an OSI-approved open-source license.
- Code and documentation for the project are submitted only through [pull requests to the official repository](https://github.com/Gitrochi/Gitrochi/pulls). Contribution forks and branches, and patches for review, are allowed; they are not a permission to distribute an independent product. The right to view and fork under GitHub's terms stays whether or not a pull request follows.
- Exceptions for resale or outside distribution are requested through the two licensing contacts. They need written approval from the rights holders over the material in question; silence or repository maintenance access does not count as approval.

The exact scope and conditions are those of [LICENSE](LICENSE). Bug reports, feature requests and security reports use the existing issue and [security](SECURITY.md) channels and need no CLA; submitting a code or documentation patch follows the process for covered contributions.

## Contributor CLA assent

[CLA.md](CLA.md) is a proposal under which contributors keep ownership and grant the official Gitrochi project a non-exclusive permission to use the identified original contribution under the v1.0 terms. It is not a blanket consent to every future license and not a copyright assignment. **Until the legal identity and authority of the CLA grantees and the private verification procedure are settled, no assent is collected or treated as a valid agreement.**

After adoption, a maintainer checks the following by hand before merging. There is no automated CLA bot or required check today.

1. Each contributing rights holder, or their authorized representative, reads the approved full text of CLA v1.0, through the permanent link that contains the approved document's commit SHA.
2. They post the [assent statement from CLA.md](CLA.md#5-express-assent-and-records) **as a comment on the pull request from their own account**, naming the pull request URL and the full commit SHA or explicit SHA range of their contribution. Opening the pull request, a checkbox or a commit sign-off is not taken as CLA assent.
3. With co-authors, each rights holder's assent is checked. If an employer or another entity holds the rights, a representative whose authority has been confirmed must assent. Third-party code is identified in the pull request with its origin, license and whether it was modified; its notices are kept, and the CLA does not cover it.
4. The maintainer records in the pull request the permanent link to the assent comment, the CLA version and its permanent link, the covered SHAs and the verification result per rights holder. Unverified contributions are not merged.
5. When commits, authors or the terms change, assent is obtained again for the affected scope. Do not put sensitive identity or employment documents in a public pull request; ask the licensing contacts about the agreed private procedure.

Never write or tick CLA assent on someone else's behalf. The checklist in the proposal pull request itself is not a substitute for the existing rights holders' adoption approval or for a CLA signature.

## Getting started

| | macOS | Windows |
|---|---|---|
| Where | `macos/` (SwiftUI, macOS 15+) | `windows/` (Tauri 2: Rust + React/TypeScript) |
| Needs | Swift 6 or later (Xcode or Command Line Tools), Rust 1.88+ | Node.js 22+, Rust 1.88+, the `wasm32-unknown-unknown` target |
| Build | `macos/build.sh` | `cd windows && npm ci && npx tauri build` |
| Check | builds with no errors or warnings | `npm run build` · `npm test` · `cargo check --manifest-path src-tauri/Cargo.toml` |

- After cloning, run `git config core.hooksPath .githooks` once: the hooks check the Git rules when you commit and push.
- The Windows app runs on a Mac too: `npx tauri dev` (its data folder is separate, `Gitrochi (Tauri)`).
- Changed a screen? Check it with the demo repository (`docs/make-demo-repo.sh <folder>`) and attach light and dark screenshots to the pull request.
- The tests for the bundled helpers (gitch, gitch-swift-index) and the version check are in [docs/code-style.md](docs/code-style.md#tests-and-verification).

## Shared core and verification

Git parsing, diff and partial patches, conflict parsing, graph layout and CLI analysis share a [Rust core](crates/README.md). Install Rust through rustup; add `wasm32-unknown-unknown` before building Windows, and `aarch64-apple-darwin` plus `x86_64-apple-darwin` for a universal macOS release. Users of packaged releases do not need Rust.

`npm ci` and `npm run build`, `npm test` or `npm run dev` in `windows/` generate the WASM core and native helper. Before running `tsc` or `vitest` directly, run `npm run core`. Keep Cargo lockfiles; do not commit `target/`, generated WASM or generated binaries. The macOS builder links and signs the native core; `GITROCHI_BUILD_DIR` and `GITROCHI_OBJECT_DIR` can separate concurrent builds, and `GITROCHI_CARGO` selects a Rust executable.

Run the feature-specific checks listed in [code-style.md](docs/code-style.md#tests-and-verification). The [review](docs/review-workflows-validation.md), [extended workflows](docs/complete-workflows-validation.md) and [navigation](docs/navigation-workspace-validation.md) records (Korean) describe the implementation, fixtures and limits of earlier checks. They are not a claim that real-server writes or Windows device installation were verified in this change.

## Rules

- [docs/code-style.md](docs/code-style.md) — layout, both platforms together, code rules (Swift · TypeScript · Rust · comments · performance), screen text and translations, privacy and secrets, tests
- [docs/git-workflow.md](docs/git-workflow.md) — branches, commit messages, pull requests, what never goes into a commit
- [AGENTS.md](AGENTS.md) · [CLAUDE.md](CLAUDE.md) — the same rules, summarized for coding agents

The ones to remember:

- **A feature goes into both the macOS and the Windows app.** If it can only work on one, say why in the pull request.
- **Commit subjects are `Area: Summary`** — English, imperative, and the area is required. Examples: `Graph: Show avatars in the inspector`, `Terminal: Type dropped files as paths`. A feature done on both sides takes its own area (`Graph`, `Sidebar` …); a fix for one platform takes `macOS` or `Windows`.
- **Screen text is English in the code.** A new string gets its Korean (`ko`) translation, and as many of the other languages as you can, in the same pull request.
- **Comments are English, short, and say why.** Older Korean comments are being converted over time.
- **Tokens live only in the Keychain or the Credential Manager.** No company or person names, internal hostnames or paths on your machine in a commit.

## Pull requests

1. Branch from `main` (`feature/…`, `fix/…`, `docs/…`). One topic per pull request.
2. Pass the checks above (build · `tsc` · `vitest` · `cargo check`). Changed a screen? Attach light and dark screenshots.
3. Fill in the pull request template's checklist. CI (the Windows self-test and the Git rules) must pass before merging.
4. Merge with a merge commit, so each pull request stays one unit in the history. `gh pr merge --auto --merge` merges as soon as the checks pass and deletes the branch.

The details — collaborator permissions, stacked pull requests, fixing a pull request the checks rejected, what the Windows CI does — are in [docs/git-workflow.md](docs/git-workflow.md).

## Releases

Maintainers only: [docs/release.md](docs/release.md).
