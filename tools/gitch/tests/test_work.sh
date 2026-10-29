# Work item tests use temporary HOME and local fake hosting only.
# shellcheck shell=bash

work_fixture() {
  mk_config
  install_quiet
  mk_remote_seeded github-alice alice/work-one alice@example.com
  mk_remote_seeded github-alice alice/work-two alice@example.com
  WORK_ONE="$HOME/Develop/alice/work one"
  WORK_TWO="$HOME/Develop/alice/work two"
  gitch clone alice alice/work-one "$WORK_ONE" >/dev/null 2>&1 || fail 'clone work one'
  gitch clone alice alice/work-two "$WORK_TWO" >/dev/null 2>&1 || fail 'clone work two'
  cd "$WORK_ONE" || fail cd
  WORK_RECORD="$HOME/.local/state/gitsw/work"
}

test_work_start_info_list_and_preserving_end() {
  work_fixture
  git switch -q -c original
  run gitch work start sample --repo "$WORK_ONE" --repo "$WORK_TWO" --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results | length')" 2
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" feature/sample
  assert_eq "$(git -C "$WORK_TWO" branch --show-current)" feature/sample
  run gitch work info --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.repositories[0].originalBranch')" original
  assert_eq "$(printf '%s' "$OUT" | jq -r '.repositories[1].matchesBranch')" true
  run gitch work list --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.workItems[0].active')" true
  run gitch work end --json; assert_ok; assert_json "$OUT"
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" original
  assert_eq "$(git -C "$WORK_TWO" branch --show-current)" main
  git show-ref --verify --quiet refs/heads/feature/sample || fail 'end deleted work branch'
  run gitch work status sample --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r '.state')" ended
  [ ! -e "$WORK_RECORD/active" ] || fail 'ended item remains active'
}

test_work_start_preflights_every_repository() {
  work_fixture
  echo dirty > "$WORK_TWO/untracked.txt"
  run gitch work start blocked --repo "$WORK_ONE" --repo "$WORK_TWO" --json
  assert_fail; assert_json "$OUT"; assert_out 'untracked changes'
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" main
  git show-ref --verify --quiet refs/heads/feature/blocked && fail 'first branch created before all checks'
  [ ! -e "$WORK_RECORD/blocked.config" ] || fail 'failed preflight wrote work record'
  rm "$WORK_TWO/untracked.txt"
  git -C "$WORK_TWO" branch feature/duplicate
  run gitch work start duplicate --repo "$WORK_ONE" --repo "$WORK_TWO"
  assert_fail; assert_out 'already exists'
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" main
}

test_work_start_rejects_detached_and_operations() {
  work_fixture
  git switch -q --detach
  run gitch work start detached; assert_fail; assert_out detached
  git switch -q main
  git rev-parse HEAD > .git/MERGE_HEAD
  run gitch work start merging; assert_fail; assert_out 'operation in progress'
  rm .git/MERGE_HEAD
}

test_work_start_uses_cached_base_and_explicit_branch() {
  work_fixture
  git switch -q -c original
  git branch -q -d main
  run gitch work start cached --branch fix/cached --base origin/main --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git branch --show-current)" fix/cached
  assert_eq "$(git config --file "$WORK_RECORD/cached.config" repo.0.base)" refs/remotes/origin/main
  run gitch work end; assert_ok
  assert_eq "$(git branch --show-current)" original
  run gitch work start unavailable --base missing
  assert_fail; assert_out 'unavailable locally'
  [ ! -e "$WORK_RECORD/unavailable.config" ] || fail 'unavailable base wrote work record'
}

test_work_start_rejects_duplicate_worktrees() {
  work_fixture
  git worktree add -q -b other "$T/other worktree"
  run gitch work start duplicate --repo "$WORK_ONE" --repo "$T/other worktree"
  assert_fail; assert_out 'two worktrees of the same repository'
  assert_eq "$(git branch --show-current)" main
}

test_work_dry_run_does_not_create_state_or_branches() {
  work_fixture
  run gitch work start preview --repo "$WORK_ONE" --repo "$WORK_TWO" --dry-run --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .dryRun)" true
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results[0].status')" planned
  [ ! -e "$WORK_RECORD" ] || fail 'dry run created state'
  assert_eq "$(git branch --show-current)" main
  run gitch work start actual; assert_ok
  run gitch work end --dry-run --json; assert_ok; assert_json "$OUT"
  assert_eq "$(git branch --show-current)" feature/actual
}

test_work_commit_defaults_to_staged_files() {
  work_fixture
  gitch work start staged --repo "$WORK_ONE" --repo "$WORK_TWO" >/dev/null || fail start
  echo staged > "$WORK_ONE/staged.txt"
  git -C "$WORK_ONE" add staged.txt
  echo unstaged > "$WORK_ONE/unstaged.txt"
  echo untouched > "$WORK_TWO/untouched.txt"
  run gitch work commit -m 'gitch: Add staged fixture' --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results[1].status')" skipped
  assert_eq "$(git -C "$WORK_ONE" show --format= --name-only HEAD)" staged.txt
  assert_eq "$(git -C "$WORK_TWO" rev-list --count HEAD)" 1
  [ -f "$WORK_ONE/unstaged.txt" ] || fail 'unstaged file disappeared'
  run gitch work commit -a -m 'gitch: Include explicit all' --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git -C "$WORK_TWO" show --format= --name-only HEAD)" untouched.txt
}

test_work_actions_report_partial_failures_and_preserve_branch_identity() {
  work_fixture
  gitch work start partial --repo "$WORK_ONE" --repo "$WORK_TWO" >/dev/null || fail start
  git -C "$WORK_TWO" switch -q main
  echo staged > "$WORK_ONE/staged.txt"; git -C "$WORK_ONE" add staged.txt
  echo other > "$WORK_TWO/other.txt"; git -C "$WORK_TWO" add other.txt
  run gitch work commit -m 'gitch: Add partial fixture' --work partial --json
  assert_fail; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .success)" false
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results[0].status')" ok
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results[1].status')" failed
  assert_eq "$(git -C "$WORK_TWO" rev-list --count HEAD)" 1
  [ -f "$WORK_RECORD/partial.config" ] || fail 'partial action deleted record'
}

test_work_end_preflights_every_repository() {
  work_fixture
  gitch work start ending --repo "$WORK_ONE" --repo "$WORK_TWO" >/dev/null || fail start
  echo dirty > "$WORK_TWO/dirty.txt"
  run gitch work end --json; assert_fail; assert_json "$OUT"
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" feature/ending
  assert_eq "$(git config --file "$WORK_RECORD/ending.config" work.state)" active
}

test_work_end_deletion_requires_confirmation_and_base_merge() {
  work_fixture
  gitch work start unmerged >/dev/null || fail start
  echo change > change.txt; git add change.txt
  gitch c -m 'gitch: Add work fixture' >/dev/null || fail commit
  run gitch work end --delete-branch --yes --json
  assert_fail; assert_json "$OUT"; assert_out 'not merged'
  assert_eq "$(git branch --show-current)" feature/unmerged
  git branch -f main HEAD
  run gitch work end --delete-branch --json
  assert_rc 2; assert_json "$OUT"
  assert_eq "$(git branch --show-current)" feature/unmerged
  run gitch work end --delete-branch --yes --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git branch --show-current)" main
  if git show-ref --verify --quiet refs/heads/feature/unmerged; then fail 'merged work branch remains'; fi
}

test_work_add_and_set_keep_explicit_item_selection() {
  work_fixture
  gitch work start first >/dev/null || fail start
  run gitch work add --repo "$WORK_TWO" --work first --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git -C "$WORK_TWO" branch --show-current)" feature/first
  gitch work end first >/dev/null || fail end
  gitch work start second >/dev/null || fail start
  cd "$WORK_TWO" || fail cd
  gitch work start third >/dev/null || fail start
  run gitch work set second --json; assert_ok; assert_json "$OUT"
  assert_eq "$(cat "$WORK_RECORD/active")" second
  assert_eq "$(git branch --show-current)" feature/third
  run gitch work info --work third --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .name)" third
  assert_eq "$(cat "$WORK_RECORD/active")" second
}

test_work_start_accepts_local_workspace() {
  work_fixture
  gitch workspace create services "$WORK_ONE" "$WORK_TWO" >/dev/null || fail workspace
  run gitch work start grouped --workspace services --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results | length')" 2
}

test_work_rejects_invalid_names_ai_and_unsafe_state() {
  work_fixture
  run gitch work start ../escape --json; assert_fail; assert_json "$OUT"
  run gitch work start bad/name --json; assert_fail; assert_json "$OUT"
  run gitch work commit --ai --json; assert_fail; assert_json "$OUT"; assert_out 'not supported'
  gitch work start safe >/dev/null || fail start
  mkdir "$WORK_RECORD/.lock"
  run gitch work end --json; assert_fail; assert_json "$OUT"; assert_out 'Another work command'
  rmdir "$WORK_RECORD/.lock"
  mv "$WORK_RECORD/safe.config" "$T/safe.config"
  ln -s "$T/safe.config" "$WORK_RECORD/safe.config"
  run gitch work info safe --json; assert_fail; assert_json "$OUT"
  rm "$WORK_RECORD/safe.config"
  cp "$T/safe.config" "$WORK_RECORD/safe.config"
  git config --file "$WORK_RECORD/safe.config" repo.0.phase unknown
  run gitch work info safe --json; assert_fail; assert_json "$OUT"; assert_out 'Invalid repository work phase'
}

test_work_relative_body_and_message_files_use_caller_directory() {
  work_fixture
  gitch work start files --repo "$WORK_ONE" --repo "$WORK_TWO" >/dev/null || fail start
  echo first > "$WORK_ONE/first.txt"; git -C "$WORK_ONE" add first.txt
  echo second > "$WORK_TWO/second.txt"; git -C "$WORK_TWO" add second.txt
  cd "$T" || fail cd
  printf 'gitch: Read caller message\n' > message.txt
  run gitch work commit -F message.txt --work files --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git -C "$WORK_ONE" log -1 --format=%s)" 'gitch: Read caller message'
  assert_eq "$(git -C "$WORK_TWO" log -1 --format=%s)" 'gitch: Read caller message'
  printf 'Description from caller.\n' > pr.txt
  echo fake-token > "$FAKE_GH/tokens/alice"
  run gitch work pr --work files --title 'Work fixture' --body-file pr.txt --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results[1].status')" ok
  assert_out 'https://github.com/alice/work-two/pull/7'
}

test_work_commit_preserves_existing_secret_checks() {
  work_fixture
  gitch work start guarded >/dev/null || fail start
  printf 'API_KEY=ghp_%s\n' '0123456789abcdefghijklmnopqrstuvwxyz' > guarded.conf
  git add guarded.conf
  run gitch work commit -m 'gitch: Add guarded fixture' --json
  assert_fail; assert_json "$OUT"
  assert_out 'GitHub'
  assert_eq "$(git rev-list --count HEAD)" 1
  assert_eq "$(printf '%s' "$OUT" | jq -r '.results[0].status')" failed
}

test_work_json_errors_are_single_structured_documents() {
  work_fixture
  run gitch work start missing --workspace nonexistent --json
  assert_fail; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -s length)" 1
  assert_out 'Cannot load workspace'
  gitch work start corrupt >/dev/null || fail start
  git config --file "$WORK_RECORD/corrupt.config" --unset work.schemaVersion
  run gitch work info corrupt --json
  assert_fail; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -s length)" 1
  printf '../invalid\n' > "$WORK_RECORD/active"
  run gitch work list --json
  assert_fail; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -s length)" 1
}

test_work_commit_aliases_and_option_like_messages_are_preserved() {
  work_fixture
  gitch work start aliases >/dev/null || fail start
  echo first > first.txt
  run gitch work commit --all --message 'gitch: Include all alias' --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git show --format= --name-only HEAD)" first.txt
  echo second > second.txt
  run gitch work commit -am 'gitch: Include short alias' --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git show --format= --name-only HEAD)" second.txt
  echo third > third.txt; git add third.txt
  run gitch work commit --message --work --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git log -1 --format=%s)" --work
}

test_work_info_reports_missing_repository_as_failure() {
  work_fixture
  gitch work start missingrepo --repo "$WORK_ONE" --repo "$WORK_TWO" >/dev/null || fail start
  mv "$WORK_TWO" "$T/moved"
  run gitch work info --json
  assert_fail; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.repositories[1].missing')" true
}

test_work_end_recovers_interrupted_start_and_journaled_return() {
  work_fixture
  gitch work start recover --repo "$WORK_ONE" --repo "$WORK_TWO" >/dev/null || fail start
  git config --file "$WORK_RECORD/recover.config" repo.0.phase pending
  git config --file "$WORK_RECORD/recover.config" repo.1.phase ending
  git config --file "$WORK_RECORD/recover.config" work.state partial
  git -C "$WORK_TWO" switch -q main
  run gitch work end --work recover --dry-run --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git config --file "$WORK_RECORD/recover.config" repo.0.phase)" pending
  assert_eq "$(git config --file "$WORK_RECORD/recover.config" repo.1.phase)" ending
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" feature/recover
  run gitch work end --work recover --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(git -C "$WORK_ONE" branch --show-current)" main
  assert_eq "$(git -C "$WORK_TWO" branch --show-current)" main
  assert_eq "$(git config --file "$WORK_RECORD/recover.config" work.state)" ended
  assert_eq "$(git config --file "$WORK_RECORD/recover.config" repo.0.phase)" ended
}

test_work_end_rejects_unjournaled_wrong_branch() {
  work_fixture
  gitch work start wrongbranch >/dev/null || fail start
  git switch -q main
  run gitch work end --json
  assert_fail; assert_json "$OUT"; assert_out 'not on its work branch'
  assert_eq "$(git config --file "$WORK_RECORD/wrongbranch.config" repo.0.phase)" started
}
