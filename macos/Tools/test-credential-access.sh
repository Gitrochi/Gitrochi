#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
# 제품의 큐·정책 코드를 그대로 컴파일하고 Security 진입점만 가짜 함수로 바꾼다.
python3 - "$ROOT/Sources/Services/Accounts.swift" "$TASK_TMP/Keychain.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text().split('/// GitHub·사내 GitLab 계정')[0]
for original,replacement in {'SecKeychainGetUserInteractionAllowed':'FixtureSecurity.getInteraction','SecKeychainSetUserInteractionAllowed':'FixtureSecurity.setInteraction','SecItemCopyMatching':'FixtureSecurity.copy','SecItemUpdate':'FixtureSecurity.update','SecItemAdd':'FixtureSecurity.add','SecItemDelete':'FixtureSecurity.delete','SecKeychainItemCopyAccess':'FixtureSecurity.copyAccess','SecKeychainItemSetAccess':'FixtureSecurity.setAccess','SecKeychainItem':'FixtureKeychainItem'}.items():
 source=source.replace(original,replacement)
pathlib.Path(sys.argv[2]).write_text(source)
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
import Security

enum LegacyData { static let keychainService = "fixture.legacy" }

final class FixtureKeychainItem: NSObject {
    var access: SecAccess?
}

final class FixtureSecurity: @unchecked Sendable {
    static let shared = FixtureSecurity()
    private let lock = NSLock()
    private var interaction = true
    private var operations: [String] = []
    private var holdRead = false
    private var entered = false
    private var readResult: OSStatus = errSecSuccess
    private var approvalRequired = false
    private var persistResult: OSStatus = errSecSuccess
    private var legacyOnly = false
    private let item = FixtureKeychainItem()
    private var originalSelector = SecKeychainPromptSelector(rawValue: 0)
    let release = DispatchSemaphore(value: 0)
    func configure(hold: Bool, status: OSStatus = errSecSuccess) { lock.lock(); holdRead = hold; entered = false; readResult = status; operations = []; lock.unlock() }
    func requireApproval(persistStatus: OSStatus = errSecSuccess, legacy: Bool = false) {
        configure(hold: false)
        var application: SecTrustedApplication?, access: SecAccess?
        precondition(SecTrustedApplicationCreateFromPath("/bin/ls", &application) == errSecSuccess)
        precondition(SecAccessCreate("Fixture credential" as CFString, [application!] as CFArray, &access) == errSecSuccess)
        let entries = SecAccessCopyMatchingACLList(access!, kSecACLAuthorizationDecrypt) as! [SecACL]
        var applications: CFArray?, description: CFString?, selector = SecKeychainPromptSelector(rawValue: 0)
        precondition(SecACLCopyContents(entries[0], &applications, &description, &selector) == errSecSuccess)
        lock.lock(); originalSelector = selector; item.access = access; approvalRequired = true; persistResult = persistStatus; legacyOnly = legacy; lock.unlock()
    }
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
        let s = shared; s.lock.lock(); let hold = s.holdRead
        let query = query as NSDictionary
        let missing = s.legacyOnly && query[kSecAttrService] as? String != LegacyData.keychainService
        let status = missing ? errSecItemNotFound : s.approvalRequired && !s.interaction ? errSecInteractionNotAllowed : s.readResult
        s.entered = true; s.operations.append("read:\(s.interaction)"); s.lock.unlock()
        if hold { s.release.wait() }
        if status == errSecSuccess {
            if query[kSecReturnRef] as? Bool == true {
                output?.pointee = [kSecValueData as String: Data("fixture-only".utf8), kSecValueRef as String: s.item] as CFDictionary
            } else { output?.pointee = Data("fixture-only".utf8) as CFData }
        }
        return status
    }
    static func copyAccess(_ item: FixtureKeychainItem, _ output: UnsafeMutablePointer<SecAccess?>) -> OSStatus {
        record("access"); output.pointee = item.access; return errSecSuccess
    }
    static func setAccess(_ item: FixtureKeychainItem, _ access: SecAccess) -> OSStatus {
        record("remember")
        let s = shared; s.lock.lock(); defer { s.lock.unlock() }
        guard s.persistResult == errSecSuccess else { return s.persistResult }
        precondition(s.interaction, "Trust changed without explicit approval")
        item.access = access; s.approvalRequired = false; return errSecSuccess
    }
    var trustedApplications: [SecTrustedApplication] {
        lock.lock(); defer { lock.unlock() }
        let entries = SecAccessCopyMatchingACLList(item.access!, kSecACLAuthorizationDecrypt) as! [SecACL]
        var applications: CFArray?, description: CFString?, selector = SecKeychainPromptSelector(rawValue: 0)
        precondition(SecACLCopyContents(entries[0], &applications, &description, &selector) == errSecSuccess)
        precondition(description as String? == "Fixture credential", "Approval replaced the credential's description")
        precondition(selector == originalSelector, "Approval changed the credential's prompt restrictions")
        return applications as! [SecTrustedApplication]
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
        precondition(firstLaunch.requiresAuthorization && !security.events.contains("remember:true"))
        let oneTime = await Keychain.read("fixture", allowInteraction: true)
        precondition(oneTime.value == "fixture-only" && !security.events.contains("remember:true"), "An ordinary read changed saved permissions")
        let invalidPolicy = await Keychain.read("fixture", rememberAccess: true)
        precondition(invalidPolicy.status == errSecParam, "Silent access was allowed to change permissions")
        let approved = await Keychain.read("fixture", allowInteraction: true, rememberAccess: true)
        precondition(approved.value == "fixture-only" && security.events.contains("remember:true"))
        let trusted = security.trustedApplications
        precondition(trusted.count == 2, "Approval removed an existing trusted app or allowed every application")
        var priorPath: CFData?, currentPath: CFData?, expectedPath: CFData?, currentApp: SecTrustedApplication?
        precondition(SecTrustedApplicationCreateFromPath(nil, &currentApp) == errSecSuccess)
        precondition(SecTrustedApplicationCopyData(trusted[0], &priorPath) == errSecSuccess)
        precondition(SecTrustedApplicationCopyData(trusted[1], &currentPath) == errSecSuccess)
        precondition(SecTrustedApplicationCopyData(currentApp!, &expectedPath) == errSecSuccess)
        precondition(!CFEqual(priorPath!, currentPath!) && CFEqual(currentPath!, expectedPath!), "Approval trusted a different app")
        let relaunched = CredentialCache { await Keychain.read($0) }
        let restored = await relaunched.awaitValue("fixture")
        precondition(restored == "fixture-only" && relaunched.state("fixture") == .ready, "A new app session lost saved approval")

        security.requireApproval(persistStatus: errSecUserCanceled)
        let notSaved = await Keychain.read("fixture", allowInteraction: true, rememberAccess: true)
        precondition(notSaved.value == nil && notSaved.status == errSecUserCanceled, "Failed persistence was reported as saved approval")
        let stillDenied = await Keychain.read("fixture")
        precondition(stillDenied.requiresAuthorization, "Failed persistence changed saved trust")
        security.requireApproval()
        security.configure(hold: false, status: errSecUserCanceled)
        let canceled = await Keychain.read("fixture", allowInteraction: true, rememberAccess: true)
        precondition(canceled.requiresAuthorization && !security.events.contains("access:true") && !security.events.contains("remember:true"), "A denied read changed saved permissions")
        security.requireApproval(persistStatus: errSecUserCanceled, legacy: true)
        let failedMigration = await Keychain.read("fixture", allowInteraction: true, rememberAccess: true)
        precondition(failedMigration.value == nil && failedMigration.status == errSecUserCanceled && !security.events.contains("write:true") && !security.events.contains("delete:true"), "Failed legacy approval migrated or deleted the credential")
        security.requireApproval(legacy: true)
        let migrated = await Keychain.read("fixture", allowInteraction: true, rememberAccess: true)
        precondition(migrated.value == "fixture-only" && security.events.contains("remember:true") && security.events.contains("write:true") && security.events.contains("delete:true"), "Legacy approval was not saved before migration")

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
        print("Credential policy, persistent approval across sessions, legacy approval, failed/denied persistence, transient-session retention, guarded retries, awaited reads and stale-result guards passed (fake Keychain storage; in-memory Security ACLs)")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/CredentialCache.swift" "$TASK_TMP/Keychain.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-credential-access"
"$TASK_TMP/test-credential-access"
