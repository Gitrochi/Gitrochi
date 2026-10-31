import Foundation

/// The ledger behind the screens: a contract method and its JSON arguments in, the contract's JSON out — the answer
/// itself, `{"result": …}` or `{"error": {code, message}}`. A call may block, so the app makes it off the main thread.
/// Wave 2 connects the core's C ABI (gitrochi_ledger_call / gitrochi_ledger_free) behind this; until then the screens
/// run on DemoLedgerBackend. (Windows: entities/ledger/api/backend.ts)
protocol LedgerBackend: AnyObject, Sendable {
    func call(method: String, args: Data) -> Data
}

/// An answer the app cannot use: the core's error envelope, or JSON in an unexpected shape
struct LedgerFailure: Error, LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Typed calls over a backend. Encoding, the call and decoding run off the main thread.
/// (Windows: entities/ledger/api/backend.ts)
struct LedgerClient: Sendable {
    let backend: LedgerBackend

    func info() async throws -> LedgerInfo { try await call("info") }
    func rev() async throws -> Int { try await call("rev", as: LedgerRev.self).rev }

    func state(project: String?, range: LedgerRange) async throws -> LedgerState {
        var args: [String: LedgerJSON] = ["range": .string(range.rawValue)]
        if let project { args["project"] = .string(project) }
        return try await call("state", args)
    }

    func session(_ id: String) async throws -> LedgerSessionDetail { try await call("session", ["id": .string(id)]) }

    func graph(project: String, range: LedgerRange) async throws -> LedgerGraph {
        try await call("graph", ["project": .string(project), "range": .string(range.rawValue)])
    }

    func search(_ query: String, project: String?, limit: Int = 30) async throws -> [LedgerSearchHit] {
        var args: [String: LedgerJSON] = ["query": .string(query), "limit": .number(Double(limit))]
        if let project { args["project"] = .string(project) }
        return try await call("search", args, as: LedgerSearchResult.self).hits
    }

    func importReports(_ text: String, project: String?) async throws -> [LedgerImportResult.Block] {
        var args: [String: LedgerJSON] = ["text": .string(text)]
        if let project { args["project"] = .string(project) }
        return try await call("import", args, as: LedgerImportResult.self).results
    }

    func human(_ action: LedgerHumanAction, sessionId: String) async throws -> LedgerWriteResult {
        var args = action.arguments
        args["sessionId"] = .string(sessionId)
        return try await call("human", args)
    }

    /// `ok` is false when the prompt no longer waits (answered or released elsewhere)
    func answerPrompt(_ id: Int, _ reply: LedgerPromptReply) async throws -> LedgerWriteResult {
        try await call("prompt_answer", ["id": .number(Double(id)), "answer": .object(reply.answer)])
    }

    /// Marks what auto-continue sent for a prompt as seen by a person
    func reviewPrompt(_ id: Int) async throws -> LedgerWriteResult { try await call("prompt_review", ["id": .number(Double(id))]) }

    func backup() async throws -> String { try await call("backup", as: LedgerBackupResult.self).path }

    /// Reads a claude-ledger database without writing to it; `dryRun` only counts what would be copied
    func importLegacy(path: String, dryRun: Bool) async throws -> LedgerLegacyImportResult {
        try await call("import_legacy", ["path": .string(path), "dryRun": .bool(dryRun)])
    }

    func settings() async throws -> LedgerGlobalSettings { try await call("settings") }

    /// Stores settings (`.null` puts one back to its default) and answers with every setting as stored
    func setSettings(_ values: [String: LedgerJSON]) async throws -> LedgerGlobalSettings {
        try await call("settings_set", ["values": .object(values)], as: LedgerSettingsWrite.self).settings
    }

    func projects() async throws -> [LedgerProjectSettings] { try await call("projects", as: LedgerProjectList.self).projects }

    /// Changes a project's name or baseline source (`.null` clears a value) and answers with the project as stored
    func setProject(_ key: String, _ values: [String: LedgerJSON]) async throws -> LedgerProjectSettings {
        var args = values
        args["project"] = .string(key)
        return try await call("project_set", args, as: LedgerProjectWrite.self).project
    }

    /// Looks for baselines now, for one project or all of them
    func scan(project: String?) async throws -> [LedgerScanResult.Project] {
        try await call("scan", project.map { ["project": .string($0)] } ?? [:], as: LedgerScanResult.self).results
    }

    private func call<T: Decodable & Sendable>(_ method: String, _ args: [String: LedgerJSON] = [:], as type: T.Type = T.self) async throws -> T {
        let backend = backend
        return try await Task.detached(priority: .userInitiated) {
            let input = try JSONEncoder().encode(LedgerJSON.object(args))
            return try LedgerClient.decode(T.self, from: backend.call(method: method, args: input))
        }.value
    }

    /// Reads an answer: an error envelope throws, `{"result": …}` is unwrapped, anything else is the answer itself
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LedgerErrorEnvelope.self, from: data) {
            throw LedgerFailure(code: envelope.error.code, message: envelope.error.message)
        }
        if let wrapped = try? decoder.decode(Wrapped<T>.self, from: data) { return wrapped.result }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LedgerFailure(code: "BAD_ANSWER", message: String(localized: "The ledger sent an answer this version of Gitrochi cannot read.") + " (\(error))")
        }
    }

    private struct Wrapped<Value: Decodable>: Decodable { let result: Value }
}
