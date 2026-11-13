import SwiftUI
import AppKit

/// The one way to add a hosting account, opened from the account popover and from Settings › Accounts, as the Settings
/// board draws it: the GitHub | GitLab switch at the header's right; GitHub in the browser (or with a token, or the gh
/// command's login), or a self-hosted GitLab server with a token.
/// (Windows: features/account-connection/ui/AddAccountSheet.tsx)
struct AddAccountSheet: View {
    var provider: Provider = .github
    /// A GitLab server to start from, such as the open repository's
    var server: String? = nil
    /// The browser sign-in is its own sheet: the owner shows it in place of this one
    let signInWithBrowser: () -> Void
    var onConnected: (HostAccount) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    private let accounts = AccountStore.shared
    @ViewState private var chosen: Provider?
    @ViewState private var useToken = false
    @ViewState private var githubToken = ""
    @ViewState private var gitlabServer = ""
    @ViewState private var gitlabToken = ""
    @ViewState private var working = false
    @ViewState private var error: String?

    private var current: Provider { chosen ?? provider }

    private var primary: SheetPrimary {
        if current == .gitlab {
            let ready = !gitlabServer.trimmed.isEmpty && !gitlabToken.trimmed.isEmpty
            return SheetPrimary(title: String(localized: "Connect"), disabledReason: ready ? nil : String(localized: "Enter the server URL and a token first"),
                                busy: working, identifier: "add-account-primary") {
                run { try await accounts.connectGitLab(server: gitlabServer, token: gitlabToken) }
            }
        }
        if useToken {
            return SheetPrimary(title: String(localized: "Connect"), disabledReason: githubToken.trimmed.isEmpty ? String(localized: "Enter a token first") : nil,
                                busy: working, identifier: "add-account-primary") {
                run { try await accounts.connectGitHub(token: githubToken) }
            }
        }
        return SheetPrimary(title: String(localized: "Sign in with the browser…"), disabled: working, identifier: "add-account-primary", run: signInWithBrowser)
    }

    var body: some View {
        SharedSheet(title: String(localized: "Add account"), context: String(localized: "Pull requests, issues and CI use this account."), width: 600,
                    cancelDisabled: working, primary: primary, accessory: AnyView(switcher), cancel: { dismiss() }) {
            VStack(alignment: .leading, spacing: 12) {
                if current == .github { github } else { gitlab }
                if let error {
                    NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: String(localized: "Couldn't add the account"), caption: error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        }
        .interactiveDismissDisabled(working)
        .onAppear {
            if gitlabServer.isEmpty { gitlabServer = server ?? accounts.suggestedGitLabServer }
        }
    }

    private var switcher: some View {
        Picker("Provider", selection: Binding(get: { current }, set: { chosen = $0; error = nil })) {
            Text(verbatim: "GitHub").tag(Provider.github)
            Text("GitLab (self-hosted)").tag(Provider.gitlab)
        }
        // small, so the title and its context line keep the rest of the header; never narrower than its words
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        .accessibilityIdentifier("add-account-provider")
    }

    @ViewBuilder private var github: some View {
        Text("github.com opens in your browser to approve access. The token is kept in the Keychain.")
            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 4) {
            Button { useToken.toggle(); error = nil } label: {
                HStack(spacing: 4) {
                    DesignIconImage(icon: useToken ? .chevronDown : .chevronRight, size: 12)
                    Text("Use a token instead").font(.system(size: 12))
                }
                .foregroundStyle(HostedList.caption).frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(useToken ? .isSelected : [])
            if useToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal access token").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    SecureField("Personal access token", text: $githubToken, prompt: Text(verbatim: "ghp_…")).labelsHidden().textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Create token") { NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org,workflow&description=Gitrochi")!) }
                        .buttonStyle(HostedListTextButtonStyle())
                }
                .padding(.bottom, 4)
            }
            if accounts.ghPath != nil {
                // the caption drops below the button in a narrow sheet rather than squeezing beside it
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { importButton; importCaption }
                    VStack(alignment: .leading, spacing: 0) { importButton; importCaption }
                }
            }
        }
    }

    private var importButton: some View {
        Button("Import gh CLI login") { run { try await accounts.importGitHubCLI() } }
            .buttonStyle(HostedListTextButtonStyle()).disabled(working)
            .accessibilityIdentifier("add-account-import")
    }

    private var importCaption: some View {
        Text("Uses the account the gh command is signed in to.").font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize()
    }

    @ViewBuilder private var gitlab: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server URL").font(.system(size: 12)).foregroundStyle(HostedList.caption)
            TextField("Server URL", text: $gitlabServer, prompt: Text(verbatim: "https://gitlab.example.com")).labelsHidden().textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal access token (api scope)").font(.system(size: 12)).foregroundStyle(HostedList.caption)
            SecureField("Personal access token (api scope)", text: $gitlabToken, prompt: Text(verbatim: "glpat-…")).labelsHidden().textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            if !gitlabServer.trimmed.isEmpty,
               let url = URL(string: AccountStore.normalizeServer(gitlabServer) + "/-/user_settings/personal_access_tokens?name=Gitrochi&scopes=api") {
                Button("Create token") { NSWorkspace.shared.open(url) }.buttonStyle(HostedListTextButtonStyle())
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> HostAccount) {
        guard !working else { return }
        working = true; error = nil
        Task {
            do {
                let account = try await work()
                working = false
                onConnected(account)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                working = false
            }
        }
    }
}
