import SwiftUI

/// 파이프라인·작업 상태(GitLab status 와 GitHub status+conclusion 을 하나로)
enum CIStatus: String, Hashable {
    case created, waiting, pending, running, success, failed, canceled, skipped, manual, scheduled, neutral, unknown

    init(gitlab s: String) {
        switch s {
        case "created": self = .created
        case "waiting_for_resource", "preparing", "waiting_for_callback": self = .waiting
        case "pending": self = .pending
        case "running": self = .running
        case "success": self = .success
        case "failed": self = .failed
        case "canceled", "canceling": self = .canceled
        case "skipped": self = .skipped
        case "manual": self = .manual
        case "scheduled": self = .scheduled
        default: self = .unknown
        }
    }

    init(github status: String?, conclusion: String?) {
        switch status {
        case "queued", "requested", "pending": self = .pending
        case "waiting": self = .waiting           // 환경 보호 규칙의 승인 대기
        case "in_progress": self = .running
        case "completed":
            switch conclusion {
            case "success": self = .success
            case "failure", "timed_out", "startup_failure": self = .failed
            case "cancelled": self = .canceled
            case "skipped": self = .skipped
            case "action_required": self = .manual
            case "neutral", "stale": self = .neutral
            default: self = .unknown
            }
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .created: return String(localized: "Created")
        case .waiting: return String(localized: "Waiting")
        case .pending: return String(localized: "Queued")
        case .running: return String(localized: "Running")
        case .success: return String(localized: "Succeeded")
        case .failed: return String(localized: "Failed")
        case .canceled: return String(localized: "Canceled")
        case .skipped: return String(localized: "Skipped")
        case .manual: return String(localized: "Waiting to be run manually")
        case .scheduled: return String(localized: "Scheduled")
        case .neutral: return String(localized: "Done")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var symbol: String {
        switch self {
        case .created, .pending: return "circle.dashed"
        case .waiting: return "pause.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "slash.circle.fill"
        case .skipped: return "forward.circle"
        case .manual: return "hand.tap.fill"
        case .scheduled: return "clock.fill"
        case .neutral, .unknown: return "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .failed: return .red
        case .running: return .blue
        case .waiting, .manual: return .orange
        case .scheduled: return .purple
        default: return .secondary
        }
    }

    /// 아직 끝나지 않아 자주 새로 고쳐야 하는 상태
    var isActive: Bool { [.created, .waiting, .pending, .running].contains(self) }
    var isFinished: Bool { [.success, .failed, .canceled, .skipped, .neutral].contains(self) }
}

/// GitLab 파이프라인 / GitHub Actions 실행
struct CIPipeline: Identifiable, Hashable {
    let id: Int
    /// GitLab iid / GitHub run_number
    let number: Int
    /// GitHub 워크플로 이름, GitLab 파이프라인 이름(있으면)
    let name: String
    /// GitHub: 커밋 메시지·PR 제목. GitLab 은 없어서 화면에서 로컬 커밋 제목으로 채운다
    let title: String
    let ref: String
    let sha: String
    let status: CIStatus
    let url: String
    let created: Date?
    /// push, web, schedule, workflow_dispatch …
    let event: String
    let actor: String?
    /// When this attempt started and when the run last changed; together they say how long a finished run took
    var started: Date? = nil
    var updated: Date? = nil
    /// GitHub: the pull request the run belongs to, when the run list names one
    var request: Int? = nil

    var eventTitle: String {
        switch event {
        case "push": return "push"
        case "web", "workflow_dispatch": return String(localized: "Manual")
        case "schedule": return String(localized: "Scheduled")
        case "merge_request_event", "pull_request", "pull_request_target": return "MR·PR"
        case "api": return "API"
        case "trigger", "repository_dispatch": return String(localized: "Trigger")
        case "parent_pipeline", "pipeline", "workflow_run": return String(localized: "Connect")
        default: return event
        }
    }
}

struct CIJob: Identifiable, Hashable {
    let id: Int
    let name: String
    /// GitLab 단계(GitHub 은 빈 문자열)
    let stage: String
    let status: CIStatus
    let url: String
    let allowFailure: Bool
    let duration: Double?

    /// GitLab 수동 작업(when: manual)·지연 작업(when: delayed)은 바로 실행할 수 있다
    var canPlay: Bool { status == .manual || status == .scheduled }
}

/// GitHub 환경 보호 규칙 때문에 승인을 기다리는 배포
struct CIDeployment: Identifiable, Hashable {
    let environmentID: Int
    let environment: String
    let canApprove: Bool
    var id: Int { environmentID }
}

/// "Run workflow" 버튼이 있는(workflow_dispatch) GitHub 워크플로
struct CIWorkflow: Identifiable, Hashable {
    let id: Int
    let name: String
    let path: String
    var inputs: [CIInput]
}

/// workflow_dispatch 입력값 / GitLab 파이프라인 변수(.gitlab-ci.yml 에 설명이 있는 변수)
struct CIInput: Identifiable, Hashable {
    let name: String
    let description: String
    let required: Bool
    let defaultValue: String
    /// string, boolean, choice, number, environment
    let type: String
    let options: [String]
    var id: String { name }
}

/// 브랜치별로 묶은 실행 기록(가장 최근에 돈 브랜치가 위)
struct CIBranchGroup: Identifiable {
    let ref: String
    var pipelines: [CIPipeline]
    var id: String { ref }

    /// 목록이 최신순이면 묶음도 가장 최근 실행 순서가 된다
    static func group(_ pipelines: [CIPipeline]) -> [CIBranchGroup] {
        var order: [String] = []
        var groups: [String: [CIPipeline]] = [:]
        for p in pipelines {
            if groups[p.ref] == nil { order.append(p.ref) }
            groups[p.ref, default: []].append(p)
        }
        return order.map { CIBranchGroup(ref: $0, pipelines: groups[$0] ?? []) }
    }
}
