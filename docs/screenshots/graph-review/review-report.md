# browser 변경 리뷰

- 브랜치: main
- 생성: 2026-10-25T23:14:45+0900
- 범위: 작업 트리 · 스테이지 포함 · 미추적 파일 excluded
- 선택 ref: main
- 기준 SHA: ac072b86599bfc60f81adc7193e035935ff026fb
- 현재 HEAD: ac072b86599bfc60f81adc7193e035935ff026fb · 스냅샷 worktree
- merge-base: 적용
- 필터: {"language":"all","query":"","folder":"","includeHeuristic":true,"includeTests":true,"depth":3,"hiddenGroups":\[\],"canvas":{"relation":"files","unit":"file","onlyDiff":false,"onlyAffected":false}}

## 선택 변경과 리뷰 순서

- packages/a/src/f1.ts · 본문 또는 선언 변경 · 새 규칙 위반 1
- packages/a/src/f2.ts · 본문 또는 선언 변경 · 새 규칙 위반 1
- swift/Value.swift · 본문 또는 선언 변경 · 변경 내용 확인
- 한글 space ' \<b\>&.ts · 본문 또는 선언 변경 · 변경 내용 확인
- dotnet/App.cs · 본문 또는 선언 변경 · 변경 내용 확인
- packages/a/src/legacy moved.js · 이름 변경 · 이전 packages/a/src/legacy.js · 변경 내용 확인

## 직접 확인 대상 · 3

- packages/a/src/f8.ts → packages/a/src/f1.ts · 1단계
- packages/a/tests/review.test.ts → packages/a/src/f1.ts · 1단계
- swift/Caller.swift → swift/Value.swift · 1단계 · 추정 포함

## 간접 확인 대상 · 2

- packages/a/src/f7.ts → packages/a/src/f8.ts → packages/a/src/f1.ts · 2단계
- packages/a/src/f6.ts → packages/a/src/f7.ts → packages/a/src/f8.ts → packages/a/src/f1.ts · 3단계

## 순환과 규칙 비교

- 순환 신규: 0
- 순환 구성 변경: 0
- 순환 해소: 0
- 순환 기존: 1
  - packages/a/src/f1.ts ⇄ packages/a/src/f2.ts ⇄ packages/a/src/f3.ts ⇄ packages/a/src/f4.ts ⇄ packages/a/src/f5.ts ⇄ packages/a/src/f6.ts ⇄ packages/a/src/f7.ts ⇄ packages/a/src/f8.ts
- 규칙 기존 · error · forbid packages/a/src/f1.ts -\> packages/a/src/f2.ts · packages/a/src/f1.ts → packages/a/src/f2.ts · 규칙 2행
- 규칙 신규 · error · forbid packages/a/src/f2.ts -\> packages/a/src/f1.ts · packages/a/src/f2.ts → packages/a/src/f1.ts · 규칙 3행

## 테스트 후보와 선정 근거

- packages/a/tests/review.test.ts
  - 직접 참조 · packages/a/tests/review.test.ts → packages/a/src/f1.ts
  - 같은 모듈 · 관례 후보

실행 가능한 프로젝트 명령을 확인하지 못하여 실행 명령은 제안하지 않습니다. 경로를 사용해 직접 실행하세요.

## 추정과 분석 한계

- 추정 포함/제외 시 변경과 확인 대상 합계: 11/10
- 영향은 정적 의존 경로상 확인 대상이며 런타임 오류를 예측하지 않습니다.
- 참조가 없더라도 미사용 코드로 단정할 수 없습니다. 엔트리 포인트·동적 로딩·지원하지 않는 문법은 누락될 수 있습니다.
- 비교 양쪽은 같은 정적 분석기를 사용합니다. 외부 컴파일러 인덱스와 매니페스트 실행을 제외하여 노후 인덱스에 의존하지 않습니다.
- 검색·언어·폴더 필터는 시작 변경 파일을 고릅니다. 의존 경로는 연결된 다른 언어·폴더까지 추적합니다. 그래프 표시 전용 필터는 보고서에 설정으로 기록합니다.
- 미추적 파일 제외 · 폴더 범위 전체 · 언어 all · 3단계 탐색
- Swift: 파일끼리 import 하지 않아서, 다른 파일에 선언된 최상위 타입(class · struct · enum · protocol · actor · typealias) 이름을 쓰면 연결로 추정했습니다 (heuristic: true, 그림에서는 점선).
- 파일만 인식·미지원: 11개
  - deploy/Dockerfile
  - dotnet/App.cs
  - java/pom.xml
  - package.json
  - packages/a/package.json
  - packages/a/src/asset.constructor
  - packages/a/src/asset.toString
  - packages/a/src/logo.png
  - packages/b/package.json
  - php/composer.json
  - python/pyproject.toml
