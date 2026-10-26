import Foundation

/// 코드 발급 전과 브라우저 승인 대기를 구분하고 멈춘 세션의 대기 시간을 제한한다.
struct GitHubLoginProgress {
    enum Phase: Equatable { case queued, preparing, approval }
    enum Failure: Equatable {
        case preparation, expired
        var message: String {
            switch self {
            case .preparation: return String(localized: "GitHub hasn't returned a sign-in code. Cancel and try again. Check your connection and GitHub CLI if this keeps happening.")
            case .expired: return String(localized: "Sign-in expired. Cancel and start again to get a new code.")
            }
        }
    }
    let startedAt: Date
    private var preparingAt: Date?
    init(startedAt: Date = Date()) { self.startedAt = startedAt }
    static func phase(_ phase: String?, code: String?) -> Phase {
        if code?.isEmpty == false { return .approval }
        return phase == "queued" ? .queued : .preparing
    }
    mutating func failure(phase: Phase, now: Date = Date()) -> Failure? {
        if now.timeIntervalSince(startedAt) >= 900 { return .expired }
        if phase != .preparing { preparingAt = nil; return nil }
        if preparingAt == nil { preparingAt = now }
        return now.timeIntervalSince(preparingAt!) >= 90 ? .preparation : nil
    }
}
