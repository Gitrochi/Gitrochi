import SwiftUI
import AppKit

/// Markdown drawn as SwiftUI views (Windows: shared/ui/Markdown.tsx). Links open in the browser.
struct MarkdownView: View {
    private let blocks: [Markdown.Block]
    private let canLoadImage: (URL) -> Bool

    /// canLoadImage decides which image URLs may load; the rest show as links so arbitrary servers aren't contacted
    init(_ text: String, refs: Markdown.Refs? = nil, baseURL: URL? = nil, imageBaseURL: URL? = nil, canLoadImage: @escaping (URL) -> Bool = { _ in false }) {
        blocks = Markdown.parse(text, refs: refs, baseURL: baseURL, imageBaseURL: imageBaseURL)
        self.canLoadImage = canLoadImage
    }

    /// #123 · @name links and images from the repository's own server
    init(_ text: String, target: RepoTarget?, revision: String? = nil, baseURL: URL? = nil) {
        let page = baseURL ?? target.flatMap { URL(string: $0.webURL + ($0.provider == .github ? "/pull/0" : "/-/merge_requests/0")) }
        self.init(text, refs: target?.markdownRefs, baseURL: page,
                  imageBaseURL: Markdown.repositoryImageBaseURL(webURL: page, revision: revision),
                  canLoadImage: { target?.canLoadImage($0) ?? false })
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
            MarkdownInlineContent(inlines: inlines, canLoadImage: canLoadImage)
        case .heading(let level, let inlines):
            VStack(alignment: .leading, spacing: 3) {
                MarkdownInlineContent(inlines: inlines, canLoadImage: canLoadImage)
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
            MarkdownTable(align: align, head: head, rows: rows, canLoadImage: canLoadImage)
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
    let canLoadImage: (URL) -> Bool

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
        return MarkdownInlineContent(inlines: inlines, canLoadImage: canLoadImage)
            .frame(minWidth: 60, maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: a == .center ? .center : a == .right ? .trailing : .leading)
            .border(Color.secondary.opacity(0.25), width: 0.5)
    }
}

/// Splits images from text without losing formatting or a linked image's click destination.
private struct MarkdownInlineContent: View {
    let inlines: [Markdown.Inline]
    let canLoadImage: (URL) -> Bool

    private enum Segment {
        case text([Markdown.Inline])
        case image(src: String, alt: String, link: String?)
    }

    var body: some View {
        let segments = Self.segments(inlines)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case .text(let nodes):
                    Text(MarkdownBlock.attributed(nodes)).fixedSize(horizontal: false, vertical: true)
                case .image(let src, let alt, let link):
                    MarkdownImage(src: src, alt: alt, link: link, canLoad: canLoadImage)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func segments(_ nodes: [Markdown.Inline]) -> [Segment] {
        var output: [Segment] = []
        var text: [Markdown.Inline] = []
        func flush() {
            if !Markdown.plain(text).trimmed.isEmpty { output.append(.text(text)) }
            text = []
        }
        func visit(_ nodes: [Markdown.Inline], decorate: ([Markdown.Inline]) -> [Markdown.Inline], link: String?) {
            for node in nodes {
                switch node {
                case .image(let src, let alt):
                    flush()
                    output.append(.image(src: src, alt: alt, link: link))
                case .strong(let children):
                    visit(children, decorate: { decorate([.strong($0)]) }, link: link)
                case .em(let children):
                    visit(children, decorate: { decorate([.em($0)]) }, link: link)
                case .strike(let children):
                    visit(children, decorate: { decorate([.strike($0)]) }, link: link)
                case .link(let href, let children):
                    visit(children, decorate: { decorate([.link(href: href, children: $0)]) }, link: href)
                default:
                    text += decorate([node])
                }
            }
        }
        visit(nodes, decorate: { $0 }, link: nil)
        flush()
        return output
    }
}

/// Images use an isolated session, with the same host policy applied after every redirect.
private final class MarkdownImageSession: NSObject, URLSessionTaskDelegate {
    let canLoad: (URL) -> Bool

    init(canLoad: @escaping (URL) -> Bool) { self.canLoad = canLoad }

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Markdown.resolvedURL(url.absoluteString, baseURL: nil, allowMail: false) != nil,
              canLoad(url), response.url?.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https" else {
            completionHandler(nil); return
        }
        var safe = request
        safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(safe)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

private struct MarkdownImage: View {
    let src: String
    let alt: String
    let link: String?
    let canLoad: (URL) -> Bool
    @ViewState private var image: NSImage?
    @ViewState private var loading = true

    var body: some View {
        Group {
            if let image {
                MarkdownImageLayout(size: image.size) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { open() }
                .focusable()
                .onKeyPress(.return) { open(); return .handled }
                .onKeyPress(.space) { open(); return .handled }
                .help(alt.isEmpty ? src : alt)
                .accessibilityLabel(alt.isEmpty ? Self.fileName(src) : alt)
                .accessibilityAddTraits(.isLink)
                .accessibilityAction { open() }
            } else {
                HStack(spacing: 6) {
                    if loading { ProgressView().controlSize(.small) }
                    Text(fallback)
                }
            }
        }
        .task(id: src) { await load() }
    }

    private var fallback: AttributedString {
        var text = AttributedString("🖼 " + (alt.isEmpty ? Self.fileName(src) : alt))
        text.link = URL(string: link ?? src)
        return text
    }

    private func open() {
        if let destination = URL(string: link ?? src) { NSWorkspace.shared.open(destination) }
    }

    private func load() async {
        image = nil; loading = true
        defer { loading = false }
        guard let url = Markdown.resolvedURL(src, baseURL: nil, allowMail: false), canLoad(url) else { return }
        let delegate = MarkdownImageSession(canLoad: canLoad)
        defer { delegate.session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await delegate.session.bytes(for: request)
            let limit = 15 * 1024 * 1024
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.expectedContentLength <= limit else { return }
            var data = Data()
            for try await byte in bytes {
                if Task.isCancelled || data.count >= limit { return }
                data.append(byte)
            }
            guard !Task.isCancelled, let rendered = NSImage(data: data),
                  rendered.size.width > 0, rendered.size.height > 0 else { return }
            image = rendered
        } catch { /* Images that need browser authentication retain their link. */ }
    }

    static func fileName(_ src: String) -> String {
        let path = src.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? src
        let last = path.split(separator: "/").last.map(String.init) ?? src
        return last.removingPercentEncoding ?? last
    }
}

private struct MarkdownImageLayout: Layout {
    let size: NSSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ratio = max(size.width, 1) / max(size.height, 1)
        let width = max(0, min(proposal.width ?? size.width, size.width, 360 * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
