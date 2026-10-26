import SwiftUI
import AppKit

/// 그래프의 한 행: 브랜치·태그 칸, 그래프 조각, 메시지·작성자·날짜·SHA
struct CommitRow: View {
    enum Match { case none, hit, miss }

    @Environment(RepoStore.self) private var store
    @ViewState private var dropTargeted = false

    let entry: GraphEntry
    let graphWidth: CGFloat
    /// 화면 너비에 맞춘 칸(좁으면 일부 칸을 숨기고 줄인다)
    let columns: GraphMetrics.Columns
    let refs: [RefLabel]
    let selected: Bool
    let isHead: Bool
    let wipCount: Int
    /// Branch of another worktree's row
    var wipLabel: String?
    var match: Match = .none
    /// 이 커밋의 가장 최근 CI 파이프라인
    var ci: CIPipeline?

    /// Rows stay 6pt apart, like GitKraken
    static let bandHeight = GraphMetrics.rowHeight - 6

    var body: some View {
        let c = entry.commit
        let tint = GraphStyle.lane(entry.row.color)
        let groups = RefGroup.group(refs)
        HStack(spacing: 0) {
            // 왼쪽: 브랜치·태그(첫 번째 + 나머지 개수), 그래프 동그라미까지 이어지는 선
            if columns.ref > 0 {
                RefColumn(groups: groups, tint: tint, store: store)
                    .frame(width: columns.ref, height: GraphMetrics.rowHeight)
            }
            if columns.graph > 0 {
                GraphCell(row: entry.row, isWIP: c.isPending, isHead: isHead, isMerge: c.isMerge,
                          hasRefs: !groups.isEmpty, author: c.author, email: c.email)
                    .frame(width: graphWidth, height: GraphMetrics.rowHeight)
                    // 좁아서 그래프 칸이 잘리면 오른쪽 끝을 흐리게
                    .frame(width: columns.graph, alignment: .leading)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: columns.graph < graphWidth ? max(0, 1 - 16 / columns.graph) : 1),
                                               .init(color: columns.graph < graphWidth ? .clear : .black, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .background(alignment: .leading) {
                        // like GitKraken: a band from the node to the message, a little shorter than the row so rows stay apart
                        Rectangle()
                            .fill(tint.opacity(selected ? 0.4 : 0.1))
                            .frame(height: Self.bandHeight)
                            .padding(.leading, min(GraphMetrics.leftPad + GraphMetrics.laneWidth * (CGFloat(entry.row.column) + 0.5), columns.graph))
                    }
            }
            // 커밋 메시지: 레인 색 막대 · 제목 · 본문 첫 줄(흐리게) · 오른쪽 끝에 시간. 작성자·SHA 는 마우스를 올리면.
            HStack(spacing: 6) {
                Rectangle()
                    .fill(tint.opacity(c.isPending ? 0.5 : 0.9))
                    .frame(width: 3, height: Self.bandHeight)
                    .padding(.trailing, 4)
                if isHead {
                    Text("HEAD").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                }
                if c.isPending {
                    if c.wipWorktree != nil {
                        Text("// Uncommitted changes in \(wipLabel ?? "")").italic().foregroundStyle(.secondary)
                    } else {
                        Text("// Uncommitted changes").italic().foregroundStyle(.secondary)
                    }
                    Text("\(wipCount) files")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.18)))
                } else {
                    SubjectAndBody {
                        Text(c.subject)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(c.isMerge ? .secondary : .primary)
                        if let ci {
                            CIStatusIcon(status: ci.status, size: 11)
                                .help("CI: \(ci.status.title) · \(ci.name.isEmpty ? "" : ci.name + " ")#\(ci.number) — click to open in the browser")
                                .onTapGesture { if let u = URL(string: ci.url) { NSWorkspace.shared.open(u) } }
                        }
                        if !c.body.isEmpty {
                            Text(c.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(.secondary)
                                .layoutValue(key: IsCommitBody.self, value: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                if columns.time && !c.isPending {
                    Text(Fmt.short(c.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.bandHeight)
            // selection and search hits tint only the message, at the band's height
            .background(selected ? Color.accentColor.opacity(0.16) : (match == .hit ? Color.yellow.opacity(0.16) : Color.clear))
            .clipped()
            .help(c.isPending ? "" : "\(c.subject)\n\(c.author) <\(c.email)>\n\(Fmt.long(c.date)) · \(c.short)")
        }
        .font(.system(size: 12.5))
        .padding(.trailing, 12)
        .frame(height: GraphMetrics.rowHeight)
        .opacity(match == .miss ? 0.32 : 1)
        .overlay(alignment: .leading) {
            if selected || match == .hit { Rectangle().fill(Color.accentColor).frame(width: selected ? 3 : 2) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.10)))
            }
        }
        .contentShape(Rectangle())
        // 커밋 줄을 끌어 브랜치에 놓으면 cherry-pick, 이 줄에 브랜치를 놓으면 머지·리베이스
        .draggable(RepoStore.commitPayload + c.id) {
            Label("Commit \(c.short)  \(c.subject)", systemImage: "smallcircle.filled.circle")
                .lineLimit(1)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first, !c.isPending else { return false }
            store.handleDrop(payload, onto: entry)
            return true
        } isTargeted: { dropTargeted = $0 && !c.isPending }
    }
}

/// 같은 이름의 로컬·원격 브랜치를 한 줄로 묶은 것(GitKraken 처럼 💻·☁︎ 아이콘으로 구분)
struct RefGroup: Identifiable {
    let name: String
    var isCurrent = false
    var local: String?
    var remotes: [String] = []
    var isTag = false
    var isHead = false
    var id: String { (isTag ? "t:" : isHead ? "h:" : "b:") + name }

    /// 체크아웃·끌기·메뉴에 쓸 실제 참조
    var primary: RefLabel {
        if isHead { return RefLabel(name: "HEAD", kind: .head, isCurrent: true) }
        if isTag { return RefLabel(name: name, kind: .tag, isCurrent: false) }
        if let local { return RefLabel(name: local, kind: .local, isCurrent: isCurrent) }
        return RefLabel(name: remotes.first ?? name, kind: .remote, isCurrent: false)
    }

    var all: [RefLabel] {
        if isHead || isTag { return [primary] }
        return (local.map { [RefLabel(name: $0, kind: .local, isCurrent: isCurrent)] } ?? [])
            + remotes.map { RefLabel(name: $0, kind: .remote, isCurrent: false) }
    }

    static func group(_ refs: [RefLabel]) -> [RefGroup] {
        var order: [String] = []
        var byName: [String: RefGroup] = [:]
        var extra: [RefGroup] = []
        for r in refs {
            switch r.kind {
            case .head: extra.insert(RefGroup(name: "HEAD", isCurrent: true, isHead: true), at: 0)
            case .tag: extra.append(RefGroup(name: r.name, isTag: true))
            case .local:
                if byName[r.name] == nil { order.append(r.name); byName[r.name] = RefGroup(name: r.name) }
                byName[r.name]?.local = r.name
                byName[r.name]?.isCurrent = r.isCurrent
            case .remote:
                let short = r.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? r.name
                if byName[short] == nil { order.append(short); byName[short] = RefGroup(name: short) }
                byName[short]?.remotes.append(r.name)
            }
        }
        let branches = order.compactMap { byName[$0] }.sorted { a, b in
            (a.isCurrent ? 0 : a.local != nil ? 1 : 2) < (b.isCurrent ? 0 : b.local != nil ? 1 : 2)
        }
        let heads = extra.filter(\.isHead), tags = extra.filter(\.isTag)
        return heads + branches + tags
    }
}

/// 왼쪽 칸: 첫 번째 브랜치(또는 태그) 라벨 + 나머지 개수, 그리고 그래프까지 이어지는 선
private struct RefColumn: View {
    let groups: [RefGroup]
    let tint: Color
    let store: RepoStore

    var body: some View {
        HStack(spacing: 4) {
            if let g = groups.first {
                RefPill(group: g, tint: tint, store: store)
                if groups.count > 1 {
                    Menu {
                        ForEach(groups.dropFirst()) { g in
                            Menu(g.name) { ForEach(g.all) { r in RefMenu(ref: r) } }
                        }
                    } label: { Text("+\(groups.count - 1)") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .help(groups.dropFirst().map(\.name).joined(separator: "\n"))
                        .contextMenu {
                            ForEach(groups.dropFirst()) { g in
                                Menu(g.name) { ForEach(g.all) { r in RefMenu(ref: r) } }
                            }
                        }
                }
                Rectangle().fill(tint.opacity(GraphMetrics.refOpacity)).frame(minWidth: 8, maxWidth: 24).frame(height: GraphMetrics.refStroke)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 6)
    }
}

private struct RefPill: View {
    let group: RefGroup
    let tint: Color
    let store: RepoStore

    var body: some View {
        let solid = group.isCurrent
        let color = group.isTag ? Color.secondary : tint
        HStack(spacing: 3) {
            if solid { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)) }
            if group.isTag { Image(systemName: "tag").font(.system(size: 9, weight: .semibold)) }
            if group.isHead { Image(systemName: "scope").font(.system(size: 9, weight: .semibold)) }
            Text(group.name)
                .font(.system(size: 11, weight: solid ? .bold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if group.local != nil { Image(systemName: "laptopcomputer").font(.system(size: 9)) }
            if !group.remotes.isEmpty { Image(systemName: "cloud").font(.system(size: 9)) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(solid ? GraphStyle.currentRefText : color)
        .background(RoundedRectangle(cornerRadius: 6).fill(solid ? color : color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(solid ? 0 : 0.24), lineWidth: 0.75))
        .layoutPriority(1)
        .contentShape(Rectangle())
        .help(helpText)
        .contextMenu {
            if group.all.count > 1 {
                ForEach(group.all) { r in Menu(r.name) { RefMenu(ref: r) } }
            } else {
                RefMenu(ref: group.primary)
            }
        }
        .modifier(BranchInteractions(group: group, store: store, tint: tint))
    }

    private var helpText: String {
        var parts: [String] = []
        if let l = group.local { parts.append(String(localized: "Local: \(l)") + (group.isCurrent ? String(localized: " (current)") : "")) }
        if !group.remotes.isEmpty { parts.append(String(localized: "Remote: ") + group.remotes.joined(separator: ", ")) }
        if group.isTag { parts.append(String(localized: "Tag: \(group.name)")) }
        if !group.isTag && !group.isHead { parts.append(String(localized: "Double-click: check out · Drag onto another branch's row: merge or rebase · Right-click: menu")) }
        return parts.joined(separator: "\n")
    }
}

/// 브랜치 라벨: 더블클릭 체크아웃, 끌어서 다른 브랜치에 놓기
private struct BranchInteractions: ViewModifier {
    let group: RefGroup
    let store: RepoStore
    let tint: Color

    func body(content: Content) -> some View {
        if group.isTag || group.isHead {
            content
        } else {
            let name = group.local ?? group.remotes.first ?? group.name
            content
                .simultaneousGesture(TapGesture().onEnded {
                    if let branch = store.branch(named: name) { store.selectedBranchID = branch.id }
                })
                .onTapGesture(count: 2) {
                    if let b = store.branch(named: name) { Task { await store.checkout(b) } }
                }
                .draggable(RepoStore.branchPayload + name) {
                    RefBadge(label: group.primary, color: tint)
                }
        }
    }
}

/// 한 행의 그래프 조각: 위·아래로 이어지는 레인 선, 브랜치 라벨에서 오는 선, 커밋 동그라미(작성자 프로필)
struct GraphCell: View {
    let row: GraphRow
    let isWIP: Bool
    let isHead: Bool
    let isMerge: Bool
    var hasRefs = false
    var author = ""
    var email = ""

    private func x(_ lane: Double) -> CGFloat {
        GraphMetrics.leftPad + GraphMetrics.laneWidth * (CGFloat(lane) + 0.5)
    }

    var body: some View {
        let color = GraphStyle.lane(row.color)
        let cx = x(Double(row.column))
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let h = size.height
                // 왼쪽 브랜치 라벨에서 이 커밋까지
                if hasRefs {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    p.addLine(to: CGPoint(x: cx, y: h / 2))
                    ctx.stroke(p, with: .color(color.opacity(GraphMetrics.refOpacity)), lineWidth: GraphMetrics.refStroke)
                }
                for s in row.segments {
                    let a = CGPoint(x: x(s.x1), y: h * s.y1)
                    let b = CGPoint(x: x(s.x2), y: h * s.y2)
                    var p = Path()
                    p.move(to: a)
                    if s.x1 == s.x2 {
                        p.addLine(to: b)
                    } else {
                        let mid = (a.y + b.y) / 2
                        p.addCurve(to: b, control1: CGPoint(x: a.x, y: mid), control2: CGPoint(x: b.x, y: mid))
                    }
                    ctx.stroke(p, with: .color(GraphStyle.lane(s.color)),
                               style: StrokeStyle(lineWidth: GraphMetrics.laneStroke, lineCap: .round, lineJoin: .round, dash: s.dashed ? [3, 3] : []))
                }
                let center = CGPoint(x: cx, y: h / 2)
                func circle(_ r: CGFloat) -> Path { Circle().path(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)) }
                if isWIP {
                    ctx.fill(circle(7), with: .color(Color(nsColor: .textBackgroundColor)))
                    ctx.stroke(circle(7), with: .color(color), style: StrokeStyle(lineWidth: GraphMetrics.nodeStroke, dash: [2.5, 2]))
                } else if isMerge {
                    // 머지 커밋은 작은 점
                    ctx.fill(circle(5.5), with: .color(Color(nsColor: .textBackgroundColor)))
                    ctx.fill(circle(4), with: .color(color))
                } else {
                    ctx.fill(circle(4.5), with: .color(Color(nsColor: .textBackgroundColor)))
                    ctx.stroke(circle(4.5), with: .color(color), lineWidth: GraphMetrics.nodeStroke)
                }
                if isHead {
                    ctx.stroke(circle(8), with: .color(Color.accentColor), lineWidth: GraphMetrics.nodeStroke)
                }
            }
        }
    }
}

/// 그래프 행 우클릭 메뉴
struct CommitMenu: View {
    @Environment(RepoStore.self) private var store
    let commit: Commit

    var body: some View {
        if let path = commit.wipWorktree {
            Button("Open worktree") { Task { await store.switchWorktree(to: path) } }
            Button("Open in new tab") { Task { await store.openOrReport(URL(fileURLWithPath: path, isDirectory: true)) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        } else if commit.isWIP {
            Button("Stage all") { Task { await store.stageAll() } }
            Button("Stash…") { store.sheet = .stash }
            Divider()
            Button("Discard all changes…", role: .destructive) { store.confirmDiscardAll() }
        } else {
            let branches = (store.refsByCommit[commit.id] ?? []).filter { $0.kind == .local || $0.kind == .remote }
            if !branches.isEmpty {
                ForEach(branches) { r in
                    Menu("Branch '\(r.name)'") { RefMenu(ref: r) }
                }
                Divider()
            }
            if let current = store.headBranch, commit.id != store.headHash {
                Button("Merge this commit into '\(current)'") { Task { await store.merge(commit.id) } }
                Button("Rebase '\(current)' onto this commit") { Task { await store.rebase(onto: commit.id) } }
                Divider()
            }
            if store.headBranch != nil {
                Button("Clean up commits from here (squash, reorder, reword)…") { Task { await store.startInteractiveRebase(from: commit.id) } }
                    .disabled(store.repoState != .clean)
                Divider()
            }
            Button("Compare with HEAD…") { store.openRevisionComparison(left: commit.id, right: "HEAD") }
            if !store.historyTools.selected.isEmpty {
                Button("Selected commits…") { Task { await store.openBatchCommits() } }
            }
            Button("New branch from here…") { store.requestNewBranch(from: commit.id, label: commit.short) }
            Button("Tag here…") { store.sheet = .tag(sha: commit.id) }
            Button("Create worktree from here…") { store.sheet = .addWorktree(branch: nil, start: commit.id) }
            Divider()
            Button("Check out this commit (detached HEAD)") { Task { await store.checkoutDetached(commit.id) } }
            Button("Cherry-pick") { Task { await store.cherryPick(commit.id) } }
                .disabled(commit.id == store.headHash)
            Button("Revert (create a reverting commit)") { Task { await store.revert(commit.id) } }
            if store.headBranch != nil {
                Menu("Reset current branch to here") {
                    Button("Soft — keep changes staged") { store.reset(to: commit.id, mode: .soft) }
                    Button("Mixed — keep changes in the working tree") { store.reset(to: commit.id, mode: .mixed) }
                    Button("Hard — discard changes too…", role: .destructive) { store.reset(to: commit.id, mode: .hard) }
                }
            }
            Divider()
            Button("Copy SHA") { store.copy(commit.id) }
            Button("Copy message") { store.copy(commit.subject) }
        }
    }
}

private struct IsCommitBody: LayoutValueKey { static let defaultValue = false }

/// 제목(과 CI 표시)은 먼저 다 보이게 놓고, 본문 첫 줄은 남는 자리가 넉넉할 때만(조각만 보이면 숨긴다)
private struct SubjectAndBody: Layout {
    private let spacing: CGFloat = 6
    private let bodyMin: CGFloat = 70

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: min(proposal.width ?? ideal, ideal), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for v in subviews {
            let ideal = v.sizeThatFits(.unspecified)
            var left = max(0, bounds.maxX - x)
            if v[IsCommitBody.self] && left < bodyMin { left = 0 }
            let w = min(ideal.width, left)
            v.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: ideal.height))
            x += w + (w > 0 ? spacing : 0)
        }
    }
}
