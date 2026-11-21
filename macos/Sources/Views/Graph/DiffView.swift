import SwiftUI
import AppKit

/// 파일 하나의 변경 내용. 그래프 자리를 대신 차지하고, ← 또는 Esc 로 그래프로 돌아간다.
/// 한 줄로 / 나란히 보기, 공백 무시, 단어 단위 강조, 이미지 비교, 덩어리·줄 단위 스테이지.
struct DiffView: View {
    @Environment(RepoStore.self) private var store
    let source: DiffSource
    /// false where the page draws the header itself (a request's Changed files)
    var chrome = true
    /// false where the diff is too narrow for two columns: it renders unified and the stored preference stays
    var splitAllowed = true

    @AppStorage(fileViewModeKey) private var fileViewMode = "list"
    @ViewState private var keys = FileKeys()

    var body: some View {
        let change = source.change
        let _ = store.diffSettingsVersion
        if chrome {
            framed(change)
                // J and K step through the files the diff was opened from, as the header's buttons say
                .onAppear { keys.start { step($0 ? 1 : -1) } }
                .onChange(of: source) { keys.start { step($0 ? 1 : -1) } }
                .onDisappear { keys.stop() }
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func framed(_ change: FileChange) -> some View {
        VStack(spacing: 0) {
            DiffHeader(back: .init(title: backLabel, help: isReview ? "Close diff (Esc)" : "Back to graph (Esc)") { store.closeDiff() },
                       kind: change.kind, path: change.path, help: subtitle, position: position,
                       splitDisabledReason: splitAllowed ? nil : String(localized: "Split needs a diff at least 1000 px wide"),
                       ask: .init(disabled: store.diffLoading || store.diff?.isBinary == true) { Task { await store.openChangeQuestion() } }) {
                more(change)
            }
            Divider()

            // 안내 화면(바이너리·빈 파일 등)도 남은 자리를 다 채워 머리줄이 가운데로 내려오지 않게
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A diff on the repository screen stands where the graph was, so its way back names the graph
    private var backLabel: LocalizedStringKey {
        if case .review = source { return "Back to conversation" }
        return "Graph"
    }

    /// The files the open one was opened among, in the order their list draws them: the working changes (conflicts,
    /// unstaged, staged) or the selected commit's files. Other diffs have no list beside them.
    private var siblings: [DiffSource] {
        let ordered: ([FileChange]) -> [FileChange] = { files in
            fileViewMode == "tree" ? FileTree.rows(files, collapsed: []).compactMap { if case .file(let change) = $0.kind { return change } else { return nil } } : files
        }
        switch source {
        case .working:
            return (ordered(store.status.conflicted) + ordered(store.status.unstaged) + ordered(store.status.staged)).map { .working($0) }
        case .commit(let sha, _, let parent):
            return store.detail?.sha == sha ? ordered(store.detailFiles).map { .commit(sha: sha, change: $0, parent: parent) } : []
        case .review, .worktree:
            return []
        }
    }

    private var position: CodeFilePosition? {
        let files = siblings
        guard let index = files.firstIndex(of: source) else { return nil }
        return CodeFilePosition(index: index, count: files.count, step: step)
    }

    private func step(_ offset: Int) {
        let files = siblings
        guard let index = files.firstIndex(of: source), files.indices.contains(index + offset) else { return }
        store.openDiff(files[index + offset])
    }

    @ViewBuilder
    private var content: some View {
        if case .working(let c) = source, c.kind == .conflicted {
            ConflictView(change: c)
        } else if let doc = store.diff {
            if let error = doc.error {
                ContentUnavailableView("Couldn't load the changes", symbol: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let images = store.diffImages {
                ImageDiffView(images: images)
            } else if doc.isBinary {
                ContentUnavailableView("Binary file", symbol: "doc.zipper",
                                       description: Text("This isn't a text file, so a line-by-line comparison isn't shown."))
            } else if doc.lines.isEmpty {
                DiffEmptyState(doc: doc, ignoreWhitespace: store.diffIgnoreWhitespace)
            } else {
                DiffLinesView(doc: doc, split: store.diffSplit && splitAllowed, editable: store.canEditDiffLines,
                              staged: { if case .working(let c) = source { return c.staged } else { return false } }())
            }
        } else {
            ProgressView()
        }
    }

    private var subtitle: String {
        switch source {
        case .working(let c):
            let where_ = c.kind == .conflicted ? String(localized: "Conflict") : (c.staged ? String(localized: "Staged") : String(localized: "Working tree"))
            return "\(c.path) · \(where_)"
        case .commit(let sha, let c, _):
            return String(localized: "\(c.oldPath.map { "\($0) → " } ?? "")\(c.path) · commit \(sha.prefix(7))")
        case .review(let n, let c, _):
            return "\(c.oldPath.map { "\($0) → " } ?? "")\(c.path) · \(store.target?.provider.requestShort ?? "PR") #\(n)"
        case .worktree(let path, let c):
            let name = store.worktrees.first { $0.path == path }?.branch ?? (path as NSString).lastPathComponent
            return "\(c.path) · " + String(localized: "Worktree: \(name)")
        }
    }

    private var isReview: Bool { if case .review = source { return true } else { return false } }
    private var isWorktree: Bool { if case .worktree = source { return true } else { return false } }

    /// More: what the header does not draw. Staging first, the file's history tools, where the file is, and
    /// discarding last.
    @ViewBuilder
    private func more(_ c: FileChange) -> some View {
        let busy = store.busy != nil
        if case .working = source {
            if c.kind == .conflicted {
                Button("Mark as resolved") { Task { await store.stage([c]) } }.disabled(busy)
            } else if c.staged {
                Button("Unstage") { Task { await store.unstage([c]) } }.disabled(busy)
            } else {
                Button("Stage") { Task { await store.stage([c]) } }.disabled(busy)
            }
            Divider()
        }
        if c.kind != .untracked, !isReview, !isWorktree {
            Button("File history") { store.openFileHistory(c.path) }
            if c.kind != .deleted {
                Button("Show blame") {
                    if case .commit(let sha, _, _) = source { store.openBlame(c.path, rev: sha) } else { store.openBlame(c.path) }
                }
            }
            Button("Trace lines…") { store.openSelectedLineHistory() }.disabled(store.diffLoading || store.diff?.isBinary == true)
            Divider()
        }
        Button("Show in Finder") {
            if case .worktree(let path, _) = source {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).appendingPathComponent(c.path)])
            } else {
                store.revealInFinder(c)
            }
        }
        Button("Copy path") { store.copy(c.path) }
        if case .working = source, !c.staged, c.kind != .conflicted {
            Divider()
            Button("Discard changes…", role: .destructive) { store.confirmDiscard(c) }.disabled(busy)
        }
    }
}

/// 내용 줄이 없는 diff: 새 빈 파일·이름만·권한만 바뀐 경우 등을 알맞게 알린다
struct DiffEmptyState: View {
    let doc: DiffDocument
    var ignoreWhitespace = false

    var body: some View {
        let i = doc.info
        let (title, icon, detail): (String, String, String) = {
            if i.newFile { return (String(localized: "Empty file"), "doc", String(localized: "A new file with no content.")) }
            if i.deletedFile { return (String(localized: "An empty file was deleted"), "trash", String(localized: "The deleted file had no content.")) }
            let rename = i.renamed ? "\(i.renameFrom ?? "") → \(i.renameTo ?? "")" : nil
            if let rename, let mode = i.modeSummary { return (String(localized: "Only the name and permissions changed"), "pencil", String(localized: "\(rename)\nPermissions \(mode)")) }
            if let rename { return (String(localized: "Only the name changed"), "pencil", String(localized: "\(rename)\nThe content is unchanged.")) }
            if let mode = i.modeSummary { return (String(localized: "Only permissions changed"), "lock.open", mode) }
            if ignoreWhitespace { return (String(localized: "No changes to show"), "equal.circle", String(localized: "Only whitespace changed (turn off Ignore whitespace to see it).")) }
            return (String(localized: "No changes to show"), "equal.circle", String(localized: "Only permissions or the name may have changed, without content changes."))
        }()
        ContentUnavailableView(title, symbol: icon, description: Text(detail))
    }
}

/// diff 줄 목록(한 줄로 / 나란히). 긴 줄은 칸 안에서 줄바꿈해 가로로 밀리지 않고 모두 보인다. 파일 히스토리에서도 쓴다.
struct DiffLinesView: View {
    @Environment(RepoStore.self) private var store
    let doc: DiffDocument
    let split: Bool
    let editable: Bool
    let staged: Bool
    /// One language for the whole document, worked out once rather than per row
    private var language: String { doc.language }

    var body: some View {
        // 새 파일·지운 파일처럼 한쪽만 있으면 나란히 보기라도 한 칸으로(빈 반쪽 없이)
        let halves = split && !doc.oneSided
        let numberWidth = Self.numberWidth(doc)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                FileInfoBar(info: doc.info)
                if halves {
                    ForEach(doc.splitRows) { row in
                        if let f = row.full {
                            fullRow(doc.lines[f], gutter: numberWidth + (editable ? DiffLineRow.stageWidth : 0) + 20)
                        } else {
                            Halves {
                                cell(row.left.map { doc.lines[$0] }, side: .left, numberWidth: numberWidth)
                                Rectangle().fill(Color(nsColor: .separatorColor))
                                cell(row.right.map { doc.lines[$0] }, side: .right, numberWidth: numberWidth)
                            }
                        }
                    }
                } else {
                    let gutter = (doc.hasOldSide ? numberWidth : 0) + (doc.hasNewSide ? numberWidth : 0) + (editable ? DiffLineRow.stageWidth : 0) + 20
                    ForEach(doc.lines) { line in
                        if line.kind == .hunk || line.kind == .meta {
                            fullRow(line, gutter: gutter)
                        } else {
                            DiffLineRow(line: line, language: language, showOld: doc.hasOldSide, showNew: doc.hasNewSide, numberWidth: numberWidth,
                                        selected: store.diffSelection.contains(line.id), stage: stage(line))
                                .modifier(Selectable(line: line, enabled: editable))
                                .modifier(ReviewCommentable(line: line, side: nil, enabled: !doc.combined && !doc.multipleFiles))
                        }
                    }
                }
                if doc.truncated {
                    Text("… The diff is too long; only the beginning is shown")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
        // 보기를 바꾸면 스크롤 뷰를 새로 만든다(이전 보기의 가로 위치가 남아 칸이 밀리지 않게)
        .id(halves)
        .background(Color(nsColor: .textBackgroundColor))
    }

    enum Side { case left, right }

    /// What the line's gutter column holds in a working diff: the per-line button on a changed line, room on the others
    private func stage(_ line: DiffLine) -> DiffLineRow.Stage? {
        guard editable else { return nil }
        guard line.kind == .added || line.kind == .removed, let hunk = line.hunk else { return .room }
        return .button(unstage: staged, disabled: store.busy != nil) {
            Task { await store.applyLines(staged ? .unstage : .stage, hunk: hunk, only: line.id) }
        }
    }

    /// 줄 번호 칸 너비: 가장 큰 번호의 자릿수에 맞춘다
    static func numberWidth(_ doc: DiffDocument) -> CGFloat {
        let maxNo = doc.lines.reduce(0) { max($0, $1.oldNo ?? 0, $1.newNo ?? 0) }
        return CGFloat(max(2, String(maxNo).count)) * 7.5 + 14
    }

    @ViewBuilder
    private func fullRow(_ line: DiffLine, gutter: CGFloat) -> some View {
        if line.kind == .hunk, let h = line.hunk {
            HunkHeader(line: line, hunk: h, editable: editable, staged: staged)
        } else {
            // "\ No newline at end of file"
            Label(line.text, symbol: "arrow.turn.down.left")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, gutter)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cell(_ line: DiffLine?, side: Side, numberWidth: CGFloat) -> some View {
        if let line {
            DiffLineRow(line: line, language: language, showOld: side == .left, showNew: side == .right, numberWidth: numberWidth,
                        selected: store.diffSelection.contains(line.id), stage: stage(line))
                .modifier(Selectable(line: line, enabled: editable))
                .modifier(ReviewCommentable(line: line, side: side == .left ? .left : .right, enabled: !doc.combined && !doc.multipleFiles))
        } else {
            Color.secondary.opacity(0.06)
        }
    }
}

/// 나란히 보기 한 줄: [왼쪽, 가운데 선, 오른쪽] 을 정확히 반씩 놓고, 높이는 더 긴(줄바꿈된) 쪽에 맞춘다
private struct Halves: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        guard subviews.count == 3 else { return CGSize(width: width, height: 0) }
        let half = max(0, (width - 1) / 2)
        let height = [subviews[0], subviews[2]].map { $0.sizeThatFits(ProposedViewSize(width: half, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let half = max(0, (bounds.width - 1) / 2)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: half, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + half, y: bounds.minY), proposal: ProposedViewSize(width: 1, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.minX + half + 1, y: bounds.minY), proposal: ProposedViewSize(width: half, height: bounds.height))
    }
}

/// 이름·권한이 바뀌었으면 줄 목록 위에 한 줄로
private struct FileInfoBar: View {
    let info: DiffFileInfo

    var body: some View {
        let items: [(String, String)] = [
            info.renamed ? ("pencil", String(localized: "Renamed  \(info.renameFrom ?? "") → \(info.renameTo ?? "")")
                            + (info.similarity.map { $0 < 100 ? String(localized: " · \($0)% similar") : "" } ?? "")) : nil,
            info.modeSummary.map { ("lock.open", String(localized: "Permissions changed  \($0)")) },
        ].compactMap { $0 }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.1) { icon, text in
                    Label(text, symbol: icon).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// 바뀐 줄을 누르면 고르기(Shift 로 범위). 고른 줄은 덩어리 머리의 버튼으로 스테이지·언스테이지·버리기.
private struct Selectable: ViewModifier {
    @Environment(RepoStore.self) private var store
    let line: DiffLine
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, line.kind == .added || line.kind == .removed {
            content
                .contentShape(Rectangle())
                .onTapGesture { store.toggleDiffLine(line, extend: NSEvent.modifierFlags.contains(.shift)) }
                .help("Click to select this line (Shift: range) — you can stage only the selected lines")
        } else {
            content
        }
    }
}

/// PR 서버가 준 패치의 실제 줄에서만 댓글 초안을 만들고, 작업 파일·히스토리 diff는 구분한다.
private struct ReviewCommentable: ViewModifier {
    @Environment(RepoStore.self) private var store
    let line: DiffLine
    let side: ReviewLineSide?
    let enabled: Bool
    @ViewState private var hovered = false

    @ViewBuilder func body(content: Content) -> some View {
        let actualSide = side ?? (line.newNo != nil ? .right : .left)
        let number = actualSide == .left ? line.oldNo : line.newNo
        if enabled, store.fileInspect == nil, let number, line.kind != .hunk, line.kind != .meta,
           case .review(let request, let change, _)? = store.diffSource {
            HStack(alignment: .top, spacing: 0) {
                Button {
                    store.addReviewDraft(request, path: change.path, line: number, side: actualSide, oldLine: line.oldNo)
                } label: {
                    SymbolIcon("plus.bubble.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help("Add review comment")
                .accessibilityLabel(Text("Add review comment on line \(number)"))
                .disabled(store.reviewBusy || store.reviewLoading)
                .opacity(hovered ? 1 : 0)
                content
            }
            .onHover { hovered = $0 }
        } else { content }
    }
}

/// @@ 줄: 덩어리 위치 + (작업 트리 diff 면) 덩어리·고른 줄 스테이지·언스테이지·버리기
private struct HunkHeader: View {
    @Environment(RepoStore.self) private var store
    let line: DiffLine
    let hunk: Int
    let editable: Bool
    let staged: Bool

    var body: some View {
        let picked = editable ? store.selectedCount(inHunk: hunk) : 0
        HStack(spacing: 8) {
            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if editable {
                if staged {
                    Button(picked > 0 ? "Unstage selected lines (\(picked))" : "Unstage hunk") {
                        Task { await store.applyLines(.unstage, hunk: hunk) }
                    }
                    .help(picked > 0 ? "Unstages only the selected lines" : "Unstages this hunk")
                } else {
                    Button(picked > 0 ? "Discard selected lines…" : "Discard hunk…") { store.confirmDiscardLines(hunk: hunk) }
                        .help(picked > 0 ? "Discards the selected lines' changes from the working tree" : "Discards this hunk's changes from the working tree")
                    Button(picked > 0 ? "Stage selected lines (\(picked))" : "Stage hunk") {
                        Task { await store.applyLines(.stage, hunk: hunk) }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(picked > 0 ? "Stages only the selected lines" : "Stages only this hunk (click changed lines to stage only those)")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.07))
    }
}

private struct DiffLineRow: View {
    /// The column a working diff keeps for the per-line stage button, between the line numbers and the +/− sign
    static let stageWidth: CGFloat = 24
    enum Stage {
        case room
        case button(unstage: Bool, disabled: Bool, run: () -> Void)
    }

    let line: DiffLine
    /// The file's language, for its syntax colours
    var language = "Plain text"
    var showOld = true
    var showNew = true
    var numberWidth: CGFloat = 44
    var selected = false
    /// nil where lines cannot be staged (a commit's diff, file history): no column at all
    var stage: Stage? = nil
    @ViewState private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if showOld {
                Text(line.oldNo.map(String.init) ?? "")
                    .frame(width: numberWidth - 6, alignment: .trailing)
                    .padding(.trailing, 6)
                    .foregroundStyle(.tertiary)
            }
            if showNew {
                Text(line.newNo.map(String.init) ?? "")
                    .frame(width: numberWidth - 6, alignment: .trailing)
                    .padding(.trailing, 6)
                    .foregroundStyle(.tertiary)
            }
            if let stage {
                // a 24pt target that never makes the line taller: it is centred over a blank of the line's own height
                Text(verbatim: " ").frame(width: Self.stageWidth)
                    .overlay { if case .button(let unstage, let disabled, let run) = stage { stageButton(unstage: unstage, disabled: disabled, run: run) } }
            }
            Text(marker)
                .frame(width: 20)
                .foregroundStyle(markerColor)
            Text(content)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .onHover { if stage != nil { hovered = $0 } }
    }

    /// "Stage line": a 16pt circle with a plus in a 24pt target, shown on the line under the pointer
    private func stageButton(unstage: Bool, disabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            DesignIconImage(icon: unstage ? .minus : .plus, size: 10)
                .foregroundStyle(Color.primary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(StudioStyle.surface))
                .overlay(Circle().strokeBorder(HostedList.edge))
                .frame(width: Self.stageWidth, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(hovered ? 1 : 0)
        .help(unstage ? "Unstage line" : "Stage line")
        .accessibilityLabel(unstage ? "Unstage line" : "Stage line")
    }

    /// The line in the code reader's colours, the words that changed on a stronger fill (Windows: LineText in DiffView.tsx)
    private var content: AttributedString {
        RepositoryCodeReading.attributed(line.text.isEmpty ? " " : line.text, language: language, dark: colorScheme == .dark,
                                         changes: line.changes, changeFill: line.kind == .added ? Color.green.opacity(0.32) : Color.red.opacity(0.30))
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? .green : (line.kind == .removed ? .red : .secondary)
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.22) }
        switch line.kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
        default: return .clear
        }
    }
}

/// 이미지 파일: 바뀌기 전과 후를 나란히(크기·용량 함께). 작은 이미지는 키우지 않고 원래 크기로.
private struct ImageDiffView: View {
    let images: DiffImages

    var body: some View {
        HStack(spacing: 0) {
            pane(String(localized: "Before"), images.old, tint: .red)
            Divider()
            pane(String(localized: "After"), images.new, tint: .green)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func pixels(_ img: NSImage) -> CGSize {
        if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return img.size
    }

    private func pane(_ title: String, _ data: Data?, tint: Color) -> some View {
        let img = data.flatMap { NSImage(data: $0) }
        return VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                if let data, let img {
                    let px = pixels(img)
                    Text("\(Int(px.width)) × \(Int(px.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let img {
                let px = pixels(img)
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: px.width, maxHeight: px.height)
                    .background(CheckerBoard())
                    .overlay(Rectangle().strokeBorder(tint.opacity(0.5)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(data == nil ? "None" : "Can't open this image", symbol: "photo",
                                       description: Text(data == nil ? (title == String(localized: "Before") ? "This file was newly added." : "This file was deleted.") : ""))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 투명한 부분이 보이게 깔아 두는 체크 무늬
private struct CheckerBoard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.secondary.opacity(0.15)))
                }
            }
        }
    }
}
