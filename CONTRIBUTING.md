# 기여 안내

Gitrochi 에 관심 가져 주셔서 고맙습니다. 버그 제보·기능 요청은 [이슈](https://github.com/Gitrochi/Gitrochi/issues/new/choose)로, 코드는 PR 로 보내 주세요.

> **English** — Issues and PRs are welcome in English too. UI text in the code is English (translated into 20 languages), **commit messages are English** (`Area: Imperative summary`), and code comments are in Korean. Run `git config core.hooksPath .githooks` once — the hooks check the Git rules below, and so does CI.

## 기여자

- [조문성 (ChoMnSeong)](https://github.com/ChoMnSeong)
- [jjunhaa0211](https://github.com/jjunhaa0211) — gitch CLI, 다중 언어 구조 분석, 앱 연동 및 검증 개선

기존 저작권자 표기는 [LICENSE](LICENSE)와 [기존 MIT 전문](LICENSE-MIT)에 보존합니다. 확인된 라이선스 문의 연락처는 조문성(ChoMnSeong) <mailto:chemins60217@gmail.com>, jjunhaa0211 <mailto:goodjunha@gmail.com>입니다. 연락처가 제공되었다는 사실만으로 모든 기여물의 권리나 라이선스 변경 동의가 확인된 것은 아닙니다.

## 사용·배포와 공식 기여 경로

**현재 상태: Gitrochi Community Use License v1.0과 CLA v1.0은 제안 단계이며 아직 발효되지 않았습니다.** [전환 검토 기록](docs/licensing-review.md)의 권리자·동의·적용 범위를 확인하고 채택 기록을 완료하기 전에는 기존 MIT 허락이 유지됩니다. 아래 새 정책과 CLA 절차는 그 채택 이후 확인된 적용 자료에 사용하는 제안입니다. 과거 기여자가 자동으로 동의한 것으로 처리하지 않습니다.

- 개인·기업 모두 설치·실행과 내부 업무 사용이 무료입니다. 상업 업무의 일반 결과물에 Gitrochi 라이선스가 전파되지 않습니다.
- 개인 또는 조직 내부에서 비공개 수정·빌드를 할 수 있으며, 사용하거나 내부 수정했다는 이유만으로 코드 공개나 PR을 요구하지 않습니다.
- 새 정책이 적용되는 Gitrochi 자체의 무단 재판매·유료 재포장과 독립 파생 프로젝트의 외부 배포는 제한합니다. 무료 파생 배포도 해당하며, 기존 MIT·제삼자 라이선스·법률·GitHub 약관에서 별도로 허용한 권리는 유지합니다.
- 변경 없는 공식 배포본의 무료 공유는 LICENSE의 고지 보존 조건을 따릅니다. 새 정책은 OSI 승인 오픈소스 라이선스가 아닌 **source-available** 정책입니다.
- 프로젝트에 제출하는 코드·문서는 반드시 [공식 저장소 PR](https://github.com/Gitrochi/Gitrochi/pulls)로 보냅니다. 기여 포크·브랜치와 검토용 패치를 허용하며, 이를 독립 제품 배포 허가로 해석하지 않습니다. GitHub 약관상 열람·포크 권리는 PR 제출 여부와 관계없이 유지됩니다.
- 재판매·외부 배포 예외는 두 라이선스 문의 연락처로 요청합니다. 해당 자료에 권한이 있는 권리자의 서면 승인이 필요하며 침묵이나 저장소 관리 권한을 승인으로 보지 않습니다.

정확한 적용 범위와 조건은 [LICENSE](LICENSE)를 따릅니다. 버그·기능 요청과 보안 신고는 기존 이슈·[보안 신고](SECURITY.md) 경로를 사용하며, 신고 자체에 CLA를 요구하지 않습니다. 코드·문서 패치를 제출하면 적용 대상 기여 절차를 따릅니다.

## 기여자 CLA 명시 동의

[CLA.md](CLA.md)는 소유권을 기여자에게 남겨 두고, 식별된 원본 기여물에 대해 공식 Gitrochi 프로젝트가 v1.0 조건으로 사용할 수 있는 비독점 권한을 받는 제안입니다. 모든 미래 라이선스에 포괄 동의시키거나 저작권을 양도받는 문서가 아닙니다. **CLA 수익자의 법적 신원·권한과 비공개 확인 절차를 확정하기 전에는 동의를 수집하거나 유효한 합의라고 처리하지 않습니다.**

채택 후에는 아래 절차를 병합 전에 관리자가 수동 확인합니다. 현재 자동 CLA 봇·필수 검사는 없습니다.

1. 각 기여 권리자 또는 그 권한 있는 대리인이 승인된 CLA v1.0 전문을 읽습니다. 승인된 문서의 커밋 SHA가 들어간 불변 링크를 사용합니다.
2. PR URL과 본인의 기여를 포함한 전체 커밋 SHA 또는 명시적인 SHA 범위를 정해 [CLA.md의 동의문](CLA.md#5-express-assent-and-records)을 **본인의 계정으로 PR 댓글에 직접** 남깁니다. PR 제출·체크박스·커밋 sign-off만으로 별도 CLA 동의를 간주하지 않습니다.
3. 공동 작성자가 있으면 각 권리자의 동의를 확인합니다. 고용주나 다른 법인이 권리를 가지면 권한을 확인한 대리인이 동의해야 합니다. 제삼자 코드는 출처·라이선스·변경 여부를 PR에 밝히고 고지를 유지하며 CLA로 덮지 않습니다.
4. 관리자는 동의 댓글 영구 링크, CLA 버전·불변 링크, 대상 SHA, 권리자별 검증 결과를 PR 기록에 남깁니다. 확인되지 않은 기여물은 병합하지 않습니다.
5. 이후 커밋·작성자·약관이 바뀌면 해당 범위에 대한 동의를 새로 받습니다. 민감한 신원·고용 자료를 공개 PR에 쓰지 말고, 확정된 비공개 절차를 라이선스 연락처에 문의합니다.

CLA 동의를 임의로 대신 작성하거나 체크하지 마세요. 이 제안 PR에 포함된 체크리스트도 기존 권리자의 전환 승인이나 CLA 서명을 대신하지 않습니다.

## 시작하기

| | 맥 | Windows |
|---|---|---|
| 위치 | `macos/` (SwiftUI, macOS 15+) | `windows/` (Tauri 2: Rust + React/TypeScript) |
| 필요 | Swift 6 이상(Xcode 또는 Command Line Tools) | Node.js 22, Rust stable |
| 빌드 | `macos/build.sh` | `cd windows && npm ci && npx tauri build` |
| 확인 | 빌드 오류·경고 없이 | `npx tsc --noEmit -p .` · `npx vitest run` · `cargo check` |

- 받은 뒤 한 번 `git config core.hooksPath .githooks` — 커밋할 때 [Git 규칙](#git-규칙)을 검사합니다.
- 맥은 SwiftPM 없이 `swiftc` 로 바로 빌드합니다. 새 파일은 `macos/Sources/` 아래 알맞은 폴더에 두면 자동으로 포함됩니다.
- 맥 앱에 함께 들어가는 [gitch](tools/gitch/README.md)(bash 3.2 + git)를 고쳤으면 `tools/gitch/tests/run.sh` 로 확인합니다(3분쯤, 실제 설정은 건드리지 않음).
- 정밀 참조·자동 갱신 도우미를 고쳤으면 `python3 tools/gitch/tests/test_scip.py`와 `python3 tools/gitch/tests/test_watch.py`도 실행합니다. 앱 URL 이동은 `bash macos/Tools/test-app-route.sh`로 검증합니다. CI는 JSON Schema 계약도 검증합니다(테스트 의존성 `jsonschema==4.25.1`; 제품 도우미는 Python 표준 라이브러리만 사용).
- 앱과 gitch는 같은 릴리스 버전을 씁니다. `bash tools/check-versions.sh`로 macOS · Windows · CLI 버전을 한 번에 확인합니다(맥 빌드와 CI에서도 검사).
- gitch 옆에 들어가는 Xcode 인덱스 도우미 [gitch-swift-index](tools/gitch-swift-index/README.md)(Swift)를 고쳤으면 `tools/gitch-swift-index/tests/run.sh` 로 확인합니다(30초쯤, 예제를 `swift build` 해서 읽음).
- Windows 는 맥에서도 `npx tauri dev` 로 띄워 볼 수 있습니다(데이터 폴더는 `Gitrochi (Tauri)` 로 분리).
- 화면을 바꿨다면 [데모 저장소](docs/make-demo-repo.sh)(`docs/make-demo-repo.sh <폴더>`)로 확인하고 스크린샷을 PR 에 붙여 주세요.

## 구조

```
macos/Sources/
  App/       앱·창·탭·업데이트·테마
  Core/      git 실행(Git.swift), 출력 해석(Parsers), 그래프 배치(Graph), 모델, 파일 감시
  Store/     RepoStore(탭 하나의 상태) + 기능별 확장 RepoStore+Actions·+Selection·+CI …
  Services/  GitHub·GitLab(Hosting), CI/CD, AI, 계정, 에이전트, 도구, 프로필 사진, 터미널 세션
  Views/     Graph · Sidebar · Inspector · Settings · Sheets · Shared
windows/src/            Feature-Sliced Design — 위 계층이 아래 계층만 가져온다
  app/       시작(main·start)·탭 껍데기·단축키·전역 스타일·자동 점검(selftest)
  pages/     repo(저장소 화면) · welcome(시작 화면)
  widgets/   commit-graph · diff-viewer · inspector · sidebar · toolbar · tab-bar · terminal-panel · settings · dialog-host · update-dialog
  features/  사용자 동작 하나씩: create-branch · create-tag · stash-changes · clone-repo · add-worktree · create-pull-request ·
             interactive-rebase · split-commits · resolve-conflict · run-pipeline · start-agent · git-menus(우클릭 메뉴)
  entities/  git(모델·파서·그래프·diff) · repo(RepoStore) · hosting · ci · ai · agent · terminal · avatar · workspace
  shared/    api(ipc) · config(env·settings) · platform(git 실행·도구·WSL·업데이트) · i18n · lib · ui(기본 부품·테마) · assets
windows/src-tauri/src/  프로세스 실행·pty·파일 감시·HTTP·자격 증명(Rust)
```

Windows 폴더 규칙(어기면 `windows/tests/architecture.test.ts` 가 실패합니다):

- 계층은 `app → pages → widgets → features → entities → shared`. **아래 계층만** 가져오고, 같은 계층의 다른 조각은 가져오지 않습니다(엔티티끼리, `shared` 세그먼트끼리는 허용).
- 다른 조각은 **공개 API(`index.ts`)로만** 가져옵니다: `import { Sidebar } from "@/widgets/sidebar"`. 조각 안에서는 상대 경로.
- `index.ts` 는 다른 조각이 쓰는 이름만 밝혀 다시 내보냅니다(`export *` 금지).
- 조각 안 파일은 세그먼트 폴더에 둡니다: `ui/`(화면·CSS) · `model/`(상태) · `api/`(외부 호출) · `lib/`(순수 함수) · `config/`.
- 조각 사이에 순환 참조를 만들지 않습니다. 아래 조각이 위 조각을 알아야 하면 필요한 것만 담은 인터페이스를 아래에 둡니다(예: `CIHost`, `AgentHost`).
- 스타일은 그 화면 조각의 `ui/*.css` 에(컴포넌트에서 `import "./x.css"`). 색·글꼴 토큰과 배치 도우미는 `app/styles/global.css`.

## 규칙

### 두 플랫폼은 같이

- **기능은 맥과 Windows 에 함께** 넣습니다. 한쪽만 되는 기능이면 PR 에 이유를 적어 주세요.
- 이름과 나누는 방식을 맞춥니다: 맥 `RepoStore+CI.swift` ↔ Windows `entities/ci/model/store.ts`, `Views/Sheets/NewBranchSheet.swift` ↔ `features/create-branch/ui/NewBranchSheet.tsx`. 한쪽 코드를 읽으면 다른 쪽을 찾을 수 있게.
- git 동작은 새로 만들지 않고 **시스템 `git` 을 호출**합니다(맥 `Git.run`, Windows `git()` / `this.g()`). 출력은 기계용 형식(`--porcelain=v2 -z`, `--format=…%x1f…`)으로 받아 `Parsers` 로 해석합니다.

### 코드

- **들여쓰기**: Swift · Rust 4칸, TypeScript · JSON · CSS · YAML 2칸. LF, 파일 끝 줄바꿈([`.editorconfig`](.editorconfig)).
- **Swift**
  - 상태는 `@MainActor @Observable final class`, 화면 상태는 `@State` 대신 `@ViewState`(일부 Command Line Tools 에서 매크로가 깨져서 쓰는 별칭).
  - 무거운 일(그래프 배치 등)은 `Task.detached` 로 메인 스레드 밖에서.
  - `private` 이 기본. 다른 파일의 확장에서 써야 할 때만 넓힙니다.
- **TypeScript**
  - `strict` · 쓰지 않는 변수·import 금지(`tsc` 가 막습니다). `any` 대신 정확한 타입.
  - 상태는 `Observable` 을 상속한 클래스 + 바뀐 뒤 `this.emit()`, 화면은 `useObserve(store)`.
  - 백엔드 호출은 `shared/api`(`ipc`)를 거칩니다. 컴포넌트에서 `invoke` 를 바로 부르지 않습니다.
  - 큰따옴표, 세미콜론, 화살표 함수 위주. 한 파일이 400줄을 넘으면 나눌 때가 됐다는 신호입니다.
- **Rust**: `cargo fmt`. Windows 에서 띄우는 프로세스는 콘솔 창이 뜨지 않게(`CREATE_NO_WINDOW`).
- **주석**: 한국어로, **왜** 그렇게 하는지를 씁니다. 무엇을 하는지는 코드가 말하게. 공개 타입·함수는 `///`(Swift) · `/** */`(TS) 한 줄 설명.
- **성능**: 파일 감시로 불리는 코드는 큰 저장소(커밋 수만 개)를 생각합니다. 같은 값을 다시 넣어 화면을 다시 그리게 하지 않고, git 프로세스 수를 줄입니다. 맥은 `GITROCHI_TRACE=1` 로 새로 고침 시간을 볼 수 있습니다.

### 화면과 글

- **화면 글은 코드에 영어로** 쓰고, 그 영어가 번역의 키입니다. 짧고 문장형 대소문자(sentence case), 메뉴·버튼은 동사형(「Stage」, 「Create branch…」).
  - 맥: SwiftUI 의 `Text("…")`·`Button("…")` 등은 그대로 번역되고, 그 밖의 글자(오류 메시지 등)는 `String(localized: "…")`.
  - Windows: `t("…")`, 값은 `t("Commit {0} files", n)` 처럼 `{0}`·`{1}`.
  - 번역: 맥 `macos/Resources/Localizations/<언어>.lproj/Localizable.strings`, Windows `windows/src/shared/i18n/locales/<언어>.json`. 새 글자를 넣었으면 같은 PR 에서 한국어(`ko`)는 꼭, 다른 언어는 할 수 있는 만큼 채워 주세요(없으면 영어로 보입니다).
  - 기본 화면 언어는 영어이고, 설정 > 화면에서 바꿉니다.
- **아이콘 버튼의 뜻은 글자 대신 마우스를 올렸을 때**(맥 `.help(…)`, Windows `tip=` / `data-tip`) 보여 줍니다.
- 되돌리기 어려운 동작(삭제·강제 Push·Reset hard·배포 실행·세션 종료)은 확인을 한 번 받습니다.
- 라이트·다크 두 테마에서 모두 확인합니다. 색은 맥 시스템 색 / Windows CSS 변수(`--text`, `--accent` …)만 씁니다.
- 맥은 VoiceOver 로 읽히고 눌리게(`accessibilityElement` · `accessibilityAction`).

### 개인정보 · 보안

- **토큰은 키체인(맥) · 자격 증명 관리자(Windows)에만.** 설정 파일·로그·오류 메시지에 남기지 않습니다.
- 코드·테스트·스크린샷에 실제 회사·사람 이름, 사내 주소, 개인 이메일을 넣지 않습니다. 예시는 `example.com` 과 데모 저장소로.
- 외부로 보내는 요청(GitHub·GitLab·AI·Gravatar)은 사용자가 연결·선택한 것만.

### 테스트

- 파서·그래프·YAML 처럼 순수한 로직은 `windows/tests/*.test.ts` 에 단위 테스트를 더합니다.
- Windows 에 화면·동작을 더했다면 `windows/src/app/selftest.ts` 에 실제 앱으로 해 보는 항목을 하나 더합니다. 푸시하면 GitHub Actions 의 Windows 서버에서 돕니다.
- 외부 서버가 필요한 기능은 `windows/tests/mock-ai-server.mjs` 에 가짜 응답을 더해 점검합니다.

## Git 규칙

처음 한 번 `git config core.hooksPath .githooks` 를 해 두면 커밋·푸시할 때 아래 규칙을 검사합니다. 같은 검사([`.githooks/rules.sh`](.githooks/rules.sh))가 GitHub Actions 「Git 규칙」에서도 돌아, 어긋난 PR·푸시는 통과하지 못합니다.

### 브랜치

- `main` 은 언제나 빌드되고 배포할 수 있는 상태입니다. 작업은 `main` 에서 딴 브랜치에서 합니다.
- 이름은 `종류/내용`, 영문 소문자·숫자·`-` 로: `feature/ci-branch-view`, `fix/narrow-graph`, `refactor/…`, `docs/…`, `ci/…`, 버전은 `release/0.3.11`.
- 한 브랜치에 한 주제. 오래 두지 말고 `git fetch && git rebase origin/main` 으로 최신을 따라갑니다(`main` 을 merge 해 들여오지 않습니다).
- **`main` 은 PR 로만 바뀝니다.** GitHub 규칙(ruleset)으로 직접 푸시·force push·삭제가 막혀 있고(관리자 포함), `Git 규칙` 검사가 통과해야 합칠 수 있습니다. 로컬 pre-push 훅도 `main` 으로의 푸시를 미리 막습니다.
- **공동 작업자**(저장소 쓰기 권한)는 이 저장소에 브랜치를 만들고 PR 을 합칠 수 있습니다. 공동 작업자의 PR 은 **다른 사람의 승인 1개**가 있어야 합쳐지고(새로 푸시하면 승인이 풀림), 관리자는 자기 PR 을 승인 없이 합칩니다.
- 자기 PR 브랜치는 `git push --force-with-lease` 로 고쳐도 됩니다.

### 커밋 메시지

여러 나라 사람이 기록을 읽으므로 **커밋 메시지는 영어로** 씁니다(코드 주석은 지금처럼 한국어).

```
Area: Imperative summary of the change

- Why, or one bullet per notable change
- Another change
```

- 제목은 `영역: 요약`. 영역 예: `Graph`, `Sidebar`, `CI/CD`, `Windows`, `macOS`, `i18n`, `Perf`, `README`, `CI`. 두 플랫폼 모두면 영역 없이 요약만.
- 요약은 **명령형**: `Add …`, `Fix …`, `Show …` (`Added`·`Fixes`·`Updating` 아님). 예: `Graph: Show avatars in the inspector`, `Windows: Fix the layout on narrow windows`.
- 영어가 아닌 글(화면 번역문 등)을 적어야 하면 `` `탐색기에서 보기` `` 처럼 백틱으로 감쌉니다. `Co-Authored-By:` 같은 트레일러의 이름은 그대로 둬도 됩니다.
- 검사하는 것: 영어(라틴 문자·문장 부호) · 제목 100자 이내 · 끝에 마침표 없음 · 콜론 뒤 한 칸 · 명령형 · 제목 다음 줄은 빈 줄 · `wip`·`fix`·`update` 처럼 내용 없는 제목 금지.
- `fixup!`·`squash!` 커밋은 PR 을 올리기 전에 `git rebase -i --autosquash origin/main` 으로 합칩니다.
- 한 커밋에는 한 가지 주제. 정리(파일 이동)와 동작 변경은 나누고, 커밋마다 빌드가 되게 합니다(`git bisect` 가 쓸 수 있게).
- 버전 커밋 `Release 0.3.11 (summary)` 와 태그 `v0.3.11` 는 관리자가 만듭니다(아래 「릴리스」).
- 이 규칙 전의 기록(한국어 메시지)은 그대로 둡니다.

### 검사에 걸린 PR 고치기

코드는 그대로 두고 커밋 메시지만 다시 쓴 뒤 같은 브랜치에 강제 푸시합니다. PR 은 그대로 이어집니다.

```sh
git remote add upstream https://github.com/Gitrochi/Gitrochi.git   # 포크라면 처음 한 번
git fetch upstream
git rebase -i upstream/main        # 고칠 커밋의 pick 을 reword(r) 로 → 열리는 편집기에서 영어로
git push --force-with-lease
```

커밋이 하나뿐이면 `git commit --amend` 후 `git push --force-with-lease`. 검사가 통과해야 합칠 수 있으므로, 기여자가 고치기 어려우면 PR 의 「Allow edits by maintainers」가 켜져 있을 때 관리자가 기여자에게 알리고 같은 방법으로 그 브랜치를 고칩니다.

### 올리지 않는 것

검사가 막는 것:

- **비밀값**: 개인 키, 업데이트 서명 키, GitHub·GitLab·Anthropic·Slack·AWS 토큰. 실수로 올렸다면 커밋을 지우는 것으로 끝내지 말고 **그 키를 폐기**하세요.
- **내 컴퓨터 경로**: `/Users/<이름>/`, `/home/<이름>/`, `C:\Users\<이름>\`. 예시는 `/Users/me` 처럼.
- 빌드 결과·의존성(`dist/`, `target/`, `.build/`, `node_modules/`), `.DS_Store`, `.env`, 키 파일(`*.key`·`*.pem`), 2MB 넘는 파일.
- 줄 끝 공백, 빈 줄로 끝나는 파일, 남은 충돌 표시(`<<<<<<<`). 텍스트는 모두 LF 로 저장됩니다([`.gitattributes`](.gitattributes)).

검사가 못 잡는 것: 회사·사람 이름, 사내 주소, 개인 이메일 — 올리기 전에 `git diff --cached` 로 직접 봐 주세요.

## PR

1. `main` 에서 브랜치를 만들어 작업합니다(위 「브랜치」).
2. 위의 확인(빌드·`tsc`·`vitest`·`cargo check`)을 통과시키고, 화면이 바뀌었으면 라이트·다크 스크린샷을 붙입니다.
3. PR 설명의 체크리스트를 채워 주세요. CI(Windows 자동 점검 · Git 규칙)가 통과해야 합칩니다.
   - Windows CI 는 `windows/` 를 바꾼 PR 마다 점검용 빌드 한 번 + 실제 앱 자동 점검을 합니다(9분 안팎, 새로 푸시하면 이전 실행은 취소). 필수 검사는 아니라 auto-merge 는 기다리지 않으니, 결과를 PR 에서 확인하세요.
   - 서명한 설치 파일·자동 업데이트 서명 점검·README 스크린샷은 `v*` 태그와 수동 실행(Actions › Windows › Run workflow)에서만.
4. 합칠 때는 merge commit 으로(PR 단위 기록이 남게). `gh pr merge --auto --merge` 를 걸어 두면 검사가 통과하는 대로 합쳐지고, 합친 브랜치는 자동으로 지워집니다.

## 릴리스

관리자가 합니다. `v*` 태그는 관리자만 만들 수 있고, 업데이트 서명 열쇠(`GITROCHI_UPDATE_KEY`·`TAURI_SIGNING_PRIVATE_KEY`)는 `v*` 태그와 `main` 에서만 쓸 수 있는 `release` 환경에 있어 PR 의 실행에서는 읽을 수 없습니다. `main` 이 PR 로만 바뀌므로 버전도 PR 로 올리고, 합친 뒤 태그를 답니다.

버전은 `macos/Resources/Info.plist`의 `CFBundleShortVersionString`, `tools/gitch/gitch`의 `GITSW_VERSION`, Windows의 `package.json` · `package-lock.json` · `src-tauri/tauri.conf.json` · `src-tauri/Cargo.toml` · Cargo.lock의 gitrochi 패키지를 함께 맞춥니다. `CFBundleVersion`은 별도 빌드 번호입니다. CLI의 `GITCH_VERSION_SCHEME="gitrochi"`는 예전 독립 버전과 구분하는 표식이고, 그래프 지원은 `GITCH_GRAPH_API`로 확인합니다. 버전 변경 뒤 `bash tools/check-versions.sh`가 통과해야 합니다.

```sh
git switch -c release/0.3.11            # 버전 올리기(Info.plist · tauri.conf.json · package.json …)
git commit -m "Release 0.3.11 (summary)"
git push -u origin HEAD && gh pr create --fill && gh pr merge --auto --merge
# 합쳐지면
git switch main && git pull --ff-only
git tag v0.3.11 && git push origin v0.3.11   # 태그 실행이 서명한 배포 파일을 릴리스 초안에 올린다
```

태그 실행은 맥(`macos.yml`)과 Windows(`windows.yml`)가 따로 돌고, 태그와 앱 버전(`Info.plist` · `tauri.conf.json`)이 다르면 멈춥니다. 둘 다 그 태그의 릴리스에 올리며, 릴리스가 없으면 먼저 올리는 쪽이 초안을 만듭니다. 두 올리기 작업은 같은 `concurrency` 그룹에서 하나씩 돌아 초안이 둘 생기지 않습니다.

- 맥: `Gitrochi-0.3.11-macOS.dmg` · `.zip` · `.zip.sig` · `.sha256`, 그리고 앱 없이 쓰는 `gitch` · `gitch.sha256`(`tools/gitch/install.sh` 와 `gitch self-update` 가 받음)
- Windows(자동 점검까지 통과한 뒤): `Gitrochi_0.3.11_x64-setup.exe` · `.exe.sig` · `_x64_portable.zip`(`Gitrochi.exe` + `LICENSE.txt`) · `_windows.sha256` · `latest.json`. 같은 파일이 그 실행의 아티팩트 `gitrochi-windows` 에도 남습니다.

앱의 업데이트 확인은 초안을 보지 않으므로, 게시하기 전에:

1. 릴리스 노트를 씁니다. 맥 앱의 업데이트 창에는 이 본문이 보입니다.
2. Windows 업데이트 창에 보일 한 줄을 `latest.json` 의 `notes` 에 넣습니다. 태그 실행은 비워서 올리고(비어 있으면 창에 버전만 보임), Windows 의 「릴리스에 올리기」를 다시 돌리면 다시 비워지므로 게시 직전에 합니다.

   ```sh
   gh release download v0.3.11 -R Gitrochi/Gitrochi -p latest.json   # 받은 파일의 "notes" 를 고치고
   gh release upload v0.3.11 latest.json -R Gitrochi/Gitrochi --clobber
   ```

3. 게시합니다: `gh release edit v0.3.11 -R Gitrochi/Gitrochi --draft=false --latest`
