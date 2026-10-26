# 흐름 검증 범위

흐름 엔진(`tools/gitch-flow`) · gitch 앞문 · 두 앱의 흐름 화면을 **어디까지 실제로 확인했고 무엇이 아직인지** 적습니다. "확인함"은 이 저장소의 시험이 자동으로 다시 보여 주는 것만 씁니다. 설계는 [flow/DESIGN.md](flow/DESIGN.md).

## 확인함 (macOS 26.5 · Apple Silicon, cargo 1.99 · Swift 6.3 · Node 22)

| 무엇 | 어떻게 | 결과 |
|---|---|---|
| 엔진 단위 시험 | `cargo test --lib` — YAML 부분집합 · 스펙 검증(줄 번호) · 표현식과 셸 인용 · 판정 규칙 · 보고서 해석(JUnit · TRX · go test · jest · TAP · libtest) · 마스킹 · 서명 · 되돌림 범위 · 시간대 · 버전 비교 · Docker 인자 · HTTP 리다이렉트 | 93 통과 |
| 엔진 통합 시험 | `cargo test` — 실행 파일을 임시 저장소 · 임시 HOME 에서(실제 사용자 설정 · 키체인을 건드리지 않음) | 73 통과(아래) |
| ├ CLI | 신뢰(사람 · AI · 스크립트), 서명 · 위조 감지, 이벤트 seq, failFast · 실패 갈래, 0개 · 거짓말 · 옛 보고서 함정, flaky 정책, 멱등 키, **취소 시 손자 프로세스까지 종료**, 셸 인용(주입 방지), init, CI 결과 계약, export · schema, 게이트 켜고 끄기 | 14 |
| ├ 흐름 | 영향 선택(이름 관례 · 전역 파일 · 기본 브랜치 기준 · 스모크), `changed()` 기준, 캐시 재생 · 무효화, 프로세스 서비스 + HTTP 스모크 · 정리, 준비 안 되는 서비스, 가짜 docker CLI 로 서비스 라벨 · 네트워크 · 정리 · 마스킹, 조합(matrix) | 10 |
| ├ 원격 CI | 가짜 GitLab · GitHub · Jenkins · HTTP CI: 상관 ID, **응답을 잃은 트리거를 다시 보내지 않음**(찾으면 이어 봄 · 못 찾으면 CI-01), 외부 취소 CI-04, 계약 없음 CI-03, 계약 실패 CI-02, 로그 표식, 속도 제한(`Retry-After` · `x-ratelimit-reset`), 마감 → 원격 취소 CI-05, 잘못된 토큰 CONN-02, 허용 목록 CI-07, **다른 호스트로 가는 리다이렉트에 토큰이 실리지 않음**(바꾸기 전 코드는 이 시험에서 실패), Jenkins 큐 · crumb · 내부 주소 다시 쓰기 | 19 |
| ├ 되돌림 | 범위 node · flow, 검사 실패와 onCheckFailure, 되돌림 실패 → hold → GUARD-02 → 사람이 풂(AI 거부), 취소 뒤 되돌림, 언제나 도는 정리, 되돌림 스크립트 셸 인용, **강제 종료된 엔진의 실행 닫기**(바꾼 흔적 → hold, 없으면 EXEC-06) | 10 |
| ├ Docker 실행 위치 · 블록 | 가짜 docker CLI(컨테이너 명령을 호스트에서 실행): 라벨 · 같은 경로 마운트 · 환경을 이름으로만 · 스크립트가 명령줄에 없음, 환경의 executor, Docker 꺼짐 → 그 노드만 DOCKER-01, docker.build(태그 · 빌드 인자 이름만 · 비밀 값은 CLI 환경으로) · push · run(125 구분) | 6 |
| ├ 시험 환경 블록 | mock.http(경로 · 파일 · 요청 기록), 장애 스위치 켜고 끄기, check.mock 호출 수, fixture.seed(정리 · keep), gate.window(사전 점검 거부), check.log | 6 |
| └ 운영 블록 | setup.python(버전 비교 · 잠금 파일 그대로면 설치 건너뜀), gitch.preflight · graph.check(가짜 gitch), 알림이 결과를 바꾸지 않음(웹훅 연결 · 토큰), deploy.compose(교체 · 실패 · 건강 확인 실패 → 이전 이미지로 · 비교 후 교체 거부 · 운영 보호) | 8 |
| 정적 검사 | `cargo fmt --check` · `cargo clippy --all-targets -- -D warnings` · `shellcheck -S warning`(gitch · install.sh · build.sh · 시험) | 경고 0 |
| gitch 전체 시험 | `tools/gitch/tests/run.sh` — 앞문 위임 · preflight 의 FLOW 줄 · **실제 push 를 게이트가 통과/차단** · guard 규칙(게이트 켜고 끄기 거부 포함) · 설치기 · self-update 의 엔진 받기(체크섬 · 실행 확인 · 망가진 파일 거부) · 버전 검사 | 213 통과 |
| 맥 앱 | `macos/build.sh` 로 앱 빌드(엔진이 `Contents/MacOS` 에 서명되어 들어가고 Resources 에서 링크, 앱의 gitch 로 `gitch flow version`), 앱 소스 전체 타입 검사, **`macos/Tools/test-flow.sh`: 실제 엔진의 list · plan · gate · 오류 봉투 · 분리 실행 · 이벤트(줄 중간에서 끊어 넣기) · 실행 목록 · 기록 · init 을 앱 모델로 읽음** | 통과 |
| Windows 앱(맥에서) | `npx tsc --noEmit` · `npx vitest run`(흐름 이벤트 읽기 · 오류 봉투 · 확인 조건 4건 포함, 폴더 구조 규칙) · `npx vite build` · `src-tauri` 의 `cargo check`(엔진 없이 — 엔진 자원은 `tauri.windows.conf.json` 에만 있어 다른 OS 빌드가 막히지 않음, 기본 설정에 두면 이 검사가 실패) | 130 통과 |

## 아직 확인하지 않음

| 무엇 | 왜 · 어떻게 확인할지 |
|---|---|
| **Windows 에서 엔진 컴파일 · 시험** | 이 맥에는 Windows 대상 Rust 표준 라이브러리가 없습니다. 작업 개체(Job Object) · 콘솔 신호 · 프로세스 확인 코드는 Windows 에서 빌드된 적이 없습니다. → PR 의 「Flow engine」 작업(windows-latest: fmt · clippy · 시험 · gitch 앞문 시험)과 「Windows」 작업(Windows 전용 설정 `tauri.windows.conf.json` 으로 엔진 빌드 · 설치 파일에 넣기 · 포터블 zip · 자동 점검의 흐름 단계)이 처음으로 확인합니다. |
| **Linux 에서 엔진 시험 · 정적 링크 빌드** | 같은 이유. → 「Flow engine」 작업(ubuntu-latest) · 태그 실행의 musl 빌드. |
| **실제 Docker** | 이 맥의 Docker 데몬이 꺼져 있어 `tests/real_docker.rs`(실제 alpine 컨테이너에서 실행 · 파일 소유자 · nginx 서비스 · 컨테이너끼리 별칭 · 라벨로 정리 확인)는 건너뛰었습니다. 가짜 docker CLI 시험은 인자 · 순서 · 정리만 봅니다. → 「Flow engine」 의 「실제 Docker 시험」 작업. compose.up 은 실제 compose 로 돌린 적이 없습니다. |
| **실제 GitLab · GitHub · Jenkins** | 가짜 서버로 운전 규칙을 확인했지만 실제 서버의 응답 모양 · 권한 · 산출물 경로(특히 GitHub 산출물은 zip 이라 지금은 로그 표식으로 판정) · Jenkins 플러그인 차이는 실제로 보지 않았습니다. → 연결을 만들고 `gitch flow export` 로 만든 CI 파일로 한 번씩. |
| **앱 화면을 눈으로** | 맥은 빌드 · 타입 검사 · 계약 시험까지, Windows 는 타입 검사 · 단위 시험까지 했고 화면을 띄워 보지는 않았습니다(라이트 · 다크 · VoiceOver 포함). Windows 자동 점검에 흐름 단계(앱에 든 엔진으로 신뢰 · 분리 실행 · 흐름 탭 표시)를 더했고 CI 에서 처음 돕니다. |
| **맥 유니버설 · 배포본 서명** | 개발 빌드는 이 맥의 arm64 만. `build.sh release`(aarch64 + x86_64 lipo)는 CI 의 태그 실행에서 처음 돕니다. |
| **OS 비밀 보관소** | 시험은 `GITCH_FLOW_NO_KEYSTORE=1` 로 키체인 · 자격 증명 관리자를 건드리지 않습니다. `connect add`(토큰 저장) · 앱 계정 토큰(`app:`) 읽기는 손으로 확인해야 합니다. |
| **원격 SSH 배포** | `deploy.compose` 의 `host:`(DOCKER_HOST=ssh://)는 가짜 docker 로 인자만 봤습니다. |
| **시간대 이름** | `gate.window` 의 IANA 이름(`Asia/Seoul`)은 시스템 `date` 로 풀어 macOS 에서만 확인했습니다. 고정 차이(`+09:00`)는 모든 운영체제에서 같습니다. |
| **Gitrochi 자신의 흐름** | `.gitch/flow.yml` 은 검증(`gitch flow validate`) · 계획까지 확인했습니다. 실행에는 사람의 신뢰 승인(`gitch flow trust`)이 필요해 아직 돌리지 않았습니다. |
| **gitch 앞문의 시작 비용** | 특히 Windows Git Bash 에서의 측정은 아직 없습니다. |
