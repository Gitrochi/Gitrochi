import SwiftUI

/// Home combines selected projects without borrowing or changing the active project controller.
struct WorkspacePlanningDashboard: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var portfolio = ProjectPortfolioState()
    @ViewState private var accountID = ""
    @ViewState private var projectSource = UserDefaults.standard.string(forKey: "planningHome.projectSource") ?? "automatic"
    @ViewState private var creatingProject = false
    @ViewState private var scope = "personal"
    @ViewState private var focus = "focus"
    @ViewState private var query = ""
    @ViewState private var onlyMine = false
    @ViewState private var today = ProjectSchedule.today()
    @ViewState private var anchor = ProjectSchedule.today()
    @ViewState private var mode = "agenda"
    @ViewState private var width: CGFloat = 1000
    @ViewState private var opening = false
    @ViewState private var navigationID = UUID()
    @ViewState private var portfolioContext = ""
    var fixture: ProjectPortfolioState? = nil
    private var data: ProjectPortfolioState { fixture ?? portfolio }
    private var accounts: [HostAccount] { AccountStore.shared.accounts.filter { $0.provider == .github } }
    private var isLocal: Bool {
        if projectSource != "automatic" { return projectSource == "local" }
        if let fixture { return fixture.details.first.map { LocalProjectStore.isLocal($0.item) } ?? false }
        return accounts.isEmpty
    }
    private var account: HostAccount? { accounts.first { $0.id == accountID } ?? accounts.first { $0.id == store.hubAccount?.id } ?? accounts.first }
    private var repositoryScope: Bool { guard let target = store.target, let account else { return false }; return AccountStore.shared.candidates(for: target).contains { $0.id == account.id } }
    private var effectiveScope: String { repositoryScope ? scope : "personal" }
    private var selectionContext: String { isLocal ? "local" : [account?.id ?? "", effectiveScope, store.url?.path ?? "", store.target?.provider.rawValue ?? "", store.target?.host ?? "", store.target?.path ?? ""].joined(separator: "\0") }
    private var context: String { selectionContext + "\0" + String(isLocal ? LocalProjectStore.shared.revision : AccountStore.shared.revision) }
    private var tasks: [ProjectPortfolioTask] {
        let settings = Dictionary(uniqueKeysWithValues: data.details.map { ($0.item.id, ProjectSchedulePreferences.load(accountID: account?.id ?? "", projectID: $0.item.id)) })
        return ProjectPortfolio.tasks(data.details, settingsByProject: settings).filter(matches)
    }
    private func matches(_ task: ProjectPortfolioTask) -> Bool {
            (isLocal || !onlyMine || task.entry.row.assignees.contains { $0.caseInsensitiveCompare(account?.username ?? "") == .orderedSame }) &&
        (query.trimmed.isEmpty || ([task.entry.row.title, task.entry.row.repository] + task.projectNames + task.entry.row.assignees).joined(separator: " ").localizedCaseInsensitiveContains(query.trimmed))
    }
    private var summary: ProjectScheduleSummary { ProjectSchedule.summary(tasks.map(\.entry), today: today) }
    private var agenda: [ProjectPortfolioTask] {
        tasks.filter { task in
            let entry = task.entry
            if focus == "completed" { return entry.completed }
            guard !entry.completed else { return false }
            if focus == "unscheduled" { return entry.date == nil }
            if focus == "overdue" { return !entry.invalidRange && entry.due.map { $0 < today } == true }
            if focus == "today" { return !entry.invalidRange && entry.date == today }
            if focus == "upcoming" { return !entry.invalidRange && entry.date.map { $0 > today && $0 <= (ProjectSchedule.addDays(today, 7) ?? today) } == true }
            return true
        }.sorted { ($0.entry.date ?? "9999", $0.entry.row.title) < ($1.entry.date ?? "9999", $1.entry.row.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Your planning desk", systemImage: "sun.horizon").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Text("A clear day starts with a clear plan.").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Bring project deadlines and your next actions into one place.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if data.loading { ProgressView().controlSize(.small) }
                Button("New project") { creatingProject = true }.buttonStyle(.borderedProminent).controlSize(.small)
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh planning dashboard").disabled(data.loading || (!isLocal && account == nil))
            }
            if fixture == nil && portfolioContext != context {
                ProgressView("Loading project schedules…").font(.callout)
            } else {
                controls
                if let error = data.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if !isLocal && accounts.isEmpty && fixture == nil {
                    Text("Connect a GitHub account to plan across your projects.").font(.callout).foregroundStyle(.secondary)
                }
                if !data.loading && (data.error != nil || data.projects.isEmpty) && (isLocal || account != nil) {
                    Button("Open project workspace") {
                        store.hostingHub.projectSource = isLocal ? "local" : "remote"
                        if !isLocal { store.hostingHub.selectedAccountID = account?.id }
                        store.hostingHub.projectScope = effectiveScope
                        store.navigate(.projects)
                    }
                }
                if !isLocal, fixture == nil, let account, AccountStore.shared.credentialState(for: account) == .authorizationRequired {
                    Button("Allow saved account access") { Task { try? await AccountStore.shared.allowStoredAccess(for: account); await refresh() } }
                }
                if !data.projectErrors.isEmpty {
                    Text("Some projects could not be refreshed. Their last loaded tasks may be out of date.").font(.caption).foregroundStyle(.orange)
                }
                metrics
                WorkbenchFlow(spacing: 10) {
                    Picker("Planning view", selection: $mode) { Text("Agenda").tag("agenda"); Text("Week").tag("week"); Text("Projects").tag("projects") }.labelsHidden().pickerStyle(.segmented).frame(width: 280)
                    TextField("Search tasks and projects", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    if !isLocal { Toggle("Assigned to me", isOn: $onlyMine).toggleStyle(.button) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if mode == "week" { week }
                else if mode == "projects" { projects }
                else { agendaList }
                if isLocal { Text("Saved on this device. Local projects do not sync with GitHub.").font(.caption2).foregroundStyle(.secondary) }
                else { Text("Loaded tasks from selected projects. Shared issues appear once, using their earliest active date.").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.055), Color(nsColor: .controlBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.accentColor.opacity(0.12)))
        .task(id: context) {
            if fixture == nil {
                data.reset(context: context)
                portfolioContext = context
                if let saved = ProjectPortfolioPreferences.load(context: selectionContext) { data.setSelected(saved) }
                await load()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { today = ProjectSchedule.today() }
            }
        }
        .sheet(isPresented: $creatingProject) {
            ProjectCreationSheet(store: store) { item in
                projectSource = LocalProjectStore.isLocal(item) ? "local" : "remote"
                UserDefaults.standard.set(projectSource, forKey: "planningHome.projectSource")
                if !LocalProjectStore.isLocal(item) { accountID = store.hostingHub.selectedAccountID ?? accountID; scope = store.hostingHub.projectScope }
                var selected = ProjectPortfolioPreferences.load(context: selectionContext) ?? Set(store.hostingHub.items.prefix(3).map(\.id))
                selected.insert(item.id)
                ProjectPortfolioPreferences.save(selected, context: selectionContext)
                store.navigate(.projects)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Home planning dashboard")
        .onChange(of: context) { _, _ in navigationID = UUID(); opening = false }
        .onChange(of: projectSource) { _, value in UserDefaults.standard.set(value, forKey: "planningHome.projectSource"); onlyMine = false }
        .onDisappear { navigationID = UUID(); opening = false }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    private var controls: some View {
        WorkbenchFlow(spacing: 10) {
            Picker("Project source", selection: Binding(get: { isLocal ? "local" : "remote" }, set: { projectSource = $0 })) { Text("Local projects").tag("local"); Text("GitHub projects").tag("remote") }.labelsHidden().frame(width: 185)
            if !isLocal {
                Picker("Planning account", selection: Binding(get: { account?.id ?? "" }, set: { accountID = $0 })) { ForEach(accounts) { Text("@\($0.username) · \($0.host)").tag($0.id) } }.labelsHidden().frame(maxWidth: 250)
                if repositoryScope { Picker("Project scope", selection: $scope) { Text("My projects").tag("personal"); Text("Repository owner projects").tag("repository") }.labelsHidden().frame(width: 195) }
            }
            Menu {
                ForEach(data.projects) { item in
                    Toggle(item.title, isOn: Binding(get: { data.selectedIDs.contains(item.id) }, set: { enabled in
                        var selected = data.selectedIDs; if enabled { selected.insert(item.id) } else { selected.remove(item.id) }
                        data.setSelected(selected)
                        ProjectPortfolioPreferences.save(selected, context: selectionContext)
                        Task { await refresh() }
                    }))
                }
                if data.selectedIDs.contains(where: { id in !data.projects.contains { $0.id == id } }) {
                    Divider()
                    Button("Remove unavailable selections") {
                        let selected = data.selectedIDs.intersection(Set(data.projects.map(\.id)))
                        data.setSelected(selected)
                        ProjectPortfolioPreferences.save(selected, context: selectionContext)
                        Task { await refresh() }
                    }
                }
                if data.more { Divider(); Button("Load more projects") { Task { await load(append: true) } } }
            } label: { Label("Choose projects", systemImage: "rectangle.3.group") }.disabled(data.loading)
            Text(verbatim: String(localized: "{0} projects selected").replacingOccurrences(of: "{0}", with: data.selectedIDs.count.formatted())).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).controlSize(.small)
    }
    private var metrics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 100), spacing: 10), count: width >= 900 ? 5 : width >= 640 ? 3 : 2), spacing: 10) {
            metric("Overdue", summary.overdue, "overdue", .red)
            metric("Today", summary.today, "today", .accentColor)
            metric("Next 7 days", summary.upcoming, "upcoming", .blue)
            metric("Unscheduled", summary.unscheduled, "unscheduled", .secondary)
            metric("Completed", summary.completed, "completed", .green)
        }
    }
    private func metric(_ label: LocalizedStringKey, _ count: Int, _ key: String, _ color: Color) -> some View {
        Button { focus = focus == key ? "focus" : key; mode = "agenda" } label: {
            VStack(alignment: .leading, spacing: 7) { Text(label).font(.caption).foregroundStyle(.secondary); Text(count.formatted()).font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(color) }
                .padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == key ? color.opacity(0.6) : .clear))
        }.buttonStyle(.plain)
    }
    private var agendaList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("Your next actions").font(.headline); Spacer(); if focus != "focus" { Button("Clear filter") { focus = "focus" }.font(.caption) } }
            if agenda.isEmpty { Text(data.loading ? "Loading project schedules…" : "No tasks in this view. Choose projects or adjust your filters.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 18) }
            ForEach(agenda.prefix(16)) { task in taskRow(task) }
            if agenda.count > 16 { Text("Open a project to see its full plan.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func taskRow(_ task: ProjectPortfolioTask) -> some View {
        Button { open(task.detail.item, rowID: task.entry.row.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: task.entry.completed ? "checkmark.circle.fill" : ProjectTaskStyle.symbol(task.entry.row)).foregroundStyle(task.entry.completed ? .green : Color.accentColor)
                VStack(alignment: .leading, spacing: 5) { Text(task.entry.row.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2); Text(task.projectNames.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 6)
                if task.entry.invalidDate || task.entry.invalidRange { Text("Check task dates").font(.caption).foregroundStyle(.orange) }
                else if let day = task.entry.date { Text(ProjectSchedulePresentation.date(day)).font(.caption.weight(.medium)).foregroundStyle(task.entry.due.map { $0 < today } == true && !task.entry.completed ? .red : Color.secondary) }
                else { Text("No date").font(.caption).foregroundStyle(.tertiary) }
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(opening)
    }
    private var week: some View {
        let entries = tasks
        let columnWidth = max(170, (width - 108) / 7)
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text("This week, in focus").font(.headline); Spacer(); Button { anchor = ProjectSchedule.addDays(anchor, -7) ?? anchor } label: { Image(systemName: "chevron.left") }.help("Previous week"); Button("Today") { anchor = today }; Button { anchor = ProjectSchedule.addDays(anchor, 7) ?? anchor } label: { Image(systemName: "chevron.right") }.help("Next week") }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ProjectSchedule.weekDays(anchor), id: \.self) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ProjectSchedulePresentation.date(day, template: "EEE MMMd")).font(.caption.weight(.semibold)).foregroundStyle(day == today ? Color.accentColor : .secondary)
                            ForEach(entries.filter { !$0.entry.completed && !$0.entry.invalidRange && $0.entry.date == day }) { task in weekTaskRow(task) }
                            if !entries.contains(where: { !$0.entry.completed && !$0.entry.invalidRange && $0.entry.date == day }) { Text("No scheduled work").font(.caption2).foregroundStyle(.tertiary).padding(.vertical, 15) }
                        }.padding(12).frame(width: columnWidth, alignment: .leading).frame(minHeight: 165, alignment: .top).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
    private func weekTaskRow(_ task: ProjectPortfolioTask) -> some View {
        Button { open(task.detail.item, rowID: task.entry.row.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: ProjectTaskStyle.symbol(task.entry.row)).foregroundStyle(Color.accentColor)
                    if let number = task.entry.row.number { Text("#\(number)").monospacedDigit().foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }.font(.caption2)
                Text(task.entry.row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
                Text(task.projectNames.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(task.entry.row.title)
    }
    private var projects: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 220), spacing: 12), count: max(1, min(data.details.count, width >= 1100 ? 3 : width >= 760 ? 2 : 1))), spacing: 12) {
            ForEach(data.details, id: \.item.id) { detail in
                let settings = ProjectSchedulePreferences.load(accountID: account?.id ?? "", projectID: detail.item.id)
                let entries = ProjectPortfolio.tasks([detail], settingsByProject: [detail.item.id: settings]).filter(matches).map(\.entry)
                let progress = ProjectSchedule.summary(entries, today: today)
                if !entries.isEmpty || ((isLocal || !onlyMine) && query.trimmed.isEmpty) {
                VStack(alignment: .leading, spacing: 11) {
                    Button { open(detail.item) } label: { Text(detail.item.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).disabled(opening)
                    ProgressView(value: Double(progress.completed), total: Double(max(1, entries.count))).tint(.accentColor)
                    Text(verbatim: String(localized: "{0} completed · {1} active").replacingOccurrences(of: "{0}", with: progress.completed.formatted()).replacingOccurrences(of: "{1}", with: progress.active.formatted())).font(.caption).foregroundStyle(.secondary)
                    if data.projectErrors[detail.item.id] != nil { Text("Refresh needed").font(.caption).foregroundStyle(.orange) }
                    if detail.more { Button("Load more tasks") { Task { do { await data.loadMoreItems(try access(), context: context, projectID: detail.item.id) } catch { data.error = HostingHubAPI.error(error) } } }.disabled(data.loading) }
                    Button("Open project schedule") { open(detail.item) }.font(.caption).disabled(opening)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    private func access() throws -> HubAccess {
        let expected = context
        if isLocal {
            return HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "local", path: "local/workspace"), token: "", apiBase: "", me: "", isCurrent: { context == expected && store.destination == .home }, local: true)
        }
        guard let account, let token = AccountStore.shared.token(for: account) else { throw HostingHubAPI.fail(String(localized: "Allow access to the saved account to use repository services.")) }
        let target = HostingHubAPI.projectTarget(repositoryScope ? store.target : nil, provider: .github, host: account.host, username: account.username, personal: effectiveScope == "personal")
        return HubAccess(target: target, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { context == expected && store.destination == .home })
    }
    private func load(append: Bool = false) async {
        guard fixture == nil, isLocal || account != nil else { return }
        do { await data.load(try access(), context: context, appendProjects: append) }
        catch { data.error = HostingHubAPI.error(error) }
    }
    private func refresh() async {
        do { if data.projects.isEmpty { await load() } else { await data.refresh(try access(), context: context) } }
        catch { data.error = HostingHubAPI.error(error) }
    }
    private func open(_ item: HubItem, rowID: String? = nil) {
        guard !opening, isLocal || account != nil else { return }
        let selectedAccount = isLocal ? nil : account?.id, selectedScope = effectiveScope, selectedSource = isLocal ? "local" : "remote", expected = context
        let request = UUID()
        navigationID = request
        opening = true
        Task {
            defer { if navigationID == request { opening = false } }
            store.hostingHub.projectSource = selectedSource
            if selectedSource == "remote" { store.hostingHub.selectedAccountID = selectedAccount }
            store.hostingHub.projectScope = selectedScope
            await store.activateHostingHub(.projects)
            guard navigationID == request, context == expected, store.destination == .home, store.hostingHub.projectSource == selectedSource, (selectedSource == "local" || store.hubAccount?.id == selectedAccount), store.hostingHub.section == .projects else { return }
            await store.selectHostingHubItem(item)
            guard navigationID == request, context == expected, store.destination == .home, store.hostingHub.projectSource == selectedSource, (selectedSource == "local" || store.hubAccount?.id == selectedAccount) else { return }
            if let rowID {
                while let detail = store.hostingHub.detail, detail.item.id == item.id, detail.more, !detail.rows.contains(where: { $0.id == rowID }), store.hostingHub.error == nil {
                    let cursor = detail.cursor, count = detail.rows.count
                    await store.selectHostingHubItem(item, append: true)
                    guard navigationID == request, context == expected, store.destination == .home, store.hostingHub.projectSource == selectedSource, (selectedSource == "local" || store.hubAccount?.id == selectedAccount) else { return }
                    if store.hostingHub.detail?.cursor == cursor && store.hostingHub.detail?.rows.count == count { break }
                }
                if store.hostingHub.detail?.rows.contains(where: { $0.id == rowID }) != true {
                    store.hostingHub.error = store.hostingHub.error ?? String(localized: "The task could not be found in this project. Refresh and try again.")
                } else { store.hostingHub.requestedProjectRowID = rowID }
            }
            store.navigate(.projects)
        }
    }
}
