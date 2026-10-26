import SwiftUI
import AppKit
import Vision

typealias ViewState<Value> = SwiftUI.State<Value>

/// Real network image rendering, using a local server that receives no user data.
@main struct MarkdownImagesFixture {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let endpoint = CommandLine.arguments[2]
        let source = """
        ## Settings previews

        | Light settings | Dark settings |
        | --- | --- |
        | ![Light settings](\(endpoint)/image.png?markdown) | [🖼 Dark settings](\(endpoint)/image.png?marker) |

        | HTML preview | Linked preview |
        | --- | --- |
        | <img width="320" alt="HTML preview" src="\(endpoint)/image.png?html"> | [![Linked preview](\(endpoint)/image.png?linked)](https://example.invalid/checks) |

        ### Uploaded comment image

        <p align="center"><img alt="Uploaded screenshot" src="\(endpoint)/image.png?comment"></p>

        END OF IMAGE PREVIEWS
        """
        var results: [[String: Any]] = []
        for width: CGFloat in [320, 800] {
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                let bounds = NSRect(x: 0, y: 0, width: width, height: 760)
                let host = NSHostingView(rootView: MarkdownView(source, canLoadImage: { $0.host == "127.0.0.1" })
                    .padding(16).frame(width: width, height: bounds.height, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor)).preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0)); window.contentView = host
                host.frame = bounds; window.orderBack(nil)
                var rendered: Data?
                var samples = 0
                var lastSamples = -1
                var stableFrames = 0
                let deadline = Date().addingTimeInterval(10)
                repeat {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
                    host.cacheDisplay(in: bounds, to: bitmap)
                    samples = 0
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            if color.redComponent > 0.75, color.greenComponent < 0.5, color.blueComponent < 0.45 { samples += 1 }
                        }
                    }
                    rendered = bitmap.representation(using: .png, properties: [:])
                    stableFrames = samples >= 2_000 && samples == lastSamples ? stableFrames + 1 : 0
                    lastSamples = samples
                } while stableFrames < 4 && Date() < deadline
                guard let rendered else { fatalError("No PNG") }
                let name = "markdown-images-\(Int(width))-\(theme).png"
                try rendered.write(to: output.appendingPathComponent(name))
                precondition(samples >= 2_000, "Actual images did not render in the table and comment: \(width), \(theme), \(samples)")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: rendered).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                precondition(text.contains("Settings previews") && text.contains("END OF IMAGE PREVIEWS"), "Images pushed text outside the panel: \(text)")
                precondition(!text.contains("<img") && !text.contains("<p"), "Raw image HTML remains: \(text)")
                results.append(["width": width, "theme": theme, "screenshot": name, "imageColorSamples": samples])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print("PASS: real Markdown/table/HTML/comment images visible at 320/800 points in light/dark. \(output.path)")
    }
}
