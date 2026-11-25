import SwiftUI
import AppKit

/// Native account setup; every write has a separate user action and the CLI owns all configuration. Started from a
/// saved hosting account (or filled in from one), it fills the details from that account's token and one action saves
/// the account, creates the key, registers it with the token and checks the connection (GitchConnect).
struct GitchAccountSetupSheet: View {
    let accountID: String?
    /// The saved hosting account to connect
    var hosting: HostAccount? = nil
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var id = ""
    @ViewState private var email = ""
    @ViewState private var host = "github.com"
    @ViewState private var port = "22"
    @ViewState private var useFolder = false
    @ViewState private var folder = ""
    @ViewState private var via = ""
    @ViewState private var accounts: [Gitch.Account] = []
    @ViewState private var setup: Gitch.AccountSetup?
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var confirmAdd = false
    @ViewState private var confirmKey = false
    @ViewState private var confirmAlias = false
    @ViewState private var copied = false
    @ViewState private var showPortHelp = false
    @ViewState private var showBrowserLogin = false
    @ViewState private var confirmRegistration = false
    @ViewState private var registrationResult: String?
    /// The saved hosting account the details came from; its token registers the key
    @ViewState private var source: HostAccount?
    @ViewState private var emailChoices: [String] = []
    /// Why the key has to be copied by hand (the token lacks the scope)
    @ViewState private var keyNote: String?
    @ViewState private var confirmConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(source != nil && setup == nil ? String(localized: "Connect to gitch") : accountID == nil ? String(localized: "Add Git account") : String(localized: "Connect with SSH")).font(.title2.weight(.semibold)).padding(20)
            Form {
                if let setup { keySteps(setup) } else if let source, accountID == nil { connectForm(source) } else if accountID == nil { accountForm }
                else if !busy { Button("Reload account") { Task { await refreshKey() } } }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
                Spacer()
                Button(setup == nil ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if setup == nil && accountID == nil && source != nil {
                    Button("Connect to gitch") { confirmConnect = true }.buttonStyle(.borderedProminent).disabled(!valid || busy)
                } else if setup == nil && accountID == nil {
                    Button("Save account") { confirmAdd = true }.buttonStyle(.borderedProminent).disabled(!valid || busy)
                }
            }.padding(20)
        }
        .frame(width: 660, height: 650)
        .interactiveDismissDisabled(busy)
        .task(id: accountID) {
            accounts = await Gitch.accounts()
            if let hosting { await fill(from: hosting) }
            if let accountID { await perform { setup = try await Gitch.setupAccount(accountID, action: .inspect) } }
        }
        .sheet(isPresented: $showBrowserLogin) { GitHubBrowserLoginSheet(expectedLogin: setup?.id ?? accountID, onConnected: connectedGitHub) }
        .alert("Save this Git account?", isPresented: $confirmAdd) {
            Button("Cancel", role: .cancel) {}
            Button("Save account") { Task { await save() } }
        } message: {
            Text("Saves this account and the optional folder rule in gitch. SSH keys and SSH connection settings are prepared separately in the next step.")
        }
        .alert("Connect this account to gitch?", isPresented: $confirmConnect) {
            Button("Cancel", role: .cancel) {}
            Button("Connect to gitch") { Task { await connect() } }
        } message: {
            Text("Saves this account and the folder rule in gitch, creates an SSH key on this Mac if there is none, registers its public key with \(source?.host ?? host) using the saved sign-in, and checks the connection. The token and the private key are not stored in gitch.")
        }
        .alert("Create an SSH key?", isPresented: $confirmKey) {
            Button("Cancel", role: .cancel) {}
            Button("Create key") { Task { await generate() } }
        } message: {
            Text("Creates an unencrypted Ed25519 key on this Mac and prepares its SSH connection in ~/.ssh/config, backing up existing settings first. Existing keys are preserved. To add a passphrase, choose Set up in Terminal instead.")
        }
        .alert("Register this public key with GitHub?", isPresented: $confirmRegistration) {
            Button("Cancel", role: .cancel) {}
            Button("Register public key") { Task { await registerKey() } }
        } message: {
            Text("Only the public key is sent to the matching GitHub account. Your private key stays on this Mac. Gitrochi checks the SSH connection after registration.")
        }
        .alert("Set up the SSH connection for this key?", isPresented: $confirmAlias) {
            Button("Cancel", role: .cancel) {}
            Button("Set up connection") { Task { await generate() } }
        } message: {
            Text("Adds or updates this account's SSH host alias in ~/.ssh/config after making a backup. Your existing SSH key is preserved.")
        }
    }

    private var accountForm: some View {
        Group {
            if !AccountStore.shared.accounts.isEmpty {
                Section {
                    Menu("Fill in from a saved account") {
                        ForEach(AccountStore.shared.accounts) { account in
                            Button { Task { await fill(from: account) } } label: { Text(verbatim: "@" + account.username + " · " + account.host) }
                        }
                    }
                    .disabled(busy)
                    Text("Uses the account's saved sign-in for the name, email and server, and to register the SSH key.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Sign in to GitHub in browser…") { showBrowserLogin = true }
                Text("Browser sign-in fills in your GitHub account and connects pull request features. Review your commit email and choose Save account to continue.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("For self-hosted GitLab, enter your details below. Browser login requires an OAuth app registered by your server administrator; use the existing token settings and SSH guide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Use the name and email you use for commits. The SSH key connects this Mac to GitHub or GitLab.").font(.callout).foregroundStyle(.secondary)
                TextField("Account name", text: $id, prompt: Text("my-github"))
                TextField("Commit email", text: $email, prompt: Text("you@example.com"))
                TextField("Git server", text: $host, prompt: Text("github.com or gitlab.example.com"))
                LabeledContent("SSH port") {
                    HStack(spacing: 4) {
                        TextField("SSH port", text: $port).labelsHidden().accessibilityLabel("SSH port")
                        Button { showPortHelp.toggle() } label: { SymbolIcon("questionmark.circle") }
                            .buttonStyle(.borderless)
                            .help(portHelp)
                            .accessibilityLabel("About SSH ports")
                            .accessibilityHint(portHelp)
                            .popover(isPresented: $showPortHelp) {
                                Text(portHelp).font(.callout).padding().frame(width: 300)
                            }
                    }
                }
            } header: { Text("1. Account") }
            Section {
                Toggle("Choose this account automatically in a folder", isOn: $useFolder)
                if useFolder {
                    HStack {
                        Text(folder.isEmpty ? String(localized: "No folder selected") : folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose folder…") { chooseFolder() }
                    }
                }
                if !accounts.isEmpty {
                    Picker("SSH jump account (optional)", selection: $via) {
                        Text("None").tag("")
                        ForEach(accounts) { account in Text(verbatim: account.id).tag(account.id) }
                    }
                }
            } header: { Text("Optional settings") }
        }
    }

    /// The details filled in from the saved account; the email is asked only when there is more than one
    private func connectForm(_ account: HostAccount) -> some View {
        Group {
            Section {
                Label("@" + account.username, symbol: "person.crop.circle").font(.headline)
                TextField("Account name", text: $id)
                if emailChoices.count > 1 {
                    Picker("Commit email", selection: $email) {
                        ForEach(emailChoices, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                } else {
                    TextField("Commit email", text: $email, prompt: Text("you@example.com"))
                }
                LabeledContent("Git server") { Text(verbatim: host) }
                LabeledContent("SSH port") {
                    TextField("SSH port", text: $port).labelsHidden().accessibilityLabel("SSH port").help(portHelp)
                }
            } header: { Text("1. Account") }
            Section {
                Toggle("Choose this account automatically in a folder", isOn: $useFolder)
                if useFolder {
                    HStack {
                        Text(folder.isEmpty ? String(localized: "No folder selected") : folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose folder…") { chooseFolder() }
                    }
                }
                Text("Defaults to the folder that holds an open repository from this server.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Folder") }
        }
    }

    private func keySteps(_ state: Gitch.AccountSetup) -> some View {
        Group {
            Section {
                Label(state.id, symbol: "person.crop.circle.badge.checkmark").font(.headline)
                Text(state.email + " · " + state.host + ":" + String(state.port)).foregroundStyle(.secondary)
            } header: { Text("1. Account saved") }
            Section {
                if state.keyExists {
                    Label("SSH key found", symbol: "checkmark.circle.fill").foregroundStyle(.green)
                    if state.aliasConfigured == false {
                        Button("Set up connection for existing key…") { confirmAlias = true }.disabled(busy)
                    }
                    if state.keyProtection == "none" { Text("This key has no passphrase. Keep the private key on this Mac.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("An SSH key lets this Mac connect without a Git password. Only the public key is shared with your Git server.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Create SSH key…") { confirmKey = true }.disabled(busy)
                        Button("Set up in Terminal…") { openTerminal(["setup", state.id]) }.disabled(busy)
                    }
                }
                Button("Refresh key details") { Task { await refreshKey() } }.disabled(busy)
            } header: { Text("2. SSH key") }
            if !state.publicKey.isEmpty {
                Section {
                    Text("Copy this public key, open your server's settings, and add it to your account.").font(.callout).foregroundStyle(.secondary)
                    Text(verbatim: state.publicKey).font(.caption.monospaced()).textSelection(.enabled).lineLimit(5)
                    HStack {
                        Button(copied ? String(localized: "Copied") : String(localized: "Copy public key")) { copyKey(state.publicKey) }
                        Button("Open SSH key settings") { openRegistration(state.registrationURL) }
                    }
                    if let keyNote {
                        Label(keyNote, symbol: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    }
                    if let source, source.host == state.host.lowercased() {
                        Button("Register key with \(source.host)…") { Task { await registerHosted(source) } }.disabled(busy)
                    } else if state.host.lowercased() == "github.com" {
                        if AccountStore.shared.accounts(for: .github).contains(where: { $0.username.caseInsensitiveCompare(state.id) == .orderedSame }) {
                            Button("Register key with GitHub…") { confirmRegistration = true }.disabled(busy)
                        } else {
                            Button("Sign in to GitHub to register key…") { showBrowserLogin = true }.disabled(busy)
                        }
                    }
                    if let registrationResult { Text(registrationResult).font(.caption).foregroundStyle(.green) }
                } header: { Text("3. Register public key") }
            }
            Section {
                Button("Check SSH connection") { Task { await check() } }.disabled(busy || !state.keyExists)
                if let authenticated = state.authenticated {
                    Label(authenticated ? String(localized: "SSH connection verified") : String(localized: "SSH connection needs attention"), symbol: authenticated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(authenticated ? .green : .orange)
                    if authenticated {
                        Text("Your account is ready. Choose Done, then open or clone a repository in Gitrochi.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !state.message.isEmpty { Text(verbatim: state.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: { Text("4. Verify connection") }
        }
    }

    private var valid: Bool {
        let name = id.trimmed, address = email.trimmed, server = host.trimmed
        return name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
            && address.split(separator: "@").count == 2 && !address.contains(where: \.isWhitespace)
            && !server.isEmpty && !server.contains(where: \.isWhitespace)
            && (Int(port).map { (1...65535).contains($0) } ?? false) && (!useFolder || !folder.isEmpty)
    }

    private var portHelp: String {
        String(localized: "Usually leave this at 22. If your company or self-hosted Git server uses another number, enter the SSH port given by its administrator, such as 2222. This is for SSH connections, not the port in a website address.")
    }

    @MainActor private func perform(_ action: () async throws -> Void) async {
        busy = true; error = nil
        defer { busy = false }
        do { try await action() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func save() async {
        await perform {
            setup = try await Gitch.addAccount(id: id.trimmed, email: email.trimmed, host: host.trimmed, port: Int(port) ?? 22, folder: useFolder ? folder : nil, via: via.isEmpty ? nil : via)
            onChanged()
        }
    }

    private func generate() async {
        guard let setup else { return }
        await perform { self.setup = try await Gitch.setupAccount(setup.id, action: .generate); onChanged() }
    }

    private func check() async {
        guard let setup else { return }
        await perform { self.setup = try await Gitch.setupAccount(setup.id, action: .check); onChanged() }
    }

    private func refreshKey() async {
        guard let name = setup?.id ?? accountID else { return }
        await perform { setup = try await Gitch.setupAccount(name, action: .inspect); copied = false }
    }

    private func connectedGitHub(_ login: Gitch.BrowserLogin, _ account: HostAccount) {
        if let setup {
            guard setup.host.lowercased() == "github.com", setup.id.caseInsensitiveCompare(account.username) == .orderedSame else {
                error = String(localized: "The signed-in GitHub account doesn't match this account. Sign in with the intended account.")
                return
            }
            if setup.keyExists { Task { await check() } }
            return
        }
        id = account.username; email = login.email ?? ""; host = "github.com"; port = "22"
        Task {
            accounts = await Gitch.accounts()
            if let savedAccount = accounts.first(where: { $0.id.caseInsensitiveCompare(account.username) == .orderedSame }) {
                await perform {
                    var existing = try await Gitch.setupAccount(savedAccount.id, action: .inspect)
                    guard existing.host.lowercased() == "github.com" else {
                        throw Gitch.Failure(message: String(localized: "This account name is already used for another Git server. Review the account details before saving."))
                    }
                    if existing.keyExists { existing = try await Gitch.setupAccount(existing.id, action: .check) }
                    setup = existing; onChanged()
                }
            }
        }
    }

    /// Fills the form from a saved hosting account's token: name, server, email choices and the folder rule's default
    private func fill(from account: HostAccount) async {
        await perform {
            guard let token = AccountStore.shared.token(for: account) else {
                throw Gitch.Failure(message: String(localized: "Gitrochi can't read this account's saved sign-in. Restore it in Settings › Accounts and try again."))
            }
            let found = try await GitchConnect.emails(for: account, token: token)
            source = account
            id = GitchConnect.accountName(login: account.username, host: account.host, taken: accounts)
            host = account.host; port = "22"
            emailChoices = found; email = found.first ?? ""
            let open = Workspace.shared.openRepositories.compactMap { store in store.url.map { (path: $0.path, host: store.target?.host) } }
            let parent = GitchConnect.defaultFolder(repositories: open, host: account.host, home: NSHomeDirectory())
            useFolder = parent != nil; folder = parent ?? ""
        }
    }

    /// Saves (or reuses) the gitch account, creates its key when missing, registers it with the saved token and checks
    /// the connection; a token without the scope leaves the copy-the-key step with the reason
    private func connect() async {
        guard let source else { return }
        await perform {
            var state: Gitch.AccountSetup
            if let existing = GitchConnect.existing(name: id.trimmed, host: host.trimmed, in: accounts) {
                state = try await Gitch.setupAccount(existing.id, action: .inspect)
            } else {
                state = try await Gitch.addAccount(id: id.trimmed, email: email.trimmed, host: host.trimmed, port: Int(port) ?? 22, folder: useFolder ? folder : nil, via: nil)
            }
            setup = state; onChanged()
            if !state.keyExists || state.aliasConfigured == false {
                state = try await Gitch.setupAccount(state.id, action: .generate)
                setup = state; onChanged()
            }
            try await register(state, with: source)
        }
    }

    private func registerHosted(_ account: HostAccount) async {
        guard let setup else { return }
        await perform { try await register(setup, with: account) }
    }

    private func register(_ state: Gitch.AccountSetup, with account: HostAccount) async throws {
        guard let token = AccountStore.shared.token(for: account) else {
            throw Gitch.Failure(message: String(localized: "Gitrochi can't read this account's saved sign-in. Restore it in Settings › Accounts and try again."))
        }
        do {
            let created = try await GitchConnect.registerKey(account, token: token, publicKey: state.publicKey, title: "Gitrochi (\(state.id))")
            keyNote = nil
            registrationResult = created ? String(localized: "Public key registered with \(account.host).") : String(localized: "This public key is already registered with \(account.host).")
        } catch let missing as GitchConnect.MissingScope {
            keyNote = missing.message
            return
        }
        setup = try await Gitch.setupAccount(state.id, action: .check)
        onChanged()
    }

    private func registerKey() async {
        guard let setup else { return }
        await perform {
            let created = try await AccountStore.shared.registerGitHubSSHKey(setup)
            registrationResult = created ? String(localized: "Public key registered with GitHub.") : String(localized: "This public key is already registered with GitHub.")
            self.setup = try await Gitch.setupAccount(setup.id, action: .check)
            onChanged()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func copyKey(_ key: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string); copied = true
    }

    private func openRegistration(_ raw: String) {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTerminal(_ args: [String]) {
        do { try Gitch.openInTerminal(args) } catch { self.error = error.localizedDescription }
    }
}
