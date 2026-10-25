# Gitrochi 변경 리뷰

- 브랜치: main
- 생성: 2026-10-25T23:17:50+0900
- 범위: 작업 트리 · 스테이지 포함 · 미추적 파일 excluded
- 선택 ref: origin/main
- 기준 SHA: 61538df92fb5df2bec8ea741186cde3e1ff5509b
- 현재 HEAD: 61538df92fb5df2bec8ea741186cde3e1ff5509b · 스냅샷 worktree
- merge-base: 적용
- 필터: {"language":"all","query":"","folder":"","includeHeuristic":true,"includeTests":true,"depth":3,"hiddenGroups":\[\],"canvas":{"relation":"files","unit":"file","onlyDiff":false,"onlyAffected":false}}

## 선택 변경과 리뷰 순서

- tools/gitch/gitch · 본문 또는 선언 변경 · 변경 내용 확인
- tools/gitch/tests/graph\_browser.mjs · 본문 또는 선언 변경 · 변경 내용 확인
- tools/gitch/tests/test\_graph.sh · 본문 또는 선언 변경 · 변경 내용 확인

## 직접 확인 대상 · 0

찾은 경로 없음.

## 간접 확인 대상 · 0

찾은 경로 없음.

## 순환과 규칙 비교

- 순환 신규: 0
- 순환 구성 변경: 0
- 순환 해소: 0
- 순환 기존: 0
- 규칙 파일 없음 · 검사하지 않음.

## 테스트 후보와 선정 근거

- tools/gitch/tests/graph\_browser.mjs
  - 같은 폴더 · 관례 후보
  - 파일 이름 관례 · 추정 후보
- tools/gitch/tests/test\_graph.sh
  - 같은 폴더 · 관례 후보
  - 파일 이름 관례 · 추정 후보
- windows/tests/gitch.test.ts
  - 파일 이름 관례 · 추정 후보
- tools/gitch/tests/completion\_powershell.ps1
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/helper\_test\_support.py
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/lib.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/run.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/scip\_fixtures.py
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_app.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_cli\_contract.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_commit.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_compat.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_config.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_graph\_evidence.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_graph\_history.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_graph\_impact.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_graph\_precise.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_guard.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_hooks.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_login.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_misc.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_onboarding.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_repo.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_scip.py
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_standalone.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_versions.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_watch.py
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/test\_windows.sh
  - 같은 폴더 · 관례 후보
- tools/gitch/tests/validate\_schema.py
  - 같은 폴더 · 관례 후보

실행 가능한 프로젝트 명령을 확인하지 못하여 실행 명령은 제안하지 않습니다. 경로를 사용해 직접 실행하세요.

## 추정과 분석 한계

- 추정 포함/제외 시 변경과 확인 대상 합계: 3/3
- 영향은 정적 의존 경로상 확인 대상이며 런타임 오류를 예측하지 않습니다.
- 참조가 없더라도 미사용 코드로 단정할 수 없습니다. 엔트리 포인트·동적 로딩·지원하지 않는 문법은 누락될 수 있습니다.
- 비교 양쪽은 같은 정적 분석기를 사용합니다. 외부 컴파일러 인덱스와 매니페스트 실행을 제외하여 노후 인덱스에 의존하지 않습니다.
- 검색·언어·폴더 필터는 시작 변경 파일을 고릅니다. 의존 경로는 연결된 다른 언어·폴더까지 추적합니다. 그래프 표시 전용 필터는 보고서에 설정으로 기록합니다.
- 미추적 파일 제외 · 폴더 범위 전체 · 언어 all · 3단계 탐색
- Swift: Tuist · SwiftPM 매니페스트로 파일의 모듈을 정해, 다른 모듈의 타입은 그 모듈을 import 했고 public · open · package 로 선언됐을 때만 이었습니다(@testable 이면 internal 도) (모듈 3개, 그래서 뺀 이름 16개).
- Swift: 파일끼리 import 하지 않아서, 다른 파일에 선언된 최상위 타입(class · struct · enum · protocol · actor · typealias) 이름을 쓰면 연결로 추정했습니다 (heuristic: true, 그림에서는 점선).
- 파일만 인식·미지원: 37개
  - .github/ISSUE\_TEMPLATE/bug\_report.yml
  - .github/ISSUE\_TEMPLATE/config.yml
  - .github/ISSUE\_TEMPLATE/feature\_request.yml
  - .github/ISSUE\_TEMPLATE/question.yml
  - .github/workflows/git-rules.yml
  - .github/workflows/macos.yml
  - .github/workflows/windows.yml
  - tools/gitch/schema/gitch-v1.schema.json
  - tools/gitch/tests/completion\_powershell.ps1
  - windows/index.html
  - windows/package-lock.json
  - windows/package.json
  - windows/src-tauri/Cargo.toml
  - windows/src-tauri/capabilities/default.json
  - windows/src-tauri/tauri.conf.json
  - windows/src/shared/assets/icon.png
  - windows/src/shared/i18n/locales/cs.json
  - windows/src/shared/i18n/locales/de.json
  - windows/src/shared/i18n/locales/es.json
  - windows/src/shared/i18n/locales/fr.json
  - windows/src/shared/i18n/locales/hu.json
  - windows/src/shared/i18n/locales/id.json
  - windows/src/shared/i18n/locales/it.json
  - windows/src/shared/i18n/locales/ja.json
  - windows/src/shared/i18n/locales/ko.json
  - windows/src/shared/i18n/locales/nl.json
  - windows/src/shared/i18n/locales/pl.json
  - windows/src/shared/i18n/locales/pt-BR.json
  - windows/src/shared/i18n/locales/ru.json
  - windows/src/shared/i18n/locales/th.json
  - windows/src/shared/i18n/locales/tr.json
  - windows/src/shared/i18n/locales/uk.json
  - windows/src/shared/i18n/locales/vi.json
  - windows/src/shared/i18n/locales/zh-Hans.json
  - windows/src/shared/i18n/locales/zh-Hant.json
  - windows/tsconfig.json
  - tools/gitch/gitch
- UNANALYZED\_CHANGE · tools/gitch/gitch · Changed file is listed, but its dependency syntax is not supported by this analysis.
