import SwiftUI
import AppKit
import Darwin
import SwiftTerm

/// 가운데 열: 그래프(또는 diff) 위, 터미널 패널 아래. 경계선을 끌어 높이를 바꾼다.
struct ContentColumn: View {
    @Environment(RepoStore.self) private var store
    @AppStorage("terminalHeight") private var terminalHeight = 260.0
    @ViewState private var columnHeight: CGFloat = 800
    @AppStorage("changesListWidth") private var changesWidth = 300.0
    @AppStorage("historyInspectorWidth") private var inspectorWidth = 320.0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.area == .changes {
                    WorkspaceColumns(width: $changesWidth, fixedTrailing: false, minimumFlexible: 380) {
                        WorkingChangesView()
                    } trailing: {
                        VStack(spacing: 0) {
                            document.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            Divider()
                            CommitComposer()
                        }
                    }
                } else {
                    WorkspaceColumns(width: $inspectorWidth, fixedTrailing: true, minimumFlexible: 410) {
                        document
                    } trailing: {
                        InspectorView()
                    }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            if store.showTerminal {
                let range = 100.0...max(100.0, Double(columnHeight) - 440)
                TerminalPanel()
                    .frame(height: min(max(terminalHeight, range.lowerBound), range.upperBound))
                    .overlay(alignment: .top) {
                        SplitHandle(height: $terminalHeight, range: range)
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
    }

    @ViewBuilder private var document: some View {
        if let f = store.fileInspect {
            FileInspectView(inspect: f)
        } else if let source = store.diffSource {
            DiffView(source: source)
        } else if store.area == .history {
            GraphView()
        } else {
            ContentUnavailableView(store.status.isEmpty ? "Working directory is clean" : "Select a file to review",
                systemImage: store.status.isEmpty ? "checkmark.circle" : "doc.text.magnifyingglass",
                description: Text(store.status.isEmpty ? "Modified files appear here." : "Review changes, then stage the files or lines you want to commit."))
        }
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

struct TerminalPanel: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            Divider()
            ZStack {
                Color(nsColor: TerminalSession.background)
                if let s = store.activeTerminal {
                    TerminalHost(session: s)
                        .id(s.id)
                        .padding(.leading, 8)
                        .padding(.top, 4)
                    if !s.running {
                        ended(s)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.terminal")
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.terminals.enumerated()), id: \.element.id) { i, s in
                        TerminalTab(session: s, number: store.terminals.count > 1 ? i + 1 : nil,
                                    selected: s.id == store.activeTerminal?.id,
                                    select: { store.selectTerminal(s) },
                                    close: { store.requestCloseTerminal(s) })
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button { store.newTerminal() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .hoverTip(String(localized: "New terminal"), String(localized: "Opens another shell in the repository folder."))
            Spacer(minLength: 8)
            if let s = store.activeTerminal {
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
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    private func ended(_ s: TerminalSession) -> some View {
        VStack(spacing: 8) {
            Text(s.exitCode.map { "The shell exited (code \($0))" } ?? "The shell exited")
                .foregroundStyle(.secondary)
            HStack {
                Button("Restart") { s.start(); s.focus() }
                    .keyboardShortcut(.defaultAction)
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

    func makeNSView(context: Context) -> TerminalContainer {
        let c = TerminalContainer()
        c.attach(session)
        return c
    }

    func updateNSView(_ c: TerminalContainer, context: Context) {
        c.attach(session)
    }

    static func dismantleNSView(_ c: TerminalContainer, coordinator: ()) {
        c.session?.isVisible = false
    }
}

private final class TerminalContainer: NSView {
    private(set) weak var session: TerminalSession?

    func attach(_ s: TerminalSession) {
        if session === s, s.view.superview === self { return }
        session?.isVisible = false
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

    private func focusSoon() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, let w = self.window, s.view.superview === self else { return }
                s.applyColors(for: self.effectiveAppearance)
                w.makeFirstResponder(s.view)
            }
        }
    }
}
