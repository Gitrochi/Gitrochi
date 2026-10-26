# shellcheck shell=bash
# Runtime uses Bash/Git/AWK only; jq below validates the public result in tests.
ma_test_repo() {
  mkdir -p "$1" || fail 'cannot create fixture repository'
  cd "$1" || fail 'cannot open fixture repository'
  # Starting inside the folder avoids MSYS rewriting special characters in an absolute argument.
  git init -q . || fail 'cannot initialize fixture repository'
}
ma_test_put() { mkdir -p "$(dirname "$1")" && cat > "$1"; }
ma_test_track() { git add -A -- . || fail 'cannot track fixture files'; }
ma_test_q() { printf '%s' "$OUT" | jq -r "$1"; }
ma_test_json() { run gitch module audit "$@" --json; assert_json "$OUT"; }

test_module_audit_direct_declarations_builtins_and_tooling_candidates() {
  ma_test_repo "$T/audit-basic"
  cat <<'EOF' | ma_test_put package.json
{"name":"app","dependencies":{"one":"^1"},"devDependencies":{"two":"^2","eslint":"^9"},"peerDependencies":{"@scope/three":"*"},"optionalDependencies":{"four":"*"},"scripts":{"lint":"eslint ."}}
EOF
  cat <<'EOF' | ma_test_put index.ts
import "one/subpath";
import {x} from "two";
export {x} from "@scope/three/api";
const four = require("four");
import "node:test";
import "fs/promises";
import "assert/strict";
import "path";
import "node:sqlite";
EOF
  ma_test_track
  ma_test_json --strict
  assert_ok
  assert_eq "$(ma_test_q '.stats.errors')" 0
  assert_eq "$(ma_test_q '.incomplete')" false
  assert_eq "$(ma_test_q '[.findings[]|select(.code=="UNOBSERVED_DEPENDENCY")|.dependency]|join(",")')" eslint
  assert_eq "$(ma_test_q '[.findings[].severity]|unique|join(",")')" info
  assert_eq "$(ma_test_q '.scope')" tracked-working-tree
}

test_module_audit_scans_real_import_tokens_and_evidence() {
  ma_test_repo "$T/audit-tokens"
  echo '{"name":"tokens"}' > package.json
  cat <<'EOF' | ma_test_put 'src/a space.ts'
// import "comment-fake";
const example = "require(\"string-fake\")";
const pattern = /require("regex-fake")/;
const template = `import "template-fake"`;
/* require("block-fake"); */
import {
  x
} from "@scope/real/subpath";
export * from 'real-export';
const dynamic = import("real-dynamic");
const common = require("real-common");
object.require("method-fake");
EOF
  ma_test_track
  ma_test_json
  assert_ok
  assert_eq "$(ma_test_q '[.findings[]|select(.code=="MISSING_DEPENDENCY")|.dependency]|sort|join(",")')" '@scope/real,real-common,real-dynamic,real-export'
  assert_eq "$(ma_test_q '.findings[]|select(.dependency=="@scope/real")|.evidence[0].line')" 6
  assert_eq "$(ma_test_q '.findings[]|select(.dependency=="@scope/real")|.files[0]')" 'src/a space.ts'
  ma_test_json --strict
  assert_rc 1
  assert_eq "$(ma_test_q '.stats.errors')" 4
  assert_eq "$(ma_test_q '.incomplete')" false
}

test_module_audit_workspace_member_needs_own_declarations_and_relative_boundary() {
  ma_test_repo "$T/audit-workspace"
  echo '{"name":"root","workspaces":["packages/*"],"dependencies":{"hoisted":"^1"}}' > package.json
  echo '{"name":"@app/a"}' | ma_test_put packages/a/package.json
  echo '{"name":"@app/b"}' | ma_test_put packages/b/package.json
  echo 'export const x = 1;' | ma_test_put packages/b/index.ts
  cat <<'EOF' | ma_test_put packages/a/index.ts
import "hoisted";
import "@app/b";
import "../b/index";
EOF
  ma_test_track
  ma_test_json packages/a --strict
  assert_rc 1
  assert_eq "$(ma_test_q '[.modules[].name]|join(",")')" '@app/a'
  assert_eq "$(ma_test_q '[.findings[]|select(.code=="MISSING_DEPENDENCY")|.dependency]|sort|join(",")')" '@app/b,hoisted'
  assert_eq "$(ma_test_q '.findings[]|select(.dependency=="@app/b")|.evidence|length')" 2
  echo '{"name":"@app/a","dependencies":{"@app/b":"workspace:*","hoisted":"^1"}}' > packages/a/package.json
  ma_test_json packages/a --strict
  assert_ok
  assert_eq "$(ma_test_q '.stats.errors')" 0
}

test_module_audit_version_specs_are_advisory_with_workspace_boundaries() {
  ma_test_repo "$T/audit-specs"
  echo '{"name":"root","workspaces":["packages/*"],"dependencies":{"shared":"^1"}}' > package.json
  echo '{"name":"a","dependencies":{"shared":"^2"}}' | ma_test_put packages/a/package.json
  echo '{"name":"unrelated","dependencies":{"shared":"^9","other":"^1"}}' | ma_test_put examples/unrelated/package.json
  echo '{"name":"nested","dependencies":{"other":"^8"}}' | ma_test_put packages/a/example/package.json
  ma_test_track
  ma_test_json --strict
  assert_ok
  assert_eq "$(ma_test_q '[.findings[]|select(.code=="VERSION_SPEC_MISMATCH")]|length')" 1
  assert_eq "$(ma_test_q '.findings[]|select(.code=="VERSION_SPEC_MISMATCH")|.dependency')" shared
  assert_eq "$(ma_test_q '.findings[]|select(.code=="VERSION_SPEC_MISMATCH")|.files|sort|join(",")')" package.json,packages/a/package.json
  assert_eq "$(ma_test_q '.stats.errors')" 0
}

test_module_audit_alias_configs_report_incomplete_without_missing_guesses() {
  ma_test_repo "$T/audit-alias"
  echo '{"name":"aliases","dependencies":{"declared":"*"}}' > package.json
  cat <<'EOF' | ma_test_put tsconfig.json
{
  // JSONC is valid for tsconfig, unlike package.json.
  "compilerOptions": {"baseUrl":".","paths":{"@local/*":["src/*"]},},
}
EOF
  cat <<'EOF' | ma_test_put src/main.ts
import "@local/model";
import "potential-base-url";
import "declared";
import "#private";
EOF
  ma_test_track
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '.incomplete')" true
  assert_eq "$(ma_test_q '.stats.errors')" 0
  assert_eq "$(ma_test_q '[.diagnostics[].code]|unique|sort|join(",")')" ALIAS_IMPORT_NOT_AUDITED,UNRESOLVED_CONFIG_IMPORT
  assert_eq "$(ma_test_q '[.findings[]|select(.dependency=="declared")]|length')" 0
}

test_module_audit_rejects_malformed_json_and_duplicate_keys_and_names() {
  ma_test_repo "$T/audit-invalid"
  echo '{"name":"root","workspaces":["packages/*"]}' > package.json
  echo '{"name":"same"}' | ma_test_put packages/a/package.json
  echo '{"name":"same"}' | ma_test_put packages/b/package.json
  echo '{"name":"bad",}' | ma_test_put packages/bad/package.json
  echo '{"name":"dup","dependencies":{"pkg":"1","pkg":"2"}}' | ma_test_put packages/keys/package.json
  echo 'import "must-not-be-owned-by-root";' | ma_test_put packages/bad/source.ts
  ma_test_track
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '[.diagnostics[]|select(.code=="INVALID_MANIFEST")]|length')" 2
  assert_eq "$(ma_test_q '[.diagnostics[]|select(.code=="DUPLICATE_PACKAGE_NAME")]|length')" 1
  assert_eq "$(ma_test_q '.stats.errors')" 0
}

test_module_audit_working_bytes_tracked_scope_and_partial_filter() {
  ma_test_repo "$T/audit-working"
  echo '{"name":"working","dependencies":{"tool":"^1"}}' > package.json
  echo 'import "staged-version";' | ma_test_put src/index.ts
  ma_test_track
  echo 'import "working-version";' > src/index.ts
  echo 'import "untracked-version";' > src/untracked.ts
  ma_test_json src/index.ts
  assert_ok
  assert_eq "$(ma_test_q '[.findings[].dependency]|join(",")')" working-version
  assert_eq "$(ma_test_q '.path')" src/index.ts
  ma_test_json "$PWD/src"
  assert_ok
  assert_eq "$(ma_test_q '[.findings[].dependency]|join(",")')" working-version
  cd src || fail 'fixture cd'
  ma_test_json
  assert_ok
  assert_eq "$(ma_test_q '.path')" src
  assert_eq "$(ma_test_q '[.findings[].dependency]|join(",")')" working-version
}

test_module_audit_normalizes_repository_root_before_scope_comparison() {
  ma_test_repo "$T/audit-root-spelling"
  echo '{"name":"normalized"}' > package.json
  echo 'import "missing";' | ma_test_put src/index.ts
  ma_test_track
  local real_git
  real_git=$(command -v git)
  cat > "$T/fakebin/git" <<'EOF'
#!/bin/bash
if [ "$1 $2" = 'rev-parse --show-toplevel' ]; then
  printf '%s/.\n' "$GITCH_TEST_REPO_TOP"
else
  exec "$GITCH_TEST_REAL_GIT" "$@"
fi
EOF
  chmod +x "$T/fakebin/git"
  run env GITCH_TEST_REPO_TOP="$PWD" GITCH_TEST_REAL_GIT="$real_git" gitch module audit src --json
  assert_ok
  assert_json "$OUT"
  assert_eq "$(ma_test_q '.path')" src
  assert_eq "$(ma_test_q '.stats.errors')" 1
}

test_module_audit_strings_and_weird_paths_are_never_executed() {
  local jq_bin
  jq_bin=$(command -v jq)
  ma_test_repo "$T/audit space ' \$(literal)"
  cat <<'EOF' | ma_test_put package.json
{"name":"data-only","dependencies":{"tool":"$(touch SHOULD_NOT_EXIST)"},"scripts":{"prepare":"touch SCRIPT_MUST_NOT_RUN"}}
EOF
  echo 'import "real";' | ma_test_put "src/\$() quote '.ts"
  ma_test_track
  mkdir -p "$T/no-runtimes"
  cat > "$T/no-runtimes/jq" <<'EOF'
#!/bin/sh
touch RUNTIME_MUST_NOT_RUN
exit 77
EOF
  cp "$T/no-runtimes/jq" "$T/no-runtimes/node"
  cp "$T/no-runtimes/jq" "$T/no-runtimes/python3"
  chmod +x "$T/no-runtimes/"*
  run env PATH="$T/no-runtimes:$PATH" gitch module audit --json
  assert_ok
  printf '%s' "$OUT" | "$jq_bin" -e '.stats.errors==1 and .incomplete==false' >/dev/null || fail 'invalid dependency audit'
  [ ! -e SHOULD_NOT_EXIST ] && [ ! -e SCRIPT_MUST_NOT_RUN ] && [ ! -e RUNTIME_MUST_NOT_RUN ] || fail 'data or optional runtime was executed'
  assert_out 'src/$() quote'
}

test_module_audit_unsafe_paths_symlinks_and_missing_manifests_are_explicit() {
  # NTFS cannot represent the LF fixture; graph inventory has a protocol-level
  # Windows equivalent. The other audit tests run on both platforms.
  mac_only || return 0
  ma_test_repo "$T/audit-paths"
  echo '{"name":"safe"}' > package.json
  echo 'import "outside-sentinel";' > "$T/outside.ts"
  echo 'import "newline-sentinel";' > $'bad\nname.ts'
  ln -s "$T/outside.ts" linked.ts
  ma_test_track
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '.stats.errors')" 0
  assert_eq "$(ma_test_q '.diagnostics[0].code')" UNSUPPORTED_PATH
  run gitch module audit "$T/outside.ts" --json
  assert_rc 1
  assert_out 'error'
  rm package.json
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '[.diagnostics[].code]|index("INVALID_MANIFEST")!=null')" true
}

test_module_audit_non_npm_and_dynamic_sources_are_not_reported_complete() {
  ma_test_repo "$T/audit-non-npm"
  echo '[package]' > Cargo.toml
  ma_test_track
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '.diagnostics[0].code')" NO_NPM_MANIFESTS
  echo '{"name":"dynamic"}' > package.json
  echo 'const name="runtime"; import(name);' > index.js
  ma_test_track
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '.stats.errors')" 0
  assert_eq "$(ma_test_q '.diagnostics[0].code')" DYNAMIC_IMPORT
}

test_module_audit_parent_alias_context_and_jsx_runtime_are_conservative() {
  ma_test_repo "$T/audit-parent-alias"
  echo '{"name":"root","workspaces":["packages/*"]}' > package.json
  echo '{"compilerOptions":{"paths":{"@/*":["src/*"]}}}' > tsconfig.json
  echo '{"name":"member"}' | ma_test_put packages/member/package.json
  cat <<'EOF' | ma_test_put packages/member/view.tsx
import "@/model";
export const view = <div>require("jsx-text")</div>;
EOF
  ma_test_track
  ma_test_json packages/member
  assert_rc 1
  assert_eq "$(ma_test_q '.stats.errors')" 0
  assert_eq "$(ma_test_q '[.diagnostics[].code]|sort|join(",")')" JSX_RUNTIME_IMPORT_NOT_AUDITED,UNRESOLVED_CONFIG_IMPORT
}

test_module_audit_human_output_has_context_and_real_locations() {
  ma_test_repo "$T/audit-human"
  echo '{"name":"human","devDependencies":{"tool":"*"}}' > package.json
  echo 'import "missing";' > source.ts
  ma_test_track
  run gitch module audit
  assert_ok
  assert_out 'MISSING_DEPENDENCY'
  assert_out 'human → missing'
  assert_out 'source.ts:1'
  assert_out 'package.json'
  assert_out '관찰되지 않은 선언 1개'
  assert_no_out '{"code"'
}

test_module_audit_concurrent_file_change_is_explicitly_incomplete() {
  local real_awk
  real_awk=$(command -v awk)
  ma_test_repo "$T/audit-race"
  echo '{"name":"before"}' > package.json
  echo 'import "missing";' > source.ts
  ma_test_track
  mkdir -p "$T/racebin"
  cat > "$T/racebin/awk" <<'EOF'
#!/bin/bash
"$GITCH_TEST_REAL_AWK" "$@"
rc=$?
case "$*" in *audit.awk*) printf '{"name":"after"}\n' > "$GITCH_TEST_CHANGED_MANIFEST" ;; esac
exit "$rc"
EOF
  chmod +x "$T/racebin/awk"
  run env PATH="$T/racebin:$PATH" GITCH_TEST_REAL_AWK="$real_awk" GITCH_TEST_CHANGED_MANIFEST="$PWD/package.json" gitch module audit --json
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(ma_test_q '.incomplete')" true
  assert_eq "$(ma_test_q '[.diagnostics[].code]|index("INPUT_CHANGED")!=null')" true
  assert_eq "$(ma_test_q '.stats.warnings')" 1
}

test_module_audit_root_wildcard_workspace_and_malformed_shape() {
  ma_test_repo "$T/audit-root-star"
  echo '{"name":"root","workspaces":["*"],"dependencies":{"shared":"1"}}' > package.json
  echo '{"name":"member","dependencies":{"shared":"2"}}' | ma_test_put member/package.json
  ma_test_track
  ma_test_json --strict
  assert_ok
  assert_eq "$(ma_test_q '[.findings[]|select(.code=="VERSION_SPEC_MISMATCH")]|length')" 1
  echo '{"name":"root","workspaces":{"packages":"member/*"}}' > package.json
  ma_test_json
  assert_rc 1
  assert_eq "$(ma_test_q '[.diagnostics[].code]|index("INVALID_MANIFEST")!=null')" true
}

test_module_audit_jsx_text_arrow_regex_and_local_require_never_create_missing() {
  ma_test_repo "$T/audit-lexical"
  echo '{"name":"lexical","dependencies":{"loader":"*"}}' > package.json
  cat <<'EOF' | ma_test_put view.tsx
export const view = <pre>import "display-only";</pre>;
EOF
  cat <<'EOF' | ma_test_put pattern.js
const pattern = () => /require("regex-display")/;
const throwing = () => { throw /import("throw-display")/; };
EOF
  cat <<'EOF' | ma_test_put import-binding.js
import { require } from "loader";
require("local-handler");
EOF
  cat <<'EOF' | ma_test_put destructured.js
const { require } = loader;
require("destructured-handler");
EOF
  ma_test_track
  ma_test_json --strict
  assert_rc 1
  assert_eq "$(ma_test_q '.stats.errors')" 0
  assert_eq "$(ma_test_q '[.diagnostics[].code]|unique|sort|join(",")')" JSX_DECLARATION_NOT_AUDITED,SHADOWED_REQUIRE
}

test_module_audit_resolves_simple_tsconfig_paths_without_missing_or_noise() {
  ma_test_repo "$T/audit-resolved-alias"
  echo '{"name":"alias"}' > package.json
  echo '{"compilerOptions":{"paths":{"@/*":["src/*"]}}}' > tsconfig.json
  echo 'export const value=1;' | ma_test_put src/value.ts
  echo 'export const nested=1;' | ma_test_put src/nested/value.ts
  cat <<'EOF' | ma_test_put src/main.ts
import "@/value";
import "@/nested/value";
import "real-external";
EOF
  ma_test_track
  ma_test_json
  assert_ok
  assert_eq "$(ma_test_q '.incomplete')" false
  assert_eq "$(ma_test_q '[.findings[].dependency]|join(",")')" real-external
}
