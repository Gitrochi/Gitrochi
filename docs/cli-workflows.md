# Work across repositories with gitch

Gitrochi includes the same `gitch` CLI on macOS and Windows. Enable the terminal command in **Settings > CLI**, then open a new terminal. Windows also needs Git for Windows. These commands work in Git Bash and through the installed `gitch.cmd` launcher in PowerShell and cmd.

Use a **workspace** to name an explicit group of local repositories. Use a **work item** to record the branches involved in one task across those repositories. CLI groups and work items are local records; they are separate from the app's workspaces and are not uploaded to a cloud service.

The examples below use two existing repositories. Replace their relative paths, the task name, and the issue number with your own values.

## Register and inspect repositories

```sh
gitch workspace create product ../api ../web
gitch workspace list --json
gitch workspace show product --json
gitch workspace status product --json
```

Repositories are registered explicitly. This does not clone repositories, create accounts, or change account locks. Run `gitch workspace --help` for membership and inspection options.

Use `workspace add product <path>` or `workspace remove product <path>` to change membership. `workspace delete product` removes the group record and keeps every repository. A group can contain up to 100 repositories. Membership changes do not alter an existing work item's recorded repositories.

## Start a task

```sh
gitch work start feature-name --workspace product --dry-run --json
gitch work start feature-name --workspace product
gitch work info feature-name --json
gitch work list --json
```

Starting work prepares a task branch in each selected repository and records where each repository started. The CLI checks the repositories before changing branches. Resolve existing changes or an operation in progress first. Use `gitch work --help` to choose an explicit branch, base, or repository instead of a group.

Starting a task uses the available local refs. Fetch the latest changes using your normal repository workflow before starting if the task needs newer remote commits.

`work set feature-name` selects the active work item without switching branches. Actions can use that selection, or specify `--work feature-name` explicitly as below. Use `work add --work feature-name --repo <path>` to prepare the same task branch in another repository.

## Commit, push and create pull requests

Stage the intended files in each repository first, using the app or `git add <file>`. Then run:

```sh
gitch work commit --work feature-name -m "Area: Describe change"
gitch work push --work feature-name
gitch work pr --work feature-name --title "Describe change" --body-file pr.md
```

The commit action uses staged files. Each repository's existing `gitch` command performs the action, retaining its account checks, hooks, secret checks and push protections. PR creation uses the repository's hosting provider, so a GitLab repository creates a merge request through the existing flow. Supply a PR description file appropriate for the repositories you selected.

These are separate Git operations in separate repositories. A failure can leave earlier repositories successfully updated. Inspect the per-repository results and work status before retrying. A repository on an unexpected branch is stopped instead of receiving another task's commit or push.

Supply commit messages and PR descriptions explicitly. The existing `gitch ai` command manages coding-agent integration; work actions do not generate messages with an AI provider.

## Finish a task

```sh
gitch work end feature-name
```

End returns each repository to its recorded branch and keeps the task branch. Resolve uncommitted files or an unexpected branch before ending. Branch deletion is an explicit option described in `gitch work --help`; the normal command preserves the branches and their commits.

Start and end save progress for each repository. If a command is interrupted, inspect `work info` and retry `work end` to return repositories safely, including a branch switch completed just before the interruption. The record remains available after ending. A competing work mutation is refused while another command holds the local work lock.

## Find issues and pull requests

Run these commands inside the repository whose hosting data you want to inspect:

```sh
gitch issue list --json
gitch issue list --state open --label bug --limit 20 --json
gitch issue show 123 --json
gitch pr list --json
gitch pr status --json
```

Hosting commands use the repository's existing account and authentication: GitHub discovery needs an existing account login in `gh`, and GitLab discovery needs `glab` authenticated as that repository account. They do not sign you in or change an account. Provider-specific availability and missing authentication are reported by the command. Issue and PR list JSON wraps the provider's results in `items`, with the provider and repository identified alongside them.

## Inspect Git and worktrees

```sh
gitch git status --short
gitch git log --oneline -10
gitch git diff --stat
gitch wt list --json
```

`gitch git` provides explicit read-only access to a small set of system Git commands. Use `gitch git --help` for supported commands. Use the existing guarded commands for commits, pushes and branch changes. Worktree JSON includes paths, revisions, branches, and detached, locked and prunable states.

The existing repository reader and MCP integration remain available through the app's repository menu. See the [repository reader documentation](../tools/gitrochi-mcp/README.md) for connecting external AI tools.

## Help and shell completion

```sh
gitch help
gitch workspace --help
gitch work --help
gitch issue --help
gitch completion bash
gitch completion zsh
gitch completion fish
gitch completion powershell
```

Completion commands print a script; choose the one for your shell and follow its instructions. Read-only inspection supports JSON output for automation. An error or a partial failure returns a nonzero exit code, so inspect it before proceeding to a later action.

`gitch schema workspace`, `gitch schema work`, `gitch schema hosting`, and `gitch schema worktrees` describe the version 1 JSON contracts. Errors use the existing error schema on standard error; aggregate actions include each repository's output and exit code in their result.

## Workflow reference

The task-oriented multi-repository workflow was informed by the public [GitKraken CLI introduction](https://gitkraken.com/cli) and [work command documentation](https://gitkraken.github.io/gk-cli/docs/gk_work.html). Gitrochi's implementation uses its existing local CLI, account rules and system Git. No GitKraken source code is included.
