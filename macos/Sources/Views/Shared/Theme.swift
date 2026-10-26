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

struct StatusBadge: View {
    let kind: ChangeKind

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.25)))
            .help(help)
            .accessibilityLabel(help)
    }

    private var letter: String {
        switch kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "N"
        case .conflicted: return "!"
        }
    }

    private var color: Color {
        switch kind {
        case .added, .untracked: return StudioStyle.added
        case .modified, .typeChanged: return Color(nsColor: .systemOrange)
        case .deleted, .conflicted: return StudioStyle.deleted
        case .renamed, .copied: return Color(nsColor: .systemBlue)
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
        case .untracked: return String(localized: "New file (untracked)")
        case .conflicted: return String(localized: "Conflict")
        }
    }
}

struct RefBadge: View {
    let label: RefLabel
    let color: Color
    var constrained = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(label.name)
                .font(.system(size: 11, weight: label.isCurrent ? .bold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            if label.isCurrent && label.kind == .local {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
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
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(width: max(0, geometry.size.width - 24), alignment: .topLeading)
                    .padding(12)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// +12 −3
struct LineStatText: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(Color(red: 0.16, green: 0.6, blue: 0.32)) }
            if deleted > 0 { Text("−\(deleted)").foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.28)) }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
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

/// 변경 파일 한 줄(작업 영역·커밋 상세 공용)
struct FileRow: View {
    let change: FileChange
    let selected: Bool
    var showDirectory = true
    var stat: LineStat? = nil
    var actionIcon: String? = nil
    var actionHelp: String = ""
    var action: () -> Void = {}

    @ViewState private var hover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showMetadata: true)
            row(showMetadata: false)
        }
        .frame(minHeight: StudioStyle.rowHeight)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hover ? StudioStyle.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(change.path)
    }

    // Keep the filename readable before allocating space to secondary metadata.
    private func row(showMetadata: Bool) -> some View {
        HStack(spacing: 8) {
            StatusBadge(kind: change.kind)
            Text(change.fileName)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: showMetadata, vertical: false)
                .layoutPriority(1)
            if showMetadata, let old = change.oldPath {
                Text("← \(showDirectory ? old : (old as NSString).lastPathComponent)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if showMetadata && showDirectory {
                Text(change.directory)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if showMetadata, let stat {
                Group {
                    if let a = stat.added, let d = stat.deleted {
                        LineStatText(added: a, deleted: d)
                    } else {
                        Text("Binary").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .fixedSize()
                .layoutPriority(2)
            }
            if let actionIcon {
                Button(action: action) {
                    Image(systemName: actionIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(selected ? StudioStyle.accent : Color.secondary)
                .help(actionHelp)
                .accessibilityLabel(actionHelp)
            }
        }
    }
}

/// SwiftUI.State 를 프로퍼티 래퍼로 직접 쓰기 위한 별칭.
/// 현재 Command Line Tools 에는 `@State` 매크로 플러그인(SwiftUIMacros)이 빠져 있어서,
/// 이름을 바꿔 매크로 대신 기존 프로퍼티 래퍼가 쓰이게 한다(동작은 @State 와 같다).
typealias ViewState<Value> = SwiftUI.State<Value>
