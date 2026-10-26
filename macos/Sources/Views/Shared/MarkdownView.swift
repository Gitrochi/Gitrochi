import SwiftUI
import AppKit

/// Markdown drawn as SwiftUI views (Windows: shared/ui/Markdown.tsx). Links open in the browser.
struct MarkdownView: View {
    private let blocks: [Markdown.Block]
    private let canLoadImage: (URL) -> Bool

    /// canLoadImage decides which image URLs may load; the rest show as links so arbitrary servers aren't contacted
    init(_ text: String, refs: Markdown.Refs? = nil, canLoadImage: @escaping (URL) -> Bool = { _ in false }) {
        blocks = Markdown.parse(text, refs: refs)
        self.canLoadImage = canLoadImage
    }

    /// #123 · @name links and images from the repository's own server
    init(_ text: String, target: RepoTarget?) {
        self.init(text, refs: target?.markdownRefs, canLoadImage: { target?.canLoadImage($0) ?? false })
    }

    var body: some View {
        MarkdownBlocks(blocks: blocks, spacing: 8, canLoadImage: canLoadImage)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocks: View {
    let blocks: [Markdown.Block]
    let spacing: CGFloat
    let canLoadImage: (URL) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                MarkdownBlock(block: b, canLoadImage: canLoadImage)
            }
        }
    }
}

private struct MarkdownBlock: View {
    let block: Markdown.Block
    let canLoadImage: (URL) -> Bool

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            if let images = Self.imagesOnly(inlines) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                        MarkdownImage(src: img.src, alt: img.alt, link: img.link, canLoad: canLoadImage)
                    }
                }
            } else {
                Text(Self.attributed(inlines)).fixedSize(horizontal: false, vertical: true)
            }
        case .heading(let level, let inlines):
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.attributed(inlines))
                    .font(Self.headingFont(level))
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 { Divider() }
            }
            .padding(.top, 2)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize()
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, spacing: 8, canLoadImage: canLoadImage)
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.35)).frame(width: 3)
                }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Self.marker(ordered: ordered, number: start + i, task: item.task)
                            .frame(minWidth: 14, alignment: .trailing)
                        MarkdownBlocks(blocks: item.blocks, spacing: 3, canLoadImage: canLoadImage)
                    }
                }
            }
        case .table(let align, let head, let rows):
            MarkdownTable(align: align, head: head, rows: rows)
        case .details(let summary, let blocks):
            DisclosureGroup {
                MarkdownBlocks(blocks: blocks, spacing: 8, canLoadImage: canLoadImage)
                    .padding(.top, 4)
            } label: {
                Text(Self.attributed(summary)).fontWeight(.medium)
            }
        case .rule:
            Divider()
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .body.weight(.semibold)
        }
    }

    private static func marker(ordered: Bool, number: Int, task: Bool?) -> Text {
        if let task {
            return Text(Image(systemName: task ? "checkmark.square.fill" : "square")).foregroundStyle(task ? Color.accentColor : Color.secondary)
        }
        return ordered ? Text(verbatim: "\(number).").monospacedDigit() : Text(verbatim: "•")
    }

    /// A paragraph of nothing but images (maybe linked) is drawn as images; elsewhere an image becomes a link
    private static func imagesOnly(_ nodes: [Markdown.Inline]) -> [(src: String, alt: String, link: String?)]? {
        var images: [(src: String, alt: String, link: String?)] = []
        for n in nodes {
            switch n {
            case .image(let src, let alt):
                images.append((src, alt, nil))
            case .link(let href, let children):
                guard children.count == 1, case .image(let src, let alt) = children[0] else { return nil }
                images.append((src, alt, href))
            case .lineBreak:
                continue
            case .text(let t) where t.trimmed.isEmpty:
                continue
            default:
                return nil
            }
        }
        return images.isEmpty ? nil : images
    }

    static func attributed(_ nodes: [Markdown.Inline], _ intent: InlinePresentationIntent = []) -> AttributedString {
        var out = AttributedString()
        for n in nodes {
            switch n {
            case .text(let t):
                var a = AttributedString(t)
                if !intent.isEmpty { a.inlinePresentationIntent = intent }
                out += a
            case .lineBreak:
                out += AttributedString("\n")
            case .code(let t):
                var a = AttributedString(t)
                a.inlinePresentationIntent = intent.union(.code)
                a.swiftUI.backgroundColor = Color.secondary.opacity(0.15)
                out += a
            case .strong(let c):
                out += attributed(c, intent.union(.stronglyEmphasized))
            case .em(let c):
                out += attributed(c, intent.union(.emphasized))
            case .strike(let c):
                out += attributed(c, intent.union(.strikethrough))
            case .link(let href, let c):
                var a = attributed(c, intent)
                a.link = URL(string: href)
                out += a
            case .image(let src, let alt):
                var a = AttributedString("🖼 " + (alt.isEmpty ? MarkdownImage.fileName(src) : alt))
                a.link = URL(string: src)
                out += a
            }
        }
        return out
    }
}

private struct MarkdownTable: View {
    let align: [Markdown.Align?]
    let head: [[Markdown.Inline]]
    let rows: [[[Markdown.Inline]]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(head.indices, id: \.self) { c in
                        cell(head[c], c).fontWeight(.semibold).background(Color.secondary.opacity(0.06))
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c], c) }
                    }
                }
            }
        }
    }

    private func cell(_ inlines: [Markdown.Inline], _ column: Int) -> some View {
        let a = column < align.count ? align[column] : nil
        return Text(MarkdownBlock.attributed(inlines))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: a == .center ? .center : a == .right ? .trailing : .leading)
            .border(Color.secondary.opacity(0.25), width: 0.5)
    }
}

/// Loads only what canLoad allows; anything else, or a failed load, is a link to the image
private struct MarkdownImage: View {
    let src: String
    let alt: String
    let link: String?
    let canLoad: (URL) -> Bool

    @ViewState private var image: NSImage?
    @ViewState private var failed = false

    var body: some View {
        let url = URL(string: src)
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, maxHeight: min(image.size.height, 360), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { if let u = URL(string: link ?? src) { NSWorkspace.shared.open(u) } }
                .help(alt.isEmpty ? src : alt)
                .accessibilityLabel(alt)
        } else if failed || url.map(canLoad) != true {
            Text(fallback)
        } else {
            ProgressView()
                .controlSize(.small)
                .task(id: src) { await load(url!) }
        }
    }

    private var fallback: AttributedString {
        var a = AttributedString("🖼 " + (alt.isEmpty ? Self.fileName(src) : alt))
        a.link = URL(string: link ?? src)
        return a
    }

    private func load(_ url: URL) async {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data), img.size.width > 0
        else {
            failed = true
            return
        }
        image = img
    }

    static func fileName(_ src: String) -> String {
        let path = src.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? src
        let last = path.split(separator: "/").last.map(String.init) ?? src
        return last.removingPercentEncoding ?? last
    }
}
