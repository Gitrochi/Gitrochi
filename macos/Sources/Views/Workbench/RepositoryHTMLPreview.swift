import SwiftUI
import WebKit

struct RepositoryHTMLPreview: View {
    let text: String
    let entry: RepositoryTreeEntry
    let tree: RepositoryTreeSnapshot
    let repository: URL
    @ViewState private var document: RepositoryHTMLDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Scripts and external resources are disabled in preview.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).padding(12)
            if let document {
                if document.missingResources { Text("Some local resources could not be loaded.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8) }
                RepositoryHTMLCanvas(document: document).id(document.id).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: tree.revision + ":" + entry.path) {
            document = nil
            let source = text, path = entry.path, snapshot = tree, root = repository
            let value = await Task.detached(priority: .userInitiated) { await RepositoryHTMLDocument.load(text: source, path: path, tree: snapshot, repository: root) }.value
            guard !Task.isCancelled else { return }
            document = value
        }
    }
}

/// A fresh isolated WebView has no script bridge, persistent storage or file URL access.
struct RepositoryHTMLCanvas: NSViewRepresentable {
    let document: RepositoryHTMLDocument
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(RepositoryHTMLSchemeHandler(resources: document.resources), forURLScheme: RepositoryHTMLDocument.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setAccessibilityLabel(String(localized: "Preview"))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard !context.coordinator.loaded else { return }
        context.coordinator.loaded = true
        view.loadHTMLString(document.html, baseURL: URL(string: "about:blank"))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded = false
        private var initialNavigation = true
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = initialNavigation && navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url?.absoluteString == "about:blank"
            if allowed { initialNavigation = false }
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}

private final class RepositoryHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resources: [String: RepositoryHTMLDocument.Resource]
    init(resources: [String: RepositoryHTMLDocument.Resource]) { self.resources = resources }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let resource = resources[url.absoluteString], urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET" else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: resource.mime, expectedContentLength: resource.data.count, textEncodingName: resource.mime == "text/css" ? "utf-8" : nil))
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
