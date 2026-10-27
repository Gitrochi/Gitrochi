import SwiftUI

/// 서비스 인증 계정과 Git 작성자·잠금을 한 자리에서 확인하고 사용자 동작으로만 연결한다.
struct AccountQuickControls: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var showing = false
    @ViewState private var sheet: AccountQuickSheet?
    private let accounts = AccountStore.shared

    private var account: HostAccount? { store.hostingAccount }
    /// Without a GitHub/GitLab remote there is no repository account; the control then shows the connected accounts
    private var noTarget: Bool { store.target == nil }
    /// In the order Settings lists them: GitHub first, then GitLab servers
    private var connected: [HostAccount] { accounts.accounts(for: .github) + accounts.accounts(for: .gitlab) }
    private var shown: HostAccount? { noTarget ? connected.first : account }
    private var title: String {
        guard let shown else { return String(localized: "Connect account") }
        return "@" + shown.username + (noTarget && connected.count > 1 ? " +\(connected.count - 1)" : "")
    }
    private var candidates: [HostAccount] { store.target.map { accounts.candidates(for: $0) } ?? [] }
    private var gitAccount: String { store.gitchStatus?.lockedAccount ?? store.gitchStatus?.account ?? store.me?.name ?? String(localized: "Not configured") }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                profile(shown, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 3) {
                        if store.gitchStatus?.lockedAccount != nil { Image(systemName: "lock.fill").font(.system(size: 8)) }
                        Text("Git: \(gitAccount)").font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    }.foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 190, alignment: .leading)
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 30)
            // the whole capsule answers a click, not only the avatar and the text
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Accounts")
        .help("View and manage the repository account and Git identity")
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
        .onChange(of: store.url) { _, _ in showing = false; sheet = nil }
        .task(id: store.url) { if store.url == nil { await store.loadGlobalIdentity() } }
        .sheet(item: $sheet) { request in
            switch request {
            case .connections:
                VStack(spacing: 0) {
                    HStack {
                        Text("Connected accounts").font(.title2.weight(.semibold))
                        Spacer()
                        Button("Done") { sheet = nil }.keyboardShortcut(.cancelAction)
                    }.padding(20)
                    Divider()
                    AccountsSettings()
                }.frame(width: 710, height: 650)
            case .login(let expected, let capability):
                GitHubBrowserLoginSheet(expectedLogin: expected, capability: capability) { _, connected in
                    if candidates.contains(where: { $0.id == connected.id }), account == nil || account?.id == connected.id {
                        store.useAccount(connected)
                    }
                }
            }
        }
    }

    private var popover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if noTarget {
                    connectedList
                } else {
                HStack(spacing: 11) {
                    profile(account, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account?.name ?? account?.username ?? String(localized: "Repository account")).font(.headline).lineLimit(2)
                        if let account {
                            Text("@\(account.username) · \(account.provider.title)").font(.callout)
                            Text(verbatim: account.host).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Connect an account for repository services.").font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account for this repository").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Account for this repository", selection: Binding(get: { account?.id ?? "" }, set: { id in
                            if let next = candidates.first(where: { $0.id == id }) { store.useAccount(next) }
                        })) {
                            ForEach(candidates) { next in Text(verbatim: "@\(next.username) · \(next.host)").tag(next.id) }
                        }.labelsHidden()
                    }
                } else if let target = store.target {
                    Text("Connect an account on \(target.host) to use repository services.").font(.caption).foregroundStyle(.secondary)
                }
                if let account, accounts.credentialState(for: account) != .ready { SavedAccountAccessNotice(account: account) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Git identity").font(.callout.weight(.semibold))
                        Spacer()
                        if store.gitchStatus?.lockedAccount != nil { Label("Locked", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    }
                    accountLine("Git account", value: gitAccount)
                    accountLine("Author", value: store.me?.name ?? String(localized: "Not configured"))
                    accountLine("Email", value: store.me?.email ?? String(localized: "Not configured"))
                    Text("Git author and SSH identity follow this repository's Git account rules.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh account status") { Task { await store.refreshGitch() } }
                        .controlSize(.small).disabled(store.gitchChecking)
                }
                Divider()
                if let account, account.provider == .github, account.host == "github.com" {
                    Button("Renew browser connection…") { present(.login(account.username, .standard)) }
                    Button("Connect GitHub project access") { present(.login(account.username, .projects)) }
                }
                Button("Connect another GitHub account…") { present(.login(nil, .standard)) }
                Button("Add or remove connected accounts…") { present(.connections) }
            }.padding(18).frame(width: 370, alignment: .leading)
        }.frame(maxHeight: 600)
    }

    /// No repository account to pick: every connected account, so the window agrees with Settings > Accounts
    private var connectedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected accounts").font(.headline)
            if connected.isEmpty {
                Text("Connect an account for repository services.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(connected) { a in
                HStack(spacing: 9) {
                    profile(a, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name ?? a.username).font(.callout.weight(.medium)).lineLimit(1)
                        Text(verbatim: "@\(a.username) · \(a.host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if accounts.credentialState(for: a) != .ready { SavedAccountAccessNotice(account: a) }
            }
            Text("Open a repository with a GitHub or GitLab remote to choose the account it uses.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func present(_ request: AccountQuickSheet) { showing = false; sheet = request }

    private func accountLine(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(verbatim: value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profile(_ value: HostAccount?, size: CGFloat) -> some View {
        AsyncImage(url: value?.avatarURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            if let value { Avatar(name: value.name ?? value.username, email: value.username, size: size) }
            else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

private enum AccountQuickSheet: Identifiable {
    case connections
    case login(String?, Gitch.GitHubLoginCapability)
    var id: String {
        switch self {
        case .connections: "connections"
        case .login(let expected, let capability): "login:\(expected ?? "new"):\(capability.rawValue)"
        }
    }
}
