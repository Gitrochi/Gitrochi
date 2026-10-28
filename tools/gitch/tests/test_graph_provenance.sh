# shellcheck shell=bash
# Snapshot identity follows source bytes, never wall-clock or cache-hit telemetry.
test_graph_provenance_stable_snapshot_and_source_freshness() {
  gr_repo "$T/provenance"
  printf 'import "./b";\n' | gr_put a.ts
  printf 'export const b=1;\n' | gr_put b.ts
  gr_commit
  gr_json files
  local first head
  first=$(gr_q '.snapshotID'); head=$(git rev-parse HEAD)
  assert_eq "$(gr_q '.provenance.headSha')" "$head"
  assert_eq "$(gr_q '.snapshotID|test("^[a-f0-9]{40,64}$")')" true
  assert_eq "$(gr_q '.coverage.files')" 2
  assert_eq "$(gr_q '.coverage.analyzed')" 2
  assert_eq "$(gr_q '.coverage.declaredEdges')" 1
  assert_eq "$(gr_q '.provenance.verification.status')" not-run
  gr_json files
  assert_eq "$(gr_q '.snapshotID')" "$first"
  assert_eq "$(gr_q '.stats.cache.hit')" true
  printf 'export const b=2;\n' > b.ts
  gr_json files
  [ "$(gr_q '.snapshotID')" != "$first" ] || fail 'Snapshot ignored a same-size source edit'
  assert_eq "$(gr_q '.provenance.headSha')" "$head"
}

test_graph_provenance_json_and_html_share_snapshot() {
  gr_repo "$T/provenance-html"
  printf 'import "./b";\n' | gr_put a.ts
  printf 'export const b=1;\n' | gr_put b.ts
  gr_commit
  gr_json files
  local snapshot
  snapshot=$(gr_q '.snapshotID')
  run gitch graph files --format html --out "$T/provenance.html" --no-open
  assert_ok
  grep -F '"snapshotID":"'"$snapshot"'"' "$T/provenance.html" >/dev/null || fail 'HTML snapshot differs from JSON'
  grep -F 'window.gitchGraph=Object.freeze' "$T/provenance.html" >/dev/null || fail 'Graph action bridge missing'
  grep -F 'aria-describedby="graphTextSummary"' "$T/provenance.html" >/dev/null || fail 'Text alternative missing'
}
