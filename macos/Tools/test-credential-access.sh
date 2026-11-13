#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
# 제품의 큐·정책 코드를 그대로 컴파일하고 Security 진입점만 가짜 함수로 바꾼다.
python3 - "$ROOT/Sources/Services/Accounts.swift" "$TASK_TMP/Keychain.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text().split('/// GitHub·사내 GitLab 계정')[0]
# An approval may only read: reading or changing the item's access list needs its own authorization, so macOS asks for the password again.
for api in ('SecKeychainItemSetAccess','SecKeychainItemCopyAccess','SecACLSetContents'):
 assert api not in source, api+' adds a second Keychain password prompt to an approval'
for original,replacement in {'SecKeychainGetUserInteractionAllowed':'FixtureSecurity.getInteraction','SecKeychainSetUserInteractionAllowed':'FixtureSecurity.setInteraction','SecItemCopyMatching':'FixtureSecurity.copy','SecItemUpdate':'FixtureSecurity.update','SecItemAdd':'FixtureSecurity.add','SecItemDelete':'FixtureSecurity.delete'}.items():
 source=source.replace(original,replacement)
pathlib.Path(sys.argv[2]).write_text(source)
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
import Security

enum LegacyData { static let keychainService = "fixture.legacy" }

final class FixtureSecurity: @unchecked Sendable {
    /// The system dialog's answers to an allowed read of an item that does not trust this build
    enum Choice { case allowOnce, alwaysAllow }
    static let shared = FixtureSecurity()
    private let lock = NSLock()
    private var interaction = true
    private var operations: [String] = []
    private var holdRead = false
    private var entered = false
    private var readResult: OSStatus = errSecSuccess
    private var approvalRequired = false
    private var choice = Choice.allowOnce
    private var prompted = 0
    private var legacyOnly = false
    let release = DispatchSemaphore(value: 0)
    func configure(hold: Bool, status: OSStatus = errSecSuccess) { lock.lock(); holdRead = hold; entered = false; readResult = status; operations = []; prompted = 0; lock.unlock() }
    /// The item does not trust this build yet: a silent read fails, an allowed read shows the system dialog.
    func requireApproval(_ answer: Choice = .allowOnce, legacy: Bool = false, status: OSStatus = errSecSuccess) {
        configure(hold: false, status: status)
        lock.lock(); approvalRequired = true; choice = answer; legacyOnly = legacy; lock.unlock()
    }
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return operations }
    /// System dialogs shown since the last configuration
    var prompts: Int { lock.lock(); defer { lock.unlock() }; return prompted }
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
        let s = shared; s.lock.lock(); let hold = s.holdRead
        let query = query as NSDictionary
        let missing = s.legacyOnly && query[kSecAttrService] as? String != LegacyData.keychainService
        let status = missing ? errSecItemNotFound : s.approvalRequired && !s.interaction ? errSecInteractionNotAllowed : s.readResult
        if !missing && s.approvalRequired && s.interaction {
            s.prompted += 1
            // Always Allow is the system's own way to keep an approval; Allow and Deny leave the item as it was.
            if status == errSecSuccess && s.choice == .alwaysAllow { s.approvalRequired = false }
        }
        s.entered = true; s.operations.append("read:\(s.interaction)"); s.lock.unlock()
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

        let security = FixtureSecurity.shared
        security.requireApproval()
        let firstLaunch = await Keychain.read("fixture")
        precondition(firstLaunch.requiresAuthorization && security.prompts == 0, "A silent read asked for approval")
        let once = await Keychain.read("fixture", allowInteraction: true)
        precondition(once.value == "fixture-only" && security.prompts == 1, "Approving a saved credential must ask only once")
        precondition(security.events.filter { !$0.hasPrefix("UI:") && $0.hasSuffix(":true") } == ["read:true"], "An approval did more than the one approved read")
        let afterOnce = CredentialCache { await Keychain.read($0) }
        let notKept = await afterOnce.awaitValue("fixture")
        precondition(notKept == nil && afterOnce.state("fixture") == .authorizationRequired && security.prompts == 1, "After a one-time Allow, the next launch must wait for the user without a dialog")

        security.requireApproval(.alwaysAllow)
        let always = await Keychain.read("fixture", allowInteraction: true)
        precondition(always.value == "fixture-only" && security.prompts == 1, "Approving a saved credential must ask only once")
        let relaunched = CredentialCache { await Keychain.read($0) }
        let restored = await relaunched.awaitValue("fixture")
        precondition(restored == "fixture-only" && relaunched.state("fixture") == .ready && security.prompts == 1, "Always Allow in the one system dialog must restore the next launch silently")

        security.requireApproval(status: errSecUserCanceled)
        let canceled = await Keychain.read("fixture", allowInteraction: true)
        precondition(canceled.requiresAuthorization && security.prompts == 1 && !security.events.contains("write:true") && !security.events.contains("delete:true"), "A denied read changed the saved credential")
        security.requireApproval(legacy: true, status: errSecUserCanceled)
        let failedMigration = await Keychain.read("fixture", allowInteraction: true)
        precondition(failedMigration.value == nil && failedMigration.status == errSecUserCanceled && security.prompts == 1 && !security.events.contains("write:true") && !security.events.contains("delete:true"), "A denied legacy read migrated or deleted the credential")
        security.requireApproval(legacy: true)
        let migrated = await Keychain.read("fixture", allowInteraction: true)
        precondition(migrated.value == "fixture-only" && security.prompts == 1 && security.events.contains("write:true") && security.events.contains("delete:true"), "An approved legacy credential was not moved with one dialog")

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
        for status: Int32 in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable] {
            cache.store("restored-fixture", for: "restored")
            let attempt = cache.begin("restored")
            cache.complete("restored", attempt: attempt, result: CredentialReadResult(value: nil, status: status))
            precondition(cache.value("restored") == "restored-fixture" && cache.state("restored") == .ready, "Transient Keychain failures must retain an existing session")
        }
        let missingAttempt = cache.begin("restored")
        cache.complete("restored", attempt: missingAttempt, result: CredentialReadResult(value: nil, status: errSecItemNotFound))
        precondition(cache.value("restored") == nil && cache.state("restored") == .unavailable, "A missing credential must not retain stale cache data")

        let unavailableCount = await source.count
        for name in ["restored", "removed"] {
            for _ in 0..<20 { cache.retry(name, minimumInterval: 0, now: .distantFuture); cache.prepare(name, now: .distantFuture) }
            let absent = await cache.awaitValue(name)
            precondition(absent == nil)
            precondition(cache.state(name) == .unavailable && cache.value(name) == nil, "Missing or explicitly removed credentials must not silently restore on app activation")
        }
        let afterUnavailableCount = await source.count, unavailablePending = await source.pending
        precondition(afterUnavailableCount == unavailableCount && !unavailablePending, "Lifecycle retry reread an unavailable credential after its future retry date")

        let retrySource = CacheFixture(), retryCache = CredentialCache { _ in await retrySource.read() }
        precondition(retryCache.value("unlocked") == nil)
        await until { await retrySource.pending }
        await retrySource.finish(nil, status: errSecInteractionNotAllowed)
        await until { retryCache.state("unlocked") == .authorizationRequired }
        let retryClock = Date()
        for _ in 0..<20 { retryCache.retry("unlocked", minimumInterval: 300, now: retryClock.addingTimeInterval(30)) }
        let throttledCount = await retrySource.count
        precondition(throttledCount == 1 && retryCache.state("unlocked") == .authorizationRequired, "Lifecycle retry ignored its minimum interval")
        for _ in 0..<20 { retryCache.retry("unlocked", minimumInterval: 300, now: retryClock.addingTimeInterval(301)) }
        await until { await retrySource.pending }
        let retryCount = await retrySource.count
        precondition(retryCount == 2, "Lifecycle retries did not coalesce into one silent read")
        await retrySource.finish("unlocked-fixture")
        await until { retryCache.state("unlocked") == .ready }
        precondition(retryCache.value("unlocked") == "unlocked-fixture")
        for _ in 0..<20 { retryCache.retry("unlocked", minimumInterval: 0, now: retryClock.addingTimeInterval(1000)) }
        let readyCount = await retrySource.count
        precondition(readyCount == 2, "Ready credentials reread on application navigation")
        let deviceAttempt = retryCache.begin("device-unavailable")
        retryCache.complete("device-unavailable", attempt: deviceAttempt, result: CredentialReadResult(value: nil, status: errSecNotAvailable))
        precondition(retryCache.state("device-unavailable") == .unavailable)
        retryCache.retry("device-unavailable", minimumInterval: 0, now: .distantFuture)
        await until { await retrySource.pending }
        let deviceRetryCount = await retrySource.count
        precondition(deviceRetryCount == 3, "A temporarily unavailable Keychain must still recover silently")
        await retrySource.finish("device-restored-fixture")
        await until { retryCache.state("device-unavailable") == .ready }
        precondition(retryCache.value("device-unavailable") == "device-restored-fixture")
        cache.retryInterval = 0
        precondition(cache.value("denied") == nil && cache.state("denied") == .loading, "Denied access was not retried after the back-off")
        await until { await source.pending }
        let retried = await source.count
        precondition(retried == finalCount + 1, "The retry did not read again")
        await source.finish("approved-later")
        await until { cache.value("denied") == "approved-later" }
        precondition(cache.state("denied") == .ready)
        cache.retryInterval = 30
        let waited = Task { await cache.awaitValue("awaited") }
        await until { await source.pending }
        await source.finish("awaited-value")
        let awaited = await waited.value
        precondition(awaited == "awaited-value" && cache.value("awaited") == "awaited-value", "awaitValue did not wait for the read in flight")
        print("Credential policy, one system dialog per approval (Always Allow restores the next session, Allow once does not), legacy approval, denied approval, transient-session retention, guarded retries, awaited reads and stale-result guards passed (fake Keychain storage and system dialog)")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/CredentialCache.swift" "$TASK_TMP/Keychain.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-credential-access"
"$TASK_TMP/test-credential-access"
