# shellcheck shell=bash
export GITCH_GRAPH_LANG=ko # Keep replay text assertions independent of the host locale.
# The shared graph fixtures are defined in test_graph.sh.
test_graph_replay_in_browser() {
  local chrome
  chrome=$(gr_chrome) || return 0
  node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null || return 0
  gr_repo "$T/replay 공백"
  printf '{"name":"replay","dependencies":{"old-lib":"1","shared-lib":"1"}}\n' | gr_put package.json
  printf 'import "./old";\nimport "./gone";\nimport "./same";\n' | gr_put src/entry.ts
  echo 'export const old=1;' | gr_put src/old.ts
  echo 'export const gone=1;' | gr_put src/gone.ts
  echo 'export const same=1;' | gr_put src/same.ts
  echo 'value=1' | gr_put python/tool.py
  echo 'struct Caller { let value: Value }' | gr_put swift/Caller.swift
  echo 'struct Value {}' | gr_put swift/Value.swift
  gr_commit baseline
  git mv src/old.ts src/moved.ts
  git rm -q src/gone.ts
  printf 'import "./moved";\nimport "./new";\nimport "./same";\n' > src/entry.ts
  echo 'export const same=2;' > src/same.ts
  echo 'export const fresh=1;' | gr_put src/new.ts
  printf '{"name":"replay","dependencies":{"new-lib":"1","shared-lib":"1"}}\n' > package.json
  git add src/new.ts
  run gitch graph diff HEAD --format html --no-open --out "$T/replay.html"
  assert_ok
  run node "$ROOT/tests/graph_replay_browser.mjs" "$chrome" "$T/replay.html" "$T"
  assert_ok "구조 변화 재생 브라우저 확인 실패"
  assert_out '"ok":true'
}
