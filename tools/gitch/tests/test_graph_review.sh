# shellcheck shell=bash
# Review must use source snapshots matching its explicitly selected scope.
test_graph_review_body_rename_delete_and_scopes() {
  gr_repo "$T/review 공백"
  printf 'import "./core";\n' | gr_put app/main.ts
  echo 'export const core=1;' | gr_put app/core.ts
  echo 'export const dead=1;' | gr_put '한글 dead.ts'
  echo 'export const moved=1;' | gr_put 'old name.ts'
  gr_commit
  local base beforeIndex
  base=$(git rev-parse HEAD)
  echo 'export const core=2;' > app/core.ts
  git add app/core.ts
  echo 'import "../new name";' > app/core.ts
  git mv 'old name.ts' 'new name.ts'
  git rm -q '한글 dead.ts'
  echo 'export const pending=1;' > untracked.ts
  beforeIndex=$(git hash-object -- "$(git rev-parse --git-path index)")
  gr_json diff --base HEAD
  assert_eq "$(gr_q '.review.changes|length')" 3
  assert_eq "$(gr_q '.review.changes[]|select(.path=="new name.ts")|.oldPath')" 'old name.ts'
  assert_eq "$(gr_q '.review.untracked')" excluded
  assert_eq "$(gr_q '.review.baseSha')" "$base"
  assert_eq "$(gr_q '.review.scope')" worktree
  gr_attr app/core.ts .changed true
  assert_eq "$(gr_q '.review.current.edges|any(.source=="app/core.ts")')" true
  gr_json diff --base HEAD --scope staged
  assert_eq "$(gr_q '.review.current.edges|any(.source=="app/core.ts")')" false
  assert_eq "$(gr_q '.review.scope')" staged
  gr_attr app/core.ts .changed true
  gr_json diff --base HEAD --scope committed
  assert_eq "$(gr_q '.review.changes|length')" 0
  assert_eq "$(gr_q '.review.scope')" committed
  assert_eq "$(git hash-object -- "$(git rev-parse --git-path index)")" "$beforeIndex"
  assert_eq "$(git rev-parse HEAD)" "$base"
  assert_eq "$(cat app/core.ts)" 'import "../new name";'
}

test_graph_review_content_only_and_new_cycle() {
  gr_repo "$T/review-cycles"
  echo 'import "./b";' | gr_put a.ts
  echo 'export const b=1;' | gr_put b.ts
  gr_commit
  echo 'export const b=2;' > b.ts
  gr_json diff --base HEAD
  gr_attr b.ts .status changed
  assert_eq "$(gr_q '.review.changes[0].path')" b.ts
  assert_eq "$(gr_q '.stats.addedEdges')" 0
  echo 'import "./a";' > b.ts
  gr_json diff --base HEAD
  assert_eq "$(gr_q '.review.diff.cycles.new|length')" 1
}

test_graph_review_rename_preserves_cycle_identity() {
  gr_repo "$T/review-rename-cycle"
  echo 'import "./b";' | gr_put a.ts
  echo 'import "./a";' | gr_put b.ts
  gr_commit
  git mv b.ts moved.ts
  echo 'import "./moved";' > a.ts
  gr_json diff --base HEAD
  assert_eq "$(gr_q '.review.diff.cycles.new|length')" 0
  assert_eq "$(gr_q '.review.diff.cycles.changed|length')" 0
}

test_graph_review_tree_matches_selected_source_bytes() {
  gr_repo "$T/review-tree"
  echo 'export const a=1;' | gr_put src/a.ts
  gr_commit
  echo 'export const a=123456;' > src/a.ts
  git add src/a.ts
  echo 'export const a=123456789012345;' > src/a.ts
  local staged worktree
  staged=$(git cat-file -s :src/a.ts)
  worktree=$(wc -c < src/a.ts | tr -d ' ')
  gr_json diff tree --base HEAD --scope staged
  assert_eq "$(gr_q '.nodes[]|select(.id=="src/")|.bytes')" "$staged"
  gr_json diff tree --base HEAD --scope worktree
  assert_eq "$(gr_q '.nodes[]|select(.id=="src/")|.bytes')" "$worktree"
  gr_json diff tree --base HEAD --scope committed
  assert_eq "$(gr_q '.stats.changedNodes')" 0
}

test_graph_review_empty_external_filter_and_merge_metadata() {
  gr_repo "$T/review-meta"
  echo 'import "external";' | gr_put a.ts
  gr_commit
  gr_json diff --no-external --base HEAD...
  assert_eq "$(gr_q '.review.changes|length')" 0
  assert_eq "$(gr_q '.review.mergeBase')" true
  assert_eq "$(gr_q '.review.baseSha|length')" 40
  assert_eq "$(gr_q '.review.headSha|length')" 40
  assert_eq "$(gr_q '.review.current.nodes|any(.kind=="package")')" false
  gr_json diff --base HEAD
  assert_eq "$(gr_q '.review.mergeBase')" false
  run gitch graph diff --scope invalid --json
  assert_rc 1
}

test_graph_review_untracked_policy_is_explicit() {
  gr_repo "$T/review-untracked"
  echo 'export const a=1;' | gr_put a.ts
  gr_commit
  echo 'import "./a";' | gr_put '새 파일.ts'
  run gitch graph --format html --no-open --out "$T/plain.html"
  assert_ok
  awk '/<script id="graph-data"/ {on=1;next} /<\/script>/ {on=0} on' "$T/plain.html" > "$T/plain.json"
  assert_eq "$(jq -r '.review.untracked' "$T/plain.json")" excluded
  assert_eq "$(jq -r '.review.changes|length' "$T/plain.json")" 0
  run gitch graph affected --base HEAD --format html --no-open --out "$T/affected.html"
  assert_ok
  awk '/<script id="graph-data"/ {on=1;next} /<\/script>/ {on=0} on' "$T/affected.html" > "$T/affected.json"
  assert_eq "$(jq -r '.review.untracked' "$T/affected.json")" included
  assert_eq "$(jq -r '.review.changes[0].path' "$T/affected.json")" '새 파일.ts'
  assert_eq "$(jq -r '.review.current.nodes|any(.id=="새 파일.ts")' "$T/affected.json")" true
}

test_graph_review_utf8_basename_keeps_character_boundaries() {
  gr_repo "$T/review-한글"
  echo 'import "./한글";' | gr_put 진입.ts
  echo 'export const value=1;' | gr_put 한글.ts
  gr_commit
  gr_json files
  gr_edge 진입.ts 한글.ts
  echo 'export const value=2;' > 한글.ts
  gr_json diff --base HEAD
  gr_attr 한글.ts .changed true
  assert_eq "$(gr_q '.review.changes[0].path')" 한글.ts
  gr_commit body
  git mv 한글.ts 새이름.ts
  gr_json diff --base HEAD
  assert_eq "$(gr_q '.review.changes[]|select(.path=="새이름.ts")|.oldPath')" 한글.ts
}

# 실제 UTF-8 로캘에서도 ASCII 접미사가 같은 한글 경로를 별개로 취급한다.
test_graph_review_utf8_locale_preserves_character_boundaries() {
  local task_locale
  task_locale=$(locale -a 2>/dev/null | LC_ALL=C awk '
    tolower($0) ~ /^en_us[.]utf-?8$/ { print; found = 1; exit }
    tolower($0) ~ /^c[.]utf-?8$/ { fallback = $0 }
    END { if (!found && fallback != "") print fallback }')
  [ -n "$task_locale" ] || return 0
  LC_ALL="$task_locale" test_graph_review_utf8_basename_keeps_character_boundaries
}
