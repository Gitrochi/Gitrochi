import AppKit
import WebKit

/// A browser tab in a terminal pane. Like a terminal, the page lives in the session, so switching tabs keeps it as it
/// was. Pages run JavaScript and keep cookies in the app's own store, but get no bridge into the app.
/// (Windows: entities/terminal/model/browser.ts)
@MainActor @Observable
final class BrowserSession: Identifiable {
    let id = UUID()
    let view: WKWebView
    private(set) var title: String
    private(set) var url: URL?
    /// The local file the tab previews, if any; the address bar shows its path
    private(set) var file: URL?
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let relay = BrowserRelay()
    /// The file whose preview page this tab built (reload builds it again from disk)
    @ObservationIgnored private var builtFile: URL?

    init(url: URL?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 260), configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.setAccessibilityLabel(String(localized: "Browser"))
        title = String(localized: "New tab")
        self.url = url
        view.uiDelegate = relay
        view.navigationDelegate = relay
        observations = [
            view.observe(\.title) { [weak self] v, _ in let t = v.title; MainActor.assumeIsolated { self?.update(title: t) } },
            view.observe(\.url) { [weak self] v, _ in let u = v.url; MainActor.assumeIsolated { self?.update(url: u) } },
            view.observe(\.isLoading) { [weak self] v, _ in let l = v.isLoading; MainActor.assumeIsolated { self?.loading = l } },
            view.observe(\.canGoBack) { [weak self] v, _ in let b = v.canGoBack; MainActor.assumeIsolated { self?.canGoBack = b } },
            view.observe(\.canGoForward) { [weak self] v, _ in let f = v.canGoForward; MainActor.assumeIsolated { self?.canGoForward = f } },
        ]
        if let url { view.load(URLRequest(url: url)) }
    }

    /// Goes to what was typed in the address bar: an address, or a search
    func open(_ text: String) {
        let path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { openFile(URL(fileURLWithPath: path)); return }
        guard let target = BrowserAddress.resolve(text) else { return }
        view.load(URLRequest(url: target))
        view.window?.makeFirstResponder(view)
    }

    /// Previews a local file: WebKit shows media, PDF and HTML itself, text formats get a page of their own
    func openFile(_ path: URL) {
        file = path
        title = path.lastPathComponent
        guard FilePreview.kind(for: path.path) != .native else {
            builtFile = nil
            view.loadFileURL(path, allowingReadAccessTo: path.deletingLastPathComponent())
            return
        }
        builtFile = path
        let name = path.lastPathComponent, kind = FilePreview.kind(for: path.path)
        Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) { () -> String in
                guard let handle = try? FileHandle(forReadingFrom: path) else { return FilePreview.document(title: name, body: "") }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: FilePreview.textLimit + 1)) ?? Data()
                return FilePreview.page(name: name, data: data, kind: kind)
                    ?? FilePreview.document(title: name, body: "<p class=\"note\">" + FilePreview.escape(String(localized: "This file can't be shown as text.")) + "</p>")
            }.value
            guard let self, self.builtFile == path else { return }
            self.view.loadHTMLString(page, baseURL: nil)
        }
    }

    /// What the address bar shows
    var address: String { file?.path ?? url?.absoluteString ?? "" }

    func back() { view.goBack() }
    func forward() { view.goForward() }
    func reload() {
        if loading { view.stopLoading() } else if let builtFile { openFile(builtFile) } else { view.reload() }
    }

    /// A web page opens in the system browser; a previewed file is shown in Finder
    func openExternally() {
        if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) } else if let url { NSWorkspace.shared.open(url) }
    }

    func close() {
        observations = []
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    private func update(title value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmed.isEmpty ? (file?.lastPathComponent ?? url?.host() ?? String(localized: "New tab")) : trimmed
    }

    private func update(url value: URL?) {
        // leaving a preview for a web page (a link, back, the address bar) forgets the file
        if let scheme = value?.scheme, scheme == "http" || scheme == "https" { file = nil; builtFile = nil }
        if value?.isFileURL == true { file = value }
        url = value
        if view.title?.isEmpty != false { update(title: nil) }
    }
}

/// Links that ask for a new window open in the same tab rather than nowhere; a local file (a previewed HTML page)
/// runs no script, as the built preview pages run none (Windows: the CSP in preview.rs)
private final class BrowserRelay: NSObject, WKUIDelegate, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let url = navigationAction.request.url
        preferences.allowsContentJavaScript = !(url?.isFileURL == true || url?.absoluteString == "about:blank")
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// What the address bar does with typed text (Windows: entities/terminal/lib/browser-address.ts)
enum BrowserAddress {
    static let searchURL = "https://duckduckgo.com/?q="

    static func resolve(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about"].contains(scheme), scheme == "about" || url.host() != nil {
            return url
        }
        if !value.contains(" "), looksLikeHost(value), let url = URL(string: (isLocal(value) ? "http://" : "https://") + value) {
            return url
        }
        let query = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? value
        return URL(string: searchURL + query)
    }

    /// localhost, an IP address, or a name with a dot, each with an optional port and path
    static func looksLikeHost(_ value: String) -> Bool {
        let host = hostPart(value)
        if isLocal(value) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count > 1 && labels.allSatisfy { !$0.isEmpty } && labels.last.map { $0.allSatisfy(\.isLetter) || $0.allSatisfy(\.isNumber) } == true
    }

    /// Dev servers: plain http
    static func isLocal(_ value: String) -> Bool {
        let host = hostPart(value).lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || host.hasPrefix("127.") || host == "[::1]"
            || (host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false })
    }

    private static func hostPart(_ value: String) -> String {
        let end = value.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? value.endIndex
        let authority = value[..<end]
        if authority.hasPrefix("[") { return String(authority.prefix { $0 != "]" }) + "]" }
        return String(authority.split(separator: ":", maxSplits: 1).first ?? "")
    }

    /// Links clicked in a terminal that open in a browser tab rather than the system browser
    static func opensInPanel(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host() else { return false }
        return isLocal(host.contains(":") ? "[\(host)]" : host)
    }
}
