import SwiftUI

/// The Blame view of the Code page: every line with the commit that last changed it. Consecutive lines from one
/// commit form a group that names the commit once, in a 280 pt gutter; a 1 pt line separates the groups, and no
/// stripes, which read as hover. (Windows: widgets/local-workbench/ui/CodeBlameView.tsx)
struct RepositoryCodeBlameView: View {
    let lines: [BlameLine]
    /// The widest line, so the lines scroll sideways as one sheet
    let textWidth: CGFloat
    let wraps: Bool
    let show: (String) -> Void
    /// Blames the file as it was before a commit; nil when its history does not reach an older commit
    let before: (String) -> (() -> Void)?
    /// The first line of the group under the pointer
    @ViewState private var hovered: Int?
    /// The first line of the group whose commit card is open
    @ViewState private var opened: Int?

    private static let gutter: CGFloat = 280

    var body: some View {
        // each line's group, named by the group's first line
        var group = 0
        let groups = lines.map { line -> Int in
            if line.startsBlock { group = line.id }
            return group
        }
        GeometryReader { geometry in
            ScrollView(wraps ? [.vertical] : [.vertical, .horizontal]) {
                // a wrapped line hangs its indentation, up to half of the columns it has
                let hanging = wraps ? max(0, Int((geometry.size.width - Self.gutter - RepositoryCodeText.gutter - 24) / RepositoryCodeText.advance) / 2) : 0
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(zip(lines, groups)), id: \.0.id) { line, group in row(line, group: group, hanging: hanging) }
                }
                .frame(width: wraps ? geometry.size.width : max(geometry.size.width, Self.gutter + RepositoryCodeText.gutter + textWidth + 24), alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .background(StudioStyle.surface)
        .accessibilityLabel("Blame")
    }

    private func row(_ line: BlameLine, group: Int, hanging: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if line.startsBlock { commit(line) } else { Color.clear }
            }
            .frame(width: Self.gutter)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { StudioStyle.border.frame(width: 1) }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: String(line.id)).foregroundStyle(StudioStyle.Rail.icon)
                    .frame(width: RepositoryCodeText.gutter - 8, alignment: .trailing).padding(.trailing, 8)
                let indent = RepositoryCodeText.hangingIndent(line.text, limit: hanging)
                Text(verbatim: String(repeating: " ", count: indent)).fixedSize().padding(.leading, 12)
                Text(verbatim: line.text.count > indent ? String(line.text.dropFirst(indent)) : " ")
                    .fixedSize(horizontal: !wraps, vertical: true)
                    .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                    .padding(.trailing, 12)
            }
            .font(RepositoryCodeText.swiftFont)
            .padding(.vertical, RepositoryCodeText.inset)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // the whole group answers to the pointer, gutter and code alike
        .background(hovered == group || opened == group ? StudioStyle.hover : Color.clear)
        .overlay(alignment: .top) { if line.startsBlock && line.id > 1 { StudioStyle.border.frame(height: 1) } }
        .onHover { hovered = $0 ? group : (hovered == group ? nil : hovered) }
    }

    @ViewBuilder private func commit(_ line: BlameLine) -> some View {
        if line.uncommitted {
            Text("Not committed").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        } else {
            Button { opened = line.id } label: {
                HStack(spacing: 6) {
                    AuthorAvatar(name: line.author, email: line.email, size: 16)
                    Text(line.summary).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    // the age column is 56 pt, and a longer age takes what it needs from the summary rather than being cut
                    Text(Fmt.short(line.date)).font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1)
                        .frame(minWidth: 56, alignment: .trailing).fixedSize()
                }
                .padding(.horizontal, 10).frame(height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Commit") + " " + String(line.sha.prefix(7)) + ", " + line.summary)
            .popover(isPresented: Binding(get: { opened == line.id }, set: { if !$0 && opened == line.id { opened = nil } }), arrowEdge: .bottom) { card(line) }
        }
    }

    private func card(_ line: BlameLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AuthorAvatar(name: line.author, email: line.email, size: 20)
                Text(line.author).fontWeight(.semibold).lineLimit(1)
                Text(Fmt.short(line.date)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize()
            }
            Text(line.summary).fontWeight(.semibold).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(String(line.sha.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).textSelection(.enabled)
            HStack(spacing: 16) {
                Button("Show commit") { opened = nil; show(line.sha) }
                if let action = before(line.sha) { Button("Blame before this change") { opened = nil; action() } }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(StudioStyle.Rail.icon).frame(minHeight: 24)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 280, alignment: .leading)
    }
}
