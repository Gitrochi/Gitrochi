# 확장 작업 흐름 구현과 검증

검증일: 2026-10-26. Mac·Windows 양쪽에 구현했다. 기존 Push 검토·줄 댓글 일괄 리뷰·선택 변경 AI 질문과 함께 사용할 수 있다.

## 사용 위치

| 기능 | 진입과 동작 |
| --- | --- |
| 두 커밋·브랜치·태그 비교 | 저장소 메뉴 → **두 시점 비교…**. 직접/공통 조상 기준, 방향 변경, 변경 파일·diff를 제공하며 시점을 SHA로 고정한다. |
| 여러 커밋 일괄 작업 | 그래프의 ⌘/Ctrl·Shift 선택. 순서 검토 후 cherry-pick/revert, 현재 브랜치의 인접 커밋 squash, 선택 커밋 drop 계획을 실행한다. 미완료 작업·HEAD 변경·작업 파일 변경을 검사하고 복구 참조를 남긴다. |
| 3열 충돌 편집 | 충돌 파일을 연다. 내 변경·최종 결과·상대 변경과 공통 조상을 보고 결과 전체를 편집한다. 동기 스크롤과 기존 블록별 선택을 제공하며 미해결 표식·원본·인덱스 변경을 검사한다. |
| PR/MR 관리 | PR/MR 목록에서 상태·내 요청·리뷰 요청 검색과 페이지 탐색. 상세에서 제목·본문·대상·리뷰어를 고치고 병합·닫기·다시 열기를 진행한다. 병합 전 최신 SHA·대상·권한·CI·승인·서버 정책을 확인한다. GitHub 토론 해결·다시 열기도 제공한다. |
| 복구 이력·버린 변경 복구 | 저장소 메뉴 → **저장소 도구… → 복구**. reflog에서 새 브랜치를 만들거나, 변경 버리기 전 보관한 작업 파일·스테이지를 원래 HEAD의 깨끗한 작업 트리로 복원한다. |
| 여러 저장소 통합 현황 | 저장소 메뉴 → **통합 작업함…**. 열린 저장소의 브랜치·계정·변경 수·원격 대비 차이를 보고 이동한다. CI·리뷰 요청은 각 저장소의 선택 계정으로 버튼을 눌러 갱신하며 최근 저장소도 연다. |
| 저장소 탐색 AI | 작업 메뉴 → **저장소 AI 도우미…**. 상태·최근 이력·파일 목록을 미리 확인한 뒤 질문한다. AI가 필요한 추적 파일·이력·diff·검색을 읽기 전용 도구로 요청하고 읽기 기록을 보여 준다. |
| 외부 AI용 MCP | 저장소 메뉴 → **MCP로 외부 AI 연결…**. 현재 저장소 전용 설정 복사·연결 시험. stdio와 엄격한 인자를 사용하고 임의 셸·쓰기·네트워크 도구를 노출하지 않는다. [도구·설정·제한](../tools/gitrochi-mcp/README.md) |
| LFS 관리 | **저장소 도구… → LFS**. 설치 감지·추적 패턴·객체 검사·서버 잠금 조회/생성/해제. 잠금 해제는 대상을 확인하며 강제 해제를 사용하지 않는다. |
| Submodule 관리 | **저장소 도구… → 하위 저장소**. 기록된 SHA·상태·URL 확인, 초기화·정확한 커밋 갱신·열기. 경로 이탈·외부 실행 프로토콜·URL/원격 변경·내부 작업 변경을 검사한다. |
| 선택 줄·함수 이력 | diff·파일 보기에서 줄 이력을 연다. 줄 범위 또는 함수 기준과 시점을 지정해 최대 200개 변경 이력·패치를 확인한다. 삭제 줄은 이전 시점으로 추적한다. |
| Bisect | **저장소 도구… → 문제 커밋 찾기**. 정상/문제 시점 검토 → 현재 검사 커밋 → 정상/문제/건너뛰기 → 최초 문제 커밋 표시 → 원래 브랜치 복귀. |
| 이슈·멘션 작업함 | 저장소 메뉴 → **이슈와 멘션…**. 선택한 저장소·연결 계정의 담당 이슈·리뷰 요청·멘션을 읽고 댓글·이슈 상태·지원되는 알림 읽음을 처리한다. |

## 검증

- Mac 앱 전체 arm64 빌드와 ad-hoc 서명 통과.
- Windows TypeScript 검사·제품용 화면 빌드와 macOS 호스트의 Tauri Rust 검사 통과.
- Windows 전체 단위·실제 Git 통합 검사: **29개 파일, 278개 검사 통과**. 기존 기능과 새 기능 검사를 모두 포함한다.
- Mac Git 핵심 검사: 32개 통과. 비교·협업·로컬 도구의 새 독립 검사와 기존 Push·리뷰·AI 검사도 실행했다.
- 공통 Node 읽기 도구: 9개 검사 통과. 파일 경계·비밀 경로·심볼릭 링크·바이너리·길이 제한·비밀값 가림·HEAD/index/파일 불변·stdio 초기화·취소를 포함한다.
- 실제 React 화면 조작 5묶음 모두 통과. 비교·일괄 작업·이력·충돌·복구·LFS·Submodule·Bisect·협업·AI·MCP·작업함을 가짜 서비스로 조작했으며 예상 밖 백엔드 호출은 0건이다.
- 가상 저장소로 13개 화면의 라이트·다크 26장을 확인했다. 검사 중 발견한 이슈함 모달 누락·가로 넘침·배경 토큰을 수정했다.

주요 명령:

```sh
GITROCHI_SIGN_IDENTITY=- macos/build.sh
bash macos/Tools/test-git-core.sh
bash macos/Tools/test-history-tools.sh
bash macos/Tools/test-collaboration.sh
bash macos/Tools/test-local-workflows.sh
node --test tools/gitrochi-mcp/server.test.mjs
cd windows
npm run build
npm test
cargo check --manifest-path src-tauri/Cargo.toml
```

새 Mac 검사와 Node MCP 검사를 CI에 연결했다. Windows 기존 단위 검사·실제 앱 자동 점검에 새 기능을 포함했고 설치본·포터블 ZIP 모두 공통 읽기 도구를 포함하도록 구성했다. 한국어 번역과 README 사용 안내를 갱신했다.

## 화면과 원자료

모든 화면은 가상 저장소·가짜 응답으로 생성했다. Mac의 실제 실행 화면 캡처와 Windows 실기기 캡처는 포함하지 않는다.

| 화면 | 라이트 | 다크 |
| --- | --- | --- |
| 비교 | [보기](screenshots/complete-workflows/compare-light.png) | [보기](screenshots/complete-workflows/compare-dark.png) |
| 커밋 일괄 작업 | [보기](screenshots/complete-workflows/batch-light.png) | [보기](screenshots/complete-workflows/batch-dark.png) |
| 줄·함수 이력 | [보기](screenshots/complete-workflows/lines-light.png) | [보기](screenshots/complete-workflows/lines-dark.png) |
| 충돌 편집 | [보기](screenshots/complete-workflows/conflict-light.png) | [보기](screenshots/complete-workflows/conflict-dark.png) |
| 복구 | [보기](screenshots/complete-workflows/recovery-light.png) | [보기](screenshots/complete-workflows/recovery-dark.png) |
| PR/MR 관리 | [보기](screenshots/complete-workflows/lifecycle-light.png) | [보기](screenshots/complete-workflows/lifecycle-dark.png) |
| 이슈함 | [보기](screenshots/complete-workflows/inbox-light.png) | [보기](screenshots/complete-workflows/inbox-dark.png) |
| 저장소 AI | [보기](screenshots/complete-workflows/assistant-light.png) | [보기](screenshots/complete-workflows/assistant-dark.png) |
| MCP | [보기](screenshots/complete-workflows/mcp-light.png) | [보기](screenshots/complete-workflows/mcp-dark.png) |
| 통합 작업함 | [보기](screenshots/complete-workflows/workspace-light.png) | [보기](screenshots/complete-workflows/workspace-dark.png) |

[React 자동 조작 결과](screenshots/complete-workflows/result.json), [화면 검증 목록](screenshots/complete-workflows/validation-summary.json). LFS·Submodule·Bisect 화면도 같은 폴더에 있다.

## 동작 범위와 남은 검증

- Windows 실기기 실행·설치 파일 생성과 실서버 PR/MR 쓰기는 수행하지 않았다. CI 구성은 추가했으나 원격에 올려 실행하지 않았다.
- Git LFS가 검증 장비에 없어 LFS 실행은 모사한 명령·응답으로 검사했다. 실제 서버 잠금 권한·GitLab 버전/프로젝트별 병합 정책·인증 환경은 연결 환경에서 확인해야 한다.
- 원격 Push·실제 댓글·병합·승인·유료 AI 요청은 실행하지 않았다. 기존 계정·인증·SSH·훅 설정을 변경하지 않았다.
- 이슈함은 현재 저장소·연결 계정 범위다. 통합 작업함은 열린 저장소별 현황을 모으며 모든 계정을 무조건 조회하지 않는다. CI와 리뷰 요청은 불러온 페이지의 요약이고 전체 총계로 표시하지 않는다.
- 안전 사본은 로컬 Git 객체와 워크트리별 참조로 보관한다. 200MB·20,000파일 한도를 넘거나 충돌 중이면 버리기를 중단한다. 별도 백업 장치의 대체가 아니며 영구 작업 파일 복원은 원래 HEAD·깨끗한 상태를 요구한다.
- 저장소 AI·MCP는 Node.js 22 이상이 필요하다. 대화 1회당 최대 6번 읽기, 파일 64KB, 응답 18,000자 등 제한이 있다. 비밀 경로·흔한 비밀 형식을 제외/가리지만 모든 비밀값을 식별하는 것은 아니다. 파일은 읽은 시점의 내용이며 전체 작업 트리를 동결하지 않는다.
- gitch 의존 비교는 기존 브랜치 변경도 포함하며 미추적 새 파일을 제외한다. Windows의 전체 소스 의존 규칙·순환 검사는 구조 테스트로 별도 확인했다.

기존 검색 관련 사용자 수정과 앞선 세 기능은 유지했다. 변경은 로컬 작업 브랜치에 있고 커밋·Push·릴리스 배포는 하지 않았다.
