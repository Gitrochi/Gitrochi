import Foundation

/// Connects a saved hosting account to gitch: the account details come from its token, the public key is registered
/// with the same token, and only public details (name, email, server, folder) reach gitch. The token and the private
/// key never leave the Keychain and ~/.ssh. (Windows: entities/gitch/model/connect.ts and HostingAccounts)
enum GitchConnect {
    /// The token can't add SSH keys; the person copies the key instead, and this says why
    struct MissingScope: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The servers of a gitch account, without the port and login notes of `gitch list` ("gitlab.x(포트 2222)")
    static func hosts(_ account: Gitch.Account) -> [String] {
        account.hosts.split(separator: ",").map {
            String($0.split(separator: "(").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
    }

    /// The gitch account already set up for this name on this server
    static func existing(name: String, host: String, in accounts: [Gitch.Account]) -> Gitch.Account? {
        accounts.first { $0.id == name && hosts($0).contains(host.lowercased()) }
    }

    /// The login as a gitch account name; when another server's account has that name, the server's own label is
    /// added (`ensnif-smart-fact` for gitlab.smart-fact.co.kr)
    static func accountName(login: String, host: String, taken: [Gitch.Account]) -> String {
        var name = String(login.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
        while let first = name.first, !(first.isLetter || first.isNumber) { name.removeFirst() }
        if name.isEmpty { name = "account" }
        guard let other = taken.first(where: { $0.id == name }), !hosts(other).contains(host.lowercased()) else { return name }
        let labels = host.lowercased().split(separator: ".").map(String.init)
        let label = labels.dropLast().first { !["www", "git", "gitlab", "ssh"].contains($0) } ?? labels.first ?? "server"
        var candidate = name + "-" + label, n = 2
        while let used = taken.first(where: { $0.id == candidate }), !hosts(used).contains(host.lowercased()) {
            candidate = name + "-" + label + "-\(n)"; n += 1
        }
        return candidate
    }

    struct GitHubEmail: Decodable { let email: String; let primary: Bool?; let verified: Bool? }

    /// Verified addresses with the primary first; when the account keeps its email private (no public email),
    /// GitHub's noreply address is offered too
    static func gitHubEmails(listed: [GitHubEmail]?, publicEmail: String?, userID: Int, login: String, noreply: Bool) -> [String] {
        var found = (listed ?? []).filter { $0.verified != false }.sorted { ($0.primary == true ? 0 : 1) < ($1.primary == true ? 0 : 1) }.map(\.email)
        if let publicEmail, !publicEmail.isEmpty { found.insert(publicEmail, at: 0) }
        if noreply, publicEmail?.isEmpty != false { found.append("\(userID)+\(login)@users.noreply.github.com") }
        return unique(found)
    }

    /// The commit email first, then the account's and the public one
    static func gitLabEmails(commit: String?, email: String?, publicEmail: String?) -> [String] {
        unique([commit, email, publicEmail].compactMap { $0 })
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") && seen.insert($0.lowercased()).inserted }
    }

    /// The folder rule's default: the parent folder of an open repository whose remote is on this server, never the
    /// home folder, the Desktop or the root. Nil when no such repository is open.
    static func defaultFolder(repositories: [(path: String, host: String?)], host: String, home: String) -> String? {
        let home = (home as NSString).standardizingPath
        let refused: Set<String> = ["/", "", home, (home as NSString).appendingPathComponent("Desktop")]
        for repo in repositories where repo.host?.lowercased() == host.lowercased() {
            let parent = ((repo.path as NSString).standardizingPath as NSString).deletingLastPathComponent
            if !refused.contains(parent) { return parent }
        }
        return nil
    }

    /// The account's email choices, read with its token
    static func emails(for account: HostAccount, token: String) async throws -> [String] {
        switch account.provider {
        case .github:
            struct User: Decodable { let id: Int; let login: String; let email: String? }
            let user = try await Hosting.send(User.self, Hosting.request(.github, account.apiBase + "/user", token: token))
            // listing the emails needs the user:email scope; without it only the public one is known
            let listed = try? await Hosting.send([GitHubEmail].self, Hosting.request(.github, account.apiBase + "/user/emails", token: token))
            return gitHubEmails(listed: listed, publicEmail: user.email, userID: user.id, login: user.login, noreply: account.host == "github.com")
        case .gitlab:
            struct User: Decodable { let commitEmail: String?; let email: String?; let publicEmail: String? }
            let user = try await Hosting.send(User.self, Hosting.request(.gitlab, account.apiBase + "/user", token: token))
            return gitLabEmails(commit: user.commitEmail, email: user.email, publicEmail: user.publicEmail)
        }
    }

    /// Adds the public key to the account with its token: true when added, false when it was there already. A token
    /// without the scope for it (GitHub write:public_key, GitLab api) throws MissingScope.
    static func registerKey(_ account: HostAccount, token: String, publicKey: String, title: String) async throws -> Bool {
        guard let key = GitHubSSHRegistration.canonical(publicKey) else {
            throw Gitch.Failure(message: String(localized: "Couldn't read a valid SSH public key. Refresh the key details and retry."))
        }
        let p = account.provider
        let missing = MissingScope(message: p == .github
            ? String(localized: "The saved GitHub token can't add SSH keys (it needs the write:public_key scope). Copy the public key below and add it in GitHub's SSH key settings.")
            : String(localized: "The saved GitLab token can't add SSH keys (it needs the api scope). Copy the public key below and add it in GitLab's SSH key settings."))
        func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
            do { return try await Hosting.data(Hosting.request(p, account.apiBase + path, token: token, method: method, body: body)) }
            catch let e as HostingError where [401, 403, 404].contains(e.status) { throw missing }
        }
        struct Listed: Decodable { let key: String }
        for page in 1...10 {
            let keys = try JSONDecoder().decode([Listed].self, from: await send("/user/keys?per_page=100&page=\(page)"))
            if keys.contains(where: { GitHubSSHRegistration.canonical($0.key) == key }) { return false }
            if keys.count < 100 { break }
        }
        _ = try await send("/user/keys", method: "POST", body: ["title": title, "key": key])
        return true
    }
}
