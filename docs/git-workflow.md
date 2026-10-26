# Git workflow

Branches, commit messages and pull requests. Run `git config core.hooksPath .githooks` once after cloning: the hooks check these rules when you commit and push, and the same script ([`.githooks/rules.sh`](../.githooks/rules.sh)) runs in GitHub Actions as the **Git rules** check, so a pull request that breaks them cannot be merged.

## Branches

- `main` always builds and can be released. Work happens on a branch taken from `main`.
- Name it `kind/topic`, in lower-case letters, digits and `-`: `feature/ci-branch-view`, `fix/narrow-graph`, `refactor/…`, `docs/…`, `ci/…`; version bumps are `release/0.3.12`.
- One topic per branch. Don't let it age: `git fetch && git rebase origin/main` (don't merge `main` into it).
- **`main` changes only through pull requests.** A GitHub ruleset blocks direct pushes, force pushes and deletion (administrators included), and the Git rules check must pass before merging. The local pre-push hook also refuses a push to `main`.
- **Collaborators** (write access) create branches in this repository and merge pull requests. A collaborator's pull request needs **one approval from someone else** (a new push dismisses it); administrators merge their own without one.
- You may rewrite your own pull-request branch with `git push --force-with-lease`.
- A change that depends on another open pull request can be stacked: branch from that branch and open the pull request against it. GitHub retargets it to `main` when the base is merged.

## Commit messages

People from many countries read the history, so **commit messages are in English** and every subject has an area prefix:

```
Area: Imperative summary of the change

- Why, or one bullet per notable change
- Another change
```

- The subject is `Area: Summary`. **The area is required.** Use the part of the app the change is about: `Graph`, `Sidebar`, `Inspector`, `Terminal`, `Diff`, `CI/CD`, `Agents`, `Settings`, `i18n`, `Perf`, `README`, `Docs`, `CI`, `gitch`. Use `macOS` or `Windows` only when the change really is about one platform (a platform-specific fix); a feature done on both sides takes the feature's area. One space after the colon.
- The summary is **imperative**: `Add …`, `Fix …`, `Show …` (not `Added`, `Fixes`, `Updating`). Examples: `Graph: Show avatars in the inspector`, `Windows: Fix the layout on narrow windows`, `Terminal: Type dropped files as paths`.
- If you must quote text that is not English (a translated label, say), wrap it in backticks: `` `탐색기에서 보기` ``. Names in trailers such as `Co-Authored-By:` may stay as they are.
- The hook checks: English (Latin letters and punctuation) · subject within 100 characters · no period at the end · the area and one space after the colon · imperative mood · a blank line after the subject · no empty subjects like `wip`, `fix`, `update`.
- Squash `fixup!` and `squash!` commits before opening the pull request: `git rebase -i --autosquash origin/main`.
- One topic per commit. Keep tidying (moving files) apart from behaviour changes, and make every commit build, so `git bisect` stays useful.
- Only administrators make the version commit `Release 0.3.12 (summary)` and the tag `v0.3.12` (see [release.md](release.md)).
- History from before these rules (Korean messages) stays as it is.

## Pull requests

1. Branch from `main` (see Branches above) and keep the pull request to one topic.
2. Pass the checks: macOS build without warnings; Windows `npm run build`, `npm test`, `cargo check --manifest-path src-tauri/Cargo.toml` from `windows/`; shared Rust formatting, tests and Clippy when changed (see [code-style.md](code-style.md#tests-and-verification)). Changed a screen? Attach light and dark screenshots.
3. Fill in the pull request template's checklist. CI (the Windows self-test and the Git rules) must pass before merging.
   - The Windows CI builds and runs the real-app self-test for every pull request that touches `windows/` (about nine minutes; a new push cancels the previous run). It is not a required check, so auto-merge does not wait for it — look at the result in the pull request.
   - Signed installers, the update-signature check and the README screenshots run only for `v*` tags and manual runs (Actions › Windows › Run workflow).
4. Merge with a merge commit so each pull request stays one unit in the history. `gh pr merge --auto --merge` merges as soon as the checks pass and deletes the branch.
5. Contribution rights: identify third-party code in the pull request with its origin and license, and keep its notices. The [Community Use License](../LICENSE) and [CLA v1.0](../CLA.md) are proposals that are not in effect; once adopted, each rights holder posts the assent comment described in CLA.md and the maintainer verifies it before merging (see [CONTRIBUTING.md](../CONTRIBUTING.md)). Nothing is collected before that.

### Fixing a pull request the checks rejected

Leave the code, rewrite the commit messages, force-push the same branch; the pull request carries on.

```sh
git remote add upstream https://github.com/Gitrochi/Gitrochi.git   # once, if you work from a fork
git fetch upstream
git rebase -i upstream/main        # change pick to reword (r) on the commits to fix, then write them in English
git push --force-with-lease
```

With a single commit, `git commit --amend` then `git push --force-with-lease`. If a contributor cannot fix it, a maintainer can do the same on the branch when **Allow edits by maintainers** is on.

## What never goes into a commit

The hook refuses:

- **Secrets**: private keys, update signing keys, GitHub, GitLab, Anthropic, Slack and AWS tokens. If one slipped in, **revoke the key** — removing the commit is not enough.
- **Paths on your machine**: `/Users/<name>/`, `/home/<name>/`, `C:\Users\<name>\`. Write examples as `/Users/me`.
- Build output and dependencies (`dist/`, `target/`, `.build/`, `node_modules/`), `.DS_Store`, `.env`, key files (`*.key`, `*.pem`), files over 2 MB.
- Trailing whitespace, files ending in blank lines, leftover conflict markers (`<<<<<<<`). Text is stored with LF ([`.gitattributes`](../.gitattributes)).

What the hook cannot catch: company and person names, internal hostnames, personal emails. Look at `git diff --cached` before you push.
