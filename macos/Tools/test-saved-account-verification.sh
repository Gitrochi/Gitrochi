#!/usr/bin/env bash
# Compile the production approval method and credential cache with fake Keychain/HTTP only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT/Sources/Services/Accounts.swift" "$TASK_TMP/Approval.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
def extract(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    quoted = False
    escaped = False
    for index in range(opening, len(source)):
        char = source[index]
        if quoted:
            if escaped: escaped = False
            elif char == '\\': escaped = True
            elif char == '"': quoted = False
            continue
        if char == '"': quoted = True
        elif char == '{': depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError('Production account method is unbalanced')
method = extract('    func allowStoredAccess(for account: HostAccount) async throws {')
assert 'Keychain.read' in method and 'Hosting.me' in method and 'credentials.isCurrent' in method
methods = [method] + [extract(marker) for marker in ['    func token(for a: HostAccount)', '    private func secret(_ name: String)', '    func credentialState(for account: HostAccount)', '    func loadToken(for a: HostAccount)', '    func awaitsAccess(_ account: HostAccount)']]
Path(sys.argv[2]).write_text('''import Foundation
import Security

@MainActor final class AccountFixture {
    var accounts: [HostAccount]
    let credentials = CredentialCache { _ in fatalError("Fixture must not perform automatic credential reads") }
    init(_ account: HostAccount, cached: String?) {
        accounts = [account]
        credentials.store(cached, for: "acct:" + account.id)
    }
''' + '\n'.join(methods) + '\n}\n')
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
import Security

enum Provider: String { case github, gitlab }
struct HostAccount: Equatable { let id: String; let provider: Provider; let username: String; let apiBase: String }
struct HostingError: Error { let status: Int }
struct FixtureUser { let username: String }
@MainActor enum Keychain {
    static var reads: [(String, Bool)] = []
    static var result = CredentialReadResult(value: "approved-fixture", status: errSecSuccess)
    static var results: [String: CredentialReadResult] = [:]
    static func read(_ name: String, allowInteraction: Bool = false) async -> CredentialReadResult {
        reads.append((name, allowInteraction)); return results[name] ?? result
    }
}
@MainActor enum Hosting {
    static var calls = 0
    static var handler: () async throws -> FixtureUser = { FixtureUser(username: "demo") }
    static func me(_ provider: Provider, token: String, apiBase: String) async throws -> FixtureUser {
        precondition(token == "approved-fixture" && apiBase == "https://api.example.com")
        calls += 1; return try await handler()
    }
}
@main struct SavedAccountVerificationTests {
    @MainActor static func main() async throws {
        let account = HostAccount(id: "fixture-account", provider: .github, username: "demo", apiBase: "https://api.example.com"), name = "acct:fixture-account"
        func reset() { Keychain.reads = []; Keychain.results = [:]; Keychain.result = CredentialReadResult(value: "approved-fixture", status: errSecSuccess); Hosting.calls = 0 }
        func assertExplicitRead() { precondition(Keychain.reads.count == 1 && Keychain.reads[0].0 == name && Keychain.reads[0].1, "Only one explicit synthetic Keychain read may run") }
        reset(); let accepted = AccountFixture(account, cached: "previously-verified-fixture")
        Hosting.handler = { FixtureUser(username: "DEMO") }
        try await accepted.allowStoredAccess(for: account)
        precondition(accepted.credentials.value(name) == "approved-fixture" && accepted.credentials.state(name) == .ready)
        assertExplicitRead()
        for status in [0, 403, 429, 500, 503] {
            reset(); let model = AccountFixture(account, cached: "previously-verified-fixture")
            Hosting.handler = { if status == 0 { throw URLError(.notConnectedToInternet) }; throw HostingError(status: status) }
            do { try await model.allowStoredAccess(for: account); fatalError("Failed verification reported success") } catch {}
            precondition(model.credentials.value(name) == "approved-fixture" && model.credentials.state(name) == .ready, "Transient verification must retain the approved saved credential")
            precondition(Hosting.calls == 1); assertExplicitRead()
        }
        for mismatch in [false, true] {
            reset(); let model = AccountFixture(account, cached: "previously-verified-fixture")
            Hosting.handler = { if mismatch { return FixtureUser(username: "other") }; throw HostingError(status: 401) }
            do { try await model.allowStoredAccess(for: account); fatalError("Invalid identity reported success") } catch {}
            precondition(model.credentials.value(name) == nil && model.credentials.state(name) == .unavailable, "Rejected credentials or wrong identity must not remain usable")
            precondition(Hosting.calls == 1); assertExplicitRead()
            for _ in 0..<20 { model.credentials.retry(name, minimumInterval: 0, now: .distantFuture) }
            model.credentials.prepare(name, now: .distantFuture)
            let rejectedLoad = await model.loadToken(for: account)
            precondition(rejectedLoad == nil, "Awaited reads must not restore rejected credentials")
            precondition(model.credentials.value(name) == nil && model.credentials.state(name) == .unavailable, "Rejected credentials must not silently restore after the lifecycle retry date")
            precondition(Hosting.calls == 1); assertExplicitRead()
        }
        reset(); let denied = AccountFixture(account, cached: nil)
        Keychain.result = CredentialReadResult(value: nil, status: errSecInteractionNotAllowed)
        Hosting.handler = { fatalError("Denied Keychain access must not contact the server") }
        do { try await denied.allowStoredAccess(for: account); fatalError("Denied Keychain read accepted") } catch {}
        precondition(denied.credentials.state(name) == .authorizationRequired && Hosting.calls == 0); assertExplicitRead()
        reset(); let replaced = AccountFixture(account, cached: "previously-verified-fixture")
        Hosting.handler = { replaced.credentials.store("replacement-fixture", for: name); return FixtureUser(username: "demo") }
        try await replaced.allowStoredAccess(for: account)
        precondition(replaced.credentials.value(name) == "replacement-fixture", "Late verification must not replace newer credentials")
        reset(); let removed = AccountFixture(account, cached: "previously-verified-fixture")
        Hosting.handler = { removed.accounts = []; removed.credentials.store(nil, for: name); return FixtureUser(username: "demo") }
        try await removed.allowStoredAccess(for: account)
        precondition(removed.credentials.value(name) == nil && removed.credentials.state(name) == .unavailable, "Removed account must not recover a credential from an old request")
        let legacyAccount = HostAccount(id: "legacy-fixture", provider: .github, username: "demo", apiBase: "https://api.example.com"), legacyName = "acct:legacy-fixture"
        func legacyFixture() -> AccountFixture {
            reset()
            Keychain.results[legacyName] = CredentialReadResult(value: nil, status: errSecItemNotFound)
            let model = AccountFixture(legacyAccount, cached: nil)
            model.credentials.store("approved-fixture", for: legacyAccount.provider.rawValue)
            precondition(model.token(for: legacyAccount) == "approved-fixture" && model.credentialState(for: legacyAccount) == .ready)
            return model
        }
        for mismatch in [false, true] {
            let legacy = legacyFixture()
            Hosting.handler = { if mismatch { return FixtureUser(username: "other") }; throw HostingError(status: 401) }
            do { try await legacy.allowStoredAccess(for: legacyAccount); fatalError("Rejected legacy identity reported success") } catch {}
            precondition(legacy.token(for: legacyAccount) == nil && legacy.credentialState(for: legacyAccount) == .unavailable, "Rejected provider fallback remained usable after legacy verification failed")
            precondition(legacy.credentials.value(legacyAccount.provider.rawValue) == nil && legacy.credentials.state(legacyAccount.provider.rawValue) == .unavailable)
            for key in [legacyName, legacyAccount.provider.rawValue] { legacy.credentials.retry(key, minimumInterval: 0, now: .distantFuture); legacy.credentials.prepare(key, now: .distantFuture) }
            let legacyLoad = await legacy.loadToken(for: legacyAccount)
            precondition(legacyLoad == nil)
            precondition(legacy.token(for: legacyAccount) == nil && legacy.credentialState(for: legacyAccount) == .unavailable)
            precondition(Keychain.reads.map { $0.0 } == [legacyName, legacyAccount.provider.rawValue] && Keychain.reads.allSatisfy { $0.1 } && Hosting.calls == 1, "Legacy recovery must only read the explicit synthetic primary and fallback once")
        }
        for mismatch in [false, true] {
            let rotated = legacyFixture()
            Hosting.handler = {
                rotated.credentials.store("rotated-fixture", for: legacyName)
                if mismatch { return FixtureUser(username: "other") }; throw HostingError(status: 401)
            }
            try await rotated.allowStoredAccess(for: legacyAccount)
            precondition(rotated.token(for: legacyAccount) == "rotated-fixture" && rotated.credentialState(for: legacyAccount) == .ready, "An older rejection cleared a newer rotated credential")
        }
        let legacyRemoved = legacyFixture()
        Hosting.handler = {
            legacyRemoved.accounts = []
            legacyRemoved.credentials.store(nil, for: legacyName)
            legacyRemoved.credentials.store(nil, for: legacyAccount.provider.rawValue)
            throw HostingError(status: 401)
        }
        try await legacyRemoved.allowStoredAccess(for: legacyAccount)
        precondition(legacyRemoved.token(for: legacyAccount) == nil && legacyRemoved.credentialState(for: legacyAccount) == .unavailable, "A late legacy verification restored a disconnected account")
        print("Saved account verification passed: actual approval/cache code, transient credential preservation, invalid identity and legacy-fallback rejection, explicit-read and late-response guards (fake Keychain/HTTP only)")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/CredentialCache.swift" "$ROOT/Sources/Services/GitHubLoginIdentity.swift" "$ROOT/Sources/Services/AccountConnectionFailure.swift" "$TASK_TMP/Approval.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-saved-account-verification"
"$TASK_TMP/test-saved-account-verification"
