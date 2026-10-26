# shellcheck shell=bash
# gitch graph — 구조 그래프 (files · modules · changes · tree / json · html · dot · svg · png)
export GITCH_SWIFT_INDEX=""   # 이 기계에 Xcode 인덱스 도우미가 있어도 시험은 이름 추정으로(도우미 시험만 따로 켠다)

gr_repo() {   # $1 폴더 — 빈 저장소를 만들고 들어간다 (커밋 작성자는 임시 값)
  mkdir -p "$1" && cd "$1" || fail "cd $1"
  git init -q .
  git config user.name t && git config user.email t@example.com
}
gr_put() { mkdir -p "$(dirname "$1")" && cat > "$1"; }   # $1 경로, 내용은 표준입력
gr_commit() { git add -A && git commit -q -m "${1:-c}" || fail "커밋 실패"; }
gr_json() { run gitch graph "$@"; assert_ok "gitch graph $*"; assert_json "$OUT" "gitch graph $* 출력이 JSON 이 아님"; }
gr_q() { printf '%s' "$OUT" | jq -r "$1"; }
gr_edge() {   # $1 시작 $2 끝 [$3 종류] — 마지막 JSON(OUT)에 그 연결이 있어야
  printf '%s' "$OUT" | jq -e --arg s "$1" --arg t "$2" --arg k "${3:-}" \
    '.edges | any(.source == $s and .target == $t and ($k == "" or .kind == $k))' >/dev/null \
    || fail "연결 없음: $1 → $2 ${3:+($3)}\n--- 연결:\n$(gr_q '.edges[] | "\(.source) → \(.target) (\(.kind))"')"
}
gr_no_edge() {
  printf '%s' "$OUT" | jq -e --arg s "$1" --arg t "$2" '.edges | any(.source == $s and .target == $t) | not' >/dev/null \
    || fail "있으면 안 되는 연결: $1 → $2"
}
gr_node() { printf '%s' "$OUT" | jq -e --arg n "$1" '.nodes | any(.id == $n)' >/dev/null || fail "노드 없음: $1\n--- 노드:\n$(gr_q '.nodes[].id')"; }
gr_no_node() { printf '%s' "$OUT" | jq -e --arg n "$1" '.nodes | any(.id == $n) | not' >/dev/null || fail "있으면 안 되는 노드: $1"; }
gr_attr() {   # $1 노드 $2 jq 식(노드 기준) $3 기대값
  local v; v=$(printf '%s' "$OUT" | jq -r --arg n "$1" ".nodes[] | select(.id == \$n) | $2")
  assert_eq "$v" "$3" "$1 의 $2"
}

test_graph_files_typescript() {
  gr_repo "$T/ts"
  gr_put tsconfig.json <<'EOF'
{
  // 주석이 있는 tsconfig
  "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["src/*"] } }
}
EOF
  gr_put src/a.ts <<'EOF'
import { b } from "./b";
import type { C } from '../lib';
import {
  d1,
  d2,
} from "./d";
export * from "./e.js";
import React from "react";
import sub from "@scope/pkg/sub";
import alias from "@/util/alias";
import "./side";
import u from "./untracked";
const lazy = () => import("./lazy");
const r = require("./req");
const s = "import x from './not-a-dep'";
// import z from "./commented";
/*
import y from "./commented";
*/
EOF
  echo 'export const b = 1' | gr_put src/b.ts
  echo 'export type C = 1' | gr_put lib/index.ts
  echo 'export const d1 = 1, d2 = 2' | gr_put src/d.tsx
  echo 'export const e = 1' | gr_put src/e.ts
  echo 'export default 1' | gr_put src/util/alias.ts
  echo 'export default 1' | gr_put src/lazy.tsx
  echo 'module.exports = 1' | gr_put src/req.js
  echo 'console.log(1)' | gr_put src/side.mjs
  echo 'export default 1' | gr_put src/not-a-dep.ts
  echo 'export default 1' | gr_put src/commented.ts
  gr_commit
  echo 'export default 1' > src/untracked.ts            # 추적하지 않는 파일은 보지 않는다
  gr_json
  assert_eq "$(gr_q '.tool + " " + .relation + " " + (.directed | tostring)')" "gitch graph files true"
  gr_edge src/a.ts src/b.ts import
  gr_edge src/a.ts lib/index.ts import
  gr_edge src/a.ts src/d.tsx import
  gr_edge src/a.ts src/e.ts reexport
  gr_edge src/a.ts pkg:npm/react import
  gr_edge src/a.ts pkg:npm/@scope/pkg import
  gr_edge src/a.ts src/util/alias.ts import
  gr_edge src/a.ts src/side.mjs import
  gr_edge src/a.ts src/lazy.tsx dynamic-import
  gr_edge src/a.ts src/req.js require
  gr_no_edge src/a.ts src/not-a-dep.ts
  gr_no_edge src/a.ts src/commented.ts
  gr_no_node src/untracked.ts
  gr_attr src/a.ts .lines 19
  gr_attr src/a.ts .group ts
  assert_eq "$(gr_q '.stats.unresolved')" "1" "찾지 못한 상대 경로 import"
  assert_eq "$(gr_q '.edges[] | select(.source == "src/a.ts" and .target == "src/util/alias.ts") | .via[0]')" "@/util/alias"
  gr_json --no-external
  gr_no_node pkg:npm/react
  gr_edge src/a.ts src/b.ts import
}

test_graph_files_python() {
  gr_repo "$T/py"
  : | gr_put pkg/__init__.py
  gr_put pkg/a.py <<'EOF'
"""설명 안의 글은 import 가 아니다
import fake_in_docstring
"""
import os
import pkg.b as bb
from . import c
from .sub import d
from .sub.e import thing
from pkg import f
from pkg.g import (
    x,
    y,
)
import numpy as np
EOF
  for f in b c f g sub/d sub/e; do echo 'x = 1' | gr_put "pkg/$f.py"; done
  : | gr_put pkg/sub/__init__.py
  echo 'from pkg.a import main' | gr_put scripts/run.py
  gr_commit
  gr_json files
  gr_edge pkg/a.py pkg/b.py import
  gr_edge pkg/a.py pkg/c.py import
  gr_edge pkg/a.py pkg/sub/d.py import
  gr_edge pkg/a.py pkg/sub/e.py import
  gr_edge pkg/a.py pkg/f.py import
  gr_edge pkg/a.py pkg/g.py import
  gr_edge pkg/a.py pkg:pypi/os import
  gr_edge pkg/a.py pkg:pypi/numpy import
  gr_edge scripts/run.py pkg/a.py import
  gr_no_node pkg:pypi/fake_in_docstring
  gr_no_node pkg:pypi/pkg
  gr_attr pkg/a.py .group python
}

test_graph_files_go() {
  gr_repo "$T/go"
  printf 'module example.com/app\n\ngo 1.22\n\nrequire github.com/spf13/cobra v1.8.0\n' | gr_put go.mod
  gr_put main.go <<'EOF'
package main

import (
	"fmt"

	"example.com/app/internal/store"
	cli "github.com/spf13/cobra/doc"
)

func main() { fmt.Println(store.X, cli.X) }
EOF
  printf 'package store\n\nimport "example.com/app/internal/util"\n\nvar X = util.Y\n' | gr_put internal/store/store.go
  printf 'package store\n\nimport "testing"\n' | gr_put internal/store/store_test.go
  printf 'package util\n\nvar Y = 1\n' | gr_put internal/util/util.go
  gr_commit
  gr_json
  gr_edge main.go internal/store/ import
  gr_edge internal/store/store.go internal/util/ import
  gr_edge main.go pkg:golang/fmt import
  gr_edge main.go pkg:golang/github.com/spf13/cobra import
  gr_edge internal/store/ internal/store/store.go contains
  gr_no_edge internal/store/ internal/store/store_test.go
  gr_attr internal/store/ .kind folder
  gr_attr internal/store/ .importPath example.com/app/internal/store
}

test_graph_files_rust() {
  gr_repo "$T/rs"
  printf '[package]\nname = "demo-app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1"\n' | gr_put Cargo.toml
  gr_put src/lib.rs <<'EOF'
pub mod net;
mod store;
#[cfg(test)]
mod tests;
use crate::store::Db;
use serde::Serialize;
EOF
  printf 'mod http;\npub struct Client;\nuse super::store::Db;\n' | gr_put src/net/mod.rs
  gr_put src/net/http.rs <<'EOF'
use crate::{
    store::Db,
    net::Client as C,
};
EOF
  printf 'pub struct Db;\nmod inner {\n    use super::Db;\n}\n' | gr_put src/store.rs
  printf 'use super::*;\n' | gr_put src/tests.rs
  printf 'use demo_app::store::Db;\n' | gr_put tests/it.rs
  gr_commit
  gr_json
  gr_edge src/lib.rs src/net/mod.rs mod
  gr_edge src/lib.rs src/store.rs mod
  gr_edge src/lib.rs src/tests.rs mod
  gr_edge src/lib.rs src/store.rs use
  gr_edge src/lib.rs pkg:cargo/serde use
  gr_edge src/net/mod.rs src/net/http.rs mod
  gr_edge src/net/mod.rs src/store.rs use
  gr_edge src/net/http.rs src/store.rs use
  gr_edge src/net/http.rs src/net/mod.rs use
  gr_edge src/tests.rs src/lib.rs use
  gr_edge tests/it.rs src/store.rs use
  gr_no_edge src/store.rs src/lib.rs                   # 인라인 mod 안의 super:: 는 그 파일 자신
  gr_no_node pkg:cargo/demo_app
}

test_graph_files_kotlin_java() {
  gr_repo "$T/jvm"
  gr_put app/src/main/kotlin/com/example/app/Main.kt <<'EOF'
package com.example.app

import com.example.core.Repo
import com.example.core.util.*
import kotlinx.coroutines.flow.Flow

fun main() {
    val r = Repo()
    Helper.run("Hidden in a string")
}
EOF
  printf 'package com.example.app\n\nobject Helper {\n    fun run(s: String) {}\n}\n' | gr_put app/src/main/kotlin/com/example/app/Helper.kt
  printf 'package com.example.core\n\nclass Repo\n\nprivate class Hidden\n' | gr_put core/src/main/kotlin/com/example/core/Repo.kt
  printf 'package com.example.core.util\n\nfun String.shout() = uppercase()\n' | gr_put core/src/main/kotlin/com/example/core/util/Strings.kt
  printf 'package com.example.core;\n\nimport java.util.List;\n\npublic class Legacy {\n    Repo repo;\n}\n' | gr_put core/src/main/java/com/example/core/Legacy.java
  gr_commit
  gr_json
  gr_edge app/src/main/kotlin/com/example/app/Main.kt core/src/main/kotlin/com/example/core/Repo.kt import
  gr_edge app/src/main/kotlin/com/example/app/Main.kt core/src/main/kotlin/com/example/core/util/Strings.kt import
  gr_edge app/src/main/kotlin/com/example/app/Main.kt pkg:maven/kotlinx.coroutines.flow import
  gr_edge app/src/main/kotlin/com/example/app/Main.kt app/src/main/kotlin/com/example/app/Helper.kt type-ref
  gr_edge core/src/main/java/com/example/core/Legacy.java core/src/main/kotlin/com/example/core/Repo.kt type-ref
  gr_edge core/src/main/java/com/example/core/Legacy.java pkg:maven/java.util import
  assert_eq "$(gr_q '[.edges[] | select(.kind == "type-ref") | .heuristic] | all')" "true" "같은 패키지 추정 연결은 heuristic"
  case "$(gr_q '.notes | join(" ")')" in *Kotlin/Java*) ;; *) fail "Kotlin/Java 추정 안내가 없음" ;; esac
}

test_graph_files_swift_heuristic() {
  gr_repo "$T/swift"
  gr_put Sources/Core/Model.swift <<'EOF'
import Foundation

public struct Model {}
private struct Secret {}
@MainActor final class Store {}
EOF
  gr_put Sources/Core/Helpers.swift <<'EOF'
/*
 Store 는 주석 안이라 세지 않는다
*/
let text = "Store in a string"
// Store in a comment
extension Model {}
EOF
  gr_put Sources/App/main.swift <<'EOF'
import Core
@testable import Foundation

let s = Store()
let x: Secret? = nil
let msg = """
Model in a multiline string
"""
EOF
  gr_commit
  gr_json
  gr_edge Sources/Core/Helpers.swift Sources/Core/Model.swift type-ref
  gr_edge Sources/App/main.swift Sources/Core/Model.swift type-ref
  assert_eq "$(gr_q '.edges[] | select(.source == "Sources/Core/Helpers.swift" and .kind == "type-ref") | .via | join(",")')" "Model" "주석 · 문자열 속 이름은 빼고"
  assert_eq "$(gr_q '.edges[] | select(.source == "Sources/App/main.swift" and .kind == "type-ref") | .via | join(",")')" "Store" "private 타입 · 여러 줄 문자열은 빼고"
  assert_eq "$(gr_q '.edges[] | select(.kind == "type-ref") | .heuristic' | sort -u)" "true"
  gr_edge Sources/App/main.swift module:Core import
  gr_edge Sources/App/main.swift module:Foundation import
  gr_attr module:Core .local Sources/Core
  [ "$(gr_q '.stats.heuristicEdges')" -ge 2 ] || fail "heuristicEdges 가 2 이상이어야"
  case "$(gr_q '.notes | join(" ")')" in *Swift*) ;; *) fail "Swift 추정 안내가 없음" ;; esac
}

test_graph_files_swift_index_helper() {
  gr_repo "$T/swiftidx"
  printf 'public struct A {}\n' | gr_put Sources/M/A.swift
  printf 'let b = A()\nlet c = C()\n' | gr_put Sources/M/B.swift
  printf 'struct C {}\n' | gr_put Sources/M/C.swift
  printf 'let d = C()\n' | gr_put Sources/M/D.swift          # 빌드 뒤에 만든 파일 — 인덱스에 없다
  gr_commit
  # 도우미가 준 쌍은 정확한 연결(ref), 인덱스에 든 파일은 이름으로 추정하지 않는다. 오래된 인덱스 경고는 notes 로
  cat > "$T/idx-ok" <<'EOF'
#!/bin/bash
[ "$1" = --repo ] && [ -d "$2" ] && [ "$3" = --covered ] || exit 9
printf 'Sources/M/A.swift\nSources/M/B.swift\nSources/M/C.swift\n' > "$4"
printf 'Sources/M/B.swift\tSources/M/A.swift\tA\n'
printf 'Sources/M/B.swift\tSources/M/B.swift\tself\n'
printf 'Sources/M/nope.swift\tSources/M/A.swift\tA\n'
echo "gitch-swift-index: 경고: 인덱스가 Swift 파일 1개보다 오래됐습니다" >&2
EOF
  chmod +x "$T/idx-ok"
  GITCH_SWIFT_INDEX="$T/idx-ok" gr_json
  gr_edge Sources/M/B.swift Sources/M/A.swift ref
  gr_no_edge Sources/M/B.swift Sources/M/C.swift
  gr_edge Sources/M/D.swift Sources/M/C.swift type-ref                 # 인덱스에 없는 파일은 이름으로
  assert_eq "$(gr_q '[.edges[] | select(.heuristic)] | length')" "1" "인덱스에 든 파일은 추정하지 않는다"
  case "$(gr_q '.notes | join(" ")')" in *"Xcode 인덱스(gitch-swift-index)로 읽은 정확한 참조입니다 (연결 1개, 인덱스에 없는 파일 1개는 타입 이름으로 추정)"*) ;; *) fail "인덱스 안내가 없음: $(gr_q '.notes | join(" / ")')" ;; esac
  case "$(gr_q '.notes | join(" ")')" in *"인덱스가 Swift 파일 1개보다 오래됐습니다"*) ;; *) fail "오래된 인덱스 경고가 notes 에 없음" ;; esac
  # --covered 를 쓰지 않은 도우미면 모든 파일이 든 것으로 본다
  printf '#!/bin/bash\nprintf "Sources/M/B.swift\\tSources/M/A.swift\\tA\\n"\n' > "$T/idx-all"; chmod +x "$T/idx-all"
  GITCH_SWIFT_INDEX="$T/idx-all" gr_json
  assert_eq "$(gr_q '[.edges[] | select(.heuristic)] | length')" "0" "목록이 없으면 모두 인덱스로"
  # 인덱스가 없으면(종료 3) 이름 추정
  printf '#!/bin/bash\nexit 3\n' > "$T/idx-none"; chmod +x "$T/idx-none"
  GITCH_SWIFT_INDEX="$T/idx-none" gr_json
  gr_edge Sources/M/B.swift Sources/M/C.swift type-ref
  case "$(gr_q '.notes | join(" ")')" in *"Xcode 인덱스가 없어"*) ;; *) fail "인덱스 없음 안내가 없음" ;; esac
  # 실패하면 이유를 적고 이름 추정
  printf '#!/bin/bash\necho "store is locked" >&2\nexit 1\n' > "$T/idx-bad"; chmod +x "$T/idx-bad"
  GITCH_SWIFT_INDEX="$T/idx-bad" gr_json
  gr_edge Sources/M/B.swift Sources/M/A.swift type-ref
  case "$(gr_q '.notes | join(" ")')" in *"실패해(store is locked)"*) ;; *) fail "도우미 실패 안내가 없음" ;; esac
  # 빈 값이면 끈다
  GITCH_SWIFT_INDEX='' gr_json
  case "$(gr_q '.notes | join(" ")')" in *gitch-swift-index*|*"Xcode 인덱스"*) fail "빈 값인데 도우미를 불렀음" ;; esac
}

test_graph_files_swift_modules() {
  gr_repo "$T/swiftmod"
  # Tuist: 도우미 매니페스트(Sources/** · Tests/**)와 sources 를 적은 타깃, SwiftPM 패키지
  echo 'let project = Project.framework(name: "Core", dependencies: [])' | gr_put Projects/Core/Project.swift
  echo 'let project = Project.framework(name: "Kit")' | gr_put Projects/Kit/Project.swift
  gr_put Projects/App/Project.swift <<'EOF'
let project = Project(name: "App", targets: [
    .target(name: "App", destinations: .iOS, product: .app, bundleId: "x.app",
            sources: ["Sources/**", "../Shared/**"], dependencies: [.project(target: "Core", path: "../Core")]),
    .target(name: "Widget", destinations: .iOS, product: .appExtension, bundleId: "x.app.widget",
            sources: .glob("../Widget/**", excluding: ["../Widget/Gen/**"]))
])
EOF
  gr_put Packages/Net/Package.swift <<'EOF'
let package = Package(name: "Net", targets: [
    .target(name: "Net"),
    .target(name: "NetUI", dependencies: ["Net"]),
])
EOF
  printf 'public final class Store {}\nstruct Hidden {}\n' | gr_put Projects/Core/Sources/Store.swift
  printf 'public final class Store {}\npublic struct Tool {}\n' | gr_put Projects/Kit/Sources/Store.swift
  printf 'struct Local {}\n' | gr_put Projects/App/Sources/Local.swift
  printf 'struct Banner {}\n' | gr_put Projects/Shared/Banner.swift
  gr_put Projects/App/Sources/AppView.swift <<'EOF'
import Core

let a = Store()      // Core 를 import — Kit 의 같은 이름은 아니다
let b = Hidden()     // Core 의 internal 타입 — 보이지 않는다
let c = Tool()       // Kit 은 import 하지 않았다
let d = Local()      // 같은 모듈
let e = Banner()     // ../Shared/** 도 App 모듈
let f = Client()     // Net 은 import 하지 않았다
EOF
  printf '@testable import Core\n\nlet h = Hidden()\n' | gr_put Projects/Core/Tests/StoreTests.swift
  printf 'let w = Banner()\n' | gr_put Projects/Widget/WidgetView.swift
  printf 'public class Client {}\n' | gr_put Packages/Net/Sources/Net/Client.swift
  printf 'import Net\n\nlet c = Client()\n' | gr_put Packages/Net/Sources/NetUI/View.swift
  gr_commit
  gr_json
  gr_edge Projects/App/Sources/AppView.swift Projects/Core/Sources/Store.swift type-ref
  gr_no_edge Projects/App/Sources/AppView.swift Projects/Kit/Sources/Store.swift
  gr_edge Projects/App/Sources/AppView.swift Projects/App/Sources/Local.swift type-ref
  gr_edge Projects/App/Sources/AppView.swift Projects/Shared/Banner.swift type-ref
  gr_no_edge Projects/App/Sources/AppView.swift Packages/Net/Sources/Net/Client.swift
  assert_eq "$(gr_q '.edges[] | select(.source == "Projects/App/Sources/AppView.swift" and .target == "Projects/Core/Sources/Store.swift") | .via | join(",")')" "Store" "internal 타입(Hidden)은 다른 모듈에서 보이지 않음"
  gr_edge Projects/Core/Tests/StoreTests.swift Projects/Core/Sources/Store.swift type-ref   # @testable 이면 internal 도
  gr_no_edge Projects/Widget/WidgetView.swift Projects/Shared/Banner.swift                # Widget 은 Shared 를 소스로 갖지 않는다
  gr_edge Packages/Net/Sources/NetUI/View.swift Packages/Net/Sources/Net/Client.swift type-ref
  assert_eq "$(gr_q '[.edges[] | select(.kind == "type-ref") | .checked] | unique | map(tostring) | join(",")')" "true" "모듈로 확인한 추정에는 checked"
  gr_attr Projects/Shared/Banner.swift '.modules | join(",")' "App"
  gr_attr Projects/Core/Tests/StoreTests.swift '.modules | join(",")' "CoreTests"
  gr_attr Packages/Net/Sources/NetUI/View.swift '.modules | join(",")' "NetUI"
  gr_attr module:Core .local Projects/Core/Sources
  case "$(gr_q '.notes | join(" ")')" in *"모듈 8개, 그래서 뺀 이름 4개"*) ;; *) fail "모듈 경계 안내가 없음: $(gr_q '.notes | join(" / ")')" ;; esac
}

gr_spm_fixture() {   # Package.swift + 타깃 폴더(실제 swift package describe 도 되게)
  gr_put Package.swift <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Demo",
    products: [
        .library(name: "Core", targets: ["Core"]),
        .plugin(name: "Gen", targets: ["Gen"]),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")],
    targets: [
        .target(name: "Core"),  // .target(name: "Fake") 는 주석
        .executableTarget(
            name: "App",
            dependencies: ["Core", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "CoreTests", dependencies: [.target(name: "Core")], path: "Tests/CoreTests"),
        .plugin(name: "Gen", capability: .buildTool()),
    ]
)
EOF
  echo 'public struct Core {}' | gr_put Sources/Core/Core.swift
  echo 'import Core' | gr_put Sources/App/main.swift
  echo 'import XCTest' | gr_put Tests/CoreTests/CoreTests.swift
  printf 'import PackagePlugin\n@main struct Gen: BuildToolPlugin {\n    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] { [] }\n}\n' | gr_put Plugins/Gen/Gen.swift
}

gr_spm_check() {
  gr_edge swift:App swift:Core depends
  gr_edge swift:App pkg:swiftpm/ArgumentParser depends
  gr_edge swift:CoreTests swift:Core depends
  gr_node swift:Gen
  gr_no_node swift:Fake
  gr_attr swift:App .type executable
  gr_attr swift:CoreTests .path Tests/CoreTests
  gr_attr swift:Core .path Sources/Core
  assert_eq "$(gr_q '.edges[] | select(.source == "swift:App" and .target == "swift:Core") | .scope')" "target"
}

test_graph_modules_swiftpm_tuist() {
  gr_repo "$T/spm"
  gr_spm_fixture
  gr_put Projects/App/Project.swift <<'EOF'
import ProjectDescription

let project = Project(
    name: "App",
    targets: [
        .target(
            name: "App",
            destinations: .iOS,
            product: .app,
            bundleId: "com.example.app",
            dependencies: [
                .target(name: "AppUI"),
                .project(target: "Core", path: "../Core"),
                .external(name: "Alamofire"),
                .sdk(name: "StoreKit", type: .framework),
            ]
        ),
        .target(name: "AppUI", destinations: .iOS, product: .framework, bundleId: "com.example.ui"),
    ]
)
EOF
  gr_put Projects/Core/Project.swift <<'EOF'
import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(name: "Core", dependencies: [.external(name: "Logging")])
EOF
  gr_commit
  GITSW_SWIFT_DESCRIBE=0 gr_json modules
  gr_spm_check
  gr_edge tuist:App tuist:AppUI depends
  gr_edge tuist:App tuist:Core depends
  gr_edge tuist:App pkg:swiftpm/Alamofire depends
  gr_edge tuist:App pkg:sdk/StoreKit depends
  gr_edge tuist:Core pkg:swiftpm/Logging depends
  gr_attr tuist:App .type app
  gr_attr tuist:AppUI .type framework
  # swift 가 있으면 swift package describe 의 JSON 으로도 같은 결과
  if command -v swift >/dev/null 2>&1; then
    gr_json modules
    gr_spm_check
  fi
}

test_graph_modules_workspaces() {
  gr_repo "$T/mono"
  gr_put package.json <<'EOF'
{
  "name": "root",
  "private": true,
  "workspaces": [
    "packages/*"
  ],
  "devDependencies": {
    "typescript": "^5.6.0"
  }
}
EOF
  gr_put packages/ui/package.json <<'EOF'
{
  "name": "@acme/ui",
  "dependencies": {
    "@acme/utils": "workspace:*",
    "react": "^18.3.0"
  }
}
EOF
  gr_put packages/utils/package.json <<'EOF'
{
  "name": "@acme/utils",
  "version": "1.0.0",
  "author": {
    "name": "Someone"
  }
}
EOF
  printf '[workspace]\nmembers = ["crates/*"]\n\n[workspace.dependencies]\nshared = { path = "crates/shared" }\nserde = "1"\n' | gr_put Cargo.toml
  gr_put crates/app/Cargo.toml <<'EOF'
[package]
name = "app"

[dependencies]
shared.workspace = true
serde = { workspace = true }
local-util = { path = "../util", package = "util" }

[dev-dependencies]
tempfile = "3"
EOF
  printf '[package]\nname = "shared"\n' | gr_put crates/shared/Cargo.toml
  printf '[package]\nname = "util"\n' | gr_put crates/util/Cargo.toml
  printf 'module example.com/svc\n\nrequire (\n\tgithub.com/google/uuid v1.6.0\n)\n' | gr_put go/go.mod
  printf 'package main\n\nimport (\n\t"net/http"\n\n\t"example.com/svc/internal/api"\n\t"github.com/google/uuid"\n)\n\nfunc main() {}\n' | gr_put go/cmd/server/main.go
  printf 'package api\n\nimport "example.com/svc/internal/db"\n' | gr_put go/internal/api/api.go
  printf 'package db\n' | gr_put go/internal/db/db.go
  printf 'rootProject.name = "shop"\ninclude(":app", ":core:data")\ninclude(":feature-login")\n' | gr_put settings.gradle.kts
  gr_put app/build.gradle.kts <<'EOF'
plugins { id("com.android.application") }

dependencies {
    implementation(project(":core:data"))
    implementation(projects.featureLogin)
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    testImplementation(libs.junit)
}
EOF
  printf 'dependencies {\n    api(libs.kotlinx.coroutines)\n}\n' | gr_put core/data/build.gradle.kts
  printf "dependencies {\n    implementation project(':core:data')\n}\n" | gr_put feature-login/build.gradle
  gr_commit
  gr_json modules
  gr_edge npm:@acme/ui npm:@acme/utils depends
  gr_edge npm:@acme/ui pkg:npm/react depends
  gr_edge npm:root pkg:npm/typescript depends
  gr_node npm:@acme/utils
  gr_attr npm:@acme/ui .workspace .
  gr_attr npm:@acme/utils .label @acme/utils
  gr_edge cargo:app cargo:shared depends
  gr_edge cargo:app cargo:util depends
  gr_edge cargo:app pkg:cargo/serde depends
  gr_edge cargo:app pkg:cargo/tempfile depends
  assert_eq "$(gr_q '.edges[] | select(.source == "cargo:app" and .target == "pkg:cargo/tempfile") | .scope')" "dev-dependencies"
  gr_edge go:example.com/svc/cmd/server go:example.com/svc/internal/api depends
  assert_eq "$(gr_q '.edges[] | select(.source == "go:example.com/svc/cmd/server" and .target == "go:example.com/svc/internal/api") | .evidence[0].file + ":" + (.evidence[0].line|tostring)')" go/cmd/server/main.go:6
  gr_edge go:example.com/svc/internal/api go:example.com/svc/internal/db depends
  gr_edge go:example.com/svc/cmd/server pkg:golang/github.com/google/uuid depends
  gr_no_node pkg:golang/net/http
  gr_edge gradle::app gradle::core:data depends
  gr_edge gradle::app gradle::feature-login depends
  gr_edge gradle::app pkg:maven/com.squareup.retrofit2:retrofit depends
  gr_edge gradle::app pkg:gradle/libs.junit depends
  gr_edge gradle::feature-login gradle::core:data depends
  gr_edge gradle::core:data pkg:gradle/libs.kotlinx.coroutines depends
  assert_eq "$(gr_q '.edges[] | select(.source == "gradle::app" and .target == "pkg:gradle/libs.junit") | .scope')" "testImplementation"
  # 폴더를 주면 그 아래 설정만
  gr_json modules packages
  gr_node npm:@acme/ui
  gr_no_node cargo:app
  gr_no_node npm:root
}

test_graph_changes_cochange() {
  gr_repo "$T/ch"
  for f in a b c d e g; do echo 0 > "$f.txt"; done
  echo '{}' > package.json; echo '{}' > package-lock.json; echo old > old.txt
  gr_commit init
  gch() { local m=$1; shift; for f in "$@"; do echo "$m" >> "$f"; done; git add -A && git commit -q -m "$m"; }
  GIT_COMMITTER_DATE="2020-01-01T00:00:00" gch 1 a.txt b.txt
  GIT_COMMITTER_DATE="2020-01-02T00:00:00" gch 2 a.txt b.txt old.txt
  gch 3 a.txt c.txt old.txt
  gch 4 a.txt b.txt c.txt d.txt e.txt            # --max-files 4 면 빠지는 큰 커밋 (첫 커밋도)
  gch 5 package.json package-lock.json
  gch 6 package.json g.txt
  gch 7 package.json g.txt
  git rm -q old.txt && git commit -q -m "rm old"     # 지운 파일은 추적하지 않으므로 빠진다
  gr_json changes --max-files 4
  assert_eq "$(gr_q '.directed')" "false"
  gr_edge a.txt b.txt cochange
  assert_eq "$(gr_q '.edges[] | select(.source == "a.txt" and .target == "b.txt") | .weight')" "2"
  assert_eq "$(gr_q '.edges[] | select(.source == "a.txt" and .target == "b.txt") | .degree')" "80" "degree = 200*2/(3+2)"
  gr_edge g.txt package.json cochange
  gr_no_edge a.txt c.txt                             # 한 번만 같이 바뀜 (< --min 2)
  gr_no_node old.txt
  gr_no_node package-lock.json
  gr_no_node d.txt
  gr_attr a.txt .changes 3
  gr_attr package.json .changes 3
  gr_attr a.txt .lastChanged "$(date +%Y-%m-%d)"
  assert_eq "$(gr_q '.stats.skippedLargeCommits')" "2"
  assert_eq "$(gr_q '.stats.minCount')" "2"
  gr_json changes --max-files 4 --min 1
  gr_edge a.txt c.txt cochange
  gr_json changes --since 2021-01-01 --max-files 4
  gr_no_edge a.txt b.txt                             # 2020 년 커밋에서만 같이 바뀌었다
  gr_json changes --max-commits 2 --min 1
  assert_eq "$(gr_q '.stats.commits')" "2"
  gr_edge g.txt package.json cochange
  run gitch graph changes --max-commits 1                      # 비면 JSON 은 그대로, 안내는 표준오류로
  assert_ok; assert_out '"nodes": ['; assert_out "같이 바뀐 파일이 없습니다"
  assert_json "$(gitch graph changes --max-commits 1 2>/dev/null)"
  run gitch graph changes --min 0; assert_fail "--min 0 은 거부"
}

test_graph_tree_sizes() {
  gr_repo "$T/tree"
  mkdir -p src/lib/deep docs
  printf '0123456789' > README.md; printf '%0100d' 0 > src/a.ts
  printf 'x' > src/lib/b.ts; printf 'yy' > src/lib/deep/c.ts; printf 'doc' > docs/x.md
  gr_commit
  printf 'new' > src/staged.ts; git add src/staged.ts      # 커밋 전이라도 추적(인덱스)하면 센다
  echo junk > untracked.txt
  gr_json tree
  gr_attr ./ .files 6
  gr_attr ./ .bytes 119
  gr_attr ./ .label tree
  gr_attr src/ .files 4
  gr_attr src/ .filesHere 2
  gr_attr src/ .dirs 1
  gr_attr src/ '.exts.ts' 4
  gr_edge ./ src/ contains
  gr_edge src/lib/ src/lib/deep/ contains
  gr_no_node untracked.txt
  gr_json tree --depth 1
  gr_no_node src/lib/
  gr_attr src/ .files 4
  gr_attr src/ .dirs 1
  gr_json tree --files
  gr_edge src/ src/a.ts contains
  gr_attr src/a.ts .bytes 100
  gr_json tree src
  gr_attr src/ .label src
  gr_no_node ./
  gr_no_node docs/
}

test_graph_formats_and_output() {
  gr_repo "$T/fmt"
  printf 'import x from "</script><b>"\nimport { y } from "./y"\n' | gr_put src/a.ts
  echo 'export const y = 1' | gr_put src/y.ts
  gr_commit
  # 비대화형 기본: json 을 표준출력
  run gitch graph; assert_ok; assert_json "$OUT"
  # html: 오프라인 한 페이지, 데이터 속 </script> 는 끊지 않게
  run gitch graph files --out "$T/out/g.html"; assert_ok
  assert_out "GRAPH_FILE=$T/out/g.html NODES=3 EDGES=2"
  [ -f "$T/out/g.html" ] || fail "html 파일이 없음"
  grep -q '<script id="graph-data" type="application/json">' "$T/out/g.html" || fail "데이터 블록 없음"
  grep -q '"relation": "files"' "$T/out/g.html" || fail "데이터에 관계가 없음"
  for id in panel table legend info q ana banner logo; do grep -q "id=\"$id\"" "$T/out/g.html" || fail "html 에 #$id 가 없음"; done   # 설정 창 · 표로 보기 · 범례 · 정보 · 찾기 · 분석 · 강조 알림 · 표시
  grep -q '<html lang="ko" data-theme="dark">' "$T/out/g.html" || fail "기본은 어두운 화면이어야"
  assert_eq "$(grep -o '</script>' "$T/out/g.html" | wc -l | tr -d ' ')" "3" "데이터 속 </script> 가 그대로 들어감"
  if command -v node >/dev/null 2>&1; then   # 보기 스크립트 문법(브라우저 없이)
    awk '/^<script>$/ { on = 1; next } /^<\/script>$/ { on = 0 } on' "$T/out/g.html" > "$T/out/viewer.js"
    grep -q 'function renderAna' "$T/out/viewer.js" || fail "보기 스크립트를 찾지 못함"
    node --check "$T/out/viewer.js" 2>"$T/out/node.err" || fail "보기 스크립트 문법 오류\n$(cat "$T/out/node.err")"
  fi
  grep -Eq '<(script|link)[^>]+(src|href)=' "$T/out/g.html" && fail "외부 파일(CDN)을 불러옴"
  # The offline report's CSP uses http-equiv, which is metadata rather than a network request.
  grep -Eq 'https?://' "$T/out/g.html" && fail "인터넷 주소가 들어 있음"
  awk '/<script id="graph-data"/ { on = 1; next } /<\/script>/ { on = 0 } on' "$T/out/g.html" > "$T/out/data.json"
  jq -e '.initial == "files" and (.views.files.nodes | length == 3) and (.views | keys == ["changes", "files", "modules", "tree"])' "$T/out/data.json" >/dev/null \
    || fail "html 에 네 관계가 들어 있지 않음\n$(head -c 400 "$T/out/data.json")"
  run gitch graph modules --out "$T/out/m.html"; assert_ok
  grep -q '{"initial":"modules"' "$T/out/m.html" || fail "modules 로 열면 모듈 탭이 처음이어야"
  # 확장자로 형식, --open 은 기본 앱으로
  run gitch graph --out "$T/out/g.json" --open; assert_ok
  assert_json "$(cat "$T/out/g.json")"
  local opened="$T/out/g.json"; [ -n "$IS_WIN" ] && opened=$(cygpath -w "$opened")   # Windows 는 url.dll 에 C:\… 로 넘긴다
  grep -qF "open $opened" "$T/opened" || fail "--open 이 파일을 열지 않음\n$(cat "$T/opened" 2>&1)"
  run gitch graph --format dot; assert_ok; assert_out "digraph gitch {"; assert_out '"src/a.ts" -> "src/y.ts"'
  run gitch graph --format dot --out -; assert_ok; assert_out "digraph"
  run gitch graph --format gif; assert_fail; assert_out "html, json, svg, png, dot"
  run gitch graph --nope; assert_fail; assert_out "사용법: gitch graph"
  run gitch graph "$T/none"; assert_fail; assert_out "폴더가 아닙니다"
  mkdir -p "$T/plain"; run gitch graph "$T/plain"; assert_fail; assert_out "git 저장소 안의 폴더가 아닙니다"
  if command -v dot >/dev/null 2>&1; then
    run gitch graph --out "$T/out/g.svg"; assert_ok
    grep -q '<svg' "$T/out/g.svg" || fail "svg 가 아님"
    run gitch graph modules --format png --out "$T/out/g.png"; assert_ok
    [ "$(head -c 4 "$T/out/g.png" | od -An -c | tr -d ' ')" = '211PNG' ] || fail "png 가 아님"
  else
    run gitch graph --format svg; assert_rc 1
    if [ -n "$IS_WIN" ]; then assert_out "winget install Graphviz.Graphviz"; else assert_out "brew install graphviz"; fi
  fi
}

test_graph_short_name_and_repo_lookup() {
  mk_config
  gr_repo "$HOME/Develop/alice/my-app"
  printf 'import { b } from "./b";\n' | gr_put src/a.ts
  printf 'export const b = 1;\n' | gr_put src/b.ts
  gr_commit
  # g 는 graph 의 짧은 이름
  run gitch g --json; assert_ok; assert_json "$OUT"; assert_eq "$(gr_q .repo)" "my-app" "gitch g"
  gr_edge src/a.ts src/b.ts
  # 저장소 밖에서 이름으로(대소문자 무시) — 계정 폴더 바로 아래
  cd "$T" || fail "cd $T"
  run gitch g my-app --json; assert_ok; assert_eq "$(gr_q .repo)" "my-app" "이름으로"
  run gitch g MY-APP --json; assert_ok; assert_eq "$(gr_q '.nodes | length')" "2" "대소문자 무시"
  # 바로 아래에 없으면 한 단계 더 아래(묶음 폴더)
  gr_repo "$HOME/Develop/corp/team/svc"; printf 'x = 1\n' | gr_put a.py; gr_commit; cd "$T" || fail "cd $T"
  run gitch g svc --json; assert_ok; assert_eq "$(gr_q .repo)" "svc" "한 단계 더 아래"
  # 이름이 겹치면 계정/이름으로 고른다
  gr_repo "$HOME/Develop/alice/dup"; printf 'x = 1\n' | gr_put a.py; gr_commit
  gr_repo "$HOME/Develop/bob/dup"; printf 'y = 1\n' | gr_put b.py; gr_commit; cd "$T" || fail "cd $T"
  run gitch g dup --json; assert_fail; assert_out "여럿입니다"; assert_out "gitch g alice/dup"; assert_out "gitch g bob/dup"
  run gitch g bob/dup --json; assert_ok; assert_eq "$(gr_q '[.nodes[].id] | join(",")')" "b.py" "계정/이름"
  run gitch g nobody/dup --json; assert_fail; assert_out "폴더가 아닙니다: nobody/dup"
  # 없는 이름, 저장소 밖에서 그냥 부르면 계정 폴더의 저장소를 알려 준다
  run gitch g no-such-repo --json; assert_fail; assert_out "저장소 이름도 아닙니다: no-such-repo"; assert_out "my-app"
  mkdir -p "$T/plain2" && cd "$T/plain2" || fail "cd $T/plain2"
  run gitch g --json; assert_fail; assert_out "git 저장소 안의 폴더가 아닙니다"; assert_out "계정 폴더의 저장소: dup, my-app"
  # diff · check 도 [폴더] 자리에 이름 (저장소 밖에서 준 기준은 그 저장소에서 찾는다)
  run gitch g diff HEAD my-app --json; assert_ok; assert_json "$OUT"
  run gitch g diff no-such-commit my-app --json; assert_fail; assert_out "커밋도 폴더도 아닙니다: no-such-commit"
  run gitch g check my-app; assert_fail; assert_out "gitch graph check --init my-app"
}

test_graph_scope_and_worktree_name() {
  gr_repo "$T/scope/myrepo"
  echo 'import { b } from "../lib/b"' | gr_put app/a.ts
  echo 'export const b = 1' | gr_put lib/b.ts
  echo 'export const c = 1' | gr_put lib/c.ts
  gr_commit
  cd app || fail cd
  gr_json files .
  assert_eq "$(gr_q '.scope')" "app"
  gr_edge app/a.ts lib/b.ts import
  gr_attr lib/b.ts .outside true
  gr_no_node lib/c.ts
  cd .. && git worktree add -q "$T/scope/wt" -b side 2>/dev/null || fail "worktree"
  cd "$T/scope/wt" || fail cd
  gr_json tree
  assert_eq "$(gr_q '.repo')" "myrepo" "워크트리여도 본 저장소 이름"
}

test_graph_lang_filter() {
  gr_repo "$T/lang"
  echo 'import { b } from "./b"' | gr_put web/a.ts
  echo 'export const b = 1' | gr_put web/b.ts
  echo 'const x = require("./c")' | gr_put web/legacy.js
  echo 'module.exports = 1' | gr_put web/c.js
  printf 'struct Model {}\n' | gr_put ios/Model.swift
  printf 'let m = Model()\n' | gr_put ios/View.swift
  echo 'import os' | gr_put tools/run.py
  printf '{\n  "name": "web"\n}\n' | gr_put web/package.json
  printf '[package]\nname = "core"\n' | gr_put core/Cargo.toml
  gr_commit
  gr_json --lang swift
  assert_eq "$(gr_q '.lang | join(",")')" "swift"
  assert_eq "$(gr_q '[.nodes[] | select(.kind == "file") | .lang] | unique | join(",")')" "swift"
  gr_edge ios/View.swift ios/Model.swift type-ref
  gr_json --lang web
  assert_eq "$(gr_q '.lang | join(",")')" "ts,js,vue,svelte,astro,html,css,scss,less,mdx"
  gr_edge web/a.ts web/b.ts import
  gr_edge web/legacy.js web/c.js require
  gr_no_node ios/Model.swift
  gr_json files --lang ts,py
  gr_node web/a.ts
  gr_node tools/run.py
  gr_no_node web/legacy.js
  gr_json tree --lang swift
  gr_node ios/
  gr_no_node web/
  gr_attr ./ .files 2
  gr_json modules --lang rust
  gr_node cargo:core
  gr_no_node npm:web
  run gitch graph --lang unknown-language; assert_rc 1; assert_out "--lang 은"
  assert_eq "$(gitch graph --json | jq -r '.lang')" "null" "고르지 않으면 lang 은 null"
}

test_graph_diff() {
  gr_repo "$T/diff"
  echo 'import { b } from "./b"' | gr_put src/a.ts
  echo 'export const b = 1' | gr_put src/b.ts
  echo 'export const c = 1' | gr_put src/c.ts
  printf 'import { y } from "./y"\nexport const x = 1\n' | gr_put src/x.ts      # x ↔ y 순환 — 작업 트리에서 z 가 끼어 커진다
  printf 'import { x } from "./x"\nexport const y = 1\n' | gr_put src/y.ts
  gr_commit base
  local base; base=$(git rev-parse --short HEAD)
  # 작업 트리: a → b 를 a → c 로, b ↔ c 순환, 새 파일 d (커밋 없이 추적만)
  echo 'import { c } from "./c"' | gr_put src/a.ts
  printf 'import { c } from "./c"\nexport const b = 1\n' | gr_put src/b.ts
  printf 'import { b } from "./b"\nexport const c = 1\n' | gr_put src/c.ts
  echo 'import { a } from "./a"' | gr_put src/d.ts
  printf 'import { z } from "./z"\nexport const y = 1\n' | gr_put src/y.ts
  printf 'import { x } from "./x"\nexport const z = 1\n' | gr_put src/z.ts
  git add -A
  run gitch graph diff "$base" --json; assert_ok; assert_json "$OUT"
  assert_eq "$(gr_q '.diff.base + " " + .diff.head')" "$base worktree"
  assert_eq "$(gr_q '[.stats.addedEdges, .stats.removedEdges, .stats.addedNodes, .stats.removedNodes, .stats.newCycles, .stats.changedCycles, .stats.goneCycles] | map(tostring) | join(" ")')" "6 2 2 0 1 1 0"
  assert_eq "$(gr_q '.cycles.new[0].nodes | join(",")')" "src/b.ts,src/c.ts" "새 순환"
  assert_eq "$(gr_q '.cycles.changed[0] | (.before | join(",")) + " > " + (.nodes | join(","))')" "src/x.ts,src/y.ts > src/x.ts,src/y.ts,src/z.ts" "커진 순환은 새 순환이 아니다"
  assert_eq "$(gr_q '[.edges[] | select(.status == "removed") | .source + ">" + .target] | sort | join(" ")')" "src/a.ts>src/b.ts src/y.ts>src/x.ts"
  assert_eq "$(gr_q '[.edges[] | select(.status == "added")] | length')" "6"
  assert_eq "$(gr_q '[.nodes[] | select(.status == "added") | .id] | sort | join(",")')" "src/d.ts,src/z.ts"
  # 기준을 주지 않으면 기본 브랜치(여기서는 로컬 main)와 갈라진 곳
  run gitch graph diff --json; assert_ok
  assert_eq "$(gr_q '.diff.baseName + " " + .diff.base')" "main $base"
  # 기준... 은 그 기준과 갈라진 곳 — 기준 브랜치가 앞서 나가도 갈라진 곳과 비교하고, 이름은 기준 그대로(앱의 「다른 기준과 비교…」)
  git update-ref refs/heads/ahead "$(git commit-tree "HEAD^{tree}" -p HEAD -m ahead)"
  run gitch graph diff --base ahead... --json; assert_ok
  assert_eq "$(gr_q '.diff.baseName + " " + .diff.base')" "ahead $base"
  run gitch graph diff --base ahead --json; assert_ok
  assert_eq "$(gr_q '.diff.base')" "$(git rev-parse --short ahead)" "... 없이는 기준 그대로"
  run gitch graph diff --base no-such... --json; assert_fail; assert_out "커밋이 아닙니다: no-such"
  git update-ref refs/heads/alone "$(git commit-tree "$(git mktree < /dev/null)" -m alone)"
  run gitch graph diff --base alone... --json; assert_fail; assert_out "alone 와(과) 이 브랜치에는 공통 커밋이 없습니다"
  # 사람용 요약 · html(바뀐 것을 색으로) · 폴더 구조
  run gitch graph diff "$base" --format text; assert_ok
  assert_out "연결 +6 −2"; assert_out "새 순환 1개"; assert_out "커지거나 줄어든 순환 1개"; assert_out "~ 2 → 3개"; assert_out "+ src/z.ts"
  assert_out "+ src/d.ts → src/a.ts"; assert_out "− src/a.ts → src/b.ts"
  run gitch graph diff "$base" --out "$T/out/d.html"; assert_ok
  grep -q '"status":"removed"' "$T/out/d.html" || fail "html 에 바뀐 표시가 없음"
  grep -q '"diff": {"base": "'"$base"'"' "$T/out/d.html" || fail "html 에 기준이 없음"
  run gitch graph diff "$base" tree --json; assert_ok
  assert_eq "$(gr_q '.nodes[] | select(.id == "src/") | "\(.status) \(.filesDelta)"')" "changed 2" "폴더의 파일 수 변화"
  run gitch graph diff "$base" tree --format text; assert_ok; assert_out "~ src/ 파일 +2"
  run gitch graph diff changes; assert_fail; assert_out "changes 는 비교하지 않습니다"
  run gitch graph diff no-such-commit; assert_fail; assert_out "커밋도 폴더도 아닙니다"
  run gitch graph diff --help; assert_ok; assert_out "사용법: gitch graph diff"
}

test_graph_check() {
  gr_repo "$T/check"
  echo 'import { db } from "../db/db"' | gr_put src/ui/view.ts
  echo 'import { db } from "../../db/db"' | gr_put src/ui/debug/tool.ts
  echo 'export const db = 1' | gr_put src/db/db.ts
  printf 'import { y } from "./y"\nexport const x = 1\n' | gr_put src/core/x.ts
  printf 'import { x } from "./x"\nexport const y = 1\n' | gr_put src/core/y.ts
  gr_commit
  run gitch graph check; assert_fail; assert_out "gitch graph check --init"
  run gitch graph check --init; assert_ok
  [ -f .gitch/graph.rules ] || fail "--init 이 규칙 파일을 만들지 않음"
  run gitch graph check --init; assert_fail; assert_out "이미 있습니다"
  run gitch graph check --format text; assert_ok; assert_out "위반 없음"     # 예시는 모두 주석
  cat > .gitch/graph.rules <<'RULES'
# 화면은 DB 를 바로 쓰지 않는다
[files]
forbid  src/ui -> src/db
allow   src/ui/debug -> src/db    # 예외
no-cycles src/**
layers  src/ui > src/core > src/db
RULES
  run gitch graph check --format text; assert_rc 1
  assert_out "src/ui/view.ts → src/db/db.ts"; assert_out "순환 src/core/x.ts · src/core/y.ts"; assert_out "위반 2개"
  case "$OUT" in *tool.ts*) fail "allow 예외가 먹지 않음\n$OUT" ;; esac
  run gitch graph check --json; assert_rc 1; assert_json "$OUT"
  assert_eq "$(gr_q '.ok')" "false"
  assert_eq "$(gr_q '[.violations[].kind] | sort | join(",")')" "forbid,no-cycles"
  assert_eq "$(gr_q '.violations[] | select(.kind == "no-cycles") | .nodes | join(",")')" "src/core/x.ts,src/core/y.ts"
  assert_eq "$(gr_q '.violations[] | select(.kind == "forbid") | "\(.line) \(.rule)"')" "3 forbid  src/ui -> src/db"
  # --base: 기준에도 있던 위반은 「기존」, 새 위반만 실패
  gr_commit rules
  local base; base=$(git rev-parse --short HEAD)
  echo 'import { x } from "../core/x"' | gr_put src/db/up.ts      # db → core: 층을 거스른다
  git add -A
  run gitch graph check --base "$base" --json; assert_rc 1
  assert_eq "$(gr_q '[.violations[] | select(.existing)] | length')" "2" "기준에도 있던 위반"
  assert_eq "$(gr_q '.violations[] | select(.existing | not) | "\(.kind) \(.source) \(.target)"')" "layers src/db/up.ts src/core/x.ts"
  git rm -q --cached src/db/up.ts && rm src/db/up.ts
  run gitch graph check --base "$base" --format text; assert_ok "기존 위반만 있으면 통과"; assert_out "기준에도 있던 위반 2개"
  # html 에 규칙 결과, 그냥 gitch graph html 에도 (규칙 파일이 있으면)
  run gitch graph check --out "$T/out/c.html"; assert_rc 1
  awk '/^<script id="graph-data"/ { active=1; next } active && /^<\/script>/ { exit } active { print }' "$T/out/c.html" | jq -e '.rules.tool == "gitch graph check" and (.rules.violations|type == "array")' >/dev/null || fail "check html 에 규칙 결과가 없음"
  run gitch graph files --out "$T/out/g.html"; assert_ok
  awk '/^<script id="graph-data"/ { active=1; next } active && /^<\/script>/ { exit } active { print }' "$T/out/g.html" | jq -e '.rules.tool == "gitch graph check" and .rules.file == ".gitch/graph.rules"' >/dev/null || fail "graph html 에 규칙 결과가 없음"
  # 틀린 규칙은 줄 번호와 함께 멈춘다
  printf '[files]\nforbid src/a\nlayers only\nfrobid a -> b\n[nope]\n' > "$T/bad.rules"
  run gitch graph check --rules "$T/bad.rules"; assert_fail
  assert_out "2번 줄: forbid 에는"; assert_out "3번 줄: layers 에는"; assert_out "4번 줄: 모르는 규칙"; assert_out "5번 줄: 모르는 절 [nope]"
}

test_graph_check_modules() {
  gr_repo "$T/checkmod"
  echo 'let project = Project.framework(name: "AFeature", dependencies: [.project(target: "BFeature", path: "../B"), .project(target: "Domain", path: "../Domain")])' | gr_put Projects/A/Project.swift
  echo 'let project = Project.framework(name: "BFeature", dependencies: [.project(target: "Domain", path: "../Domain")])' | gr_put Projects/B/Project.swift
  echo 'let project = Project.framework(name: "Domain", dependencies: [.project(target: "AFeature", path: "../A")])' | gr_put Projects/Domain/Project.swift
  mkdir -p .gitch
  printf '[modules]\nforbid *Feature -> *Feature   # 기능끼리\nlayers *Feature > Domain\n' > .gitch/graph.rules
  gr_commit
  run gitch graph check --json; assert_rc 1; assert_json "$OUT"
  assert_eq "$(gr_q '[.violations[] | "\(.kind) \(.source) \(.target)"] | sort | join(" | ")')" "forbid tuist:AFeature tuist:BFeature | layers tuist:Domain tuist:AFeature"
}

gr_chrome() {   # 시험에 쓸 Chrome — GITCH_TEST_CHROME 이 먼저, 없으면 실패(그 시험은 건너뛴다)
  local c
  for c in "${GITCH_TEST_CHROME:-}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$(command -v google-chrome 2>/dev/null)" "$(command -v chromium 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

test_graph_html_in_browser() {   # 헤드리스 Chrome 에서: 오류 없이 그리고, 배치 · 그리기마다 겹친 노드가 없고, PNG 로 저장된다 (Chrome · Node 22 가 없으면 건너뜀)
  local chrome
  chrome=$(gr_chrome) || return 0
  node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null || return 0
  gr_repo "$T/browser"
  printf '{"name":"root","workspaces":["packages/*"]}\n' | gr_put package.json
  printf '{"name":"@x/a","dependencies":{"@x/b":"1"}}\n' | gr_put packages/a/package.json
  printf '{"name":"@x/b"}\n' | gr_put packages/b/package.json
  echo 'export class Legacy {}' | gr_put packages/a/src/legacy.js
  echo '<project><groupId>com.example</groupId><artifactId>java-app</artifactId></project>' | gr_put java/pom.xml
  echo 'public class App {}' | gr_put java/App.java
  printf '[project]\nname = "python-app"\ndependencies = ["requests"]\n' | gr_put python/pyproject.toml
  echo 'class App: pass' | gr_put python/app.py
  echo '<Project Sdk="Microsoft.NET.Sdk" />' | gr_put dotnet/App.csproj
  echo 'class App {}' | gr_put dotnet/App.cs
  echo '{"name":"example/php-app"}' | gr_put php/composer.json
  echo '<?php class App {}' | gr_put php/app.php
  echo 'FROM scratch' | gr_put deploy/Dockerfile
  printf 'import "./logo.png";\nimport "./asset.constructor";\nimport "./asset.toString";\nexport const assets = true;\n' | gr_put packages/a/src/assets.ts
  printf 'fixture image\n' | gr_put packages/a/src/logo.png
  printf 'fixture asset\n' | gr_put packages/a/src/asset.constructor
  printf 'fixture asset\n' | gr_put packages/a/src/asset.toString
  local i
  for i in 1 2 3 4 5 6 7 8; do printf 'import { v%s } from "./f%s"\nexport const v%s = 1\n' $(( i % 8 + 1 )) $(( i % 8 + 1 )) "$i" | gr_put "packages/a/src/f$i.ts"; done
  printf 'import "../src/f1";\nimport "../src/f2";\n' | gr_put packages/a/tests/review.test.ts
  echo 'struct Caller { let value: Value }' | gr_put swift/Caller.swift
  echo 'struct Value {}' | gr_put swift/Value.swift
  echo 'export const special=1;' | gr_put "한글 space ' <b>&.ts"
  echo 'export const removed=1;' | gr_put removed/history/only.ts
  echo 'export const readable=1;' | gr_put 'packages/a/src/nested/long file name that stays readable in the changed file list.ts'
  echo 'export const sibling=1;' | gr_put packages/a/src2/sibling.ts
  for i in $(seq -w 1 125); do printf 'folder fixture\n' | gr_put "archive/folder-$i/readme.txt"; done
  printf '[files]\nforbid packages/a/src/f1.ts -> packages/a/src/f2.ts\nforbid packages/a/src/f2.ts -> packages/a/src/f1.ts\n' | gr_put .gitch/graph.rules
  gr_commit one
  for i in 2 3; do echo "// $i" >> packages/a/src/f1.ts; echo "// $i" >> packages/a/src/f2.ts; gr_commit "c$i"; done   # 같이 바뀌는 쌍
  echo '// pending body change' >> packages/a/src/f1.ts
  echo '// pending body change' >> packages/a/src/f2.ts
  echo 'import "./f1";' >> packages/a/src/f2.ts
  echo '// pending' >> swift/Value.swift
  echo '// pending' >> dotnet/App.cs
  echo '// pending' >> "한글 space ' <b>&.ts"
  echo '// pending' >> 'packages/a/src/nested/long file name that stays readable in the changed file list.ts'
  echo '// pending' >> packages/a/src2/sibling.ts
  git rm -q removed/history/only.ts
  git mv packages/a/src/legacy.js 'packages/a/src/legacy moved.js'
  run gitch graph files --out "$T/out/browser.html"; assert_ok
  run node "$ROOT/tests/graph_browser.mjs" "$chrome" "$T/out/browser.html" "$T"
  assert_ok "브라우저에서 확인 실패"
  assert_out '"ok":true'
}

test_graph_files_more_languages() {
  gr_repo "$T/multilang"
  printf '#include "model.h"\n#include <stdio.h>\n// #include "fake.h"\n' | gr_put native/main.c
  echo 'struct Model {};' | gr_put native/model.h
  printf '#include "model.hpp"\n' | gr_put native/main.cpp
  echo 'class Model {};' | gr_put native/model.hpp
  printf 'require_relative "model"\nrequire "json"\n' | gr_put ruby/main.rb
  echo 'class Model; end' | gr_put ruby/model.rb
  printf 'include "model.php";\n' | gr_put php/main.php
  echo '<?php class Model {}' | gr_put php/model.php
  printf 'import "model.dart";\n' | gr_put dart/main.dart
  echo 'class Model {}' | gr_put dart/model.dart
  printf 'syntax = "proto3";\nimport "model.proto";\n' | gr_put proto/main.proto
  echo 'syntax = "proto3";' | gr_put proto/model.proto
  printf '@use "tokens";\n' | gr_put styles/main.scss
  echo '$color: red;' | gr_put styles/_tokens.scss
  local f
  for f in app.cs app.fs app.vb app.scala app.groovy app.lua app.sh app.ps1 app.pl app.R app.jl app.ex app.erl app.hs app.clj app.ml app.elm app.nim app.zig app.d app.f90 app.pas app.adb app.cob app.lisp app.scm app.rkt app.sql app.graphql app.sol app.move app.vy app.cr app.html app.css app.yaml app.tf app.sv app.vhd app.asm app.tcl app.awk; do echo '// example' | gr_put "other/$f"; done
  echo 'FROM scratch' | gr_put Dockerfile
  echo 'all:' | gr_put Makefile
  gr_commit
  gr_json files
  gr_edge native/main.c native/model.h include
  gr_edge native/main.c pkg:system/stdio.h include
  gr_no_node pkg:system/fake.h
  gr_edge native/main.cpp native/model.hpp include
  gr_edge ruby/main.rb ruby/model.rb require
  gr_edge ruby/main.rb pkg:gem/json require
  gr_edge php/main.php php/model.php include
  gr_edge dart/main.dart dart/model.dart import
  gr_edge proto/main.proto proto/model.proto import
  gr_edge styles/main.scss styles/_tokens.scss import
  gr_attr other/app.cs .lang csharp
  gr_attr other/app.R .lang r
  gr_attr other/app.cob .lang cobol
  gr_attr Dockerfile .lang docker
  gr_attr Makefile .lang make
  assert_eq "$(gr_q '[.nodes[] | select(.kind == "file")] | length')" "58"
  gr_json files --lang 'C++,C#,py,cobol'
  assert_eq "$(gr_q '.lang | join(",")')" "cpp,csharp,python,cobol"
  gr_node native/main.cpp
  gr_node other/app.cs
  gr_node other/app.cob
  gr_no_node native/main.c
}

test_graph_modules_maven() {
  gr_repo "$T/maven"
  gr_put pom.xml <<'EOF_POM'
<project><modelVersion>4.0.0</modelVersion><groupId>com.example</groupId><artifactId>root</artifactId><version>1</version><packaging>pom</packaging><modules><module>app</module><module>core</module></modules></project>
EOF_POM
  gr_put app/pom.xml <<'EOF_POM'
<project>
  <parent><groupId>com.example</groupId><artifactId>root</artifactId><version>1</version></parent>
  <artifactId>app</artifactId>
  <properties><lib.group>org.example</lib.group></properties>
  <dependencyManagement><dependencies><dependency><groupId>ignored</groupId><artifactId>managed</artifactId></dependency></dependencies></dependencyManagement>
  <!-- <dependencies><dependency><groupId>fake</groupId><artifactId>comment</artifactId></dependency></dependencies> -->
  <dependencies>
    <dependency><groupId>${project.groupId}</groupId><artifactId>core</artifactId></dependency>
    <dependency><groupId>${lib.group}</groupId><artifactId>testing</artifactId><scope>test</scope></dependency>
  </dependencies>
  <build><plugins><plugin><artifactId>plugin</artifactId><dependencies><dependency><groupId>ignored</groupId><artifactId>plugin-dep</artifactId></dependency></dependencies></plugin></plugins></build>
</project>
EOF_POM
  echo '<project><groupId>com.example</groupId><artifactId>core</artifactId></project>' | gr_put core/pom.xml
  gr_commit
  gr_json modules --lang java
  gr_node maven:com.example:root
  gr_edge maven:com.example:app maven:com.example:core depends
  gr_edge maven:com.example:app pkg:maven/org.example:testing depends
  gr_no_node pkg:maven/ignored:managed
  gr_no_node pkg:maven/ignored:plugin-dep
  gr_no_node pkg:maven/fake:comment
  gr_json modules --no-external app
  gr_edge maven:com.example:app maven:com.example:core depends
  gr_attr maven:com.example:core .outside true
  gr_no_node maven:com.example:root
  gr_no_node pkg:maven/org.example:testing
}

test_graph_modules_python() {
  gr_repo "$T/python-modules"
  gr_put app/pyproject.toml <<'EOF_PY'
[project]
name = "demo-app"
dependencies = [
  "demo_core>=1",
  "fastapi[standard]>=0.100",
  "requests>=2; python_version >= '3.10'",
]
[project.optional-dependencies]
test = ["pytest>=8"]
[dependency-groups]
dev = ["ruff"]
[build-system]
requires = ["setuptools"]
EOF_PY
  gr_put core/pyproject.toml <<'EOF_PY'
[tool.poetry]
name = "demo-core"
[tool.poetry.dependencies]
python = "^3.12"
pydantic = "^2"
[tool.poetry.group.test.dependencies]
pytest = "^8"
EOF_PY
  printf 'numpy>=2\n-r requirements-base.txt\n' | gr_put app/requirements.txt
  printf 'packaging>=24\n' | gr_put app/requirements-base.txt
  gr_commit
  gr_json modules --lang python
  gr_edge pypi:demo-app pypi:demo-core depends
  gr_edge pypi:demo-app pkg:pypi/requests depends
  gr_edge pypi:demo-app pkg:pypi/fastapi depends
  gr_edge pypi:demo-app pkg:pypi/pytest depends
  gr_edge pypi:demo-app pkg:pypi/ruff depends
  gr_edge pypi:demo-app pkg:pypi/numpy depends
  gr_edge pypi:demo-app pkg:pypi/packaging depends
  gr_edge pypi:demo-core pkg:pypi/pydantic depends
  gr_no_node pkg:pypi/setuptools
  gr_no_node pkg:pypi/python
  gr_no_node pkg:pypi/3-10
  gr_json modules --lang python --no-external
  assert_eq "$(gr_q '.nodes | length')" "2"
  gr_edge pypi:demo-app pypi:demo-core depends
}

test_graph_modules_dotnet() {
  gr_repo "$T/dotnet"
  gr_put app/App.csproj <<'EOF_CS'
<Project Sdk="Microsoft.NET.Sdk"><ItemGroup>
<!-- <PackageReference Include="Fake" /> -->
<ProjectReference
  Include="..\core\Core.fsproj" />
<PackageReference Include="Example.Json" Version="1" />
<PackageReference Update="Only.Version" Version="2" />
</ItemGroup></Project>
EOF_CS
  echo '<Project Sdk="Microsoft.NET.Sdk" />' | gr_put core/Core.fsproj
  gr_commit
  gr_json modules --lang csharp
  gr_edge dotnet:app/App.csproj dotnet:core/Core.fsproj depends
  gr_edge dotnet:app/App.csproj pkg:nuget/Example.Json depends
  gr_no_node pkg:nuget/Fake
  gr_no_node pkg:nuget/Only.Version
  gr_json modules --no-external app
  gr_edge dotnet:app/App.csproj dotnet:core/Core.fsproj depends
  gr_attr dotnet:core/Core.fsproj .outside true
}

test_graph_modules_composer_bundler_pub_cmake() {
  gr_repo "$T/other-modules"
  echo '{"name":"example/app","require":{"php":"^8","ext-json":"*","example/core":"*","psr/log":"^3"},"require-dev":{"phpunit/phpunit":"^11"}}' | gr_put php/app/composer.json
  printf '{\n "name":\n "example/core"\n}\n' | gr_put php/core/composer.json
  printf 'source "https://example.com"\ngem "rails"\n# gem "fake"\n' | gr_put ruby/Gemfile
  printf 'name: demo_app\ndependencies:\n  demo_core:\n    path: ../core\n  http: ^1.0\ndev_dependencies:\n  test: ^1.0\n' | gr_put dart/app/pubspec.yaml
  printf 'name: demo_core\n' | gr_put dart/core/pubspec.yaml
  printf 'project(Demo)\nadd_executable(app main.cpp)\nadd_subdirectory(core)\ntarget_link_libraries(app PRIVATE core Threads::Threads)\n' | gr_put native/CMakeLists.txt
  printf 'add_library(core core.cpp)\n' | gr_put native/core/CMakeLists.txt
  gr_commit
  gr_json modules
  gr_edge composer:example/app composer:example/core depends
  gr_edge composer:example/app pkg:composer/psr/log depends
  gr_edge composer:example/app pkg:composer/phpunit/phpunit depends
  gr_no_node pkg:composer/php
  gr_no_node pkg:composer/ext-json
  gr_edge gem:ruby pkg:gem/rails depends
  gr_no_node pkg:gem/fake
  gr_edge pub:demo_app pub:demo_core depends
  gr_edge pub:demo_app pkg:pub/http depends
  gr_edge cmake:app cmake:core depends
  gr_edge cmake:app pkg:cmake/Threads::Threads depends
  gr_json modules --lang php --no-external
  gr_edge composer:example/app composer:example/core depends
  gr_no_node cmake:app
  gr_json modules --lang cpp
  gr_edge cmake:app cmake:core depends
  gr_no_node composer:example/app
}

test_graph_modules_standalone_gradle_and_npm_json() {
  gr_repo "$T/standalone-modules"
  printf 'plugins { java }\ndependencies {\n  implementation("org.example:core:1.0")\n}\n' | gr_put jvm/build.gradle.kts
  gr_put web/package.json <<'EOF_JSON'
{
  "name":
    "web",
  "workspaces": {"packages": ["packages/*"]},
  "dependencies": {"@example/core": "workspace:*"}
}
EOF_JSON
  echo '{"name":"@example/core"}' | gr_put web/packages/core/package.json
  gr_commit
  gr_json modules --lang java
  gr_edge gradle:jvm: pkg:maven/org.example:core depends
  gr_json modules --lang ts
  gr_edge npm:web npm:@example/core depends
  gr_attr npm:@example/core .workspace web
}

test_graph_modules_python_requirements_and_legacy() {
  gr_repo "$T/requirements"
  printf '[project]\nname = "demo-app"\n' | gr_put app/pyproject.toml
  printf -- '-r base.txt\npytest==8.0\n' | gr_put app/requirements/dev.txt
  printf -- '-r common.txt\nrequests>=2\n' | gr_put app/requirements/base.txt
  printf -- '-r dev.txt\npackaging>=24\n' | gr_put app/requirements/common.txt
  printf '[metadata]\nname = legacy\n[options]\ninstall_requires = click>=8\n  numpy==2.0\n' | gr_put legacy/setup.cfg
  printf '[packages]\n"Django" = "*"\n[dev-packages]\npytest = "*"\n' | gr_put pip/Pipfile
  gr_commit
  gr_json modules --lang python
  gr_edge pypi:demo-app pkg:pypi/requests depends
  gr_edge pypi:demo-app pkg:pypi/pytest depends
  gr_edge pypi:demo-app pkg:pypi/packaging depends
  gr_no_node pypi:app/requirements
  gr_edge pypi:legacy pkg:pypi/click depends
  gr_edge pypi:legacy pkg:pypi/numpy depends
  gr_edge pypi:pip pkg:pypi/django depends
  gr_edge pypi:pip pkg:pypi/pytest depends
  assert_eq "$(gr_q '[.edges[] | select(.source == "pypi:demo-app" and .target == "pkg:pypi/requests") | .weight] | add')" "1"
}
