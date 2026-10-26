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
    private var values: [String: String] = [:]
    private var states: [String: State] = [:]
    @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored var onChange: (() -> Void)?

    init(reader: @escaping Reader) { self.reader = reader }

    func state(_ name: String) -> State { states[name] ?? .loading }

    func value(_ name: String) -> String? {
        if let value = values[name] { return value }
        prepare(name)
        return nil
    }

    func prepare(_ name: String) {
        guard states[name] == nil else { return }
        let attempt = begin(name)
        let reader = reader
        reads[name] = Task { [weak self] in
            let result = await reader(name)
            guard !Task.isCancelled else { return }
            self?.complete(name, attempt: attempt, result: result)
        }
    }

    /// 명시적 승인·새 토큰 저장·해제는 이전 자동 읽기의 결과를 무효화한다.
    @discardableResult func begin(_ name: String) -> UUID {
        reads.removeValue(forKey: name)?.cancel()
        let attempt = UUID(); generations[name] = attempt
        states[name] = .loading
        return attempt
    }

    func isCurrent(_ name: String, attempt: UUID) -> Bool { generations[name] == attempt }

    func complete(_ name: String, attempt: UUID, result: CredentialReadResult) {
        guard isCurrent(name, attempt: attempt) else { return }
        reads.removeValue(forKey: name)
        values[name] = result.value
        states[name] = result.value == nil ? (result.requiresAuthorization ? .authorizationRequired : .unavailable) : .ready
        onChange?()
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
