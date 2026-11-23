import SwiftUI

/// The file's type as a small glyph in its colour, grey when it has none (Windows: FileTypeIcon in shared/ui/FileTypeIcon.tsx)
struct FileTypeIcon: View {
    let path: String
    var size: CGFloat = 12

    var body: some View {
        let icon = FileIcon.of(path)
        SymbolIcon(Self.symbol(icon.kind)).font(.system(size: size))
            .foregroundStyle(icon.color.map { value in
                Color(.sRGB, red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
            } ?? StudioStyle.Rail.icon)
            .frame(width: size + 2)
            .accessibilityHidden(true)
    }

    static func symbol(_ kind: FileIcon.Kind) -> String {
        switch kind {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .style: return "paintpalette"
        case .json: return "curlybraces"
        case .config: return "gearshape"
        case .markdown, .text, .pdf: return "doc.text"
        case .sql: return "cylinder"
        case .shell: return "terminal"
        case .image: return "photo"
        case .archive: return "doc.zipper"
        case .lock: return "lock"
        case .git: return "arrow.triangle.branch"
        case .docker: return "cube"
        case .file: return "doc"
        }
    }
}
