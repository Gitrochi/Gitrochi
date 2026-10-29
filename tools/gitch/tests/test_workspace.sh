# shellcheck shell=bash

workspace_fixture() {
  mk_config
  mk_repo "$T/Frontend with spaces"
  mk_repo "$T/backend"
  git -C "$T/Frontend with spaces" config user.name alice
  git -C "$T/Frontend with spaces" config user.email alice@example.com
  seed_commit "$T/Frontend with spaces"
  git -C "$T/backend" config user.name alice
  git -C "$T/backend" config user.email alice@example.com
  seed_commit "$T/backend"
}

test_workspace_membership_and_canonical_paths() {
  workspace_fixture
  run gitch workspace create product "$T/Frontend with spaces" "$T/backend" --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq '.repositories | length')" 2
  run gitch ws add product "$T/backend/." --json
  assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq '.repositories | length')" 2
  run gitch workspace list --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.workspaces[0].name')" product
  run gitch workspace remove product "$T/backend" --json
  assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq '.repositories | length')" 1
  run gitch workspace delete product --json
  assert_ok
  [ -d "$T/Frontend with spaces/.git" ] && [ -d "$T/backend/.git" ] || fail 'Deleting group removed repository files'
}

test_workspace_status_preserves_failed_repository_results() {
  workspace_fixture
  run gitch workspace create product "$T/Frontend with spaces" "$T/backend"
  assert_ok
  echo changed >> "$T/backend/seed.txt"
  run gitch workspace status product --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq '.repositories[1].status.unstaged | length')" 1
  rm -rf "$T/backend"
  run gitch workspace status product --json
  assert_rc 1; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq '.ok')" false
  assert_eq "$(printf '%s' "$OUT" | jq '.repositories[0].status.branch')" '"main"'
  assert_eq "$(printf '%s' "$OUT" | jq '.repositories[1].status')" null
  run gitch workspace remove product "$T/backend" --json
  assert_ok
}

test_workspace_validation_is_atomic_and_dry_run_preserves_records() {
  workspace_fixture
  run gitch workspace create ../escape "$T/backend" --json
  assert_rc 1; assert_json "$OUT"
  run gitch workspace create product "$T/backend" "$T/missing" --json
  assert_rc 1
  [ ! -f "$HOME/.local/state/gitsw/workspaces/product.config" ] || fail 'Invalid group was partly saved'
  run gitch workspace create product "$T/backend" --dry-run --json
  assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq .dryRun)" true
  [ ! -f "$HOME/.local/state/gitsw/workspaces/product.config" ] || fail 'Dry run saved a record'
  run gitch workspace create product "$T/backend" --json
  assert_ok
  cp "$HOME/.local/state/gitsw/workspaces/product.config" "$T/original"
  run gitch workspace add product "$T/Frontend with spaces" --dry-run --json
  assert_ok
  cmp "$T/original" "$HOME/.local/state/gitsw/workspaces/product.config" || fail 'Dry run changed existing record'
  run gitch workspace remove product "$T/missing" --json
  assert_rc 1
  cmp "$T/original" "$HOME/.local/state/gitsw/workspaces/product.config" || fail 'Failed removal changed existing record'
}

test_workspace_rejects_symlink_records_and_control_paths() {
  workspace_fixture
  mkdir -p "$HOME/.local/state/gitsw/workspaces"
  printf '[workspace]\nname = product\n' > "$T/outside"
  ln -s "$T/outside" "$HOME/.local/state/gitsw/workspaces/product.config"
  run gitch workspace create product "$T/backend" --json
  assert_rc 1
  # Git Bash can copy a file for ln -s when native symlinks are unavailable.
  if [ -L "$HOME/.local/state/gitsw/workspaces/product.config" ]; then
    run gitch workspace show product --json
    assert_rc 1
  fi
  if mac_only; then
    mkdir -p "$T/line
break"
    git init -q "$T/line
break"
  fi
  run gitch workspace create controls "$T/line
break" --json
  assert_rc 1
}

test_workspace_corrupt_list_emits_one_json_error_without_partial_output() {
  workspace_fixture
  run gitch workspace create aaa "$T/backend" --json; assert_ok
  printf '[workspace]\nname = different\n' > "$HOME/.local/state/gitsw/workspaces/zzz.config"
  run gitch workspace list --json
  assert_rc 1; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.error.code')" GITCH_ERROR
}
