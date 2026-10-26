import SwiftUI
import AppKit

/// 파일 하나의 변경 내용. 그래프 자리를 대신 차지하고, ← 또는 Esc 로 그래프로 돌아간다.
/// 한 줄로 / 나란히 보기, 공백 무시, 단어 단위 강조, 이미지 비교, 덩어리·줄 단위 스테이지.
struct DiffView: View {
    @Environment(RepoStore.self) private var store
    let source: DiffSource

    var body: some View {
        let change = source.change
        let _ = store.diffSettingsVersion
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.closeDiff() } label: {
                    Label(backLabel, systemImage: "chevron.left")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close diff (Esc)")

                StatusBadge(kind: change.kind)
                VStack(alignment: .leading, spacing: 0) {
                    Text(change.fileName).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            WorkbenchFlow(spacing: 10) {
                viewOptions
                fileButtons(change)
                questionButtons(change)
                actions(change)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .disabled(store.busy != nil)
            Divider()

            // 안내 화면(바이너리·빈 파일 등)도 남은 자리를 다 채워 머리줄이 가운데로 내려오지 않게
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var backLabel: LocalizedStringKey {
        switch source {
        case .working: return "Changes"
        case .review: return "Back to conversation"
        case .commit, .worktree: return "Graph"
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .working(let c) = source, c.kind == .conflicted {
            ConflictView(change: c)
        } else if let doc = store.diff {
            if let error = doc.error {
                ContentUnavailableView("Couldn't load the changes", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let images = store.diffImages {
                ImageDiffView(images: images)
            } else if doc.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper",
                                       description: Text("This isn't a text file, so a line-by-line comparison isn't shown."))
            } else if doc.lines.isEmpty {
                DiffEmptyState(doc: doc, ignoreWhitespace: store.diffIgnoreWhitespace)
            } else {
                DiffLinesView(doc: doc, split: store.diffSplit, editable: store.canEditDiffLines,
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

    @ViewBuilder private func questionButtons(_ change: FileChange) -> some View {
        if !isReview && !isWorktree && change.kind != .untracked {
            Button("Trace lines…") { store.openSelectedLineHistory() }.disabled(store.diffLoading || store.diff?.isBinary == true)
        }
        Button { Task { await store.openChangeQuestion() } } label: { Label("Ask AI…", systemImage: "sparkles") }
            .help("Ask questions about the selected changes")
            .disabled(store.diffLoading || store.diff?.isBinary == true)
    }

    /// 이 파일의 히스토리·blame 열기
    @ViewBuilder
    private func fileButtons(_ c: FileChange) -> some View {
        if c.kind != .untracked, !isReview, !isWorktree {
            Button { store.openFileHistory(c.path) } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
                .help("File history — commits that changed this file")
                .accessibilityLabel("File history")
            if c.kind != .deleted {
                Button {
                    if case .commit(let sha, _, _) = source { store.openBlame(c.path, rev: sha) } else { store.openBlame(c.path) }
                } label: { Image(systemName: "person.text.rectangle") }
                    .buttonStyle(.borderless)
                    .help("Blame — who changed each line and when")
                    .accessibilityLabel("Blame")
            }
        }
        Button {
            if case .worktree(let path, _) = source {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).appendingPathComponent(c.path)])
            } else {
                store.revealInFinder(c)
            }
        } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
    }

    private var isReview: Bool { if case .review = source { return true } else { return false } }
    private var isWorktree: Bool { if case .worktree = source { return true } else { return false } }

    /// 보기: 한 줄로 / 나란히, 공백 무시
    private var viewOptions: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { store.diffSplit }, set: { store.diffSplit = $0 })) {
                Image(systemName: "list.bullet").help("Unified view").accessibilityLabel("Unified view").tag(false)
                Image(systemName: "rectangle.split.2x1").help("Side by side (old on the left · new on the right)").accessibilityLabel("Side by side").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            let on = store.diffIgnoreWhitespace
            Button { store.diffIgnoreWhitespace.toggle() } label: {
                Image(systemName: "text.word.spacing")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Ignore whitespace")
            .accessibilityValue(on ? "On" : "Off")
            .help("Ignore whitespace\(on ? String(localized: " (on)") : "") — lines that only changed indentation or spaces are treated as unchanged (line staging is unavailable while on)")
        }
    }

    @ViewBuilder
    private func actions(_ c: FileChange) -> some View {
        if case .working = source {
            if c.kind == .conflicted {
                Button("Mark as resolved") { Task { await store.stage([c]) } }
            } else if c.staged {
                Button("Unstage") { Task { await store.unstage([c]) } }
            } else {
                Menu {
                    Button("Discard changes…", role: .destructive) { store.confirmDiscard(c) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("File actions")
                Button("Stage") { Task { await store.stage([c]) } }
                    .buttonStyle(.borderedProminent)
            }
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
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
    }
}

/// diff 줄 목록(한 줄로 / 나란히). 긴 줄은 칸 안에서 줄바꿈해 가로로 밀리지 않고 모두 보인다. 파일 히스토리에서도 쓴다.
struct DiffLinesView: View {
    @Environment(RepoStore.self) private var store
    let doc: DiffDocument
    let split: Bool
    let editable: Bool
    let staged: Bool

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
                            fullRow(doc.lines[f], gutter: numberWidth + 20)
                        } else {
                            Halves {
                                cell(row.left.map { doc.lines[$0] }, side: .left, numberWidth: numberWidth)
                                Rectangle().fill(Color(nsColor: .separatorColor))
                                cell(row.right.map { doc.lines[$0] }, side: .right, numberWidth: numberWidth)
                            }
                        }
                    }
                } else {
                    let gutter = (doc.hasOldSide ? numberWidth : 0) + (doc.hasNewSide ? numberWidth : 0) + 20
                    ForEach(doc.lines) { line in
                        if line.kind == .hunk || line.kind == .meta {
                            fullRow(line, gutter: gutter)
                        } else {
                            DiffLineRow(line: line, showOld: doc.hasOldSide, showNew: doc.hasNewSide, numberWidth: numberWidth,
                                        selected: store.diffSelection.contains(line.id))
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
            Label(line.text, systemImage: "arrow.turn.down.left")
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
            DiffLineRow(line: line, showOld: side == .left, showNew: side == .right, numberWidth: numberWidth,
                        selected: store.diffSelection.contains(line.id))
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
                    Label(text, systemImage: icon).lineLimit(1).truncationMode(.middle)
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

    @ViewBuilder func body(content: Content) -> some View {
        let actualSide = side ?? (line.newNo != nil ? .right : .left)
        let number = actualSide == .left ? line.oldNo : line.newNo
        if enabled, store.fileInspect == nil, let number, line.kind != .hunk, line.kind != .meta,
           case .review(let request, let change, _)? = store.diffSource {
            HStack(alignment: .top, spacing: 0) {
                Button {
                    store.addReviewDraft(request, path: change.path, line: number, side: actualSide, oldLine: line.oldNo)
                } label: {
                    Image(systemName: "plus.bubble.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help("Add review comment")
                .accessibilityLabel(Text("Add review comment on line \(number)"))
                .disabled(store.reviewBusy || store.reviewLoading)
                content
            }
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
    let line: DiffLine
    var showOld = true
    var showNew = true
    var numberWidth: CGFloat = 44
    var selected = false

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
    }

    /// 단어 단위로 바뀐 부분을 진하게
    private var content: AttributedString {
        var s = AttributedString(line.text.isEmpty ? " " : line.text)
        guard !line.changes.isEmpty else { return s }
        let strong = line.kind == .added ? Color.green.opacity(0.32) : Color.red.opacity(0.30)
        let chars = Array(line.text)
        for r in line.changes where r.lowerBound >= 0 && r.upperBound <= chars.count {
            let lo = s.index(s.startIndex, offsetByCharacters: r.lowerBound)
            let hi = s.index(s.startIndex, offsetByCharacters: r.upperBound)
            s[lo..<hi].backgroundColor = strong
        }
        return s
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
                ContentUnavailableView(data == nil ? "None" : "Can't open this image", systemImage: "photo",
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
