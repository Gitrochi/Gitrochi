# shellcheck shell=bash
# Keep architecture calculations covered even when no browser is installed.
test_graph_architecture_metrics() {
  command -v node >/dev/null 2>&1 || return 0
  GITCH_ARCHITECTURE_SOURCE="$GITSW_SRC" run node --test "$ROOT/tests/graph_architecture_metrics.test.mjs"
  assert_ok "Architecture coupling and cohesion metrics failed"
}
