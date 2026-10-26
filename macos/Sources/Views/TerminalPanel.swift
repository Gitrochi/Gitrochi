import SwiftUI
import AppKit
import Darwin
import SwiftTerm

/// 가운데 열: 그래프(또는 diff) 위, 터미널 패널 아래. 경계선을 끌어 높이를 바꾼다.
struct ContentColumn: View {
    @Environment(RepoStore.self) private var store
    @AppStorage("terminalHeight") private var terminalHeight = 260.0
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
            .frame(maxHeight: .infinity)

            if store.showTerminal {
                let range = 120.0...max(120.0, Double(columnHeight) - 200)
                TerminalPanel()
                    .frame(height: min(max(terminalHeight, range.lowerBound), range.upperBound))
                    .overlay(alignment: .top) {
                        SplitHandle(height: $terminalHeight, range: range)
                    }
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

/// The terminal panel: panes split right or down, each with its own tabs
struct TerminalPanel: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let layout = store.terminalLayout {
                TerminalNodeView(node: layout, corner: layout.corner.id, split: layout.panes.count > 1)
            }
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

    var body: some View {
        GeometryReader { geo in
            let side = axis == .sideBySide
            let total = side ? geo.size.width : geo.size.height
            let first = max(0, total * ratio - 0.5)
            let stack = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                TerminalNodeView(node: a, corner: corner, split: split)
                    .frame(width: side ? first : nil, height: side ? nil : first)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: side ? 1 : nil, height: side ? nil : 1)
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
        }
    }
}

private struct TerminalPaneView: View {
    @Environment(RepoStore.self) private var store
    let pane: TerminalNode.Pane
    let isCorner: Bool
    let split: Bool

    var body: some View {
        let shown = store.shownTerminal(in: pane)
        let focused = shown != nil && shown?.id == store.activeTerminal?.id
        VStack(spacing: 0) {
            header(shown)
                .overlay(alignment: .bottom) {
                    if split && focused { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
            Divider()
            ZStack {
                Color(nsColor: TerminalSession.background)
                if let s = shown {
                    TerminalHost(session: s, focus: focused)
                        .id(s.id)
                        .padding(.leading, 8)
                        .padding(.top, 4)
                    if !s.running {
                        ended(s, focused: focused)
                    }
                }
            }
        }
    }

    private func header(_ shown: TerminalSession?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.terminal")
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(pane.sessions, id: \.self) { id in
                        if let s = store.terminals.first(where: { $0.id == id }) {
                            TerminalTab(session: s,
                                        number: store.terminals.count > 1 ? (store.terminals.firstIndex { $0.id == id } ?? 0) + 1 : nil,
                                        selected: s.id == shown?.id,
                                        select: { store.selectTerminal(s) },
                                        close: { store.requestCloseTerminal(s) })
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button {
                if let shown { store.selectTerminal(shown) }
                store.newTerminal()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .hoverTip(String(localized: "New terminal"), String(localized: "Opens another shell in the repository folder."))
            Button { store.splitTerminal(pane, .sideBySide) } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .hoverTip(String(localized: "Split right"), String(localized: "Opens another shell next to this one, in the same folder."))
            Button { store.splitTerminal(pane, .stacked) } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .buttonStyle(.borderless)
            .hoverTip(String(localized: "Split down"), String(localized: "Opens another shell below this one, in the same folder."))
            Spacer(minLength: 8)
            if isCorner {
                if let s = shown {
                    Button { Launcher.openTerminal(at: s.directory) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .hoverTip(String(localized: "Open in Terminal"), String(localized: "Opens the current folder (\(abbreviate(s.directory))) in a new macOS Terminal window."))
                }
                Button { store.showTerminal = false } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .hoverTip(String(localized: "Hide terminal"), String(localized: "Only the panel is hidden; shells keep running."), shortcut: "⌃`")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    private func ended(_ s: TerminalSession, focused: Bool) -> some View {
        VStack(spacing: 8) {
            Group {
                if s.command != nil {
                    Text(s.exitCode.map { "The process exited (code \($0))" } ?? "The process exited")
                } else {
                    Text(s.exitCode.map { "The shell exited (code \($0))" } ?? "The shell exited")
                }
            }
                .foregroundStyle(.secondary)
            HStack {
                Button("Restart") { s.start(); s.focus() }
                    .keyboardShortcut(focused ? .defaultAction : nil)
                Button("Close") { store.closeTerminal(s) }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    /// 같은 폴더 이름의 탭을 구분하려고 여러 개일 때만 번호를 붙인다
    let number: Int?
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(session.running ? (session.unseenOutput ? Color.accentColor : Color.green) : Color.secondary)
                .frame(width: 6, height: 6)
            if let number {
                Text("\(number)").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close terminal")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(selected ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(session.directory)
    }
}

/// 세션의 터미널 뷰를 SwiftUI 안에 붙인다. 뷰는 세션이 들고 있어 탭을 바꿔도 화면과 셸이 그대로다.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// With several panes only the focused one takes the keyboard
    var focus = true

    func makeNSView(context: Context) -> TerminalContainer {
        let c = TerminalContainer()
        c.takesFocus = focus
        c.attach(session)
        return c
    }

    func updateNSView(_ c: TerminalContainer, context: Context) {
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
