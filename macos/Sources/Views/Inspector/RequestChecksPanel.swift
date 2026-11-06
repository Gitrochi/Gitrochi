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
                        groupButton(String(localized: "Failed"), open: $failedOpen)
                        if failedOpen { ForEach(groups.failed) { failedCard($0) } }
                    }
                }
                if !groups.running.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        groupButton(String(localized: "Running"), open: $runningOpen)
                        if runningOpen { rows(groups.running) }
                    }
                }
                if !groups.passed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        passedButton(groups.passed)
                        if passedOpen { rows(groups.passed) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: results.checks.map(\.status), initial: true) { _, _ in onBadge(PullRequestPage.checksBadge(results.checks)) }
        .task(id: context + refreshID.uuidString) {
            results = RequestCheckResults(); logs = [:]; logErrors = [:]; loadingLogs = []; loading = false; error = nil
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

    private func groupButton(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                SymbolIcon(open.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                Text(verbatim: title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
            .frame(minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Passed 5" and the names on one line: what passed needs no rows until someone asks
    private func passedButton(_ checks: [RequestCheck]) -> some View {
        Button { passedOpen.toggle() } label: {
            HStack(spacing: 6) {
                SymbolIcon(passedOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                Text(verbatim: String(localized: "Passed") + " \(checks.count)").fixedSize()
                SymbolIcon("checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.passed.text)
                Text(verbatim: checks.map(\.name).joined(separator: " · ")).font(.system(size: 11, design: .monospaced)).fontWeight(.regular).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
            .frame(minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func failedCard(_ check: RequestCheck) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { title(check); Spacer(minLength: 8); actions(check, failed: true) }
                    VStack(alignment: .leading, spacing: 6) { title(check); actions(check, failed: true) }
                }
                if !check.detail.isEmpty { PullRequestCaption(check.detail).textSelection(.enabled).padding(.leading, 22) }
                if !check.output.isEmpty {
                    DisclosureGroup("Details") { MarkdownView(check.output, target: store.target).padding(.top, 6) }.font(.system(size: 12)).padding(.leading, 22)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            log(check)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
    }

    private func rows(_ checks: [RequestCheck]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) { title(check); Spacer(minLength: 8); actions(check, failed: false) }
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

    private func actions(_ check: RequestCheck, failed: Bool) -> some View {
        let log = logs[check.id]
        return HStack(spacing: 6) {
            if loadingLogs.contains(check.id) || rerunning.contains(check.id) { ProgressView().controlSize(.small) }
            if failed {
                if let log, PullRequestPage.firstError(PullRequestPage.logLines(log.body)) != nil {
                    Button("Jump to first error") { jumps[check.id, default: 0] += 1 }.buttonStyle(PullRequestButtonStyle())
                }
                if check.jobID != nil {
                    Button { Task { await rerun(check) } } label: { Label("Re-run job", symbol: "arrow.clockwise") }
                        .buttonStyle(PullRequestButtonStyle()).disabled(rerunning.contains(check.id))
                }
            } else if check.jobID != nil, log == nil {
                Button("Load log") { Task { await loadLog(check) } }.buttonStyle(PullRequestTextButtonStyle()).disabled(loadingLogs.contains(check.id))
            }
            if let url = safeURL(check.url) {
                Button { NSWorkspace.shared.open(url) } label: { DesignIconImage(icon: .external) }
                    .buttonStyle(PullRequestButtonStyle(iconOnly: true))
                    .help("Open check result").accessibilityLabel("Open check result")
            }
            if check.jobID != nil, failed || log != nil {
                Menu {
                    if let log { Button("Copy log") { store.copy(log.body) } }
                    Button(log == nil ? String(localized: "Load log") : String(localized: "Refresh log")) { Task { await loadLog(check) } }
                        .disabled(loadingLogs.contains(check.id))
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
        if let log = logs[check.id] {
            Divider()
            RequestCheckLog(log: log, jump: jumps[check.id] ?? 0)
            if log.truncated {
                PullRequestCaption(String(localized: "Log truncated. Open the job in the browser for the full output.")).padding(.horizontal, 16).padding(.vertical, 6)
            }
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
            if isCurrent(expected) { logs[check.id] = log }
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

/// A job's log: numbered lines, error lines in the failed tone on its fill. A long log shows its end first.
private struct RequestCheckLog: View {
    let log: WorkspaceCILog.Result
    let jump: Int
    @ViewState private var all = false

    var body: some View {
        let lines = PullRequestPage.logLines(log.body)
        let hidden = all ? 0 : max(0, lines.count - PullRequestPage.logTail)
        let shown = lines.count - hidden
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hidden > 0 {
                        Button("Show \(hidden) earlier lines") { all = true }.buttonStyle(PullRequestTextButtonStyle()).padding(.leading, 64)
                    }
                    if lines.isEmpty { PullRequestCaption(String(localized: "No log output yet.")).padding(.horizontal, 16) }
                    ForEach(lines.dropFirst(hidden)) { line in
                        HStack(alignment: .top, spacing: 14) {
                            Text(verbatim: String(line.number)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 34, alignment: .trailing)
                            Text(verbatim: line.text).foregroundStyle(line.isError ? StudioStyle.Tone.failed.text : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 16).padding(.vertical, 2)
                        .background(line.isError ? StudioStyle.Tone.failed.fill : Color.clear)
                        .id(line.number)
                    }
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .frame(height: min(320, CGFloat(max(1, shown)) * 20 + 16 + (hidden > 0 ? 24 : 0)))
            // a log opens at its first error, when that is among the lines shown
            .onAppear { if let first = PullRequestPage.firstError(lines), first.number > hidden { proxy.scrollTo(first.number, anchor: .top) } }
            .onChange(of: jump) { _, _ in
                guard let first = PullRequestPage.firstError(lines) else { return }
                // the first error may be among the lines not shown yet
                if first.number <= hidden { all = true }
                proxy.scrollTo(first.number, anchor: .top)
            }
        }
        .background(StudioStyle.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Job log")
    }
}
