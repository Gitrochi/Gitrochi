import SwiftUI

/// A stable title row and a quiet source row leave the task surface room to breathe.
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
    private var hub: HostingHubState { store.hostingHub }
    private var detail: HubDetail? { hub.detail }
    private var local: Bool { store.hubIsLocalProject }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("Project source", selection: Binding(get: { hub.projectSource }, set: { source in Task { await store.selectHubProjectSource(source) } })) {
                    Text("Local").tag("local"); Text("GitHub").tag("remote")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 152)
                if !local {
                    Picker("Workspace account", selection: Binding(get: { store.hubAccount?.id ?? "" }, set: { id in Task { await store.selectHubAccount(id) } })) {
                        ForEach(AccountStore.shared.accounts) { account in Text(verbatim: "@" + account.username).tag(account.id) }
                    }.labelsHidden().frame(maxWidth: 180)
                    if store.hubProvider == .github {
                        Picker("Project scope", selection: Binding(get: { store.hubProjectEffectiveScope }, set: { scope in Task { await store.selectHubProjectScope(scope) } })) {
                            Text("My projects").tag("personal")
                            if let owner = store.hubProjectRepositoryOwner { Text(owner).tag("repository") }
                        }.labelsHidden().frame(maxWidth: 150)
                    }
                }
                Spacer(minLength: 8)
                Button(action: newProject) { Label("New project", systemImage: "plus") }.buttonStyle(.borderless)
            }.font(.caption).controlSize(.small).disabled(locked)
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "rectangle.3.group").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Menu {
                        ForEach(hub.items) { item in Button(item.title) { chooseProject(item) } }
                        if hub.more { Divider(); Button("Load more projects") { Task { await store.loadHostingHub(append: true) } } }
                    } label: {
                        HStack(spacing: 8) { Text(detail?.item.title ?? String(localized: "Choose a project")).font(.system(size: 21, weight: .semibold)).foregroundStyle(.primary).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true).disabled(locked || hub.items.isEmpty)
                    if let detail, !detail.item.body.isEmpty { Text(detail.item.body).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    else { Text(local ? String(localized: "Local project") : String(localized: "GitHub project")).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }.buttonStyle(.borderless).help("Refresh project")
                    if detail != nil {
                        Menu {
                            Button("Project overview", action: overview)
                            if store.hubProvider == .github {
                                Button("Project settings…") { manage(.overview) }
                                if !local { Button("Manage fields…") { manage(.fields) }; Button("Manage shared views…") { manage(.views) } }
                            }
                            if !local { Divider(); Button("Open in GitHub", action: openBrowser) }
                        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Project actions").disabled(hub.uncertainWrite)
                        if local {
                            Button(action: addTask) { Label("New task", systemImage: "plus").fontWeight(.semibold) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(hub.uncertainWrite)
                        } else {
                            Menu { if store.hubProvider == .github { Button("Draft task", action: addTask) }; Button("Existing issue or pull request", action: importItem) }
                                label: { Label("Add item", systemImage: "plus").fontWeight(.semibold).foregroundStyle(.white) }
                                .menuStyle(.borderlessButton).tint(.white).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 9).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8)).disabled(hub.uncertainWrite)
                        }
                    }
                }.disabled(locked)
            }
        }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
    }
}
