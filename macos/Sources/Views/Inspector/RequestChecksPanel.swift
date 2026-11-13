import SwiftUI
import AppKit

/// A request's Checks tab, as the redesign's board draws it: failed checks open with their log, checks still running,
/// and the passed ones folded into one "Passed N" line. Windows: RequestChecksPanel.tsx.
struct RequestChecksPanel: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    let headSHA: String
    var draft = false
    /// What the Checks tab counts: failures, else checks still running, else nothing
    var onBadge: (PullRequestPage.ChecksBadge?) -> Void = { _ in }
    @ViewState private var results = RequestCheckResults()
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var refreshID = UUID()
    @ViewState private var logs: [String: WorkspaceCILog.Result] = [:]
    /// Each loaded log as it is drawn: numbered lines and the tests it names
    @ViewState private var readings: [String: JobLog.Reading] = [:]
    @ViewState private var logErrors: [String: String] = [:]
    @ViewState private var loadingLogs = Set<String>()
    @ViewState private var failedOpen = true
    @ViewState private var passedOpen = false
    @ViewState private var runningOpen = true
    @ViewState private var rerunning = Set<String>()
    /// Counts "Jump to first error" presses per check, so its log scrolls each time
    @ViewState private var jumps: [String: Int] = [:]
    private var context: String { "\(store.collaboration.contextID):\(store.hostingAccount?.id ?? ""): \(number):\(headSHA)" }

    var body: some View {
        let groups = PullRequestPage.checkGroups(results.checks)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading
                if let error { Label(error, symbol: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
                ForEach(results.warnings, id: \.self) { warning in
                    Label(warning, symbol: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).textSelection(.enabled)
                }
                if !loading && results.checks.isEmpty && error == nil && results.warnings.isEmpty {
                    PullRequestCaption(String(localized: "No checks reported for this commit."))
                }
                if !groups.failed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        // the Checks tab already counts the failures
                        CheckGroupHead(title: String(localized: "Failed"), open: $failedOpen)
                        if failedOpen { ForEach(groups.failed) { failedCard($0) } }
                    }
                }
                if !groups.running.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        // the tab counts what still runs only while nothing failed
                        CheckGroupHead(title: String(localized: "Running"), count: groups.failed.isEmpty ? nil : groups.running.count, open: $runningOpen)
                        if runningOpen { rows(groups.running) }
                    }
                }
                if !groups.passed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        // "Passed 5" and the names on one line: what passed needs no rows until someone asks
                        CheckGroupHead(title: String(localized: "Passed"), count: groups.passed.count, open: $passedOpen) {
                            if !passedOpen {
                                SymbolIcon("checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.passed.text)
                                Text(verbatim: groups.passed.map(\.name).joined(separator: " · ")).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        if passedOpen { rows(groups.passed) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: results.checks.map(\.status), initial: true) { _, _ in onBadge(PullRequestPage.checksBadge(results.checks)) }
        .task(id: context + refreshID.uuidString) {
            results = RequestCheckResults(); logs = [:]; readings = [:]; logErrors = [:]; loadingLogs = []; loading = false; error = nil
            repeat {
                await load()
                // the failed check opens with its log; one job, so opening the tab stays one extra read
                if let first = PullRequestPage.checkGroups(results.checks).failed.first(where: { $0.jobID != nil }), logs[first.id] == nil, logErrors[first.id] == nil {
                    await loadLog(first)
                }
                guard results.checks.contains(where: { $0.status.isActive }), !Task.isCancelled else { break }
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            } while !Task.isCancelled
        }
    }

    // MARK: Parts

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Checks").font(.system(size: 15, weight: .semibold))
                Text(String(headSHA.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).textSelection(.enabled)
                Spacer(minLength: 8)
                if loading { ProgressView().controlSize(.small) }
                Button { refreshID = UUID() } label: { DesignIconImage(icon: .refresh) }
                    .buttonStyle(PullRequestIconButtonStyle()).help("Refresh checks").accessibilityLabel("Refresh checks").disabled(loading)
            }
            if draft { PullRequestCaption(String(localized: "Draft requests cannot be merged.")) }
        }
    }

    /// The log of a check as it is drawn, read once when it arrives
    private func reading(_ check: RequestCheck) -> JobLog.Reading? {
        readings[check.id] ?? logs[check.id].map { JobLog.Reading(log: $0.body) }
    }

    /// A failed check is the shared block: what failed and after how long, the ways to act on it, and its log below
    private func failedCard(_ check: RequestCheck) -> some View {
        let log = logs[check.id], reading = reading(check)
        var actions = FailedCheckActions()
        if let reading, JobLog.firstError(reading.lines) != nil { actions.jump = { jumps[check.id, default: 0] += 1 } }
        if check.jobID != nil {
            actions.rerun = (String(localized: "Re-run job"), rerunning.contains(check.id), { Task { await rerun(check) } })
            actions.menu = true
            if let log { actions.copy = { store.copy(log.body) } }
            actions.more = [CheckMenuItem(title: log == nil ? String(localized: "Load log") : String(localized: "Refresh log"), disabled: loadingLogs.contains(check.id)) { Task { await loadLog(check) } }]
        }
        if let url = safeURL(check.url) { actions.open = { NSWorkspace.shared.open(url) } }
        // "Failed after 3m 12s" where the server says how long the check ran, else its state
        let outcome = check.duration.flatMap { $0 > 0 ? String(localized: "Failed after \(ciDuration($0))") : nil } ?? check.status.title
        return FailedCheckBlock(form: .card, name: check.name, outcome: outcome, tests: reading?.tests ?? [], caption: check.detail,
                                busy: loadingLogs.contains(check.id) || rerunning.contains(check.id), actions: actions) {
            CIStatusIcon(status: check.status, size: 14)
        } content: {
            if !check.output.isEmpty {
                DisclosureGroup("Details") { MarkdownView(check.output, target: store.target).padding(.top, 6) }
                    .font(.system(size: 12)).padding(.leading, 34).padding(.trailing, 12).padding(.bottom, 10)
            }
            self.log(check)
        }
    }

    private func rows(_ checks: [RequestCheck]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) { title(check); Spacer(minLength: 8); actions(check) }
                        if !check.detail.isEmpty { PullRequestCaption(check.detail).textSelection(.enabled).padding(.leading, 22) }
                        if !check.output.isEmpty {
                            DisclosureGroup("Details") { MarkdownView(check.output, target: store.target).padding(.top, 6) }.font(.system(size: 12)).padding(.leading, 22)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    log(check)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
    }

    /// Icon, job name and, for anything not passed, its status in words: colour is never the only sign
    private func title(_ check: RequestCheck) -> some View {
        HStack(spacing: 8) {
            CIStatusIcon(status: check.status, size: 14)
            Text(check.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            if check.status != .success {
                Text(check.status.title).font(.system(size: 12)).foregroundStyle(check.status == .failed ? StudioStyle.Tone.failed.text : StudioStyle.Rail.icon).fixedSize()
            }
        }
    }

    /// What a check that did not fail offers: its log on request, its page, and what to do with a loaded log
    private func actions(_ check: RequestCheck) -> some View {
        let log = logs[check.id]
        return HStack(spacing: 6) {
            if loadingLogs.contains(check.id) { ProgressView().controlSize(.small) }
            if check.jobID != nil, log == nil {
                Button("Load log") { Task { await loadLog(check) } }.buttonStyle(PullRequestTextButtonStyle()).disabled(loadingLogs.contains(check.id))
            }
            if let url = safeURL(check.url) {
                Button { NSWorkspace.shared.open(url) } label: { DesignIconImage(icon: .external) }
                    .buttonStyle(PullRequestButtonStyle(iconOnly: true))
                    .help("Open check result").accessibilityLabel("Open check result")
            }
            if check.jobID != nil, let log {
                Menu {
                    Button("Copy log") { store.copy(log.body) }
                    Button("Refresh log") { Task { await loadLog(check) } }.disabled(loadingLogs.contains(check.id))
                } label: {
                    DesignIconImage(icon: .more, size: 12).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More job actions").accessibilityLabel("More job actions")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func log(_ check: RequestCheck) -> some View {
        if let log = logs[check.id], let reading = reading(check) {
            Divider()
            CheckLog(label: check.name + " · " + String(localized: "Job log"), lines: reading.lines, jump: jumps[check.id] ?? 0, truncated: log.truncated)
        }
        if let error = logErrors[check.id] {
            Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled).padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    // MARK: Loading

    private func isCurrent(_ expected: String) -> Bool {
        context == expected && store.selection == .pullRequest(number)
            && store.pullRequests.first(where: { $0.number == number })?.headSHA == headSHA
    }
    private func safeURL(_ raw: String) -> URL? {
        guard let u = URL(string: raw), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil else { return nil }; return u
    }
    @MainActor private func load() async {
        let expected = context
        guard !headSHA.isEmpty else { return }
        loading = true; error = nil
        defer { if isCurrent(expected) { loading = false } }
        let access = await store.resolveCollaborationAccess()
        guard isCurrent(expected), !Task.isCancelled else { return }
        guard var c = access else {
            error = store.hostingAccount.map { AccountStore.shared.savedAccessMessage(for: $0) }
                ?? String(localized: "Connect an account to load checks.")
            return
        }
        c.isCurrent = { isCurrent(expected) }
        do {
            let value = try await RequestChecksAPI.load(c, number: number, headSHA: headSHA)
            if isCurrent(expected) && !Task.isCancelled { results = value }
        } catch is CancellationError {} catch { if isCurrent(expected) && !Task.isCancelled { self.error = WorkspaceCILog.redact(error.localizedDescription, token: c.token) } }
    }
    /// A job of another project (a GitLab downstream pipeline) is read and restarted there
    private func jobTarget(_ check: RequestCheck, _ original: ReviewAccess) -> RepoTarget {
        check.logProjectID.map { RepoTarget(provider: original.target.provider, remote: original.target.remote, host: original.target.host, path: String($0)) } ?? original.target
    }
    @MainActor private func loadLog(_ check: RequestCheck) async {
        let expected = context
        guard let job = check.jobID, let original = store.collaborationAccess else { return }
        var c = ReviewAccess(target: jobTarget(check, original), token: original.token, apiBase: original.apiBase, me: original.me)
        c.isCurrent = { isCurrent(expected) }
        loadingLogs.insert(check.id); logErrors[check.id] = nil
        defer { if isCurrent(expected) { loadingLogs.remove(check.id) } }
        do {
            let log = try await WorkspaceCILog.load(c, job: job)
            if isCurrent(expected) { logs[check.id] = log; readings[check.id] = JobLog.Reading(log: log.body) }
        } catch is CancellationError {} catch { if isCurrent(expected) { logErrors[check.id] = WorkspaceCILog.redact(error.localizedDescription, token: c.token) } }
    }
    /// Restarts the job with the call the Actions page uses, then reads the checks again
    @MainActor private func rerun(_ check: RequestCheck) async {
        let expected = context
        guard let job = check.jobID, let original = store.collaborationAccess, !rerunning.contains(check.id) else { return }
        let target = jobTarget(check, original)
        rerunning.insert(check.id)
        defer { if isCurrent(expected) { rerunning.remove(check.id) } }
        do {
            try await CIAPI.retry(target, token: original.token, apiBase: original.apiBase, job: job)
            if isCurrent(expected) { refreshID = UUID() }
        } catch { if isCurrent(expected) { store.errorMessage = store.ciError(error, target.provider) } }
    }
}
