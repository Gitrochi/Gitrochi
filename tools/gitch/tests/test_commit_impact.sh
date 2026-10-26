# shellcheck shell=bash
# 커밋 카드는 작업 트리와 섞이지 않는 스테이지 스냅샷을 사용한다.
test_commit_impact_staged_dependencies_and_test_candidates() {
  gr_repo "$T/impact"
  echo 'export const core=1;' | gr_put core.ts
  echo 'import "./core";' | gr_put app.ts
  echo 'import "./app";' | gr_put entry.ts
  echo 'import "../app";' | gr_put tests/app.test.ts
  echo '// name-only candidate' | gr_put tests/core.spec.ts
  gr_commit
  echo 'export const core=2;' > core.ts
  git add core.ts
  echo 'import "./unstaged-only";' > core.ts
  echo 'export const x=1;' > unstaged-only.ts
  local indexBefore stamp
  indexBefore=$(git hash-object -- "$(git rev-parse --git-path index)")
  run gitch graph review --json
  assert_ok; assert_json "$OUT"
  stamp=$(gr_q '.stamp')
  assert_eq "$(gr_q '.changed|map(.path)|join(",")')" core.ts
  assert_eq "$(gr_q '.direct|map(.path)|join(",")')" app.ts
  assert_eq "$(gr_q '.indirect|map(.path)|sort|join(",")')" 'entry.ts,tests/app.test.ts'
  assert_eq "$(gr_q '.tests[]|select(.path=="tests/app.test.ts")|.kind')" dependency
  assert_eq "$(gr_q '.tests[]|select(.path=="tests/core.spec.ts")|.kind')" name
  assert_eq "$(gr_q '.tests[]|select(.path=="tests/core.spec.ts")|.heuristic')" true
  assert_eq "$(gr_q '.coverage.analyzed')" 1
  assert_eq "$(gr_q '.stale')" false
  assert_eq "$(gr_q '.indirect[]|select(.path=="entry.ts")|.via|join("->")')" 'entry.ts->app.ts->core.ts'
  assert_eq "$(git hash-object -- "$(git rev-parse --git-path index)")" "$indexBefore"
  run gitch graph review --stamp --json
  assert_ok; assert_eq "$(gr_q '.stamp')" "$stamp"
  echo '// another unstaged edit' >> core.ts
  run gitch graph review --stamp --json
  assert_ok; assert_eq "$(gr_q '.stamp')" "$stamp"
  git add core.ts
  run gitch graph review --stamp --json
  assert_ok
  [ "$(gr_q '.stamp')" != "$stamp" ] || fail 'restaging new content must change the stamp'
}

test_commit_impact_deleted_renamed_and_unsupported() {
  gr_repo "$T/impact-renames"
  echo 'export const old=1;' | gr_put old.ts
  echo 'import "./old";' | gr_put caller.ts
  echo 'export const gone=1;' | gr_put gone.ts
  echo 'import "./gone";' | gr_put consumer.ts
  echo 'one' | gr_put notes.txt
  gr_commit
  git mv old.ts moved.ts
  git rm -q gone.ts
  echo two > notes.txt
  git add notes.txt
  run gitch graph review --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(gr_q '.changed[]|select(.path=="moved.ts")|.oldPath')" old.ts
  assert_eq "$(gr_q '.direct|map(.path)|sort|join(",")')" 'caller.ts,consumer.ts'
  assert_eq "$(gr_q '.changed[]|select(.path=="notes.txt")|.analyzed')" false
  assert_eq "$(gr_q '.coverage.unsupported')" 1
  assert_eq "$(gr_q '.changed|length')" 3
}

test_commit_impact_initial_commit_and_empty_stage() {
  gr_repo "$T/impact-initial"
  run gitch graph review --json
  assert_ok; assert_json "$OUT"
  assert_eq "$(gr_q '.changed|length')" 0
  assert_eq "$(gr_q '.headSha')" ''
  echo 'export const first=1;' | gr_put first.ts
  git add first.ts
  run gitch graph review --json
  assert_ok; assert_eq "$(gr_q '.changed[0].path')" first.ts
  assert_eq "$(gr_q '.coverage.analyzed')" 1
  run gitch graph review --format html --out "$T/initial.html" --no-open
  assert_ok
  grep -q '"scope":"staged"' "$T/initial.html" || fail 'initial commit HTML must use the staged snapshot'
}

test_commit_impact_stamp_ignores_index_stat_and_tracks_head() {
  gr_repo "$T/impact-stamp"
  echo 'export const x=1;' | gr_put x.ts
  gr_commit
  run gitch graph review --stamp --json
  assert_ok
  local stamp; stamp=$(gr_q '.stamp')
  touch x.ts
  git update-index --refresh
  run gitch graph review --stamp --json
  assert_ok; assert_eq "$(gr_q '.stamp')" "$stamp"
  git commit --allow-empty -q -m 'Advance HEAD'
  run gitch graph review --stamp --json
  assert_ok
  [ "$(gr_q '.stamp')" != "$stamp" ] || fail 'a different HEAD must change the stamp'
}
