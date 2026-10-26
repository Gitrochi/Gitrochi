import SwiftUI

/// 변경 파일 보기 방식(목록/트리) — 작업 영역과 커밋 상세가 함께 쓴다
let fileViewModeKey = "fileViewMode"

struct FileViewToggle: View {
    @AppStorage(fileViewModeKey) private var mode = "list"

    var body: some View {
        Picker("File display", selection: $mode) {
            Image(systemName: "list.bullet").tag("list").help("Show as list").accessibilityLabel("Show as list")
            Image(systemName: "list.bullet.indent").tag("tree").help("Show as folder tree").accessibilityLabel("Show as folder tree")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
    let changes: [FileChange]
    let isSelected: (FileChange) -> Bool
    var stats: [String: LineStat] = [:]
    var actionIcon: String? = nil
    var actionHelp: String = ""
    var onAction: ([FileChange]) -> Void = { _ in }
    let onOpen: (FileChange) -> Void
    @ViewBuilder let menu: (FileChange) -> MenuContent

    @AppStorage(fileViewModeKey) private var mode = "list"
    @ViewState private var collapsed: Set<String> = []

    private let indent: CGFloat = 14

    var body: some View {
        // 수백 개의 미추적 파일이 있어도 현재 보이는 행부터 만든다.
        LazyVStack(alignment: .leading, spacing: 0) {
            if mode == "tree" {
                ForEach(FileTree.rows(changes, collapsed: collapsed)) { row in
                    switch row.kind {
                    case .folder(let path, let name, let files):
                        FolderRow(path: path, name: name, count: files.count, expanded: !collapsed.contains(path),
                                  actionIcon: actionIcon, actionHelp: actionHelp,
                                  action: { onAction(files) },
                                  toggle: { toggle(path) })
                            .padding(.leading, CGFloat(row.depth) * indent)
                    case .file(let c):
                        fileRow(c, showDirectory: false)
                            .padding(.leading, CGFloat(row.depth) * indent + indent)
                    }
                }
            } else {
                ForEach(changes) { c in fileRow(c, showDirectory: true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(_ c: FileChange, showDirectory: Bool) -> some View {
        FileRow(change: c, selected: isSelected(c), showDirectory: showDirectory, stat: stats[c.path],
                actionIcon: actionIcon, actionHelp: actionHelp, action: { onAction([c]) })
            .onTapGesture { onOpen(c) }
            .focusable()
            .onKeyPress(.return) { onOpen(c); return .handled }
            .onKeyPress(.space) { onOpen(c); return .handled }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(c) }
            .accessibilityActions {
                if actionIcon != nil, !actionHelp.isEmpty { Button(actionHelp) { onAction([c]) } }
            }
            .contextMenu { menu(c) }
    }

    private func toggle(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    }
}

private struct FolderRow: View {
    @Environment(RepoStore.self) private var store
    let path: String
    let name: String
    let count: Int
    let expanded: Bool
    var actionIcon: String?
    var actionHelp: String
    var action: () -> Void
    let toggle: () -> Void

    @ViewState private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: expanded ? "folder.fill" : "folder")
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let actionIcon, hover {
                Button(action: action) { Image(systemName: actionIcon) }
                    .buttonStyle(.borderless)
                    .help(actionHelp + String(localized: " — whole folder"))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Show in Finder") { store.revealInFinder(path: path) }
            Button("Copy path") { store.copy(path) }
        }
    }
}
