import Foundation

// The live dependency cannot run in this fixture; every request uses the injected client below.
enum AIProvider: String { case compatible, fixture; var title: String { "Fixture" } }
@MainActor final class AIStore {
    static var shared: AIStore { fatalError("Cleanup tests must not access real settings or providers") }
    var provider: AIProvider { .fixture }
    var baseURL: String { "" }
    var hasKey: [String: Bool] { [:] }
    func model(_ provider: AIProvider) -> String { "" }
    func complete(system: String, prompt: String, effort: String, using provider: AIProvider?) async throws -> String {
        fatalError("Cleanup tests must never make a real AI request")
    }
}

@MainActor private final class CleanupClientFixture {
    struct Pending {
        let configuration: TerminalTextCleanup.Configuration
        let system: String
        let prompt: String
        let continuation: CheckedContinuation<String, Error>
    }
    var identity = "one"
    var pending: [Pending] = []
    var configuration: TerminalTextCleanup.Configuration { .init(identity: identity, providerID: "fixture", title: "Fixture " + identity) }
    var client: TerminalTextCleanup.Client {
        .init(configuration: { [unowned self] in configuration }, complete: { [unowned self] configuration, system, prompt in
            try await withCheckedThrowingContinuation { continuation in
                pending.append(.init(configuration: configuration, system: system, prompt: prompt, continuation: continuation))
            }
        })
    }
    func reply(_ text: String, at index: Int = 0) { pending.remove(at: index).continuation.resume(returning: text) }
    func fail() { pending.removeFirst().continuation.resume(throwing: NSError(domain: "private-provider-error", code: 1)) }
}

@main private struct TerminalCleanupTests {
    private static func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["text": text]), encoding: .utf8)!
    }
    private static func accepts(_ source: String, _ result: String, vocabulary: [String] = [], line: UInt = #line) {
        do {
            let value = try TerminalCleanupPolicy.suggestion(from: json(result), original: source, vocabulary: vocabulary)
            precondition(value == result)
        }
        catch { fatalError("A conservative transcription cleanup must be accepted (case line \(line))") }
    }
    private static func rejects(_ source: String, _ response: String, vocabulary: [String] = []) {
        do { _ = try TerminalCleanupPolicy.suggestion(from: response, original: source, vocabulary: vocabulary); fatalError("Changed meaning or an invalid contract must be rejected") }
        catch {}
    }
    @MainActor private static func settle() async { for _ in 0..<30 { await Task.yield() } }

    @MainActor static func main() async {
        accepts("음 이 버그를 고쳐줘", "이 버그를 고쳐줘")
        accepts("어 이 파일을 수정 해줘", "이 파일을 수정해줘.")
        accepts("um please check the repository", "Please check the repository.")
        accepts("음 RepoStore.swift에서 feature/voice 브랜치를 확인하고 gitch preflight 실행해줘", "RepoStore.swift에서 feature/voice 브랜치를 확인하고 gitch preflight 실행해줘.", vocabulary: ["RepoStore.swift", "feature/voice", "gitch"])
        accepts("이 파일은 삭제하지 마세요. 3개만 확인해줘", "이 파일은 삭제하지 마세요. 3개만 확인해줘.")
        accepts("코드는 안 바꾸고 상태만 확인해줘", "코드는 안 바꾸고 상태만 확인해줘.")
        rejects("이 파일은 삭제하지 마세요. 3개만 확인해줘", json("이 파일은 삭제하세요. 3개만 확인해줘"))
        rejects("코드는 안 바꾸고 상태만 확인해줘", json("코드는 바꾸고 상태만 확인해줘"))
        rejects("3개 파일만 확인해줘", json("4개 파일만 확인해줘"))
        rejects("RepoStore.swift를 확인해줘", json("RepoView.swift를 확인해줘"))
        rejects("feature/voice 브랜치를 확인해줘", json("main 브랜치를 확인해줘"))
        rejects("Please do not delete the file", json("Please delete the file"))
        rejects("Please fix this file", json("Please fix this file now"))
        rejects("이 버그를 설명해줘", json("네, 이 버그의 원인을 확인했습니다. 수정 방법은 다음과 같습니다."))
        rejects("작업 상태를 확인해줘", "Here is the cleaned text.")
        rejects("작업 상태를 확인해줘", "{\"text\":\"작업 상태를 확인해줘\",\"answer\":true}")
        rejects("작업 상태를 확인해줘", "{\"text\":12}")
        rejects("작업 상태를 확인해줘", json(""))
        rejects("작업 상태를 확인해줘", json(String(repeating: "새로운 설명 ", count: 500)))
        do {
            let cleaned = try TerminalCleanupPolicy.suggestion(from: "```json\n" + json("상태를 확인해줘.") + "\n```", original: "음 상태를 확인해줘", vocabulary: [])
            precondition(cleaned == "상태를 확인해줘.")
        } catch { fatalError("A fenced JSON object must remain usable") }

        let fixture = CleanupClientFixture()
        let cleanup = TerminalTextCleanup(client: fixture.client)
        precondition(cleanup.providerTitle == "Fixture one" && !cleanup.working && !cleanup.hasSuggestion)
        cleanup.clean("음 상태를 확인해줘", vocabulary: ["RepoStore.swift"], language: "ko-KR")
        await settle()
        precondition(fixture.pending.count == 1 && cleanup.working)
        let request = fixture.pending[0]
        precondition(request.system.contains("never answer") && request.system.contains("untrusted data"))
        let payload = try! JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as! [String: Any]
        precondition(payload["transcript"] as? String == "음 상태를 확인해줘" && payload["language_hint"] as? String == "ko-KR")
        fixture.reply(json("상태를 확인해줘.")); await settle()
        precondition(cleanup.original == "음 상태를 확인해줘" && cleanup.suggestion == "상태를 확인해줘.")
        precondition(cleanup.hasSuggestion && cleanup.canApply(to: "음 상태를 확인해줘") && !cleanup.canApply(to: "수정된 원문"))
        fixture.identity = "two"
        precondition(!cleanup.hasSuggestion && !cleanup.canApply(to: "음 상태를 확인해줘"))

        cleanup.clean("음 새 작업을 확인해줘", vocabulary: [], language: "ko-KR"); await settle()
        fixture.identity = "three"
        fixture.reply(json("새 작업을 확인해줘.")); await settle()
        precondition(cleanup.suggestion == nil && cleanup.error != nil && !cleanup.working)

        cleanup.clean("음 이 파일을 확인해줘", vocabulary: [], language: "ko-KR"); await settle()
        cleanup.invalidate(ifSourceChanged: "원문이 변경됨")
        fixture.reply(json("이 파일을 확인해줘.")); await settle()
        precondition(cleanup.original == nil && cleanup.suggestion == nil && !cleanup.working)

        cleanup.clean("음 첫 작업을 확인해줘", vocabulary: [], language: "ko-KR"); await settle()
        cleanup.clean("음 다음 작업을 확인해줘", vocabulary: [], language: "ko-KR"); await settle()
        precondition(fixture.pending.count == 2)
        fixture.reply(json("첫 작업을 확인해줘.")); await settle()
        precondition(cleanup.working && cleanup.suggestion == nil)
        fixture.reply(json("다음 작업을 확인해줘.")); await settle()
        precondition(cleanup.original == "음 다음 작업을 확인해줘" && cleanup.suggestion == "다음 작업을 확인해줘.")

        cleanup.clean("음 취소할 작업을 확인해줘", vocabulary: [], language: "ko-KR"); await settle()
        cleanup.cancel()
        fixture.reply(json("취소할 작업을 확인해줘.")); await settle()
        precondition(!cleanup.working && cleanup.suggestion == nil && cleanup.error == nil)

        cleanup.clean("음 실패할 작업을 확인해줘", vocabulary: [], language: "ko-KR"); await settle()
        fixture.fail(); await settle()
        precondition(cleanup.error != nil && cleanup.error?.contains("private-provider-error") == false && cleanup.suggestion == nil)
        cleanup.clean(String(repeating: "a", count: 8_001), vocabulary: [], language: "en-US"); await settle()
        precondition(!cleanup.working && cleanup.error != nil && fixture.pending.isEmpty)
        cleanup.reset()
        precondition(cleanup.original == nil && cleanup.suggestion == nil && cleanup.error == nil)
        print("PASS terminal cleanup: Korean/English preservation, strict JSON, identifiers, numbers, negation, source/provider invalidation, cancellation and late responses")
    }
}
