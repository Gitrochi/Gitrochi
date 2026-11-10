import SwiftUI

/// The Projects page's header, as the redesign's Projects board draws it: whose projects are shown and where they are
/// kept, then the project with its one filled action. (Windows: widgets/hosting-hub/ui/ProjectWorkspaceHeader.tsx)
struct ProjectWorkspaceHeader: View {
    @Bindable var store: RepoStore
    let locked: Bool
    let newProject: () -> Void
    let chooseProject: (HubItem) -> Void
    let refresh: () -> Void
    let addTask: () -> Void
    let importItem: () -> Void
    let overview: () -> Void
    let manage: (ProjectManagementTab) -> Void
    let openBrowser: () -> Void
    let deleteProject: () -> Void
    @ViewState private var catalogs = ProjectScopeCatalogs()
    private var hub: HostingHubState { store.hostingHub }
    private var detail: HubDetail? { hub.detail }
    private var local: Bool { store.hubIsLocalProject }
    /// The account the page returns to from Local names the other side of the switch
    private var remote: Provider {
        (AccountStore.shared.accounts.first { $0.id == hub.selectedAccountID } ?? store.hostingAccount ?? AccountStore.shared.accounts.first)?.provider ?? .github
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProjectScopeMenu(store: store, catalogs: catalogs, locked: locked)
                Picker("Project source", selection: Binding(get: { hub.projectSource }, set: { source in Task { await store.selectHubProjectSource(source) } })) {
                    Text("Local").tag("local"); Text(verbatim: remote == .gitlab ? "GitLab" : "GitHub").tag("remote")
                }.labelsHidden().pickerStyle(.segmented).fixedSize().disabled(locked)
                Button(action: refresh) { DesignIconImage(icon: .refresh) }.controlSize(.large).help("Refresh").accessibilityLabel("Refresh").disabled(locked)
                Spacer(minLength: 0)
            }.padding(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20))
            if !local, catalogs.failed(store.hubAccount), let account = store.hubAccount {
                ProjectScopeFailureStrip(gitlab: account.provider == .gitlab) { Task { await catalogs.load(account) } }
                    .padding(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
            }
            // With no project and nothing failed the empty state below says so; a title would have nothing to name.
            if detail != nil || !hub.items.isEmpty || hub.error != nil { titleRow } else { Color.clear.frame(height: 12) }
        }
    }

    /// The project, chosen in its own menu, and the page's one filled action
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SymbolIcon("checkmark.square").font(.system(size: 15)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 16).accessibilityHidden(true)
                    // A menu's label keeps only its text, so the icon sits beside it and the chevron after it is the menu's own.
                    Menu {
                        ForEach(hub.items) { item in
                            Button { chooseProject(item) } label: { if item.id == detail?.item.id { Label(item.title, symbol: "checkmark") } else { Text(item.title) } }
                        }
                        if hub.more { Button("Load more projects") { Task { await store.loadHostingHub(append: true) } } }
                        if !hub.items.isEmpty { Divider() }
                        Button("New project…", action: newProject)
                    } label: {
                        Text(detail?.item.title ?? String(localized: "Choose a project")).font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().disabled(locked)
                        .accessibilityLabel(Text("Project")).accessibilityValue(detail?.item.title ?? String(localized: "Choose a project"))
                }
                if let detail, !detail.item.body.isEmpty { Text(detail.item.body).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).padding(.leading, 24) }
                else if detail != nil { Text(local ? String(localized: "Local project") : String(localized: "GitHub project")).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).padding(.leading, 24) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if detail != nil {
                HStack(spacing: 8) {
                    Menu {
                        Button("New project…", action: newProject)
                        if store.hubProvider == .github { Button("Rename project…") { manage(.overview) } }
                        Divider()
                        Button("Project overview", action: overview)
                        if store.hubProvider == .github, !local { Button("Manage fields…") { manage(.fields) }; Button("Manage shared views…") { manage(.views) } }
                        // New task… drafts a task; an item that already exists on the server is added from here.
                        if store.hubProvider == .github, !local { Button("Add existing issue or pull request…", action: importItem) }
                        if !local { Button("Open in GitHub", action: openBrowser) }
                        if local { Divider(); Button("Delete project…", role: .destructive, action: deleteProject) }
                    } label: { DesignIconImage(icon: .more) }.menuStyle(.button).menuIndicator(.hidden).fixedSize().help("More project actions").accessibilityLabel("More project actions").disabled(hub.uncertainWrite)
                    Button(action: store.hubProvider == .github ? addTask : importItem) { Label("New task…", symbol: "plus") }.buttonStyle(.borderedProminent).disabled(hub.uncertainWrite)
                }.controlSize(.large).disabled(locked)
            }
        }.padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
    }
}
