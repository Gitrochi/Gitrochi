import SwiftUI

enum GraphMetrics {
    static let laneWidth: CGFloat = 22
    static let rowHeight: CGFloat = 34
    static let leftPad: CGFloat = 6
    static let maxVisibleLanes = 16
    /// 왼쪽 브랜치·태그 칸 너비
    static let refWidth: CGFloat = 190
    /// 커밋 동그라미(프로필) 지름
    static let avatar: CGFloat = 20

    static func width(lanes: Int, expanded: Bool = false) -> CGFloat {
        max(44, CGFloat(expanded ? lanes : min(lanes, maxVisibleLanes)) * laneWidth + leftPad * 2)
    }

    /// 그래프 행의 칸: 브랜치·태그, 그래프, 커밋 메시지(제목 + 본문 첫 줄 + 오른쪽 끝에 시간).
    /// 좁으면 시간을 숨기고, 브랜치 칸, 그래프 칸(오른쪽 레인은 잘림) 순으로 줄여 메시지 칸을 지킨다.
    struct Columns: Equatable {
        var ref = GraphMetrics.refWidth
        var graph: CGFloat
        var time = true
    }

    private static let messageMin: CGFloat = 200

    static func columns(width: CGFloat, graph: CGFloat) -> Columns {
        var c = Columns(graph: graph)
        // 메시지 앞 막대·여백 20, 행 오른쪽 여백 12, 시간 칸 90
        func short() -> CGFloat { messageMin - (width - (c.ref + c.graph + 32 + (c.time ? 90 : 0))) }
        if short() > 0 { c.time = false }
        if short() > 0 { c.ref = max(110, c.ref - short()) }
        if short() > 0 { c.graph = max(min(graph, 66), c.graph - short()) }
        return c
    }
}

struct GraphView: View {
    @Environment(RepoStore.self) private var store
    @FocusState private var focused: Bool
    @ViewState private var width: CGFloat = 1000
    @AppStorage("graphExpandLanes") private var expandLanes = false

    var body: some View {
        let graphWidth = GraphMetrics.width(lanes: store.maxLanes, expanded: expandLanes)
        let canvasWidth = expandLanes ? max(width, graphWidth + GraphMetrics.refWidth + 322) : width
        // 좁은 화면에서는 SHA·날짜·작성자 칸을 숨기고 브랜치·그래프 칸을 줄여 커밋 메시지 칸을 지킨다
        let columns = GraphMetrics.columns(width: canvasWidth, graph: graphWidth)
        VStack(spacing: 0) {
            SearchBar()
            Divider()
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    GraphHeader(columns: columns)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(store.entries) { entry in
                                    if !entry.commit.isWIP {
                                        CommitRow(entry: entry,
                                                  graphWidth: graphWidth,
                                                  columns: columns,
                                                  refs: store.refsByCommit[entry.id] ?? [],
                                                  selected: isSelected(entry),
                                                  isHead: entry.id == store.headHash,
                                                  wipCount: entry.commit.isWIP ? store.status.count : 0,
                                                  match: matchState(entry),
                                                  ci: store.ciBySha[entry.id])
                                            .id(entry.id)
                                            .onTapGesture {
                                                focused = true
                                                store.select(entry.commit.isWIP ? .wip : .commit(entry.id))
                                            }
                                        // VoiceOver 등 접근성: 행 하나를 버튼처럼(메시지·작성자·날짜를 한 번에 읽고 눌러서 선택)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityAction { store.select(entry.commit.isWIP ? .wip : .commit(entry.id)) }
                                        .contextMenu { CommitMenu(commit: entry.commit) }
                                    }
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
                        .onAppear {
                            if let target = store.selectedID { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
                .frame(width: canvasWidth)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay {
            if store.entries.allSatisfy({ $0.commit.isWIP }) {
                ContentUnavailableView("No commits yet", systemImage: "circle.dotted",
                                       description: Text("Open Changes to stage files and create your first commit."))
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
        case .commit(let s)?: return e.id == s
        case .pullRequest?, nil: return false
        }
    }
}

extension RepoStore {
    var selectedID: String? {
        switch selection {
        case .wip?: return Commit.wipID
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
                        store.clearSearch()
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

            GraphFilterMenu()

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: store.searchText) { store.updateSearch() }
        .onChange(of: store.searchScope) { store.updateSearch() }
        .onChange(of: store.searchFocusRequest) { focused = true }
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

    var body: some View {
        HStack(spacing: 0) {
            Text("Branch / Tag").padding(.leading, 10).frame(width: columns.ref, alignment: .leading)
            Text("Graph").padding(.leading, 6).frame(width: columns.graph, alignment: .leading)
            Text("Commit message").padding(.leading, 20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(.bar)
    }
}

/// 그래프 거르기: 현재 브랜치만 보기, 숨긴 브랜치 다시 보이기
private struct GraphFilterMenu: View {
    @AppStorage("graphExpandLanes") private var expandLanes = false
    @Environment(RepoStore.self) private var store

    var body: some View {
        let hidden = store.hiddenRefs.count
        let active = store.graphCurrentOnly || hidden > 0
        Menu {
            Toggle("Show only the current branch", isOn: Binding(get: { store.graphCurrentOnly }, set: { on in Task { await store.setCurrentOnly(on) } }))
            Toggle("Show all graph lanes", isOn: $expandLanes)
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
