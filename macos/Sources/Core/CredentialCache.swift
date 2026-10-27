import Foundation
import Observation

/// 원본 키체인 오류나 비밀값을 화면 상태와 분리한다.
struct CredentialReadResult: Sendable {
    let value: String?
    let status: Int32
    var requiresAuthorization: Bool { [-25308, -25315, -25293, -128].contains(status) }
}

/// 메인 액터는 캐시만 읽고 자격 증명 조회는 비동기 reader가 담당한다.
@MainActor @Observable
final class CredentialCache {
    enum State: Equatable { case loading, ready, authorizationRequired, unavailable }
    typealias Reader = @Sendable (String) async -> CredentialReadResult
    /// A failed read is tried again this much later, so a denied system prompt does not come straight back.
    @ObservationIgnored var retryInterval: TimeInterval = 30
    private var values: [String: String] = [:]
    private var states: [String: State] = [:]
    @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastStatus: [String: Int32] = [:]
    @ObservationIgnored private var lastReads: [String: Date] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var failures: [String: Date] = [:]
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored var onChange: (() -> Void)?

    init(reader: @escaping Reader) { self.reader = reader }

    func state(_ name: String) -> State { states[name] ?? .loading }

    func value(_ name: String) -> String? {
        if let value = values[name] { return value }
        prepare(name)
        return nil
    }

    /// Starts a read unless the value is known, a read is in flight, or the last failure is still fresh.
    /// Only temporary access failures retry; missing or rejected credentials require explicit recovery.
    func prepare(_ name: String, now: Date = Date()) {
        guard values[name] == nil, states[name] != .loading, reads[name] == nil, retryable(name) else { return }
        if let failed = failures[name], now.timeIntervalSince(failed) < retryInterval { return }
        let attempt = begin(name)
        let reader = reader
        reads[name] = Task { [weak self] in
            let result = await reader(name)
            guard !Task.isCancelled else { return }
            self?.complete(name, attempt: attempt, result: result)
        }
    }

    /// Waits for the read in flight, so a loader shows progress instead of "no account" while the system prompt is up.
    func awaitValue(_ name: String) async -> String? {
        if let value = values[name] { return value }
        prepare(name)
        while let read = reads[name] { await read.value }
        return values[name]
    }

    /// 명시적 승인·새 토큰 저장·해제는 이전 자동 읽기의 결과를 무효화한다.
    @discardableResult func begin(_ name: String) -> UUID {
        reads.removeValue(forKey: name)?.cancel()
        let attempt = UUID(); generations[name] = attempt; lastReads[name] = Date()
        states[name] = .loading
        return attempt
    }

    func isCurrent(_ name: String, attempt: UUID) -> Bool { generations[name] == attempt }

    func complete(_ name: String, attempt: UUID, result: CredentialReadResult) {
        guard isCurrent(name, attempt: attempt) else { return }
        reads.removeValue(forKey: name)
        lastStatus[name] = result.status
        // A locked Keychain or a canceled read does not revoke an already restored session.
        let transient = result.requiresAuthorization || result.status == -25291
        if result.value != nil || !transient || values[name] == nil { values[name] = result.value }
        states[name] = values[name] == nil ? (result.requiresAuthorization ? .authorizationRequired : .unavailable) : .ready
        failures[name] = values[name] == nil ? Date() : nil
        onChange?()
    }

    private func retryable(_ name: String) -> Bool {
        states[name] == nil || states[name] == .authorizationRequired || lastStatus[name] == -25291
    }

    /// Lifecycle retries stay silent and coalesced; ready credentials never reread on navigation.
    func retry(_ name: String, minimumInterval: TimeInterval = 30, now: Date = Date()) {
        guard values[name] == nil, reads[name] == nil, states[name] != .loading, retryable(name),
              (failures[name] ?? lastReads[name]).map({ now.timeIntervalSince($0) >= minimumInterval }) ?? true else { return }
        prepare(name, now: now)
    }

    func store(_ value: String?, for name: String) {
        let attempt = begin(name)
        complete(name, attempt: attempt, result: CredentialReadResult(value: value, status: value == nil ? -25300 : 0))
    }
}

/// file-based 키체인도 자동 조회에서 UI를 띄우지 않게 하며 호출 전 상태를 반드시 복원한다.
enum KeychainInteractionPolicy {
    static func perform(allowInteraction: Bool, get: () -> (Int32, Bool), set: (Bool) -> Int32, operation: () -> CredentialReadResult) -> CredentialReadResult {
        let (status, previous) = get()
        guard status == 0 else { return CredentialReadResult(value: nil, status: status) }
        if previous != allowInteraction {
            let changed = set(allowInteraction)
            guard changed == 0 else { return CredentialReadResult(value: nil, status: changed) }
        }
        defer { if previous != allowInteraction { _ = set(previous) } }
        return operation()
    }
}
