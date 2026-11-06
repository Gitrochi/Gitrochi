import AppKit
import SwiftUI

/// One list of the Account page: the inbox of the chosen account, or one category of its open work. The page owns it,
/// so its tab row can mark the whole inbox as read and its Refresh reloads the section that shows.
@MainActor @Observable final class AccountWorkModel {
    enum Failure: Equatable {
        /// The server refused the saved sign-in (401)
        case expired
        case unreachable
        case message(String)
    }

    let inbox: Bool
    /// The category of My work
    var kind = "mine"
    var items: [AccountWorkItem] = []
    var page = 0
    var more = false
    var busy = false
    var failure: Failure?
    /// When the rows were read, for "Showing data from 12m ago" under a failed refresh
    var loadedAt: Date?
    var selectedID: String?
    private var scope = ""
    private var generation = UUID()

    init(inbox: Bool) { self.inbox = inbox }

    /// What "Mark all as read" covers: the loaded rows the server can mark
    var unread: [AccountWorkItem] { items.filter { $0.unread && $0.readID != nil } }

    /// Another account, category or sign-in starts from nothing; the same one refreshes in place
    func open(scope: String) {
        guard scope != self.scope else { return }
        self.scope = scope
        generation = UUID()
        items = []; page = 0; more = false; busy = false; failure = nil; loadedAt = nil; selectedID = nil
    }

    func cancel() { generation = UUID(); busy = false }

    private func access(_ account: HostAccount, _ id: UUID) -> ReviewAccess? {
        guard let token = AccountStore.shared.token(for: account) else { return nil }
        let revision = AccountStore.shared.revision, opened = scope
        return ReviewAccess(
            target: RepoTarget(provider: account.provider, remote: "", host: account.host, path: ""),
            token: token, apiBase: account.apiBase, me: account.username,
            isCurrent: { [weak self] in self?.generation == id && self?.scope == opened && AccountStore.shared.revision == revision })
    }

    func load(_ account: HostAccount, append: Bool = false) async {
        let id = UUID()
        generation = id
        // without a readable token the page shows the saved-access notice instead
        guard let c = access(account, id) else { busy = false; return }
        busy = true
        failure = nil
        defer { if generation == id { busy = false } }
        do {
            let (next, hasMore) = try await AccountWorkAPI.page(c, kind: inbox ? "inbox" : kind, page: append ? page + 1 : 1, accountID: account.id)
            guard generation == id, c.isCurrent?() != false else { return }
            items = append ? items + next.filter { item in !items.contains { $0.id == item.id } } : next
            page = append ? page + 1 : 1
            more = hasMore
            loadedAt = Date()
        } catch { if generation == id { failure = Self.failure(error) } }
    }

    func read(_ item: AccountWorkItem, account: HostAccount) async {
        guard !busy else { return }
        await mark([item], account: account)
    }

    /// One request per notification, the same one a single row sends; it stops at the first that fails
    func readAll(_ account: HostAccount) async {
        guard !busy else { return }
        await mark(unread, account: account)
    }

    private func mark(_ rows: [AccountWorkItem], account: HostAccount) async {
        let id = UUID()
        generation = id
        guard let c = access(account, id) else { return }
        busy = true
        failure = nil
        defer { if generation == id { busy = false } }
        do {
            for row in rows {
                try await AccountWorkAPI.read(c, item: row, accountID: account.id)
                guard generation == id, c.isCurrent?() != false else { return }
                if let index = items.firstIndex(where: { $0.id == row.id }) { items[index].unread = false }
            }
        } catch { if generation == id { failure = Self.failure(error) } }
    }

    private static func failure(_ error: Error) -> Failure {
        if (error as? HostingError)?.status == 401 { return .expired }
        if error is URLError { return .unreachable }
        return .message(error.localizedDescription)
    }
}

/// The Inbox section: the chosen account's notifications across its repositories
struct WorkInboxPanel: View {
    let model: AccountWorkModel
    let account: HostAccount
    var body: some View { AccountWorkPanel(model: model, account: account) }
}

/// The My work section: the open pull requests and issues the chosen account wrote, was assigned or has to review
struct MyWorkPanel: View {
    let model: AccountWorkModel
    let account: HostAccount
    var body: some View { AccountWorkPanel(model: model, account: account) }
}

/// A list column with search, sort and one filter, and the selected row beside it, as the Account board draws the
/// inbox. (Windows: features/account-work/ui/AccountWorkPanel.tsx)
private struct AccountWorkPanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: AccountWorkModel
    let account: HostAccount
    @ViewState private var search = ""
    @ViewState private var unreadOnly = false
    @ViewState private var oldestFirst = false
    @ViewState private var hovered: String?

    private var ready: Bool { AccountStore.shared.token(for: account) != nil }
    private var key: String { "\(account.id)|\(model.kind)|\(AccountStore.shared.revision)|\(ready)" }
    private var rows: [AccountWorkItem] {
        AccountInbox.visible(model.items, search: search, unreadOnly: model.inbox && unreadOnly, oldestFirst: oldestFirst)
    }
    /// The first row shows until another is chosen, as on the board
    private func selected(in rows: [AccountWorkItem]) -> AccountWorkItem? { rows.first { $0.id == model.selectedID } ?? rows.first }

    var body: some View {
        Group {
            if !ready {
                access
            } else if model.failure == .expired {
                AccountState(symbol: "exclamationmark.triangle.fill", tint: StudioStyle.Tone.waiting.text, title: String(localized: "Sign-in expired"),
                             caption: String(localized: "@\(account.username) on \(account.host). Local branches and commits still work."),
                             action: String(localized: "Sign in again…"), filled: true) { openSettings() }
            } else if model.inbox, model.items.isEmpty, let failure = model.failure {
                firstFailure(failure)
            } else {
                let visible = rows, chosen = selected(in: visible)
                AccountSplit {
                    listColumn(visible, selected: chosen)
                } detail: {
                    detail(chosen)
                }
            }
        }
        .task(id: key) {
            model.open(scope: key)
            await model.load(account)
        }
        .onDisappear { model.cancel() }
    }

    /// macOS asks before a saved sign-in is used; one that cannot be read at all offers to restore it
    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountNotice {
                if AccountStore.shared.awaitsAccess(account) {
                    CredentialAccessNotice(account: account)
                } else {
                    SavedAccountAccessNotice(account: account) { Task { await model.load(account) } }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Nothing to keep on screen, so the failure takes the place of the rows; recovering is a plain button
    private func firstFailure(_ failure: AccountWorkModel.Failure) -> some View {
        AccountState(symbol: "xmark.circle.fill", tint: StudioStyle.Tone.failed.text, title: title(failure),
                     action: String(localized: "Retry")) { Task { await model.load(account) } }
    }

    private func title(_ failure: AccountWorkModel.Failure) -> String {
        if case .message(let text) = failure { return text }
        return String(localized: "Couldn't reach \(account.host)")
    }

    // MARK: List column

    private func listColumn(_ rows: [AccountWorkItem], selected: AccountWorkItem?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = model.failure, failure != .expired, !model.items.isEmpty { failed(failure) }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    searchField
                    sortMenu
                }
                if model.inbox {
                    Picker("Filter", selection: $unreadOnly) {
                        Text("Unread \(model.items.filter(\.unread).count)").tag(true)
                        Text("All \(model.items.count)").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                } else {
                    Picker("Work category", selection: $model.kind) {
                        Text("Authored requests").tag("mine")
                        Text("Assigned requests").tag("assignedRequests")
                        Text("Review requested").tag("review")
                        Text("Assigned issues").tag("issues")
                        Text("Authored issues").tag("myIssues")
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.busy)
                }
            }
            .padding(.bottom, 4)
            if model.items.isEmpty, let failure = model.failure {
                // My work keeps its list column, so another category can be chosen when one of them fails
                firstFailure(failure)
            } else if rows.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        let groups = AccountInbox.groups(rows)
                        // oldest first shows the earlier rows above today's
                        if oldestFirst { group("Earlier", groups.earlier, selected: selected); group("Today", groups.today, selected: selected) }
                        else { group("Today", groups.today, selected: selected); group("Earlier", groups.earlier, selected: selected) }
                        if model.more {
                            Button { Task { await model.load(account, append: true) } } label: {
                                Text("Load more").frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(AccountTextButtonStyle()).disabled(model.busy)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(StudioStyle.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.inbox ? Text("Inbox") : Text("My work"))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            TextField(model.inbox ? String(localized: "Search notifications") : String(localized: "Search my work"), text: $search)
                .textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AccountStyle.edge))
    }

    private var sortMenu: some View {
        Menu {
            Button { oldestFirst = false } label: { if oldestFirst { Text("Newest first") } else { Label("Newest first", systemImage: "checkmark") } }
            Button { oldestFirst = true } label: { if oldestFirst { Label("Oldest first", systemImage: "checkmark") } else { Text("Oldest first") } }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AccountStyle.edge))
        .help("Sort").accessibilityLabel("Sort")
    }

    /// A refresh that failed leaves the last rows and says how old they are
    private func failed(_ failure: AccountWorkModel.Failure) -> some View {
        AccountNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.failed.text).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title(failure)).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioStyle.Tone.failed.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let loadedAt = model.loadedAt {
                        Text("Showing data from \(AccountInbox.when(loadedAt, locale: AppLanguage.locale))").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { Task { await model.load(account) } }.controlSize(.large).disabled(model.busy)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private func group(_ title: LocalizedStringKey, _ items: [AccountWorkItem], selected: AccountWorkItem?) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
                .padding(EdgeInsets(top: 10, leading: 8, bottom: 4, trailing: 8))
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { row($0, on: $0.id == selected?.id) }
        }
    }

    private func row(_ item: AccountWorkItem, on: Bool) -> some View {
        // on the tint the secondary text is a step darker and the pill turns white (docs/design.md, Selection)
        let secondary = on ? Color.primary.opacity(0.7) : StudioStyle.Rail.icon
        let reference = AccountInbox.reference(item)
        return Button { model.selectedID = item.id } label: {
            HStack(alignment: .top, spacing: 8) {
                if model.inbox {
                    Circle().fill(item.unread ? Color.accentColor : Color.clear).frame(width: 8, height: 8).padding(.top, 5)
                        .accessibilityLabel(item.unread ? Text("Unread") : Text("Read"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: item.title).font(.system(size: 13, weight: item.unread || on ? .semibold : .medium))
                            .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        if let updated = item.updated {
                            Text(verbatim: AccountInbox.when(updated, locale: AppLanguage.locale)).font(.system(size: 12)).foregroundStyle(secondary).fixedSize()
                        }
                    }
                    HStack(spacing: 6) {
                        if !reference.isEmpty {
                            Text(verbatim: reference).font(.system(size: 11, design: .monospaced)).fixedSize()
                            Text(verbatim: "·").accessibilityHidden(true)
                        }
                        Text(verbatim: AccountInbox.repositoryName(item.repository)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        trailing(item, on: on)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                }
            }
            .padding(.vertical, 8).padding(.leading, model.inbox ? 8 : 10).padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // selection is the accent at 16 %, and nothing else: no bar, border or ring (docs/design.md)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.16) : hovered == item.id ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu {
            if let url = URL(string: item.url) { Button("Open in browser") { NSWorkspace.shared.open(url) } }
            if item.unread, item.readID != nil { Button("Mark as read") { Task { await model.read(item, account: account) } }.disabled(model.busy) }
        }
    }

    /// The inbox says why the row is there; My work says a draft, and whose it is when it is not the account's own
    @ViewBuilder private func trailing(_ item: AccountWorkItem, on: Bool) -> some View {
        if model.inbox {
            let reason = AccountInbox.reason(item)
            AccountRowPill(title: AccountInbox.label(reason, actor: item.actor), symbol: Self.symbol(reason), tone: Self.tone(reason), onSelection: on)
        } else if item.status == "draft" {
            AccountRowPill(title: String(localized: "Draft"), symbol: "pencil.circle", tone: .waiting, onSelection: on)
        } else if !item.author.isEmpty, item.author.caseInsensitiveCompare(account.username) != .orderedSame {
            Text(verbatim: "@" + item.author).lineLimit(1).fixedSize()
        }
    }

    private static func symbol(_ reason: AccountInbox.Reason) -> String {
        switch reason {
        case .review: return "eye"
        case .mention: return "at"
        case .assigned: return "person"
        case .ciFailed: return "xmark.circle.fill"
        case .ci: return "play.circle"
        case .update: return "bell"
        }
    }

    private static func tone(_ reason: AccountInbox.Reason) -> StudioStyle.Tone {
        switch reason {
        case .review, .mention, .assigned: return .info
        case .ciFailed: return .failed
        case .ci, .update: return .neutral
        }
    }

    @ViewBuilder private var empty: some View {
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.busy && model.items.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            }
            .padding(.horizontal, 8).padding(.top, 6)
            Spacer(minLength: 0)
        } else if !words.isEmpty {
            AccountState(symbol: "magnifyingglass", title: model.inbox ? String(localized: "No notifications match “\(words)”") : String(localized: "No items match “\(words)”"),
                         caption: String(localized: "The search covers titles, numbers and repositories."),
                         action: String(localized: "Clear search")) { search = "" }
        } else if model.inbox && unreadOnly && !model.items.isEmpty {
            AccountState(symbol: "tray", title: String(localized: "No unread notifications"),
                         caption: String(localized: "Read notifications are under All."),
                         action: String(localized: "Show all")) { unreadOnly = false }
        } else if model.inbox {
            AccountState(symbol: "tray", title: String(localized: "No notifications"),
                         caption: String(localized: "Review requests, mentions and assignments for @\(account.username) appear here."),
                         action: String(localized: "Refresh")) { Task { await model.load(account) } }
        } else {
            AccountState(symbol: "checklist", title: String(localized: "Nothing open in this list"),
                         caption: String(localized: "No open pull requests or issues for @\(account.username) here. Choose another list above."),
                         action: String(localized: "Refresh")) { Task { await model.load(account) } }
        }
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ item: AccountWorkItem?) -> some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        let reference = AccountInbox.reference(item)
                        if !reference.isEmpty { Text(verbatim: reference).font(.system(size: 13, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon) }
                        state(item)
                    }
                    Text(verbatim: item.title).font(.system(size: 22, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    WorkbenchFlow(spacing: 12) {
                        let name = item.actor.isEmpty ? item.author : item.actor
                        if !name.isEmpty {
                            HStack(spacing: 6) {
                                HostingAvatar(name: name, username: item.author.isEmpty ? name : item.author, size: 20)
                                Text(verbatim: item.actor.isEmpty ? "@" + name : name).fontWeight(.semibold).foregroundStyle(.primary)
                            }
                        }
                        if model.inbox { Text(verbatim: AccountInbox.label(AccountInbox.reason(item))) }
                        // the row shows the repository's name only; here is where it lives
                        Text(verbatim: item.host + "/" + item.repository).textSelection(.enabled)
                        if !item.source.isEmpty, !item.target.isEmpty { StatusPill(title: item.source + " → " + item.target, tone: .neutral) }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(StudioStyle.Rail.icon)
                    if !item.body.isEmpty {
                        Text(verbatim: item.body).font(.system(size: 13)).lineSpacing(4).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    // the board's buttons are 28 pt tall, which is the system's large size
                    WorkbenchFlow(spacing: 8) { actions(item) }.controlSize(.large).padding(.top, 10)
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func state(_ item: AccountWorkItem) -> some View {
        let request = item.kind == .request
        switch item.status {
        case "open": StatusPill(title: WorkState.title("open"), symbol: request ? "arrow.triangle.pull" : "circle.dotted", tone: .passed)
        case "draft": StatusPill(title: String(localized: "Draft"), symbol: "pencil.circle", tone: .waiting)
        case "merged": StatusPill(title: WorkState.title("merged"), symbol: "arrow.triangle.merge", tone: .neutral)
        case "closed": StatusPill(title: WorkState.title("closed"), symbol: "xmark.circle", tone: .neutral)
        default: EmptyView()
        }
    }

    /// One filled button: the open repository's own requests and issues open on their page of the app, anything
    /// else in the browser
    @ViewBuilder private func actions(_ item: AccountWorkItem) -> some View {
        let local = AccountInbox.isLocal(item, host: store.target?.host, path: store.target?.path)
        if local {
            Button { open(item) } label: {
                if item.kind == .request {
                    Label(AccountInbox.reason(item) == .review ? String(localized: "Review in Pull requests") : String(localized: "Open in Pull requests"), systemImage: "arrow.triangle.pull")
                } else {
                    Label("Open in Issues", systemImage: "circle.dotted")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        if let url = URL(string: item.url) {
            if local {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in browser", systemImage: "arrow.up.right.square") }
            } else {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in browser", systemImage: "arrow.up.right.square") }.buttonStyle(.borderedProminent)
            }
        }
        if item.unread, item.readID != nil {
            Button { Task { await model.read(item, account: account) } } label: { Label("Mark as read", systemImage: "checkmark") }
                .disabled(model.busy)
        }
    }

    private func open(_ item: AccountWorkItem) {
        if item.kind == .request {
            store.navigate(.pullRequests)
            store.select(.pullRequest(item.number))
        } else {
            store.openIssue(CollaborationInboxItem(id: "issue-\(item.number)", kind: "issue", number: item.number, title: item.title, url: item.url,
                                                   body: item.body, state: item.status == "closed" ? "closed" : "open", author: item.author))
        }
    }
}

/// The status badge of a list row. On the selected row its fill turns white (docs/design.md, Selection), which the
/// shared StatusPill does not draw.
private struct AccountRowPill: View {
    let title: String
    let symbol: String
    let tone: StudioStyle.Tone
    let onSelection: Bool

    var body: some View {
        if onSelection {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text(verbatim: title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.text)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(StudioStyle.surface))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
        } else {
            StatusPill(title: title, symbol: symbol, tone: tone)
        }
    }
}
