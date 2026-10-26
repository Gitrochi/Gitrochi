import SwiftUI
import AppKit

/// A permanent, optional entry point for people who have never used the bundled CLI.
struct GitchGuideSheet: View {
    let repo: RepoStore?
    var checkOnOpen = false
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var accounts: [Gitch.Account] = []
    @ViewState private var addAccount = false
    @ViewState private var selectedAccount = ""
    @ViewState private var connectAccount: String?
    @ViewState private var showingSSH = false
    @ViewState private var confirmInstall = false
    @ViewState private var busy = false
    @ViewState private var result: String?
    @ViewState private var error: String?
    @ViewState private var doctor: Gitch.Doctor?
    @ViewState private var commandHelp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(embedded ? "Tools" : "Get started with Git accounts").font(.title2.weight(.semibold))
                    Text(embedded ? "Run diagnostics, explore code and find commands without opening Settings." : "Set up your account and connection here, then open a repository.").foregroundStyle(.secondary)
                }
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }.padding(20)
            Form {
                Section {
                    Label("gitch is already included in Gitrochi", systemImage: "checkmark.seal.fill").font(.headline)
                    Text("No separate download is needed. Gitrochi can add Git accounts, connect with SSH, check your setup and draw code maps from the app. Terminal commands are optional.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !embedded { accountStep }
                repositoryStep
                if !embedded { terminalStep }
                diagnosticsStep
                if let result { Section { Text(result).font(.caption.monospaced()).textSelection(.enabled) } }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) } }
            }.formStyle(.grouped)
        }
        .frame(minWidth: embedded ? 300 : 740, idealWidth: 740, maxWidth: .infinity, minHeight: embedded ? 300 : 680, idealHeight: 680, maxHeight: .infinity)
        .interactiveDismissDisabled(busy)
        .task(id: checkOnOpen) { await refresh(); if checkOnOpen { await checkSetup() } }
        .sheet(isPresented: $addAccount) { GitchAccountSetupSheet(accountID: nil) { Task { await refresh() } } }
        .sheet(isPresented: $showingSSH) { GitchAccountSetupSheet(accountID: connectAccount) { Task { await refresh() } } }
        .alert("Install gitch?", isPresented: $confirmInstall) {
            Button("Cancel", role: .cancel) {}
            Button("Install") { Task { await install() } }
        } message: {
            Text("This changes files outside Gitrochi, backing them up first:\n• ~/bin/gitch and the old name ~/bin/gitsw: link to the gitch inside Gitrochi\n• ~/.zshrc: adds a gitch block\n• ~/.gitconfig: global hooks that check authors, secrets, big files and force pushes, and rules that pick the account\n• ~/.claude and ~/.codex: rules, skills and a hook for AI agents\nRemove it later with gitch uninstall.")
        }
    }

    private var accountStep: some View {
        Section {
            Text("Add the name and email used for commits. The SSH guide helps you create a key, register its public part with your Git server, and verify the connection.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Add Git account…") { addAccount = true }
                if !accounts.isEmpty {
                    Picker("Account", selection: $selectedAccount) {
                        ForEach(accounts) { account in Text(verbatim: account.id).tag(account.id) }
                    }.labelsHidden().frame(maxWidth: 180)
                    Button("Connect with SSH…") { connectAccount = selectedAccount; showingSSH = true }
                        .disabled(selectedAccount.isEmpty)
                }
            }
            if accounts.isEmpty { Text("No Git accounts added yet").font(.caption).foregroundStyle(.secondary) }
            else { Text("You can add more accounts later from Settings → CLI.").font(.caption).foregroundStyle(.secondary) }
            command("gitch add", "Add a Git identity and choose an optional folder rule.")
            command("gitch setup", "Create or inspect an SSH key and check the connection.")
            Text("These accounts choose your commit identity and SSH connection. For pull requests and server features, connect GitHub or GitLab in Settings → Accounts.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open app settings…") { openSettings() }
        } header: { Text("1. Account and SSH connection") }
    }

    private var repositoryStep: some View {
        Section {
            Text("Open an existing repository or clone one from the welcome screen. Use Changes to stage and commit, and the toolbar to pull or push.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Open repository…") { chooseRepository() }
                Button("Open code map") {
                    guard let repo, repo.url != nil else { return }
                    Task { await repo.openStructureGraph(.files) }
                }.disabled(repo?.url == nil || repo?.graphJob != nil)
                if repo?.url != nil {
                    Button("Show changes") { repo?.select(.wip); dismiss() }
                }
            }
            if repo?.url == nil {
                Text("After opening a repository, choose Repository → Structure graph to see file imports, modules and files that change together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            command("gitch app .", "Open the current repository in Gitrochi.")
            command("gitch ck", "See changed files and branch status.")
            command("gitch g", "Draw imports and dependencies; the app calls this a code map.")
            command("gitch preflight", "Check the account and common problems before committing or pushing.")
        } header: { Text("2. Open a repository and explore") }
    }

    private var terminalStep: some View {
        Section {
            Text("You can use the app without installing a terminal command. Enable it only if you also want to type gitch in Terminal or use it with coding agents.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(Gitch.installedIsBundled ? String(localized: "Reinstall terminal command…") : String(localized: "Enable terminal command…")) { confirmInstall = true }
                    .disabled(accounts.isEmpty || busy || Gitch.bundled == nil)
                if Gitch.installedIsBundled { Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if busy { ProgressView().controlSize(.small) }
            }
            Text("You will see the files and settings it changes before installation. Open a new Terminal window after installing.").font(.caption).foregroundStyle(.secondary)
            command("gitch install", "Enable the terminal command and the account protection hooks.")
        } header: { Text("3. Terminal command (optional)") }
    }

    private var diagnosticsStep: some View {
        Section {
            HStack {
                Button("Check setup") { Task { await checkSetup() } }.disabled(busy)
                Text("Checks your local setup without changing it.").font(.caption).foregroundStyle(.secondary)
            }
            command("gitch doctor", "Explain missing tools, account setup and connection settings.")
            Button("All commands and options") { Task { await readHelp() } }.disabled(busy)
            if let commandHelp {
                ScrollView {
                    Text(verbatim: commandHelp).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 230)
            }
            if let doctor {
                Text(doctor.problems == 0 ? String(localized: "Setup checks passed") : String(localized: "Some setup steps need attention")).font(.headline)
                ForEach(Array(doctor.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.level == "OK" ? "checkmark.circle.fill" : item.level == "INFO" ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.level == "OK" ? Color.green : item.level == "INFO" ? Color.secondary : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.section).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(verbatim: item.message).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: { Text("4. Check your setup") }
    }

    private func command(_ text: String, _ purpose: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: text).font(.caption.monospaced()).frame(width: 112, alignment: .leading).textSelection(.enabled)
            Text(purpose).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy command").accessibilityLabel("Copy command")
        }
    }

    private func refresh() async {
        accounts = await Gitch.accounts()
        if !accounts.contains(where: { $0.id == selectedAccount }) { selectedAccount = accounts.first?.id ?? "" }
    }

    private func install() async {
        busy = true; error = nil
        defer { busy = false }
        do { result = try await Gitch.install().split(separator: "\n").suffix(6).joined(separator: "\n") }
        catch { self.error = error.localizedDescription }
    }

    private func checkSetup() async {
        busy = true; error = nil
        defer { busy = false }
        do { doctor = try await Gitch.doctor() }
        catch { self.error = error.localizedDescription }
    }

    private func readHelp() async {
        busy = true; error = nil
        defer { busy = false }
        do { commandHelp = try await Gitch.commandHelp() }
        catch { self.error = error.localizedDescription }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let repo { Task { await repo.openOrReport(url) }; dismiss() }
        else { openWindow(id: "repo", value: url.path); dismiss() }
    }
}
