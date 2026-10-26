#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
# 제품의 큐·정책 코드를 그대로 컴파일하고 Security 진입점만 가짜 함수로 바꾼다.
python3 - "$ROOT/Sources/Services/Accounts.swift" "$TASK_TMP/Keychain.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text().split('/// GitHub·사내 GitLab 계정')[0]
for original,replacement in {'SecKeychainGetUserInteractionAllowed':'FixtureSecurity.getInteraction','SecKeychainSetUserInteractionAllowed':'FixtureSecurity.setInteraction','SecItemCopyMatching':'FixtureSecurity.copy','SecItemUpdate':'FixtureSecurity.update','SecItemAdd':'FixtureSecurity.add','SecItemDelete':'FixtureSecurity.delete'}.items():
 source=source.replace(original,replacement)
pathlib.Path(sys.argv[2]).write_text(source)
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
import Security

enum LegacyData { static let keychainService = "fixture.legacy" }

final class FixtureSecurity: @unchecked Sendable {
    static let shared = FixtureSecurity()
    private let lock = NSLock()
    private var interaction = true
    private var operations: [String] = []
    private var holdRead = false
    private var entered = false
    private var readResult: OSStatus = errSecSuccess
    let release = DispatchSemaphore(value: 0)
    func configure(hold: Bool, status: OSStatus = errSecSuccess) { lock.lock(); holdRead = hold; entered = false; readResult = status; operations = []; lock.unlock() }
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return operations }
    static func getInteraction(_ output: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
        precondition(!Thread.isMainThread)
        let s = shared; s.lock.lock(); defer { s.lock.unlock() }; output.pointee = DarwinBoolean(s.interaction); return errSecSuccess
    }
    static func setInteraction(_ value: Bool) -> OSStatus {
        precondition(!Thread.isMainThread)
        let s = shared; s.lock.lock(); defer { s.lock.unlock() }; s.interaction = value; s.operations.append("UI:\(value)"); return errSecSuccess
    }
    static func copy(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        precondition(!Thread.isMainThread)
        let s = shared; s.lock.lock(); let hold = s.holdRead, status = s.readResult; s.entered = true; s.operations.append("read:\(s.interaction)"); s.lock.unlock()
        if hold { s.release.wait() }
        if status == errSecSuccess { output?.pointee = Data("fixture-only".utf8) as CFData }
        return status
    }
    static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus { record("write"); return errSecSuccess }
    static func add(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { record("add"); return errSecSuccess }
    static func delete(_ query: CFDictionary) -> OSStatus { record("delete"); return errSecSuccess }
    private static func record(_ name: String) { precondition(!Thread.isMainThread); let s = shared; s.lock.lock(); s.operations.append("\(name):\(s.interaction)"); s.lock.unlock() }
}

actor CacheFixture {
    var count = 0
    var waiting: CheckedContinuation<CredentialReadResult, Never>?
    func read() async -> CredentialReadResult { count += 1; return await withCheckedContinuation { waiting = $0 } }
    func finish(_ value: String?, status: Int32 = 0) { waiting?.resume(returning: CredentialReadResult(value: value, status: status)); waiting = nil }
    var pending: Bool { waiting != nil }
}

@main struct CredentialAccessTests {
    @MainActor static func until(_ check: () async -> Bool) async {
        for _ in 0..<200 { if await check() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        fatalError("Fixture did not advance")
    }
    @MainActor static func main() async throws {
        var interactions = [Bool](), allowed = true, ran = false
        let denied = KeychainInteractionPolicy.perform(allowInteraction: false, get: { (0, allowed) }, set: { allowed = $0; interactions.append($0); return 0 }, operation: { ran = true; precondition(!allowed); return CredentialReadResult(value: nil, status: errSecInteractionNotAllowed) })
        precondition(ran && denied.requiresAuthorization && allowed && interactions == [false, true], "Silent read did not restore the previous policy")
        interactions = []; allowed = false
        _ = KeychainInteractionPolicy.perform(allowInteraction: true, get: { (0, allowed) }, set: { allowed = $0; interactions.append($0); return 0 }, operation: { precondition(allowed); return CredentialReadResult(value: "fixture-only", status: 0) })
        precondition(!allowed && interactions == [true, false], "Explicit authorization did not restore the previous policy")
        ran = false
        _ = KeychainInteractionPolicy.perform(allowInteraction: false, get: { (-1, true) }, set: { _ in fatalError("Unexpected policy change") }, operation: { ran = true; return CredentialReadResult(value: nil, status: 0) })
        precondition(!ran, "A failed policy check still queried a credential")

        FixtureSecurity.shared.configure(hold: true)
        let read = Task { await Keychain.read("fixture") }
        await until { FixtureSecurity.shared.didEnter }
        var heartbeat = 0
        let tick = Task { @MainActor in heartbeat += 1 }
        await tick.value
        precondition(heartbeat == 1, "MainActor stalled while a credential read was waiting")
        let write = Task { await Keychain.write("fixture-new", for: "fixture") }
        try await Task.sleep(for: .milliseconds(30))
        precondition(!FixtureSecurity.shared.events.contains { $0.hasPrefix("write:") }, "Write raced the silent read policy")
        FixtureSecurity.shared.release.signal()
        let result = await read.value, status = await write.value
        precondition(result.value == "fixture-only" && status == 0)
        precondition(FixtureSecurity.shared.events == ["UI:false", "read:false", "UI:true", "write:true", "delete:true"], "Keychain queue failed to restore the policy before a write")
        FixtureSecurity.shared.configure(hold: false, status: errSecInteractionNotAllowed)
        let unavailable = await Keychain.read("fixture")
        precondition(unavailable.requiresAuthorization && unavailable.value == nil)
        precondition(FixtureSecurity.shared.events == ["UI:false", "read:false", "UI:true"], "Denied read retried another service or retained the silent flag")

        let source = CacheFixture(), cache = CredentialCache { _ in await source.read() }
        precondition(cache.value("approved") == nil)
        for _ in 0..<20 { _ = cache.value("approved") }
        await until { await source.pending }
        let firstCount = await source.count
        precondition(firstCount == 1, "Automatic reads were not coalesced")
        cache.store("fresh-approved", for: "approved")
        await source.finish("stale-old")
        try await Task.sleep(for: .milliseconds(20))
        precondition(cache.value("approved") == "fresh-approved", "Late read replaced a new approved credential")
        precondition(cache.value("removed") == nil)
        await until { await source.pending }
        cache.store(nil, for: "removed")
        await source.finish("must-not-return")
        try await Task.sleep(for: .milliseconds(20))
        precondition(cache.value("removed") == nil && cache.state("removed") == .unavailable, "Late read restored a disconnected credential")
        precondition(cache.value("denied") == nil)
        await until { await source.pending }
        await source.finish(nil, status: errSecInteractionNotAllowed)
        await until { cache.state("denied") == .authorizationRequired }
        let count = await source.count
        for _ in 0..<20 { _ = cache.value("denied") }
        let finalCount = await source.count
        precondition(finalCount == count, "Denied automatic access caused repeated prompts")
        print("Credential policy, serialized background access, responsive MainActor, coalescing and stale-result guards passed (fake Security only)")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/CredentialCache.swift" "$TASK_TMP/Keychain.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-credential-access"
"$TASK_TMP/test-credential-access"
