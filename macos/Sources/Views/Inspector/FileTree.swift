import SwiftUI

/// 변경 파일 보기 방식(목록/트리) — 작업 영역과 커밋 상세가 함께 쓴다
let fileViewModeKey = "fileViewMode"
/// Requests open as a tree (the Changed files board); the choice is apart from the repository's changes
let requestFileViewModeKey = "requestFileViewMode"

/// The list/tree toggle every file list shares: the icon form of `Segmented`. (Windows: FileViewToggle)
struct FileViewToggle: View {
    @AppStorage private var mode: String

    init(key: String = fileViewModeKey, fallback: String = "list") { _mode = AppStorage(wrappedValue: fallback, key) }

    var body: some View {
        Segmented(label: "File list layout", items: [
            .init(value: "list", icon: .fileList, label: String(localized: "Show as list")),
            .init(value: "tree", icon: .fileTree, label: String(localized: "Show as folder tree")),
        ], selection: mode == "tree" ? "tree" : "list") { mode = $0 }
    }
}

struct FileTreeRow: Identifiable {
    enum Kind {
        case folder(path: String, name: String, files: [FileChange])
        case file(FileChange)
    }
    let id: String
    let depth: Int
    let kind: Kind
}

enum FileTree {
    /// One level of the tree
    static let indent: CGFloat = 14

    /// Where a file's badge starts at a depth: past the folder's chevron slot, under its glyph
    static func fileIndent(depth: Int) -> CGFloat { 6 + CGFloat(depth) * indent + 18 }

    private final class Node {
        var dirs: [String: Node] = [:]
        var files: [FileChange] = []
    }

    /// 경로를 폴더 트리로 펼친 행. 파일 없이 폴더 하나만 든 폴더는 한 줄로 합친다(src/main/java).
    static func rows(_ changes: [FileChange], collapsed: Set<String>) -> [FileTreeRow] {
        let root = Node()
        for c in changes {
            var node = root
            for dir in c.path.split(separator: "/").dropLast().map(String.init) {
                if node.dirs[dir] == nil { node.dirs[dir] = Node() }
                node = node.dirs[dir]!
            }
            node.files.append(c)
        }

        func allFiles(_ n: Node) -> [FileChange] { n.files + n.dirs.values.flatMap { allFiles($0) } }

        var out: [FileTreeRow] = []
        func emit(_ n: Node, prefix: String, depth: Int) {
            for name in n.dirs.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                var child = n.dirs[name]!
                var label = name
                var path = prefix.isEmpty ? name : prefix + "/" + name
                while child.files.isEmpty, child.dirs.count == 1, let only = child.dirs.first {
                    label += "/" + only.key
                    path += "/" + only.key
                    child = only.value
                }
                out.append(FileTreeRow(id: "d:" + path, depth: depth, kind: .folder(path: path, name: label, files: allFiles(child))))
                if !collapsed.contains(path) { emit(child, prefix: path, depth: depth + 1) }
            }
            for f in n.files.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
                out.append(FileTreeRow(id: "f:" + f.id, depth: depth, kind: .file(f)))
            }
        }
        emit(root, prefix: "", depth: 0)
        return out
    }
}

/// 변경 파일 목록. 트리 모드에서는 폴더를 접고 펼 수 있고, 폴더 단위로 스테이지·언스테이지할 수 있다.
struct ChangeList<MenuContent: View>: View {
    @Environment(RepoStore.self) private var store
    let changes: [FileChange]
    let isSelected: (FileChange) -> Bool
    var stats: [String: LineStat] = [:]
    var actionIcon: String? = nil
    var actionHelp: String = ""
    /// The action as words on every row (Mark as resolved) instead of an icon on hover
    var actionTitle: String? = nil
    var onAction: ([FileChange]) -> Void = { _ in }
    let onOpen: (FileChange) -> Void
    @ViewBuilder let menu: (FileChange) -> MenuContent

    @AppStorage(fileViewModeKey) private var mode = "list"
    @ViewState private var collapsed: Set<String> = []

    var body: some View {
        // 수백 개의 미추적 파일이 있어도 현재 보이는 행부터 만든다. Rows keep the board's 4 pt between them.
        LazyVStack(alignment: .leading, spacing: 4) {
            if mode == "tree" {
                ForEach(FileTree.rows(changes, collapsed: collapsed)) { row in
                    switch row.kind {
                    case .folder(let path, let name, let files):
                        FileFolderRow(name: name, count: files.count, depth: row.depth, expanded: !collapsed.contains(path),
                                      actionIcon: actionIcon,
                                      actionHelp: actionHelp + String(localized: " — whole folder"),
                                      action: { onAction(files) },
                                      toggle: { toggle(path) })
                            .contextMenu {
                                Button("Show in Finder") { store.revealInFinder(path: path) }
                                Button("Copy path") { store.copy(path) }
                            }
                    case .file(let c):
                        fileRow(c, showDirectory: false, indent: FileTree.fileIndent(depth: row.depth))
                    }
                }
            } else {
                ForEach(changes) { c in fileRow(c, showDirectory: true, indent: 8) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(_ c: FileChange, showDirectory: Bool, indent: CGFloat) -> some View {
        FileRow(change: c, selected: isSelected(c), showDirectory: showDirectory, stat: stats[c.path], indent: indent,
                actionIcon: actionIcon, actionHelp: actionHelp, actionTitle: actionTitle, action: { onAction([c]) },
                open: { onOpen(c) },
                // Space stages or unstages where the list has that action, and opens the file elsewhere
                space: actionIcon == nil ? nil : { onAction([c]) })
            .contextMenu { menu(c) }
    }

    private func toggle(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    }
}

/// A folder of the tree every file list shares: 28 pt, a chevron in a 10 pt slot, the folder glyph and the name in
/// medium, all neutral, then a count pill when it holds more than one file. (Windows: FileFolderRow)
struct FileFolderRow: View {
    let name: String
    let count: Int
    let depth: Int
    let expanded: Bool
    var actionIcon: String? = nil
    var actionHelp: String = ""
    var action: () -> Void = {}
    let toggle: () -> Void

    @ViewState private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    SymbolIcon(expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    DesignIconImage(icon: .repository, size: 13)
                    Text(verbatim: name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.head)
                    // a folder holding a single file needs no count
                    if count > 1 {
                        Text(verbatim: String(count)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(StudioStyle.Tone.neutral.text)
                            .padding(.horizontal, 8).frame(height: 18)
                            .background(Capsule().fill(StudioStyle.Tone.neutral.fill))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioStyle.Rail.icon)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: name))
            if let actionIcon, hover {
                Button(action: action) { SymbolIcon(actionIcon).font(.system(size: 14)) }
                    .buttonStyle(PullRequestIconButtonStyle())
                    .help(actionHelp)
                    .accessibilityLabel(actionHelp)
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * FileTree.indent).padding(.trailing, 8)
        .frame(height: StudioStyle.FileList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? StudioStyle.FileList.hover : Color.clear))
        .onHover { hover = $0 }
    }
}
