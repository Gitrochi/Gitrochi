<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Gitrochi 아이콘">
</p>

<h1 align="center">Gitrochi</h1>

<p align="center">
  <b>커밋 그래프로 보고, 클릭으로 다루는 Git 클라이언트</b><br>
  macOS · Windows &nbsp;|&nbsp; 브랜치 · 머지 · PR/MR · CI/CD · AI 커밋 메시지 · 코딩 에이전트 · 내장 터미널
</p>

<p align="center">
  <a href="https://github.com/Gitrochi/Gitrochi/releases/latest"><img src="https://img.shields.io/github/v/release/Gitrochi/Gitrochi?label=%EC%B5%9C%EC%8B%A0%20%EB%B2%84%EC%A0%84&color=2f6fec" alt="최신 버전"></a>
  <a href="https://github.com/Gitrochi/Gitrochi/releases"><img src="https://img.shields.io/github/downloads/Gitrochi/Gitrochi/total?label=%EB%8B%A4%EC%9A%B4%EB%A1%9C%EB%93%9C&color=2a9a55" alt="다운로드"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Windows-10%20%C2%B7%2011-0078d4?logo=windows&logoColor=white" alt="Windows 10 · 11">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Gitrochi/Gitrochi?color=6b6b72" alt="MIT"></a>
</p>

<p align="center">
  <a href="https://github.com/Gitrochi/Gitrochi/releases/latest"><b>⬇&nbsp; 내려받기</b></a>
  &nbsp;·&nbsp; <a href="#설치">설치</a>
  &nbsp;·&nbsp; <a href="#사용법">사용법</a>
  &nbsp;·&nbsp; <a href="#기능-자세히">기능 자세히</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" alt="Gitrochi 메인 화면 — 왼쪽 브랜치·태그, 가운데 커밋 그래프, 오른쪽 작업 중인 변경과 커밋 입력">
  </picture>
</p>

> **English** — A native Git client for macOS and Windows: a readable commit graph, staging and commits, GitHub / GitLab pull requests, CI/CD pipelines you can trigger, AI-written commit messages, Claude Code · Codex · Gemini agents in worktrees, and a built-in terminal. Git itself does the work — Gitrochi calls your system `git`.

## 한눈에

|  |  |
|---|---|
| 🌳 **읽기 쉬운 커밋 그래프**<br>모든 브랜치를 레인 색으로 그리고, 브랜치·태그는 왼쪽 칸에 모아 커밋 메시지와 겹치지 않게. 로컬 💻 · 원격 ☁ 을 한 라벨로 보여 주고 작성자 프로필 사진까지. | ✍️ **스테이지 · 커밋 · diff**<br>줄·덩어리 단위 스테이지, 한 줄로·나란히 diff(단어 단위 강조·이미지 비교), 충돌 해결 화면, 커밋 정리(합치기·순서·메시지), 마지막 작업 되돌리기. 끌어다 놓기로 머지·리베이스·cherry-pick. |
| ✨ **AI 커밋 메시지**<br>Claude Code · Codex · Gemini CLI 또는 API 키로 커밋 메시지·PR 글을 쓰고, 팀 **규칙**(예: `Feat:` · `Fix:` 접두어)을 지키게. 바뀐 파일을 주제별로 **나눠서 커밋**. | 🔀 **GitHub · GitLab**<br>열린 PR/MR 목록, 앱 안에서 리뷰(대화·댓글·승인·바뀐 파일), 체크아웃, 현재 브랜치로 PR/MR 만들기, 그래프에 CI 상태. 사내(자체 호스팅) GitLab 지원. |
| 🚀 **CI/CD 실행**<br>GitLab 파이프라인 · GitHub Actions 를 보고, 손으로 눌러야 도는 작업(`when: manual`)을 ▶ 로 실행. 다시 실행 · 취소 · 배포 승인, `workflow_dispatch` 실행. | 🤖 **코딩 에이전트**<br>Claude Code · Codex · Gemini CLI 세션을 워크트리마다 띄우고 상태(작업 중 · 권한 요청 · 입력 대기)를 사이드바에서. |
| 🖥️ **내장 터미널**<br>그래프 아래에서 저장소 폴더의 셸을 탭으로 여러 개. git 명령을 치면 그래프가 바로 갱신. | 🌗 **라이트 · 다크**<br>시스템을 따르거나 고정. 그래프 · 터미널 · 창 제목 표시줄까지 함께. |

## 화면

<table>
  <tr>
    <td width="50%"><img src="docs/images/commit-diff-light.png" alt="커밋을 고르면 오른쪽에 상세, 파일을 누르면 가운데에 diff"></td>
    <td width="50%"><img src="docs/images/changes-light.png" alt="작업 중인 변경: 파일별 diff 와 스테이지·커밋"></td>
  </tr>
  <tr>
    <td align="center"><b>커밋 상세와 diff</b><br><sub>커밋을 고르면 작성자·부모·바뀐 파일, 파일을 누르면 diff</sub></td>
    <td align="center"><b>작업 중인 변경</b><br><sub>스테이지 전 diff 를 보고 파일별로 스테이지 → 커밋</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/images/commit-diff-dark.png" alt="다크 테마"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><b>다크 테마</b><br><sub>설정 &gt; 화면에서 시스템 · 라이트 · 다크</sub></td>
  </tr>
</table>

### Windows

<table>
  <tr>
    <td width="50%"><img src="docs/images/windows-light.png" alt="Windows 버전 — 라이트"></td>
    <td width="50%"><img src="docs/images/windows-dark.png" alt="Windows 버전 — 다크"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><sub>Windows 도 같은 화면과 기능 — 창 안의 탭, Ctrl 단축키, PowerShell · WSL 터미널, 제목 표시줄까지 테마를 따름</sub></td>
  </tr>
</table>

<sub>스크린샷의 저장소·작성자는 모두 지어낸 데모입니다(<a href="docs/make-demo-repo.sh"><code>docs/make-demo-repo.sh</code></a>로 똑같이 만들 수 있습니다).</sub>

## 설치

### macOS (15 이상, Apple Silicon · Intel)

1. [최신 릴리스](https://github.com/Gitrochi/Gitrochi/releases/latest)에서 `Gitrochi-<버전>-macOS.dmg` 를 받아 `Gitrochi.app` 을 응용 프로그램 폴더로 옮깁니다.
2. 아직 Apple 공증을 받지 않은 빌드라 처음 열 때 "확인되지 않은 개발자" 경고가 뜹니다. 둘 중 하나로 여세요.
   - **시스템 설정 → 개인정보 보호 및 보안** 아래쪽의 **그래도 열기**
   - 또는 터미널에서 `xattr -dr com.apple.quarantine /Applications/Gitrochi.app`

필요: `git`(Xcode 또는 `xcode-select --install`). 선택: [Claude Code](https://claude.com/claude-code) · [GitHub CLI](https://cli.github.com).

### Windows (10 1809 이상 · 11, x64)

1. [최신 릴리스](https://github.com/Gitrochi/Gitrochi/releases/latest)에서 `Gitrochi_<버전>_x64-setup.exe` 를 받아 실행합니다(설치 없이 쓰려면 `_portable.zip`).
2. 코드 서명을 하지 않은 빌드라 SmartScreen 이 막으면 **추가 정보 → 실행**.

필요: [Git for Windows](https://git-scm.com/download/win). WSL 에 설치한 Claude Code · Codex · Gemini CLI 도 쓸 수 있습니다.

> 두 버전 모두 **자동 업데이트**: 켤 때와 하루에 한 번 새 버전을 확인하고, 누르면 받아서 설치한 뒤 다시 시작합니다(받은 파일은 서명·해시가 맞을 때만 설치).

## 사용법

### 처음 사용하는 경우

시작 화면의 **Git 계정 시작하기**(Windows: **Git 계정 설정 · gitch 시작하기**)나 **설정 > CLI**를 여세요. gitch는 앱에 포함돼 있어 따로 받을 필요가 없습니다.

1. **브라우저로 GitHub 로그인**을 누르면 기본 브라우저에서 승인한 계정을 앱에 연결하고 사용자 이름·이메일을 채웁니다. 공식 [GitHub CLI](https://cli.github.com/)가 필요하며, 없으면 앱에서 다운로드 안내를 엽니다. 회사 GitLab은 서버 주소·계정 정보를 직접 입력합니다.
2. 계정 정보를 확인하고 저장한 뒤 SSH 키를 준비하세요. 앱에서 전용 키를 만들거나 기존 키를 사용하고, GitHub에서는 **공개키 자동 등록 후 연결**로 등록과 확인을 이어갈 수 있습니다. SSH 포트 옆 **?**에 기본값 22와 회사 서버 설정 설명이 있습니다.
3. 저장소를 열어 작업하세요. 터미널에서도 명령을 쓰고 싶으면 **터미널에서도 사용하기**를 선택합니다. 전역 설정을 바꾸기 전에 적용할 파일 목록을 보여 줍니다.

**시작 안내 · 명령 설명**에는 `gitch add`(계정 추가), `gitch g`(구조 그래프), `gitch app`(앱 열기)와 나머지 명령의 목적·앱에서 찾는 위치가 있습니다. 구조 그래프는 계정을 설정하기 전에도 사용할 수 있습니다. 설정 확인 결과와 SSH 연결 문제도 앱 안에서 볼 수 있습니다.


1. **저장소 열기** — 폴더 버튼(⌘O / Ctrl+O)으로 열거나 복제(⇧⌘O), 여러 저장소는 탭으로(⌘T).
2. **그래프 둘러보기** — 커밋을 누르면 오른쪽에 상세, 파일을 누르면 diff. 왼쪽 브랜치를 누르면 그 커밋으로, 두 번 누르면 체크아웃.
3. **커밋** — macOS는 **변경 사항**(⌘1)에서 파일 선택 → diff 확인 → 스테이지 → 하단 메시지 작성 → ⌘↩ 순서로 진행합니다. **히스토리**(⌘2)에서는 그래프와 커밋 상세를 탐색하며, 화면을 오가도 선택한 파일과 초안을 유지합니다. Windows는 그래프 맨 위 **작업 중인 변경**에서 준비합니다.
4. **브랜치 다루기** — 브랜치 라벨을 다른 커밋·브랜치로 끌어다 놓으면 머지 · 리베이스 · 빨리 감기 메뉴. 커밋 우클릭으로 cherry-pick · revert · reset · 태그.
5. **올리기와 PR** — 툴바의 Push 후 사이드바 Pull Requests 의 ＋ 로 PR/MR 만들기. 계정은 설정(⌘,) > 계정에서 GitHub · 사내 GitLab 토큰 연결.
6. **CI/CD** — 사이드바 **CI/CD** 탭에서 파이프라인을 펼쳐 수동 작업 ▶, 또는 **실행…**으로 새 파이프라인·워크플로.

| 동작 | macOS | Windows |
|---|---|---|
| 새 탭 · 탭 닫기 | ⌘T · ⌘W | Ctrl+T · Ctrl+W (탭 우클릭: 다른 탭 모두 닫기) |
| 커밋 검색 · 다음 결과 | ⌘F · ⌘G | Ctrl+F · F3 |
| 변경 사항 · 히스토리 | ⌘1 · ⌘2 | — |
| 커밋 | ⌘↩ | Ctrl+Enter |
| 마지막 작업 되돌리기 | ⌥⌘Z | Ctrl+Z (입력 칸 밖에서) |
| 새로 고침 | ⌘R | F5 |
| 터미널 보이기 · 새 터미널 | ⌃\` · ⌃⇧\` | Ctrl+\` · Ctrl+Shift+\` |
| 설정 | ⌘, | Ctrl+, |

## 기능 자세히

<details>
<summary><b>그래프 · 브랜치 · 커밋</b></summary>

- **커밋 그래프**: 모든 브랜치를 레인 색으로 그리고 머지·분기를 곡선으로 연결. 왼쪽 '브랜치 / 태그' 칸(같은 이름의 로컬·원격은 한 라벨, 현재 브랜치 ✓), 맨 위 "작업 중인 변경" 행, 커밋 동그라미에 작성자 프로필(GitHub · 사내 GitLab · Gravatar, 없으면 이니셜), 커밋마다 CI 상태
- **그래프 거르기**: 브랜치 숨기기 · 사이드바 맨 위에 고정 · 현재 브랜치만 보기(저장소마다 기억)
- **사이드바**: 로컬 브랜치(↑/↓), 원격 브랜치(리모트별), 태그, 스태시. 클릭 = 그 커밋으로 이동, 더블클릭 = 체크아웃, 우클릭 = 머지 · 리베이스 · 새 브랜치 · Push · 삭제
- **작업 영역**: 스테이지/언스테이지(파일별·폴더별·전체), 변경 버리기, 커밋, Amend, 목록 / 폴더 트리 보기
- **줄·덩어리 단위 스테이지**: diff 의 덩어리마다 스테이지 · 언스테이지 · 버리기, 바뀐 줄을 눌러(Shift 로 범위) 고른 줄만
- **커밋 상세 · diff**: 메시지, 작성자, 부모 커밋 이동, 바뀐 파일 → 한 줄로 / 나란히 보기, 단어 단위 강조, 공백 무시, 긴 줄은 줄바꿈, 이미지 이전·이후 비교, 이름·권한 바뀜 안내, CRLF 파일 그대로
- **파일 히스토리 · 줄별 작성자(blame)**: 파일을 바꾼 커밋들과 그때의 변경, 줄마다 누가 언제 바꿨는지(오래된 줄일수록 옅게)
- **커밋 우클릭**: 브랜치·태그 만들기, 체크아웃(분리된 HEAD), Cherry-pick, Revert, Reset(soft/mixed/hard), **여기부터 커밋 정리**(인터랙티브 리베이스: 합치기 · 순서 바꾸기 · 메시지 고치기 · 빼기)
- **끌어다 놓기**: 브랜치를 브랜치·커밋 위로 → 머지 · 리베이스 · 빨리 감기, 커밋을 브랜치로 → cherry-pick
- **툴바**: Fetch, Pull(기본/ff-only/merge/rebase), Push(업스트림 자동 설정, force-with-lease), 새 브랜치, Stash/Pop
- **진행 중 작업**: 머지·리베이스·cherry-pick 충돌 배너(중단/계속), **충돌 해결 화면**(블록마다 내 것 · 상대 것 · 둘 다 · 직접 고치기, 파일 전체를 한쪽으로)
- **되돌리기**: 커밋 · 머지 · 리베이스 · 체크아웃 · 브랜치 삭제 등 마지막 작업을 한 번에(그 뒤로 저장소가 바뀌었으면 막음)
- **커밋 검색**: 제목·작성자·SHA·브랜치 + 메시지 본문, 파일 경로, 코드 변경(-G). 결과 강조, 그래프 밖 결과는 더 불러와서 찾기
- **워크트리**: 목록, 새 워크트리(새/기존 브랜치, 기본 위치 `<저장소>-worktrees/<브랜치>`), 제거·정리, 다른 워크트리가 쓰는 브랜치 표시

</details>

<details>
<summary><b>AI · 규칙 · 나눠서 커밋</b></summary>

- **작성**: 커밋 메시지 · 커밋 설명 · PR/MR 제목과 본문
- **고를 수 있는 AI**: Claude Code · Codex(ChatGPT 로그인) · Gemini CLI(이 PC 의 로그인 그대로, 도구는 끈 채 글만), Claude API · ChatGPT API · Gemini API(키), OpenAI 호환 서버(Ollama · LM Studio · OpenRouter 등). API 는 계정의 모델 목록을 받아 온다
- **규칙**(설정 > 규칙): 공통 규칙 + 커밋 메시지 · 커밋 설명 · PR 설명 규칙(예: `prefix 는 Feature, Fix, Hotfix 중 하나`), 자주 쓰는 규칙 버튼, 기능마다 다른 AI
- **나눠서 커밋**: AI 가 바뀐 파일을 주요 내용별로 묶은 계획을 보여 주고, 메시지·파일을 고친 뒤 차례로 커밋

</details>

<details>
<summary><b>GitHub · GitLab · CI/CD</b></summary>

- **계정**: 토큰(맥 키체인 / Windows 자격 증명 관리자), GitHub 는 `gh` 로그인 가져오기, GitLab 은 자체 호스팅 주소
- **PR/MR**: 열린 목록·상세, 앱 안에서 리뷰(대화 · 코드 줄 댓글 · 댓글 쓰기 · 승인 · 변경 요청, 바뀐 파일 diff), 체크아웃(포크는 `pr/번호` · `mr/번호`), 현재 브랜치로 만들기(필요하면 먼저 push, Draft), 복제 창에서 내 저장소 검색
- **HTTPS 인증**: 연결한 토큰으로 push/pull/clone(기존 키체인·자격 증명 도우미가 우선). 자격 증명을 물으면 멈추지 않고 실패(`GIT_TERMINAL_PROMPT=0`)
- **CI/CD 탭**: GitLab 파이프라인 · GitHub Actions 실행 목록(현재 브랜치만 보기), 펼치면 단계별 작업
  - GitLab `when: manual` · `when: delayed` 작업 ▶ 실행(기다리는 수동 작업 수를 목록에 미리 표시)
  - 작업·파이프라인 다시 실행(GitHub 은 실패한 작업만도), 취소, 브라우저로 열기, 커밋 보기
  - **실행…**: GitLab 새 파이프라인(브랜치·변수, `.gitlab-ci.yml` 의 설명 붙은 변수 미리 채움) / GitHub `workflow_dispatch`(브랜치·입력값)
  - GitHub 환경 보호 규칙의 배포 승인·거부
  - 실행하려면 토큰에 GitLab 은 `api` 권한, GitHub 은 Actions 쓰기 권한(클래식 토큰은 `repo`)

</details>

<details>
<summary><b>에이전트 · 터미널 · 도구 · 기타</b></summary>

- **에이전트 탭**: 워크트리 카드(새 파일·수정·삭제 수, 원격 대비 ↑↓)와 그 안의 Claude Code · Codex · Gemini CLI 세션 상태(작업 중 · 권한 요청 · 입력 대기 · 종료). 세션 시작(워크트리 선택 또는 새 워크트리, 맡길 작업, 권한 모드). 상태는 Gitrochi 가 띄운 세션에 `--settings` 로 더한 훅이 남기는 파일로 판단하며, 사용자 설정·훅은 그대로
- **터미널**: 그래프 아래 패널에서 저장소 폴더의 셸(맥 zsh · Windows PowerShell/WSL). 탭 여러 개, 높이 조절, 숨겨도 계속 실행. 맥은 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), Windows 는 [xterm.js](https://xtermjs.org)
- **도구**(설정 > 도구): git · Claude Code · Codex · Gemini CLI · gh · 터미널 셸을 자동으로 찾고, 못 찾으면 **불러오기**로 직접 지정. Windows 는 WSL 안의 도구도
- **gitch**(맥 · Windows, 설정 > CLI): 여러 Git 계정을 섞이지 않게 쓰는 셸 도구를 앱에 함께 넣었습니다(예전 이름 gitsw). 설치하면 저장소마다 계정을 잠그고, 폴더 · 조직 규칙으로 계정을 고르고, 잘못된 작성자 · 비밀값 · 강제 push 를 git 훅에서 막습니다(터미널 · AI 에이전트 · Gitrochi 모두). 커밋 칸 위에 이 저장소의 계정과 커밋 · push 전 점검이 보이고, 계정 이름을 눌러 계정을 바꿉니다. Windows 는 Git for Windows 의 Git Bash 로 돌고, PowerShell · cmd 에서도 `gitch` 로 부릅니다 — [tools/gitch](tools/gitch/README.md)
  - **CLI 만**(앱 없이): `curl -fsSL https://raw.githubusercontent.com/Gitrochi/Gitrochi/main/tools/gitch/install.sh | bash` — 릴리스의 gitch 를 SHA-256 으로 확인해 `~/.local/share/gitch/gitch` 에 둡니다. 계정 추가와 `gitch install` 은 설치기가 보여 주는 대로 직접 하고, 업데이트는 `gitch self-update`
  - **구조 그래프**(저장소 메뉴): 파일 import · 모듈 의존 · 같이 바뀌는 파일 · 폴더 구조 중 하나를 고르면 `gitch graph` 가 그린 한 페이지를 기본 브라우저로 엽니다(계정 설정 없이도 됨). **이 브랜치에서 바뀐 의존**은 기본 브랜치(또는 고른 브랜치 · 태그)와 갈라진 곳과 비교해 더하고 뺀 의존 · 순환을, **의존 규칙 검사**는 `.gitch/graph.rules` 를 어긴 의존을 보여 줍니다
- **탭**: 맥은 기본 창 탭(탭을 끌어 새 창으로), Windows 는 창 안의 탭. 다시 켜면 탭 복원
- **화면 테마**: 시스템 · 라이트 · 다크
- **자동 새로 고침**: 파일을 저장하면 상태만, 브랜치·커밋이 바뀌면 그래프까지(큰 저장소도 가볍게)

</details>

## 개발

<details>
<summary><b>저장소 구조 · 빌드 · 자동 점검</b></summary>

```
macos/     맥 앱(SwiftUI)
  Sources/App       앱·창·탭·업데이트·테마
  Sources/Core      git 실행·출력 해석·그래프 배치·모델·파일 감시
  Sources/Store     저장소 화면 상태(RepoStore)와 기능별 확장
  Sources/Services  GitHub·GitLab·CI/CD·AI·계정·에이전트·도구·프로필 사진
  Sources/Views     화면
  Resources/ Tools/ Vendor/SwiftTerm/  build.sh
windows/   Windows 앱(Tauri 2 + React): src-tauri(Rust), src(Feature-Sliced Design: app·pages·widgets·features·entities·shared), tests
docs/      README 이미지와 데모 저장소 스크립트
tools/gitch  여러 Git 계정용 셸 도구(bash 3.2 + git, Windows 는 Git Bash) — 맥 · Windows 앱에 함께 들어감, tests/run.sh
```

**맥** — Swift 6 이상(Xcode 또는 Command Line Tools)만 있으면 됩니다. 외부 패키지를 내려받지 않습니다.

```sh
macos/build.sh           # macos/build/Gitrochi.app (이 맥의 아키텍처)
macos/build.sh install   # 빌드 후 /Applications 에 설치
macos/build.sh release   # macos/dist/ 에 배포용 dmg·zip·sha256 (arm64 + x86_64 유니버설, ad-hoc 서명, 업데이트 서명)
```

- SwiftPM 없이 `swiftc` 로 직접 컴파일합니다(일부 Command Line Tools 에서 SwiftPM 이 동작하지 않아서). 같은 이유로 `@State` 매크로 대신 `ViewState` 별칭(`Views/Shared/Theme.swift`)
- SwiftTerm 은 아키텍처별 정적 라이브러리(`macos/.build/swiftterm/<arch>/`)로 따로 컴파일(처음 한 번 1분쯤)
- `tools/gitch/gitch` 를 앱의 `Contents/Resources/gitch` 로 넣는다. gitch 를 고쳤으면 `tools/gitch/tests/run.sh`
- 이 맥에 Apple Development 인증서가 있으면 그걸로 서명(키체인 허용을 빌드마다 다시 묻지 않게, `GITROCHI_SIGN_IDENTITY` 로 변경)
- `GITROCHI_TRACE=1` 로 실행하면 새로 고침 종류와 걸린 시간을 표준 오류로
- **업데이트 서명**: `macos/Tools/updatekey.sh new` 로 Ed25519 열쇠를 만들면 비밀키는 로그인 키체인에, 공개키는 `Info.plist`(`GitrochiUpdatePublicKey`)에 들어갑니다. 그 뒤 `build.sh release` 는 zip 을 서명(`<zip>.sig`, 비밀키는 `GITROCHI_UPDATE_KEY` 또는 키체인)하고, 앱은 SHA-256 과 이 서명이 맞을 때만 설치
- **배포**: `v*` 태그를 push 하면 Actions(`.github/workflows/macos.yml`)가 태그와 `Info.plist` 버전이 같은지 보고 유니버설로 빌드·서명해 그 태그의 릴리스(없으면 초안)에 올립니다(앱 없이 쓰는 `gitch` · `gitch.sha256` 도). 앱은 초안을 보지 않으니 노트를 쓰고 게시하면 사용자에게 갑니다

**Windows** — Node.js 22 와 Rust(stable).

```sh
cd windows
npm ci
npx tauri build      # src-tauri/target/release/bundle/nsis/*-setup.exe
npx vitest run       # 파서·그래프·CI 단위 테스트
```

- **자동 점검**: `GITROCHI_SELFTEST=<테스트 저장소>` 로 실행하면 열기 · 스테이지 · 커밋 · 브랜치 · 머지 · 검색 · stash · 터미널 · 자격 증명 · 도구 · AI · 나눠서 커밋 · 업데이트 서명 · CI/CD · WSL · diff · 줄 단위 스테이지 · 충돌 해결 · 커밋 정리 · 되돌리기 · PR 리뷰 · 탭 메뉴 · 테마를 실제 앱에서 차례로 해 보고 결과를 남깁니다(가짜 서버 `tests/mock-ai-server.mjs`). GitHub Actions 의 Windows 서버에서 푸시마다 돌고, README 의 Windows 스크린샷도 거기서 찍습니다(`.github/workflows/windows.yml`)
- **업데이트 서명**: 릴리스 빌드는 `TAURI_SIGNING_PRIVATE_KEY`(Actions 비밀 값)로 서명하고, 앱은 `tauri.conf.json` 의 공개 키로 확인한 뒤에만 설치. 릴리스에 `latest.json`(`windows/scripts/latest-json.mjs`)

</details>

## 기여

- 🐞 [버그 제보](https://github.com/Gitrochi/Gitrochi/issues/new?template=bug_report.yml) · ✨ [기능 요청](https://github.com/Gitrochi/Gitrochi/issues/new?template=feature_request.yml) · 💬 [질문](https://github.com/Gitrochi/Gitrochi/issues/new?template=question.yml)
- 코드 규칙 · 빌드 · 테스트 · 커밋 메시지: [CONTRIBUTING.md](CONTRIBUTING.md)
- 보안 문제는 이슈 대신 [비공개로](SECURITY.md)

## 라이선스

[MIT](LICENSE) © 2026 조문성 (ChoMnSeong), [jjunhaa0211](https://github.com/jjunhaa0211)

포함된 서드파티 코드: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) v1.20.0 — MIT ([macos/Vendor/SwiftTerm/LICENSE](macos/Vendor/SwiftTerm/LICENSE)).
Windows 앱이 쓰는 오픈소스: [Tauri](https://tauri.app)(MIT/Apache-2.0), [React](https://react.dev)(MIT), [xterm.js](https://xtermjs.org)(MIT), [portable-pty](https://github.com/wezterm/wezterm)(MIT), [Lucide](https://lucide.dev) 아이콘(ISC) 등 — 각 패키지의 라이선스를 따릅니다.
