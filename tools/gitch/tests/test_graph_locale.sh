# shellcheck shell=bash
# Real browser checks for app overrides, browser preferences, and offline report localization.

graph_locale_chrome() {
  local candidate
  for candidate in "${GITCH_TEST_CHROME:-}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$(command -v google-chrome 2>/dev/null)" "$(command -v chromium 2>/dev/null)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

test_graph_html_locales_in_browser() {
  local chrome code filename
  chrome=$(graph_locale_chrome) || return 0
  node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null || return 0
  mkdir -p "$T/locale-fixture/src/nested" "$T/locale-fixture/tests" "$T/out"
  cd "$T/locale-fixture" || fail "Cannot enter locale fixture"
  git init -q .
  git config user.name fixture
  git config user.email fixture@example.com
  printf '{"name":"locale-fixture"}\n' > package.json
  filename='very long file name with 변경 리뷰 Graph settings 相対パス intact.ts'
  printf 'export const value = 1;\n' > "src/nested/$filename"
  printf 'import { value } from "./nested/%s";\nimport "./generated-missing";\nexport const result = value;\n' "$filename" > src/consumer.ts
  printf 'import { result } from "../src/consumer";\nconsole.log(result);\n' > tests/review.test.ts
  git add -A
  git commit -q -m 'Locale fixture'
  printf 'export const value = 2;\n' > "src/nested/$filename"
  for code in en ko ja KO_kr ja-JP en-GB; do
    GITCH_GRAPH_LANG="$code" run gitch graph files --format html --no-open --out "$T/out/$code.html"
    assert_ok "Cannot generate $code graph"
  done
  GITCH_GRAPH_LANG='' LANG=C LC_ALL=C run gitch graph files --format html --no-open --out "$T/out/auto.html"
  assert_ok "Cannot generate automatic-language graph"
  run node "$ROOT/tests/graph_locale_browser.mjs" "$chrome" "$T/out" "$T"
  assert_ok "Offline graph locale browser checks failed"
  assert_out '"ok":true'
}
