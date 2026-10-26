import Foundation

/// 커밋에 들어갈 스테이지 스냅샷의 의존 영향과 테스트 후보(gitch graph review).
struct CommitReviewReport: Decodable, Equatable {
    struct ChangedFile: Decodable, Equatable, Identifiable {
        let path: String
        let status: String
        let oldPath: String?
        let analyzed: Bool
        var id: String { path }
    }

    struct AffectedFile: Decodable, Equatable, Identifiable {
        let path: String
        let depth: Int
        let via: [String]
        let heuristic: Bool
        var id: String { path }
    }

    struct TestCandidate: Decodable, Equatable, Identifiable {
        enum Kind: String, Decodable { case dependency, name }
        let path: String
        let kind: Kind
        let depth: Int
        let heuristic: Bool
        var id: String { path }
    }

    struct Coverage: Decodable, Equatable {
        let changed: Int
        let analyzed: Int
        let unsupported: Int
    }

    let schemaVersion: Int
    let tool: String
    let scope: String
    let stamp: String
    let snapshot: String
    let headSha: String
    let branch: String
    let stale: Bool
    let changed: [ChangedFile]
    let direct: [AffectedFile]
    let indirect: [AffectedFile]
    let tests: [TestCandidate]
    let coverage: Coverage
    let limitations: [String]

    static func decode(_ data: Data) throws -> Self {
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.schemaVersion == 1, report.tool == "gitch graph review", report.scope == "staged",
              !report.stamp.isEmpty, !report.snapshot.isEmpty else { throw CommitReviewContractError.unsupported }
        return report
    }

    /// 분석을 마친 직후에도 index 가 바뀔 수 있어서 CLI 의 종료 시점 검사만 믿지 않는다.
    func isCurrent(comparedTo current: CommitReviewStamp) -> Bool {
        !stale && stamp == current.stamp && headSha == current.headSha
    }
}

/// 전체 의존 분석을 다시 하지 않고 읽는 현재 스테이지의 식별값.
struct CommitReviewStamp: Decodable, Equatable {
    let schemaVersion: Int
    let scope: String
    let stamp: String
    let headSha: String

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1, result.scope == "staged", !result.stamp.isEmpty else {
            throw CommitReviewContractError.unsupported
        }
        return result
    }
}

private enum CommitReviewContractError: Error { case unsupported }
