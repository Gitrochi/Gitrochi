import SwiftUI

/// The sidebar folded away: one icon per section with its count. Hovering (or clicking) an icon opens that section as a
/// flyout, like GitKraken. (Windows: widgets/sidebar/ui/SidebarRail.tsx)
struct SidebarRail: View {
    @Environment(RepoStore.self) private var store
    /// Brings the sidebar back
    let show: () -> Void
    @ViewState private var open: String?
    @ViewState private var overFlyout = false

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: Text
        let count: Int?
    }

    private var items: [Item] {
        var out: [Item] = []
        if let t = store.target {
            let loaded = store.prState == .loaded
            out.append(Item(id: "pullRequests", icon: "arrow.triangle.pull",
                            title: Text(loaded ? "\(t.provider.requestsTitle) \(store.pullRequests.count)" : t.provider.requestsTitle),
                            count: loaded ? store.pullRequests.count : nil))
        }
        let pinned = store.localBranches.filter { store.isPinned($0) }.count
        if pinned > 0 { out.append(Item(id: "pinned", icon: "pin", title: Text("Pinned"), count: pinned)) }
        out.append(Item(id: "local", icon: "arrow.triangle.branch", title: Text("Local branches \(store.localBranches.count)"), count: store.localBranches.count))
        if store.worktrees.count > 1 { out.append(Item(id: "worktrees", icon: "folder", title: Text("Worktrees \(store.worktrees.count)"), count: store.worktrees.count)) }
        if !store.remoteBranches.isEmpty { out.append(Item(id: "remotes", icon: "cloud", title: Text("Remotes \(store.remoteBranches.count)"), count: store.remoteBranches.count)) }
        if !store.tags.isEmpty { out.append(Item(id: "tags", icon: "tag", title: Text("Tags \(store.tags.count)"), count: store.tags.count)) }
        if !store.stashes.isEmpty { out.append(Item(id: "stashes", icon: "tray", title: Text("Stashes \(store.stashes.count)"), count: store.stashes.count)) }
        return out
    }

    var body: some View {
        VStack(spacing: 2) {
            Button(action: show) { Image(systemName: "sidebar.leading") }
                .buttonStyle(.borderless)
                .help("Show sidebar")
                .padding(.vertical, 6)
            ForEach(items) { item in
                VStack(spacing: 1) {
                    Image(systemName: item.icon).font(.system(size: 14))
                    if let n = item.count { Text("\(n)").font(.caption2.monospacedDigit()) }
                }
                .foregroundStyle(open == item.id ? Color.accentColor : .secondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(open == item.id ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { open = item.id } else { closeSoon(item.id) }
                }
                .onTapGesture { open = open == item.id ? nil : item.id }
                .help(item.title)
                .popover(isPresented: Binding(get: { open == item.id }, set: { if !$0 { open = nil } }), arrowEdge: .trailing) {
                    SidebarView(flyout: item.id)
                        .onHover { inside in
                            overFlyout = inside
                            if !inside { closeSoon(item.id) }
                        }
                }
            }
            Spacer()
        }
        .frame(width: 44)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: open) { overFlyout = false }
    }

    /// Closes the flyout unless the mouse went into it, or onto another icon, meanwhile
    private func closeSoon(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if open == id, !overFlyout { open = nil }
        }
    }
}
