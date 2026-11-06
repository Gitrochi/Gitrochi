import SwiftUI

/// The History view of the Code page: the commits that changed the file in a 312 pt list column, and the chosen
/// commit's change beside it. (Windows: widgets/local-workbench/ui/CodeHistoryView.tsx)
struct RepositoryCodeHistoryView: View {
    let repository: URL
    /// nil while the commits are being read
    let entries: [FileHistoryEntry]?
    /// The commits that are on no remote yet
    let local: Set<String>
    @Binding var selected: String?
    @Binding var wraps: Bool
    @Binding var lineCount: Int?
    @FocusState private var focused: Bool

    var body: some View {
        if let entries {
            if let entry = entries.first(where: { $0.id == selected }) ?? entries.first {
                AdaptiveWorkbenchSplit(threshold: 680, listWidth: 312) {
                    list(Array(entries.prefix(RepositoryCodeHistory.limit)), current: entry.id)
                } detail: {
                    RepositoryCodeChangesView(repository: repository, path: entry.path, commit: entry.commit.id, wraps: $wraps, lineCount: $lineCount)
                }
            } else {
                ContentUnavailableView("No history", systemImage: "clock", description: Text("This file hasn't been committed yet."))
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ entries: [FileHistoryEntry], current: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(entries) { row($0, selected: $0.id == current).id($0.id) }
                }
                .padding(8)
            }
            // a click on a row takes the keys, so the arrows then move the selection as in any list
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard let index = entries.firstIndex(where: { $0.id == current }) else { return }
                let next = direction == .up ? index - 1 : direction == .down ? index + 1 : index
                guard next != index, entries.indices.contains(next) else { return }
                selected = entries[next].id
                proxy.scrollTo(entries[next].id)
            }
        }
        .accessibilityLabel("Commits that changed this file")
    }

    private func row(_ entry: FileHistoryEntry, selected isSelected: Bool) -> some View {
        RepositoryCodeRow(selected: isSelected, action: { selected = entry.id; focused = true }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.commit.subject).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).lineLimit(2)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.short(entry.commit.date)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize()
                }
                HStack(spacing: 6) {
                    AuthorAvatar(name: entry.commit.author, email: entry.commit.email, size: 16)
                    Text(entry.commit.author).font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1)
                    Text(entry.commit.short).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).fixedSize()
                    if local.contains(entry.id) {
                        // a marker, not a status: neutral, and white on the selected row (docs/design.md, Selection)
                        Text("local").font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.Tone.neutral.text)
                            .padding(.horizontal, 8).frame(height: 18)
                            .background(Capsule().fill(isSelected ? StudioStyle.surface : StudioStyle.Tone.neutral.fill)).fixedSize()
                            .help("Commits not pushed to the remote")
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }
}
