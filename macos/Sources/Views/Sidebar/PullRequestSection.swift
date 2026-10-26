import SwiftUI
import AppKit

struct PullRequestSection: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let target: RepoTarget

    var body: some View {
        SidebarSection("pullRequests") {
            switch store.prState {
            case .needsAccount:
                let others = AccountStore.shared.accounts(for: target.provider)
                if let a = others.first {
                    Button("Try with the connected account (@\(a.username) · \(a.host))") { Task { await store.tryExistingAccounts() } }
                        .buttonStyle(.link)
                        .help("If the same server is used under another address, an account you've already connected works there too")
                }
                Button(target.provider == .gitlab ? "Connect a self-hosted GitLab (\(target.host)) account…" : "Connect a GitHub account…") { openSettings() }
                    .buttonStyle(.link)
            case .failed(let m):
                Text(m).font(.caption).foregroundStyle(.red).lineLimit(3)
            case .loading where store.pullRequests.isEmpty:
                ProgressView().controlSize(.small)
            case .loaded where store.pullRequests.isEmpty:
                Text("No open \(target.provider.requestShort)").font(.callout).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            ForEach(store.pullRequests) { pr in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("#\(pr.number)").foregroundStyle(.secondary).monospacedDigit()
                        Text(pr.title).lineLimit(1)
                        if let sha = pr.headSHA, let ci = store.ciBySha[sha] {
                            CIStatusIcon(status: ci.status, size: 10)
                                .help("CI: \(ci.status.title) · #\(ci.number)")
                        }
                    }
                    HStack(spacing: 4) {
                        if pr.isDraft { Text("Draft").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                        Text("\(pr.source) → \(pr.target)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .sidebarRow()
                .contentShape(Rectangle())
                .onTapGesture { store.select(.pullRequest(pr.number)) }
                .contextMenu {
                    Button("Check out branch") { Task { await store.checkoutPullRequest(pr) } }
                    Button("Open in browser") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                    Button("Copy link") { store.copy(pr.url) }
                }
            }
        } header: {
            HStack {
                Text(store.prState == .loaded ? "\(target.provider.requestsTitle) \(store.pullRequests.count)" : target.provider.requestsTitle)
                Spacer()
                let candidates = AccountStore.shared.candidates(for: target)
                if let current = store.hostingAccount {
                    Menu {
                        ForEach(candidates) { a in
                            Button {
                                store.useAccount(a)
                            } label: {
                                if a.id == current.id { Label("@\(a.username)", systemImage: "checkmark") } else { Text("@\(a.username)") }
                            }
                        }
                        Divider()
                        Button("Add account…") { openSettings() }
                    } label: {
                        Text("@\(current.username)").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(candidates.count > 1 ? "Choose the account for this repository" : "Account for this repository")
                }
                Button { Task { await store.loadPullRequests() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh list")
                Button { store.sheet = .createPullRequest } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(store.headBranch == nil)
                    .help("New \(target.provider.requestShort) from the current branch")
            }
        }
    }
}
