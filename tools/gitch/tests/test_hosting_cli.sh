# shellcheck shell=bash
# Discovery uses fake hosting CLIs and isolated repository accounts.
hosting_cli_repo() {
  mk_config
  mk_repo "$HOME/Develop/alice/discovery" 'git@github-alice:alice/discovery.git'
  cd "$HOME/Develop/alice/discovery" || fail cd
  gitch use alice >/dev/null || fail account
  printf 'fixture-token' > "$FAKE_GH/tokens/alice"
  mv "$T/fakebin/gh" "$T/fakebin/gh-base"
  cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  'issue list'|'issue view'|'pr list')
    printf '%s\n' "$GH_TOKEN" > "$FAKE_GH/request-account"
    printf '%s\n' "$@" > "$FAKE_GH/request-args"
    [ ! -f "$FAKE_GH/fail-read" ] || { printf 'private failure details' >&2; exit 9; }
    case "$1 $2" in
      'issue view') printf '{"number":42,"title":"Read fixture","state":"OPEN","url":"https://github.com/alice/discovery/issues/42","body":"Fixture body"}\n' ;;
      *) printf '[{"number":42,"title":"Read fixture","state":"OPEN","url":"https://github.com/alice/discovery/issues/42"}]\n' ;;
    esac
    ;;
  *) exec "$(dirname "$0")/gh-base" "$@" ;;
esac
EOF
  chmod +x "$T/fakebin/gh"
}

hosting_cli_gitlab() {
  hosting_cli_repo
  git remote set-url origin 'git@gitlab-carol:team/discovery.git'
  gitch use carol >/dev/null || fail account
  cat > "$T/fakebin/glab" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_GH/glab-args"
case "$*" in
  *' GET user '*) cat "$FAKE_GH/glab-user" ;;
  *'projects/'*'/issues/7') printf '{"iid":7,"title":"GitLab fixture","state":"opened","description":"Fixture details"}\n' ;;
  *'projects/'*) printf '[{"iid":7,"title":"GitLab fixture","state":"opened"}]\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/fakebin/glab"
  printf 'carol\n' > "$FAKE_GH/glab-user"
}

test_hosting_issue_and_pr_lists_use_repository_account() {
  hosting_cli_repo
  run gitch issue list --state closed --limit 5 --label 'needs review' --assignee alice --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .repository)" 'alice/discovery'
  assert_eq "$(printf '%s' "$OUT" | jq -r '.items[0].number')" 42
  assert_eq "$(cat "$FAKE_GH/request-account")" fixture-token
  assert_eq "$(sed -n '6p' "$FAKE_GH/request-args")" closed
  run gitch pr list --state merged --limit 2 --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .tool)" 'gitch pr list'
  assert_eq "$(sed -n '1p' "$FAKE_GH/request-args")" pr
  run gitch issue
  assert_ok
}

test_hosting_issue_show_and_validation() {
  hosting_cli_repo
  run gitch issue show 42 --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.items[0].body')" 'Fixture body'
  run gitch issue show --json; assert_fail; assert_out INVALID_ARGUMENT
  run gitch issue show 0 --json; assert_fail
  run gitch issue show 00 --json; assert_fail
  run gitch issue list --limit 0 --json; assert_fail
  run gitch issue list --limit 101 --json; assert_fail
  run gitch issue list --limit 9999999999999999999999 --json; assert_fail
  run gitch issue list --limit --json; assert_fail
  run gitch issue list --state merged --json; assert_fail
  run gitch issue list --unknown --json; assert_fail
  run gitch pr list --state nonsense --json; assert_fail
}

test_hosting_read_failures_are_structured_without_credentials() {
  hosting_cli_repo
  touch "$FAKE_GH/fail-read"
  run gitch issue list --json
  assert_fail; assert_json "$OUT"; assert_out HOSTING_REQUEST_FAILED
  assert_no_out fixture-token; assert_no_out 'private failure details'
  rm "$FAKE_GH/tokens/alice"
  run gitch pr list --json
  assert_fail; assert_json "$OUT"; assert_out HOSTING_AUTH_REQUIRED
}

test_hosting_gitlab_checks_existing_identity_before_reading() {
  hosting_cli_gitlab
  run gitch issue list --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .provider)" gitlab
  assert_eq "$(printf '%s' "$OUT" | jq -r '.items[0].iid')" 7
  grep -q 'projects/team%2Fdiscovery/issues?state=opened&per_page=30' "$FAKE_GH/glab-args" || fail endpoint
  run gitch issue show 7 --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.items[0].description')" 'Fixture details'
  run gitch pr list --state merged --limit 3 --json
  assert_ok; assert_json "$OUT"
  grep -q 'projects/team%2Fdiscovery/merge_requests?state=merged&per_page=3' "$FAKE_GH/glab-args" || fail endpoint
  printf 'someone-else\n' > "$FAKE_GH/glab-user"
  : > "$FAKE_GH/glab-args"
  run gitch pr list --json
  assert_fail; assert_json "$OUT"; assert_out HOSTING_ACCOUNT_MISMATCH
  if grep -q 'projects/' "$FAKE_GH/glab-args"; then fail 'Read data with a different account'; fi
}

test_git_read_only_access_rejects_mutations_and_execution_flags() {
  hosting_cli_repo
  printf 'seed\n' > seed.txt
  run gitch c -a -m 'gitch: Seed fixture'; assert_ok
  run gitch git status --short; assert_ok
  run gitch git log -1 --oneline; assert_ok; assert_out 'gitch: Seed fixture'
  run gitch git branch --list; assert_ok; assert_out main
  run gitch git remote get-url origin; assert_ok; assert_out 'github-alice'
  run gitch git rev-parse --show-toplevel; assert_ok
  run gitch git commit -m unsafe; assert_fail; assert_out read-only
  run gitch git push; assert_fail
  run gitch git -c core.hooksPath=other commit; assert_fail
  run gitch git branch unsafe; assert_fail
  run gitch git branch --delete main; assert_fail
  run gitch git tag unsafe; assert_fail
  run gitch git remote set-url origin unsafe; assert_fail
  run gitch git log --output "$T/written"; assert_fail
  [ ! -e "$T/written" ] || fail 'Created output file'
  run gitch git diff --ext-diff; assert_fail
  run gitch git show --textconv; assert_fail
  run gitch git rev-parse --local-env-vars; assert_fail
}

test_git_read_only_access_preserves_arguments_and_exit_codes() {
  hosting_cli_repo
  printf 'seed\n' > 'file with spaces.txt'
  run gitch c -a -m 'gitch: Seed fixture'; assert_ok
  printf 'changed\n' >> 'file with spaces.txt'
  run gitch git diff --exit-code -- 'file with spaces.txt'
  assert_rc 1; assert_out changed
  run gitch git diff --name-only -- 'file with spaces.txt'
  assert_ok; assert_eq "$OUT" 'file with spaces.txt'
  run gitch git rev-parse --verify does-not-exist
  assert_fail
}
