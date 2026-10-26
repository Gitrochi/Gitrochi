import SwiftUI
import AppKit

/// 사용자 승인 흐름과 계정 가져오기를 분리하고 코드 발급 전에도 복구 동작을 제공한다.
struct GitHubBrowserLoginSheet: View {
    var expectedLogin: String? = nil
    var capability: Gitch.GitHubLoginCapability = .standard
    let onConnected: (Gitch.BrowserLogin, HostAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var login: Gitch.BrowserLogin?
    @ViewState private var working = false
    @ViewState private var error: String?
    @ViewState private var task: Task<Void, Never>?
    @ViewState private var openedBrowser = false
    @ViewState private var copied = false
    @ViewState private var generation = 0
    @ViewState private var closed = false
    @ViewState private var importing = false
    private let tools = ToolStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(capability == .projects ? String(localized: "Connect GitHub project access") : String(localized: "Sign in to GitHub")).font(.title2.weight(.semibold))
            Text("GitHub opens in your default browser. Approve the login there, then return here. Gitrochi imports the approved account without showing its token.")
                .font(.callout).foregroundStyle(.secondary)
            if capability == .projects {
                Text("GitHub Projects needs the additional project permission to list projects and update their status. Review it in your browser before approving.")
                    .font(.callout).foregroundStyle(.secondary)
                if let expectedLogin { Text("Approve access with the selected account: @\(expectedLogin)").font(.callout.weight(.medium)) }
            }
            if tools.path(.gh) == nil {
                Text("GitHub CLI is needed for secure browser sign-in. Install it from its official site, then check again.")
                HStack {
                    Button("Get GitHub CLI") { NSWorkspace.shared.open(URL(string: "https://cli.github.com")!) }
                    Button("Check again") { tools.detect(.gh) }
                }
            } else if let login {
                if let code = login.deviceCode, !code.isEmpty, login.state == .pending {
                    Text("Enter this code on GitHub").font(.headline)
                    HStack {
                        Text(verbatim: code).font(.title.monospaced()).textSelection(.enabled)
                        Button(copied ? String(localized: "Copied") : String(localized: "Copy code")) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string); copied = true
                        }
                        Button("Open browser") { openBrowser(login) }
                    }
                }
                if login.state == .pending {
                    pendingProgress(login)
                    if login.deviceCode?.isEmpty != false {
                        Button("Open browser") { openBrowser(login) }
                        Text("The sign-in code will appear here when GitHub is ready. Opening the page alone doesn't approve access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if working { ProgressView().controlSize(.small) }
                    if importing { Text("Connecting the approved account…").font(.callout).foregroundStyle(.secondary) }
                    Text(verbatim: login.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if login.state == .complete, error != nil {
                    Button("Retry connecting account") {
                        let attempt = generation
                        task = Task { await connect(login, attempt: attempt) }
                    }.disabled(working)
                    Button("Try signing in again") { begin() }.disabled(working)
                } else if !working, login.state != .complete {
                    Button("Try signing in again") { begin() }
                }
            } else {
                if capability == .standard {
                    Text("GitHub will request access for repositories, pull requests, workflows and SSH public keys. You can review the permissions in the browser before approving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(capability == .projects ? String(localized: "Continue to approve project access") : String(localized: "Continue to GitHub")) { begin() }.buttonStyle(.borderedProminent).disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(importing)
            }
        }
        .padding(24).frame(width: 590, height: capability == .projects ? 560 : 480)
        .interactiveDismissDisabled(working)
        .onDisappear { invalidate() }
    }

    private func begin() {
        let previous = login
        task?.cancel(); generation += 1; closed = false
        let attempt = generation
        error = nil; working = true; importing = false; login = nil; openedBrowser = false; copied = false
        task = Task {
            do {
                if let previous, previous.state == .pending { _ = try? await Gitch.gitHubLogin(previous.session, cancel: true) }
                guard active(attempt) else { return }
                var timing = GitHubLoginProgress()
                var next = try await Gitch.startGitHubLogin(capability: capability, expectedLogin: expectedLogin)
                guard active(attempt) else {
                    let abandonedSession = next.session
                    Task { _ = try? await Gitch.gitHubLogin(abandonedSession, cancel: true) }
                    return
                }
                login = next; openWhenReady(next)
                while next.state == .pending {
                    if let failure = timing.failure(phase: GitHubLoginProgress.phase(next.phase, code: next.deviceCode)) {
                        throw Gitch.Failure(message: failure.message)
                    }
                    try await Task.sleep(for: .milliseconds(1500))
                    next = try await Gitch.gitHubLogin(next.session)
                    guard active(attempt) else { return }
                    login = next; openWhenReady(next)
                }
                if next.state == .complete { await connect(next, attempt: attempt) }
                else { working = false }
            } catch is CancellationError { if active(attempt) { working = false } }
            catch {
                guard active(attempt) else { return }
                self.error = error.localizedDescription; working = false; tools.detect(.gh)
            }
        }
    }

    private func connect(_ state: Gitch.BrowserLogin, attempt: Int) async {
        guard active(attempt) else { return }
        working = true; importing = true; error = nil
        defer { if generation == attempt { working = false; importing = false } }
        do {
            guard let name = state.login, !name.isEmpty else {
                throw Gitch.Failure(message: String(localized: "GitHub didn't return an account name. Sign in again."))
            }
            let account = try await GitHubLoginIdentity.connect(login: name, expected: expectedLogin) {
                try await AccountStore.shared.importGitHubCLI(expectedLogin: $0)
            }
            guard active(attempt) else { return }
            onConnected(state, account)
            dismiss()
        } catch is CancellationError {} catch {
            guard active(attempt) else { return }
            self.error = AccountConnectionFailure.message(for: error)
        }
    }

    private func openWhenReady(_ state: Gitch.BrowserLogin) {
        guard !openedBrowser, state.state == .pending, state.deviceCode?.isEmpty == false else { return }
        openBrowser(state); openedBrowser = true
    }

    private func openBrowser(_ state: Gitch.BrowserLogin) {
        guard state.verificationURL == "https://github.com/login/device", let url = URL(string: state.verificationURL) else { return }
        if !NSWorkspace.shared.open(url) {
            error = String(localized: "Couldn't open your browser. Open https://github.com/login/device and enter the code shown here.")
        }
    }

    @ViewBuilder private func pendingProgress(_ state: Gitch.BrowserLogin) -> some View {
        HStack(spacing: 10) {
            if working { ProgressView().controlSize(.small) }
            switch GitHubLoginProgress.phase(state.phase, code: state.deviceCode) {
            case .queued: Text("Another GitHub sign-in is in progress. Waiting for it to finish…")
            case .preparing: Text("Getting a sign-in code from GitHub…")
            case .approval: Text("Enter the code in your browser, approve access, then return here.")
            }
        }.font(.callout).foregroundStyle(.secondary)
    }

    private func cancel() {
        guard !importing else { return }
        invalidate()
        dismiss()
    }

    private func invalidate() {
        closed = true; generation += 1; task?.cancel()
        if let login, login.state == .pending {
            Task { _ = try? await Gitch.gitHubLogin(login.session, cancel: true) }
        }
        login = nil
    }

    private func active(_ attempt: Int) -> Bool {
        generation == attempt && !closed && !Task.isCancelled
    }
}
