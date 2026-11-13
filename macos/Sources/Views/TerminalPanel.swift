import SwiftUI
import AppKit
import Darwin
import SwiftTerm

/// The middle column of the repository screen: graph, diff or file history above, the terminal below
struct ContentColumn: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var columnHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let f = store.fileInspect {
                    FileInspectView(inspect: f)
                } else if let source = store.diffSource {
                    DiffView(source: source)
                } else {
                    GraphView()
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            if store.showTerminal {
                TerminalPanel(columnHeight: columnHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
    }
}

/// 위아래 크기 조절 손잡이(보이는 선은 1pt, 잡는 영역은 9pt)
private struct SplitHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @ViewState private var startHeight: Double?

    var body: some View {
        Color.clear
            .frame(height: 9)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = startHeight ?? height
                        if startHeight == nil { startHeight = start }
                        height = min(max(start - v.translation.height, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startHeight = nil }
            )
            .offset(y: -4.5)
    }
}

/// The terminal panel: panes split right or down, each with its own tabs. Its top edge drags to resize it, and every
/// page shares the height. It docks under the centre column only: the sidebar and the right panel keep the full window
/// height (docs/design.md › App shell). (Windows: widgets/terminal-panel/ui/TerminalPanel.tsx)
struct TerminalPanel: View {
    @Environment(RepoStore.self) private var store
    @AppStorage("terminalHeight") private var terminalHeight = 260.0
    /// The height of the column the panel sits in; the content above keeps at least 200 pt
    let columnHeight: CGFloat

    var body: some View {
        let range = 120.0...max(120.0, Double(columnHeight) - 200)
        VStack(spacing: 0) {
            Divider()
            if let layout = store.terminalLayout {
                TerminalNodeView(node: layout, corner: layout.corner.id, split: layout.panes.count > 1)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(height: min(max(terminalHeight, range.lowerBound), range.upperBound))
        .overlay(alignment: .top) {
            SplitHandle(height: $terminalHeight, range: range)
        }
    }
}

private struct TerminalNodeView: View {
    let node: TerminalNode
    let corner: UUID
    /// More than one pane: mark the focused one
    let split: Bool

    var body: some View {
        switch node {
        case .pane(let p):
            TerminalPaneView(pane: p, isCorner: p.id == corner, split: split)
        case .split(let id, let axis, let ratio, let a, let b):
            TerminalSplitView(id: id, axis: axis, ratio: ratio, a: a, b: b, corner: corner, split: split)
        }
    }
}

private struct TerminalSplitView: View {
    @Environment(RepoStore.self) private var store
    let id: UUID
    let axis: TerminalNode.Axis
    let ratio: Double
    let a: TerminalNode
    let b: TerminalNode
    let corner: UUID
    let split: Bool
    /// Only for turning a drag into a ratio; the layout itself reads the space it is given
    @ViewState private var total: CGFloat = 0

    var body: some View {
        let side = axis == .sideBySide
        TerminalSplitLayout(sideBySide: side, ratio: ratio) {
            TerminalNodeView(node: a, corner: corner, split: split)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .overlay {
                    // a wider grab area than the 1pt line
                    Color.clear
                        .frame(width: side ? 7 : nil, height: side ? nil : 7)
                        .contentShape(Rectangle())
                        .pointerStyle(side ? .columnResize : .rowResize)
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named(id))
                                .onChanged { v in
                                    guard total > 0 else { return }
                                    store.resizeTerminalSplit(id, to: (side ? v.location.x : v.location.y) / total)
                                }
                        )
                }
            TerminalNodeView(node: b, corner: corner, split: split)
        }
        .coordinateSpace(.named(id))
        .onGeometryChange(for: CGFloat.self) { side ? $0.size.width : $0.size.height } action: { total = $0 }
    }
}

/// Places the first pane, the 1pt divider and the second pane in the space the split is given. A GeometryReader here
/// sized the first pane from the new size but kept both panes in the old frame after a window resize.
private struct TerminalSplitLayout: Layout {
    let sideBySide: Bool
    let ratio: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let total = sideBySide ? bounds.width : bounds.height
        let first = min(max(0, total * ratio - 0.5), max(0, total - 1))
        var offset: CGFloat = 0
        for (view, length) in zip(subviews, [first, 1, max(0, total - first - 1)]) {
            if sideBySide {
                view.place(at: CGPoint(x: bounds.minX + offset, y: bounds.minY), proposal: ProposedViewSize(width: length, height: bounds.height))
            } else {
                view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + offset), proposal: ProposedViewSize(width: bounds.width, height: length))
            }
            offset += length
        }
    }
}

private struct TerminalPaneView: View {
    @Environment(RepoStore.self) private var store
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    /// The bar, the rail and the status line fold by the pane's own size, so a split pane folds before the panel does
    @ViewState private var paneSize = CGSize(width: 800, height: 260)
    let pane: TerminalNode.Pane
    let isCorner: Bool
    let split: Bool

    var body: some View {
        let shown = store.shownTerminal(in: pane)
        let focused = shown != nil && shown?.id == store.activeTerminal?.id
        VStack(spacing: 0) {
            tabBar(shown, focused: !split || focused)
            Divider()
            ZStack {
                Color(nsColor: TerminalSession.background)
                if let session = shown {
                    TerminalHost(session: session, focus: focused, fontSize: fontSize)
                        .id(session.id)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    if !session.running { ended(session, focused: focused) }
                }
            }
            if TerminalPanelLayout.railShown(height: paneSize.height) {
                TerminalQuickActions(enabled: shown?.running == true, width: paneSize.width) { command in
                    insert(command.command, into: shown)
                }
            }
            if let session = shown {
                TerminalStatusBar(directory: session.directory, activity: session.tabStatus.activity,
                                  program: session.command?.title ?? URL(fileURLWithPath: TerminalSession.loginShell).lastPathComponent,
                                  branch: session.directory == store.url?.path ? store.currentBranch?.name : nil,
                                  unseenCount: store.terminals.filter(\.unseenOutput).count,
                                  width: paneSize.width,
                                  copyDirectory: {
                                      NSPasteboard.general.clearContents()
                                      NSPasteboard.general.setString(session.directory, forType: .string)
                                  }, nextUnseen: {
                                      if let next = store.terminals.first(where: \.unseenOutput) { store.selectTerminal(next) }
                                  })
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { paneSize = $0 }
    }

    private func tabBar(_ shown: TerminalSession?, focused: Bool) -> some View {
        let session = { (id: UUID) in store.terminals.first { $0.id == id } }
        let tabs = pane.sessions.compactMap(session).map { session in
            let status = session.tabStatus
            return TerminalTabItem(id: session.id, title: session.title, directory: session.directory,
                                   number: store.terminals.count > 1 ? (store.terminals.firstIndex { $0.id == session.id } ?? 0) + 1 : nil,
                                   mark: status.mark, state: status.title)
        }
        return TerminalTabBar(tabs: tabs, selected: shown?.id, focused: focused, width: paneSize.width, corner: isCorner,
                              voiceOn: store.terminalVoice.presented && store.terminalVoice.context?.sessionID == shown?.id,
                              voiceEnabled: shown?.running == true,
                              select: { if let s = session($0) { store.selectTerminal(s) } },
                              close: { if let s = session($0) { store.requestCloseTerminal(s) } },
                              newTerminal: { newTerminal(at: shown) },
                              voice: { openDictation(for: shown) },
                              hide: { store.showTerminal = false }) {
            Section("Insert command") {
                ForEach(TerminalQuickCommand.allCases) { command in
                    Button { insert(command.command, into: shown) } label: { Text(command.title) }
                }
            }
            .disabled(shown?.running != true)
            Section {
                Button("Split right", symbol: "rectangle.split.2x1") { store.splitTerminal(pane, .sideBySide) }
                Button("Split down", symbol: "rectangle.split.1x2") { store.splitTerminal(pane, .stacked) }
                if let shown {
                    Button("Open in Terminal", symbol: "arrow.up.forward.app") { Launcher.openTerminal(at: shown.directory) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func newTerminal(at session: TerminalSession?) {
        if let session { store.selectTerminal(session) }
        store.newTerminal(in: session?.directory)
    }

    private func openDictation(for session: TerminalSession?) {
        guard let session, session.running else { return }
        store.terminalVoice.open(for: session)
    }

    private func insert(_ text: String, into session: TerminalSession?) {
        guard let session, session.running else { return }
        store.selectTerminal(session)
        session.insertText(text)
        session.focus()
    }

    private func ended(_ session: TerminalSession, focused: Bool) -> some View {
        VStack(spacing: 10) {
            SymbolIcon(session.exitCode == 0 ? "checkmark.circle" : "terminal")
                .font(.title2).foregroundStyle(.secondary)
            Text(session.command != nil ? "The process exited" : "The shell exited")
                .font(.headline)
            if let code = session.exitCode {
                Text("Exit code: \(code)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restart") { session.start(); session.focus() }
                    .keyboardShortcut(focused ? .defaultAction : nil)
                Button("Close") { store.closeTerminal(session) }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 세션의 터미널 뷰를 SwiftUI 안에 붙인다. 뷰는 세션이 들고 있어 탭을 바꿔도 화면과 셸이 그대로다.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// With several panes only the focused one takes the keyboard
    var focus = true
    var fontSize = 13.0

    func makeNSView(context: Context) -> TerminalContainer {
        let c = TerminalContainer()
        session.applyFont(size: fontSize)
        c.takesFocus = focus
        c.attach(session)
        return c
    }

    func updateNSView(_ c: TerminalContainer, context: Context) {
        session.applyFont(size: fontSize)
        let gained = focus && !c.takesFocus
        c.takesFocus = focus
        if c.session !== session {
            c.attach(session)
        } else if gained {
            // the pane marked focused takes the keyboard (selecting another pane's tab)
            c.focusSoon()
        }
        // Not re-attached otherwise: when a split collapses, SwiftUI still updates the old container after a new one
        // has taken the terminal view, and attaching here would pull the view back into a container about to be removed
    }

    static func dismantleNSView(_ c: TerminalContainer, coordinator: ()) {
        c.detach()
    }
}

private final class TerminalContainer: NSView {
    private(set) weak var session: TerminalSession?
    var takesFocus = true

    func attach(_ s: TerminalSession) {
        if session === s, s.view.superview === self { return }
        detach()
        session = s
        subviews.forEach { $0.removeFromSuperview() }
        let v = s.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        s.isVisible = true
        s.unseenOutput = false
        focusSoon()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusSoon() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        session?.applyColors(for: effectiveAppearance)
    }

    /// The terminal view stays with its session; it only counts as hidden if this container still holds it
    func detach() {
        guard let s = session, s.view.superview === self else { return }
        s.isVisible = false
    }

    func focusSoon() {
        guard takesFocus else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, let w = self.window, s.view.superview === self else { return }
                s.applyColors(for: self.effectiveAppearance)
                w.makeFirstResponder(s.view)
            }
        }
    }
}

extension TerminalSession {
    /// What the tab's status slot and the status line show for this terminal (Windows: tabStatus in TerminalTabBar.tsx)
    var tabStatus: (mark: TerminalTabMark, activity: TerminalActivity, title: String) {
        let state = TerminalPanelLayout.tabActivity(agent: AgentCenter.shared.status(in: self)?.rawValue, shellBusy: busy)
        let mark = TerminalPanelLayout.tabMark(exited: !running, busy: state.busy, unseen: unseenOutput, waiting: state.waiting)
        let title: String
        switch mark {
        case .ring: title = String(localized: "Running")
        case .hollow: title = String(localized: "Exited")
        case .dot: title = state.waiting ? String(localized: "Waiting for input") : String(localized: "New output")
        case .none: title = String(localized: "Idle")
        }
        return (mark, TerminalPanelLayout.activity(exited: !running, busy: state.busy), title)
    }
}
