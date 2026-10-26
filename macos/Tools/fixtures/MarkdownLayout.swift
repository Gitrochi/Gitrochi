import SwiftUI
import AppKit
import Vision

typealias ViewState<Value> = SwiftUI.State<Value>

/// Renders the production PR Markdown view with synthetic, offline text.
@main struct MarkdownLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = """
        ## What and why

        PR descriptions now display **bold text**, *emphasis*, ~~removed text~~ and `inline code`.
        Read the [documentation](https://example.invalid/docs).

        - Shared sections keep their natural height.
        - Long sections scroll inside their own panel.
          - Nested detail stays with its parent.

        ### Checklist

        - [x] Completed build
        - [ ] Pending review

        3. First ordered step
        4. Second ordered step

        > Quoted review feedback
        >
        > A second paragraph inside the same quote.

        ```swift
        let status = "BUILD PASSED"
        print(status)
        ```

        | Platform | Status |
        | --- | --- |
        | macOS | Ready |
        | Windows | Ready |

        ---

        END OF DESCRIPTION
        """
        var results: [[String: Any]] = []
        for width: CGFloat in [320, 800] {
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                let bounds = NSRect(x: 0, y: 0, width: width, height: 1400)
                let host = NSHostingView(rootView: MarkdownView(source)
                    .padding(16).frame(width: width, height: bounds.height, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0))
                window.contentView = host
                host.frame = bounds
                window.orderBack(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let rendered = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                let name = "markdown-\(Int(width))-\(theme).png"
                try rendered.write(to: output.appendingPathComponent(name))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: rendered).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                for expected in ["What and why", "Checklist", "Completed build", "Pending review", "BUILD PASSED", "Platform", "END OF DESCRIPTION"] {
                    precondition(text.contains(expected), "Markdown content missing: \(expected), \(name)\n\(text)")
                }
                precondition(!text.contains("##") && !text.contains("[x]"), "Raw block syntax remains: \(name)")
                results.append(["width": width, "theme": theme, "screenshot": name, "contentVisible": true])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: PR Markdown headings, tasks, code and table visible at 320/800 points in light/dark. \(output.path)")
    }
}
