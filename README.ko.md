<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Gitrochi 아이콘">
</p>

<h1 align="center">Gitrochi</h1>

<p align="center">
  <b>커밋 그래프로 보고, 클릭으로 다루는 Git 클라이언트.</b><br>
  macOS · Windows
</p>

<p align="center">
  <a href="README.md">English</a> · 한국어 · <a href="README.ja.md">日本語</a>
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
  &nbsp;·&nbsp; <a href="docs/features.md">사용법과 기능(영어)</a>
  &nbsp;·&nbsp; <a href="CONTRIBUTING.md">기여(영어)</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" alt="Gitrochi 메인 화면 — 왼쪽 브랜치·태그, 가운데 커밋 그래프, 오른쪽 작업 중인 변경과 커밋 입력">
  </picture>
</p>

Gitrochi 는 맥과 Windows 용 네이티브 Git 클라이언트입니다. 히스토리를 읽기 쉬운 커밋 그래프로 그리고, 스테이지 · 커밋 · 브랜치 · 머지 · 리뷰를 클릭으로 합니다. GitHub · GitLab, CI/CD, AI 가 쓰는 커밋 메시지, 코딩 에이전트, 터미널이 앱 안에 있습니다. 일은 Git 이 합니다 — Gitrochi 는 시스템의 `git` 을 부릅니다.

## 기능

- **커밋 그래프** — 모든 브랜치를 레인 색으로, 브랜치·태그는 왼쪽 칸에, 작성자 프로필 사진과 CI 상태, 워크트리마다의 작업 중인 변경을 맨 위에
- **스테이지와 커밋** — 파일 · 덩어리 · 줄 단위, 한 줄로·나란히 diff(단어 단위 강조, 이미지 비교), 충돌 해결, 커밋 정리(합치기 · 순서 · 메시지), 마지막 작업 되돌리기
- **끌어다 놓는 브랜치** — 브랜치를 커밋 위에 놓으면 머지 · 리베이스 · 빨리 감기, 커밋을 브랜치에 놓으면 cherry-pick
- **GitHub · GitLab** — PR/MR 을 앱 안에서 리뷰 · 승인 · 만들기(Markdown), 사내 GitLab 도
- **CI/CD** — GitLab 파이프라인과 GitHub Actions: 수동 작업 실행, 다시 실행, 취소, 배포 승인, 워크플로 실행
- **AI** — Claude Code · Codex · Gemini CLI 또는 API 키가 팀 규칙대로 커밋 메시지와 PR 글을 쓰고, 변경을 주제별로 나눠 커밋
- **코딩 에이전트** — Claude Code · Codex · Gemini CLI 세션을 워크트리마다 내장 터미널에서 띄우고 상태를 사이드바에서
- **터미널** — 그래프 아래 저장소 폴더의 셸을 탭과 분할 패널로, git 명령을 치면 그래프가 바로 갱신
- **gitch** — 함께 들어가는 CLI 가 저장소마다 Git 계정을 섞이지 않게 잠그고, 잘못된 작성자 · 비밀값 · 강제 push 를 훅에서 막음

사용법과 단축키까지 전체 목록: [docs/features.md](docs/features.md)(영어).

## 설치

**macOS 15 이상**(Apple Silicon · Intel): [최신 릴리스](https://github.com/Gitrochi/Gitrochi/releases/latest)에서 `.dmg` 를 받아 `Gitrochi.app` 을 응용 프로그램 폴더로 옮깁니다. 아직 공증을 받지 않은 빌드라 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**로 허용하거나 `xattr -dr com.apple.quarantine /Applications/Gitrochi.app` 을 실행하세요. `git` 이 필요합니다(Xcode 또는 `xcode-select --install`).

**Windows 10 (1809) 이상, x64**: [최신 릴리스](https://github.com/Gitrochi/Gitrochi/releases/latest)에서 `Gitrochi_<버전>_x64-setup.exe` 를 받아 실행합니다(`_portable.zip` 은 설치 없이). SmartScreen 이 막으면 **추가 정보 → 실행**. [Git for Windows](https://git-scm.com/download/win) 가 필요합니다.

두 앱 모두 자동 업데이트합니다. 켤 때와 하루에 한 번 새 버전을 확인하고, 서명과 해시가 맞을 때만 설치합니다.

## 기여

- [CONTRIBUTING.md](CONTRIBUTING.md) — 시작하기, 빌드, PR
- [docs/code-style.md](docs/code-style.md) · [docs/git-workflow.md](docs/git-workflow.md) — 코드 · 커밋 · 브랜치 규칙
- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — 코딩 에이전트용 같은 규칙

문서는 영어로 되어 있습니다.

## 피드백

- 🐞 [버그 제보](https://github.com/Gitrochi/Gitrochi/issues/new?template=bug_report.yml) · ✨ [기능 요청](https://github.com/Gitrochi/Gitrochi/issues/new?template=feature_request.yml) · 💬 [질문](https://github.com/Gitrochi/Gitrochi/issues/new?template=question.yml)
- 보안 문제는 이슈 대신 [비공개로](SECURITY.md)

## 라이선스

Copyright © 2026 조문성 (ChoMnSeong), [jjunhaa0211](https://github.com/jjunhaa0211). [MIT 라이선스](LICENSE)입니다. 저작권 표시만 남기면 상업적으로 쓰고, 고치고, 다시 배포할 수 있습니다. 보증은 없고, 이름과 아이콘은 라이선스에 포함되지 않습니다.

포함: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)(MIT). Windows 앱은 [Tauri](https://tauri.app), [React](https://react.dev), [xterm.js](https://xtermjs.org), [portable-pty](https://github.com/wezterm/wezterm), [Lucide](https://lucide.dev) 위에 있으며 각자의 라이선스를 따릅니다.
