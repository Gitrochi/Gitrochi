import SwiftUI

/// The first page: only what needs a person — waiting prompts, questions answered in place, what auto-continue sent,
/// finished work to confirm or archive, sessions to decide. Keyboard (outside a text field): ↑↓ move, Return opens,
/// A answers, C confirms, E archives, S snoozes; ⌘Z undoes from the toast.
/// (Windows: widgets/ledger-workspace/ui/LedgerInboxView.tsx)
struct LedgerInboxView: View {
    let ledger: LedgerStore
    /// Opens a session in the inspector
    let open: (String) -> Void
    @ViewState private var highlighted: String?
    @ViewState private var lastIndex = 0
    @ViewState private var answering: String?
    @ViewState private var correcting: Int?
    @ViewState private var correction = ""
    @FocusState private var listFocused: Bool

    private var items: [LedgerInbox.Item] { ledger.inbox.items }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !ledger.inbox.prompts.isEmpty { LedgerPromptStrip(prompts: ledger.inbox.prompts, ledger: ledger) }
                    ForEach(LedgerInbox.Group.allCases, id: \.self) { group in
                        let rows = ledger.inbox.items(in: group)
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                LedgerSectionHeader(title: group.title, count: rows.count)
                                ForEach(rows) { item in row(item).id(item.id) }
                            }
                        }
                    }
                    if items.isEmpty && ledger.inbox.prompts.isEmpty {
                        WorkspaceEmptyState(title: "Nothing needs you", systemImage: "tray",
                                            description: "Questions, finished work to confirm and sessions to decide show up here.")
                            .frame(minHeight: 320)
                    } else {
                        Text("↑↓ move · Return opens · A answers · C confirms · E archives · S still active")
                            .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(16)
                .frame(maxWidth: 860, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) {
                guard let item = current, let session = item.sessionId else { return .ignored }
                open(session)
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "aceACEsS")) { press in
                guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
                return key(press.characters.lowercased()) ? .handled : .ignored
            }
            .onChange(of: highlighted) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
            .onChange(of: items.map(\.id)) { _, ids in
                // after an item leaves (confirmed, archived), the next one takes its place under the cursor
                guard let highlighted, !ids.contains(highlighted) else { return }
                self.highlighted = ids.isEmpty ? nil : ids[min(lastIndex, ids.count - 1)]
            }
            .onChange(of: ledger.selection) { _, id in
                if let id, current?.sessionId != id, let item = items.first(where: { $0.sessionId == id }) { highlight(item.id) }
            }
        }
    }

    private var current: LedgerInbox.Item? { items.first { $0.id == highlighted } }

    private func highlight(_ id: String?) {
        highlighted = id
        if let id, let index = items.firstIndex(where: { $0.id == id }) { lastIndex = index }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == highlighted }.map { $0 + delta } ?? (delta > 0 ? 0 : items.count - 1)
        highlight(items[min(max(index, 0), items.count - 1)].id)
    }

    /// A, C, E and S on the highlighted item; false when the key means nothing there
    private func key(_ key: String) -> Bool {
        guard let item = current else { return false }
        let session = ledger.session(item.sessionId)
        switch (key, item.content) {
        case ("a", .question):
            answering = nil
            DispatchQueue.main.async { answering = item.id }
            return true
        case ("c", .autoReply(let prompt)):
            Task { await ledger.review(prompt) }
            return true
        case ("c", .session) where session?.verdict == .confirm:
            confirm(session!)
            return true
        case ("e", .session) where session?.verdict == .expirable:
            archive(session!)
            return true
        case ("s", .session) where session?.verdict == .stale:
            stillActive(session!)
            return true
        default:
            return false
        }
    }

    // MARK: - Rows

    @ViewBuilder private func row(_ item: LedgerInbox.Item) -> some View {
        let session = ledger.session(item.sessionId)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let session {
                    LedgerSessionLabel(id: session.id, color: session.color)
                    Text(session.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    if item.group != .questions { LedgerVerdictBadge(verdict: session.verdict) }
                }
                Spacer(minLength: 6)
                Text(when(item, session)).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            switch item.content {
            case .question(let question):
                Text(question.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                LedgerAnswerField(placeholder: String(localized: "Answer…"), text: draft(question.id),
                                  busy: ledger.working.contains("q\(question.id)"), focusRequest: answering == item.id,
                                  save: { Task { await ledger.answer(question) } },
                                  dismiss: { Task { await ledger.dismiss(question) } })
            case .autoReply(let prompt):
                autoReply(prompt)
            case .session:
                if let session { sessionLine(session, group: item.group) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted == item.id ? StudioStyle.selection : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(highlighted == item.id && listFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture {
            highlight(item.id)
            listFocused = true
            if let id = item.sessionId { open(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle(item, session))
        .accessibilityAction(named: "Open") { if let id = item.sessionId { open(id) } }
    }

    private func draft(_ id: Int) -> Binding<String> {
        Binding(get: { ledger.drafts[id] ?? "" }, set: { ledger.drafts[id] = $0 })
    }

    private func when(_ item: LedgerInbox.Item, _ session: LedgerSession?) -> String {
        switch item.content {
        case .question(let q): return LedgerTime.short(q.createdAt)
        case .autoReply(let p): return LedgerTime.short(p.deadline)
        case .session: return session.map { LedgerTime.short($0.lastAt) } ?? ""
        }
    }

    private func accessibilityTitle(_ item: LedgerInbox.Item, _ session: LedgerSession?) -> String {
        let name = session.map { $0.id + ", " + $0.title } ?? ""
        switch item.content {
        case .question(let q): return String(localized: "Question") + ": " + q.text + ", " + name
        case .autoReply: return String(localized: "Auto-continued") + ", " + name
        case .session: return name + ", " + (session?.verdict.title ?? "")
        }
    }

    @ViewBuilder private func autoReply(_ prompt: LedgerPendingPrompt) -> some View {
        let asked = prompt.payload["questions"]?.array.first?["question"].string ?? prompt.payload["question"]?.string
            ?? prompt.payload["description"]?.string ?? prompt.kind.title
        let sent = Self.describe(prompt.answer ?? [:])
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(asked).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text("“\(sent)”").font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        let busy = prompt.sessionId.map { ledger.working.contains($0) } ?? true
        if correcting == prompt.id {
            LedgerAnswerField(placeholder: String(localized: "What should the session do instead?"), text: $correction,
                              saveTitle: String(localized: "Send correction"), busy: busy, focusRequest: true,
                              save: {
                                  let text = correction
                                  Task { await ledger.review(prompt, correction: text); correcting = nil; correction = "" }
                              },
                              dismiss: { correcting = nil; correction = "" })
        } else {
            WorkbenchFlow(spacing: 8) {
                Button("Confirm") { Task { await ledger.review(prompt) } }
                    .disabled(busy).help("The automatic answer was right (C)")
                Button("Send correction…") { correcting = prompt.id; correction = "" }
                    .disabled(busy).help("Send the session a different instruction with its next report")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func sessionLine(_ s: LedgerSession, group: LedgerInbox.Group) -> some View {
        let busy = ledger.working.contains(s.id)
        HStack(alignment: .center, spacing: 8) {
            Text(summary(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            WorkbenchFlow(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                switch s.verdict {
                case .confirm:
                    Button("Confirm") { confirm(s) }.disabled(busy).help("Confirm the outcome (C)")
                case .expirable:
                    Button("Archive") { archive(s) }.disabled(busy).help("The conversation is cleaned up (E)")
                case .pendingMerge:
                    LedgerMergeMenu(session: s, ledger: ledger).disabled(busy)
                    Button("Close") { Task { await ledger.perform(.setStatus(.closed, version: nil), on: [s.id], message: String(localized: "Closed \(s.id)")) } }
                        .disabled(busy).help("Finished without a merge")
                case .stale:
                    Button("Close") { Task { await ledger.perform(.setStatus(.closed, version: nil), on: [s.id], message: String(localized: "Closed \(s.id)")) } }
                        .disabled(busy).help("Finished without a merge")
                    Button("Still active") { stillActive(s) }.disabled(busy).help("It is still going: it does not count as stale for a while (S)")
                default:
                    EmptyView()
                }
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func summary(_ s: LedgerSession) -> String {
        var parts = [s.status.title]
        if let into = s.mergedInto { parts[0] += " → " + into }
        if s.verdict == .stale { parts.append(String(localized: "no report since \(LedgerTime.short(s.lastAt))")) }
        if s.mergedInto == nil, let base = s.baseCurrent ?? s.baseVersion { parts.append(String(localized: "on \(base)")) }
        return parts.joined(separator: " · ")
    }

    private func confirm(_ s: LedgerSession) {
        Task { await ledger.perform(.ack, on: [s.id], message: String(localized: "Confirmed \(s.id)")) }
    }

    private func archive(_ s: LedgerSession) {
        Task { await ledger.perform(.archive, on: [s.id], message: String(localized: "Archived \(s.id)")) }
    }

    private func stillActive(_ s: LedgerSession) {
        Task { await ledger.perform(.stillActive, on: [s.id], message: String(localized: "Marked \(s.id) still active")) }
    }

    static func describe(_ answer: [String: LedgerJSON]) -> String {
        if let text = answer["text"]?.string { return text }
        if let decision = answer["decision"]?.string { return decision == "allow" ? String(localized: "Allowed") : String(localized: "Denied") }
        if let answers = answer["answers"]?.object { return answers.values.compactMap(\.string).sorted().joined(separator: ", ") }
        return ""
    }
}

/// "Mark merged…": the project's versions, newest first; a person's choice also confirms
struct LedgerMergeMenu: View {
    let session: LedgerSession
    let ledger: LedgerStore

    var body: some View {
        let baselines = (ledger.state?.baselines ?? []).filter { $0.project == session.project }
        let versions = baselines.map(\.version).sorted { LedgerProjects.versionKey($1).lexicographicallyPrecedes(LedgerProjects.versionKey($0)) }
        let newest = LedgerProjects.head(session.project, baselines: baselines)
        Menu("Mark merged…") {
            ForEach(versions, id: \.self) { version in
                Button(version == newest ? String(localized: "\(version) (newest)") : version) {
                    Task { await ledger.perform(.setStatus(.merged, version: version), on: [session.id], message: String(localized: "Marked \(session.id) merged into \(version)")) }
                }
            }
            if versions.isEmpty { Text("No versions yet") }
        }
        .fixedSize()
        .help("Pick the version this work went into")
    }
}
