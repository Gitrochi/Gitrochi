# shellcheck shell=bash
# The fixture is shared by the browser's layout and architecture assertions.
graph_structure_chrome() {
  local candidate
  for candidate in "${GITCH_TEST_CHROME:-}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$(command -v google-chrome 2>/dev/null)" "$(command -v chromium 2>/dev/null)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

test_graph_structure_layouts_and_architecture_in_browser() {
  local chrome code file
  chrome=$(graph_structure_chrome) || return 0
  node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null || return 0
  mkdir -p "$T/structure/alpha/nested" "$T/structure/beta/nested" "$T/structure/swift" "$T/structure/packages/a" "$T/structure/packages/b" "$T/structure/packages/c" "$T/out"
  cd "$T/structure" || fail "Cannot enter structure fixture"
  git init -q .
  git config user.name fixture
  git config user.email fixture@example.com
  printf '{"name":"structure-fixture","workspaces":["packages/*"]}\n' > package.json
  printf '{"name":"@fixture/a","dependencies":{"@fixture/b":"1"}}\n' > packages/a/package.json
  printf '{"name":"@fixture/b","dependencies":{"@fixture/c":"1"}}\n' > packages/b/package.json
  printf '{"name":"@fixture/c","dependencies":{"@fixture/a":"1"}}\n' > packages/c/package.json
  printf 'import "./b";\nimport "../beta/c";\nexport const a=1;\n' > alpha/a.ts
  printf 'import "./a";\nexport const b=1;\n' > alpha/b.ts
  printf 'import "../a";\nexport const e=1;\n' > alpha/nested/e.ts
  printf 'import "./d";\nimport "../alpha/b";\nexport const c=1;\n' > beta/c.ts
  printf 'export const d=1;\n' > beta/d.ts
  printf 'import "../c";\nexport const f=1;\n' > beta/nested/f.ts
  printf 'struct Caller { let value: Value }\n' > swift/Caller.swift
  printf 'struct Value {}\n' > swift/Value.swift
  git add -A && git commit -q -m 'Structure baseline'
  for file in alpha/a.ts alpha/b.ts alpha/nested/e.ts beta/c.ts beta/d.ts beta/nested/f.ts; do printf '// Co-change fixture\n' >> "$file"; done
  git add -A && git commit -q -m 'Change connected fixture files'
  printf '// Current review\n' >> alpha/a.ts
  for code in en ko ja; do
    GITCH_GRAPH_LANG="$code" GITCH_SWIFT_INDEX='' run gitch graph files --format html --no-open --out "$T/out/$code.html"
    assert_ok "Cannot generate $code structure graph"
  done
  run node "$ROOT/tests/graph_structure_browser.mjs" "$chrome" "$T/out" "$T"
  assert_ok "Graph structure browser checks failed"
  assert_out '"ok":true'
}
