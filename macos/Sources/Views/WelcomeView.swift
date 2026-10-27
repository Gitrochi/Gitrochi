import SwiftUI
import AppKit

/// Home: open, clone or create a repository, the recent list and a search of repositories on a server
struct WelcomeView: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var dropping = false
    @ViewState private var showGitSetup = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                Text("Gitrochi").font(.largeTitle.weight(.bold))
                Text("A Mac app for viewing and working with Git repositories as a graph")
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    action(String(localized: "Get started with Git accounts…"), "person.crop.circle.badge.plus", prominent: !Gitch.hasConfig) { showGitSetup = true }
                    action(String(localized: "Open repository…"), "folder", prominent: Gitch.hasConfig) { store.presentOpenPanel() }
                    action(String(localized: "Clone repository…"), "arrow.down.circle") { store.sheet = .clone }
                    action(String(localized: "Create new repository…"), "plus.square.on.square") { store.presentInitPanel() }
                }
                .padding(.top, 8)
                Text("Git account setup and code maps are included. No extra download is needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("You can also drop a folder onto this window to open it")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dropping ? Color.accentColor.opacity(0.08) : Color.clear)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Recent repositories")
                    .font(.headline)
                    .padding(16)
                if store.recents.isEmpty {
                    Text("No repositories opened yet")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    Spacer()
                } else {
                    List(store.recents, id: \.self) { u in
                        Button {
                            Task { await store.openOrReport(u) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.lastPathComponent).fontWeight(.medium)
                                Text((u.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            Button("Remove from list") { store.forgetRecent(u) }
                        }
                    }
                    .listStyle(.sidebar)
                }
                Divider()
                RemoteRepositorySearch().frame(maxHeight: .infinity)
            }
            .frame(width: 340)
        }
        .sheet(isPresented: $showGitSetup) { GitchGuideSheet(repo: store) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            Task { await store.openOrReport(u) }
            return true
        } isTargeted: { dropping = $0 }
    }

    private func action(_ title: String, _ icon: String, prominent: Bool = false, _ run: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(action: run) { Label(title, systemImage: icon).frame(width: 220) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: run) { Label(title, systemImage: icon).frame(width: 220) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }
}
