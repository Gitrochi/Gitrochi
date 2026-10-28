import AppKit
import SwiftUI
import WebKit

/// Keeps the existing offline renderer beside the repository without loading external pages.
@MainActor final class StructureGraphWindow: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: StructureGraphWindow] = [:]
    private let token = UUID()
    private var repositoryKey = ""

    static func open(file: URL, browserURL: URL? = nil, store: RepoStore, actionsJSON: String? = nil) async throws {
        guard let repository = store.url else { return }
        let head = store.headHash
        let html = try await Task.detached(priority: .userInitiated) {
            try StructureGraphDocument.prepare(String(contentsOf: file, encoding: .utf8), actionsJSON: actionsJSON)
        }.value
        guard store.url == repository else { return }
        let content = StructureGraphContent(store: store, repository: repository, head: head, html: html, browserURL: browserURL ?? file)
        if let existing = windows.values.first(where: { $0.repositoryKey == repository.path }), let window = existing.window {
            window.contentView = NSHostingView(rootView: content)
            existing.showWindow(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Structure graph workspace")
        window.minSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        let controller = StructureGraphWindow(window: window)
        controller.repositoryKey = repository.path
        window.delegate = controller
        windows[controller.token] = controller
        window.center()
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.windows.removeValue(forKey: token) }
}

private struct StructureGraphContent: View {
    let store: RepoStore
    let repository: URL
    let head: String?
    let html: String
    let browserURL: URL
    var stale: Bool { store.url != repository || store.headHash != head }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This workspace shows an offline analysis snapshot. Refresh after editing files.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh graph") { Task { await store.openStructureGraph(.files) } }.disabled(store.url != repository || store.graphJob != nil)
                Button("Open in browser") { Task { try? await Launcher.openInBrowser(browserURL) } }
            }.padding([.horizontal, .top], 12)
            if stale {
                Text("The repository or HEAD changed. Refresh the analysis before using this snapshot.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).accessibilityAddTraits(.updatesFrequently)
            }
            StructureGraphWebView(html: html, repository: repository, stale: stale)
        }
    }
}

private struct StructureGraphWebView: NSViewRepresentable {
    let html: String
    let repository: URL
    let stale: Bool
    func makeCoordinator() -> Coordinator { Coordinator(repository: repository, stale: stale) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.stale = stale }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let repository: URL
        var stale: Bool
        init(repository: URL, stale: Bool) { self.repository = repository; self.stale = stale }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
            if !stale, StructureGraphDocument.appLink(url, repository: repository) { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}
