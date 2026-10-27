import SwiftUI

enum GraphMetrics {
    static let laneWidth: CGFloat = 22
    static let rowHeight: CGFloat = 30
    static let leftPad: CGFloat = 6
    /// Room between the last lane's avatar and the message bar; the lane band runs through it
    static let rightPad: CGFloat = 16
    static let maxVisibleLanes = 16
    /// 왼쪽 브랜치·태그 칸 너비
    static let refWidth: CGFloat = 190
    /// 커밋 동그라미(프로필) 지름
    static let avatar: CGFloat = 20

    static func width(lanes: Int) -> CGFloat {
        max(44, CGFloat(min(lanes, maxVisibleLanes)) * laneWidth + leftPad + rightPad)
    }

    /// Every lane side by side; past maxVisibleLanes the graph column scrolls sideways over this width
    static func contentWidth(lanes: Int) -> CGFloat {
        max(44, CGFloat(lanes) * laneWidth + leftPad + rightPad)
    }

    /// Keeps a sideways offset inside 0…(content − visible)
    static func clampOffset(_ offset: CGFloat, content: CGFloat, visible: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, content - visible))
    }

    /// The offset that brings a lane into the visible window, or the current one when it is already there
    static func offset(revealing lane: Int, current: CGFloat, content: CGFloat, visible: CGFloat) -> CGFloat {
        let left = leftPad + laneWidth * CGFloat(lane), right = left + laneWidth
        var offset = current
        if left < offset { offset = left - leftPad }
        if right > offset + visible - rightPad { offset = right + rightPad - visible }
        return clampOffset(offset, content: content, visible: visible)
    }

    static let authorWidth: CGFloat = 120
    static let timeWidth: CGFloat = 84

    /// 그래프 행의 칸: 브랜치·태그, 그래프, 커밋 메시지(제목 + 본문 첫 줄 + 오른쪽 끝에 시간).
    /// 좁으면 시간을 숨기고, 브랜치 칸, 그래프 칸(오른쪽 레인은 잘림) 순으로 줄여 메시지 칸을 지킨다.
    struct Columns: Equatable {
        var ref = GraphMetrics.refWidth
        var graph: CGFloat
        var author = false
        var time = false
    }

    private static let messageMin: CGFloat = 200

    /// hidden: the columns the user turned off ("ref", "graph"); shown: the optional ones turned on ("author", "time"),
    /// which are off by default. The message column always shows.
    static func columns(width: CGFloat, graph: CGFloat, hidden: Set<String> = [], shown: Set<String> = []) -> Columns {
        var c = Columns(graph: hidden.contains("graph") ? 0 : graph, author: shown.contains("author"), time: shown.contains("time"))
        if hidden.contains("ref") { c.ref = 0 }
        // 메시지 앞 막대·여백 20, 행 오른쪽 여백 12, 작성자·시간 칸
        func short() -> CGFloat { messageMin - (width - (c.ref + c.graph + 32 + (c.author ? authorWidth : 0) + (c.time ? timeWidth : 0))) }
        if short() > 0 { c.time = false }
        if short() > 0 { c.author = false }
        if short() > 0, c.ref > 0 { c.ref = max(110, c.ref - short()) }
        if short() > 0, c.graph > 0 { c.graph = max(min(graph, 66), c.graph - short()) }
        return c
    }
}

struct GraphView: View {
    @Environment(RepoStore.self) private var store
    @FocusState private var focused: Bool
    @ViewState private var width: CGFloat = 1000
    /// Columns the user turned off, comma-separated ("ref,graph")
    @AppStorage("graphHiddenColumns") private var hiddenColumns = ""
    /// Optional columns the user turned on ("author,time"); off by default
    @AppStorage("graphShownColumns") private var shownColumns = ""
    /// How far the lanes are scrolled sideways when there are more than fit
    @ViewState private var laneOffset: CGFloat = 0

    var body: some View {
        let graphWidth = GraphMetrics.width(lanes: store.maxLanes)
        let contentWidth = GraphMetrics.contentWidth(lanes: store.maxLanes)
        // 좁은 화면에서는 작성자·시간 칸을 숨기고 브랜치·그래프 칸을 줄여 커밋 메시지 칸을 지킨다
        let columns = GraphMetrics.columns(width: width, graph: graphWidth, hidden: Set(hiddenColumns.split(separator: ",").map(String.init)),
                                           shown: Set(shownColumns.split(separator: ",").map(String.init)))
        let offset = GraphMetrics.clampOffset(laneOffset, content: contentWidth, visible: columns.graph)
        VStack(spacing: 0) {
            if store.showSearchBar || store.isSearching {
                SearchBar()
                Divider()
            }
            GraphHeader(columns: columns, hidden: $hiddenColumns, shown: $shownColumns,
                        contentWidth: contentWidth, offset: offset) { laneOffset = GraphMetrics.clampOffset($0, content: contentWidth, visible: columns.graph) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            CommitRow(entry: entry,
                                      graphWidth: contentWidth,
                                      laneOffset: offset,
                                      columns: columns,
                                      refs: store.refsByCommit[entry.id] ?? [],
                                      selected: isSelected(entry),
                                      isHead: entry.id == store.headHash,
                                      wipCount: entry.commit.isWIP ? store.status.count
                                          : entry.commit.wipWorktree.map { store.worktreeStatus[$0]?.count ?? 0 } ?? 0,
                                      wipLabel: entry.commit.wipWorktree.map { p in store.worktrees.first { $0.path == p }?.branch ?? (p as NSString).lastPathComponent },
                                      match: matchState(entry),
                                      ci: store.ciBySha[entry.id])
                                .id(entry.id)
                                .onTapGesture {
                                    focused = true
                                    store.select(entry.commit.rowSelection)
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if let path = entry.commit.wipWorktree { Task { await store.switchWorktree(to: path) } }
                                })
                                // VoiceOver 등 접근성: 행 하나를 버튼처럼(메시지·작성자·날짜를 한 번에 읽고 눌러서 선택)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { store.select(entry.commit.rowSelection) }
                                .contextMenu { CommitMenu(commit: entry.commit) }
                        }
                        if store.hasMore {
                            Button("Load more commits") { Task { await store.loadMore() } }
                                .padding(12)
                        }
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                    store.scrollTarget = nil
                }
                // a selected commit whose lane is scrolled out of the graph column brings that lane into view
                .onChange(of: store.selection) { _, selection in
                    guard contentWidth > columns.graph, case .commit(let sha)? = selection,
                          let index = store.commitIndex[sha], store.entries.indices.contains(index) else { return }
                    laneOffset = GraphMetrics.offset(revealing: store.entries[index].row.column, current: offset,
                                                     content: contentWidth, visible: columns.graph)
                }
                .onAppear {
                    if let target = store.selectedID { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView("No commits yet", systemImage: "circle.dotted",
                                       description: Text("Create a file and make your first commit on the right."))
            }
        }
        .confirmationDialog(store.dropRequest?.title ?? "",
                            isPresented: Binding(get: { store.dropRequest != nil }, set: { if !$0 { store.dropRequest = nil } }),
                            titleVisibility: .visible,
                            presenting: store.dropRequest) { req in
            ForEach(req.choices) { c in
                Button(c.title, role: c.destructive ? .destructive : nil) { Task { await c.action() } }
            }
            Button(req.choices.isEmpty ? "OK" : "Cancel", role: .cancel) {}
        } message: { req in
            Text(req.message)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 검색 중이면 일치하는 행은 강조, 나머지는 흐리게
    private func matchState(_ e: GraphEntry) -> CommitRow.Match {
        guard store.isSearching, !store.searching || !store.searchMatchSet.isEmpty else { return .none }
        return store.searchMatchSet.contains(e.id) ? .hit : .miss
    }

    private func isSelected(_ e: GraphEntry) -> Bool {
        switch store.selection {
        case .wip?: return e.commit.isWIP
        case .worktree(let p)?: return e.commit.wipWorktree == p
        case .commit(let s)?: return e.id == s
        case .pullRequest?, nil: return false
        }
    }
}

extension RepoStore {
    var selectedID: String? {
        switch selection {
        case .wip?: return Commit.wipID
        case .worktree(let p)?: return Commit.worktreeWIP(path: p, parent: "").id
        case .commit(let s)?: return s
        case .pullRequest?, nil: return nil
        }
    }
}

/// 그래프 위 검색 줄
private struct SearchBar: View {
    @Environment(RepoStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.searchScope.prompt, text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { store.nextMatch() }
                    .onKeyPress(.escape) {
                        store.closeSearchBar()
                        focused = false
                        return .handled
                    }
                if store.searching { ProgressView().controlSize(.small) }
                if !store.searchText.isEmpty {
                    Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear search (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))

            Picker("", selection: $store.searchScope) {
                ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Search in")

            if store.isSearching {
                Text(resultText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ControlGroup {
                    Button { store.previousMatch() } label: { Image(systemName: "chevron.up") }
                        .help("Previous result (⇧⌘G)")
                    Button { store.nextMatch() } label: { Image(systemName: "chevron.down") }
                        .help("Next result (⌘G · Enter)")
                }
                .fixedSize()
                .disabled(store.searchMatches.isEmpty)
                if store.searchUnloaded > 0 && store.hasMore {
                    Button("Load more and search") { Task { await store.loadMoreForSearch() } }
                        .controlSize(.small)
                }
            }
            Button { store.closeSearchBar() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Close search (Esc)").accessibilityLabel("Close search")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: store.searchText) { store.updateSearch() }
        .onChange(of: store.searchScope) { store.updateSearch() }
        .onChange(of: store.searchFocusRequest) { focused = true }
        // the bar appears on ⌘F; take the keyboard as soon as it is on screen
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var resultText: String {
        if store.searchMatches.isEmpty {
            return store.searching ? String(localized: "Searching…") : String(localized: "No results")
        }
        let pos = store.searchPosition.map(String.init) ?? "–"
        var s = "\(pos)/\(store.searchMatches.count)"
        if store.searchUnloaded > 0 { s += String(localized: " · \(store.searchUnloaded) outside the graph") }
        return s
    }
}

private struct GraphHeader: View {
    let columns: GraphMetrics.Columns
    @Binding var hidden: String
    @Binding var shown: String
    let contentWidth: CGFloat
    let offset: CGFloat
    let onScroll: (CGFloat) -> Void
    private var scrolls: Bool { columns.graph > 0 && contentWidth > columns.graph }

    var body: some View {
        HStack(spacing: 0) {
            if columns.ref > 0 { Text("Branch / Tag").padding(.leading, 10).frame(width: columns.ref, alignment: .leading) }
            if columns.graph > 0 {
                // with more lanes than fit, a scrollbar sits under the label
                VStack(alignment: .leading, spacing: 1) {
                    Text("Graph").padding(.leading, 6)
                    if scrolls {
                        LaneScroller(visible: columns.graph, content: contentWidth, offset: offset, onScroll: onScroll)
                    }
                }
                .frame(width: columns.graph, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text("Commit message")
                // the graph filter lives here so it stays reachable while the search bar is hidden
                GraphFilterMenu()
                Menu { toggles } label: { Image(systemName: "rectangle.split.3x1") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Columns")
            }
            .padding(.leading, 20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if columns.author { Text("Author").frame(width: GraphMetrics.authorWidth, alignment: .leading) }
            if columns.time { Text("Time").frame(width: GraphMetrics.timeWidth, alignment: .trailing) }
        }
        .contextMenu { toggles }
        .lineLimit(1)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.trailing, 12)
        .frame(height: scrolls ? 32 : 26)
        .background(.bar)
    }

    /// Which columns show; the message column always does
    @ViewBuilder private var toggles: some View {
        Toggle("Branch / Tag", isOn: SidebarSections.binding($hidden, "ref"))
        Toggle("Graph", isOn: SidebarSections.binding($hidden, "graph"))
        Divider()
        Toggle("Author", isOn: optional("author"))
        Toggle("Time", isOn: optional("time"))
    }

    /// The optional columns are listed when shown, so they stay off until turned on
    private func optional(_ id: String) -> Binding<Bool> {
        Binding(get: { shown.split(separator: ",").contains(Substring(id)) }, set: { on in
            var set = shown.split(separator: ",").map(String.init).filter { $0 != id }
            if on { set.append(id) }
            shown = set.joined(separator: ",")
        })
    }
}

/// A thin scrollbar under the graph column header when there are more lanes than fit; drag it, or scroll sideways over it
private struct LaneScroller: View {
    let visible: CGFloat
    let content: CGFloat
    let offset: CGFloat
    let onScroll: (CGFloat) -> Void
    @ViewState private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.width - 8
            let thumb = max(24, track * visible / content)
            let travel = max(1, track - thumb)
            let x = 4 + travel * offset / max(1, content - visible)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(width: track, height: 4).offset(x: 4)
                Capsule().fill(Color.secondary.opacity(0.55)).frame(width: thumb, height: 4).offset(x: x)
            }
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let start = dragStart ?? offset
                if dragStart == nil { dragStart = start }
                onScroll(start + value.translation.width * (content - visible) / travel)
            }.onEnded { _ in dragStart = nil })
            .help("Scroll the graph sideways")
        }
        .frame(height: 8)
        .background(SideScrollCatcher { delta in onScroll(offset - delta) })
    }
}

/// Sideways trackpad or Shift-wheel scrolling over the header; vertical wheel events pass on
private struct SideScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }
    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            let dx = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(dx) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) else { return super.scrollWheel(with: event) }
            onScroll?(dx)
        }
    }
}

/// 그래프 거르기: 현재 브랜치만 보기, 숨긴 브랜치 다시 보이기
private struct GraphFilterMenu: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        let hidden = store.hiddenRefs.count
        let active = store.graphCurrentOnly || hidden > 0
        Menu {
            Toggle("Show only the current branch", isOn: Binding(get: { store.graphCurrentOnly }, set: { on in Task { await store.setCurrentOnly(on) } }))
            Divider()
            Button(hidden > 0 ? "Show all \(hidden) hidden branches" : "No hidden branches") { Task { await store.showAllBranches() } }
                .disabled(hidden == 0)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                if store.graphCurrentOnly { Text("Current branch only").font(.caption) }
                else if hidden > 0 { Text("Hidden \(hidden)").font(.caption) }
            }
            .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter graph — show only the current branch, show hidden branches again (hide them by right-clicking in the sidebar)")
        .accessibilityLabel("Filter graph")
    }
}
