import SwiftUI
import AppKit

/// The issue's way from opened to closed, as the Issues board's Development card draws it: its linked local branches,
/// the requests they opened and those the server reports, with the next step as a button where the line stops.
/// (Windows: widgets/inspector/ui/IssueDevelopment.tsx)
struct IssueDevelopmentPanel: View {
    @Environment(RepoStore.self) private var store
    let item: CollaborationInboxItem
    @ViewState private var requests: [IssueLinkedRequest] = []
    @ViewState private var page = 0
    @ViewState private var more = false
    @ViewState private var loading = false
    @ViewState private var error: String?
    private var context: String { [store.url?.path ?? "", store.target?.host ?? "", store.target?.path ?? "", store.hostingAccount?.id ?? "", item.id].joined(separator: "|") }
    private var isOpen: Bool { ["open", "opened"].contains(item.state) }
    private var gitlab: Bool { store.target?.provider == .gitlab }

    private enum Marker { case done, current, next, closed }

    var body: some View {
        if store.issueTask(item) != nil {
            let branches = store.issueBranches(item)
            // a request one of the branches opened is known without asking the server
            let local = store.pullRequests.filter { branches.contains($0.source) }
            let linked = requests.filter { request in !local.contains { $0.number == request.number } }
            VStack(alignment: .leading, spacing: 8) {
                Text("Development").font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption)
                VStack(alignment: .leading, spacing: 0) {
                    step(.done) { Text("Opened") }
                    ForEach(branches, id: \.self) { name in
                        step(.done) { branch(name) }
                    }
                    if branches.isEmpty {
                        step(.next) {
                            Button { store.requestIssueBranch(item) } label: { Label("Create branch", systemImage: "arrow.triangle.branch") }
                                .buttonStyle(HostedListButtonStyle())
                                .disabled(store.busy != nil || store.headHash == nil)
                        }
                    }
                    ForEach(local) { request in
                        step(.current) {
                            link(title: request.title, number: request.number, note: request.isDraft ? String(localized: "Draft") : WorkState.title("open")) {
                                store.openIssueRequest(request)
                            }
                        }
                    }
                    ForEach(linked) { request in
                        step(["open", "opened"].contains(request.state) ? .current : .done) {
                            link(title: request.title, number: request.number, note: WorkState.title(request.state)) {
                                if let url = URL(string: request.url) { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    if !branches.isEmpty, local.isEmpty, linked.isEmpty {
                        step(.next) {
                            Button { store.requestIssuePullRequest(item) } label: {
                                Label(gitlab ? String(localized: "Create merge request") : String(localized: "Create pull request"), systemImage: "arrow.triangle.pull")
                            }
                            .buttonStyle(HostedListButtonStyle())
                            .disabled(store.busy != nil || store.headBranch == nil)
                        }
                    }
                    step(isOpen ? .next : .closed, last: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: WorkState.title("closed"))
                            if isOpen, !(local.isEmpty && linked.isEmpty) {
                                caption(gitlab ? String(localized: "When the merge request merges") : String(localized: "When the pull request merges"))
                            }
                        }
                    }
                }
                .font(.system(size: 13))
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
                if page > 0 && requests.isEmpty { caption(String(localized: "No linked requests on loaded pages.")) }
                // what the server knows is read only when asked for
                WorkbenchFlow(spacing: 16) {
                    if page == 0 { Button(loading ? String(localized: "Loading…") : String(localized: "Load linked requests")) { load() }.disabled(loading) }
                    else { Button("Refresh linked requests") { load() }.disabled(loading) }
                    if more { Button("Load more linked requests") { load(append: true) }.disabled(loading) }
                    if !branches.isEmpty {
                        Button("Create branch") { store.requestIssueBranch(item) }.disabled(store.busy != nil || store.headHash == nil)
                    }
                    if !(local.isEmpty && linked.isEmpty) || branches.isEmpty {
                        Button(gitlab ? String(localized: "Create merge request") : String(localized: "Create pull request")) { store.requestIssuePullRequest(item) }
                            .disabled(store.busy != nil || store.headBranch == nil)
                    }
                }
                .buttonStyle(HostedListTextButtonStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Development")
            .onChange(of: context) { _, _ in requests = []; page = 0; more = false; loading = false; error = nil }
        }
    }

    /// A linked branch: a click checks it out; the caption says whether it is the current one and what is not pushed
    private func branch(_ name: String) -> some View {
        let local = store.localBranches.first { $0.name == name }
        var notes: [String] = []
        if name == store.headBranch { notes.append(String(localized: "Current")) }
        if let local, local.upstream == nil { notes.append(String(localized: "Not on the server yet")) }
        else if let local, local.ahead > 0 { notes.append(String(localized: "\(local.ahead) not pushed")) }
        return VStack(alignment: .leading, spacing: 0) {
            Button { if let local { Task { await store.checkout(local) } } } label: {
                Text(verbatim: name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .disabled(store.busy != nil || name == store.headBranch)
            .help("Check out branch")
            if !notes.isEmpty { caption(notes.joined(separator: " · ")) }
        }
    }

    private func link(title: String, number: Int, note: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                (Text(verbatim: title + " ") + Text(verbatim: "#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.caption))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                caption(note)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
    }

    /// One step of the line: its marker with the line down to the next step, and its content beside them
    private func step<Content: View>(_ marker: Marker, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                mark(marker).frame(width: 18, height: 20)
                if !last {
                    Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            content().padding(.bottom, last ? 0 : 12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func mark(_ marker: Marker) -> some View {
        switch marker {
        case .done: Circle().fill(StudioStyle.Tone.passed.text).frame(width: 10, height: 10)
        // the current marker of docs/design.md: a 12 pt dot in an 18 pt halo, in the accent
        case .current: Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 18, height: 18).overlay(Circle().fill(Color.accentColor).frame(width: 12, height: 12))
        case .next: Circle().strokeBorder(HostedList.caption, lineWidth: 2).frame(width: 12, height: 12)
        case .closed: Circle().fill(StudioStyle.Tone.neutral.text).frame(width: 10, height: 10)
        }
    }

    private func load(append: Bool = false) {
        guard !loading, let access = store.issueAccess else { return }
        let stamp = context, next = append ? page + 1 : 1
        loading = true; error = nil
        Task {
            defer { if context == stamp { loading = false } }
            do {
                let result = try await CollaborationAPI.issueLinkedRequests(access, item: item, page: next)
                guard context == stamp, access.isCurrent?() != false else { return }
                requests = append ? requests + result.0.filter { value in !requests.contains { $0.id == value.id } } : result.0
                more = result.1; page = next
            } catch { if context == stamp { self.error = error.localizedDescription } }
        }
    }
}
