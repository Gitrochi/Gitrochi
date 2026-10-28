import AppKit
import SwiftUI
import Observation
import Vision

typealias ViewState<Value> = SwiftUI.State<Value>

private let fixtureSource = """
import SwiftUI

/// Keeps the repository browser comfortable at every window size.
struct RepositoryPreview: View {
    let files: [String]
    @State private var selected = "Preview.swift"
    @State private var query = ""

    private var matching: [String] {
        files.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(matching, id: \\.self, selection: $selected) { file in
                Label(file, systemImage: "doc.text")
            }
            .searchable(text: $query)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text(selected).font(.headline)
                Text("A clear place to read and explore your code.")
                    .foregroundStyle(.secondary)
                ForEach(0..<3) { index in
                    Text("Section \\(index + 1)")
                }
            }
            .padding(24)
        }
    }
}
""" + "\n"

private let fixtureOID = String(repeating: "a", count: 40)
struct FixtureRef: Identifiable {
    let name: String
    var id: String { name }
}
@MainActor @Observable final class RepoStore {
    var url: URL? = URL(fileURLWithPath: "/fixture/repository")
    let localBranches = [FixtureRef(name: "main"), FixtureRef(name: "feature/code-reader")]
    let remoteBranches = [FixtureRef(name: "origin/main")]
    let tags = [FixtureRef(name: "v1.0")]
    func describe(_ error: Error) -> String { error.localizedDescription }
}
struct GitResult {
    let data: Data
    var output: String { String(decoding: data, as: UTF8.self) }
}
enum Git {
    static func run(_ args: [String], in directory: URL) async throws -> GitResult {
        precondition(directory.path == "/fixture/repository", "Only synthetic repository reads are allowed")
        let text: String
        switch args.first {
        case "rev-parse": text = fixtureOID
        case "ls-tree":
            text = ["src/Preview.swift", "src/Theme.swift", "src/Views/Toolbar.swift", "docs/reading.md"].map {
                "100644 blob \(fixtureOID) \(fixtureSource.utf8.count)\t\($0)\0"
            }.joined()
        case "cat-file" where args.contains("-s"): text = String(fixtureSource.utf8.count)
        case "cat-file": text = fixtureSource
        case "log": text = "a1b2c3d 2026-01-01 Demo Developer\nImprove source readability\n"
        case "blame": text = "a1b2c3d (Demo Developer 2026-01-01 1) import SwiftUI\n"
        case "diff": text = ""
        default: fatalError("Unexpected repository operation: \(args)")
        }
        return GitResult(data: Data(text.utf8))
    }
}

@MainActor @Observable private final class NativeReaderState {
    let text = (1...160).map { "let row\($0) = \"A comfortably readable source line with enough words to wrap in a narrow reader\"" }.joined(separator: "\n") + "\n"
    var wraps = false
    var fontSize: CGFloat = 13
    var activeMatch: NSRange?
}
private struct NativeReaderFixture: View {
    let state: NativeReaderState
    var body: some View {
        RepositorySourceView(text: state.text, tokens: RepositoryCodeReading.tokens(in: state.text, path: "fixture.swift"),
                             lineStarts: RepositoryCodeReading.lineStarts(in: state.text), fontSize: state.fontSize,
                             wraps: state.wraps, activeMatch: state.activeMatch)
    }
}

@main struct RepositoryCodeLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try checkNativeReader()
        var results: [[String: Any]] = []
        for width: CGFloat in [440, 1100] {
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                let bounds = NSRect(x: 0, y: 0, width: width, height: 780)
                let store = RepoStore()
                let host = NSHostingView(rootView: RepositoryCodePanel().environment(store)
                    .frame(width: width, height: bounds.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0))
                window.contentView = host
                host.frame = bounds
                window.orderBack(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let textViews = descendants(of: host).compactMap { $0 as? NSTextView }
                guard let reader = textViews.first(where: { $0.string.contains("struct RepositoryPreview") }) else {
                    fatalError("The production code panel did not show its automatic source preview")
                }
                precondition(!reader.isEditable && reader.isSelectable, "Source must remain read-only and selectable")
                precondition(reader.string == fixtureSource, "Source text changed in the reader")
                checkGutter(reader)
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let rendered = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                let name = "code-reader-\(Int(width))-\(theme).png"
                try rendered.write(to: output.appendingPathComponent(name))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: rendered).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                for expected in ["Preview.swift", "Source", "File history", "Blame", "import SwiftUI"] {
                    precondition(text.contains(expected), "Visible code content missing: \(expected), \(name)\n\(text)")
                }
                results.append(["width": width, "theme": theme, "screenshot": name, "sourceSelectable": true, "readOnly": true])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: Production Code panel light/dark and narrow/wide layouts; native syntax colors, wrap resizing, font sizing and match scrolling. \(output.path)")
    }

    @MainActor private static func checkNativeReader() throws {
        let state = NativeReaderState()
        let host = NSHostingView(rootView: NativeReaderFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 420, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        guard let scroll = descendants(of: host).compactMap({ $0 as? NSScrollView }).first,
              let reader = scroll.documentView as? NSTextView else { fatalError("Native source reader missing") }
        precondition(!reader.isEditable && reader.isSelectable && !reader.isAutomaticLinkDetectionEnabled && !reader.importsGraphics)
        precondition(reader.string == state.text && scroll.rulersVisible && scroll.verticalRulerView != nil)
        checkGutter(reader)
        precondition(scroll.hasHorizontalScroller, "Unwrapped source must be horizontally scrollable")
        let keywordColor = reader.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let plainColor = reader.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        precondition(keywordColor != nil && keywordColor != plainColor, "Swift keyword syntax color was not applied")
        state.wraps = true
        settle()
        precondition(!scroll.hasHorizontalScroller && reader.textContainer?.widthTracksTextView == true, "Wrap must follow the available reader width")
        precondition(reader.frame.width <= scroll.contentSize.width + 1, "Wrapped source extends outside the reader")
        window.setContentSize(NSSize(width: 320, height: 340))
        settle()
        precondition(reader.frame.width <= scroll.contentSize.width + 1, "Resizing the wrapped reader created horizontal overflow")
        state.fontSize = 17
        settle()
        let font = reader.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        precondition(font?.pointSize == 17, "Font size control did not update native source text")
        let matches = RepositoryCodeReading.matches(in: state.text, query: "row160")
        precondition(matches.count == 1)
        state.activeMatch = matches.first
        settle()
        precondition(scroll.contentView.bounds.origin.y > 0, "Finding a later source match must scroll into view")
        let highlight = reader.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: matches[0].location, effectiveRange: nil)
        precondition(highlight != nil, "Active source match was not highlighted")
        window.orderOut(nil)
    }

    @MainActor private static func checkGutter(_ reader: NSTextView) {
        guard let scroll = reader.enclosingScrollView, let ruler = scroll.verticalRulerView,
              let layout = reader.layoutManager, let container = reader.textContainer, !reader.string.isEmpty else {
            fatalError("Reader gutter is unavailable")
        }
        let glyph = layout.glyphIndexForCharacter(at: 0)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let first = reader.convert(NSPoint(x: bounds.minX + reader.textContainerOrigin.x, y: bounds.minY + reader.textContainerOrigin.y), to: scroll)
        let gutter = scroll.convert(ruler.bounds, from: ruler)
        precondition(first.x >= gutter.maxX - 1, "Line gutter overlaps source characters")
        precondition(first.x <= gutter.maxX + 30, "Automatic scroll insets duplicated the source gutter")
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
