import AppKit
import SwiftUI

/// Home keeps project planning alongside local repository actions.
struct WorkspaceHomePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var dropping = false
    @ViewState private var showGitSetup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspacePlanningDashboard()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)],
                    alignment: .leading, spacing: 8
                ) {
                    Button("Open repository…") { store.presentOpenPanel() }
                    Button("Clone repository…") { store.sheet = .clone }
                    Button("Create new repository…") { store.presentInitPanel() }
                    Button("Get started with Git accounts…") { showGitSetup = true }
                }
                if store.url != nil {
                    WorkspaceHomeCard {
                        Text(store.name).font(.title2.bold())
                        Text(store.url!.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        WorkbenchFlow(spacing: 14) {
                            Text(store.headBranch ?? String(localized: "Detached HEAD"))
                            Text("\(store.status.count) modified files")
                            Text("↑\(store.status.ahead) ↓\(store.status.behind)")
                            Text(store.gitchStatus?.account ?? String(localized: "Account not checked"))
                        }.font(.callout)
                        Button("Review changes") { store.navigate(.repository); store.showArea(.changes) }
                    }
                }
                Text("Open repositories").font(.headline)
                ForEach(Workspace.shared.openRepositories) { repository in
                    localRow(repository.url, repository: repository)
                }
                Text("Recent local repositories").font(.headline)
                let opened = Set(Workspace.shared.openRepositories.compactMap { $0.url?.path })
                ForEach(Recents.load().filter { !opened.contains($0.path) }.prefix(8), id: \.self) {
                    url in
                    localRow(url)
                }
                WorkspaceHomeCard {
                    RemoteRepositorySearch().frame(minHeight: 160, maxHeight: 360)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showGitSetup) { GitchGuideSheet(repo: store) }
        .background(dropping ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await store.openOrReport(url) }
            return true
        } isTargeted: {
            dropping = $0
        }
    }
    private func localRow(_ url: URL?, repository: RepoStore? = nil) -> some View {
        WorkspaceHomeCard {
            HStack {
                VStack(alignment: .leading) {
                    Text(url?.lastPathComponent ?? "").font(.headline)
                    Text(url?.path ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open repository") {
                    if let repository {
                        repository.window?.makeKeyAndOrderFront(nil)
                        repository.window?.tabGroup?.selectedWindow = repository.window
                    } else if let url {
                        Task { await store.openOrReport(url) }
                    }
                }
            }
        }
        .contextMenu {
            if let url {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if repository == nil { Button("Remove from list") { store.forgetRecent(url) } }
            }
        }
    }
}

private struct WorkspaceHomeCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}
