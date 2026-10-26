import SwiftUI

struct WorkspaceOverviewSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var refreshing = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace overview").font(.title3.bold())
            Text("Local status updates automatically for open repositories. Hosting summaries use the selected account for each repository and refresh only when requested.").font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Workspace.shared.openRepositories) { repository in card(repository) }
                        let opened = Set(Workspace.shared.openRepositories.compactMap { $0.url?.path })
                        ForEach(Recents.load().filter { !opened.contains($0.path) }.prefix(12), id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading) { Text(url.lastPathComponent).font(.callout.bold()); Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                Spacer()
                                Button("Open repository") { dismiss(); Task { await store.openOrReport(url) } }
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(minHeight: 300, maxHeight: 540)
            }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }.padding(20).frame(width: 900)
    }

    private func card(_ repository: RepoStore) -> some View {
        let requests = repository.collaboration.inboxKind == "review" ? repository.collaboration.inbox.count : nil
        let pipeline = repository.headHash.flatMap { repository.ciBySha[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name).font(.headline)
                    Text(repository.url?.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if refreshing.contains(repository.id) { ProgressView().controlSize(.small) }
                Button("Open repository") {
                    dismiss(); repository.window?.tabGroup?.selectedWindow = repository.window
                    repository.window?.makeKeyAndOrderFront(nil)
                }
            }
            HStack(spacing: 16) {
                Text(repository.headBranch ?? String(localized: "Detached HEAD")).font(.callout.monospaced())
                Text("\(repository.status.count) modified files")
                Text("↑\(repository.status.ahead) ↓\(repository.status.behind)")
                if let account = repository.gitchStatus?.account { Text(account).foregroundStyle(.secondary) }
            }.font(.caption)
            HStack(spacing: 12) {
                if let pipeline { Label(pipeline.status.title, systemImage: pipeline.status.symbol).foregroundStyle(pipeline.status.color) }
                else { Text("CI not loaded").foregroundStyle(.secondary) }
                Text(requests.map { String(localized: "\($0) review requests loaded") } ?? String(localized: "Review requests not loaded"))
                Spacer()
                Button("Refresh hosting summaries") { refresh(repository) }.disabled(repository.target == nil || refreshing.contains(repository.id))
                Button("Issues and mentions") { dismiss(); Task { @MainActor in try? await Task.sleep(for: .milliseconds(200)); repository.sheet = .collaborationInbox; repository.window?.makeKeyAndOrderFront(nil) } }
                    .disabled(repository.target == nil)
            }.font(.caption)
            if let error = repository.collaboration.inboxError { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refresh(_ repository: RepoStore) {
        refreshing.insert(repository.id)
        Task {
            await repository.loadCI(withJobs: false)
            await repository.loadInbox(kind: "review")
            refreshing.remove(repository.id)
        }
    }
}

struct CollaborationInboxSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CollaborationInboxPanel()
            HStack { Spacer(); Button("Close") { dismiss() } }
        }.padding(20).frame(width: 980)
    }
}
