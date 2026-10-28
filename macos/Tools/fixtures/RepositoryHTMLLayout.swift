import AppKit
import SwiftUI
import WebKit
import Vision

enum RepositoryHTMLFixtureData {
    static let repository = URL(fileURLWithPath: "/fixture/repository")
    static let source = """
    <!doctype html><html><head>
    <meta http-equiv="refresh" content="0;url=https://example.invalid/refresh">
    <link rel="stylesheet" href="styles/theme.css">
    <style>.inline-style { border-left: 8px solid rgb(0,128,96); padding: 14px; }</style>
    </head><body>
    <h1 id="heading">Repository HTML preview</h1>
    <p class="committed" id="committed">Committed CSS is visible.</p>
    <section class="inline-style" id="inline">Inline styles remain visible.</section>
    <img id="raster" src="images/tile.png" width="160" height="80" alt="Committed raster image">
    <p id="script-status">Scripts remain disabled.</p>
    <a id="outbound" href="https://example.invalid/navigation">External navigation stays blocked.</a>
    <a id="new-window" target="_blank" href="https://example.invalid/window">New windows stay blocked.</a>
    <iframe src="https://example.invalid/frame"></iframe>
    <form action="https://example.invalid/form"><button>Offline preview</button></form>
    <script>window.fixtureScriptRan = true; document.getElementById('script-status').textContent = 'UNSAFE';</script>
    </body></html>
    """

    static let objects: [String: Data] = [
        String(repeating: "b", count: 40): Data("@import \"layout.css\"; body { background: rgb(246,248,252); color: rgb(28,42,60); padding: 24px; font-family: -apple-system; } .committed { color: rgb(32,96,160); } iframe { display:none; } form { margin-top:16px; }".utf8),
        String(repeating: "c", count: 40): raster,
        String(repeating: "d", count: 40): Data(source.utf8),
        String(repeating: "e", count: 40): Data("h1 { font-size: 28px; margin:0 0 12px; } p { line-height:1.5; } img { margin-top:18px; border-radius:10px; } a { display:block; margin-top:12px; color:rgb(32,96,160); }".utf8)
    ]

    static let entries: [RepositoryTreeEntry] = [
        entry("web/styles/theme.css", "b"), entry("web/images/tile.png", "c"),
        entry("web/index.html", "d"), entry("web/styles/layout.css", "e")
    ]

    private static func entry(_ path: String, _ digit: Character) -> RepositoryTreeEntry {
        let oid = String(repeating: String(digit), count: 40)
        return RepositoryTreeEntry(path: path, mode: "100644", oid: oid, size: objects[oid]!.count)
    }

    private static let raster: Data = {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 320, bitsPerPixel: 32)!
        let pixels = bitmap.bitmapData!
        for y in 0..<40 {
            for x in 0..<80 {
                let offset = y * 320 + x * 4
                pixels[offset] = x < 40 ? 42 : 240
                pixels[offset + 1] = x < 40 ? 112 : 160
                pixels[offset + 2] = x < 40 ? 180 : 68
                pixels[offset + 3] = 255
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }()
}

/// Exercises the production isolated WebView; native evaluation only inspects fixture DOM.
enum RepositoryHTMLLayoutFixture {
    @MainActor static func run(output: URL) throws {
        let tree = RepositoryTreeSnapshot(revision: String(repeating: "f", count: 40), entries: RepositoryHTMLFixtureData.entries, truncated: false)
        var document: RepositoryHTMLDocument?
        Task {
            document = await RepositoryHTMLDocument.load(text: RepositoryHTMLFixtureData.source, path: "web/index.html", tree: tree, repository: RepositoryHTMLFixtureData.repository)
        }
        settle(until: { document != nil }, message: "The HTML document did not assemble")
        let value = document!
        precondition(!value.missingResources && value.resources.count == 3, "Committed CSS/import/raster resources did not load")
        precondition(value.resources.values.contains { $0.mime == "image/png" })
        precondition(value.resources.values.filter { $0.mime == "text/css" }.count == 2)
        for width: CGFloat in [400, 800] {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 560)
            let host = NSHostingView(rootView: RepositoryHTMLCanvas(document: value).frame(width: width, height: bounds.height))
            let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -4000, y: 0))
            window.contentView = host
            window.orderBack(nil)
            var web: WKWebView?
            settle(until: {
                web = descendants(host).compactMap { $0 as? WKWebView }.first
                return web?.url?.absoluteString == "about:blank" && web?.isLoading == false
            }, message: "The native HTML preview did not load")
            let browser = web!
            precondition(!browser.configuration.websiteDataStore.isPersistent, "HTML preview must not use persistent website storage")
            precondition(!browser.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            precondition(!browser.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            precondition(browser.configuration.userContentController.userScripts.isEmpty, "HTML preview unexpectedly installed a script bridge")
            let details = try evaluate(browser, script: "JSON.stringify({title:document.querySelector('h1').textContent, color:getComputedStyle(document.querySelector('#committed')).color, border:getComputedStyle(document.querySelector('#inline')).borderLeftWidth, font:getComputedStyle(document.querySelector('h1')).fontSize, width:document.querySelector('#raster').naturalWidth, script:window.fixtureScriptRan===true, status:document.querySelector('#script-status').textContent})") as? String
            guard let data = details?.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { fatalError("No native HTML inspection result") }
            precondition(result["title"] as? String == "Repository HTML preview")
            precondition(result["color"] as? String == "rgb(32, 96, 160)", "Committed stylesheet was not rendered")
            precondition(result["border"] as? String == "8px", "Inline stylesheet was not rendered")
            precondition(result["font"] as? String == "28px", "Committed CSS import was not rendered")
            precondition(result["width"] as? Int == 80, "Committed raster image was not rendered")
            precondition(result["script"] as? Bool == false && result["status"] as? String == "Scripts remain disabled.", "Page scripts executed in preview")
            _ = try evaluate(browser, script: "document.querySelector('#outbound').click(); document.querySelector('#new-window').click(); undefined")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            precondition(browser.url?.absoluteString == "about:blank", "An HTML anchor escaped the preview")
            browser.load(URLRequest(url: URL(string: "https://example.invalid/native-navigation")!))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            precondition(browser.url?.absoluteString == "about:blank", "The native navigation delegate allowed an external navigation")
            var image: NSImage?, snapshotError: Error?, finished = false
            browser.takeSnapshot(with: nil) { value, error in image = value; snapshotError = error; finished = true }
            settle(until: { finished }, message: "The HTML preview snapshot timed out")
            if let snapshotError { throw snapshotError }
            guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("The HTML preview snapshot is unavailable") }
            try png.write(to: output.appendingPathComponent("html-preview-\(Int(width)).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            precondition(text.contains("Repository HTML preview") && text.contains("Scripts remain disabled"), "HTML snapshot did not contain visible fixture text")
            window.orderOut(nil)
        }
        print("PASS: Native HTML renders committed CSS, CSS imports and raster assets; scripts, refresh, anchors and later navigations stay isolated")
    }

    @MainActor private static func evaluate(_ web: WKWebView, script: String) throws -> Any? {
        var value: Any?, failure: Error?, finished = false
        web.evaluateJavaScript(script) { result, error in value = result; failure = error; finished = true }
        settle(until: { finished }, message: "Native HTML inspection timed out")
        if let failure { throw failure }
        return value
    }

    @MainActor private static func settle(until condition: () -> Bool, message: String) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), message)
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
