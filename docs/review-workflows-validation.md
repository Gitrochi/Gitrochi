# Push 검토 · PR 줄 리뷰 · 변경 AI 질문

검증일: 2026-10-26. macOS와 Windows 클라이언트에 같은 세 흐름을 구현했다.

## 사용 위치와 동작

| 기능 | 사용 위치 | 동작 |
| --- | --- | --- |
| Push 전 검토 | Push, 브랜치 Push, Force Push, PR/MR 생성에 필요한 Push | 계정·연결된 인증 계정·실제 Push 주소·대상 브랜치·커밋·파일·gitch 사전 점검을 확인한 후 전송한다. 검토한 커밋과 대상을 고정하고 전송 직전에 설정과 원격 상태를 다시 확인한다. |
| PR/MR 줄 댓글·일괄 리뷰 | PR/MR의 변경 파일 diff 줄 옆 댓글 버튼, 리뷰 패널 | 댓글 초안을 저장·수정·삭제한 뒤 모아 제출한다. GitHub는 댓글과 최종 의견을 한 리뷰로 보내고 GitLab은 토론을 순차 게시한 뒤 승인한다. 답글과 GitLab 토론 해결·다시 열기를 지원한다. |
| 선택한 변경에 AI 질문 | diff의 **AI에게 질문…**, 작업 메뉴 | 선택한 파일·줄·커밋 또는 스테이지 변경을 미리 확인한 뒤 질문한다. 후속 질문은 같은 내용을 사용하고 **새로 담기**로 갱신한다. 기존 설명용 AI 설정을 사용한다. |

Push 검토를 취소하면 전송하지 않는다. PR 생성 전 취소한 제목·본문·대상 브랜치도 보관한다. 모호한 다중 Push 설정이나 누락된 비교 객체는 안내 후 멈춘다. Force Push는 검토 시 확인한 원격 커밋에 대한 lease를 사용한다.

리뷰 초안은 저장소·PR/MR·head 커밋에 묶는다. 서버의 내용이 바뀌면 최신 diff에서 다시 작성하도록 안내한다. 일부 게시 실패나 응답 유실 뒤 재시도할 때는 확인된 댓글을 대조하여 중복을 줄이고 보내지 못한 초안을 보관한다. GitHub 토론 해결은 브라우저에서 진행한다.

AI 미리보기를 여는 것만으로 요청하지 않는다. **질문 보내기**를 누르면 미리 본 내용을 보내며 파일을 수정하지 않는다. 유효한 스테이지 영향 분석이 있으면 관련 파일과 테스트 후보를 참고 자료로 포함하되 실제 테스트 실행 결과로 표시하지 않는다. 저장소나 AI 설정을 바꾼 후 도착한 이전 응답은 현재 대화에 반영하지 않는다.

## 확인 결과

| 검사 | 결과 |
| --- | --- |
| macOS 앱 전체 빌드 | arm64 개발용 앱 빌드 통과, ad-hoc 서명 |
| `bash macos/Tools/test-push-review.sh` | 목적지 선택·설정 차단·주소 가림·고정 커밋·force lease 검사 통과 |
| `bash macos/Tools/test-pull-request-review.sh` | GitHub/GitLab 응답·페이지 처리·줄 위치·변경된 head·부분 실패·응답 유실 후 재시도 검사 통과 |
| `bash macos/Tools/test-change-question.sh` | 질문 문맥·선택 범위·길이 제한 검사 통과 |
| Windows `npm run build` | TypeScript 검사와 제품용 화면 빌드 통과 |
| Windows `npm test` | 24개 파일, 214개 테스트 통과. 기존 검사와 새 기능 검사를 모두 포함 |
| `cargo check --manifest-path windows/src-tauri/Cargo.toml` | macOS 호스트에서 Tauri Rust 검사 통과 |
| 실제 React 화면 조작 | AI 입력·전송·답변, 댓글 수정·삭제·일괄 제출, Push 취소·확정 검사 통과. 외부 서비스는 가짜 응답 사용 |
| 화면 확인 | 세 화면의 라이트·다크 테마 확인 |

새 macOS 검사 세 개는 CI에 연결했고 Windows 검사는 기존 `npm test`에 포함했다. 한국어 문구와 README 사용 안내를 추가했다.

## 화면 자료

모든 캡처는 가상 저장소와 가짜 서비스로 만든 검증 화면이다.

| 화면 | 라이트 | 다크 |
| --- | --- | --- |
| Push 검토 | [보기](screenshots/review-workflows/push-light.png) | [보기](screenshots/review-workflows/push-dark.png) |
| PR 줄 리뷰 | [보기](screenshots/review-workflows/pr-light.png) | [보기](screenshots/review-workflows/pr-dark.png) |
| AI 질문 | [보기](screenshots/review-workflows/ai-light.png) | [보기](screenshots/review-workflows/ai-dark.png) |

[화면 조작 검사 결과](screenshots/review-workflows/result.json).

## 검증 범위

Windows 실기기의 WebView·자격 증명 저장소·설치 파일 실행, 새 macOS 앱의 실제 서버 연결은 이번 검증에 포함하지 않았다. 실제 원격 Push, 실제 PR/MR 댓글·승인, 유료 AI 요청도 실행하지 않았다. 인증·서버 권한·GitLab 버전별 정책은 실제 연결 환경에서 추가 확인이 필요하다.

macOS 결과물은 `macos/build/Gitrochi.app`이다. Windows는 화면 빌드와 Rust 검사를 마쳤으며 Windows 설치 파일을 생성하지 않았다. 기존 검색 작업의 수정은 유지했고 커밋·Push·릴리스 배포는 하지 않았다.
