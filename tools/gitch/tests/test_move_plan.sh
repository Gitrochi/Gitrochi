# shellcheck shell=bash
# 이동 계획은 임시 저장소의 현재 파일만 읽으며 실제 이동이나 테스트를 실행하지 않는다.
mp_repo() {
  mkdir -p "$1" && cd "$1" || fail "cd $1"
  git init -q . || fail 'fixture init'
  git config user.name 'Move plan fixture'
  git config user.email move-plan@example.com
  MP_ROOT="$PWD"
}
mp_put() { mkdir -p "$(dirname -- "$1")" && cat > "$1"; }
mp_commit() { git add -A && git commit -q -m fixture || fail 'fixture commit'; }
mp_json() { run gitch move "$@" --plan --json; assert_ok; assert_json "$OUT"; }
mp_q() { printf '%s' "$OUT" | jq -r "$1"; }
mp_assert() { printf '%s' "$OUT" | jq -e "$1" >/dev/null || fail "$2\n$OUT"; }
mp_fingerprint() {
  python3 - "$@" <<'PY'
import hashlib, os, sys
digest = hashlib.sha256()
for root in sys.argv[1:]:
    if os.path.isfile(root):
        digest.update(root.encode('utf-8'))
        with open(root, 'rb') as handle:
            digest.update(handle.read())
        continue
    for parent, dirs, files in os.walk(root):
        dirs.sort()
        digest.update(('directory:' + parent).encode('utf-8'))
        for name in dirs:
            path = os.path.join(parent, name)
            if os.path.islink(path):
                digest.update(path.encode('utf-8'))
                digest.update(os.readlink(path).encode('utf-8'))
        for name in sorted(files):
            path = os.path.join(parent, name)
            digest.update(path.encode('utf-8'))
            if os.path.islink(path):
                digest.update(os.readlink(path).encode('utf-8'))
            else:
                with open(path, 'rb') as handle:
                    digest.update(handle.read())
print(digest.hexdigest())
PY
}
mp_error() {
  local rc
  gitch move "$@" > "$T/move-stdout" 2> "$T/move-stderr"; rc=$?
  [ "$rc" -ne 0 ] || fail "move must refuse: $*"
  [ ! -s "$T/move-stdout" ] || fail "error polluted stdout: $(cat "$T/move-stdout")"
  [ -s "$T/move-stderr" ] || fail "missing error diagnostic: $*"
  assert_json "$(cat "$T/move-stderr")" 'move --json error must be JSON on stderr'
}

test_move_plan_file_reports_incoming_outgoing_and_external_boundaries() {
  mp_repo "$T/file-plan"
  echo '{"name":"app","scripts":{"test":"touch ../move-tests-ran"}}' | mp_put package.json
  echo 'export const helper=1;' | mp_put helper.ts
  echo 'import { helper } from "./helper"; import React from "react"; export const service=helper;' | mp_put service.ts
  echo 'import { service } from "./service"; export const caller=service;' | mp_put caller.ts
  echo '// filename-based candidate; never executed' | mp_put tests/service.test.ts
  mp_commit
  local before; before=$(mp_fingerprint "$MP_ROOT" "$HOME/.gitconfig")
  mp_json service.ts lib/service.ts
  assert_eq "$(mp_q '.schemaVersion')" 1
  assert_eq "$(mp_q '.tool')" 'gitch move'
  assert_eq "$(mp_q '.mode')" plan
  assert_eq "$(mp_q '.source')" service.ts
  assert_eq "$(mp_q '.destination')" lib/service.ts
  assert_eq "$(mp_q '.kind')" file
  assert_eq "$(mp_q '.moves|length')" 1
  assert_eq "$(mp_q '.moves[0]|.from+"->"+.to')" 'service.ts->lib/service.ts'
  mp_assert '.references|any(.source=="caller.ts" and .target=="service.ts" and .sourceAfter=="caller.ts" and .targetAfter=="lib/service.ts" and .heuristic==false and (.evidence|length)>0)' 'incoming reference and evidence missing'
  mp_assert '.references|any(.source=="service.ts" and .target=="helper.ts" and .sourceAfter=="lib/service.ts" and .targetAfter=="helper.ts")' 'outgoing reference missing'
  mp_assert '.suggestions|any(.file=="caller.ts" and .fileAfter=="caller.ts" and .line==1 and .from=="./service" and .to=="./lib/service")' 'incoming relative import correction missing'
  mp_assert '.suggestions|any(.file=="service.ts" and .fileAfter=="lib/service.ts" and .line==1 and .from=="./helper" and .to=="../helper")' 'moved source outgoing relative import correction missing'
  mp_assert '.references|all((.target|startswith("pkg:"))|not)' 'external packages are not movable local-file references'
  assert_eq "$(mp_q '.references|length')" 2
  mp_assert '.affectedFiles|index("caller.ts")!=null' 'caller should be affected'
  mp_assert '.tests|index("tests/service.test.ts")!=null' 'filename test candidate missing'
  mp_assert '.notes|join(" ")|test("파일명|파일 이름|filename|file name";"i")' 'test candidates must explicitly disclose filename inference'
  mp_assert '(.repo|type)=="string" and (.modules.before|type)=="array" and (.modules.after|type)=="array" and (.notes|length)>0' 'plan metadata'
  assert_eq "$(mp_q '.incomplete')" false
  assert_eq "$(mp_fingerprint "$MP_ROOT" "$HOME/.gitconfig")" "$before" 'plan must leave HEAD, index, configs and all files byte-identical'
  [ ! -e lib/service.ts ] || fail 'plan moved or copied the file'
  [ ! -e "$T/move-tests-ran" ] || fail 'plan executed test script'
  run gitch move service.ts lib/service.ts --plan
  assert_ok
  [ ! -e lib/service.ts ] || fail 'human output must also be read-only'
}

test_move_plan_directory_remaps_both_internal_endpoints() {
  mp_repo "$T/directory-plan"
  echo 'export const b=1;' | mp_put src/feature/nested/b.ts
  echo 'import { b } from "./nested/b"; export const a=b;' | mp_put src/feature/a.ts
  echo 'import { a } from "./src/feature/a";' | mp_put caller.ts
  mp_commit
  mp_json src/feature lib/feature
  assert_eq "$(mp_q '.kind')" directory
  assert_eq "$(mp_q '.moves|map(.from)|sort|join(",")')" 'src/feature/a.ts,src/feature/nested/b.ts'
  assert_eq "$(mp_q '.moves|map(.to)|sort|join(",")')" 'lib/feature/a.ts,lib/feature/nested/b.ts'
  mp_assert '.references|any(.source=="src/feature/a.ts" and .target=="src/feature/nested/b.ts" and .sourceAfter=="lib/feature/a.ts" and .targetAfter=="lib/feature/nested/b.ts")' 'internal directory reference must remap both endpoints'
  mp_assert '.references|any(.source=="caller.ts" and .target=="src/feature/a.ts" and .sourceAfter=="caller.ts" and .targetAfter=="lib/feature/a.ts")' 'external caller must retain its own path'
  assert_eq "$(mp_q '.incomplete')" false
  [ -f src/feature/a.ts ] && [ ! -e lib/feature ] || fail 'directory plan mutated filesystem'
}

test_move_plan_modules_report_source_and_destination_ownership() {
  mp_repo "$T/module-plan"
  echo '{"name":"root","workspaces":["packages/*"]}' | mp_put package.json
  echo '{"name":"a"}' | mp_put packages/a/package.json
  echo '{"name":"b"}' | mp_put packages/b/package.json
  echo 'export const core=1;' | mp_put packages/a/core.ts
  echo 'export const existing=1;' | mp_put packages/b/existing.ts
  mp_commit
  mp_json packages/a/core.ts packages/b/core.ts
  mp_assert '.modules.before|index("npm:a")!=null' 'source module missing'
  mp_assert '.modules.after|index("npm:b")!=null' 'destination module missing'
}

test_move_plan_includes_nonignored_untracked_file() {
  mp_repo "$T/untracked-plan"
  echo 'export const base=1;' | mp_put base.ts
  mp_commit
  echo 'import { base } from "./base";' | mp_put pending.ts
  mp_json pending.ts lib/pending.ts
  assert_eq "$(mp_q '.moves[0].from')" pending.ts
  mp_assert '.references|any(.source=="pending.ts" and .target=="base.ts")' 'untracked file dependencies missing'
  [ -f pending.ts ] && [ ! -e lib/pending.ts ] || fail 'untracked plan mutated files'
}

test_move_plan_directory_excludes_ignored_contents_and_marks_incomplete() {
  mp_repo "$T/ignored-plan"
  echo 'src/feature/ignored.ts' | mp_put .gitignore
  echo 'export const tracked=1;' | mp_put src/feature/tracked.ts
  mp_commit
  echo 'export const pending=1;' | mp_put src/feature/pending.ts
  echo 'export const ignored=1;' | mp_put src/feature/ignored.ts
  local before; before=$(mp_fingerprint "$MP_ROOT")
  run gitch move src/feature lib/feature --plan --json
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(mp_q '.moves|map(.from)|sort|join(",")')" 'src/feature/pending.ts,src/feature/tracked.ts'
  assert_eq "$(mp_q '.incomplete')" true
  mp_assert '.diagnostics|any(.severity=="warning" and (.message|length)>0)' 'omitted ignored content must be disclosed'
  assert_eq "$(mp_fingerprint "$MP_ROOT")" "$before" 'ignored files must remain unchanged'
  mp_error src/feature/ignored.ts ignored-moved.ts --plan --json
}

test_move_plan_reads_working_tree_instead_of_hidden_staged_imports() {
  mp_repo "$T/current-bytes-plan"
  echo 'export const service=1;' | mp_put service.ts
  echo 'export const consumer=1;' | mp_put consumer.ts
  mp_commit
  echo 'import { service } from "./service"; export const consumer=service;' > consumer.ts
  git add consumer.ts
  git show HEAD:consumer.ts > consumer.ts
  local before; before=$(mp_fingerprint "$MP_ROOT")
  mp_json service.ts lib/service.ts
  assert_eq "$(mp_q '.references|length')" 0 'move plan scope is current file contents'
  assert_eq "$(mp_fingerprint "$MP_ROOT")" "$before" 'move plan must preserve staged and unstaged state'
}

test_move_plan_preserves_spaces_quotes_backslashes_and_optionlike_paths() {
  mp_repo "$T/space quote ' plan"
  local source='space quote '\'' $literal.ts' destination='new quote '\'' $literal.ts'
  if mac_only; then source="${source}\\source.ts"; destination="${destination}\\destination.ts"; fi
  echo 'export const value=1;' | mp_put "$source"
  echo 'export const other=1;' | mp_put -source.ts
  mp_commit
  mp_json "$source" "$destination"
  printf '%s' "$OUT" | jq -e --arg source "$source" --arg destination "$destination" '.source==$source and .destination==$destination and .moves==[{from:$source,to:$destination}]' >/dev/null || fail "filenames not preserved: $OUT"
  run gitch move --plan --json -- -source.ts -destination.ts
  assert_ok
  assert_json "$OUT"
  assert_eq "$(mp_q '.moves[0].from')" -source.ts
  assert_eq "$(mp_q '.moves[0].to')" -destination.ts
}

test_move_plan_paths_resolve_relative_to_invocation_subdirectory() {
  mp_repo "$T/subdir-plan"
  echo 'export const core=1;' | mp_put src/core.ts
  echo 'import { core } from "./core";' | mp_put src/caller.ts
  mp_commit
  cd src || fail 'subdir cd'
  mp_json ./core.ts ../lib/core.ts
  assert_eq "$(mp_q '.source')" src/core.ts
  assert_eq "$(mp_q '.destination')" lib/core.ts
  mp_assert '.references|any(.source=="src/caller.ts" and .targetAfter=="lib/core.ts")' 'subdirectory plan must retain repository-relative reference paths'
  mp_json "$MP_ROOT/src/core.ts" "$MP_ROOT/lib/core.ts"
  assert_eq "$(mp_q '.source')" src/core.ts
  assert_eq "$(mp_q '.destination')" lib/core.ts
  if [ -n "$IS_WIN" ]; then
    mp_json "$(cygpath -w "$MP_ROOT/src/core.ts")" "$(cygpath -w "$MP_ROOT/lib/core.ts")"
    assert_eq "$(mp_q '.source')" src/core.ts
    assert_eq "$(mp_q '.destination')" lib/core.ts
  fi
}

test_move_plan_suggestions_preserve_runtime_extensions_suffixes_and_evidence() {
  mp_repo "$T/import-style-plan"
  echo 'export const service=1;' | mp_put service.ts
  mp_put caller.ts <<'TS'
import { service as first } from "./service.js";
import { service as second } from "./service.js";
import { service as raw } from "./service?raw";
import { service as fragment } from "./service#chunk";
TS
  mp_commit
  mp_json service.ts lib/service.ts
  mp_assert '.suggestions|any(.file=="caller.ts" and .line==1 and .from=="./service.js" and .to=="./lib/service.js")' 'explicit runtime .js must remain .js when implementation file is .ts'
  mp_assert '.suggestions|any(.file=="caller.ts" and .line==2 and .from=="./service.js" and .to=="./lib/service.js")' 'multiple import evidence lines must each receive a candidate'
  mp_assert '.suggestions|any(.line==3 and .from=="./service?raw" and .to=="./lib/service?raw")' 'query suffix must be preserved'
  mp_assert '.suggestions|any(.line==4 and .from=="./service#chunk" and .to=="./lib/service#chunk")' 'fragment suffix must be preserved'
  assert_eq "$(mp_q '.suggestions|length')" 4 'each physical import line should appear once'
}

test_move_plan_directory_index_import_style_and_index_rename() {
  mp_repo "$T/index-style-plan"
  echo 'export const value=1;' | mp_put src/pkg/index.ts
  echo 'import { value } from "./src/pkg";' | mp_put caller.ts
  mp_commit
  mp_json src/pkg lib/pkg
  mp_assert '.suggestions|any(.file=="caller.ts" and .from=="./src/pkg" and .to=="./lib/pkg")' 'directory imports must keep index filename implicit'
  mp_json src/pkg/index.ts src/pkg/entry.ts
  mp_assert '.suggestions|any(.file=="caller.ts" and .from=="./src/pkg" and .to=="./src/pkg/entry")' 'renaming an index file must expose its new stem in a directory import'
}

test_move_plan_suggestions_skip_aliases_and_unsafe_destination_specifiers() {
  mp_repo "$T/safe-suggestions-plan"
  echo '{"compilerOptions":{"baseUrl":".","paths":{"@/*":["src/*"]}}}' | mp_put tsconfig.json
  echo 'export const service=1;' | mp_put src/service.ts
  echo 'import { service } from "@/service";' | mp_put alias.ts
  echo 'import { service } from "./src/service";' | mp_put caller.ts
  mp_commit
  mp_json src/service.ts lib/service.ts
  mp_assert '.references|any(.source=="alias.ts" and .target=="src/service.ts")' 'alias reference must still be reported'
  mp_assert '.suggestions|all(.file!="alias.ts")' 'an alias needs config context and must not receive a relative-path rewrite'
  mp_json src/service.ts "lib/quote'name.ts"
  mp_assert '.references|any(.source=="caller.ts" and .targetAfter=="lib/quote'"'"'name.ts")' 'quoted target remains a remapped reference'
  assert_eq "$(mp_q '.suggestions|length')" 0 'quote-containing specifiers require manual review'
  if mac_only; then
    local destination='lib/back\slash.ts'
    mp_json src/service.ts "$destination"
    printf '%s' "$OUT" | jq -e --arg destination "$destination" '.references|any(.source=="caller.ts" and .targetAfter==$destination)' >/dev/null || fail 'backslash target reference missing'
    assert_eq "$(mp_q '.suggestions|length')" 0 'backslash-containing specifiers require manual review'
  fi
}

test_move_plan_refuses_invalid_paths_and_existing_exact_destinations() {
  mp_repo "$T/refusal-plan"
  echo 'export const core=1;' | mp_put src/core.ts
  echo 'export const occupied=1;' | mp_put occupied.ts
  mkdir existing
  mp_commit
  echo 'outside' > "$T/outside.ts"
  local before; before=$(mp_fingerprint "$MP_ROOT" "$T/outside.ts")
  mp_error missing.ts missing-new.ts --plan --json
  mp_error src/core.ts src/./core.ts --plan --json
  mp_error src/core.ts ../outside-moved.ts --plan --json
  mp_error ../outside.ts outside-moved.ts --plan --json
  mp_error .git/config config-moved.ts --plan --json
  mp_error src/core.ts .git/core.ts --plan --json
  mp_error src/core.ts occupied.ts --plan --json
  mp_error src/core.ts existing --plan --json
  mp_error existing empty-moved --plan --json
  mp_error src src/nested --plan --json
  assert_eq "$(mp_fingerprint "$MP_ROOT" "$T/outside.ts")" "$before" 'rejected paths must not mutate source, destination or metadata'
}

test_move_plan_refuses_symlink_leaf_and_ancestors() {
  mac_only || return 0
  mp_repo "$T/symlink-plan"
  echo 'export const core=1;' | mp_put src/core.ts
  mp_commit
  mkdir "$T/outside"
  echo 'export const outside=1;' > "$T/outside/outside.ts"
  ln -s "$T/outside" linked
  ln -s src/core.ts linked-file.ts
  mp_error src/core.ts linked/new.ts --plan --json
  mp_error linked/outside.ts new.ts --plan --json
  mp_error linked-file.ts new.ts --plan --json
  [ ! -e "$T/outside/new.ts" ] || fail 'plan wrote through symlink ancestor'
}

test_move_plan_unresolved_and_unsupported_sources_are_disclosed() {
  mp_repo "$T/limited-plan"
  echo 'import "./missing"; export const service=1;' | mp_put service.ts
  mp_commit
  run gitch move service.ts lib/service.ts --plan --json
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(mp_q '.incomplete')" true
  mp_assert '.diagnostics|any(.severity=="warning" and (.message|length)>0)' 'unresolved source reference must be disclosed'
  echo 'export const service=1;' > service.ts
  echo 'opaque bytes' | mp_put payload.unknown
  run gitch move payload.unknown lib/payload.unknown --plan --json
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(mp_q '.moves[0].from')" payload.unknown
  assert_eq "$(mp_q '.incomplete')" true
  mp_assert '.diagnostics|any(.severity=="warning" and (.message|length)>0)' 'unsupported moved file must be disclosed'
}

test_move_plan_requires_explicit_plan_and_reports_argument_errors_on_stderr() {
  mp_repo "$T/argument-plan"
  echo 'export const core=1;' | mp_put core.ts
  mp_commit
  mp_error core.ts moved.ts --json
  mp_error --plan --json
  mp_error core.ts --plan --json
  mp_error core.ts moved.ts extra.ts --plan --json
  mp_error core.ts moved.ts --plan --json --execute
  cd "$T" || fail 'outside cd'
  mp_error core.ts moved.ts --plan --json
}
