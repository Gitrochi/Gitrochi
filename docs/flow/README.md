# 흐름 (gitch flow)

저장소의 **테스트 · 점검 · 서비스 · 원격 CI · 배포 단계를 블록처럼 조립한 흐름**을, 앱의 흐름 탭 · `gitch flow` · push 전 게이트 · CI 에서 **같은 방법으로** 돌립니다. 판정은 언제나 흐름 엔진(`gitch-flow`, Rust)이 하고, 앱과 gitch 는 사람이 누른 동작을 보내고 결과를 보여 줄 뿐입니다.

- **조립형**: 노드(명령 · 블록 · 스위트 · 하위 흐름)를 `needs` 로 잇는 DAG. 복합 블록(`.gitch/blocks/*.yml`) · 하위 흐름 · 조합(`matrix`)으로 쌓아 올립니다.
- **거짓 통과 없음**: "종료 코드 0" 만 믿지 않습니다. 보고서가 있어야 하고(T2), 테스트가 실제로 돌았어야 하며(T3, 0개 = 실패), 종료 코드와 보고서가 맞아야 합니다(X1). 판정할 수 없으면 실패로 셉니다.
- **어떤 저장소든**: `gitch flow init` 이 파일만 읽어 테스트 도구 · 패키지 관리자 · 런타임 버전을 찾아 흐름 파일을 제안합니다.
- **효율**: 바뀐 파일에 영향받는 테스트만(영향 선택), 같은 입력이면 다시 돌리지 않기(결과 캐시), 병렬 · 잠금 · 무게, 잠금 파일이 그대로면 설치 건너뛰기, AI 용 한 줄 요약.
- **Docker · 원격 CI**: 컨테이너에서 실행(`executor: docker:<이미지>`), 서비스 컨테이너 · compose, GitLab · GitHub · Jenkins · 일반 HTTP CI 운전.
- **되돌림 · 운영 보호**: 바꾸기 전에 되돌림을 등록하고, 실패 · 취소하면 거꾸로 되돌리며, 되돌림이 실패하면 그 환경을 잠급니다(hold). 운영 등급 환경의 파괴적 블록은 기본으로 거부합니다.

> 설계와 결정은 [DESIGN.md](DESIGN.md), 무엇을 어디까지 시험했는지는 [../flow-validation.md](../flow-validation.md).

## 빠른 시작

```bash
gitch flow init            # 감지 결과와 제안(아무것도 쓰지 않음)
gitch flow init --yes      # .gitch/flow.yml 쓰기(있으면 덮어쓰지 않음)
gitch flow trust           # 사람이 명령을 보고 승인(터미널에서만, AI 는 못 함)
gitch flow run pre-push    # 흐름 실행
gitch test --affected      # 영향받은 테스트만 즉석에서
gitch flow gate on         # push 전에 pre-push 흐름 확인(같은 커밋에서 통과했으면 다시 안 돎)
gitch flow export github   # CI 에서 같은 흐름을 도는 워크플로 제안
```

앱에서는 사이드바의 **흐름** 탭: 흐름 목록 · ▶ 실행 · 실시간 진행 · 실패 위치(파일:줄) · 되돌림 · 요약 복사 · push 전 확인 켜기, 흐름 파일이 없으면 **흐름 설정…** 으로 제안을 보고 만듭니다.

## 흐름 파일

`.gitch/flow.yml` (YAML 의 안전한 부분집합: 앵커 · 별칭 · 태그 · 여러 문서는 오류). 겹침 순서는 `flow.yml` ⊕ `flows/*.yml` ⊕ 커밋하지 않는 `flow.local.yml`(init 이 `.gitignore` 에 넣음). 모르는 키는 오류(`x-` 로 시작하면 허용). 스키마: `gitch schema flow`.

```yaml
version: 1
project: { name: shop }
defaults: { timeout: 15m, env: [CI, TZ] }      # env: 노드로 물려줄 호스트 환경 허용 목록

environments:
  local:   { class: dev }
  sandbox: { class: sandbox, executor: "docker:node:22-bookworm" }
  prod:    { class: prod }                     # 파괴적 블록은 사용자 설정 없이는 GUARD-01 로 거부

services:
  db:   { use: docker.service, with: { image: "postgres:16-alpine", ports: ["5432"], env: { POSTGRES_PASSWORD: test }, health: { cmd: "pg_isready -U postgres" } } }
  api:  { use: process.service, needs: [db], with: { run: "npm start", ready: { http: "${{ services.api.url }}/health" } } }
  pay:  { use: mock.http }                     # .gitch/mocks/pay/routes.yml

suites:
  unit:
    use: test.vitest
    select: { affected: true }                 # --affected 일 때 바뀐 것에 영향받는 테스트만
    expect: { minTests: 1, passRate: 1.0 }
    retry: { max: 1, flaky: warn }             # 다시 돌려 통과하면 flaky(기본은 flaky 도 실패)
  smoke: { use: check.http, tags: [smoke], with: { url: "${{ services.api.url }}/health" } }

flows:
  pre-push:
    trigger: [manual, pre-push]
    failFast: true
    nodes:
      install: { use: setup.node }
      lint: npm run lint                       # 문자열 = run 노드
      unit: { needs: [install], suite: unit }
      api-smoke: { needs: [unit], suite: smoke, services: [api] }
  deploy:
    env: sandbox
    rollback: { scope: flow, onCheckFailure: true, timeout: 10m }
    notify: [{ on: failure, webhook: team-hook }]
    nodes:
      image: { use: docker.build }
      push: { needs: [image], use: docker.push, with: { image: "${{ nodes.image.outputs.image }}" } }
      web: { needs: [push], use: deploy.compose, with: { project: shop, service: web, image: "${{ nodes.image.outputs.image }}", health: { url: "http://127.0.0.1:8080/health" } } }
      smoke: { needs: [web], suite: smoke }
```

### 노드

노드는 `run`(셸 명령, `cmd` 블록의 줄임) · `use`(블록) · `suite`(스위트) · `flow`(하위 흐름) 중 하나와 아래 키를 가집니다.

| 키 | 뜻 |
|---|---|
| `needs` | 먼저 끝나야 하는 노드. 하위 흐름 · 복합 블록 · 조합 이름을 쓰면 그 구성원 전부 |
| `if` | `success()` · `failure()` · `always()` · `cancelled()` · `changed('glob')` 과 `&&` `\|\|` `!` |
| `with` · `env` · `secrets` | 블록 입력 · 환경 · 비밀(`secrets: { TOKEN: deploy-token }` — 이름만, 값은 엔진이 찾음) |
| `services` | 이 노드 전에 띄울 서비스(처음 필요할 때 한 번, 실행이 끝나면 언제나 정리) |
| `executor` | `local`(기본) · `docker:<이미지>` — 셸 명령(`cmd` · `test.*`)을 컨테이너에서 |
| `timeout` · `retry` · `expect` | 시간 제한 · 다시 돌리기 · 판정 기대(`exit` · `output` · `minTests` · `passRate`) |
| `cache` | `{ inputs: [glob] }` — 같은 입력이면 이전 통과를 재생(순수한 노드만, 네트워크 · Docker · 원격은 캐시 안 함) |
| `locks` · `weight` · `optional` | 이름 있는 잠금 · 병렬 슬롯 무게 · 실패해도 흐름을 실패로 만들지 않음 |
| `on-failure` | 그 노드가 실패할 때만 도는 노드들(로그 모으기 등) |
| `undo` | run 노드의 되돌림(`"script"` 또는 `{ run, check, timeout, always }`) — 아래 「되돌림」 |
| `matrix` | `{ node: [20, 22] }` → 조합마다 노드 하나(`unit/node-20`), `${{ matrix.node }}` 로 읽음(최대 64) |
| `shell` · `cwd` · `description` | `bash`(기본, Windows 는 Git Bash) · `sh` · `pwsh` · `cmd`, 작업 폴더, 설명 |

표현식 `${{ … }}` 은 **값 참조만** 합니다: `git.sha` · `git.short` · `git.branch` · `run.id` · `node.out` · `inputs.X` · `services.S.host|port|url` · `env.X`(허용 목록만) · `matrix.X` · `nodes.N.outputs.X` · `project.name`. `run` · `undo` 에 들어가는 값은 엔진이 셸 인용해서 넣고(주입 방지), `secrets` 는 `run` · `with` 에 쓸 수 없습니다(`env` · `secrets:` 로만).

### 판정 규칙

| 규칙 | 보는 것 | 실패 코드 |
|---|---|---|
| E1 | 종료 코드(`expect.exit`) · 시간 초과 · 취소 · 멈춤 | EXEC-01~05 |
| T1 · T2 · T3 · X1 | 통과율 · 보고서 있음(이번 실행에 쓴 것만) · 실행 수(0 = 실패) · 종료 코드와 보고서가 맞음 | TEST-01~06 |
| S1~S4 · O1 | 응답 · 빌드 식별자 · 로그 줄 · 없어야 할 로그 · 출력 | VERIFY-01~04 |
| C1 | 원격 CI 의 결과 계약(CI 의 성공/실패 결론은 참고만) | CI-02 · CI-03 |
| M1~M3 · V1 · G3 · G4 · D1 | 모의 서버 호출 · 런타임 버전 · gitch 점검 · 의존 규칙 · 비교 후 교체 | VERIFY-01 · SETUP-01 · GITCH-01/02 · DEPLOY-01 |

판정할 수 없음(INDETERMINATE)은 실패로 셉니다. 실패 코드의 뜻과 조치: `gitch flow explain <코드>`(모두 보기: `gitch flow explain`).

## 효율

- **영향 선택** `--affected[=base|worktree|staged]`: 의존 · 설정 파일(`package.json` · 잠금 파일 · `tsconfig*` · `Cargo.toml` · `.gitch/**` …)이 바뀌면 전부, 아니면 바뀐 테스트 + 이름 관례(`math.ts` → `math.test.ts`) + `gitch graph affected` 의 의존 그래프. 고른 근거와 뺀 이유를 계획에 그대로 적습니다(후보가 없다 ≠ 테스트가 필요 없다 — `alwaysRun` · `smoke` 태그는 언제나). `if: changed('glob')` 도 같은 기준을 씁니다.
- **결과 캐시**: `cache: { inputs: [...] }` 노드는 블록 · 입력 · 환경 · 선택 · 조합 · 실행 위치 · 입력 파일 내용이 같으면 통과를 재생(`--no-cache` 로 끔).
- **준비 블록** `setup.*`: 잠금 파일 · 설치 명령 · 실행 위치가 지난번 성공과 같고 설치 폴더가 있으면 설치를 건너뜀(`force: true`).
- **병렬** `--jobs N`(기본 논리 CPU 수) · `weight` · `locks`. `gitch flow watch <흐름>` 은 저장할 때마다 영향받은 것만.
- **AI 에게** `--summary` 는 결정적인 한 줄 + 실패 위치(`FLOW=FAILED flow=… nodes=… failed=…`). `gitch flow report <실행> --format md|junit|html`.

## 서비스 · 시험 환경

| 블록 | 하는 일 |
|---|---|
| `process.service` | 백그라운드 프로세스(`$PORT` 를 줌) + 준비 확인(`ready: { http · port · log }`) |
| `docker.service` · `compose.up` | 컨테이너 하나(건강 확인 · 포트) · compose 파일(`--wait`). 실행 전용 네트워크, 라벨 `gitch.flow.run` 으로만 정리 |
| `mock.http` | 엔진 안의 결정적 가짜 HTTP 서버: `routes`(`json` · `body` · `file`) + 이름 붙은 **장애 스위치**(`delay` · `status` · `drop`). `.gitch/mocks/<서비스>/routes.yml` 또는 `with` |
| `mock.fault` · `check.mock` | 흐름 안에서 장애 켜고 끄기 · 기대한 호출 수(`count` · `min` · `max` · `contains`)와 표에 없는 요청 |
| `fixture.seed` | 시험 자료 넣기 + 지우기(기본은 실행이 끝날 때마다, `keep: true` 면 실패 · 취소 때만) |
| `check.http` · `check.port` · `check.version` · `check.log` | 스모크의 기본: 응답 · 본문 · JSON 필드 · 포트 · 빌드 식별자 · 서비스 로그 줄 |
| `gate.manual` · `gate.window` | 사람 확인(비대화형이면 종료 코드 2) · 금지/허용 시간대(시간대 명시, 예상 시작 시각으로 미리 거부) |
| `gitch.preflight` · `gitch.graph.check` | gitch 의 커밋 · push 전 점검 · 의존 규칙 |
| `notify.webhook` · `notify.desktop` · 흐름의 `notify:` | 알림 — 보내지 못해도 결과는 바꾸지 않음 |

전체 목록과 입력: `gitch flow blocks` · `gitch flow block <ID>`.

## Docker

- `executor: docker:<이미지>`(노드나 환경): 노드마다 컨테이너 하나(`--rm`, 라벨). **저장소와 실행 폴더를 같은 경로로** 마운트해 보고서 경로 · `GITCH_FLOW_OUT` 이 안팎에서 같고, 환경 값은 이름만 넘깁니다(`-e NAME`, 비밀이 명령줄에 안 보임). 호스트 전용 변수(`PATH` · `HOME` …)는 넘기지 않고, 서비스는 네트워크 별칭(컨테이너 서비스)이나 `host.docker.internal`(호스트 프로세스)로 보입니다. Linux 는 파일이 사용자 소유가 되게 `--user` 로 돕니다. CI 와 같은 이미지를 쓰면 로컬 = CI.
- `docker.run`(일회성 컨테이너, 125 는 docker 자체 실패로 구분) · `docker.build`(태그 `<프로젝트>:<짧은 sha>`, revision 라벨, 빌드 인자는 이름만 — `null` 이면 노드 환경의 비밀값) · `docker.push`(외부 동작, 다이제스트를 출력).
- Docker 가 꺼져 있으면 그 노드만 `DOCKER-01` 로 거부하고 나머지는 계획대로 돕니다. `GITCH_DOCKER` 로 `docker` 대신 다른 CLI(podman 등).

## 원격 CI

```bash
gitch flow connect add gitlab --name company --url https://gitlab.example.com --allow 'pipeline:*'
gitch flow connect add jenkins --name ci --url https://jenkins.example.com --user bot --secret-from env:JENKINS_TOKEN
gitch flow connect test company
```

연결은 저장소 밖(`~/.config/gitsw/flow/connections.json`)에, 토큰은 OS 보관소 · 환경변수(`env:`) · 앱 계정(`app:`) · gh(`gh:`)에서만 꺼냅니다. 블록: `ci.gitlab.pipeline` · `ci.gitlab.job`(수동 작업 ▶) · `ci.github.workflow` · `ci.jenkins.job` · `ci.http`(트리거 · 상태 주소 + JSON 포인터).

모든 어댑터가 지키는 규칙: **상관 ID**(`gitch-<실행>-<노드>`)를 실행 제목 · 변수 · 파라미터에 넣고, **보내기 전에 먼저 찾고**, **응답을 잃은 트리거는 다시 보내지 않고**(찾지 못하면 CI-01, 결과 모름), 마감 안에서 기다리다 마감 · 취소면 원격 취소(CI-05), 우리가 요청하지 않은 취소는 외부 취소(CI-04), 속도 제한(`Retry-After`)을 지키고, 리다이렉트로 다른 호스트에 가면 인증 헤더를 싣지 않습니다. 판정은 **결과 계약**으로: CI 에서 `gitch flow run <흐름> --ci` 가 `gitch-flow-out/gitch-flow-result.json` 과 로그 표식 줄 `GITCH-FLOW-RESULT {…}` 를 남기고, 어댑터는 산출물 → 표식 → (없으면) CI 의 테스트 보고서 순서로 읽습니다. `gitch flow export github|gitlab|jenkins` 가 그런 CI 파일을 제안하고, `gitch flow import` 는 기존 CI 파일에서 흐름을 제안합니다.

## 되돌림 · 운영 보호

- 블록은 대상을 **바꾸기 직전에** 되돌림 단계를 등록합니다(실행 폴더 `undo.ndjson` 에도). run 노드는 `undo:` 로: `migrate: { run: "npm run db:migrate", undo: "npm run db:rollback" }` — 바꾸다 실패해도 부분 변경이 있을 수 있어 되돌림은 언제나 시도하므로, **아무것도 바뀌지 않았을 때도 안전한** 명령이어야 합니다.
- 실패 · 취소하면 서비스를 끄기 **전에** 거꾸로 되돌립니다. 범위 `node`(기본) = 실패한 노드가 바꾼 것만, `flow` = 바꾼 노드 전부(바꾸지 않는 검사 노드의 실패로는 `onCheckFailure: true` 일 때만), 취소 = 전부. `check:` 로 되돌린 뒤 확인, `rollback.timeout` 이 예산. `always: true` 단계는 결과와 상관없이 끝에 도는 정리입니다.
- **되돌림이 실패하면** `ROLLBACK_FAILED` + 그 환경 잠금(hold) — 풀기 전까지 그 환경의 새 실행은 `GUARD-02` 로 거부됩니다. 사람이 상태를 확인하고 `gitch flow hold release <환경>`(AI 는 못 함). 엔진이 강제로 끝난 실행은 다음 실행이 닫습니다: 바꾼 흔적이 있으면 아무것도 되돌리지 않고 잠그고, 없으면 `EXEC-06` 으로.
- `deploy.compose`: compose 서비스 하나의 이미지를 바꿈(이 컴퓨터 또는 `host:` 의 SSH 원격 Docker). 지금 이미지를 관측 → `expectCurrent` 비교 후 교체(DEPLOY-01) → 받기 → 지금 이미지에 되돌림 태그 → 바꿔 띄우기 → 새 이미지로 떴는지 · 건강 확인. 실패하면 태그한 이전 이미지로 되돌리고 확인합니다. DB 스키마는 되돌리지 않습니다(앞으로만).
- 운영 등급(`class: prod`) 환경의 파괴적 블록은 사용자 설정(`~/.config/gitsw/flow/settings.json` 의 `allowProd`)에 그 저장소 · 환경을 적어야만 돕니다. 블록이 허용하지 않는 환경 등급은 `GUARD-03`.

## 신뢰 · AI · 비밀값

- 흐름 파일은 코드라서 **사람이 내용을 보고 승인한 해시와 같을 때만** 비대화형으로 돕니다(`TRUST-01`). 기록은 저장소 밖 `~/.config/gitsw/flow/trust/`. 파일이 바뀌면 다시 묻습니다. CI 러너는 `--ci` + `CI=true` 일 때 예외(AI 실행 주체에는 예외 없음).
- AI 에이전트(Claude Code · Codex · Cursor · Gemini)는 흐름을 계획 · 실행 · 읽을 수 있지만 **신뢰 승인 · 잠금 해제 · 게이트 켜고 끄기를 할 수 없고**, `--yes` 로 사람 확인 단계를 건너뛰려면 사용자 확인을 받습니다(gitch guard).
- 비밀값 찾는 순서: 앱이 표준 입력으로 넘긴 값 → `GITCH_SECRET_<이름>` → (CI) 같은 이름의 환경변수 → OS 보관소. 꺼낸 값과 URL 자격 · 토큰 접두 · JWT · 높은 엔트로피 글자 · 홈 경로는 이벤트 · 로그 · 보고서에서 가립니다.
- 실행 기록(`<git common dir>/gitch/flow/runs/<워크트리>/<실행>/`)은 엔진이 HMAC 으로 서명하고, 게이트는 서명된 기록만 믿습니다.

## 명령

```
gitch flow init|validate|list|plan|run|rerun|watch|status|events|logs|report|cancel|explain|blocks|block
gitch flow trust|hold|gate|connect|export|import|doctor|gc|schema
gitch test [스위트|태그 …] [--affected] [--watch] [--summary]
gitch ci status|logs|report            # 이 저장소의 원격 CI(앱 CI/CD 탭과 같은 일)
```

`--json` 은 기계용(스키마: `gitch schema flow-plan|flow-run|flow-event|flow-report|flow-error`), `--events` 는 NDJSON 이벤트, `--detach` 는 뒤에서 돌고 실행 ID · 이벤트 파일을 줍니다. 종료 코드: 0 통과 · 1 실패 · 2 사람 확인 필요.
