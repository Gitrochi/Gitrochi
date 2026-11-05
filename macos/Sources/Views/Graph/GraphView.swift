import SwiftUI

enum GraphMetrics {
    static let laneWidth: CGFloat = 22
    static let rowHeight: CGFloat = 30
    static let leftPad: CGFloat = 6
    /// Room between the last lane's avatar and the message bar; the lane band runs through it
    static let rightPad: CGFloat = 16
    /// Eight lanes wide at most; more lanes scroll sideways inside the column
    static let maxVisibleLanes = 8
    /// 왼쪽 브랜치·태그 칸 너비
    static let refWidth: CGFloat = 190
    /// 커밋 동그라미(프로필) 지름
    static let avatar: CGFloat = 20

    static func width(lanes: Int) -> CGFloat {
        max(44, CGFloat(min(lanes, maxVisibleLanes)) * laneWidth + leftPad + rightPad)
    }

    /// The graph column's width: the one the user dragged it to, never wider than every lane, or else the lane count's
    static func width(lanes: Int, dragged: CGFloat?) -> CGFloat {
        dragged.map { min($0, contentWidth(lanes: lanes)) } ?? width(lanes: lanes)
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

    /// The optional columns after the message, in order; the user drags their header edges to change their widths
    static let optionalColumns = ["author", "time", "sha"]
    /// The branch, graph and message columns are dragged by their right edges. The graph and the message have no stored default:
    /// the graph follows the lane count and the message takes the room left over until they are dragged
    static let resizableColumns = ["ref", "graph", "message"] + optionalColumns
    static let defaultWidths: [String: CGFloat] = ["author": 120, "time": 84, "sha": 72]
    static func widthRange(_ id: String) -> ClosedRange<CGFloat> {
        switch id {
        case "ref": return 80...420
        case "graph": return 44...1200
        case "message": return 200...4000
        case "author": return 60...320
        case "time": return 60...220
        default: return 50...140
        }
    }

    /// Reads "ref:240,author:140,sha:80" (what the header's drags store) into widths inside each column's range
    static func widths(_ stored: String) -> [String: CGFloat] {
        var widths = defaultWidths
        for pair in stored.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let id = parts.first.map(String.init), let value = Double(parts[1]), resizableColumns.contains(id) else { continue }
            widths[id] = min(max(CGFloat(value), widthRange(id).lowerBound), widthRange(id).upperBound)
        }
        return widths
    }

    /// Room between an optional column's left edge, where its resize handle is, and its text
    static let columnInset: CGFloat = 8

    /// The column header and the commit detail header share this height so their dividers line up
    static let headerHeight: CGFloat = 32
    /// The filter and column menus at the right end of the header; rows keep this much room when right-hand columns show
    static let headerToolsWidth: CGFloat = 60

    /// 그래프 행의 칸: 브랜치·태그, 그래프, 커밋 메시지, 그리고 켠 경우 작성자·시간·SHA.
    /// 좁으면 SHA·시간·작성자 순으로 숨기고, 브랜치 칸, 그래프 칸(오른쪽 레인은 잘림) 순으로 줄여 메시지 칸을 지킨다.
    struct Columns: Equatable {
        var ref = GraphMetrics.refWidth
        var graph: CGFloat
        /// The optional right-hand columns' widths; 0 when off or left out for room
        var author: CGFloat = 0
        var time: CGFloat = 0
        var sha: CGFloat = 0
        var trailing: CGFloat { author + time + sha }
    }

    private static let messageMin: CGFloat = 200

    /// The width the rows are laid out at: the window's, or wider when the message column was dragged past it, and then they scroll sideways
    static func tableWidth(width: CGFloat, graph: CGFloat, hidden: Set<String> = [], shown: Set<String> = [],
                           widths: [String: CGFloat] = defaultWidths) -> CGFloat {
        guard let message = widths["message"] else { return width }
        let c = columns(width: .greatestFiniteMagnitude, graph: graph, hidden: hidden, shown: shown, widths: widths)
        return max(width, c.ref + c.graph + message + c.trailing + headerToolsWidth + 12)
    }

    /// The message header's width in rows laid out `width` wide: what is left after the other columns, the menus and the right margin
    static func messageWidth(width: CGFloat, columns c: Columns) -> CGFloat {
        max(0, width - (c.ref + c.graph + c.trailing + headerToolsWidth + 12))
    }

    /// hidden: the columns the user turned off ("ref", "graph"); shown: the optional ones turned on ("author", "time", "sha"),
    /// which are off by default. The message column always shows.
    static func columns(width: CGFloat, graph: CGFloat, hidden: Set<String> = [], shown: Set<String> = [],
                        widths: [String: CGFloat] = defaultWidths) -> Columns {
        func optional(_ id: String) -> CGFloat { shown.contains(id) ? widths[id] ?? defaultWidths[id] ?? 0 : 0 }
        var c = Columns(ref: widths["ref"] ?? refWidth, graph: hidden.contains("graph") ? 0 : graph,
                        author: optional("author"), time: optional("time"), sha: optional("sha"))
        if hidden.contains("ref") { c.ref = 0 }
        // 메시지 앞 막대·여백 20, 행 오른쪽 여백 12, 오른쪽 칸과 그 위 머리의 메뉴 자리
        func short() -> CGFloat { messageMin - (width - (c.ref + c.graph + 32 + c.trailing + (c.trailing > 0 ? headerToolsWidth : 0))) }
        if short() > 0 { c.sha = 0 }
        if short() > 0 { c.time = 0 }
        if short() > 0 { c.author = 0 }
        if short() > 0, c.ref > 0 { c.ref = max(min(c.ref, 110), c.ref - short()) }
        if short() > 0, c.graph > 0 { c.graph = max(min(graph, 66), c.graph - short()) }
        return c
    }
}

struct GraphView: View {
    @Environment(RepoStore.self) private var store
    @FocusState private var focused: Bool
    /// Columns the user turned off, comma-separated ("ref,graph")
    @AppStorage("graphHiddenColumns") private var hiddenColumns = ""
    /// Optional columns the user turned on ("author,time,sha"); off by default
    @AppStorage("graphShownColumns") private var shownColumns = ""
    /// Widths the user dragged the columns to ("ref:240,graph:120,author:140")
    @AppStorage("graphColumnWidths") private var columnWidths = ""
    /// How far the lanes are scrolled sideways when there are more than fit
    @ViewState private var laneOffset: CGFloat = 0
    /// How far the rows are scrolled sideways when the message column was dragged wider than the window
    @ViewState private var tableOffset: CGFloat = 0

    var body: some View {
        // The column's width comes straight from the layout. Kept in state, every resize laid the rows out twice: at
        // the new width, and again once the state caught up — on each frame while the page list folds or opens.
        GeometryReader { geometry in
            table(width: geometry.size.width)
        }
    }

    private func table(width: CGFloat) -> some View {
        let widths = GraphMetrics.widths(columnWidths)
        let graphWidth = GraphMetrics.width(lanes: store.maxLanes, dragged: widths["graph"])
        let contentWidth = GraphMetrics.contentWidth(lanes: store.maxLanes)
        let hidden = Set(hiddenColumns.split(separator: ",").map(String.init)), shown = Set(shownColumns.split(separator: ",").map(String.init))
        let tableWidth = GraphMetrics.tableWidth(width: width, graph: graphWidth, hidden: hidden, shown: shown, widths: widths)
        let wide = tableWidth > width
        let table = GraphMetrics.clampOffset(tableOffset, content: tableWidth, visible: width)
        // 좁은 화면에서는 작성자·시간 칸을 숨기고 브랜치·그래프 칸을 줄여 커밋 메시지 칸을 지킨다
        let columns = GraphMetrics.columns(width: tableWidth, graph: graphWidth, hidden: hidden, shown: shown, widths: widths)
        let offset = GraphMetrics.clampOffset(laneOffset, content: contentWidth, visible: columns.graph)
        return VStack(spacing: 0) {
            if store.showSearchBar || store.isSearching {
                SearchBar()
                Divider()
            }
            GraphHeader(columns: columns, hidden: $hiddenColumns, shown: $shownColumns, widths: $columnWidths,
                        contentWidth: contentWidth, offset: offset,
                        tableWidth: wide ? tableWidth : nil, tableOffset: wide ? table : 0,
                        messageWidth: GraphMetrics.messageWidth(width: tableWidth, columns: columns),
                        messageFit: GraphMetrics.messageWidth(width: width, columns: columns),
                        // while the message edge is dragged the rows stay scrolled to their end, so the edge stays under the pointer
                        onMessageResize: { tableOffset = .greatestFiniteMagnitude }) { laneOffset = GraphMetrics.clampOffset($0, content: contentWidth, visible: columns.graph) }
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
                    .frame(width: wide ? tableWidth : nil, alignment: .leading)
                    .offset(x: wide ? -table : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottom) {
                    if wide {
                        LaneScroller(visible: width, content: tableWidth, offset: table) {
                            tableOffset = GraphMetrics.clampOffset($0, content: tableWidth, visible: width)
                        }
                        .padding(.bottom, 2)
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
        .background(SideScrollMonitor(active: contentWidth > columns.graph || wide) { delta, x in
            // with the rows wider than the window, a swipe over the graph column still moves its lanes and anywhere else moves the rows
            let overGraph = (columns.ref..<(columns.ref + columns.graph)).contains(x + table)
            if contentWidth > columns.graph, !wide || overGraph {
                // read the stored offset, not the one from the last render: several wheel events can arrive in between
                let current = GraphMetrics.clampOffset(laneOffset, content: contentWidth, visible: columns.graph)
                laneOffset = GraphMetrics.clampOffset(current - delta, content: contentWidth, visible: columns.graph)
            } else if wide {
                let current = GraphMetrics.clampOffset(tableOffset, content: tableWidth, visible: width)
                tableOffset = GraphMetrics.clampOffset(current - delta, content: tableWidth, visible: width)
            }
        })
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
    @Binding var widths: String
    let contentWidth: CGFloat
    let offset: CGFloat
    /// The rows' width and sideways scroll when they are wider than the window; nil and 0 otherwise
    let tableWidth: CGFloat?
    let tableOffset: CGFloat
    /// The message header's width, and its width when the rows fit the window, below which its drag stops
    let messageWidth: CGFloat
    let messageFit: CGFloat
    let onMessageResize: () -> Void
    let onScroll: (CGFloat) -> Void
    private var scrolls: Bool { columns.graph > 0 && contentWidth > columns.graph }

    var body: some View {
        HStack(spacing: 0) {
            if columns.ref > 0 {
                Text("Branch / Tag").padding(.leading, 10).frame(width: columns.ref, alignment: .leading)
                    .overlay(alignment: .trailing) { trailingResizer("ref", width: columns.ref, range: GraphMetrics.widthRange("ref")) }
                    .zIndex(1)
            }
            if columns.graph > 0 {
                // with more lanes than fit, a scrollbar sits under the label
                VStack(alignment: .leading, spacing: 1) {
                    Text("Graph").padding(.leading, 6)
                    if scrolls {
                        LaneScroller(visible: columns.graph, content: contentWidth, offset: offset, onScroll: onScroll)
                    }
                }
                .frame(width: columns.graph, alignment: .leading)
                // dragging past every lane would only add empty room
                .overlay(alignment: .trailing) { trailingResizer("graph", width: columns.graph, range: 44...max(44, contentWidth)) }
                .zIndex(1)
            }
            Text("Commit message").padding(.leading, 20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // dragged past the window, the message gets longer and the rows scroll sideways; an optional column's
                // handle already sits on this edge when one follows
                .overlay(alignment: .trailing) {
                    if columns.trailing == 0 {
                        ColumnResizer(width: messageWidth, range: messageFit...max(messageFit, GraphMetrics.widthRange("message").upperBound),
                                      edge: .trailing) { value in
                            resize("message", to: value > messageFit + 1 ? value : nil)
                            onMessageResize()
                        }
                        .offset(x: 4)
                    }
                }
                .zIndex(1)
            if columns.author > 0 { label("Author", id: "author", width: columns.author) }
            if columns.time > 0 { label("Date", id: "time", width: columns.time) }
            if columns.sha > 0 { label("SHA", id: "sha", width: columns.sha) }
            // the menus sit over this room, pinned to the header's right end while the rows scroll sideways
            Color.clear.frame(width: GraphMetrics.headerToolsWidth)
        }
        .contextMenu { toggles }
        .padding(.trailing, 12)
        .frame(width: tableWidth)
        .offset(x: -tableOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .overlay(alignment: .trailing) {
            // the graph filter lives here so it stays reachable while the search bar is hidden
            HStack(spacing: 10) {
                GraphFilterMenu()
                Menu { toggles } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Columns")
                    .accessibilityLabel("Columns")
            }
            .frame(width: GraphMetrics.headerToolsWidth, alignment: .trailing)
            .padding(.trailing, 12)
            .frame(maxHeight: .infinity)
            .background(tableWidth == nil ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
        }
        .lineLimit(1)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: GraphMetrics.headerHeight)
        .background(.bar)
    }

    /// An optional column's label; its left edge is a handle that widens or narrows the column
    private func label(_ title: LocalizedStringKey, id: String, width: CGFloat) -> some View {
        Text(title)
            .padding(.leading, GraphMetrics.columnInset)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .leading) {
                ColumnResizer(width: width, range: GraphMetrics.widthRange(id)) { resize(id, to: $0) }
                    .offset(x: -4)
            }
    }

    /// The branch and graph columns' right edge: dragging right widens them and leaves the message less room
    private func trailingResizer(_ id: String, width: CGFloat, range: ClosedRange<CGFloat>) -> some View {
        ColumnResizer(width: width, range: range, edge: .trailing) { resize(id, to: $0) }
            .offset(x: 4)
    }

    /// nil drops the stored width
    private func resize(_ id: String, to width: CGFloat?) {
        var current = GraphMetrics.widths(widths)
        current[id] = width?.rounded()
        let defaults = GraphMetrics.defaultWidths.merging(["ref": GraphMetrics.refWidth]) { $1 }
        widths = GraphMetrics.resizableColumns.compactMap { key in
            current[key].flatMap { $0 == defaults[key] ? nil : "\(key):\(Int($0))" }
        }.joined(separator: ",")
    }

    /// Which columns show; the message column always does
    @ViewBuilder private var toggles: some View {
        Toggle("Branch / Tag", isOn: SidebarSections.binding($hidden, "ref"))
        Toggle("Graph", isOn: SidebarSections.binding($hidden, "graph"))
        Toggle("Author", isOn: optional("author"))
        Toggle("Date", isOn: optional("time"))
        Toggle("SHA", isOn: optional("sha"))
        Divider()
        Button("Reset to default layout") {
            hidden = ""
            shown = ""
            widths = ""
        }
        .disabled(hidden.isEmpty && shown.isEmpty && widths.isEmpty)
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

/// A column header's edge: drag it sideways to change the column's width. Optional columns have it on their left,
/// the branch and graph columns on their right
private struct ColumnResizer: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    var edge: HorizontalEdge = .leading
    let onResize: (CGFloat) -> Void
    @ViewState private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1, height: 14)
            .frame(width: 8, height: GraphMetrics.headerHeight)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                let origin = start ?? width
                if start == nil { start = origin }
                // a handle on the column's left widens it when dragged left, one on its right when dragged right
                let delta = edge == .leading ? -value.translation.width : value.translation.width
                onResize(min(max(origin + delta, range.lowerBound), range.upperBound))
            }.onEnded { _ in start = nil })
            .help("Drag to resize the column")
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
            .help("Drag to scroll the graph sideways, or swipe sideways over the graph")
        }
        .frame(height: 8)
    }
}

/// Sideways trackpad swipes (and Shift with a mouse wheel) anywhere over the graph scroll its lanes. A local event
/// monitor sees the wheel events before the list does: a mostly sideways one is taken, everything else passes on
/// to the list's vertical scrolling.
private struct SideScrollMonitor: NSViewRepresentable {
    let active: Bool
    /// The sideways delta and the pointer's x in this view
    let onScroll: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.active = active; view.onScroll = onScroll }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var active = false
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.active, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let shift = event.modifierFlags.contains(.shift)
                let dx = shift && event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                guard dx != 0, shift || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                self.onScroll?(dx, self.convert(event.locationInWindow, from: nil).x)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
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
            // icon only, so the header's right end keeps a fixed width; what is filtered is in the tip and the menu
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.graphCurrentOnly ? String(localized: "Current branch only") :
              hidden > 0 ? String(localized: "Hidden \(hidden)") :
              String(localized: "Filter graph — show only the current branch, show hidden branches again (hide them by right-clicking in the sidebar)"))
        .accessibilityLabel("Filter graph")
    }
}
