import SwiftUI
import AppKit

struct RequestChecksPanel: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    let headSHA: String
    @ViewState private var results = RequestCheckResults()
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var refreshID = UUID()
    @ViewState private var logs: [String: WorkspaceCILog.Result] = [:]
    @ViewState private var logErrors: [String: String] = [:]
    @ViewState private var loadingLogs = Set<String>()
    private var context: String { "\(store.collaboration.contextID):\(store.hostingAccount?.id ?? ""): \(number):\(headSHA)" }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Label("Checks", systemImage: "checkmark.circle").font(.subheadline.weight(.semibold))
                if !results.checks.isEmpty {
                    Text("\(results.checks.filter { $0.status == .success || $0.status == .neutral || $0.status == .skipped }.count)/\(results.checks.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh checks").accessibilityLabel("Refresh checks").disabled(loading)
            }
            Text(String(headSHA.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(results.warnings, id: \.self) { warning in Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !loading && results.checks.isEmpty && error == nil && results.warnings.isEmpty {
                Text("No checks reported for this commit.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(results.checks) { check in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        CIStatusIcon(status: check.status, size: 14).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.name).font(.callout.weight(.medium)).textSelection(.enabled)
                            Text(check.status.title).font(.caption).foregroundStyle(check.status.color)
                            if !check.detail.isEmpty { Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer(minLength: 0)
                        if let url = safeURL(check.url) {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                .help("Open check result").accessibilityLabel("Open check result")
                        }
                    }
                    if !check.output.isEmpty {
                        DisclosureGroup("Details") { MarkdownView(check.output, target: store.target).padding(.top, 6) }.font(.caption)
                    }
                    if check.jobID != nil {
                        DisclosureGroup("Job log") {
                            VStack(alignment: .leading, spacing: 7) {
                                if let log = logs[check.id] {
                                    GeometryReader { geometry in
                                        ScrollView([.horizontal, .vertical]) {
                                            Text(log.body.isEmpty ? String(localized: "No log output yet.") : log.body)
                                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                                .fixedSize(horizontal: true, vertical: true)
                                                .frame(minWidth: max(0, geometry.size.width - 16), minHeight: max(0, geometry.size.height - 16), alignment: .topLeading).padding(8)
                                        }
                                    }.frame(height: 220).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                    if log.truncated { Text("Log truncated. Open the job in the browser for the full output.").font(.caption).foregroundStyle(.secondary) }
                                }
                                if let error = logErrors[check.id] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                                Button(logs[check.id] == nil ? String(localized: "Load log") : String(localized: "Refresh log")) { Task { await loadLog(check) } }.disabled(loadingLogs.contains(check.id))
                                if loadingLogs.contains(check.id) { ProgressView().controlSize(.small) }
                            }.padding(.top, 6)
                        }.font(.caption)
                    }
                }.padding(10).background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .task(id: context + refreshID.uuidString) {
            results = RequestCheckResults(); logs = [:]; logErrors = [:]; loadingLogs = []; loading = false; error = nil
            repeat {
                await load()
                guard results.checks.contains(where: { $0.status.isActive }), !Task.isCancelled else { break }
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            } while !Task.isCancelled
        }
    }
    private func isCurrent(_ expected: String) -> Bool {
        context == expected && store.selection == .pullRequest(number)
            && store.pullRequests.first(where: { $0.number == number })?.headSHA == headSHA
    }
    private func safeURL(_ raw: String) -> URL? {
        guard let u = URL(string: raw), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil else { return nil }; return u
    }
    @MainActor private func load() async {
        let expected = context
        guard !headSHA.isEmpty, var c = store.collaborationAccess else { error = String(localized: "Connect an account to load checks."); return }
        c.isCurrent = { isCurrent(expected) }
        loading = true; error = nil
        defer { if isCurrent(expected) { loading = false } }
        do {
            let value = try await RequestChecksAPI.load(c, number: number, headSHA: headSHA)
            if isCurrent(expected) && !Task.isCancelled { results = value }
        } catch is CancellationError {} catch { if isCurrent(expected) && !Task.isCancelled { self.error = WorkspaceCILog.redact(error.localizedDescription, token: c.token) } }
    }
    @MainActor private func loadLog(_ check: RequestCheck) async {
        let expected = context
        guard let job = check.jobID, let original = store.collaborationAccess else { return }
        let target = check.logProjectID.map { RepoTarget(provider: original.target.provider, remote: original.target.remote, host: original.target.host, path: String($0)) } ?? original.target
        var c = ReviewAccess(target: target, token: original.token, apiBase: original.apiBase, me: original.me)
        c.isCurrent = { isCurrent(expected) }
        loadingLogs.insert(check.id); logErrors[check.id] = nil
        defer { if isCurrent(expected) { loadingLogs.remove(check.id) } }
        do {
            let log = try await WorkspaceCILog.load(c, job: job)
            if isCurrent(expected) { logs[check.id] = log }
        } catch is CancellationError {} catch { if isCurrent(expected) { logErrors[check.id] = WorkspaceCILog.redact(error.localizedDescription, token: c.token) } }
    }
}
