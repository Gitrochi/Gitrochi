import SwiftUI
import AppKit

struct AccountsSettings: View {
    private let accounts = AccountStore.shared
    @ViewState private var githubToken = ""
    @ViewState private var gitlabServer = ""
    @ViewState private var gitlabToken = ""
    @ViewState private var working: Provider?
    @ViewState private var error: String?
    @ViewState private var showBrowserLogin = false

    var body: some View {
        Form {
            Section {
                Button("Sign in to GitHub in browser…") { showBrowserLogin = true }.disabled(working != nil)
                ForEach(accounts.accounts(for: .github)) { a in
                    ConnectedRow(account: a) { accounts.disconnect(a) }
                }
                SecureField("Personal access token", text: $githubToken, prompt: Text(accounts.accounts(for: .github).isEmpty ? "ghp_… token" : "Another account's token"))
                HStack {
                    Button(accounts.accounts(for: .github).isEmpty ? "Connect" : "Add account") { connectGitHub() }
                        .disabled(githubToken.trimmed.isEmpty || working != nil)
                    if accounts.ghPath != nil {
                        Button("Import gh CLI login") { importGH() }
                            .disabled(working != nil)
                    }
                    if working == .github { ProgressView().controlSize(.small) }
                    Spacer()
                    Link("Create token", destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org,workflow&description=Gitrochi")!)
                }
            } header: {
                Text("GitHub \(countText(.github))")
            } footer: {
                Text("If you connect several accounts, choose the one a repository uses from the account button at the right end of the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(accounts.accounts(for: .gitlab)) { a in
                    ConnectedRow(account: a, showServer: true) { accounts.disconnect(a) }
                }
                TextField("Server address", text: $gitlabServer, prompt: Text("https://gitlab.example.com"))
                SecureField("Personal access token (api scope)", text: $gitlabToken)
                HStack {
                    Button(accounts.accounts(for: .gitlab).isEmpty ? "Connect" : "Add account") { connectGitLab() }
                        .disabled(gitlabServer.trimmed.isEmpty || gitlabToken.trimmed.isEmpty || working != nil)
                    if working == .gitlab { ProgressView().controlSize(.small) }
                    Spacer()
                    if !gitlabServer.trimmed.isEmpty,
                       let u = URL(string: AccountStore.normalizeServer(gitlabServer) + "/-/user_settings/personal_access_tokens?name=Gitrochi&scopes=api") {
                        Link("Create token", destination: u)
                    }
                }
            } header: {
                Text("Self-hosted GitLab \(countText(.gitlab))")
            } footer: {
                Text("Only GitLab servers run by your organization can be connected (gitlab.com isn't supported yet). You can connect several accounts per server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            Section("Commit graph") {
                Toggle("Show author profile pictures", isOn: Binding(get: { AvatarStore.shared.enabled }, set: { AvatarStore.shared.enabled = $0 }))
                HStack {
                    Text("Looks for a GitHub profile, then a connected self-hosted GitLab profile, then Gravatar, and uses initials if none is found. An email hash is sent to Gravatar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Download again") { AvatarStore.shared.refresh() }.controlSize(.small)
                }
            }

            Section {
                Text("Tokens are stored per account in the macOS Keychain and used to view and create PRs/MRs, list repositories, and authenticate HTTPS push and pull.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showBrowserLogin) { GitHubBrowserLoginSheet { _, _ in } }
        .onAppear {
            if gitlabServer.isEmpty { gitlabServer = accounts.suggestedGitLabServer }
        }
    }

    private func countText(_ p: Provider) -> String {
        let n = accounts.accounts(for: p).count
        return n == 0 ? "" : String(localized: "· \(n)")
    }

    private func connectGitHub() {
        run(.github) {
            try await accounts.connectGitHub(token: githubToken)
            githubToken = ""
        }
    }

    private func connectGitLab() {
        run(.gitlab) {
            try await accounts.connectGitLab(server: gitlabServer, token: gitlabToken)
            gitlabToken = ""
        }
    }

    private func importGH() {
        run(.github) { try await accounts.importGitHubCLI() }
    }

    private func run(_ p: Provider, _ work: @escaping @MainActor () async throws -> Void) {
        working = p
        error = nil
        Task {
            do { try await work() } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = nil
        }
    }
}

private struct ConnectedRow: View {
    let account: HostAccount
    var showServer = false
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: account.avatarURL.flatMap(URL.init(string:))) { image in
                image.resizable()
            } placeholder: {
                Avatar(name: account.name ?? account.username, email: account.username, size: 30)
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name ?? account.username).fontWeight(.medium)
                Text("@\(account.username)" + (showServer ? " · \(account.host)" : "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Button("Disconnect", action: disconnect)
        }
    }
}
