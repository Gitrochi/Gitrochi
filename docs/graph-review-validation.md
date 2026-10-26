# gitch 변경 리뷰 구현 및 검증

검증일: 2026-10-25, Asia/Seoul.
요청에 적힌 `Branchwork` 폴더는 이 컴퓨터에 없었다. 현재 작업 폴더인 `Gitrochi`에서 동일한 `tools/gitch/gitch`, `graph_html()`과 기존 그래프 테스트를 확인해 구현했다.

## 사용 흐름

```sh
# 기존 네 가지 보기와 변경 리뷰
./tools/gitch/gitch g --format html

# 기준은 기존 기본 브랜치 탐색을 재사용한다. 아래 명령은 각 범위의 소스를 실제로 다르게 읽는다.
./tools/gitch/gitch g diff --format html
./tools/gitch/gitch g diff --scope staged --format html
./tools/gitch/gitch g diff --scope committed --format html

# 특정 ref와 갈라진 지점을 비교하는 기존 문법도 유지한다.
./tools/gitch/gitch g diff --base origin/main... --format html
```

범위는 HTML 생성 시 고른다. 오프라인 HTML에서 다른 범위의 데이터를 재분석하는 기능은 넣지 않았다.

1. 상단에서 저장소·브랜치·생성 시각·범위·선택 ref·기준 SHA·merge-base 여부를 확인한다. 긴 SHA는 상단 툴팁과 보고서에 전체 값이 있다.
2. 왼쪽에서 검색, 폴더, 언어로 시작할 변경을 좁히고 체크박스로 여러 파일을 고른다. 함수 본문만 바뀐 파일도 표시한다.
3. 확인 깊이를 정하고 영향 보기로 이동한다. 오른쪽에서 중복을 제거한 직접·간접 확인 대상, 경로, 신규 문제에 따른 리뷰 순서와 테스트 후보를 확인한다.
4. 파일을 누르면 원본·대상·관계 종류·발견 방법·확보된 파일과 행을 확인한다. 선택한 변경의 상세에서 `이 변경의 리뷰·테스트`로 돌아갈 수 있다.
5. 추정 필터를 바꾸어 포함/제외 결과를 비교한다. 테스트 후보는 직접·전이 참조, 같은 모듈, 폴더·이름 관례를 구분한다. 경로를 복사해 사용자가 직접 실행한다.
6. 왼쪽의 Markdown / 오프라인 HTML 저장으로 현재 선택·시작 파일 필터·깊이에 맞는 보고서를 만든다. 외부 업로드·PR 댓글·테스트 실행은 하지 않는다.

검색·언어·폴더 필터는 시작 변경 파일을 고른다. 선택한 변경에서 연결된 다른 언어·폴더의 경로도 확인 대상으로 추적한다. 캔버스 표시용 필터는 보고서에 설정으로 기록한다. 오른쪽 순환·규칙 개요는 전체 스냅샷의 비교이며, 파일별 우선순위와 공유 보고서는 선택한 변경·확인 대상에 연결된 문제를 보여 준다.

`worktree`는 기준 커밋에서 현재 추적 파일까지이며 스테이지 변경을 포함한다. `staged`는 실제 인덱스의 stage-zero blob을 읽는다. `committed`는 HEAD의 파일을 읽는다. files/modules/tree 모두 해당 범위의 소스와 크기를 사용한다. 같이 바뀜은 현재 파일 목록에 대응시킨 HEAD까지의 관찰된 커밋 이력이다.

일반 그래프와 diff의 리뷰는 미추적 파일을 제외한다. 기존 `affected`의 미추적 포함 정책은 유지했고 HTML의 변경 리뷰에도 일치시켰다. 정책은 화면·JSON·보고서에 표시한다.

## 변경 파일

| 파일 | 내용 |
| --- | --- |
| `tools/gitch/gitch` | 읽기 전용 소스 비교, 본문 변경·rename·삭제, 범위 선택, 근거와 리뷰 UI, 테스트 후보, 내보내기, 탐색 기록·복원, UTF-8 파일명 처리 |
| `tools/gitch/tests/test_graph_review.sh` | 범위·인덱스/작업 파일 불변·본문 변경·삭제·rename·순환·미추적 정책·한글 경계 회귀 테스트 |
| `tools/gitch/tests/test_graph.sh` | 기존 브라우저 fixture에 다중 변경·테스트·추정·신규/기존 규칙·특수문자 추가 |
| `tools/gitch/tests/graph_browser.mjs` | 기존 검색·배치·탭·PNG에 리뷰·공유·복원·탐색·입력 보호·오프라인 검증과 화면 캡처 추가 |
| `tools/gitch/tests/graph_benchmark.mjs` | 별도 브라우저 측정 도구. 제품 실행 의존성이 아닌 개발 검증용 Node 22 코드 |
| `docs/screenshots/graph-review/` | 다크·라이트·작은 화면, fixture/실제 저장소 보고서, 성능 원자료 |

계정 보호·보안 검사·훅 구현은 변경하지 않았다. 브랜치·인덱스를 쓰지 않고 임시 폴더에서 기준/선택 소스를 읽는다. 기존 `g`/`graph`, JSON schemaVersion 1, 종료 코드, 앱 결과 행을 유지하고 `review` 정보를 더했다. 기존 diff.base의 짧은 SHA는 유지하며 review.baseSha/headSha에 전체 SHA를 제공한다. 신규 CLI 옵션은 diff의 `--scope` 하나다. 기본 실행에 Node·Python·서버·CDN을 추가하지 않았다.

## 단계별 확인

| 단계 | 확인한 동작 |
| --- | --- |
| 1 | 본문만 변경, 삭제의 기준 그래프, rename의 순환 동일성, 신규 순환, 범위별 소스 차이, 인덱스·HEAD·작업 내용 불변, 기존 레이아웃·검색·탭·PNG |
| 2 | 다중 시작점의 중복 제거, 깊이, 추정 관계 제외, 직접 참조 테스트 근거, 후보 없음, 검색 없음, 신규/기존 규칙 구분 |
| 3 | 선택·깊이 반영 보고서, 경로 정보 제거, 스크립트 없는 독립 HTML을 네트워크 차단 상태로 열기, 외부 요청 0건, 탐색 뒤/앞, 오래된 선택 제거, 입력 중 단축키 보호, 다크·라이트·노트북·작은 화면 |

최종 결과:

- `tests/run.sh -k graph`: **62 통과 / 0 실패**, 65초. 정밀 인덱스, 이력, 의존 규칙, 경로 안전성, Windows 경로를 모사한 검사와 실제 Chrome 브라우저 검사를 포함한다.
- `tests/run.sh -k cli_contract`: **6 통과 / 0 실패**.
- `tests/run.sh -k test_app_`: **15 통과 / 0 실패**. Windows 관련 항목은 모사된 경로·실행기 검사다.
- 기존 이름 호환 검사 `allow_marker`, `guard_treats`: 각 1개 통과.
- macOS 기본 `/bin/bash` 3.2.57 구문 검사와 ShellCheck warning 이상: 통과.
- 처음에 공백 뒤 ASCII 글자가 있는 한글 경로는 통과했지만 `한글.ts`처럼 확장자 직전이 한글인 경로에서 기존 awk의 바이트 경계 문제가 드러났다. 확장자·stem 절단 위치를 수정하고 순수 한글 파일의 import·본문 수정·rename, 한글 미추적 파일을 추가 검증했다.

## 화면과 보고서

브라우저는 Google Chrome 155.0.8059.85, headless, 로컬 `file:` URL로 실행했다. 1280×800에서 기존 브라우저 회귀를 수행하고 1366×768에서 다크·라이트, 680×800에서 위/아래 패널 구성을 확인했다. 패널이 중앙 그래프 영역을 덮지 않도록 작은 화면의 설정도 아래 패널에서 열리게 했다.

- [다크 화면](screenshots/graph-review/graph-dark.png)
- [라이트 화면](screenshots/graph-review/graph-light.png)
- [1366×768 리뷰 화면](screenshots/graph-review/graph-review-1366.png)
- [680×800 화면](screenshots/graph-review/graph-review-680.png)
- [fixture 오프라인 HTML 보고서](screenshots/graph-review/review-report.html), [Markdown](screenshots/graph-review/review-report.md)
- [실제 Gitrochi 오프라인 보고서](screenshots/graph-review/repository/review.html), [Markdown](screenshots/graph-review/repository/review.md)

실제 저장소 보고서는 생성 시점의 **추적된 수정 3개**를 담는다. 신규 테스트와 캡처·문서는 미추적 파일 제외 정책 때문에 이 보고서의 변경 목록에서 빠진다. 실행 가능한 원본 그래프는 `/tmp/gitrochi-review-real/graph.html`에 생성했다. 저장소 파일의 일반적인 위치 정보는 앱 연동용 원본 그래프에 유지하지만, 공유 보고서는 허용한 항목만 만들며 `repoPath` 및 `/Users/me` 같은 사용자 경로 정보가 없는 것을 확인했다.

## 성능 측정

환경: macOS 26.5.1, arm64, Bash 3.2.57, Node 22.23.3, Chrome 155 headless, GPU 비활성화, 브라우저 1280×800. 각 값은 단일 실행의 관찰값이며 장비 전반에 대한 보장은 아니다. 브라우저 준비/정지 시각은 페이지 시작 이후 100ms 간격으로 상태를 확인한 값이다.

| 데이터 | 크기 | HTML 생성 | 브라우저 관찰 | 리뷰 계산: 캐시 비움 → 재사용 |
| --- | --- | --- | --- | --- |
| 실제 저장소 | 원본 파일 그래프 516노드·1,629관계, HTML 4,395,750바이트 | 2.240초 | 123ms에 준비 상태 관찰, 258ms에 force 정지 확인 | 1.6ms → 0.2~0.4ms |
| 큰 fixture | 2,000 TS 소스·100 테스트·21 매니페스트, 2,121노드·2,100관계, HTML 4,123,183바이트 | 약 2초, 1초 해상도 | 104ms에 폴더 요약 준비 상태 관찰 | 3.2ms → 0.8~0.9ms |

실제 저장소 캔버스에는 정적으로 해석할 수 없는 변경 파일을 설명하는 노드 1개를 더해 517개를 표시한다. 실제 저장소 측정에서는 선택적인 Xcode 인덱스와 Swift 매니페스트 실행을 껐다. 비교 리뷰 자체는 항상 양쪽에 같은 정적 분석기를 사용한다.

반복 리뷰에서 불변인 역방향 인접 목록·모듈 소유·순환 결과를 다시 만들지 않게 했다. 측정 범위에서는 계산을 Worker로 옮길 이유가 없어 도입하지 않았다. 큰 데이터의 기본 배치는 기존 폴더 묶음을 재사용하며 확대해 펼친다. 화면 목록을 제한하면 생략 수를 알리고 보고서에는 선택된 전체 결과를 넣는다.

원자료: [큰 fixture](screenshots/graph-review/performance-large.json), [실제 저장소](screenshots/graph-review/performance-repository.json).

## 남은 한계와 미검증 환경

- 실제 Windows Git Bash 실행과 Windows의 화면·클립보드는 검증하지 못했다. 경로·앱 계약을 모사한 검사는 통과했으며 macOS Bash 3.2는 실제 실행했다.
- 비교 리뷰는 정적 분석이다. 지원하지 않는 문법·해결 실패 import·동적 로딩·엔트리 포인트·폴더/언어 범위 밖의 참조가 누락될 수 있다. 인식만 한 변경 파일은 분석 불가 상태와 진단으로 남긴다. 참조가 없다는 사실로 미사용·무결함을 단정하지 않는다.
- 비교 리뷰는 외부 컴파일러 인덱스를 사용하지 않는다. 기존 일반 그래프의 `--precise`/인덱스 근거·노후 검사 기능은 유지한다.
- rename은 Git의 `-M` 검출을 따른다. 작은 파일의 내용을 크게 바꾸면서 이동해 Git이 rename으로 판정하지 못하면 추가·삭제로 남을 수 있다.
- 테스트 후보의 같은 모듈·폴더·이름 관례는 참조 증명과 구분한다. 프로젝트별로 실행 가능성을 검증한 명령을 확보하지 못해 명령을 제안하지 않는다.
- 공유 HTML은 현재 선택에 대한 독립적인 정적 보고서다. 그래프 탐색기 전체를 복제하지 않는다. 외부 네트워크와 스크립트를 CSP로 차단한다.
- 위 성능은 약 2천 노드 fixture와 이 저장소의 결과다. 수만 노드, 실시간 파일 변경 중의 일관된 스냅샷, 모든 언어 문법을 검증한 것은 아니다.
- preflight는 원격 HTTPS 주소의 push 계정 불일치와 검사 훅 누락으로 `STOP`이었다. doctor로 확인했으며 계정·훅 설정을 변경하지 않았고 커밋·push하지 않았다. 작업 종료 시 `main`, STAGED=0 상태를 유지했다.
