# gitch

여러 Git 계정(GitHub 개인 계정들 + 회사 GitLab)을 한 컴퓨터에서 섞이지 않게 쓰기 위한 도구.
사람이 터미널에서 쓰는 것과 AI(Claude Code, Codex 등)가 쓰는 것을 모두 고려했다.
Gitrochi 맥 앱(`Gitrochi.app/Contents/Resources/gitch`)과 Windows 앱(설치 폴더의 `gitch`, 보통 `%LOCALAPPDATA%\Gitrochi\gitch`)에 함께 들어 있다. © 2026 jjunhaa0211. [Community Use v1.0 제안](../../LICENSE)은 아직 시행되지 않았다. 별도 프로젝트 MIT 라이선스 파일은 제거했으며, 과거 자료의 권리와 필요한 고지는 [통합 고지문](../../THIRD_PARTY_NOTICES.md#prior-mit-covered-gitrochi-material)에 남긴다. 적용 범위와 전환 조건은 [전환 검토 기록](../../docs/licensing-review.md)을 따른다.

- 저장소마다 계정을 **잠그고**, 커밋/push 할 때 작성자·push 주소를 검사한다.
- 폴더 / GitHub 조직 / 주소로 **계정을 자동으로 고른다**.
- 비밀값·큰 파일·강제 push·다른 계정 커밋을 **git 훅에서 막는다** (어떤 도구로 git 을 써도 적용).
- AI 에게는 규칙(CLAUDE.md/AGENTS.md), 스킬, Claude Code 명령 검사 훅을 깔아 준다.
- macOS 기본 bash 3.2 + git 만으로 동작한다 (jq 는 Claude 훅/JSON 요약에만 사용). Windows 는 Git for Windows 의 Git Bash 로 돈다 — 아래 [Windows](#windows).
- gitch 버전은 Gitrochi 릴리스 버전과 같다(현재 `0.3.12`). 예전 CLI 전용 `3.x` 번호는 더 쓰지 않는다.

## 설치

**Gitrochi 에서** — 설정 > CLI
1. 계정이 없으면 **Git 계정 추가** → 앱에서 아이디·이메일·서버·SSH 포트를 입력하고 저장한다. GitHub는 **브라우저 로그인**으로 자동 입력할 수 있고, 그다음 앱에서 SSH 키 준비·공개키 등록·연결 확인을 진행한다. 시작 화면이나 도움말의 **Git 계정 시작하기**에서 전체 안내를 다시 볼 수 있다. 계정 설정과 구조 그래프는 별도 다운로드나 터미널 명령 설치 없이 쓴다.
2. **설치(선택)** → 터미널에서도 gitch를 쓰고 싶으면 무엇이 바뀌는지 확인한 뒤 `gitch install` 을 실행한다(`~/bin/gitch` 가 앱 안의 gitch 를 가리키므로 앱을 업데이트하면 gitch 도 같이 바뀐다). 앱이 응용 프로그램 폴더(`/Applications` 또는 `~/Applications`)에 있어야 한다 — 디스크 이미지 · 다운로드 폴더 · 임시 위치(App Translocation)의 앱에 연결하면 디스크를 꺼내거나 앱을 옮길 때 끊기므로, 앱도 `gitch install` 도 거부하고 옮길 곳을 알려 준다. 터미널에서 `gitch install` 을 직접 실행할 때 계정이 아직 없으면 명령과 터미널 연동만 하고(`gitch g` · `gitch app` 처럼 계정이 필요 없는 명령은 바로 쓴다), 자동 규칙 · 검사 훅 · AI 연동은 계정을 만든 뒤 다시 설치할 때 깐다 — 계정 없이 깔면 모든 저장소의 커밋이 막히기 때문이다.
3. 터미널 명령을 설치했다면 새 터미널을 연다. 앱에서는 저장소 화면의 커밋 칸 위에 이 저장소의 계정(잠금)과 커밋·push 전 점검(`gitch preflight`)이 보이고, 계정 이름을 눌러 이 저장소의 계정을 바꾼다(`gitch use`).

**CLI 만** — 앱 없이 터미널에서 (curl + macOS 기본 bash)

```bash
curl -fsSL https://raw.githubusercontent.com/Gitrochi/Gitrochi/main/tools/gitch/install.sh | bash
~/.local/share/gitch/gitch add       # 계정이 없으면 (터미널에서 사용자가 직접)
~/.local/share/gitch/gitch install   # ~/bin/gitch 연결, 자동 규칙, 검사 훅, AI 연동, 터미널 연동
source ~/.zshrc
```

- [install.sh](install.sh) 는 [릴리스](https://github.com/Gitrochi/Gitrochi/releases)의 `gitch` 와 같은 태그의 `gitch-scip-index`·`gitch-graph-watch`를 각각의 `.sha256`으로 확인한 뒤 `~/.local/share/gitch/`에 함께 둔다. 세 파일을 모두 받은 뒤 검증을 마치고 교체하며, 체크섬이 틀리면 기존 CLI와 도우미를 모두 보존한다. 대상이 다른 파일·링크·폴더이면 덮어쓰지 않고 멈춘다.
- 새 배포본은 `GITCH_HELPER_API=1` 표식으로 두 도우미를 필수로 배포한다. 이 표식이 없는 과거 릴리스에 도우미가 없으면 기본 CLI를 설치하고 정밀 분석·자동 갱신이 제공되지 않는 이유를 안내한다. SCIP·자동 갱신을 실제로 실행할 때는 Python 3가 필요하다.
- `gitch install` 은 `~/.zshrc` · `~/.gitconfig` · `~/.claude` · `~/.codex` 를 바꾸므로 설치기가 하지 않고 할 일만 보여 준다.
- 업데이트: `gitch self-update` — 이렇게 따로 받은 gitch 만 같은 방법으로 바꾼다(바뀐 버전을 보여 줌). 앱에 든 gitch 는 앱과 함께, 저장소의 gitch 는 그 저장소와 함께 바뀐다.
- 예전 `3.x` 독립 설치는 기존 업데이트 코드가 새 `0.x` 번호를 낮은 버전으로 보므로, 위 설치 명령을 한 번 다시 실행해 공통 버전으로 옮긴다. 새 업데이트는 공통 버전에서 옛 CLI 번호로 되돌아가지 않고, 릴리스 태그와 CLI 버전도 확인한다.
- `gitch graph files` 가 Swift 파일 사이 참조를 정확히 읽는 Xcode 인덱스 도우미(`gitch-swift-index`)는 앱에만 들어 있다. 없으면 타입 이름으로 추정하고, 쓰려면 저장소에서 `tools/gitch-swift-index/build.sh ~/bin/gitch-swift-index`(Xcode 또는 Command Line Tools 필요) — [gitch-swift-index](../gitch-swift-index/README.md).

**직접**

```bash
tools/gitch/gitch add          # 계정 추가 (터미널에서 사용자가 직접)
tools/gitch/gitch org add github.com/<조직> <계정>   # (선택) 조직 → 계정 규칙
tools/gitch/gitch install      # ~/bin/gitch 연결, 자동 규칙, 검사 훅, AI 연동, 터미널 연동
source ~/.zshrc
gitch doctor
```

터미널에서 `gitch install` 을 하면 맨 위에 로고(앱 아이콘의 두 눈)가 창 크기에 맞춰 크게·중간·작게(아주 좁으면 이름만) 나오고, 단계(명령 · 터미널 · 자동 규칙 · 검사 훅 · AI 도구)별로 설치한다. 로고는 사람이 보는 터미널에서만 나온다(`GITSW_BANNER=never` 로 끄고 `always` 로 켠다).

새 컴퓨터: `gitch import <내보낸 설정>` → `gitch install` → `gitch setup` (SSH 키 생성·등록).

### Windows

Git for Windows(Git Bash)만 있으면 된다. gitch 는 bash 스크립트라 Gitrochi 도 Git Bash 의 `bash.exe` 로 실행한다.

- **Gitrochi 에서**: 설정 > CLI 는 맥과 같다. 계정 추가 · GitHub 브라우저 로그인 · SSH 키 준비 · 연결 확인 · 설정 검사(`doctor`)를 앱 안에서 진행한다. 암호가 있는 키 등 직접 설정이 필요할 때만 **고급 터미널 설정**으로 새 콘솔 창(Git Bash)을 연다. 터미널 명령 연결은 설치 프로그램으로 깐 Gitrochi(옆에 `uninstall.exe`)만 지원한다 — 포터블 zip · 빌드 폴더에 연결하면 옮기거나 지울 때 끊기므로 앱도 `gitch install` 도 거부한다.
- **CLI 만**: Git Bash 에서 위의 `curl … | bash` 그대로. 다음 안내의 `source ~/.zshrc` 대신 `source ~/.bashrc`.
- `gitch install` 이 맥과 다르게 하는 것
  - `~/bin/gitch` · `~/bin/gitsw`: Git Bash 의 `ln -s` 는 링크 대신 복사본을 만들어서, 대상 경로를 적은 작은 연결 스크립트(`# gitch-link: <경로>` + `exec`)로 만든다. 앱을 업데이트하면 gitch 도 같이 바뀌는 것은 맥과 같다.
  - `~/bin/gitch.cmd` · `gitsw.cmd`: PowerShell · cmd · Codex 에서 `gitch` 로 부르게 Git Bash 로 넘긴다. 사용자 PATH(레지스트리, `%VAR%` 는 그대로)에 `%USERPROFILE%\bin` 이 없으면 넣는다 — `gitch uninstall` 은 gitch 가 넣었을 때만 뺀다.
  - 터미널 연동: `~/.zshrc` 대신 Git Bash 의 `~/.bashrc` (PATH + 프롬프트 마지막 줄 앞에 이 저장소 계정).
  - SSH 설정에 `UseKeychain`(맥 전용 옵션 — Windows 의 OpenSSH 는 모르는 옵션이라 멈춘다)을 넣지 않는다. 공개키 복사 · 페이지 열기는 `clip` · 기본 브라우저.
- Claude Code 검사 훅에는 jq 가 필요하다: `winget install jqlang.jq`

## Gitrochi 앱에서

터미널에서 하는 일을 앱에서도 한다(앱은 같은 gitch 를 실행한다). 아직 앱에 없는 명령은 터미널에서.

| gitch | 앱 |
|---|---|
| `install` · `list` · `doctor` | 설정 > CLI |
| `app` | 앱 자체 — 터미널에서 이 gitch 가 든 Gitrochi(없으면 응용 프로그램 폴더 · Windows 설치 폴더의 앱)를 연다 |
| `add` · `setup` | 설정 > CLI의 계정 추가 · SSH 설정에서 앱 안의 입력 화면과 단계별 안내로 진행한다. 암호가 있는 키 등 직접 설정은 고급 터미널 설정을 쓴다 |
| `login github` | 설정 > 계정 또는 계정 추가 화면의 브라우저 로그인 — 기본 브라우저에서 승인하면 GitHub 계정을 연결한다 |
| `status` · `preflight` | 커밋 칸 위 — 계정(잠금)과 점검 결과, 누르면 점검 항목 · fetch 하고 다시 점검 |
| `use` · `unlock` | 커밋 칸 위 계정 이름 |
| `up` · `sync` · `fix` · `rescue` · `ignore` | 커밋 칸 위 ⋯ 메뉴 |
| `protect` | 사이드바 브랜치 우클릭 — 보호된 브랜치에는 방패 표시 |
| `c` · `p` · `pl` · `b` · `wt` · `pr` · `ci` · `continue` · `abort` | 앱의 커밋 · push · pull · 브랜치 · 워크트리 · PR · CI 화면(앱도 시스템 git 을 써서 gitch 훅이 그대로 걸린다) |
| `graph` · `g` | 저장소 메뉴 › 구조 그래프 — 맥: 툴바의 폴더 아이콘 · 메뉴 막대 Repository, Windows: 툴바의 폴더 아이콘 · ≡ 메뉴. 관계를 고르면 html 을 만들어 기본 브라우저로 연다(아래 「구조 그래프」). 이름으로 부르는 `gitch g my-app` 은 앱에서 그 저장소를 골라 여는 것과 같다 |
| `graph diff` · `graph check` | 같은 저장소 메뉴의 「이 브랜치에서 바뀐 의존」 — 관계를 고르면 기본 브랜치와 갈라진 곳과 비교한 페이지를 연다(「다른 기준과 비교…」로 브랜치 · 태그를 고르면 그것과 갈라진 곳과). 「의존 규칙 검사…」 — 결과 창에 위반 · 경고 목록, 그래프로 보기 · 규칙 고치기, `.gitch/graph.rules` 가 없으면 `--init` 으로 만들지 묻는다. `check --base` · `--lang` · `--no-external` 은 터미널에서 |

## 예전 이름 gitsw

gitch 는 gitsw 의 새 이름이다. 이미 gitsw 를 쓰던 컴퓨터는 `gitch install` 한 번이면 그대로 이어진다.

- `~/bin/gitsw` 도 같은 파일을 가리킨다 — gitsw 로 부르는 AI 규칙·스크립트가 계속 된다(링크가 아닌 파일이면 건드리지 않음).
- 설정·잠금·기록은 예전 이름 그대로 읽고 쓴다: `~/.config/gitsw/config`(`[gitsw]` 섹션), 저장소의 `gitswitch.*`, `~/.local/state/gitsw`, 전역 훅 `hook.gitsw-*`, 백업 `refs/gitsw/backup/*`, 환경 변수 `GITSW_*`, 비밀값 예외 주석 `gitsw:allow`(새 이름 `gitch:allow` 도 됨).
- `gitch install` 이 CLAUDE.md·AGENTS.md 의 규칙 블록, 스킬(`skills/gitsw` → `skills/gitch`), Claude Code 검사 훅과 허용 목록의 `gitsw` 항목을 gitch 로 바꾼다.

## 앱 계정 설정과 CLI API

Gitrochi의 계정 설정은 계정 등록, SSH 공개키 준비, 서버 등록 페이지 열기, 연결 확인을 별도 단계로 진행한다. 계정을 추가해도 SSH 키를 자동으로 생성하거나 서버에 등록하지 않는다. 기존 계정·잠금·전역 작성자와 다른 계정의 SSH 키는 유지한다.

```bash
gitch add --id alice --email alice@example.com --host github.com --no-folder --no-setup --json --yes
gitch setup alice --inspect --json
gitch setup alice --generate --json --yes
gitch setup alice --check --json
```

인자 없는 `gitch add`와 기존 `gitch setup alice`는 터미널 대화형 흐름을 유지한다. 위 인자 기반 API는 앱에서 사용자가 직접 확인한 동작을 실행하는 통로다. AI가 사용자의 명시적인 요청 없이 계정이나 키를 변경하는 통로로 사용하지 않는다.

- 추가 옵션: `--port 2222`, `--folder /절대/경로` 또는 `--no-folder`, `--via 기존계정`. 폴더 옵션을 생략하면 `~/Develop/<id>` 규칙을 등록한다. 규칙 등록 자체가 폴더를 생성하지는 않는다. 호스트는 URL·경로·포트를 섞지 않은 호스트 이름만 받고 SSH 포트는 별도로 받는다.
- `--inspect`는 계정·SSH 별칭·공개키 상태만 읽는다. `--generate --yes`는 앱의 명시적 확인 후 암호 없는 전용 Ed25519 키를 생성한다(`keyProtection: "none"`). 기존 키나 같은 SSH 별칭은 덮어쓰지 않는다. 키에 암호를 넣으려면 기존 터미널 설정 흐름을 사용한다.
- 공개키 복사와 등록 페이지 열기는 사용자가 진행한다. CLI가 웹 서비스에 키를 자동 등록하거나 비밀번호·토큰을 요청하지 않는다. 출력에는 공개키만 있고 개인키·암호는 없다.
- `--check`는 대화형 인증을 끄고 최대 약 13초 안에 끝난다. 새 호스트 키는 기존 gitch 정책대로 처음 연결 시 기록하며, 변경된 호스트 키를 무시하지 않는다. 인증 실패도 `authenticated: false`인 JSON 결과를 표준출력에 쓰고 종료 코드 1을 반환한다.
- 결과는 `schemaVersion: 1`, `account`, `ssh`, `created`를 포함한다. `ssh`에는 `alias`, `keyExists`, `aliasConfigured`, `publicKey`, `publicKeyPath`, `registrationURL`, `authenticated`, `keyProtection`, `message`가 있다. 앱 호환을 위해 주요 필드는 최상위에도 제공한다. `gitch schema account`로 검증할 수 있다. 중복 계정·폴더 충돌·필수 확인 누락은 기존 설정을 바꾸지 않고 구조화된 오류를 반환한다.

GitHub 브라우저 로그인은 공식 [GitHub CLI의 웹 인증](https://cli.github.com/manual/gh_auth_login)을 사용한다. 앱에서 로그인 버튼을 누르면 `gitch login github --start --json --yes`가 즉시 `pending` 세션을 반환한다. 앱은 응답의 `verificationURL`을 열고 `--status SESSION --json`으로 일회용 코드와 결과를 읽는다. `--cancel SESSION --json`은 해당 세션만 취소한다. 다른 계정의 인증을 종료하거나 로그아웃하지 않는다. 동시에 요청한 로그인은 GitHub CLI의 계정 저장이 충돌하지 않도록 순서대로 진행한다.

응답은 `schemaVersion`, `tool`, `session`, `state`, `deviceCode`, `verificationURL`, `login`, `email`, `message`를 포함한다(`gitch schema login`). `state`는 `pending`, `complete`, `failed`, `cancelled` 중 하나다. 완료 전 `login`과 `email`, 코드 발급 전 `deviceCode`는 `null`이다. 공식 완료 로그의 계정 이름과 그 계정 전용 자격 증명의 API 응답이 일치해야 완료된다. 이메일은 검증된 기본 이메일만 사용하고 없으면 GitHub noreply 주소를 제공한다. 토큰·원본 인증 로그는 응답하지 않는다. 앱이 완료 계정과 일치하는 자격 증명을 가져온 뒤 사용자가 계정 등록·SSH 키 생성·공개키 업로드를 진행한다.

로그인 세션은 사용자 전용 상태 폴더에 저장하며 15분 후 중단된다. 완료한 세션 중 하루 지난 항목을 다음 시작 때 최대 32개 검사해 정리한다. GitHub CLI가 없으면 설치 링크를 포함한 `GITHUB_CLI_MISSING` 오류를 반환한다. 앱의 도구 설정 경로는 `GITCH_GH`로 전달할 수 있고, 다음으로 `GH_PATH`, `PATH`의 `gh`를 사용한다. 이 API를 검증하는 테스트는 가짜 GitHub CLI와 임시 HOME만 사용한다.

## 개념

| 이름 | 뜻 |
|---|---|
| 계정 | 커밋 작성자(이름/이메일) + 서버 목록. `host = github.com` / `host = gitlab.example.com:2222` |
| 별칭 | 계정마다 SSH 별칭(`github-<계정>`, `gitlab-<계정>`)과 키(`~/.ssh/id_ed25519_<계정>`)를 쓴다 |
| 잠금 | `gitch use/clone` 이 저장소에 계정을 기록(`gitswitch.account`)하고 주소를 별칭으로 바꾼다 |
| 자동 규칙 | 폴더(`~/Develop/<계정>`), 조직(`github.com/<조직>`), 주소 소유자, 서버(계정이 하나뿐인 서버)로 계정을 고름 |
| 검사 훅 | git 전역 설정 훅(`hook.gitsw-*`) + 저장소 보조 훅(Apple git 대비) |

계정 판단 순서: 잠금 → 주소 소유자 → 조직 규칙 → 폴더 기본 → 주소 별칭 → 서버에 계정이 하나뿐.

## 매일 쓰는 명령

```bash
gitch app                  # Gitrochi 데스크톱 앱 열기
gitch preflight            # 커밋/push 전 한 번에 점검 (PREFLIGHT=OK|WARN|STOP)
gitch ck                   # 바뀐 파일 / push 안 한 커밋 / 받을 커밋 / 진행 중 rebase 등
gitch c -m "제목" -m "본문"  # 커밋 (-a 전부, -F 파일, --trailer "키: 값")
gitch p                    # push (--force 는 확인 후 --force-with-lease)
gitch cp -a -m "..."       # 커밋 + push
gitch pl                   # pull --rebase --autostash
gitch up                   # 기본 브랜치 최신을 지금 브랜치에 (push 전 rebase, push 후 merge)
gitch pr --title "..."     # GitHub PR / GitLab MR (브라우저 없이)
gitch pr status / gitch ci
gitch continue / abort     # 충돌난 rebase/merge
gitch rescue               # pl/up/sync/fix/undo/amend 전에 자동으로 남긴 백업으로 복구
gitch clone [계정] <주소>   # 계정 자동 선택 + 계정 폴더에 받기 + 잠금
gitch publish [이름]       # 원격이 없는 새 저장소를 GitHub/GitLab 에 비공개로 만들고 첫 push
gitch scan [--fix]         # ~/Develop 아래 저장소 전체 점검
gitch report --today       # 오늘 누가(사람/claude/codex) 어디에 무엇을 커밋/push 했나
```

`gitch help` 에 전체 명령이 있다. `--json` 은 status / ck / preflight / scan / doctor / list / audit / report / graph 에 있다.

종료코드: 0 정상, 1 문제/실패, 2 사용자 확인 필요(`--yes`), 3 커밋할 것 없음, 4 올릴 파일을 고르지 않음(비대화형).

### 앱 열기 (`gitch app`)

```bash
gitch app
gitch app .                         # 현재 저장소를 앱 탭으로
gitch app my-project                # 계정 폴더에 있는 저장소 이름
gitch app --repo ~/code/project --file src/main.ts --line 25
gitch app . --commit <전체커밋해시> --file src/main.ts # 해당 커밋의 파일 diff
gitch app . --view affected          # 변경의 영향을 받는 파일
gitch app . --view precise           # 저장소에 있는 SCIP 인덱스로 정밀 참조
gitch app --path "/Applications/Gitrochi.app" # macOS: 앱을 직접 지정
gitch app --path 'C:\Apps\Gitrochi\Gitrochi.exe' # Windows
```

macOS · Windows에서 동작한다. 앱에 동봉된 CLI는 그 앱을 열고, 이 소스 저장소의 CLI는 개발 빌드를 먼저 찾는다. 그 밖에는 사용자·시스템 설치 위치를 찾는다. `gitch o`는 저장소의 웹 페이지를, `gitch app`은 데스크톱 앱을 연다. 앱이 없거나 지정한 경로가 틀리면 설치·경로 지정 안내를 표시한다.

`--file` 은 저장소 안의 상대 경로다. 파일만 지정하면 히스토리, `--line` 을 함께 지정하면 blame 의 실제 줄로 이동해 강조한다. 변경한 파일의 작업 diff 는 `--view diff` 로 연다. 이미 앱이 실행 중이면 같은 저장소의 탭을 재사용한다. `--view files|modules|changes|tree` 는 앱의 구조 그래프 메뉴와 같다. 정밀 분석에는 최신 `index.scip` 또는 `.gitch/index.scip` 이 필요하며, 없으면 분석 범위 안내와 기존 분석을 보여 준다.

구조 그래프의 파일·근거 줄·근거 커밋 링크는 `gitrochi://open?repo=<절대경로>&file=<상대경로>&line=<양의정수>&commit=<전체해시>&view=<보기>` 를 사용한다. 쿼리 값은 UTF-8 퍼센트 인코딩한다. `repo` 는 필수이며 그 밖의 값은 선택이다. 저장소 밖 경로·중복 쿼리·잘못된 커밋 해시를 거부한다. Windows 의 브라우저 링크 등록은 설치 프로그램에 포함된다. CLI 의 앱 직접 실행은 설치 등록 없이도 전달된다.

## 구조 그래프 (`gitch graph`)

`tuist graph` 처럼 저장소의 구조와 관계를 그린다. 사람은 그림(html · svg · png)으로 보고, AI · 스크립트는 JSON 으로 읽는다. 추적하는 파일(`git ls-files`)만 본다.

```bash
gitch graph                                  # 파일 import — 터미널이면 html 을 만들어 브라우저로 연다
gitch g                                      # graph 의 짧은 이름 (diff · check 도 gitch g diff · gitch g check)
gitch g my-app                               # 어디서든 이름으로: 계정 폴더 바로 아래(없으면 한 단계 더)의 저장소, 대소문자 무시
gitch g alice/my-app                         # 이름이 겹치면 계정/이름 — 저장소 밖에서 그냥 gitch g 면 계정 폴더의 저장소를 알려 준다
gitch graph modules                          # 모듈/타깃 의존
gitch graph changes --since "6 months ago"   # 같이 바뀌는 파일 · 핫스팟
gitch graph tree --depth 2                   # 폴더 크기 · 파일 수
gitch graph files src/feature                # 그 폴더 아래만 (폴더 밖 대상은 outside: true)
gitch graph --lang java,ts,python             # 언어 이름·확장자·별칭으로 선택 (C++ · C# · PHP · Ruby 등, 쉼표로 여럿)
gitch graph modules --lang java              # Maven(pom.xml) · Gradle 모듈과 의존
gitch graph modules --lang python            # pyproject.toml · requirements.txt 등의 패키지와 의존
gitch graph --json | jq -r '.edges[] | select(.target == "src/api/client.ts") | .source'   # 이 파일을 쓰는 곳
gitch graph modules --out deps.png           # graphviz(dot) 로 그림
```

| 관계 | 보는 것 | 노드 · 연결 |
|---|---|---|
| `files` (기본) | 파일 → 파일 import | 파일, 저장소 밖 패키지(`pkg:npm/react`), Swift 모듈(`module:SwiftUI`), Go 패키지 폴더(`internal/store/`) |
| `modules` | 모듈/타깃 의존 | `swift:App` · `tuist:App` · `npm:@acme/ui` · `cargo:core` · `go:example.com/x/api` · `gradle::app` · `maven:com.example:core` · `pypi:demo` · `dotnet:App.csproj` · `composer:example/app` · `gem:app` · `pub:demo` · `cmake:core`, 연결의 `scope`(`devDependencies` · `testImplementation` …) |
| `changes` | 한 커밋에 같이 바뀐 파일 쌍과 바뀐 횟수(핫스팟) | 파일(`changes` · `lastChanged`), 연결 `weight` = 같이 바뀐 커밋 수 · `degree` = 두 파일 바뀐 횟수 평균에 대한 % |
| `tree` | 폴더 구조와 크기 | 폴더(`files` · `bytes` · `filesHere` · `dirs` · `exts`), `--files` 면 파일도 |

파일 인식·CLI 필터·HTML 언어 메뉴는 같은 언어 목록을 쓴다. Java · TS/JS · Python · Swift · Go · Rust · Kotlin · Scala · Groovy · C/C++ · Objective-C/C++ · C# · F# · Visual Basic · PHP · Ruby · Dart · Lua · Shell · PowerShell · Perl · R · Julia · Elixir · Erlang · Haskell · Clojure · OCaml · Elm · Nim · Zig · D · Fortran · Pascal · Ada · COBOL · Lisp · Scheme · Racket · SQL · GraphQL · Protocol Buffers · Solidity 등 70여 종을 파일 노드로 표시한다. HTML/CSS · JSON/YAML/TOML/XML · CMake · Dockerfile 등도 포함한다. 클래스 하나가 노드인 UML 그래프는 아니며, 파일이 노드이고 일부 언어에서 클래스·타입 이름을 파일 사이 참조의 근거로 쓴다.

HTML 언어 메뉴는 실제 인식한 언어를 각각 보여 준다(TypeScript/JavaScript, Java/Kotlin도 각각 선택). 색을 주는 상위 세 계열과 언어 선택은 별개라, 회색으로 그리는 언어도 따로 고를 수 있다. 폴더로 묶어도 그 언어가 들어 있는 폴더를 남긴다. `--lang` 은 언어 이름·확장자·별칭(`typescript`, `py`, `c++`, `c#` 등), `web` · `jvm` 묶음을 받는다.

`files` 에서 의존 선언까지 읽는 것(그 밖의 언어는 파일·줄 수를 표시):

| 언어 | 읽는 문장 | 잇는 곳 |
|---|---|---|
| TypeScript/JavaScript | `import` · `export … from` · `require()` · `import()` | 상대 경로(확장자 · `index` · `.js` 로 쓴 `.ts`)와 tsconfig `paths` · `baseUrl` 은 파일, 그 밖은 패키지 |
| Python | `import` · `from … import` (상대 포함) | 모듈 파일 · 패키지(`__init__.py`), 못 찾으면 패키지 |
| Go | `import` | `go.mod` 의 모듈 안이면 패키지 폴더, 밖이면 모듈(`require` 기준) |
| Rust | `mod` · `use crate::/self::/super::` · 다른 crate | `a.rs` · `a/mod.rs`, 같은 저장소 crate 는 그 crate 의 파일 |
| Kotlin/Java | `package` + `import` | 그 이름을 선언한 파일. 같은 패키지 타입은 import 없이 쓰므로 이름으로 추정 |
| C/C++ · Objective-C/C++ | `#include` · `#import` | 같은 폴더 · 저장소 루트 · `include/` 의 추적 파일, 못 찾은 시스템 헤더는 외부 노드 |
| Ruby · PHP · Lua · Shell | 정적인 `require` · `require_relative` · `include` · `source` | 추적하는 경로, 못 찾은 패키지는 외부 노드(상대 경로는 미해결 수로 표시) |
| Dart · Protocol Buffers · Solidity | `import` · `export` · `part` | 상대 경로는 파일, Dart `package:` · `dart:` 등은 외부 노드 |
| CSS · SCSS · Less | 문자열로 쓴 `@import` · `@use` · `@forward` | 파일(SCSS `_partial` 포함), 못 찾으면 외부 노드 |
| Swift | 파일끼리 import 가 없다 | 다른 파일에 선언된 최상위 타입(class · struct · enum · protocol · actor · typealias) 이름을 쓰면 추정, `import 모듈` 은 모듈 노드. Tuist(`Project.swift` 의 `sources` · 도우미 매니페스트는 `Sources/**` · `Tests/**`) · SwiftPM 으로 파일의 모듈(`modules`)을 정해, 같은 모듈이거나 import 한 모듈의 공개(public · open · package) 타입만 잇는다(`@testable import` 면 internal 도) |

- 추정한 연결은 JSON 에 `"heuristic": true`, 그림에서는 점선이다. 같은 두 파일에 정확한 연결이 있으면 더하지 않는다. 주석 · 문자열 속 이름과 `private` 타입은 세지 않는다. 모듈(Swift) · 패키지(Kotlin/Java)로 확인한 추정은 `"checked": true` 다.
- Swift 의 정확한 참조는 Xcode 인덱스에 있다. 앱이 gitch 옆에 두는 도우미 `gitch-swift-index`(또는 `GITCH_SWIFT_INDEX` 에 적은 실행 파일, 빈 값이면 끔, 그다음 `PATH`)가 있으면 `gitch-swift-index --repo <저장소> --covered <파일>` 의 `원본<TAB>대상<TAB>심볼,…` 줄을 정확한 연결(`"kind": "ref"`)로 쓰고, `--covered` 에 적힌(인덱스에 든) 파일은 추정하지 않는다 — 빌드하지 않은 타깃 · 빌드 뒤 새 파일은 그대로 이름으로 추정한다(목록을 쓰지 않으면 모두 든 것으로). 성공해도 표준오류 첫 줄(오래된 인덱스 경고 등)은 notes 에 적고, 3 으로 끝나면(인덱스 없음 — Xcode 로 한 번 빌드) 추정으로 돌아간다.
- 도우미가 인덱스를 찾는 곳(DerivedData · 저장소 안 `.build`), 쌍의 이름, 오래된 인덱스 경고, 옵션은 [gitch-swift-index](../gitch-swift-index/README.md) 에.
`modules` 가 읽는 매니페스트:

| 생태계 | 설정 파일 | 모듈 · 의존 |
|---|---|---|
| TS/JS · Web | `package.json` | npm 패키지·작업공간, dependencies · dev/peer/optionalDependencies. JSON의 줄 배치·들여쓰기와 무관하게 읽는다 |
| Java · Kotlin · Scala · Groovy | `pom.xml`, `settings.gradle(.kts)`, `build.gradle(.kts)` | Maven 좌표·같은 저장소 패키지·scope, Gradle 하위 프로젝트·외부 라이브러리. settings 없는 단독 Gradle 프로젝트와 의존 없는 루트도 표시 |
| Python | `pyproject.toml`, `requirements*.txt/in` · `requirements/*.txt/in`, `setup.cfg`, `Pipfile` | 프로젝트/Poetry 이름·의존·선택 의존·개발 그룹, requirements의 `-r`, 같은 저장소의 정규화한 패키지 이름은 내부 연결 |
| C# · F# · VB | `*.csproj/fsproj/vbproj` | .NET 프로젝트, `ProjectReference`는 내부 연결, `PackageReference Include`는 NuGet 노드 |
| PHP | `composer.json` | Composer 이름, require · require-dev, 같은 저장소 패키지는 내부 연결 |
| Ruby | `Gemfile`, `*.gemspec` | 패키지 폴더, 정적으로 쓴 gem · runtime/development 의존 |
| Dart | `pubspec.yaml` | Pub 패키지, dependencies · dev_dependencies, 같은 저장소 이름은 내부 연결 |
| C/C++ · Objective-C/C++ | `CMakeLists.txt` | add_library · add_executable 타깃, target_link_libraries 내부·외부 연결 |
| Swift · Rust · Go | `Package.swift`, `Project.swift`, `Cargo.toml`, `go.mod` | 아래 설명의 기존 모듈·타깃·패키지 분석 |

매니페스트는 실행하지 않고 정적인 선언을 읽는다. Maven dependencyManagement·빌드 플러그인의 의존은 앱의 직접 의존으로 추가하지 않고, .NET Update 항목도 새 의존으로 세지 않는다. 빌드 중 계산되는 값, 복잡한 조건·상속·매크로, 모든 언어의 패키지 관리자를 완전히 해석하지는 않는다. 언어 파일 인식과 모듈 매니페스트 지원은 별개이며, 연결 선언이 없는 모듈도 노드로 표시한다.

- `modules`: Package.swift 는 `swift package describe --type json` 으로 읽고(매니페스트를 컴파일해서 몇 초), 안 되면 파일을 직접 읽는다(`GITSW_SWIFT_DESCRIBE=0` 이면 늘 직접). Tuist 는 Project.swift 의 Target 선언과 의존(`.target` · `.project` · `.external` · `.package` · `.sdk`)을, 도우미 함수로 만든 매니페스트(`Project.module(…)`)는 파일 안의 참조를 모은다. 그 밖에 모든 package.json(작업 공간 구성원은 `workspace`), Cargo 의 `path` · `workspace = true` 의존, Go 패키지 사이 import, Gradle 의 `include` · `project(":x")` · `projects.x`.
- `changes`: `--since 날짜` · `--max-commits N`(기본 1000) · `--max-files N`(기본 30, 더 큰 커밋은 쌍이 너무 많아 뺀다) · `--min N`(기본 2). merge 커밋과 lock 파일은 뺀다. 합쳐진 브랜치의 일반 커밋은 포함하며, 같은 커밋을 한 번만 센다.
  - Git의 rename 감지를 따라 이름 변경 전 변경도 현재 추적 경로에 합친다. 다른 폴더에서 옮겨 온 파일도 놓치지 않게 `--max-commits`는 저장소 전체의 일반 커밋에 적용하고, 그 뒤 현재 경로의 폴더·언어를 거른다. 큰 커밋을 통계에서 빼더라도 그 커밋의 rename은 계보에 적용한다. Git이 rename으로 감지하지 못한 삭제·추가는 별도 파일로 남는다.
  - 파일을 삭제한 뒤 같은 이름으로 새로 만들면 옛 파일의 이력을 물려받지 않는다. 복사한 파일도 원본 이력을 물려받지 않는다. revert는 실제 수정 작업이므로 독립적인 변경 커밋으로 센다. 현재 삭제된 파일은 노드에 포함하지 않는다.
  - 연결의 `commitCount`는 전체 근거 수이고, `commits`에는 최신 근거 최대 20개의 전체 SHA·커미터 일시·제목이 들어간다. `commitsTruncated`가 참이면 그 밖의 근거가 더 있다. 이 연결은 코드 참조의 증명이 아니라 함께 수정된 작업의 관측이다(`method: "git-history"`).
  - `stats.historyFrom/historyTo`는 선택한 커밋 전체의 실제 커미터 일시 범위, `analyzedFrom/analyzedTo`는 필터와 큰 커밋 제외 후 파일 변경을 센 범위다. `commits`는 선택한 수, `analyzedCommits`는 그중 파일 변경을 센 수, `skippedLargeCommits`는 큰 커밋 제외 수다. `historyTruncated`는 `--max-commits` 뒤에 실제 커밋이 더 있을 때만 참이며, `shallowHistory`는 얕은 복제로 로컬 이력이 불완전함을 알린다. 탭·줄바꿈 등 레코드 구분 문자가 든 경로는 제외하고 `skippedHistoryPaths`에 센다.
  - 설계 참고: [CodeCharta의 Git Log Parser](https://codecharta.com/docs/parser/git-log/)의 현재 파일·rename 이력 처리와 [Code Maat](https://github.com/adamtornhill/code-maat)의 기간·최대 변경 집합 크기·공유 변경 수 기준을 이 CLI의 필터와 출력에 맞춰 적용했다. 코드를 가져오거나 외부 실행 파일을 요구하지 않는다.
- `--no-external` 은 저장소 밖 패키지 · 모듈을 뺀다. `--lang` 은 고른 언어의 파일(modules 는 그 언어의 생태계)만 남기고, JSON 의 `lang` 에 적는다.
- 파일마다 프로세스를 띄우지 않고 awk 한 번에 읽는다. 파일 21,000개(150만 줄) 저장소의 `files` 가 Apple Silicon 맥에서 7초 안팎, `modules` · `changes` · `tree` 는 1초 안이다.

| 형식 | |
|---|---|
| 기본 | 사람이 보는 터미널이면 `html` 을 만들어 열고, 아니면(스크립트 · AI) `json` 을 표준출력. `--format` 이나 `--out` 의 확장자(`.json` · `.html` · `.svg` · `.png` · `.dot`)로 바꾼다 |
| `html` | Gitrochi 앱 아이콘의 느낌을 따른 오프라인 한 페이지(CDN 없음): 검정 화면(밝게는 흰 화면, 회색은 모두 무채색), git 노드처럼 가운데가 빈 은색 고리(가장 많은 언어는 은색, 다른 언어만 색), 고른 것은 초록 빛. 네 관계를 모두 담아 위 탭(파일 · 모듈 · 같이 바뀜 · 폴더, 키 1~4)으로 바꾸고, 단위(파일 · 폴더 1~8단계로 묶기) · 언어 · 그리기(점 = 옵시디언 그래프 보기, 상자 = tuist graph 같은 다이어그램)를 고른다. 배치는 힘 · 층(위 → 아래, 모듈 탭 기본) · 나무(왼쪽 → 오른쪽, 폴더 탭 기본) · 방사형 · 폴더 원이고, 노드와 상자가 겹치지 않게 놓는다(이름은 겹치면 그리지 않는다). 폴더 원은 폴더마다 원, 그 안에 파일(넓이 = 줄 수)을 채운 것으로, 멀리서는 폴더가 접힌 원 하나(파일 수 · 비교의 +/−)로 보이고 가까이 가거나 누르면 그 자리에서 펼쳐진다. 접힌 폴더끼리의 연결은 합쳐서 굵기로, 공통 폴더 쪽으로 휘어 묶인다. 노드가 600개를 넘는 파일 · 같이 바뀜 탭은 폴더 원으로 시작한다. 찾기(`/`), 설정 창(필터 · 묶음 · 표시 · 힘), 표로 보기(정렬), 지금 화면을 PNG 로 저장, 어둡게 · 밝게(기억) |
| `html` 비교 · 규칙 | `gitch graph diff --format html` 은 새로 생긴 노드 · 연결을 초록, 없어진 것을 빨간 점선으로(「바뀐 것만」이 기본), 분석 창 맨 위에 새 순환 · 없어진 순환 · 더한 연결 · 뺀 연결. 규칙 파일이 있으면 어긴 연결을 빨갛게, 분석 창에 「규칙 위반」 |
| `html` 분석 (`A`) | 순환 의존 · 가장 긴 의존 사슬 · 많이 쓰이는 것 · 많이 쓰는 것 · 많이 쓰이는데 불안정한 것 · 아무도 안 쓰는 것 · 많이 쓰는 외부 패키지 · 폴더 사이 연결 · 핫스팟(바뀐 횟수 × 줄) · 숨은 결합(같이 바뀌는데 import 는 없음). 폴더 탭은 큰 폴더 · 파일이 바로 많이 든 폴더 · 가장 깊은 경로 · 자주 바뀌는 폴더 · 확장자, 같이 바뀜 탭은 자주 같이 바뀌는 쌍. 줄을 누르면 그래프에서 강조한다(`Esc` 로 풀기) |
| `html` 노드 | 누르면 들어옴 · 나감 · 불안정도 · 영향 범위(바꾸면 흔들리는 것 전부) · 전체 의존 · 순환과, 가져오는 것 · 가져다 쓰는 곳(폴더면 안의 파일) 목록. 단추로 영향 범위 보기 · 전체 의존 보기 · 경로 찾기(다음에 누른 노드까지 가장 짧은 길) · 주변만(로컬 그래프). 색은 언어 · 종류(모듈: 앱 · 라이브러리 · 테스트) · 바뀐 횟수, 크기는 연결 · 줄 · 바뀐 횟수. 언어 색은 노드가 많은 계열 셋에만 주고 나머지는 회색(언어 메뉴에서는 모두 각각 선택 가능) — 색 세 가지를 넘으면 서로 잘 구별되지 않는다 |
| `svg` · `png` | graphviz 의 `dot` 으로 그린다(`brew install graphviz`, Windows 는 `winget install Graphviz.Graphviz`, 없으면 그렇게 알린다). `--format dot` 은 DOT 원문 |
| 저장 | `--out 파일`(`-` 는 표준출력). 없으면 html · svg · png 는 `$TMPDIR/gitch-graph/<저장소>-<관계>.<형식>`. 파일로 쓰면 끝에 `GRAPH_FILE=… NODES=… EDGES=…` |

### 커밋할 변경의 영향 보기

macOS와 Windows의 커밋 화면에서 **스테이지 변경 검토 → 분석**을 누르면 현재 HEAD와 스테이지 내용을 비교한다. 작업 트리에만 남은 수정과 미추적 파일은 제외하고 변경 파일, 직접·간접 확인 대상, 관련 테스트 후보, 해석하지 못한 변경 파일 수를 보여 준다. 테스트 후보는 정적 의존 경로나 파일 이름으로 추정한 것이며 테스트 실행 결과가 아니다.

```bash
gitch g review --json
gitch g review --stamp --json
gitch g review --format html --out staged-review.html --no-open
```

`stamp`는 HEAD와 스테이지의 경로·파일 내용으로 만든 식별자다. 같은 경로를 다시 stage하거나 HEAD가 바뀌면 앱이 결과를 오래된 것으로 표시한다. 인덱스의 stat 정보 갱신이나 스테이지하지 않은 수정에는 바뀌지 않는다. 분석 시작·종료 시 식별자가 다르면 JSON의 `stale`이 참이다. 첫 커밋도 빈 기준 상태와 비교하며, 충돌 중인 인덱스는 분석하지 않는다. **스테이지 그래프 열기**도 같은 staged 범위를 사용한다.

### 브랜치 구조 변화 재생

`gitch g diff main --format html` 또는 앱의 **이 브랜치에서 바뀐 의존**으로 연 비교 페이지에서 **구조 변화 재생**을 누른다. 파일·모듈 그래프의 기준 상태에서 현재 상태로 노드와 연결이 등장하거나 사라지는 과정을 고정된 배치에서 확인한다. 이름 변경은 같은 노드의 이름 전환으로 표시한다.

처음·끝, 위치 슬라이더, 재생·일시정지, 속도(0.5×·1×·2×), 반복을 제공하고 검색·언어 필터도 유지한다. 운영체제의 동작 줄이기가 켜져 있으면 슬라이더로 시점을 직접 고른다. 재생을 닫으면 이전 배치로 돌아간다. 두 분석 스냅샷 사이의 전환이며, 중간 커밋 이력을 재구성하는 기능은 아니다.

JSON (노드 · 연결이 한 줄에 하나):

```json
{
  "tool": "gitch graph",
  "version": "0.3.12",
  "relation": "files",
  "directed": true,
  "repo": "app",
  "scope": "",
  "lang": null,
  "commit": "872fcdd",
  "generated": "2026-10-24T10:56:55+0900",
  "stats": {"nodes":6,"edges":4,"heuristicEdges":1,"languages":{"swift":2,"ts":2},"unresolved":0},
  "notes": ["Swift: 파일끼리 import 하지 않아서, … 연결로 추정했습니다 (heuristic: true, 그림에서는 점선)."],
  "nodes": [
    {"id":"Sources/Feed/FeedModel.swift","kind":"file","label":"FeedModel.swift","group":"swift","path":"Sources/Feed/FeedModel.swift","lang":"swift","lines":1},
    {"id":"Sources/Feed/FeedView.swift","kind":"file","label":"FeedView.swift","group":"swift","path":"Sources/Feed/FeedView.swift","lang":"swift","lines":6},
    {"id":"module:SwiftUI","kind":"module","label":"SwiftUI","group":"module","name":"SwiftUI"},
    {"id":"pkg:npm/react","kind":"package","label":"react","group":"package","ecosystem":"npm","name":"react"},
    {"id":"src/App.tsx","kind":"file","label":"App.tsx","group":"ts","path":"src/App.tsx","lang":"ts","lines":2},
    {"id":"src/api/client.ts","kind":"file","label":"client.ts","group":"ts","path":"src/api/client.ts","lang":"ts","lines":1}
  ],
  "edges": [
    {"source":"Sources/Feed/FeedView.swift","target":"Sources/Feed/FeedModel.swift","kind":"type-ref","weight":1,"heuristic":true,"via":["FeedModel"]},
    {"source":"Sources/Feed/FeedView.swift","target":"module:SwiftUI","kind":"import","weight":1},
    {"source":"src/App.tsx","target":"pkg:npm/react","kind":"import","weight":1,"via":["react"]},
    {"source":"src/App.tsx","target":"src/api/client.ts","kind":"import","weight":1,"via":["./api/client"]}
  ]
}
```

연결 `kind`: `import` · `reexport` · `require` · `dynamic-import` · `mod` · `use` · `type-ref`(추정) · `ref`(Xcode 인덱스) · `contains` · `depends` · `cochange`. `via` 는 근거(import 한 글 · 쓴 타입 이름, 다섯 개까지), `weight` 는 횟수다.

### 자동완성 · 공개 JSON 계약

[GitHub CLI의 completion 명령](https://cli.github.com/manual/gh_completion)처럼 필요한 셸 스크립트를 생성한다. 명령·옵션뿐 아니라 등록 계정, 현재 저장소 브랜치, 그래프 언어와 계정 폴더 안 저장소 이름을 동적으로 완성한다. 후보 조회는 로컬 읽기만 하며 후보 문자열을 실행하지 않는다. 공백·따옴표가 있는 이름은 셸이 인자 하나로 넘기도록 처리한다.

```bash
source <(gitch completion bash)  # Bash
autoload -Uz compinit && compinit
source <(gitch completion zsh)   # Zsh
```

Fish는 `gitch completion fish | source`, PowerShell은 `gitch completion powershell | Out-String | Invoke-Expression`으로 현재 세션에 적용한다. 계속 쓰려면 생성한 스크립트를 각 셸의 설정에서 불러온다. 이 명령은 설정 파일을 직접 바꾸지 않는다.

```bash
gitch g languages --json        # 73종 각각의 실제 분석 깊이
gitch version --json            # 앱과 맞춘 제품 버전과 JSON/그래프 API 버전
gitch schema                   # 전체 공개 JSON Schema (Draft 2020-12)
gitch schema graph             # 그래프 출력에 적용할 자체 완결형 스키마
gitch schema error             # 기계 출력 요청 중 치명적 오류의 스키마
```

`languages`의 `fileDetection`은 파일 인식, `staticImports`는 정적으로 읽는 import/include, `heuristic`은 타입 이름 추정 지원을 뜻한다. `manifests`와 `ecosystem`은 모듈 분석 범위다. `preciseBackend`는 제공된 인덱스를 읽는 선택적 통로다. SCIP는 해당 언어의 별도 인덱서가 만든 인덱스가 있어야 하며, SwiftIndex는 Xcode 인덱스 도우미가 있어야 한다. 이 목록이 모든 언어의 컴파일러·클래스 분석기가 기본 내장됐다는 뜻은 아니다.

[공개 스키마 파일](schema/gitch-v1.schema.json)은 CLI에 내장된 스키마와 동일하다. 스키마 이름은 `graph`, `error`, `languages`, `status`, `ck`, `preflight`, `rules`, `version`, `list`, `doctor`, `scan`, `audit`, `report`, `pr`, `view`, `watch`, `index`, `account`, `login`이고 기본 `public`은 이 모두를 허용한다. `view`는 저장·내보낸 화면 설정, `watch`는 감시 서버 설명과 상태 응답, `index`는 인덱서 생성 안내, `account`는 앱 계정 설정 결과, `login`은 브라우저 인증 세션이다. 객체 출력에는 `schemaVersion: 1`을 더하고 기존 필드를 유지한다. `report --json`의 기존 배열은 그대로 유지하며 문서의 스키마 버전으로 검증한다. 새 필드는 추가할 수 있으므로 읽는 쪽은 모르는 필드를 무시한다. 필드 제거·의미 변경은 스키마 버전을 올려 구별한다. 제품 버전 `0.3.12`과 스키마 버전은 별개다.

`--json` 또는 `--format json`을 명시했을 때 인자·사전조건의 치명적 오류는 결과를 표준출력에 쓰지 않고 표준오류에 `{"schemaVersion":1,"error":{"code":"GITCH_ERROR","message":"…","exitCode":1}}`을 쓴다. 비대화형 확인 필요는 `GITCH_CONFIRMATION_REQUIRED`와 종료 코드 2다. `preflight`의 STOP·규칙 위반·doctor의 문제 발견처럼 분석을 마친 결과는 기존 결과 객체를 표준출력에 쓰고 종료 코드로 실패를 알린다.

공개 종료 코드는 0(정상, `gitch c`의 변경 없음 포함), 1(문제·실패·규칙 위반), 2(사용자 확인 필요), 4(비대화형 커밋에서 올릴 파일을 고르지 않음)이다. 내부 커밋 함수의 3은 `gitch c`에서 0으로 바꾸므로 공개 계약으로 사용하지 않는다. 외부 Git·SSH 도구를 직접 실행하는 명령은 그 도구의 종료 코드와 진단을 전달할 수도 있다.

### 비교 (`gitch graph diff`)

```bash
gitch graph diff                 # 기본 브랜치(upstream > origin)와 갈라진 곳 → 지금 작업 트리 (files)
gitch graph diff main modules    # 기준을 주면 그 커밋 · 브랜치와
gitch graph diff origin/main...  # 기준... 은 그 기준과 갈라진 곳과 (기준이 그 뒤로 앞서 나가도 그 커밋은 뺀 것으로 안 보인다)
gitch graph diff --json          # AI · 스크립트: 바뀐 것만 (status: added · removed, cycles.new · changed · gone)
gitch graph diff --format html   # 전체 그래프에 더한 것 · 뺀 것을 색으로
```

- 기준 커밋의 추적 파일을 `git archive` 로 임시 폴더에 풀어 같은 방법으로 그래프를 만들고(저장소는 건드리지 않는다), 노드 · 연결 · 순환을 비교한다. 커밋하지 않은 바꿈도 들어간다(추적하는 파일만).
- 터미널에서는 요약: 연결 +/−(그중 추정), 노드 +/−, 새로 생긴 · 커지거나 줄어든(노드가 둘 넘게 겹침) · 없어진 순환, 더하고 뺀 연결. `tree` 는 폴더마다 파일 수 · 크기 변화(`"status": "changed"`, `filesDelta` · `bytesDelta`).
- 양쪽을 같은 방법으로 읽으려고 Package.swift 는 swift 없이 직접 읽고, Xcode 인덱스 도우미는 쓰지 않는다. `changes` 는 비교하지 않는다.

### 규칙 검사 (`gitch graph check`)

```bash
gitch graph check --init         # 예시가 든 .gitch/graph.rules 를 만든다
gitch graph check                # 위반이 있으면 종료 코드 1 — CI 에 그대로 넣는다
gitch graph check --base main    # main 에도 있던 위반은 「기존」으로 따로 적고 실패로 세지 않는다
```

```
[modules]
no-cycles
forbid  *Feature -> *Feature            # 기능 모듈끼리 기대지 않는다 (같은 모듈 안은 괜찮다)
layers  *App > *Feature > Domain* > Core*   # 왼쪽이 오른쪽에 기대는 것만 된다

[files]
no-cycles src/**
forbid  src/ui -> src/db
allow   src/ui/debug -> src/db          # 위반의 예외
```

| 규칙 | 뜻 |
|---|---|
| `forbid A -> B` | A 가 B 에 기대면 위반. A 와 B 가 같은 패턴이면 같은 곳(같은 모듈 · 같은 폴더)끼리는 괜찮다 |
| `allow A -> B` | `forbid` · `layers` 위반의 예외 |
| `layers A > B > …` | 노드는 처음 맞는 층에 속하고, 오른쪽 층이 왼쪽 층에 기대면 위반 |
| `no-cycles [패턴]` | 순환 의존(패턴을 주면 그 안에서만) |

- 패턴: `files` 는 경로 glob(`*` 한 마디, `**` 여러 폴더, 폴더 이름만 쓰면 그 아래 전부, 외부는 `pkg:npm/react`), `modules` 는 모듈 이름(`*Feature`) 또는 id(`tuist:App`).
- 정확한 연결과 모듈 · 패키지로 확인한 추정(`checked`)은 위반, 이름만으로 한 추정은 경고(실패 아님)다. 틀린 규칙 줄은 줄 번호와 까닭을 알리고 멈춘다.
- 규칙 파일이 있으면 `gitch graph` 의 html 분석 창에 「규칙 위반」이 같이 나온다. JSON: `{"ok", "violations": [{"relation", "severity", "line", "rule", "kind", "source", "target" | "nodes", "existing"}]}`.

## 검사 훅이 막는 것

| 언제 | 무엇을 | 사람이 꼭 넘겨야 할 때 |
|---|---|---|
| 커밋 | 잠금/규칙과 다른 작성자, 계정이 정해지지 않은 관리 서버 저장소 | `GITSW_SKIP=identity` |
| 커밋 | 비밀값(개인키, ghp_/github_pat_, glpat-, AKIA, xox?, sk-ant-, sk-, sk_live_, npm_), `.env`·`*.p12`·`*.jks`·SSH 키 파일 | 줄에 `gitsw:allow`, 또는 `GITSW_SKIP=secrets` |
| 커밋 | `maxFileMB`(기본 50MB) 이상 파일 (`warnFileMB` 이상은 경고) | `GITSW_SKIP=bigfile` |
| push | 별칭 없는 주소 / 다른 계정 별칭 | `GITSW_SKIP=identity` |
| push | 강제 push(기존 원격 커밋 덮어쓰기) | `gitch p --force` |
| push | push 할 새 커밋 중 커미터가 이 계정이 아니거나 작성자가 '다른 내 계정' | `gitch fix --yes` 로 고치기 |
| push | 기본/보호 브랜치 삭제, 보호 브랜치(`gitch protect`) 직접 push | `GITSW_SKIP=protect` |
| push | 폴더 허용 목록(`allowRemote`) 밖으로 push | `GITSW_SKIP=remote` |
| 커밋 메시지 | 계정 정책 `aiTrailer = strip` 이면 `Co-Authored-By: Claude` 같은 줄 제거 | — |

- `gitch.ignore` 로 저장소를 검사에서 뺄 수 있다: `gitch ignore` / `gitch ignore --off`.
- `user.useConfigOnly=true` 를 켜서, 규칙 밖 저장소에서 `me@컴퓨터이름` 같은 엉뚱한 작성자로 커밋되지 않게 한다.
- 설정 파일이 깨지면 커밋을 막지 않고 경고만 한다 (`gitch doctor` 로 확인).
- gitch 를 찾지 못하면(앱을 지웠거나 옮김) 커밋 · push 는 막지 않고 `[gitch] ~/bin/gitch 를 찾을 수 없어 검사를 건너뜁니다` 한 줄로 알린다. 훅 연결 스크립트는 gitch 가 바뀌면 다음 훅 실행 때 스스로 새로 쓴다.
- `--no-verify` 는 git 자체 기능이라 훅으로 막을 수 없다. AI 는 Claude 훅이 막는다.

## AI 연동

`gitch install`(또는 `gitch ai`)이 만든다.

- `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`(, `~/.gemini/GEMINI.md`) 에 규칙 블록
- `~/.claude/skills/gitch/SKILL.md`, `~/.codex/skills/gitch/SKILL.md` 스킬
- `~/.claude/settings.json`
  - PreToolUse 훅 `gitch guard --claude`: Bash 명령과 Edit/Write 대상 파일을 검사
    - 거부: `--no-verify`, `git push --force/+refspec`, `GITSW_*`/`GIT_AUTHOR_*`/`GIT_SSH_COMMAND` 환경변수, `git -c user.*|core.hooksPath|hook.*|url.*`, 전역 git 설정 쓰기, 작성자/원격 설정 쓰기, `~/.ssh`·`~/.gitconfig`·`~/.config/gitsw`·`.git/hooks` 수정, 관리 서버 저장소의 `git clone`(→ `gitch clone`), `gitch add/remove/setup/sign on|off/import`
    - 확인 창: push·PR 생성(아래 push 정책), 원격 브랜치 삭제, `reset --hard`, `clean -f`, `checkout -- 파일`, `restore`, `branch -D`, `stash drop`, `remote add/set-url`, `gitch unlock`, 잠긴 저장소를 다른 계정으로 `gitch use`, `gitch undo/amend/fix --yes/abort/rescue --restore`, gitch 설정 변경
  - 자동 허용: 읽기 명령(`gitch ck/status/preflight/l/d/doctor/...`, `git status/diff/log/show/...`)과 일상 명령(`git add`, `gitch c/cp/p/pl/up/b/wt/clone/pr`, `git commit/push/pull/branch/switch/checkout/restore/stash/remote`).
    위험한 옵션은 위의 훅이 먼저 거부하거나 확인을 받으므로, 자동 허용이어도 그대로 지켜진다.
- push 정책 (`gitsw.aiPush`)
  - `branch` (권장): 작업 브랜치 push 는 확인 없이, **main/master/원격 기본 브랜치/보호 브랜치(`gitch protect`) push 와 PR/MR 생성만 확인**. 어느 브랜치로 가는지 모르면(detached 등) 확인. 태그 push 도 확인.
  - `ask` (기본값): push·PR 생성마다 확인
  - `allow`: 확인 없음 (검사 훅은 그대로)
  - 바꾸기: `gitch config set gitsw.aiPush branch` — AI 규칙과 Claude 설정도 같이 갱신된다.
- 실행 주체는 환경변수(`CLAUDECODE`, Codex 샌드박스 변수, `AI_AGENT` 등)로 구분해 `gitch report` 에 남는다. 터미널(TTY)이면 사람으로 본다.
- 비대화형(AI)에서 `gitch c` 는 스테이지된 파일만 커밋한다 (모두 올리려면 `-a`).

지우기: `gitch ai --remove`.

## 설정 파일 (`~/.config/gitsw/config`)

git config 형식이다. `gitch config set|add|unset <키> <값>` 으로 바꾸면 바꾼 뒤 검사하고, 틀리면 되돌린다.

```ini
[gitsw]
	scanRoot = ~/Develop
	aiPush = branch         # ask(매번 확인) | branch(main/보호 브랜치 push 와 PR 만 확인) | allow
	maxFileMB = 50
	warnFileMB = 10
	sshStrict = false       # true 면 별칭 없는 github.com 등은 SSH 키 인증 안 함 (공개 저장소 SSH clone 도 막힘)
[account "alice"]
	email = alice@example.com
	host = github.com
[account "carol"]
	email = carol@corp.example
	host = gitlab.example.com:2222
	aiTrailer = keep        # strip 이면 이 계정 커밋에서 AI 표기 줄 제거
[folder "~/Develop/corp"]
	account = carol
	allowRemote = gitlab.example.com/*
	allowRemote = github.com/acme/*
[org "github.com/acme"]
	account = alice
```

고급: `host = github.com via 다른계정` — 이 계정의 신원(이메일)으로 커밋하지만 GitHub 접속은 다른 계정의 SSH 키/로그인을 빌려 쓴다.

## GitHub CLI / PR

- PR 은 `gh auth token --user <계정>` 으로 그 계정 토큰만 꺼내 쓴다. `gh auth switch` 처럼 전역 계정을 바꾸지 않아서 여러 AI 세션이 동시에 일해도 꼬이지 않는다.
- 계정마다 한 번씩 사용자가 직접 로그인해야 한다: `gh auth login --hostname github.com`
- GitLab MR 은 push 옵션(`-o merge_request.create`)으로 만든다. 토큰이나 glab 이 필요 없다 (새 커밋이 있어야 함, 설명은 한 줄로 합쳐짐).
- 새 저장소 올리기: `gitch publish [이름] [--public] [--description 설명]` — GitHub 은 그 계정 토큰으로 저장소를 만들고, GitLab 은 push 하면 비공개 프로젝트가 생긴다.

## 파일 위치

| 파일 | 내용 |
|---|---|
| `~/.config/gitsw/config` | 설정 |
| `~/.local/state/gitsw/actions.jsonl` | 작업 기록 (`gitch report`) |
| `~/.local/state/gitsw/backups/` | gitch 가 고치기 전 파일 백업 (내용이 바뀐 것만, 날짜 폴더 최근 30개. 다른 이름의 폴더는 지우지 않음) |
| `~/.local/share/gitsw/hook` | git 훅 연결 스크립트 (gitch 가 없으면 막지 않고 커밋 · push 때 한 줄로 알림) |
| `refs/gitsw/backup/*` (저장소 안) | `gitch rescue` 백업 (최근 30개, push 안 됨) |
| `~/.local/share/gitch/gitch` | 앱 없이 받은 gitch (`install.sh`, `gitch self-update`) |

## (선택) push 를 Touch ID 로 승인하기

AI 의 push 마다 손가락 승인을 받고 싶다면 하드웨어 키(Secretive, 1Password SSH 에이전트)로 push 전용 키를 만들어 `pushurl` 만 그 키를 쓰게 한다. fetch/pull 은 지금 키 그대로라 불편이 적다.

1. Secretive(또는 1Password)에서 "사용할 때마다 확인" 키를 만들고 공개키를 GitHub 계정에 추가
2. `~/.ssh/config` 에 `Host github-<계정>-push` (HostName github.com, IdentityAgent 는 그 앱의 소켓)
3. 저장소에서 `git config remote.origin.pushurl git@github-<계정>-push:<owner>/<repo>.git`
   (gitch 검사 훅은 push 주소 별칭이 계정 별칭과 같아야 통과하므로, 이 방식을 쓰면 해당 저장소는 `gitch ignore` 하거나 별칭 규칙을 맞춰야 한다 — 필요해지면 gitch 에 기능으로 추가)

## 개발 / 테스트

```bash
tools/gitch/tests/run.sh             # 전체 (실제 ~/.gitconfig, ~/.ssh, ~/.claude 는 건드리지 않음: 임시 HOME + 가짜 ssh/gh/curl/원격)
tools/gitch/tests/run.sh -k guard    # 이름에 guard 가 들어간 테스트만
shellcheck -s bash -S warning tools/gitch/gitch tools/gitch/install.sh
tools/gitch-swift-index/tests/run.sh # Xcode 인덱스 도우미: 예제를 swift build 해서 쌍 · gitch graph files 확인 (30초쯤)
```

GitHub Actions 「macOS」의 gitch 테스트가 `tools/gitch/**` 를 바꾼 PR 마다 macOS 기본 bash 3.2 로, 「Windows」가 Git Bash 로 돈다(Windows 전용은 `tests/test_windows.sh`, 가짜 PowerShell 로 실제 사용자 PATH 는 건드리지 않음).

자동완성은 설치된 Bash·Zsh·Fish·PowerShell 런타임으로 실제 후보 조회와 공백·따옴표·달러 기호의 인자 보존을 시험한다. 별도로 받은 PowerShell은 `GITCH_TEST_PWSH=/절대경로/pwsh`로 지정할 수 있고 `-NoProfile`로 실행한다. JSON Schema의 정식 검증을 더하려면 `jsonschema`가 설치된 Python을 `GITCH_JSONSCHEMA_PYTHON=/절대경로/python3`으로 지정한다. 테스트가 런타임이나 패키지를 자동 설치하지는 않는다.

## 제거

`gitch uninstall` — 자동 규칙, 검사 훅, AI 연동, 터미널 연동을 지운다. 설정 파일, SSH 키, 저장소별 잠금, `user.useConfigOnly` 는 남긴다.

## 근거를 확인하고 변경을 따라가기

파일 노드의 `analysis`는 파일 인식(`file-detection`), 정적 import 해석(`static-import`), 컴파일러 인덱스(`compiler-index`)를 구분한다. 연결에는 `method`, `confidence`, `evidence`가 있다. `evidence.file`과 1부터 시작하는 `line`은 실제 읽은 선언의 위치다. 원래 분석기가 위치를 제공하지 않은 경우에는 `null`이며 줄 번호를 만들어 내지 않는다. Swift/JVM의 이름 추정은 `heuristic`으로 남는다. `diagnostics`에는 해석하지 못한 선언과 원인·파일·줄을 기록한다. [정밀 SCIP 분석](SCIP.md)은 별도 인덱서가 만든 파일을 검증해서 읽는다.

```bash
gitch g --precise                  # .gitch/index.scip 또는 index.scip
gitch g files --index build/index.scip --lang ts,python,java
gitch g index --language java       # 공식 생성 방법 안내, 빌드는 사용자가 명시적으로 실행

gitch g affected --json             # 기본 브랜치와 갈라진 곳부터 작업 트리까지
gitch g affected --base HEAD        # 커밋하지 않은 변경 영향만
gitch g watch files                 # 수정하면 브라우저 자동 갱신
gitch g watch affected --base HEAD  # 변경 영향도 계속 갱신
gitch g watch precise --detach --json --no-open
```

`affected`는 변경 파일을 씨앗으로 이를 쓰는 파일을 전이적으로 찾고 모듈에도 반영한다. 삭제·이름 변경은 기준 커밋의 연결을 함께 읽는다. `stats.affected`의 `changedFiles`, `files`, `modules`, `unresolvedFiles`로 결과와 분석하지 못한 파일을 구분한다. 빠른 분석이 해석하지 못하는 동적 참조나 언어의 영향까지 보장하지는 않는다.

일반 그래프는 저장소·추적 파일 내용·인덱스·HEAD·분석 옵션을 기준으로 결과를 캐시한다. `--no-cache`로 끌 수 있다. Swift/SCIP 정밀 인덱스는 매번 유효성을 확인한다. 자동 갱신은 Python 3 표준 라이브러리로 실행하며 로컬 주소에서 생성한 HTML 한 장만 제공한다. 브라우저를 닫아 접속이 끊기면 감시도 종료한다. 갱신 실패 시 마지막 정상 화면을 유지하고 오류를 표시한다.

그래프 연결의 ‘근거’를 펼치면 파일·줄·분석 방법이나 실제 커밋을 확인할 수 있다. 링크는 `gitrochi://open`으로 앱의 해당 파일/줄 또는 커밋을 연다. 설정의 ‘저장한 보기’는 필터·배치·선택·확대 위치를 이름으로 저장하며 JSON 보기 파일을 가져오거나 내보낼 수 있다. 자동 갱신 때도 현재 보기를 복원한다.

설계 참고: [dependency-cruiser의 영향 분석·캐시](https://github.com/sverweij/dependency-cruiser/blob/main/doc/cli.md), [CodeCharta의 Git 이력 분석](https://codecharta.com/docs/parser/git-log/), [CodeCharta의 저장한 시나리오](https://codecharta.com/docs/visualization/user-controls/scenarios/), [SCIP 공개 프로토콜](https://github.com/scip-code/scip). 기능과 공개 형식을 참고했으며 구현은 gitch의 읽기 전용 분석·기존 앱 이동 방식에 맞췄다.
