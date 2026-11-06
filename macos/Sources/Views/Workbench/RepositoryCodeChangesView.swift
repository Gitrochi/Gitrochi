import SwiftUI
import AppKit
import CoreText

/// One file's change on the Code page, read only: a commit against its first parent, or the working tree against
/// HEAD. One 44 pt header, then the lines, with the unchanged lines between hunks folded until asked for.
/// (Windows: widgets/local-workbench/ui/CodeChangesView.tsx)
struct RepositoryCodeChangesView: View {
    @Environment(RepoStore.self) private var store
    let repository: URL
    let path: String
    /// nil for the working tree against HEAD
    let commit: String?
    @Binding var wraps: Bool
    /// The line count of the file as the commit has it, for the status bar
    @Binding var lineCount: Int?
    @ViewState private var document: DiffDocument?
    /// The file as the commit has it: the unchanged lines come from here
    @ViewState private var source: [String]?
    @ViewState private var expanded: Set<Int> = []
    /// The widest line, so the lines scroll sideways as one sheet
    @ViewState private var textWidth: CGFloat = 0

    private struct Key: Equatable { let repository: URL; let path: String; let commit: String?; let ignoreWhitespace: Bool }
    private struct Cell { let kind: DiffLine.Kind; let text: String; let oldNo: Int?; let newNo: Int?; let changes: [Range<Int>] }
    private enum Row: Identifiable {
        case fold(RepositoryCodeHistory.Gap)
        case hunk(DiffLine)
        case note(DiffLine)
        case line(String, Cell)
        case pair(String, Cell?, Cell?)

        var id: String {
            switch self {
            case .fold(let gap): return "fold-\(gap.hunk)"
            case .hunk(let line): return "hunk-\(line.id)"
            case .note(let line): return "note-\(line.id)"
            case .line(let id, _), .pair(let id, _, _): return id
            }
        }
    }

    var body: some View {
        let _ = store.diffSettingsVersion
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(folder: RepositoryCodeHistory.shortFolder((path as NSString).deletingLastPathComponent))
                header(folder: "")
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: Key(repository: repository, path: path, commit: commit, ignoreWhitespace: store.diffIgnoreWhitespace)) { await load() }
    }

    // MARK: Header

    private func header(folder: String) -> some View {
        HStack(spacing: 8) {
            if let document, document.error == nil { StatusBadge(kind: kind(document)) }
            Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            if !folder.isEmpty {
                Text(folder).font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).fixedSize()
                    .help((path as NSString).deletingLastPathComponent)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { store.diffSplit }, set: { store.diffSplit = $0 })) {
                Text("Unified").tag(false)
                Text("Split").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            let hidden = store.diffIgnoreWhitespace
            Button { store.diffIgnoreWhitespace.toggle() } label: {
                Image(systemName: "paragraphsign").font(.system(size: 13))
                    .foregroundStyle(hidden ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Rail.icon))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hidden ? StudioStyle.Tone.neutral.fill : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Ignore whitespace").accessibilityLabel("Ignore whitespace")
            .accessibilityValue(hidden ? String(localized: "On") : String(localized: "Off"))
            Menu {
                Toggle("Wrap lines", isOn: $wraps)
                if let commit { Button("Show commit") { store.reveal(commit) } }
                Button("Copy path") { store.copy(path) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func kind(_ document: DiffDocument) -> ChangeKind {
        document.info.newFile ? .added : document.info.deletedFile ? .deleted : document.info.renamed ? .renamed : .modified
    }

    // MARK: Lines

    @ViewBuilder private var content: some View {
        if let document {
            if let error = document.error {
                ContentUnavailableView("Couldn't read the changes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if document.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper")
            } else if document.lines.isEmpty {
                ContentUnavailableView("No changes to show", systemImage: "equal.circle",
                                       description: Text(verbatim: store.diffIgnoreWhitespace ? String(localized: "Only whitespace changed (turn off Ignore whitespace to see it).") : ""))
            } else {
                lines(document)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func lines(_ document: DiffDocument) -> some View {
        // two halves wrap in place: scrolling them sideways together would hide one of them
        let halves = store.diffSplit && !document.oneSided, wrapping = wraps || halves
        let list = rows(document, halves: halves)
        return GeometryReader { geometry in
            ScrollView(wrapping ? [.vertical] : [.vertical, .horizontal]) {
                // a wrapped line hangs its indentation, up to half of the columns it has
                let room = (halves ? (geometry.size.width - 1) / 2 - RepositoryCodeText.gutter : geometry.size.width - RepositoryCodeText.gutter * 2) - 28
                let hanging = wrapping ? max(0, Int(room / RepositoryCodeText.advance) / 2) : 0
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { row($0, halves: halves, wrapping: wrapping, hanging: hanging) }
                    if document.truncated {
                        Text("… The diff is too long; only the beginning is shown").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).padding(12)
                    }
                }
                .frame(width: wrapping ? geometry.size.width : max(geometry.size.width, RepositoryCodeText.gutter * 2 + 16 + textWidth + 12), alignment: .leading)
                .padding(.bottom, 16)
            }
        }
        .background(StudioStyle.surface)
        .accessibilityLabel(halves ? "Side by side" : "Unified view")
    }

    private func rows(_ document: DiffDocument, halves: Bool) -> [Row] {
        let gaps = source.map { RepositoryCodeHistory.gaps(document.hunks.map { RepositoryCodeHistory.Hunk(oldStart: $0.oldStart, oldCount: $0.oldCount, newStart: $0.newStart, newCount: $0.newCount) }, lineCount: $0.count) } ?? []
        var result: [Row] = []
        func unchanged(before hunk: Int) {
            guard let gap = gaps.first(where: { $0.hunk == hunk }), let source else { return }
            guard expanded.contains(hunk) else { result.append(.fold(gap)); return }
            for offset in 0..<gap.count where source.indices.contains(gap.newStart - 1 + offset) {
                let cell = Cell(kind: .context, text: source[gap.newStart - 1 + offset], oldNo: gap.oldStart + offset, newNo: gap.newStart + offset, changes: [])
                result.append(halves ? .pair("gap-\(hunk)-\(offset)", cell, cell) : .line("gap-\(hunk)-\(offset)", cell))
            }
        }
        func cell(_ index: Int?) -> Cell? {
            index.map { document.lines[$0] }.map { Cell(kind: $0.kind, text: $0.text, oldNo: $0.oldNo, newNo: $0.newNo, changes: $0.changes) }
        }
        func full(_ line: DiffLine) {
            if line.kind == .hunk { unchanged(before: line.hunk ?? 0); result.append(.hunk(line)) } else { result.append(.note(line)) }
        }
        if halves {
            for row in document.splitRows {
                if let index = row.full { full(document.lines[index]) } else { result.append(.pair("pair-\(row.id)", cell(row.left), cell(row.right))) }
            }
        } else {
            for line in document.lines {
                if line.kind == .hunk || line.kind == .meta { full(line) } else if let value = cell(line.id) { result.append(.line("line-\(line.id)", value)) }
            }
        }
        unchanged(before: document.hunks.count)
        return result
    }

    @ViewBuilder private func row(_ row: Row, halves: Bool, wrapping: Bool, hanging: Int) -> some View {
        let indent = halves ? RepositoryCodeText.gutter + 16 : RepositoryCodeText.gutter * 2 + 16
        switch row {
        case .fold(let gap):
            Button { expand(gap) } label: {
                Text(verbatim: "⋯ " + String(localized: "\(gap.count) unchanged lines")).font(.system(size: 12, weight: .medium)).foregroundStyle(StudioStyle.Rail.icon)
                    .padding(.leading, indent).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(StudioStyle.canvas)
            .overlay(alignment: .top) { StudioStyle.border.frame(height: 1) }
            .overlay(alignment: .bottom) { StudioStyle.border.frame(height: 1) }
            .accessibilityLabel(String(localized: "Show \(gap.count) unchanged lines, \(gap.newStart) to \(gap.newStart + gap.count - 1)"))
        case .hunk(let line):
            Text(line.text).font(RepositoryCodeText.swiftFont).foregroundStyle(StudioStyle.Tone.info.text).lineLimit(1)
                .padding(.leading, indent).padding(.trailing, 12).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(StudioStyle.Tone.info.fill.opacity(0.6))
        case .note(let line):
            Label(line.text, systemImage: "arrow.turn.down.left").font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon)
                .padding(.leading, indent).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        case .line(_, let cell):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(cell.oldNo)
                number(cell.newNo)
                code(cell, wrapping: wrapping, hanging: hanging)
            }
            .padding(.vertical, RepositoryCodeText.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill(cell.kind))
        case .pair(_, let left, let right):
            HStack(alignment: .top, spacing: 0) {
                half(left, number: left?.oldNo, wrapping: wrapping, hanging: hanging)
                StudioStyle.border.frame(width: 1)
                half(right, number: right?.newNo, wrapping: wrapping, hanging: hanging)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func half(_ cell: Cell?, number value: Int?, wrapping: Bool, hanging: Int) -> some View {
        if let cell {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(value)
                code(cell, wrapping: wrapping, hanging: hanging)
            }
            .padding(.vertical, RepositoryCodeText.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill(cell.kind))
        } else {
            StudioStyle.canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? " ").font(RepositoryCodeText.swiftFont).foregroundStyle(StudioStyle.Rail.icon)
            .frame(width: RepositoryCodeText.gutter - 8, alignment: .trailing).padding(.trailing, 8)
    }

    @ViewBuilder private func code(_ cell: Cell, wrapping: Bool, hanging: Int) -> some View {
        // the sign says it as well as the colour
        Text(verbatim: cell.kind == .added ? "+" : cell.kind == .removed ? "−" : " ").font(RepositoryCodeText.swiftFont)
            .foregroundStyle(cell.kind == .added ? StudioStyle.Tone.passed.text : StudioStyle.Tone.failed.text)
            .frame(width: 16)
        let indent = RepositoryCodeText.hangingIndent(cell.text, limit: hanging)
        if indent > 0 { Text(verbatim: String(repeating: " ", count: indent)).font(RepositoryCodeText.swiftFont).fixedSize() }
        Text(marked(cell, dropping: indent)).font(RepositoryCodeText.swiftFont).foregroundStyle(.primary)
            .fixedSize(horizontal: !wrapping, vertical: true)
            .frame(maxWidth: wrapping ? .infinity : nil, alignment: .leading)
            .padding(.trailing, 12)
    }

    private func fill(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? StudioStyle.added.opacity(0.12) : kind == .removed ? StudioStyle.deleted.opacity(0.12) : .clear
    }

    /// The line without its first `indent` spaces, the words that changed inside it on a stronger fill
    private func marked(_ cell: Cell, dropping indent: Int) -> AttributedString {
        var text = AttributedString(cell.text.count > indent ? String(cell.text.dropFirst(indent)) : " ")
        guard !cell.changes.isEmpty else { return text }
        let fill = (cell.kind == .added ? StudioStyle.added : StudioStyle.deleted).opacity(0.28), count = cell.text.count - indent
        for range in cell.changes where range.lowerBound >= indent && range.upperBound - indent <= count {
            text[text.index(text.startIndex, offsetByCharacters: range.lowerBound - indent)..<text.index(text.startIndex, offsetByCharacters: range.upperBound - indent)].backgroundColor = fill
        }
        return text
    }

    private func expand(_ gap: RepositoryCodeHistory.Gap) {
        if let source {
            let lines = Array(source[min(source.count, gap.newStart - 1)..<min(source.count, gap.newStart - 1 + gap.count)])
            textWidth = max(textWidth, RepositoryCodeText.width(lines))
        }
        expanded.insert(gap.hunk)
    }

    // MARK: Reading

    private func load() async {
        document = nil; source = nil; expanded = []; lineCount = nil; textWidth = 0
        let args = commit.map { RepositoryCodeHistory.changeArgs(commit: $0, path: path, ignoreWhitespace: store.diffIgnoreWhitespace) }
            ?? RepositoryCodeHistory.workingArgs(path: path, ignoreWhitespace: store.diffIgnoreWhitespace)
        guard let output = try? await Git.run(args, in: repository).output else {
            if !Task.isCancelled { document = DiffDocument(error: String(localized: "Couldn't read this commit's changes.")) }
            return
        }
        // a file's change in one commit is short; a generated file must not fill the page
        let parsed = await Task.detached(priority: .userInitiated) { () -> (DiffDocument, CGFloat) in
            let value = Parsers.diff(output, maxLines: 5000)
            return (value, RepositoryCodeText.width(value.lines.filter { $0.kind != .hunk && $0.kind != .meta }.map(\.text)))
        }.value
        guard !Task.isCancelled else { return }
        document = parsed.0; textWidth = parsed.1
        guard let commit, parsed.0.error == nil, !parsed.0.isBinary, !parsed.0.info.deletedFile, !parsed.0.lines.isEmpty,
              let data = try? await Git.run(RepositoryCodeHistory.fileArgs(commit: commit, path: path), in: repository).data,
              data.count <= RepositoryBrowser.textLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return }
        let lines = await Task.detached(priority: .userInitiated) { RepositoryCodeHistory.lines(text) }.value
        guard !Task.isCancelled else { return }
        source = lines; lineCount = lines.count
    }
}

/// The Code page's monospaced text: 12 pt on 20 pt rows, behind a 40 pt line-number column
enum RepositoryCodeText {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let swiftFont = Font.system(size: 12, design: .monospaced)
    static let gutter: CGFloat = 40
    /// What a line of text leaves of a 20 pt row, above and below
    static let inset = max(0, (20 - (font.ascender - font.descender + font.leading).rounded(.up)) / 2)

    /// One character's width
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width

    /// How much of a line's indentation is drawn beside it when lines wrap, so the rows a long line continues on
    /// stay under its first word instead of starting at the margin. The limit leaves a deep indent room to read.
    static func hangingIndent(_ text: String, limit: Int) -> Int {
        limit > 0 ? min(limit, text.prefix { $0 == " " }.count) : 0
    }

    /// The width of the widest of these lines. Measured, because wide characters and fallback fonts do not keep the
    /// monospaced advance; safe off the main thread.
    static func width(_ lines: [String]) -> CGFloat {
        var result: CGFloat = 0
        let attributes = [NSAttributedString.Key.font: font]
        for line in lines where !line.isEmpty {
            let measured = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), nil, nil, nil)
            result = max(result, CGFloat(measured))
        }
        return result.rounded(.up)
    }
}
