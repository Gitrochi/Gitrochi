# 흐름 설계

[README.md](README.md) 가 쓰는 법이라면 이 문서는 **왜 이렇게 만들었는지**와 지키는 계약입니다. 검증한 범위는 [../flow-validation.md](../flow-validation.md).

## 구성

```
 앱(맥 SwiftUI · Windows Tauri)        gitch(bash 앞문)            CI 러너
   흐름 탭 · 신뢰 확인 · 실행 보기     gitch flow · gitch test        gitch flow run <흐름> --ci
   push 전 확인 켜기                   pre-push 훅 · preflight 의 FLOW 줄
        │  CLI + JSON / NDJSON                │ exec                        │
        └──────────────► gitch-flow(Rust 실행 파일, tools/gitch-flow) ◄─────┘
                  spec → plan → (preflight) → run → verdict → rollback → record(서명)
                  blocks: cmd · test.* · check.* · setup.* · docker.* · deploy.* · ci.* · mock · fixture · gate · gitch · notify
```

- **엔진이 유일한 판정자**: 앱 · gitch 는 사람이 누른 동작을 보내고 엔진이 낸 JSON 을 보여 줄 뿐 판정하지 않습니다. 같은 흐름이 앱 · 터미널 · push 전 · CI 에서 같은 결과를 냅니다(로컬 = CI).
- **앱 ↔ 엔진 계약**: `list` · `plan` · `status` · `report` · `init` · `gate` 의 `--json`, `run --detach --json`(실행 ID · 이벤트 파일) 뒤 `events.ndjson` 을 따라 읽기, 오류는 표준오류의 봉투 `{"schemaVersion":1,"error":{…}}`. 스키마는 `tools/gitch-flow/schema/` 에 있고 `gitch schema flow*` 로 꺼냅니다. 맥은 `macos/Tools/test-flow.sh` 가 실제 엔진 출력을 앱 모델로 읽어 보고, Windows 는 이벤트 읽기를 단위 시험 · 자동 점검(selftest)으로 봅니다.
- **실행 기록**: `<git common dir>/gitch/flow/runs/<워크트리 ID>/<실행 ID>/` — `run.json`(HMAC 서명) · `plan.json` · `events.ndjson` · `logs/` · `reports/` · `out/<노드>/` · `undo.ndjson`. 워크트리마다 나뉘어 에이전트 워크트리끼리 섞이지 않습니다.

## 상태와 판정

- 노드: `PENDING → RUNNING → PASSED | FAILED | INDETERMINATE`, 그 밖에 `SKIPPED · CACHED · REJECTED · CANCELLED`. 실행: `PENDING → PREFLIGHT → RUNNING → SUCCEEDED | FAILED | CANCELLED | REJECTED`, 바꾼 것이 있으면 `FAILED | CANCELLED → ROLLING_BACK → ROLLED_BACK | ROLLBACK_FAILED`. 허용 전이는 표 하나에만 있고, 그 밖의 전이는 엔진 위반으로 기록합니다.
- **흐름 사전 점검**: 아무것도 바꾸기 전에 모든 노드의 전제 조건을 관측만 합니다(연결 · 허용 목록 · 예상 시작 시각의 금지 시간대 · 잠긴 환경). 하나라도 걸리면 `REJECTED` — 아무것도 바뀌지 않습니다. Docker 처럼 그 노드만 막히는 것은 그 노드만 `REJECTED` 하고 나머지는 계획대로 돕니다.
- **판정은 관측값의 순수 함수**(`verify.rs`): 종료 코드는 여러 관측값 중 하나일 뿐이고, 판정할 수 없음은 실패로 셉니다. 테스트 0개 실행 · 이번 실행 전에 쓴 보고서 · 종료 코드와 보고서의 모순은 모두 통과가 아닙니다.

## 효율

- 영향 선택은 "확신이 없으면 전부"입니다: 의존 · 설정 파일 변경, 정적으로 풀지 못한 파일, 파일 고르기를 못 하는 실행기는 전부 돌리고 그 이유를 계획에 적습니다.
- 캐시는 **순수한 노드만**(입력을 밝히고 서비스 · 네트워크 · Docker · 원격 · 바깥 동작이 없는 것). 열쇠에 블록 판 · 입력 · 환경 · 선택 · 조합 · 실행 위치 · 입력 파일 내용 · 엔진 판 · 운영체제가 들어갑니다.
- 분리 실행(`--detach`)은 앱을 닫아도 끝까지 돌고, 앱은 파일을 따라 읽기만 합니다. 강제 종료된 엔진의 실행은 다음 실행이 닫습니다(바꾼 흔적이 있으면 대상을 건드리지 않고 잠금).

## 안전

- **신뢰**: 흐름 파일 해시를 사람이 승인해야 비대화형으로 돕니다. 기록은 저장소 밖이라 저장소를 바꾸는 쪽(AI 포함)이 승인을 위조할 수 없고, gitch guard 가 AI 의 그 폴더 편집을 막습니다.
- **AI 실행 주체**: gitch 와 같은 규칙으로 실행 주체를 고르고(Claude Code · Codex · Cursor · Gemini …), AI 는 신뢰 승인 · 잠금 해제 · 게이트 켜고 끄기를 못 하며 CI 예외도 받지 못합니다. 앱은 `GITSW_ACTOR=gitrochi-app` 으로 사람이 누른 동작임을 밝힙니다.
- **주입 · 비밀값**: `run` · `undo` 에 넣는 값은 셸 인용, 비밀은 `env` · `secrets:` 로만 넘기고 그 순간 가림 사전에 넣습니다. 컨테이너에는 환경 값을 이름으로만 넘깁니다. HTTP 는 리다이렉트를 직접 따라가며 출처가 바뀌면 인증 헤더를 모두 빼고 https → http 는 거부합니다(라이브러리는 `Authorization` · `Cookie` 만 빼서 `PRIVATE-TOKEN` 같은 헤더가 새는 것을 막으려고).
- **운영 보호 · 되돌림**: 파괴적 블록은 운영 등급에서 사용자 설정 없이는 거부. 바꾸기 전에 되돌림을 등록하고, 되돌림이 실패하면 환경을 잠가 사람이 확인하게 합니다. 엔진은 되돌림을 마음대로 다시 시도하지 않습니다.
- **프로세스**: Unix 는 프로세스 그룹, Windows 는 작업 개체(Job Object)로 손자 프로세스까지 한 번에 끝냅니다. 취소 신호 뒤 정리 유예를 지나면 "멈춤"(EXEC-03)으로 보고 강제로 끝냅니다. Windows 에서는 콘솔 창을 띄우지 않습니다.

## 다른 운영 도구에서 가져온 개념

블록 · 흐름 기반 운영 도구를 만들던 경험에서 다음 개념을 범용으로 가져왔습니다(코드는 가져오지 않았습니다): 준비 구역 실패 = 거부(아무것도 안 바뀜) · 변경 구역 실패 = 되돌림, `mutates ⇒ undo`, 되돌림 범위 node · flow 와 검사 실패 되돌림 스위치, 되돌림 실패 = 환경 잠금, 예상 시작 시각으로 금지 시간대 미리 보기, 원격 CI 운전 규칙(상관 ID · 먼저 찾기 · 응답 잃은 POST 다시 안 보냄 · CI 결론은 참고만 · 마지막 표식 줄이 이김), 결정적 가짜 서버와 장애 스위치, 마스킹 순서. 그 도구에서 고친 점: 원격 엔진 막힘 → Jenkins · GitLab · GitHub 를 처음부터, 큰 대상 인터페이스 → 능력별 블록, 직선 흐름 → DAG, 이벤트를 먼저 내보내고 저장 → 파일에 먼저 쓰고 내보내기, 고정 시간대 → 시간대 명시. 회사 전용 배포 전략 · 판정 규칙은 공개 저장소 밖의 비공개 블록 묶음으로 둡니다.

## 결정

각 결정은 작업을 시작할 때 정한 **작업 기본값**입니다(사용자가 "전부 진행"을 지시해 이 값으로 구현했고, 항목별 확인은 기다리는 중). 바꾸려면 이 표와 해당 코드를 함께 고칩니다.

| # | 주제 | 작업 기본값 | 상태 |
|---|---|---|---|
| D1 | 엔진 언어 | Rust 단일 실행 파일(`tools/gitch-flow`) — 세 운영체제 · 앱 동봉 · 정적 링크 Linux | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D2 | 맥 빌드의 cargo | 개발 빌드는 선택(없으면 엔진 없이), 배포본은 필수(유니버설) | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D3 | 흐름 파일 | `.gitch/flow.yml` ⊕ `flows/*.yml` ⊕ `flow.local.yml`, 복합 블록 `.gitch/blocks/`, 격리 `.gitch/flaky.yml` | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D4 | 실행 기록 위치 | git common dir 아래 워크트리별 | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D5 | 앱 ↔ 엔진 | CLI + JSON/NDJSON, `--detach` 뒤 이벤트 파일 따라 읽기 | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D6 | 흐름 편집 | 플랫폼마다 네이티브 화면. 지금은 흐름 파일(텍스트) + 앱의 실행 · 신뢰 확인 · 제안 화면(그림 편집기는 다음 단계) | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D7 | push 전 게이트 | 기본 끔(저장소마다 `gitch flow gate on` · 앱에서 켬) | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D8 | 원격 CI 순서 | GitLab · GitHub → Jenkins → 일반 HTTP | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D9 | 회사 전용 블록 | 공개 저장소 밖 비공개 블록 묶음(기존 사내 콘솔은 유지) | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D10 | PR/MR 에 결과 쓰기 | 끔 | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D11 | Linux | CLI 만(엔진 + gitch) | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D12 | 원격 캐시 · 원격 러너 | 범위 밖 | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D13 | 흐름 스키마 | gitch 스키마와 따로, `gitch schema flow*` 가 엔진에 넘김 | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D14 | 앱 계정 · 호스팅 모델 | 지금 그대로(github.com · 자체 호스팅 GitLab), 엔진 연결은 API 주소를 받음 | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |
| D15 | 앱의 기존 CI 코드 | 그대로 둠(엔진으로 옮기는 것은 측정 뒤 제안) | 작업 기본값 — 사용자 전체 진행 지시, 개별 확인 대기 |

## 코드 위치

| 무엇 | 어디 |
|---|---|
| 엔진 | `tools/gitch-flow/src/` — `spec` · `plan` · `run` · `rollback` · `verify` · `blocks/` · `ci/` · `services` · `docker` · `executor` · `mock` · `affected` · `cache` · `store` · `trust` · `mask` |
| 엔진 시험 | `tools/gitch-flow/tests/` — 실행 파일을 임시 저장소 · 임시 HOME 에서(가짜 docker CLI · 가짜 GitLab/GitHub/Jenkins/HTTP CI · 실제 Docker 는 `real_docker.rs`) |
| gitch 앞문 | `tools/gitch/gitch` 의 `flow_cmd` · `hook_flow_gate` · guard 규칙, 시험 `tools/gitch/tests/test_flow.sh` |
| 맥 앱 | `macos/Sources/Core/FlowModels.swift` · `Services/FlowEngine.swift` · `Store/FlowStore.swift` · `Views/Sidebar/FlowPanel.swift` · `Views/Sheets/FlowSheets.swift` |
| Windows 앱 | `windows/src/entities/flow/` · `windows/src/widgets/sidebar/ui/FlowPanel.tsx` |
| 빌드 · 배포 | `tools/gitch-flow/build.sh` · `macos/build.sh` · `windows/src-tauri/tauri.windows.conf.json` · `.github/workflows/flow.yml` |
