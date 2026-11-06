import SwiftUI
import AppKit

/// Settings › Ledger: the rules the ledger core keeps in its database (when a session is stale, what each kind of
/// session means, where a project's baselines come from), its backups, and the ways in: Connect agents and Import.
/// Changes are saved as they are made. Track agents I start, notifications and the Dock badge are this app's choices
/// (UserDefaults), each off until a person turns it on; auto-continue per repository lives in the ledger's `autoContinue`
/// setting, where `track` reads it. (Windows: widgets/settings/ui/LedgerSettings.tsx)
struct LedgerSettings: View {
    static var isShown: Bool { true }

    enum Sheet: String, Identifiable {
        case connect, importReports, browser
        var id: String { rawValue }
    }

    var ledger: LedgerStore = .shared
    @ViewState private var info: LedgerInfo?
    @ViewState private var settings: LedgerGlobalSettings?
    @ViewState private var projects: [LedgerProjectSettings] = []
    /// Kinds the ledger's sessions use, so kinds without a rule can be listed
    @ViewState private var usedKinds: [String] = []
    @ViewState private var loadError: String?
    @ViewState private var error: String?
    @ViewState private var staleHours = 72.0
    @ViewState private var backupKeep = 14
    @ViewState private var newKind = ""
    @ViewState private var newRole: LedgerRole = .other
    @ViewState private var projectKey: String?
    @ViewState private var scanNotice: String?
    @ViewState private var backupNotice: String?
    /// Backups and safety copies `restore` can use, newest first
    @ViewState private var backupFiles: [LedgerBackupFile] = []
    @ViewState private var showAllBackups = false
    /// The backup waiting for the person's confirmation
    @ViewState private var restoreCandidate: LedgerBackupFile?
    /// The backup being restored
    @ViewState private var restoringPath: String?
    @ViewState private var restoreNotice: String?
    @ViewState private var working = false
    @ViewState private var sheet: Sheet?
    @ViewState private var generation = 0
    /// Saves run one after another, so quick changes reach the database in the order they were made
    @ViewState private var saving: Task<Void, Never>?
    @ViewState private var saveCount = 0
    @AppStorage(LedgerTracking.trackKey) private var trackAgents = false
    @AppStorage(LedgerTracking.toolsKey) private var agentTools = true
    @AppStorage(LedgerNotifier.notifyKey) private var notify = false
    @AppStorage(LedgerNotifier.badgeKey) private var dockBadge = false
    /// macOS refused notifications when they were turned on
    @ViewState private var notificationsBlocked = false
    var hubSharing: LedgerHubSharing = .shared
    @AppStorage(LedgerHubSharing.enabledKey) private var shareWithHub = false
    /// The hub connected under Work validation › Team overlap evidence
    @AppStorage(LedgerHubSharing.endpointKey) private var hubEndpoint = ""
    /// The repository whose auto-continue switch is shown
    @ViewState private var autoRepository: String?

    var body: some View {
        Form {
            if let settings {
                trackingSection
                wakeSection(settings)
                autoContinueSection(settings)
                notificationsSection
                hubSection
                sessionsSection
                kindsSection(settings)
                projectsSection
                backupsSection
                restoreSection
                connectionsSection
                connectSection
            } else if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red).textSelection(.enabled)
                    Button("Try again") { generation += 1 }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .task(id: generation) { await load() }
        .sheet(item: $sheet, onDismiss: { generation += 1 }) { sheet in
            switch sheet {
            case .connect: LedgerConnectSheet(ledger: ledger, openBrowser: { switchSheet(to: .browser) })
            case .browser: LedgerBrowserSheet(ledger: ledger)
            case .importReports: LedgerImportSheet(ledger: ledger)
            }
        }
        .alert("The ledger did not take the change", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .alert("Restore this backup?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }),
               presenting: restoreCandidate) { file in
            Button("Restore", role: .destructive) { restore(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("The ledger is replaced with the backup from \(Self.backupTime(file)). Its current state is kept first as a Before restore copy in the backups folder, so you can restore it again. Agents that are still running keep writing to the restored ledger, and reports sent during the restore can be lost.")
        }
    }

    // MARK: - Sections

    private var trackingSection: some View {
        Section {
            Toggle("Track agents I start", isOn: $trackAgents)
                .onChange(of: trackAgents) { _, _ in LedgerHeartbeat.shared.refresh() }
            Toggle("Give them the Ledger tools", isOn: $agentTools).disabled(!trackAgents)
        } header: {
            Text("Agents Gitrochi starts")
        } footer: {
            Text("Claude Code agents started from Gitrochi get a ledger session before they start, and their activity is recorded: times and IDs, never what anyone types. The Ledger tools let them report to it; they are left out when Claude Code already has a server named gitrochi-ledger.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Wake waiting agents with my answers (DESIGN.md §7.6): kept in the ledger's `wakeAgents` setting, which the agents'
    /// Stop hooks read, so it applies to tracked agents already running too. Off until a person turns it on.
    private func wakeSection(_ settings: LedgerGlobalSettings) -> some View {
        let wake = settings.wake
        return Section {
            Toggle("Wake waiting agents with my answers", isOn: Binding(get: { wake.enabled }, set: { setWake(.init(enabled: $0, waitSec: wake.waitSec)) }))
            LabeledContent("Wait") {
                LedgerWaitPicker(seconds: wake.waitSec) { setWake(.init(enabled: wake.enabled, waitSec: $0)) }
                    .labelsHidden()
            }
            .disabled(!wake.enabled)
        } header: {
            Text("Delivering answers")
        } footer: {
            Text("After an agent you started ends its turn, it keeps listening for this long. An answer or message you send its session in the Ledger then reaches it at once, instead of with its next report.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func setWake(_ wake: LedgerGlobalSettings.WakeAgents) {
        settings?.wakeAgents = wake
        save(["wakeAgents": .object(["enabled": .bool(wake.enabled), "waitSec": .number(Double(LedgerWait.clamped(wake.waitSec)))])])
    }

    private func autoContinueSection(_ settings: LedgerGlobalSettings) -> some View {
        let repositories = Self.repositories(settings)
        let selected = autoRepository.flatMap { repositories.contains($0) ? $0 : nil } ?? repositories.first
        return Section {
            if let selected {
                Picker("Repository", selection: Binding(get: { selected }, set: { autoRepository = $0 })) {
                    ForEach(repositories, id: \.self) { path in Text(verbatim: (path as NSString).lastPathComponent).tag(path) }
                }
                .help(selected)
                let policy = settings.autoContinue(forRepository: selected)
                    ?? .init(enabled: false, delaySec: settings.autoContinueDefault.delaySec)
                Toggle("Continue automatically when nobody answers", isOn: Binding(get: { policy.enabled }, set: { on in
                    setAutoContinue(selected, .init(enabled: on, delaySec: policy.delaySec))
                }))
                LabeledContent("Wait") {
                    LedgerWaitPicker(seconds: policy.delaySec) { seconds in
                        setAutoContinue(selected, .init(enabled: policy.enabled, delaySec: seconds))
                    }
                    .labelsHidden()
                }
            } else {
                Text("Open a repository to set auto-continue for it.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Auto-continue")
        } footer: {
            Text("When an agent started in the repository asks you something and nobody answers in time, Gitrochi answers with the agent's recommended option, at most three times in a row. It never answers decision sessions or allows risky commands, and each answer waits in the Inbox for review. It applies to agents started afterwards, with Track agents I start on.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Show notifications", isOn: Binding(get: { notify }, set: { setNotifications($0) }))
            Toggle("Show the Inbox count on the Dock icon", isOn: Binding(get: { dockBadge }, set: { on in
                dockBadge = on
                LedgerNotifier.shared.refresh()
            }))
            if notificationsBlocked {
                HStack {
                    Text("Notifications for Gitrochi are turned off in System Settings.").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("New questions, sessions to clean up and applied reports, grouped per read; every waiting prompt with the time left, and every automatic answer. Clicking one opens the Ledger at its session. Nothing is announced for what is already there when Gitrochi starts.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Sharing this computer's sessions with the team hub (DESIGN.md §14 D4): off until a person turns it on, with what is
    /// shared spelled out next to the switch and the hub's state as one quiet line
    private var hubSection: some View {
        Section {
            Toggle("Share this computer's Ledger sessions with the team hub", isOn: Binding(get: { shareWithHub }, set: { on in
                shareWithHub = on
                Task { await hubSharing.setOn(on) }
            }))
            .disabled(hubEndpoint.isEmpty && !shareWithHub)
            if hubEndpoint.isEmpty {
                Text("Connect a team hub under Work validation › Team overlap evidence first.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if shareWithHub, let line = hubStatusText(hubSharing.status) {
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What is shared").font(.system(size: 12, weight: .semibold))
                Text("Each active session's ID, project, title, kind and role, branch, verdict, touches and last activity, under its repository's remote. Never questions, answers, reports, messages, notes, the notebook, documents, chat links or folder paths. Streams and archived sessions stay on this computer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Team hub")
        } footer: {
            Text("Turning this off withdraws your sessions; anything left expires on the hub within minutes. Overlaps with other members' sessions show in the inspector's Touches.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func hubStatusText(_ status: LedgerHubSharing.Status) -> String? {
        switch status {
        case .off: return nil
        case .demo: return String(localized: "Demo data is never shared.")
        case .noHub: return String(localized: "Connect a team hub under Work validation › Team overlap evidence first.")
        case .connecting(let host): return String(localized: "Connecting to \(host)…")
        case .unreachable(let host): return String(localized: "Couldn't reach \(host). Gitrochi tries again later.")
        case .rejected(let host):
            return String(localized: "The hub token for \(host) was not accepted or could not be read. Connect again under Work validation › Team overlap evidence.")
        case .sharing(let host, let count, let unshared, let plain):
            var lines = [String(localized: "Sessions shared with \(host): \(count)")]
            if unshared > 0 { lines.append(String(localized: "Kept on this computer, no repository remote: \(unshared)")) }
            if plain { lines.append(String(localized: "This hub keeps branches and touches only; titles and verdicts need a newer hub.")) }
            return lines.joined(separator: "\n")
        }
    }

    /// Asks macOS for permission only now, when a person turns notifications on
    private func setNotifications(_ on: Bool) {
        guard on else {
            notify = false
            notificationsBlocked = false
            return
        }
        Task {
            let allowed = await LedgerNotifier.shared.requestPermission()
            notify = allowed
            notificationsBlocked = !allowed
            LedgerNotifier.shared.refresh()
        }
    }

    /// The open repositories, then the ones that already have a setting
    private static func repositories(_ settings: LedgerGlobalSettings) -> [String] {
        let open = Workspace.shared.openRepositories.compactMap { $0.url?.path }
        let stored = (settings.autoContinue?["repositories"].object?.keys).map(Array.init) ?? []
        var seen = Set<String>()
        return (open + stored.sorted()).filter { seen.insert($0).inserted }
    }

    private func setAutoContinue(_ repository: String, _ policy: LedgerSession.AutoContinue) {
        guard let settings else { return }
        let value = settings.autoContinueArgument(repository: repository, policy)
        self.settings?.autoContinue = value
        save(["autoContinue": value])
    }

    private var sessionsSection: some View {
        Section {
            LabeledContent("Stale after") {
                HStack(spacing: 6) {
                    TextField("Stale after", value: staleBinding, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                    Stepper("Stale after", value: staleBinding, in: 1...10_000).labelsHidden()
                    Text("hours")
                }
            }
        } header: {
            Text("Sessions")
        } footer: {
            Text("A session with no agent activity for this long is marked Stale. Still active puts that off for the same time.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func kindsSection(_ settings: LedgerGlobalSettings) -> some View {
        Section {
            ForEach(settings.kinds.keys.sorted() + settings.unassignedKinds(among: usedKinds), id: \.self) { kind in
                kindRow(kind, settings.kinds[kind])
            }
            HStack(spacing: 8) {
                TextField("New kind", text: $newKind, prompt: Text("New kind"))
                    .labelsHidden()
                    .onSubmit { addKind() }
                Picker("Role", selection: $newRole) {
                    ForEach(LedgerRole.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Button("Add") { addKind() }.disabled(!canAdd)
            }
            Button("Restore the default roles") { save(["kinds": .null]) }
        } header: {
            Text("Roles and stream lines")
        } footer: {
            Text("A session's kind decides its role. Implementation sessions report in cycles on a stream line; on a line that hands off, syncing to or applying a version also moves the decision session that released it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func kindRow(_ kind: String, _ rule: LedgerGlobalSettings.KindRule?) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: kind)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let rule, rule.role == .implementation {
                CommitField(title: "Line", value: rule.line ?? "core", inline: true, width: 72) { line in
                    setKind(kind, .init(role: .implementation, line: line.isEmpty ? "core" : line, handoff: rule.handoff ?? true))
                }
                .help("The stream line sessions of this kind report on")
                Toggle("Hands off", isOn: Binding(get: { rule.handoff ?? true }, set: { setKind(kind, .init(role: .implementation, line: rule.line, handoff: $0)) }))
                    .toggleStyle(.checkbox)
                    .help("Syncing to or applying a version also moves the decision session that released it")
            }
            Picker("Role", selection: Binding<LedgerRole?>(get: { rule?.role }, set: { role in
                guard let role else { return }
                setKind(kind, role == .implementation ? .init(role: role, line: rule?.line ?? "core", handoff: rule?.handoff ?? true) : .init(role: role))
            })) {
                if rule == nil { Text("No role yet").tag(LedgerRole?.none) }
                ForEach(LedgerRole.allCases, id: \.self) { Text($0.title).tag(LedgerRole?.some($0)) }
            }
            .labelsHidden().fixedSize()
            .help(rule == nil ? Text("Sessions of this kind count as Other until it has a role") : Text("The role of sessions of this kind"))
            Button { setKind(kind, nil) } label: { SymbolIcon("minus.circle") }
                .buttonStyle(.borderless)
                .disabled(rule == nil)
                .help("Remove this kind's rule")
                .accessibilityLabel("Remove this kind's rule")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: kind))
    }

    private var projectsSection: some View {
        Section {
            if projects.isEmpty {
                Text("Projects appear here with their first report.").foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $projectKey) {
                    ForEach(projects) { p in Text(verbatim: p.name == p.key ? p.key : "\(p.name) · \(p.key)").tag(Optional(p.key)) }
                }
                if let project = projects.first(where: { $0.key == projectKey }) { projectFields(project) }
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Baselines are the versions sessions start from. Git tags are read from the repository, folder names from the folder and the sub-folders listed (not deeper). The pattern is a regular expression whose first group is the version.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func projectFields(_ p: LedgerProjectSettings) -> some View {
        CommitField(title: "Name", value: p.name) { saveProject(p.key, ["name": $0.isEmpty ? .null : .string($0)]) }
        LabeledContent("Repository") {
            pathControl(p.repoPath) { saveProject(p.key, ["repoPath": $0.map { .string($0) } ?? .null]) }
        }
        .help("The repository whose tags are this project's baselines")
        Picker("Baselines from", selection: Binding(get: { p.baselineSource }, set: { saveProject(p.key, ["baselineSource": .string($0.rawValue)]) })) {
            ForEach(LedgerProjectSettings.Source.allCases) { Text($0.title).tag($0) }
        }
        if p.baselineSource != .manual {
            CommitField(title: "Version pattern", value: p.baselinePattern, monospaced: true) {
                saveProject(p.key, ["baselinePattern": $0.isEmpty ? .null : .string($0)])
            }
        }
        if p.baselineSource == .folder {
            LabeledContent("Folder") {
                pathControl(p.baselineDir) { saveProject(p.key, ["baselineDir": $0.map { .string($0) } ?? .null]) }
            }
            Toggle("Also read file names", isOn: Binding(get: { p.scanFiles }, set: { saveProject(p.key, ["scanFiles": .bool($0)]) }))
            CommitField(title: "Sub-folders", value: p.scanSubdirs.joined(separator: ", ")) { text in
                let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                saveProject(p.key, ["scanSubdirs": .array(names.map { .string($0) })])
            }
        }
        HStack {
            Button("Scan now") { scan(p.key) }.disabled(working)
            if let scanNotice { Text(scanNotice).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private var backupsSection: some View {
        Section {
            Stepper(value: Binding(get: { backupKeep }, set: { value in
                backupKeep = value
                if value != settings?.backupKeep { save(["backupKeep": .number(Double(value))]) }
            }), in: 1...365) {
                Text("Keep the newest \(backupKeep) backups")
            }
            HStack {
                Button("Back up now") { backUp() }.disabled(working)
                Button("Show in Finder") { showBackups() }
                    .disabled(info.map { !FileManager.default.fileExists(atPath: $0.dbPath) } ?? true)
                if working { ProgressView().controlSize(.small) }
            }
            if let backupNotice { Text(backupNotice).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            if let info {
                LabeledContent("Database") {
                    Text(verbatim: info.dbPath).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            Text("Back up now copies the ledger's database into the backups folder next to it. Only the newest are kept, and only files named like a backup are ever removed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Daily backups are checked while Gitrochi follows the Ledger. Failed attempts retry after five minutes.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var restoreSection: some View {
        Section {
            if backupFiles.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
            } else {
                ForEach(showAllBackups ? backupFiles : Array(backupFiles.prefix(5))) { backupRow($0) }
                if backupFiles.count > 5 {
                    Button { showAllBackups.toggle() } label: {
                        showAllBackups ? Text("Show less") : Text("Show all \(backupFiles.count) backups")
                    }
                    .buttonStyle(.link)
                }
            }
            if ledger.isDemo {
                Text("Restore is not available on demo data.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let restoreNotice { Text(restoreNotice).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
        } header: {
            Text("Restore a backup")
        } footer: {
            Text("Restoring checks the backup first and keeps the current ledger as a Before restore copy, which is never removed automatically. Agents that are running keep writing to the restored ledger.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func backupRow(_ file: LedgerBackupFile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.backupTime(file)).font(.system(size: 13))
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if file.kind == .safety {
                StatusPill(title: String(localized: "Before restore"), symbol: "arrow.uturn.backward", tone: .neutral)
            }
            Spacer(minLength: 8)
            if restoringPath == file.path { ProgressView().controlSize(.small) }
            Button("Restore…") { restoreCandidate = file }
                .disabled(ledger.isDemo || restoringPath != nil)
        }
        .help(file.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.backupTime(file)))
    }

    private static func backupTime(_ file: LedgerBackupFile) -> String {
        Date(timeIntervalSince1970: Double(file.modifiedAt) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    /// Claude Code, Codex and the browser extension, each with whether its data reaches this Ledger
    private var connectionsSection: some View {
        Section {
            LedgerConnectionsSection(ledger: ledger, openBrowser: { sheet = .browser })
        } header: {
            Text("Connections")
        } footer: {
            Text("Hooks run a stable copy of the Ledger command that Gitrochi keeps up to date, so they keep working when the app moves or updates. Gitrochi never edits MCP settings; copy the MCP command and run it yourself.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func switchSheet(to destination: Sheet) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { sheet = destination }
    }

    private var connectSection: some View {
        Section {
            HStack {
                Button("Connect agents…") { sheet = .connect }
                Button("ChatGPT browser extension") { sheet = .browser }
                Button("Import…") { sheet = .importReports }
            }
        } header: {
            Text("Connect and import")
        } footer: {
            Text("Connect agents to let them report here. Import reads pasted reports or a claude-ledger database.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func pathControl(_ path: String?, set: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 6) {
            if let path {
                Text(verbatim: path).lineLimit(1).truncationMode(.head)
            } else {
                Text("Not set").foregroundStyle(.secondary)
            }
            Button("Choose…") { if let folder = Self.chooseFolder(start: path) { set(folder) } }
            if path != nil {
                Button { set(nil) } label: { SymbolIcon("xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Clear")
                    .accessibilityLabel("Clear")
            }
        }
    }

    // MARK: - Reading and saving

    private var staleBinding: Binding<Double> {
        Binding(get: { staleHours }, set: { value in
            let hours = min(max(value, 1), 10_000)
            staleHours = hours
            if hours != settings?.staleHours { save(["staleHours": .number(hours)]) }
        })
    }

    private var canAdd: Bool {
        let name = newKind.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && settings?.kinds[name] == nil
    }

    private func load() async {
        do {
            let info = try await ledger.info()
            let settings = try await ledger.settings()
            let projects = try await ledger.projectSettings()
            let sessions = try await ledger.client.state(project: nil, range: .all).sessions
            backupFiles = (try? await ledger.backups()) ?? []
            self.info = info
            show(settings)
            self.projects = projects
            usedKinds = Array(Set(sessions.map(\.kind)))
            if projectKey == nil || !projects.contains(where: { $0.key == projectKey }) {
                projectKey = projects.first { $0.key == ledger.project }?.key ?? projects.first?.key
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func show(_ value: LedgerGlobalSettings) {
        settings = value
        staleHours = value.staleHours
        backupKeep = value.backupKeep
    }

    /// Only the newest save's answer is shown, so a slower earlier one never puts an older value back
    private func save(_ values: [String: LedgerJSON]) {
        saveCount += 1
        let mine = saveCount, previous = saving
        saving = Task {
            await previous?.value
            do {
                let saved = try await ledger.saveSettings(values)
                if mine == saveCount { show(saved) }
            } catch {
                self.error = error.localizedDescription
                if mine == saveCount, let stored = try? await ledger.settings() { show(stored) }
            }
        }
    }

    private func setKind(_ kind: String, _ rule: LedgerGlobalSettings.KindRule?) {
        guard var kinds = settings?.kinds else { return }
        kinds[kind] = rule
        settings?.kinds = kinds
        save(["kinds": LedgerGlobalSettings.kindsArgument(kinds)])
    }

    private func addKind() {
        guard canAdd else { return }
        let name = newKind.trimmingCharacters(in: .whitespaces)
        setKind(name, newRole == .implementation ? .init(role: .implementation, line: "core", handoff: true) : .init(role: newRole))
        newKind = ""
        newRole = .other
    }

    private func saveProject(_ key: String, _ values: [String: LedgerJSON]) {
        let previous = saving
        saving = Task {
            await previous?.value
            do {
                let saved = try await ledger.saveProject(key, values)
                if let i = projects.firstIndex(where: { $0.key == key }) { projects[i] = saved }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func scan(_ key: String) {
        working = true
        scanNotice = nil
        Task {
            do {
                if let result = try await ledger.scan(project: key).first {
                    if let failure = result.error {
                        error = failure
                    } else {
                        scanNotice = String(localized: "Found \(result.found) baselines, \(result.added) new")
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func backUp() {
        working = true
        backupNotice = nil
        Task {
            do {
                let path = try await ledger.backup()
                backupNotice = String(localized: "Backed up to \(path)")
                backupFiles = (try? await ledger.backups()) ?? backupFiles
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    /// Restores after the person confirmed; the whole page reads again, since the restored ledger has its own settings
    private func restore(_ file: LedgerBackupFile) {
        restoringPath = file.path
        restoreNotice = nil
        Task {
            do {
                let result = try await ledger.restore(file)
                let kept = result.safety.map { ($0.path as NSString).lastPathComponent } ?? ""
                restoreNotice = String(localized: "Restored the backup from \(Self.backupTime(file)). The previous ledger is kept as \(kept).")
                generation += 1
            } catch {
                self.error = error.localizedDescription
            }
            restoringPath = nil
        }
    }

    /// Selects the newest backup in Finder, or the database while there is none
    private func showBackups() {
        guard let info else { return }
        let database = URL(fileURLWithPath: info.dbPath)
        let folder = database.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let newest = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "sqlite3" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        NSWorkspace.shared.activateFileViewerSelecting([newest ?? database])
    }

    private static func chooseFolder(start: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// A text field that saves when Return is pressed or it loses focus, not on every key
private struct CommitField: View {
    let title: LocalizedStringKey
    let value: String
    var monospaced = false
    /// In a row of other controls: the title becomes the placeholder
    var inline = false
    var width: CGFloat?
    let commit: (String) -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if inline {
            input.labelsHidden()
        } else if monospaced {
            // only the value is monospaced, not its label
            LabeledContent(title) { input.labelsHidden().multilineTextAlignment(.trailing) }
        } else {
            input
        }
    }

    private var input: some View {
        TextField(title, text: $text, prompt: inline ? Text(title) : nil)
            .font(monospaced ? .system(.callout, design: .monospaced) : nil)
            .frame(width: width)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, now in if !now { send() } }
            .onSubmit { send() }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value { commit(trimmed) }
    }
}

private extension LedgerProjectSettings.Source {
    var title: String {
        switch self {
        case .tags: return String(localized: "Git tags")
        case .folder: return String(localized: "Folder names")
        case .manual: return String(localized: "Releases and registrations only")
        }
    }
}
