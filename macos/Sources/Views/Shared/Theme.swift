import SwiftUI

enum Palette {
    /// 레인 색. 흰 글자를 올려도 읽히도록 채도·명도를 맞췄다.
    static let lanes: [Color] = [
        Color(red: 0.16, green: 0.52, blue: 0.96),   // 파랑
        Color(red: 0.93, green: 0.42, blue: 0.16),   // 주황
        Color(red: 0.18, green: 0.62, blue: 0.36),   // 초록
        Color(red: 0.78, green: 0.30, blue: 0.80),   // 자주
        Color(red: 0.80, green: 0.58, blue: 0.08),   // 황토
        Color(red: 0.08, green: 0.60, blue: 0.66),   // 청록
        Color(red: 0.88, green: 0.27, blue: 0.40),   // 빨강
        Color(red: 0.48, green: 0.40, blue: 0.92),   // 보라
    ]

    static func lane(_ i: Int) -> Color {
        lanes[((i % lanes.count) + lanes.count) % lanes.count]
    }

    /// 실행마다 바뀌지 않는 문자열 해시(색 고정용)
    static func stableHash(_ s: String) -> Int {
        s.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fffffff }
    }
}

enum Fmt {
    // 화면 언어에 맞춘 날짜 형식
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLanguage.locale
        f.unitsStyle = .short
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateStyle = .short
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// 일주일 이내는 "3시간 전", 그보다 오래면 날짜
    static func short(_ d: Date) -> String {
        -d.timeIntervalSinceNow < 7 * 86_400 ? relative.localizedString(for: d, relativeTo: Date()) : day.string(from: d)
    }

    static func long(_ d: Date) -> String { full.string(from: d) }
}

/// 작성자 이니셜 원형 아바타(네트워크 없이 이메일로 색을 고정)
struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(Palette.lane(Palette.stableHash(email.lowercased())))
            .overlay(
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

/// A changed file's status, as the boards draw it: one letter in its tone on that tone's fill, 18 pt square with a
/// 4 pt radius, 11 pt semibold, no border. Untracked is U, a conflict is C, a copy shares the rename's R and a type
/// change the modification's M. (Windows: StatusBadge in entities/git/ui/badges.tsx)
struct StatusBadge: View {
    let kind: ChangeKind

    var body: some View {
        Text(verbatim: letter)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.text)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(tone.fill))
            .help(help)
            .accessibilityLabel(help)
    }

    private var letter: String {
        switch kind {
        case .added: return "A"
        case .modified, .typeChanged: return "M"
        case .deleted: return "D"
        case .renamed, .copied: return "R"
        case .untracked: return "U"
        case .conflicted: return "C"
        }
    }

    private var tone: StudioStyle.Tone {
        switch kind {
        case .added: return .passed
        case .modified, .typeChanged: return .waiting
        case .deleted, .conflicted: return .failed
        case .renamed, .copied: return .info
        case .untracked: return .neutral
        }
    }

    private var help: String {
        switch kind {
        case .added: return String(localized: "Added")
        case .modified: return String(localized: "Modified")
        case .deleted: return String(localized: "Deleted")
        case .renamed: return String(localized: "Renamed")
        case .copied: return String(localized: "Copied")
        case .typeChanged: return String(localized: "Type changed")
        case .untracked: return String(localized: "Untracked")
        case .conflicted: return String(localized: "Conflicted")
        }
    }
}

struct RefBadge: View {
    let label: RefLabel
    let color: Color
    var constrained = false

    var body: some View {
        HStack(spacing: 3) {
            SymbolIcon(icon).font(.system(size: 9, weight: .semibold))
            Text(label.name)
                .font(.system(size: 11, weight: label.isCurrent ? .bold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            if label.isCurrent && label.kind == .local {
                DesignIconImage(icon: .check, size: 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(outlined ? tint : .white)
        .background(RoundedRectangle(cornerRadius: 4).fill(outlined ? tint.opacity(0.12) : tint))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: outlined ? 1 : 0))
        .fixedSize(horizontal: !constrained, vertical: true)
        .help(label.name)
    }

    private var outlined: Bool { label.kind == .remote }

    private var tint: Color {
        switch label.kind {
        case .tag: return Color(nsColor: .systemGray)
        case .head: return Color(nsColor: .labelColor)
        default: return color
        }
    }

    private var icon: String {
        switch label.kind {
        case .head: return "scope"
        case .local: return "arrow.triangle.branch"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
    }
}

/// 오른쪽 패널의 둥근 카드
struct Card<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(12)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// 세로 스크롤의 내용 폭을 패널에 고정해 긴 배지나 문장이 전체 카드를 밀어내지 않게 한다.
struct InspectorScrollView<Content: View>: View {
    /// The room around the content; a flat panel whose sections carry their own padding passes 0
    var inset: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(width: max(0, geometry.size.width - inset * 2), alignment: .topLeading)
                    .padding(inset)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// +12 −3
/// Monospaced 11 pt in the diff's green and red. A file row passes `zeros` and shows both sides, the empty one in grey.
struct LineStatText: View {
    let added: Int
    let deleted: Int
    var zeros = false

    var body: some View {
        HStack(spacing: 4) {
            if zeros || added > 0 { Text(verbatim: "+\(added)").foregroundStyle(added > 0 ? StudioStyle.FileList.added : StudioStyle.Rail.icon) }
            if zeros || deleted > 0 { Text(verbatim: "−\(deleted)").foregroundStyle(deleted > 0 ? StudioStyle.FileList.deleted : StudioStyle.Rail.icon) }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
    }
}

/// 추가·삭제 비율 막대
struct ChangeBar: View {
    let added: Int
    let deleted: Int
    var width: CGFloat = 80

    var body: some View {
        let total = max(1, added + deleted)
        HStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.16, green: 0.6, blue: 0.32)).frame(width: width * CGFloat(added) / CGFloat(total))
            Rectangle().fill(Color(red: 0.85, green: 0.25, blue: 0.28)).frame(width: width * CGFloat(deleted) / CGFloat(total))
        }
        .frame(width: width, height: 6)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
    }
}

/// What a file row still shows as it narrows. The name is never cut while anything else can give way: the rename
/// caption goes first, then the folder shortens by whole segments and goes, then the counts; only a name wider than
/// the row itself is cut. (Windows: fileRowFolds in shared/ui/file-row-folds.ts)
struct FileRowFold: Hashable {
    var folder = ""
    var rename = false
    var stats = false
    var cut = false

    /// A folder and its shorter forms, each cut at a path separator and never inside a name: "a/b/c/d", "…/b/c/d",
    /// "…/c/d", "…/d". No more than the last three segments are tried.
    static func folders(_ directory: String) -> [String] {
        let parts = directory.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }
        return [directory] + (max(1, parts.count - 3)..<parts.count).map { "…/" + parts[$0...].joined(separator: "/") }
    }

    /// The forms to try, widest first
    static func all(directory: String, rename: Bool, stats: Bool) -> [FileRowFold] {
        let folders = folders(directory)
        var result: [FileRowFold] = []
        if rename { result.append(FileRowFold(folder: folders.first ?? "", rename: true, stats: stats)) }
        result += folders.map { FileRowFold(folder: $0, stats: stats) }
        result.append(FileRowFold(stats: stats))
        if stats { result.append(FileRowFold()) }
        result.append(FileRowFold(cut: true))
        return result
    }
}

/// The one changed-file row (docs/design.md, Shared components): working changes, a commit's files, a pull request's
/// files and Compare all draw this. 28 pt tall with a 6 pt radius; the status badge, the name at 13 pt, the folder and
/// the rename caption at 11 pt, then the counts or a neutral pill, the review marks and the row's own action.
/// (Windows: FileRow in shared/ui/FileRow.tsx)
struct FileRow: View {
    let change: FileChange
    let selected: Bool
    var showDirectory = true
    var stat: LineStat? = nil
    /// A neutral pill in place of the counts ("Too large")
    var note: String? = nil
    /// Reviewed already: the name steps back
    var dimmed = false
    var threads = 0
    /// The room before the badge; a tree passes its depth
    var indent: CGFloat = 8
    var actionIcon: String? = nil
    var actionHelp: String = ""
    /// The action as words that are always there (Mark as resolved); an icon action shows on hover or focus only
    var actionTitle: String? = nil
    var action: () -> Void = {}
    /// The review's Viewed box; nil where nothing is reviewed
    var viewed: Bool? = nil
    var setViewed: (Bool) -> Void = { _ in }
    var open: (() -> Void)? = nil
    /// What Space does on the focused row: stage, or tick Viewed; opening when the row has neither
    var space: (() -> Void)? = nil
    /// The hover tip, when the path alone does not say enough
    var tip: String? = nil

    @ViewState private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                ForEach(FileRowFold.all(directory: showDirectory ? change.directory : "", rename: rename != nil, stats: note != nil || stat != nil), id: \.self) {
                    words($0)
                }
            }
            if threads > 0 {
                HStack(spacing: 4) {
                    SymbolIcon("bubble.left").font(.system(size: 11))
                    Text(verbatim: String(threads)).font(.system(size: 11))
                }
                .foregroundStyle(secondary).fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(threads == 1 ? String(localized: "1 thread") : String(localized: "\(threads) threads"))
            }
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(PullRequestTextButtonStyle()).fixedSize()
            }
            if let viewed {
                Button { setViewed(!viewed) } label: {
                    SymbolIcon(viewed ? "checkmark.square.fill" : "square").font(.system(size: 16))
                        .foregroundStyle(viewed ? Color.accentColor : StudioStyle.FileList.box)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Viewed \(change.fileName)")
                .accessibilityLabel("Viewed \(change.fileName)")
                .accessibilityValue(viewed ? "On" : "Off")
            }
            if let actionIcon, actionTitle == nil, hover || focused {
                Button(action: action) { SymbolIcon(actionIcon).font(.system(size: 14)) }
                    .buttonStyle(PullRequestIconButtonStyle())
                    .help(actionHelp)
                    .accessibilityLabel(actionHelp)
            }
        }
        .padding(.leading, indent).padding(.trailing, viewed == nil ? 8 : 2)
        .frame(height: StudioStyle.FileList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.FileList.selection : hover ? StudioStyle.FileList.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open?() }
        .focusable(open != nil)
        .focused($focused)
        .onKeyPress(.return) { open?(); return open == nil ? .ignored : .handled }
        .onKeyPress(.space) { (space ?? open)?(); return space == nil && open == nil ? .ignored : .handled }
        .help(Text(verbatim: tip ?? change.oldPath.map { $0 + " → " + change.path } ?? change.path))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(open == nil ? [] : .isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { open?() }
        .accessibilityActions {
            if !actionHelp.isEmpty || actionTitle != nil { Button(actionTitle ?? actionHelp, action: action) }
            if let viewed { Button("Viewed \(change.fileName)") { setViewed(!viewed) } }
        }
    }

    private var secondary: Color { selected ? StudioStyle.FileList.onSelection : StudioStyle.Rail.icon }

    /// "find.md → search.md" for a rename, "copied from find.md" for a copy; the old folder too when only that changed
    private var rename: String? {
        guard let old = change.oldPath, old != change.path else { return nil }
        let name = (old as NSString).lastPathComponent
        if change.kind == .copied { return String(localized: "copied from \(name)") }
        return (name == change.fileName ? old : name) + " → " + change.fileName
    }

    private func words(_ fold: FileRowFold) -> some View {
        HStack(spacing: 8) {
            StatusBadge(kind: change.kind)
            // the semibold width is kept either way, so selecting a row never moves what follows the name
            Text(verbatim: change.fileName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .fixedSize(horizontal: !fold.cut, vertical: false)
                .hidden()
                .overlay(alignment: .leading) {
                    Text(verbatim: change.fileName).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(dimmed ? AnyShapeStyle(secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.tail)
                        .fixedSize(horizontal: !fold.cut, vertical: false)
                }
            if !fold.folder.isEmpty {
                Text(verbatim: fold.folder).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1).fixedSize()
            }
            if fold.rename, let rename {
                Text(verbatim: rename).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
            if fold.stats {
                if let note {
                    pill(note)
                } else if let stat {
                    if let added = stat.added, let deleted = stat.deleted {
                        LineStatText(added: added, deleted: deleted, zeros: true).fixedSize()
                    } else {
                        pill(String(localized: "Binary"))
                    }
                }
            }
        }
    }

    /// The neutral pill that stands where the counts would be; white on the selection tint
    private func pill(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.Tone.neutral.text)
            .lineLimit(1).padding(.horizontal, 8).frame(height: 18)
            .background(Capsule().fill(selected ? StudioStyle.surface : StudioStyle.Tone.neutral.fill))
            .fixedSize()
    }
}

/// SwiftUI.State 를 프로퍼티 래퍼로 직접 쓰기 위한 별칭.
/// 현재 Command Line Tools 에는 `@State` 매크로 플러그인(SwiftUIMacros)이 빠져 있어서,
/// 이름을 바꿔 매크로 대신 기존 프로퍼티 래퍼가 쓰이게 한다(동작은 @State 와 같다).
typealias ViewState<Value> = SwiftUI.State<Value>
