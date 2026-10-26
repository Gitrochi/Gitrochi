# shellcheck shell=bash
# Exercise the shipped hierarchy algorithms even when no browser is installed.
test_graph_layout_targets() {
  command -v node >/dev/null 2>&1 || return 0
  GITCH_LAYOUT_SOURCE="$GITSW_SRC" run node --test "$ROOT/tests/graph_layout_targets.test.mjs"
  assert_ok "Graph hierarchy layout targets failed"
}
