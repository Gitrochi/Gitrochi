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
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Community%20Use%20v1.0%20proposed-6b6b72" alt="Community Use v1.0 proposed"></a>
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
- **흐름** — 저장소의 테스트 · 점검 · 서비스 · 배포 단계를 `.gitch/flow.yml` 에 조립해 앱 · `gitch flow` · push 전 · CI 에서 같은 방법으로 돌림: 이 컴퓨터에서, Docker 에서, 또는 GitLab CI · GitHub Actions · Jenkins 로, 단계가 실패하면 되돌림

- **저장소 화면** — 브랜치, 터미널을 아래에 둔 그래프, 변경 내용 또는 커밋 상세를 나란히 표시; 비교·리베이스·Code는 별도 페이지; 페이지 목록은 아이콘 메뉴로 접힘
- **리뷰와 고급 Git 도구** — Push 전 계정·목적지·변경 검토, 줄 댓글 초안·일괄 리뷰, 두 시점 비교·여러 커밋 선택·3열 충돌 편집, 복구 이력·LFS·Submodule·Bisect
- **연결 작업** — PR/MR 관리·이슈·Actions와 수신함·릴리스·프로젝트·조직을 모은 계정 페이지, 툴바의 계정 표시, 선택 변경 AI 질문·저장소 읽기 도구·로컬 읽기 전용 MCP
- **공통 Rust 코어** — 양쪽 앱의 파서·diff·패치·충돌·그래프 계산을 공유하고 무거운 계산의 취소·백그라운드 실행 지원, 커밋 검색은 띄어쓰기 무시
- **저장소 인덱스** — 전체 커밋 기록, 커밋별 파일 변경, 함께 바뀌는 파일 관계를 공통 Rust 코드가 SQLite에 저장하고, C++ 토크나이저로 코드 식별자와 한국어·일본어·중국어를 색인합니다. 검색 막대가 여기서 바로 답하며, Python 도구(AI 리뷰·분석·테스트 계획·런타임 관리)와 Go 팀 허브·모니터가 이를 이용합니다 — [언어별 역할](docs/architecture.md)(영어)

사용법과 단축키까지 전체 목록: [docs/features.md](docs/features.md)(영어).

## 구현과 검증

[리뷰 작업](docs/review-workflows-validation.md), [확장 기능](docs/complete-workflows-validation.md), [탐색 화면](docs/navigation-workspace-validation.md), [공통 코어](crates/README.md)에 구현 범위와 검증을 정리했습니다. 임시 저장소와 가짜 서비스로 검사했으며, Windows 실기기 설치·실제 LFS 잠금·실서버 쓰기는 환경별 추가 확인이 필요합니다. 저장소 AI·MCP는 Node.js 22 이상, LFS 작업은 Git LFS가 필요합니다.

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

[Gitrochi Community Use License v1.0 제안](LICENSE) — **아직 시행되지 않은 검토안**입니다. 개인·기업의 무료 사용, 무단 재판매·독립 파생 프로젝트 배포 금지, 공식 저장소 PR 기여를 제안합니다. 시행에 필요한 저작권자 권한·동의와 법적 세부사항은 [전환 검토 기록](docs/licensing-review.md)에 정리합니다.

© 2026 조문성 (ChoMnSeong), [jjunhaa0211](https://github.com/jjunhaa0211). 별도 프로젝트 MIT 라이선스 파일과 MIT 표시는 제거했습니다. 이미 MIT 로 제공된 코드의 권리와 필요한 [과거 자료 고지](THIRD_PARTY_NOTICES.md#prior-mit-covered-gitrochi-material)는 유지됩니다. 제안이 채택되더라도 사용·배포 제한이 있는 source-available 정책이므로 오픈소스 라이선스로 표시하지 않습니다.

포함: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)(MIT). Windows 앱은 [Tauri](https://tauri.app), [React](https://react.dev), [xterm.js](https://xtermjs.org), [portable-pty](https://github.com/wezterm/wezterm), [Lucide](https://lucide.dev) 위에 있으며 각자의 라이선스를 따릅니다. 제안 라이선스는 이들 서드파티 코드의 권리를 제한하지 않습니다 — [서드파티 고지와 의존성 검토 범위](THIRD_PARTY_NOTICES.md)(영어). Rust 의존성의 배포 대상별 전체 고지 검토는 아직 끝나지 않았습니다.
