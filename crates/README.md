# Shared Rust core

Gitrochi의 두 화면과 CLI가 공유하는 계산 코어다. 운영체제 화면은 SwiftUI·React에, Git 실행과 인증·훅은 기존 시스템 Git·gitch 흐름에 둔다.

## 실행 경계

| 소비자 | 실행 방식 | 담당 범위 |
| --- | --- | --- |
| macOS | 아키텍처별 Rust 정적 라이브러리 + C ABI | Git 출력 파싱, diff·부분 패치, 충돌 해석·해결, 커밋 그래프 |
| Windows 화면 | 동일 Rust 소스의 WebAssembly | 같은 계산; 큰 diff·커밋·blame·이력은 worker에서 실행 |
| 앱에 포함된 gitch | `gitch-core` 네이티브 실행 파일 | 구조 그래프 JSON 생성, 기준·현재 그래프의 변경 영향 계산 |
| 단독 gitch 스크립트 | 기존 Bash·AWK 경로 | 네이티브 도우미가 없어도 기존 명령·계약을 유지 |

도우미는 gitch 옆의 `gitch-core` 또는 `gitch-core.exe`에서 찾는다. `GITCH_CORE=/path/to/gitch-core`로 지정할 수 있고 빈 값은 기존 셸 경로를 선택한다. 언어별 정적 import 수집, Swift 컴파일러 인덱스, SCIP·감시 프로토콜은 기존 구현을 유지한다. 메모리·네트워크 대기 위주의 운영체제 통합이나 단순 UI 상태를 다른 언어로 바꾸는 이점은 확인되지 않았다.

## 계산과 성능

- 단어 diff의 LCS 표는 행마다 할당한 배열 대신 연속 `u16` 메모리를 쓴다. 기존 400토큰 상한과 70% 변경 비율을 유지한다.
- 커밋 그래프는 ID를 정수로 치환하고 연속 정수 버퍼로 전달한다. 입력은 커밋 수, 각 커밋의 ID·WIP 플래그·부모 수·부모 ID다. 출력은 행 수·최대 레인 수, 각 행의 열·색·폭·선분 수와 선분당 정수 6개다. y좌표는 반 행 단위다. 모든 정수는 little-endian `u32`다.
- 범용 계산은 UTF-8 JSON 요청/응답을 쓴다. 결과 버퍼는 little-endian `u64` 본문 길이와 본문이다. `gitrochi_free`가 각 호출의 버퍼를 해제한다. 전역 결과 포인터를 공유하지 않는다.
- Swift 강조 범위는 확장 자소, TypeScript 범위는 코드포인트다. `scalarOffsets`로 이 경계를 명시해 한글·결합 문자·이모지의 위치를 보존한다.
- diff 파싱 시 나란히 보기와 양쪽 줄 유무를 함께 계산하고 화면에서 재사용한다. Windows의 WeakMap 캐시는 문서 수명이 끝나면 회수된다.
- worker 큐는 한 번에 한 계산만 실행한다. 선택을 바꿔 취소한 대기 계산은 실행하지 않으며, 실행 중 계산의 늦은 응답은 세대 검사로 폐기한다. worker 오류는 모든 대기 요청을 종료하고 다음 요청에서 새 worker를 만든다.
- Windows 프로세스 실행은 비동기 세마포어로 최대 16개만 허용한다. 대기 요청이 OS 프로세스·파이프나 차단 스레드를 먼저 만들지 않는다.
- CLI 변경 영향은 큐 기반 역방향 탐색과 폴더 조상별 소유 모듈 탐색을 쓴다. 삭제·이름 변경에는 기준 그래프도 포함한다. 공개 JSON 필드·확장 속성과 기존 HTML의 인라인 표기를 유지한다.

2026-10-26, 이 개발 Mac의 단일 세션에서 기존 구현과 실제 호출 경계를 포함해 비교했다. 100개 식별자가 있는 한 줄에서 하나를 바꾼 단어 diff는 Windows용 JS 약 0.81ms → WASM 0.37ms, Swift 약 1.02ms → 네이티브 Rust 0.33ms였다. 각 값은 워밍업 후 20~50회 측정의 중앙값이다. 직선 2,000커밋 그래프는 JS 약 0.11ms → Rust 버퍼 경로 0.23ms, Swift 약 0.33ms → Rust 버퍼 경로 0.42ms였다. 그래프는 언어 경계 비용이 남지만 초기 JSON 경로의 약 4.88ms는 제거했다. 전체 앱이 같은 배수로 빨라진다는 의미는 아니다.

실제 브라우저의 `windows/tests/core-worker.html`은 801줄 diff, 2,000개 그래프 행, 10개 대기 요청을 검사한다. 최초 관찰에서는 약 113ms 동안 메인 스레드 타이머가 28회 진행됐다. 이 값은 실제 Windows 장비의 벤치마크가 아니며 플랫폼 전체의 성능을 보장하지 않는다.

## 빌드·검사

Rust 1.88 이상, rustup 배포판을 권장한다. Windows 개발에는 Node.js 22 이상과 `wasm32-unknown-unknown` 타깃이 필요하다. macOS 유니버설 릴리스에는 `aarch64-apple-darwin`·`x86_64-apple-darwin` 표준 라이브러리가 필요하다.

```sh
rustup target add wasm32-unknown-unknown
cargo test --locked --manifest-path crates/Cargo.toml
cargo clippy --manifest-path crates/Cargo.toml --all-targets -- -D warnings
node tools/build-core.mjs
bash macos/Tools/test-git-core.sh
GITCH_CORE="$PWD/crates/target/release/gitch-core" bash tools/gitch/tests/run.sh -k graph
GITCH_CORE='' bash tools/gitch/tests/run.sh -k graph
```

`cd windows && npm test`는 생성부터 단위·실제 Git 연동 검사까지 실행한다. `npm run build`는 생성·타입 검사·배포용 프런트엔드 빌드를 실행한다. 브라우저 worker 검사는 개발 서버에서 `/tests/core-worker.html`을 연다. macOS 앱은 `macos/build.sh`로 빌드한다. 작업별 출력 폴더는 `GITROCHI_BUILD_DIR`·`GITROCHI_OBJECT_DIR`로 지정할 수 있다.

WASM과 네이티브 CLI는 빌드 산출물이며 소스에 넣지 않는다. `Cargo.lock`은 고정한다. 시스템 Rust를 변경하지 않고 `.build/rust-tools/rustup/toolchains/stable-<host>/bin`에 준비한 프로젝트 전용 툴체인도 빌드 도구가 인식한다. 다른 실행 파일은 `GITROCHI_CARGO`·`RUSTC`로 지정할 수 있다.

참고: [Rust WebAssembly 타깃](https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html), [Rust FFI](https://doc.rust-lang.org/nomicon/ffi.html).
