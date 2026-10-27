import AppKit
import SwiftUI

private struct WorkspacePage<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
                content
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
private struct WorkspaceCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }.padding(18).frame(
            maxWidth: .infinity, alignment: .leading
        ).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)).overlay(
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}
@MainActor private func workspaceAccess(_ store: RepoStore) -> ReviewAccess? {
    guard var c = store.collaborationAccess else { return nil }
    let url = store.url
    let context = store.collaboration.contextID
    let revision = AccountStore.shared.revision
    let account = store.hostingAccount?.id
    c.isCurrent = {
        store.url == url && store.collaboration.contextID == context
            && AccountStore.shared.revision == revision && store.hostingAccount?.id == account
    }
    return c
}
private struct WorkspaceAccountNotice: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if store.collaborationAccess == nil {
            WorkspaceCard {
                if store.target == nil {
                    Text("Open a repository with a GitHub or GitLab remote to use this workspace.").foregroundStyle(.secondary)
                    Button("Open repository…") { store.presentOpenPanel() }
                } else if let account = store.hostingAccount {
                    SavedAccountAccessNotice(account: account) { Task { await store.loadInbox() } }
                } else {
                    Text("Connect an account to load this workspace.").foregroundStyle(.secondary)
                    Button("Connect account…") { openSettings() }
                }
            }
        }
    }
}
struct WorkspaceHomePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var dropping = false
    @ViewState private var showGitSetup = false
    var body: some View {
        WorkspacePage(
            title: "Home",
            subtitle: String(localized: "Plan your day, then build what matters.")
        ) {
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
                WorkspaceCard {
                    Text(store.name).font(.title2.bold())
                    Text(store.url!.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    WorkbenchFlow(spacing: 14) {
                        Text(store.headBranch ?? String(localized: "Detached HEAD"))
                        Text("\(store.status.count) modified files")
                        Text("↑\(store.status.ahead) ↓\(store.status.behind)")
                        Text(store.gitchStatus?.account ?? String(localized: "Account not checked"))
                    }.font(.callout)
                    Button("Review changes") { store.navigate(.changes) }
                }
            }
            if store.url != nil { DisclosureGroup("Repository overview") { RepositoryOverview() } }
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
        WorkspaceCard {
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
    }
}
struct RepositoryLibraryPanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var accountID = ""
    @ViewState private var query = ""
    @ViewState private var repos: [RemoteRepo] = []
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var page = 0
    @ViewState private var more = false
    @ViewState private var generation = UUID()
    var body: some View {
        WorkspacePage(
            title: "Repositories",
            subtitle: String(
                localized: "Local folders stay separate from repositories on a server.")
        ) {
            WorkbenchFlow {
                Button("Open repository…") { store.presentOpenPanel() }
                Button("Clone repository…") { store.sheet = .clone }
            }
            Text("Open local repositories").font(.headline)
            ForEach(Workspace.shared.openRepositories) { repository in
                local(repository.url, repository: repository)
            }
            Text("Recent local repositories").font(.headline)
            let opened = Set(Workspace.shared.openRepositories.compactMap { $0.url?.path })
            ForEach(Recents.load().filter { !opened.contains($0.path) }, id: \.self) { url in
                local(url)
            }
            Divider()
            Text("Repositories on a server").font(.headline)
            Text(
                "Choose an account and server, then search. An empty search lists repositories you belong to."
            ).foregroundStyle(.secondary).font(.callout)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Account and server", selection: $accountID) {
                    Text("Choose an account and server").tag("")
                    ForEach(AccountStore.shared.accounts) { a in
                        Text("\(a.host) · @\(a.username)").tag(a.id)
                    }
                }.frame(maxWidth: 300)
                HStack {
                    TextField("Search remote repositories", text: $query).onSubmit {
                        Task { await search() }
                    }
                    Button("Search") { Task { await search() } }.disabled(accountID.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if AccountStore.shared.accounts.isEmpty {
                Button("Connect account…") { openSettings() }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(repos) { r in
                WorkspaceCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(r.fullName).font(.headline)
                            Text(r.isPrivate ? "Private" : "Public").font(.caption).foregroundStyle(
                                .secondary)
                            if let summary = r.summary {
                                Text(summary).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Clone…") { store.sheet = .cloneURL(r.cloneURL) }
                    }
                }
            }
            if more { Button("Load more") { Task { await search(append: true) } }.disabled(busy) }
            if page > 0, repos.isEmpty, !busy {
                Text("No repositories found.").foregroundStyle(.secondary)
            }
        }.onChange(of: accountID) { _, _ in invalidate() }.onChange(of: query) { _, _ in
            invalidate()
        }
        .onChange(of: AccountStore.shared.revision) { _, _ in invalidate() }.onDisappear {
            generation = UUID()
        }
    }
    private func invalidate() {
        generation = UUID()
        repos = []
        page = 0
        more = false
        busy = false
        error = nil
    }
    private func local(_ url: URL?, repository: RepoStore? = nil) -> some View {
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
        }.padding(.vertical, 7)
    }
    private func search(append: Bool = false) async {
        guard let a = AccountStore.shared.accounts.first(where: { $0.id == accountID }),
            let token = AccountStore.shared.token(for: a)
        else { return }
        let id = UUID()
        let revision = AccountStore.shared.revision
        generation = id
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        let c = ReviewAccess(
            target: RepoTarget(provider: a.provider, remote: "", host: a.host, path: ""),
            token: token,
            apiBase: a.apiBase, me: a.username,
            isCurrent: { generation == id && AccountStore.shared.revision == revision })
        do {
            let (items, next) = try await WorkspaceOperations.repositories(
                c, search: query, page: append ? page + 1 : 1)
            guard generation == id, c.isCurrent?() != false else { return }
            repos =
                append
                ? repos + items.filter { item in !repos.contains { $0.id == item.id } } : items
            more = next
            page = append ? page + 1 : 1
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
}
struct RepositoryWorkInboxPanel: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inbox").font(.largeTitle.bold())
            WorkspaceAccountNotice()
            if store.target != nil {
                CollaborationInboxPanel(initialKind: "mention", embedded: true)
            }
        }.padding(24)
    }
}
@MainActor @Observable private final class MyWorkModel {
    var mine: [PullRequest] = []
    var reviews: [CollaborationInboxItem] = []
    var issues: [CollaborationInboxItem] = []
    var more = false
    var busy = false
    var error: String?
    var id = UUID()
    func load(_ store: RepoStore) async {
        let id = UUID()
        self.id = id
        mine = []
        reviews = []
        issues = []
        more = false
        error = nil
        guard let c = workspaceAccess(store) else { return }
        busy = true
        defer { if self.id == id { busy = false } }
        do {
            async let m = CollaborationAPI.requests(c, RequestQuery(scope: "mine"))
            async let r = CollaborationAPI.inbox(c, kind: "review", page: 1)
            async let i = CollaborationAPI.inbox(c, kind: "issue", page: 1)
            let (mp, rp, ip) = try await (m, r, i)
            guard self.id == id, c.isCurrent?() != false else { return }
            mine = mp.0
            reviews = rp.0
            issues = ip.0
            more = mp.1 || rp.1 || ip.1
        } catch { if self.id == id { self.error = error.localizedDescription } }
    }
}
struct RepositoryMyWorkPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var model = MyWorkModel()
    private var key: String {
        "\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)|\(store.hostingAccount?.id ?? "")"
    }
    var body: some View {
        WorkspacePage(
            title: "My work",
            subtitle: store.target.map {
                "\($0.host)/\($0.path) · @\(store.hostingAccount?.username ?? "")"
            }
        ) {
            WorkspaceAccountNotice()
            HStack {
                Button("Refresh") { Task { await model.load(store) } }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            WorkspaceCard {
                Text("My pull requests").font(.headline)
                ForEach(model.mine) { item in
                    HStack {
                        Text("#\(item.number) \(item.title)")
                        Spacer()
                        Button("Browser") { open(item.url) }
                    }
                }
                if model.mine.isEmpty, !model.busy {
                    Text("No items in this page.").foregroundStyle(.secondary)
                }
            }
            group("Review requested", model.reviews)
            group("Assigned issues", model.issues)
            if model.more {
                Text(
                    "This overview shows the first page. Open Pull requests or Issues to search and load more."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await model.load(store) }
        .onDisappear { model.id = UUID() }
    }
    private func group(_ title: LocalizedStringKey, _ items: [CollaborationInboxItem]) -> some View
    {
        WorkspaceCard {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack {
                    Text("#\(item.number) \(item.title)")
                    Spacer()
                    Button("Browser") { open(item.url) }
                }
            }
            if items.isEmpty, !model.busy {
                Text("No items in this page.").foregroundStyle(.secondary)
            }
        }
    }
    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
struct IssuesWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var model = WorkspaceIssueModel()
    @ViewState private var scope = "open"
    @ViewState private var query = ""
    @ViewState private var editor = false
    @ViewState private var editingNumber: Int?
    @ViewState private var editingOrigin = ""
    @ViewState private var title = ""
    @ViewState private var description = ""
    @ViewState private var comment = ""
    private var key: String {
        "\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)|\(store.hostingAccount?.id ?? "")|\(scope)"
    }
    private var disabled: Bool { model.busy || model.mutating || store.collaboration.inboxBusy }
    var body: some View {
        WorkspacePage(title: "Issues", subtitle: store.target.map { "\($0.host)/\($0.path)" }) {
            WorkspaceAccountNotice()
            VStack(alignment: .leading, spacing: 10) {
                Picker("Issue state", selection: $scope) {
                    Text("Open").tag("open")
                    Text("Closed").tag("closed")
                    Text("All").tag("all")
                }.frame(maxWidth: 170)
                HStack {
                    TextField("Search issues", text: $query).onSubmit { Task { await load() } }
                    Button("Search") { Task { await load() } }
                    Button("New issue") {
                        editingNumber = nil
                        editingOrigin = key
                        title = ""
                        description = ""
                        editor = true
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }.disabled(disabled || store.collaborationAccess == nil)
            if let error = model.error ?? store.collaboration.inboxError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if editor { editorPanel }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    issueList.frame(minWidth: 180, maxWidth: 300)
                    issueDetail.frame(minWidth: 280, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) { issueList; issueDetail }
            }
        }.task(id: key) {
            model.reset()
            editor = false
            store.collaboration.inboxDetail = nil
            await load()
        }.onDisappear { model.reset() }.onChange(of: store.collaboration.inboxDetail?.item.id) {
            _, _ in
            comment = ""
        }
    }
    private var issueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.items) { item in
                Button {
                    Task { await store.openInboxItem(item) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("#\(item.number) \(item.title)").font(.callout.weight(.medium))
                        Text("\(item.state) · @\(item.author)").font(.caption)
                            .foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            store.collaboration.inboxDetail?.item.id == item.id
                                ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
            if model.more {
                Button("Load more") { Task { await load(append: true) } }.disabled(disabled)
            }
            if model.items.isEmpty, !model.busy {
                Text("No items in this page.").foregroundStyle(.secondary)
            }
        }
    }
    private var issueDetail: some View {
        WorkspaceCard {
            if let detail = store.collaboration.inboxDetail, detail.item.kind == "issue" {
                detailPanel(detail)
            } else {
                Text("Select an item to read its conversation.").foregroundStyle(.secondary)
            }
        }
    }
    private var editorPanel: some View {
        WorkspaceCard {
            Text(editingNumber == nil ? "New issue" : "Edit issue").font(.headline)
            TextField("Title", text: $title)
            TextEditor(text: $description).frame(height: 130).accessibilityLabel("Description")
            HStack {
                Button("Cancel") { editor = false }
                Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(
                    title.trimmed.isEmpty)
            }
        }.disabled(disabled)
    }
    private func detailPanel(_ detail: CollaborationInboxDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("#\(detail.item.number) \(detail.item.title)").font(.title3.bold())
            WorkbenchFlow {
                Text(detail.item.state).font(.caption)
                Button("Edit issue") {
                    editingNumber = detail.item.number
                    editingOrigin = key
                    title = detail.item.title
                    description = detail.item.body
                    editor = true
                }
                Button(
                    ["open", "opened"].contains(detail.item.state)
                        ? String(localized: "Close issue…") : String(localized: "Reopen…")
                ) { store.confirmIssueState(detail.item) }
                Button("Browser") {
                    if let url = URL(string: detail.item.url) { NSWorkspace.shared.open(url) }
                }
            }.controlSize(.small).disabled(disabled)
            Text(detail.item.body.isEmpty ? String(localized: "No description") : detail.item.body)
                .textSelection(.enabled)
            ForEach(detail.comments) { c in
                VStack(alignment: .leading, spacing: 5) {
                    Text("@\(c.author)").bold()
                    Text(c.body).textSelection(.enabled)
                }.font(.callout).padding(.vertical, 7)
            }
            if detail.more {
                Button("Load more comments") {
                    Task { await store.openInboxItem(detail.item, append: true) }
                }.disabled(disabled || store.collaboration.inboxLoading)
            }
            TextEditor(text: $comment).frame(height: 90).accessibilityLabel("Comment")
            Button("Comment") {
                let sent = comment
                Task {
                    if await store.inboxAction(detail.item, action: "comment", body: sent),
                        store.collaboration.inboxDetail?.item.id == detail.item.id, comment == sent
                    {
                        comment = ""
                    }
                }
            }.disabled(disabled || comment.trimmed.isEmpty || store.collaboration.inboxLoading)
        }
    }
    private func load(append: Bool = false) async {
        guard let c = workspaceAccess(store) else { return }
        await model.load(c, scope: scope, search: query, append: append)
    }
    private func save() async {
        guard !model.mutating, editingOrigin == key, let c = workspaceAccess(store) else { return }
        let id = model.generation
        let number = editingNumber
        let sentTitle = title
        let sentBody = description
        model.mutating = true
        model.error = nil
        defer { model.mutating = false }
        do {
            let item = try await WorkspaceOperations.saveIssue(
                c, title: sentTitle, body: sentBody, number: number)
            guard model.generation == id, c.isCurrent?() != false else { return }
            if title == sentTitle, description == sentBody { editor = false }
            await load()
            await store.openInboxItem(item)
        } catch { if model.generation == id { model.error = error.localizedDescription } }
    }
}
private struct WorkspaceJobLogPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var job = 0
    @ViewState private var bodyText = ""
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var truncated = false
    @ViewState private var generation = UUID()
    private var jobs: [CIJob] {
        Dictionary(
            store.ciJobs.values.flatMap { $0 }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.id > $1.id }
    }
    private var key: String {
        "\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)|\(store.hostingAccount?.id ?? "")"
    }
    var body: some View {
        WorkspaceCard {
            Text("Job log").font(.headline)
            Text(
                "Expand a run above to load its jobs, then choose a job. Logs stay on this device."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Job", selection: $job) {
                    Text("Choose a job").tag(0)
                    ForEach(jobs) { j in Text("\(j.name) · #\(j.id)").tag(j.id) }
                }.frame(maxWidth: 350)
                Button("Load log") { Task { await load() } }.disabled(job == 0 || busy)
                if busy { ProgressView().controlSize(.small) }
                Button("Copy redacted log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bodyText, forType: .string)
                }.disabled(bodyText.isEmpty)
                if let selected = jobs.first(where: { $0.id == job }),
                    let url = URL(string: selected.url)
                {
                    Link("Browser", destination: url)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            if truncated {
                Text("Log preview is limited to 2 MB. Open the browser for the complete log.").font(
                    .caption
                ).foregroundStyle(.secondary)
            }
            if !bodyText.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: bodyText).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 180, maxHeight: 440)
            }
        }.onChange(of: job) { _, _ in reset() }.onChange(of: key) { _, _ in
            job = 0
            reset()
        }.onDisappear { generation = UUID() }
    }
    private func reset() {
        generation = UUID()
        bodyText = ""
        error = nil
        busy = false
        truncated = false
    }
    private func load() async {
        guard let c = workspaceAccess(store) else { return }
        let id = UUID()
        generation = id
        busy = true
        bodyText = ""
        error = nil
        defer { if generation == id { busy = false } }
        do {
            let result = try await WorkspaceCILog.load(c, job: job)
            guard generation == id, c.isCurrent?() != false else { return }
            bodyText = result.body
            truncated = result.truncated
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
}
struct ActionsWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        WorkspacePage(
            title: store.target?.provider == .gitlab ? "Pipelines" : "Actions",
            subtitle: store.target.map { "\($0.host)/\($0.path)" }
        ) {
            CIPanel().frame(minHeight: 350, idealHeight: 450, maxHeight: 600)
            WorkspaceJobLogPanel()
        }
    }
}
struct OperationsWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Recovery, LFS, submodules and bisect…") { store.sheet = .localWorkflows }.disabled(store.url == nil)
                Button("Connect external AI with MCP…") { store.sheet = .mcpConnection }.disabled(store.url == nil)
                Spacer()
            }.padding(20)
            Divider()
            GitchGuideSheet(repo: store, embedded: true)
        }
    }
}
