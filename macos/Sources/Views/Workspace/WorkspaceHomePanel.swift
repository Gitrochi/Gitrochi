import AppKit
import SwiftUI

/// Home, as the redesign's Home board draws it: repositories first (open, clone or create one, the one opened last and
/// the recent ones), then the few tasks due today. (Windows: WorkspaceHomePanel.tsx)
struct WorkspaceHomePanel: View {
    @Environment(RepoStore.self) private var store
    /// Shown in place of a page that needs a repository while none is open
    var repositoryOnly = false
    @ViewState private var dropping = false
    @ViewState private var filter = ""
    /// Branch, sync state and changed files of each recent repository, by path, read when Home appears
    @ViewState private var states: [String: WorkingStatus] = [:]
    @ViewState private var hovered: URL?

    /// Read from the shared list on every draw: each tab's store keeps its own copy, which misses what other tabs opened
    private var recents: [URL] {
        _ = store.recents
        return Recents.load()
    }
    private var filtering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The list under the card; while filtering, every repository that matches, the last opened one too
    private var listed: [URL] {
        filtering ? recents.filter { HomeRepositories.matches($0, filter: filter) } : Array(recents.dropFirst())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                repositories
                if !repositoryOnly { WorkspacePlanningDashboard(todayOnly: true) }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20))
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(dropping ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await store.openOrReport(url) }
            return true
        } isTargeted: {
            dropping = $0
        }
        .task(id: recents) { await readStates() }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 12) {
            if repositoryOnly {
                Text("Open a repository to use this page.").font(.system(size: 13)).foregroundStyle(StudioStyle.Rail.icon)
            }
            Text("Repositories").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Button { store.presentOpenPanel() } label: { Label("Open…", systemImage: "folder") }
                Button { store.sheet = .clone } label: { Label("Clone…", systemImage: "arrow.down.to.line") }
                Button { store.presentInitPanel() } label: { Label("New repository…", systemImage: "plus") }
                Spacer(minLength: 8)
                filterField
            }
            .buttonStyle(HomeButtonStyle())
            if !filtering, let last = recents.first { lastOpened(last) }
            if !listed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
                    VStack(spacing: 0) {
                        ForEach(listed, id: \.self) { url in
                            row(url)
                            if url != listed.last { Divider() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
                }
                .padding(.top, 6)
            } else if recents.isEmpty || filtering {
                Text("No repositories opened yet").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            TextField("Filter repositories", text: $filter).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HomeButtonStyle.edge))
    }

    private func lastOpened(_ url: URL) -> some View {
        let state = states[url.path]
        return HStack(alignment: .center, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last opened").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                    Text(url.lastPathComponent).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    Text(Self.path(url)).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let state {
                        WorkbenchFlow(spacing: 6) {
                            StatusPill(title: state.branch ?? String(localized: "Detached HEAD"), symbol: "arrow.triangle.branch", tone: .neutral)
                            if state.ahead > 0 { StatusPill(title: String(localized: "\(state.ahead) not pushed"), tone: .neutral) }
                            if state.behind > 0 { StatusPill(title: String(localized: "\(state.behind) to pull"), tone: .neutral) }
                            if state.count > 0 { StatusPill(title: String(localized: "\(state.count) changed files"), tone: .neutral) }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open repository") { open(url) }
                .buttonStyle(HomeButtonStyle(filled: true))
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .contextMenu { menu(url) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last opened repository")
    }

    private func row(_ url: URL) -> some View {
        let state = states[url.path]
        return Button { open(url) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let opened = Recents.opened(url) {
                            Text(HomeRepositories.opened(opened, locale: AppLanguage.locale)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(Self.path(url)).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        if let state {
                            Text(verbatim: "·").accessibilityHidden(true)
                            Text(state.branch ?? String(localized: "Detached HEAD")).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: "·").accessibilityHidden(true)
                            Text(HomeRepositories.sync(ahead: state.ahead, behind: state.behind)).lineLimit(1).fixedSize()
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(StudioStyle.Rail.icon)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered == url ? StudioStyle.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? url : (hovered == url ? nil : hovered) }
        .contextMenu { menu(url) }
    }

    @ViewBuilder private func menu(_ url: URL) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if url != store.url { Button("Remove from list") { store.forgetRecent(url) } }
    }

    /// A repository already open in a tab comes to the front; this window's own goes to its repository screen
    private func open(_ url: URL) {
        if url == store.url { store.navigate(.repository); return }
        if let tab = Workspace.shared.openRepositories.first(where: { $0.url == url }), let window = tab.window {
            window.makeKeyAndOrderFront(nil)
            window.tabGroup?.selectedWindow = window
            return
        }
        Task { await store.openOrReport(url) }
    }

    /// ~/Projects/desktop rather than the full home path
    private static func path(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    private func readStates() async {
        let urls = recents
        let read = await withTaskGroup(of: (String, WorkingStatus?).self) { group in
            for url in urls {
                group.addTask {
                    let result = try? await Git.run(RepoStore.statusArgs, in: url)
                    return (url.path, result.map { Parsers.status($0.data) })
                }
            }
            var states: [String: WorkingStatus] = [:]
            for await (path, state) in group { if let state { states[path] = state } }
            return states
        }
        if !Task.isCancelled { states = read }
    }
}

/// The board's 28pt button: an icon and a label in a hairline frame, or filled with the accent for the one main action
private struct HomeButtonStyle: ButtonStyle {
    static let edge = Color.primary.opacity(0.16)
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(HomeButtonLabel())
            .font(.system(size: 13))
            .foregroundStyle(filled ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Color.accentColor : StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filled ? Color.clear : Self.edge))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct HomeButtonLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
