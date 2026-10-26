import Foundation
import Security
import Observation

/// 토큰·API 키를 macOS 키체인(일반 암호)에 보관한다.
enum Keychain {
    private static let service = "com.ensnif.Gitrochi"
    private static let queue = DispatchQueue(label: "com.ensnif.Gitrochi.keychain", qos: .userInitiated)

    /// 모든 Keychain 호출은 같은 큐에서 실행해 UI 허용 정책과 사용자 승인이 경합하지 않게 한다.
    static func read(_ account: String, allowInteraction: Bool = false) async -> CredentialReadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = withInteraction(allowInteraction) {
                    let current = copy(service, account)
                    guard current.status == errSecItemNotFound else { return current }
                    // 이전 서비스는 읽기만 한다. 자동 조회에서 이동·수정으로 승인창을 띄우지 않는다.
                    return copy(LegacyData.keychainService, account)
                }
                continuation.resume(returning: result)
            }
        }
    }

    static func get(_ account: String) async -> String? { await read(account).value }

    @discardableResult
    static func set(_ value: String?, for account: String) async -> Bool {
        await write(value, for: account) == errSecSuccess
    }

    /// 자격 증명 내용은 넘기지 않고 저장 실패 코드만 호출자에게 보존한다.
    static func write(_ value: String?, for account: String) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = withInteraction(true) {
                    guard let value, !value.isEmpty else {
                        let current = delete(service, account), legacy = delete(LegacyData.keychainService, account)
                        return CredentialReadResult(value: nil, status: current == errSecSuccess ? legacy : current)
                    }
                    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
                    let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
                    if update == errSecSuccess { _ = delete(LegacyData.keychainService, account); return CredentialReadResult(value: nil, status: errSecSuccess) }
                    guard update == errSecItemNotFound else { return CredentialReadResult(value: nil, status: update) }
                    var add = query; add[kSecValueData as String] = Data(value.utf8)
                    let status = SecItemAdd(add as CFDictionary, nil)
                    if status == errSecSuccess { _ = delete(LegacyData.keychainService, account) }
                    return CredentialReadResult(value: nil, status: status)
                }
                continuation.resume(returning: result.status)
            }
        }
    }

    // file-based 키체인은 LAContext의 무음 옵션을 따르지 않아 공식 legacy 정책을 큐 안에서 한정한다.
    private static func withInteraction(_ allowed: Bool, operation: () -> CredentialReadResult) -> CredentialReadResult {
        KeychainInteractionPolicy.perform(allowInteraction: allowed, get: {
            var previous = DarwinBoolean(false)
            let status = SecKeychainGetUserInteractionAllowed(&previous)
            return (status, previous.boolValue)
        }, set: { SecKeychainSetUserInteractionAllowed($0) }, operation: operation)
    }

    private static func copy(_ service: String, _ account: String) -> CredentialReadResult {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let value = String(data: data, encoding: .utf8) else {
            return CredentialReadResult(value: nil, status: status == errSecSuccess ? errSecDecode : status)
        }
        return CredentialReadResult(value: value, status: errSecSuccess)
    }

    private static func delete(_ service: String, _ account: String) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// GitHub·사내 GitLab 계정(여러 개). 앱 전체에서 하나만 쓴다.
@MainActor @Observable
final class AccountStore {
    static let shared = AccountStore()

    /// 연결한 계정들(GitHub 여러 개, 사내 GitLab 서버별 여러 개)
    private(set) var accounts: [HostAccount] = []
    /// 계정이 바뀔 때마다 증가 — 열린 저장소가 PR 목록을 다시 읽는 신호
    private(set) var revision = 0
    /// 열린 저장소가 사내 GitLab 인데 계정이 없을 때, 설정 화면에 미리 채워 둘 서버 주소
    var suggestedGitLabServer = ""

    var ghPath: String? { ToolStore.shared.path(.gh) }

    /// 저장소 경로 → 그 저장소에서 쓸 계정 ID(같은 서버에 계정이 여럿일 때)
    private var preferred: [String: String]
    /// 같은 서버의 다른 주소: 저장소 원격 호스트 → 계정 ID (예: git.example.com → gitlab.example.com 계정, 같은 서버를 다른 도메인으로 쓸 때)
    private var aliases: [String: String]
    private let credentials = CredentialCache { await Keychain.read($0) }
    private var connectionAttempts: [String: UUID] = [:]

    private init() {
        let d = UserDefaults.standard
        preferred = (d.dictionary(forKey: "preferredAccounts") as? [String: String]) ?? [:]
        aliases = (d.dictionary(forKey: "hostAliases") as? [String: String]) ?? [:]
        if let data = d.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([HostAccount].self, from: data) {
            accounts = saved
            // 예전 형식(계정 하나, 서버 주소 없음)이었으면 새 형식으로 다시 저장해 둔다
            if let raw = String(data: data, encoding: .utf8), !raw.contains("\"server\"") {
                d.set(try? JSONEncoder().encode(saved), forKey: "accounts")
            }
        }
        credentials.onChange = { [weak self] in self?.revision += 1 }
        for account in accounts {
            credentials.prepare("acct:" + account.id)
            if account.id.hasPrefix("legacy-") { credentials.prepare(account.provider.rawValue) }
        }
        Askpass.install()
    }

    func accounts(for provider: Provider) -> [HostAccount] {
        accounts.filter { $0.provider == provider }
    }

    /// gitch의 서버-로그인 SSH 별칭을 API 서버 주소와 연결한다. 겹치는 별칭은 추측하지 않는다.
    var sshHostAliases: [String: String] {
        let pairs = accounts.map { (alias: String($0.host.split(separator: ".").first ?? "") + "-" + $0.username.lowercased(), host: $0.host.lowercased()) }
        return Dictionary(grouping: pairs, by: \.alias).compactMapValues { values in
            let hosts = Set(values.map(\.host)); return hosts.count == 1 ? hosts.first : nil
        }
    }

    /// 이 저장소에 쓸 계정: 저장소마다 고른 계정 → 없으면 그 서버의 첫 계정
    func account(for t: RepoTarget, repoPath: String?) -> HostAccount? {
        let list = candidates(for: t)
        if let repoPath, let id = preferred[repoPath], let a = list.first(where: { $0.id == id }) { return a }
        return list.first
    }

    /// 이 저장소 서버에 쓸 수 있는 계정(같은 주소이거나, 같은 서버의 다른 주소로 확인된 계정)
    func candidates(for t: RepoTarget) -> [HostAccount] {
        accounts.filter { $0.provider == t.provider && ($0.host == t.host || aliases[t.host] == $0.id) }
    }

    /// 저장소 서버 주소가 연결된 계정 서버의 다른 이름인지 확인해 같은 서버로 기억한다.
    /// sameAddressOnly 이면 두 주소가 같은 IP 를 가리킬 때만 토큰으로 확인한다(엉뚱한 서버로 토큰을 보내지 않게).
    @discardableResult
    func discoverAlias(for t: RepoTarget, sameAddressOnly: Bool) async -> HostAccount? {
        for a in accounts(for: t.provider) where a.host != t.host {
            if sameAddressOnly {
                let x = a.host, y = t.host
                let same = await Task.detached { !Self.addresses(x).isDisjoint(with: Self.addresses(y)) }.value
                guard same else { continue }
            }
            guard let tok = token(for: a),
                  let me = try? await Hosting.me(t.provider, token: tok, apiBase: "https://\(t.host)/api/v4"),
                  me.username == a.username else { continue }
            aliases[t.host] = a.id
            UserDefaults.standard.set(aliases, forKey: "hostAliases")
            revision += 1
            return a
        }
        return nil
    }

    /// 호스트 이름이 가리키는 IP 주소들
    nonisolated static func addresses(_ host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out = Set<String>()
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.insert(String(cString: buf))
            }
            cur = ai.pointee.ai_next
        }
        return out
    }

    func setPreferred(_ a: HostAccount, for repoPath: String) {
        preferred[repoPath] = a.id
        UserDefaults.standard.set(preferred, forKey: "preferredAccounts")
        revision += 1
    }

    func token(for a: HostAccount) -> String? {
        if let t = secret("acct:" + a.id) { return t }
        // 예전 버전(계정 하나)에서 저장한 토큰
        return a.id.hasPrefix("legacy-") ? secret(a.provider.rawValue) : nil
    }

    private func secret(_ name: String) -> String? {
        credentials.value(name)
    }

    func credentialState(for account: HostAccount) -> CredentialCache.State {
        if token(for: account) != nil { return .ready }
        let primary = credentials.state("acct:" + account.id)
        if primary == .authorizationRequired { return primary }
        if account.id.hasPrefix("legacy-") {
            let legacy = credentials.state(account.provider.rawValue)
            if legacy == .authorizationRequired || legacy == .loading { return legacy }
        }
        return primary
    }

    /// 사용자가 누른 경우에만 시스템 승인을 허용하고 기존 토큰의 계정을 다시 확인한다.
    func allowStoredAccess(for account: HostAccount) async throws {
        guard accounts.contains(account) else { return }
        let name = "acct:" + account.id, attempt = credentials.begin("acct:" + account.id)
        var result = await Keychain.read(name, allowInteraction: true)
        if result.status == errSecItemNotFound, account.id.hasPrefix("legacy-") {
            result = await Keychain.read(account.provider.rawValue, allowInteraction: true)
        }
        guard credentials.isCurrent(name, attempt: attempt), accounts.contains(account) else { return }
        guard let value = result.value else {
            credentials.complete(name, attempt: attempt, result: result)
            throw AccountConnectionFailure.credentialAccess(status: result.status)
        }
        do {
            let me = try await Hosting.me(account.provider, token: value, apiBase: account.apiBase)
            guard credentials.isCurrent(name, attempt: attempt), accounts.contains(account) else { return }
            guard me.username.caseInsensitiveCompare(account.username) == .orderedSame else { throw AccountConnectionFailure.identityMismatch }
            credentials.complete(name, attempt: attempt, result: CredentialReadResult(value: value, status: errSecSuccess))
        } catch {
            guard credentials.isCurrent(name, attempt: attempt), accounts.contains(account) else { return }
            credentials.complete(name, attempt: attempt, result: CredentialReadResult(value: nil, status: errSecAuthFailed))
            if let known = error as? AccountConnectionFailure { throw known }
            throw AccountConnectionFailure.verification(status: (error as? HostingError)?.status)
        }
    }

    // MARK: 연결·해제

    /// "gitlab.회사.co.kr" → "https://gitlab.회사.co.kr" (끝 / 제거)
    static func normalizeServer(_ s: String) -> String {
        var v = s.trimmed
        if !v.contains("://") { v = "https://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    @discardableResult
    func connectGitHub(token: String) async throws -> HostAccount {
        try await add(.github, server: "https://github.com", token: token)
    }

    /// 사내(자체 호스팅) GitLab 만 받는다 — gitlab.com 은 지금은 연결하지 않는다
    @discardableResult
    func connectGitLab(server: String, token: String) async throws -> HostAccount {
        let base = Self.normalizeServer(server)
        guard let host = URL(string: base)?.host?.lowercased(), !host.isEmpty else {
            throw GitError(command: "gitlab", message: String(localized: "Check the server address. Example: https://gitlab.example.com"))
        }
        if host == "gitlab.com" || host.hasSuffix(".gitlab.com") {
            throw GitError(command: "gitlab", message: String(localized: "Only self-hosted GitLab can be connected for now. Enter your GitLab server address."))
        }
        return try await add(.gitlab, server: base, token: token)
    }

    private func add(_ provider: Provider, server: String, token: String) async throws -> HostAccount {
        let t = token.trimmed
        let connectionKey = provider.rawValue + "|" + server, attempt = UUID(), initialAccounts = accounts
        connectionAttempts[connectionKey] = attempt
        let probe = HostAccount(id: "", provider: provider, server: server, username: "", name: nil, avatarURL: nil)
        let me = try await Hosting.me(provider, token: t, apiBase: probe.apiBase)
        let original = initialAccounts.first { $0.provider == provider && $0.host == probe.host && $0.username == me.username }
        let current = { self.connectionAttempts[connectionKey] == attempt && (original == nil || self.accounts.contains { $0.id == original?.id }) }
        guard current() else { throw CancellationError() }
        // 같은 서버의 같은 사용자면 토큰만 바꾼다
        let existing = accounts.first { $0.provider == provider && $0.host == probe.host && $0.username == me.username }
        let acc = HostAccount(id: existing?.id ?? UUID().uuidString, provider: provider, server: server,
                              username: me.username, name: me.name, avatarURL: me.avatarURL)
        let status = await Keychain.write(t, for: "acct:" + acc.id)
        guard current() else { throw CancellationError() }
        guard status == errSecSuccess else {
            throw AccountConnectionFailure.credentialSave(status: status)
        }
        credentials.store(t, for: "acct:" + acc.id)
        accounts.removeAll { $0.id == acc.id }
        accounts.append(acc)
        save()
        return acc
    }

    /// gh CLI 에 로그인돼 있는 GitHub 계정을 가져온다
    @discardableResult
    func importGitHubCLI(expectedLogin: String? = nil) async throws -> HostAccount {
        guard let gh = ghPath else { throw AccountConnectionFailure.missingCLI }
        let args = ["auth", "token", "--hostname", "github.com"] + (expectedLogin.map { ["--user", $0] } ?? [])
        var env = ProcessInfo.processInfo.environment
        if expectedLogin != nil {
            for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] { env.removeValue(forKey: key) }
        }
        let r: GitResult
        do {
            r = try await Shell.run(gh, args, cwd: FileManager.default.temporaryDirectory, env: env, timeout: 30)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountConnectionFailure.credentialRead
        }
        let t = r.output.trimmed
        guard r.status == 0, !t.isEmpty else {
            throw AccountConnectionFailure.credentialRead
        }
        do {
            if let expectedLogin {
                let me = try await Hosting.me(.github, token: t, apiBase: "https://api.github.com")
                guard me.username.caseInsensitiveCompare(expectedLogin) == .orderedSame else {
                    throw AccountConnectionFailure.identityMismatch
                }
            }
            return try await connectGitHub(token: t)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AccountConnectionFailure {
            throw failure
        } catch {
            throw AccountConnectionFailure.verification(status: (error as? HostingError)?.status)
        }
    }

    /// Uploads only a public key after the user chooses the registration action.
    func registerGitHubSSHKey(_ setup: Gitch.AccountSetup) async throws -> Bool {
        guard setup.host.lowercased() == "github.com",
              let account = accounts(for: .github).first(where: { $0.username.caseInsensitiveCompare(setup.id) == .orderedSame }),
              let secret = token(for: account) else {
            throw Gitch.Failure(message: String(localized: "Sign in to GitHub with the same account name before registering this key."))
        }
        return try await GitHubSSHRegistration.register(publicKey: setup.publicKey, login: setup.id, token: secret)
    }

    func disconnect(_ a: HostAccount) {
        credentials.store(nil, for: "acct:" + a.id)
        Task { await Keychain.set(nil, for: "acct:" + a.id) }
        if a.id.hasPrefix("legacy-") {
            credentials.store(nil, for: a.provider.rawValue)
            Task { await Keychain.set(nil, for: a.provider.rawValue) }
        }
        accounts.removeAll { $0.id == a.id }
        preferred = preferred.filter { $0.value != a.id }
        UserDefaults.standard.set(preferred, forKey: "preferredAccounts")
        aliases = aliases.filter { $0.value != a.id }
        UserDefaults.standard.set(aliases, forKey: "hostAliases")
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
        revision += 1
    }

    /// 네트워크 git 명령에 붙일 환경: 서버마다 계정 하나씩(이 저장소에 고른 계정 우선) 토큰으로 HTTPS 인증에 답한다.
    /// 키체인·자격 증명 도우미가 먼저 답하면 그것이 쓰이고, 비어 있을 때만 이 토큰이 쓰인다.
    func gitEnvironment(target: RepoTarget?, repoPath: String?) -> [String: String] {
        guard let askpass = Askpass.path else { return [:] }
        var byHost: [String: HostAccount] = [:]
        for a in accounts where byHost[a.host] == nil { byHost[a.host] = a }
        // 같은 서버의 다른 주소에도 그 계정 토큰으로 답한다
        for (host, id) in aliases where byHost[host] == nil {
            if let a = accounts.first(where: { $0.id == id }) { byHost[host] = a }
        }
        if let target, let a = account(for: target, repoPath: repoPath) { byHost[target.host] = a }
        var env: [String: String] = ["GIT_ASKPASS": askpass]
        var i = 0
        for (host, a) in byHost.sorted(by: { $0.key < $1.key }) {
            guard let tok = token(for: a) else { continue }
            i += 1
            env["GITROCHI_ASKPASS_HOST_\(i)"] = host
            env["GITROCHI_ASKPASS_USER_\(i)"] = a.provider == .github ? "x-access-token" : "oauth2"
            env["GITROCHI_ASKPASS_PASS_\(i)"] = tok
        }
        guard i > 0 else { return [:] }
        env["GITROCHI_ASKPASS_COUNT"] = String(i)
        return env
    }
}

/// GIT_ASKPASS 로 쓰는 작은 셸 스크립트(~/Library/Application Support/Gitrochi/askpass.sh)
enum Askpass {
    static var path: String? {
        let p = directory.appendingPathComponent("askpass.sh").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitrochi", isDirectory: true)
    }

    static func install() {
        let script = """
        #!/bin/sh
        # Gitrochi: 연결된 계정 토큰으로 HTTPS git 인증 질문에 답한다(GIT_ASKPASS).
        # 서버마다 GITROCHI_ASKPASS_HOST_n / USER_n / PASS_n 이 넘어온다.
        n=${GITROCHI_ASKPASS_COUNT:-0}
        i=1
        while [ "$i" -le "$n" ]; do
          eval host=\\$GITROCHI_ASKPASS_HOST_$i
          if [ -n "$host" ] && printf '%s' "$1" | grep -qF "$host"; then
            eval user=\\$GITROCHI_ASKPASS_USER_$i
            eval pass=\\$GITROCHI_ASKPASS_PASS_$i
            [ -n "$pass" ] || exit 1
            case "$1" in
              Username*) printf '%s\\n' "$user" ;;
              *) printf '%s\\n' "$pass" ;;
            esac
            exit 0
          fi
          i=$((i + 1))
        done
        exit 1

        """
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("askpass.sh")
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
}
