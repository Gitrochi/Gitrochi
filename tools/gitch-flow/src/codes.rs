//! 실패 코드 목록. 모든 실패는 코드 · 설명 · 조치를 함께 보인다.
//! 앱은 코드로 화면 글을 고르고, 모르는 코드는 엔진이 준 글을 그대로 보인다.

use serde_json::{json, Value};

/// (코드, 분류, 한국어 설명, 한국어 조치, 영어 설명, 영어 조치)
type Row = (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
);

pub const CODES: &[Row] = &[
    ("SPEC-01", "spec", "흐름 파일을 읽지 못했습니다.", "표시된 줄의 YAML 형식을 고치세요.", "The flow file could not be read.", "Fix the YAML at the reported line."),
    ("SPEC-02", "spec", "알 수 없는 키가 있습니다.", "철자를 확인하세요. 따로 쓰는 값은 x- 로 시작하는 키에 두세요.", "The flow file has an unknown key.", "Check the spelling. Put private values under keys that start with x-."),
    ("SPEC-03", "spec", "값의 형식이 맞지 않습니다.", "표시된 키의 값 형식을 고치세요.", "A value has the wrong type.", "Fix the value of the reported key."),
    ("SPEC-04", "spec", "없는 이름을 가리킵니다.", "needs · suite · service · flow · use 의 이름을 확인하세요.", "A reference points to something that does not exist.", "Check the names used in needs, suite, service, flow and use."),
    ("SPEC-05", "spec", "노드 의존이 순환합니다.", "needs 가 돌고 돌지 않게 고치세요.", "Node dependencies form a cycle.", "Break the cycle in needs."),
    ("SPEC-06", "spec", "표현식 ${{ }} 을 해석하지 못했습니다.", "지원하는 값 이름과 함수만 쓰세요(gitch flow explain SPEC-06).", "An expression ${{ }} could not be evaluated.", "Use only supported names and functions (gitch flow explain SPEC-06)."),
    ("SPEC-07", "spec", "비밀값을 명령 문자열에 직접 넣었습니다.", "비밀값은 env: 로만 넘기세요. 그래야 가려집니다.", "A secret is placed directly in a command string.", "Pass secrets only through env: so they can be masked."),
    ("SPEC-08", "spec", "흐름 파일이 없습니다.", "gitch flow init 으로 만드세요.", "No flow file was found.", "Create one with gitch flow init."),
    ("SPEC-09", "spec", "지원하지 않는 흐름 파일 버전입니다.", "version: 1 을 쓰거나 gitch 를 업데이트하세요.", "This flow file version is not supported.", "Use version: 1 or update gitch."),
    ("TRUST-01", "trust", "이 흐름 파일을 아직 신뢰하지 않았습니다.", "실행될 명령을 확인한 뒤 터미널에서 gitch flow trust 를 실행하거나 앱에서 승인하세요.", "This flow file is not trusted yet.", "Review the commands, then run gitch flow trust in a terminal or approve it in the app."),
    ("TRUST-02", "trust", "AI 실행 주체는 흐름 신뢰를 승인할 수 없습니다.", "사람이 터미널이나 앱에서 승인하세요.", "An AI agent cannot approve a flow.", "A person must approve it in a terminal or the app."),
    ("GUARD-01", "guard", "운영 환경에서 되돌리기 어려운 블록을 거부했습니다.", "운영은 기존 배포 절차를 쓰거나, 사용자 설정에서 이 저장소 · 환경을 명시적으로 허용하세요.", "A destructive block was refused on a production environment.", "Use the existing release process, or explicitly allow this repository and environment in user settings."),
    ("GUARD-02", "guard", "이 환경은 되돌림 실패로 잠겨 있습니다(hold).", "상태를 직접 확인한 뒤 gitch flow hold release <환경> 으로 푸세요.", "This environment is on hold after a failed rollback.", "Check it by hand, then run gitch flow hold release <environment>."),
    ("GUARD-03", "guard", "이 블록은 이 환경 등급에서 쓸 수 없습니다.", "블록이 허용하는 환경을 쓰세요(gitch flow block <ID>).", "This block cannot run in this environment class.", "Use an environment the block allows (gitch flow block <ID>)."),
    ("PLAN-01", "plan", "그런 흐름이 없습니다.", "gitch flow list 로 이름을 확인하세요.", "No flow has that name.", "List flows with gitch flow list."),
    ("PLAN-02", "plan", "그런 노드가 없습니다.", "gitch flow plan 으로 노드 이름을 확인하세요.", "No node has that name.", "Check node names with gitch flow plan."),
    ("PLAN-03", "plan", "그런 환경이 없습니다.", "environments: 에 정의한 이름을 쓰세요.", "No environment has that name.", "Use a name defined under environments:."),
    ("CONFIRM-01", "confirm", "사람의 확인이 필요합니다.", "터미널에서 직접 실행하거나 앱에서 확인하세요.", "A person must confirm this step.", "Run it in a terminal or confirm it in the app."),
    ("EXEC-01", "exec", "명령이 실패했습니다(종료 코드가 0 이 아님).", "로그 끝부분을 확인하세요.", "The command failed (non-zero exit code).", "Read the end of the log."),
    ("EXEC-02", "exec", "시간 제한을 넘었습니다.", "멈춘 곳을 로그에서 찾거나 timeout 을 늘리세요.", "The step exceeded its time limit.", "Find where it stopped in the log, or raise timeout."),
    ("EXEC-03", "exec", "취소 신호 뒤에도 끝나지 않아 강제로 끝냈습니다.", "종료 신호를 무시하는 하위 프로세스가 있는지 확인하세요.", "The process ignored the stop signal and was killed.", "Check for child processes that ignore termination signals."),
    ("EXEC-04", "exec", "실행 파일을 찾지 못했습니다.", "도구가 설치됐는지 gitch flow doctor 로 확인하세요.", "The program could not be started.", "Check that the tool is installed with gitch flow doctor."),
    ("EXEC-05", "exec", "실행이 취소됐습니다.", "필요하면 다시 실행하세요.", "The run was cancelled.", "Run it again if needed."),
    ("EXEC-06", "exec", "엔진이 실행을 끝내지 못하고 멈췄습니다(강제 종료 · 전원 꺼짐).", "기록을 닫았습니다. 다시 실행하세요.", "The engine stopped before the run finished (killed or powered off).", "The record was closed. Run the flow again."),
    ("TEST-01", "test", "통과율이 기준보다 낮습니다.", "실패한 테스트를 고치세요.", "The pass rate is below the threshold.", "Fix the failing tests."),
    ("TEST-02", "test", "테스트 보고서가 없거나 읽을 수 없습니다(판정 불가).", "실행기의 보고서 출력 설정(경로 · 형식)을 확인하세요.", "The test report is missing or unreadable (cannot judge).", "Check the runner's report output path and format."),
    ("TEST-03", "test", "실행된 테스트가 없습니다.", "테스트 경로 · 필터 · 설정을 확인하세요. 0개 실행은 통과가 아닙니다.", "No tests were executed.", "Check test paths, filters and configuration. Zero tests is not a pass."),
    ("TEST-04", "test", "종료 코드와 보고서가 서로 맞지 않습니다(판정 불가).", "실행기가 실패를 종료 코드로 알리는지, 보고서가 이번 실행 것인지 확인하세요.", "The exit code and the report disagree (cannot judge).", "Check that the runner reports failures through its exit code and that the report belongs to this run."),
    ("TEST-05", "test", "재시도해서야 통과한 불안정한 테스트가 있습니다.", "테스트를 고치거나 .gitch/flaky.yml 에 담당자 · 만료일과 함께 격리하세요.", "Some tests passed only after a retry (flaky).", "Fix them, or quarantine them in .gitch/flaky.yml with an owner and an expiry date."),
    ("TEST-06", "test", "테스트 밖에서 실패했습니다(빌드 · 테스트 파일 로드 실패).", "로그에서 컴파일 · import 오류를 찾으세요.", "Something failed outside the tests (build or test file load error).", "Look for compile or import errors in the log."),
    ("VERIFY-01", "verify", "기대한 응답을 받지 못했습니다.", "주소 · 포트 · 서비스 기동 로그를 확인하세요.", "The expected response was not received.", "Check the address, port and service startup log."),
    ("VERIFY-02", "verify", "앱이 말하는 빌드 식별자가 기대값과 다릅니다.", "올바른 빌드가 떠 있는지, 캐시된 옛 버전이 아닌지 확인하세요.", "The build identifier reported by the app differs from the expected one.", "Check that the right build is running and not an old cached one."),
    ("VERIFY-03", "verify", "판정에 필요한 관측값이 없습니다(판정 불가).", "관측 대상 설정을 확인하세요. 판정 불가는 실패로 셉니다.", "An observation needed for the verdict is missing (cannot judge).", "Check what is being observed. Cannot-judge counts as a failure."),
    ("VERIFY-04", "verify", "출력이 기대와 다릅니다.", "expect.output 과 실제 출력을 비교하세요.", "The output does not match the expectation.", "Compare expect.output with the actual output."),
    ("VERIFY-05", "verify", "기동 근거가 없거나 너무 빨리 끝났습니다.", "실제로 새로 떴는지 로그를 확인하세요.", "There is no startup evidence, or it finished suspiciously fast.", "Check the log to confirm the service really restarted."),
    ("VERIFY-06", "verify", "적용하지 않은 변경(마이그레이션)이 있습니다.", "변경을 확인 · 적용한 뒤 다시 실행하세요.", "There are pending changes (migrations).", "Review and apply them, then run again."),
    ("SERVICE-01", "service", "서비스가 준비되지 않았습니다(시간 초과).", "서비스 로그와 건강 확인 설정을 보세요.", "The service did not become ready in time.", "Check the service log and its health check."),
    ("SERVICE-02", "service", "서비스를 시작하지 못했습니다.", "명령 · 이미지 · 포트를 확인하세요.", "The service could not be started.", "Check the command, image and ports."),
    ("DOCKER-01", "docker", "Docker 에 닿지 못했습니다.", "Docker Desktop(또는 OrbStack · colima)을 켜세요.", "Docker is not reachable.", "Start Docker Desktop (or OrbStack, colima)."),
    ("DOCKER-02", "docker", "이미지를 받지 못했습니다.", "이미지 이름 · 네트워크 · 레지스트리 로그인을 확인하세요.", "The image could not be pulled.", "Check the image name, network and registry login."),
    ("DOCKER-03", "docker", "컨테이너를 실행하지 못했습니다.", "Docker 로그를 확인하세요.", "The container could not be run.", "Read the Docker log."),
    ("CI-01", "ci", "원격 실행을 찾지 못했습니다(결과를 모름).", "CI 화면에서 실행이 생겼는지 직접 확인하세요. 중복 실행을 막으려고 다시 보내지 않았습니다.", "The remote run could not be found (outcome unknown).", "Check the CI site. It was not re-sent, to avoid duplicate runs."),
    ("CI-02", "ci", "원격 실행이 실패했습니다.", "원격 로그와 보고서를 확인하세요.", "The remote run failed.", "Read the remote log and report."),
    ("CI-03", "ci", "원격 결과 계약(보고서)이 없습니다(판정 불가).", "원격 작업이 gitch flow run --ci 를 쓰거나 JUnit 보고서를 남기게 하세요.", "The remote result contract (report) is missing (cannot judge).", "Make the remote job run gitch flow run --ci or publish a JUnit report."),
    ("CI-04", "ci", "누군가 원격 실행을 취소했습니다.", "다시 실행할지 확인하세요. 자동으로 다시 보내지 않습니다.", "Someone else cancelled the remote run.", "Decide whether to run it again. It is not re-sent automatically."),
    ("CI-05", "ci", "원격 실행을 기다리다 시간이 지났습니다.", "CI 대기열 · 러너 상태를 확인하세요.", "Timed out waiting for the remote run.", "Check the CI queue and runners."),
    ("CI-06", "ci", "원격 CI 가 입력을 거부했습니다.", "워크플로 · 파이프라인이 받는 입력 이름을 확인하세요.", "The remote CI rejected the inputs.", "Check the input names the workflow or pipeline accepts."),
    ("CI-07", "ci", "허용 목록에 없는 원격 작업입니다.", "연결 설정의 허용 목록에 작업 이름을 더하세요.", "The remote job is not on the allow list.", "Add the job to the connection's allow list."),
    ("CONN-01", "connection", "그런 연결이 없습니다.", "gitch connect list 로 확인하거나 앱 설정 > 연결에서 추가하세요.", "No connection has that name.", "Check gitch connect list, or add it in the app settings."),
    ("CONN-02", "connection", "인증에 실패했습니다.", "토큰 권한(GitLab api, GitHub Actions 쓰기, Jenkins API 토큰)을 확인하세요.", "Authentication failed.", "Check the token scopes (GitLab api, GitHub Actions write, Jenkins API token)."),
    ("CONN-03", "connection", "비밀값을 찾지 못했습니다.", "연결의 비밀값을 다시 저장하거나 CI 에서는 환경변수를 넘기세요.", "The secret could not be found.", "Store the connection secret again, or pass the environment variable in CI."),
    ("CONN-04", "connection", "대상을 찾지 못했습니다(404).", "주소 · 프로젝트 · 작업 이름을 확인하세요.", "The target was not found (404).", "Check the address, project and job names."),
    ("CONN-05", "connection", "네트워크 오류입니다.", "주소와 네트워크를 확인하세요.", "Network error.", "Check the address and the network."),
    ("CONN-06", "connection", "요청 한도에 걸렸습니다.", "잠시 뒤 다시 하세요.", "Rate limited.", "Try again later."),
    ("CACHE-01", "cache", "캐시를 읽지 못해 다시 실행했습니다.", "gitch flow gc 로 캐시를 정리할 수 있습니다.", "The cache could not be read, so the node ran again.", "You can clean the cache with gitch flow gc."),
    ("LOCK-01", "lock", "같은 흐름이 이미 실행 중입니다.", "끝날 때까지 기다리거나 gitch flow cancel 로 취소하세요.", "The same flow is already running.", "Wait for it, or cancel it with gitch flow cancel."),
    ("ROLLBACK-01", "rollback", "되돌리기에 실패했습니다. 환경을 잠갔습니다(hold).", "환경을 직접 확인하고 복구한 뒤 gitch flow hold release 로 푸세요.", "Rollback failed. The environment is on hold.", "Check and repair the environment, then run gitch flow hold release."),
    ("SETUP-01", "setup", "런타임 버전이 저장소가 바라는 것과 다릅니다.", "버전 관리자(nvm · pyenv · asdf …)로 맞추거나 executor 로 같은 이미지에서 돌리세요.", "The runtime version differs from what the repository asks for.", "Switch versions with your version manager, or run in the same image with executor."),
    ("SETUP-02", "setup", "의존성 설치에 실패했습니다.", "잠금 파일과 설치 로그를 확인하세요.", "Installing dependencies failed.", "Check the lock file and the install log."),
    ("GITCH-01", "gitch", "gitch preflight 가 STOP 을 냈습니다.", "gitch preflight 의 항목을 해결한 뒤 다시 실행하세요.", "gitch preflight reported STOP.", "Fix the items gitch preflight lists, then run again."),
    ("GITCH-02", "gitch", "의존 규칙을 어겼습니다(gitch graph check).", "gitch graph check 의 위반을 고치세요.", "Dependency rules were broken (gitch graph check).", "Fix the violations gitch graph check reports."),
    ("DEPLOY-01", "deploy", "지금 떠 있는 버전이 기대한 버전이 아닙니다(비교 후 교체 거부).", "누가 먼저 바꿨는지 확인하고 expectCurrent 를 고친 뒤 다시 실행하세요.", "The running version is not the expected one (compare-and-swap refused).", "Find out who changed it first, fix expectCurrent and run again."),
    ("GATE-01", "gate", "금지 시간대에 걸립니다.", "다른 시간에 실행하거나 gate.window 설정을 확인하세요.", "This falls inside a blocked time window.", "Run it at another time or check the gate.window settings."),
    ("GATE-02", "gate", "사람이 거부했습니다.", "필요하면 다시 실행하세요.", "A person declined this step.", "Run it again if needed."),
    ("ENGINE-01", "engine", "엔진 내부 오류입니다.", "gitch flow report 결과와 함께 문제를 알려 주세요.", "Internal engine error.", "Please report it with the output of gitch flow report."),
    ("ENGINE-02", "engine", "실행 기록이 손상됐거나 서명이 맞지 않습니다.", "기록을 믿지 않습니다. 흐름을 다시 실행하세요.", "The run record is damaged or its signature does not match.", "The record is not trusted. Run the flow again."),
    ("ENGINE-03", "engine", "흐름 엔진을 찾지 못했습니다.", "앱을 업데이트하거나 gitch self-update 를 실행하세요.", "The flow engine was not found.", "Update the app or run gitch self-update."),
];

fn row(code: &str) -> Option<&'static Row> {
    CODES.iter().find(|r| r.0 == code)
}

/// 지금 언어의 설명. 모르는 코드는 코드 그대로.
pub fn describe(code: &str) -> String {
    match row(code) {
        Some(r) => crate::util::tr(r.2, r.4),
        None => code.to_string(),
    }
}

pub fn action(code: &str) -> String {
    match row(code) {
        Some(r) => crate::util::tr(r.3, r.5),
        None => String::new(),
    }
}

pub fn known(code: &str) -> bool {
    row(code).is_some()
}

/// 사람용 한 줄: `[CODE] 설명 (조치: …)`.
pub fn line(code: &str) -> String {
    let a = action(code);
    if a.is_empty() {
        format!("[{code}] {}", describe(code))
    } else {
        format!(
            "[{code}] {} ({}: {a})",
            describe(code),
            crate::util::tr("조치", "action")
        )
    }
}

/// JSON 으로 넣을 실패 정보. `detail` 은 상황별 설명(마스킹을 거친 글).
pub fn failure(code: &str, detail: &str) -> Value {
    json!({
        "code": code,
        "category": row(code).map(|r| r.1).unwrap_or("engine"),
        "description": describe(code),
        "action": action(code),
        "detail": detail,
    })
}

/// `gitch flow explain` 용 전체 표.
pub fn catalog() -> Value {
    Value::Array(
        CODES
            .iter()
            .map(|r| {
                json!({
                    "code": r.0, "category": r.1,
                    "description": {"ko": r.2, "en": r.4},
                    "action": {"ko": r.3, "en": r.5},
                })
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn codes_are_unique_and_complete() {
        let mut seen = HashSet::new();
        for r in CODES {
            assert!(seen.insert(r.0), "duplicate code {}", r.0);
            assert!(
                !r.2.is_empty() && !r.3.is_empty() && !r.4.is_empty() && !r.5.is_empty(),
                "{} needs text",
                r.0
            );
            assert!(r.0.contains('-'));
        }
    }

    #[test]
    fn unknown_code_falls_back() {
        assert_eq!(describe("NOPE-1"), "NOPE-1");
        assert!(!known("NOPE-1"));
        assert!(known("TEST-03"));
    }
}
