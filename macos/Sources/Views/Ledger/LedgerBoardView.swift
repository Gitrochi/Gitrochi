import SwiftUI
import AppKit

/// Every session of the project as a dense list: verdict chips with counts, multi-select (⌘ or ⇧ click, Space) and
/// bulk confirm, archive, snooze and close. Streams stay out of it. (Windows: widgets/ledger-workspace/ui/LedgerBoardView.tsx)
struct LedgerBoardView: View {
    let ledger: LedgerStore
    let open: (String) -> Void
    let showStreams: () -> Void
    @ViewState private var anchor: String?
    @FocusState private var focused: Bool

    private var rows: [LedgerSession] { ledger.boardRows }

    var body: some View {
        VStack(spacing: 0) {
            chips
            if !ledger.boardSelection.isEmpty { bulkBar }
            Divider()
            if rows.isEmpty {
                WorkspaceEmptyState(title: "No sessions match", systemImage: "line.3.horizontal.decrease.circle",
                                    description: "Clear the filter, or pick another project or period.",
                                    actionTitle: "Clear filter", action: { ledger.filter = LedgerSessionFilter() })
            } else {
                list
            }
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkbenchFlow(spacing: 6) {
                ForEach(LedgerVerdict.displayOrder, id: \.self) { verdict in
                    let count = ledger.verdictCounts[verdict] ?? 0
                    let on = ledger.filter.verdicts.contains(verdict)
                    Button {
                        var filter = ledger.filter
                        if on { filter.verdicts.remove(verdict) } else { filter.verdicts.insert(verdict) }
                        ledger.filter = filter
                    } label: {
                        LedgerVerdictBadge(verdict: verdict, count: count)
                            .padding(2)
                            .overlay(Capsule().strokeBorder(on ? Color.primary.opacity(0.55) : Color.clear, lineWidth: 1.5))
                            .opacity(count == 0 && !on ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(on ? String(localized: "Stop filtering by \(verdict.title)") : String(localized: "Show only \(verdict.title)"))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if ledger.streamCount > 0 {
                HStack(spacing: 4) {
                    Text("Streams kept out of this list (they report in cycles): \(ledger.streamCount)").font(.caption).foregroundStyle(.secondary)
                    Button("Show streams", action: showStreams).buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selected: [LedgerSession] { rows.filter { ledger.boardSelection.contains($0.id) } }

    private var bulkBar: some View {
        let picked = selected
        let toConfirm = picked.filter { $0.verdict == .confirm }.map(\.id)
        let toArchive = picked.filter { $0.verdict != .archived }.map(\.id)
        let live = picked.filter { !$0.status.isFinished && $0.status != .shelved }.map(\.id)
        let stale = picked.filter { $0.verdict == .stale }.map(\.id)
        return HStack(spacing: 8) {
            Text("\(picked.count) selected").font(.callout.weight(.semibold)).monospacedDigit()
            Divider().frame(height: 16)
            WorkbenchFlow(spacing: 6) {
                Button("Confirm (\(toConfirm.count))") {
                    Task { await ledger.perform(.ack, on: toConfirm, message: String(localized: "Sessions confirmed: \(toConfirm.count)")) }
                }.disabled(toConfirm.isEmpty)
                Button("Archive (\(toArchive.count))") {
                    Task { await ledger.perform(.archive, on: toArchive, message: String(localized: "Sessions archived: \(toArchive.count)")) }
                }.disabled(toArchive.isEmpty)
                Button("Still active (\(stale.count))") {
                    Task { await ledger.perform(.stillActive, on: stale, message: String(localized: "Sessions marked still active: \(stale.count)")) }
                }.disabled(stale.isEmpty)
                Button("Close (\(live.count))") {
                    Task { await ledger.perform(.setStatus(.closed, version: nil), on: live, message: String(localized: "Sessions closed: \(live.count)")) }
                }.disabled(live.isEmpty)
            }
            Spacer(minLength: 4)
            Button("Clear selection") { ledger.boardSelection = [] }.buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(StudioStyle.selection)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { session in
                        LedgerBoardRow(session: session, behind: LedgerProjects.behind(session, baselines: ledger.state?.baselines ?? []),
                                       selected: ledger.selection == session.id, picked: ledger.boardSelection.contains(session.id),
                                       busy: ledger.working.contains(session.id), togglePick: { toggle(session.id) })
                            .id(session.id)
                            .onTapGesture { click(session.id) }
                            .accessibilityAction(named: "Open") { open(session.id) }
                            .accessibilityAction(named: ledger.boardSelection.contains(session.id) ? String(localized: "Deselect") : String(localized: "Select")) { toggle(session.id) }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.space) {
                guard let id = ledger.selection else { return .ignored }
                toggle(id)
                return .handled
            }
            .onKeyPress(.return) {
                guard let id = ledger.selection else { return .ignored }
                open(id)
                return .handled
            }
        }
    }

    private func click(_ id: String) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggle(id)
        } else if flags.contains(.shift), let anchor, let a = rows.firstIndex(where: { $0.id == anchor }), let b = rows.firstIndex(where: { $0.id == id }) {
            ledger.boardSelection.formUnion(rows[min(a, b)...max(a, b)].map(\.id))
        } else {
            anchor = id
            open(id)
        }
    }

    private func toggle(_ id: String) {
        if ledger.boardSelection.contains(id) { ledger.boardSelection.remove(id) } else { ledger.boardSelection.insert(id) }
        anchor = id
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == ledger.selection }.map { $0 + delta } ?? 0
        let id = rows[min(max(index, 0), rows.count - 1)].id
        ledger.selection = id
        anchor = id
        proxy.scrollTo(id)
    }
}

/// One session in the Board: what it is, where it stands and how it is linked
private struct LedgerBoardRow: View {
    let session: LedgerSession
    let behind: Int
    let selected: Bool
    let picked: Bool
    let busy: Bool
    let togglePick: () -> Void
    @ViewState private var hover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(wide: true)
            row(wide: false)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(selected ? StudioStyle.selection : hover ? StudioStyle.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func row(wide: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: togglePick) {
                Image(systemName: picked ? "checkmark.square.fill" : "square").foregroundStyle(picked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(picked ? String(localized: "Remove from the selection") : String(localized: "Add to the selection (Space)"))
            .accessibilityLabel(picked ? String(localized: "Deselect") : String(localized: "Select"))
            LedgerSessionLabel(id: session.id, color: session.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if busy { ProgressView().controlSize(.small) }
            if wide {
                if let branch = session.links.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
                }
                if let pr = session.links.pr {
                    Text("#\(pr.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            LedgerVerdictBadge(verdict: session.verdict)
            Text(LedgerTime.short(session.lastAt)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: wide ? 72 : 0, alignment: .trailing).fixedSize()
        }
    }

    private var subtitle: String {
        var parts = [session.kind]
        if let base = session.baseVersion {
            let current = session.baseCurrent ?? base
            parts.append(current == base ? base : base + " → " + current)
        }
        if behind > 0 { parts.append(String(localized: "\(behind) behind")) }
        if session.openQuestions > 0 { parts.append(String(localized: "Open questions: \(session.openQuestions)")) }
        return parts.joined(separator: " · ")
    }
}
