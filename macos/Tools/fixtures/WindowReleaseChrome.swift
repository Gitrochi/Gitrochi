import AppKit
import SwiftUI

/// Exercises the production root through SwiftUI's own window creation, without AppDelegate or Workspace restoration.
struct ReleaseChromeFixtureApp: App {
    @NSApplicationDelegateAdaptor(ReleaseChromeFixtureDelegate.self) private var delegate

    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
        windowFixtureDefaults.set(false, forKey: "avatarFetch")
        windowFixtureDefaults.set("local", forKey: "planningHome.projectSource")
    }

    var body: some Scene {
        WindowGroup("Gitrochi release chrome fixture", id: "release-chrome", for: Int.self) { $index in
            ReleaseChromeFixtureRoot(index: index ?? 0)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .commands { ReleaseChromeFixtureCommands() }
    }
}

private final class ReleaseChromeFixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ReleaseChromeFixtureSession.shared.requestInitialWindow()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ReleaseChromeFixtureCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = ReleaseChromeFixtureSession.shared.installInitialOpener {
            openWindow(id: "release-chrome", value: 0)
        }
        CommandGroup(replacing: .newItem) {
            Button("Open synthetic repository") { ReleaseChromeFixtureSession.shared.requestInitialWindow() }
        }
    }
}

private struct ReleaseChromeFixtureRoot: View {
    let index: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let session = ReleaseChromeFixtureSession.shared
        RepoContainer()
            .environment(session.stores[index])
            .defaultAppStorage(windowFixtureDefaults)
            .background(ReleaseChromeFixtureAttachment(index: index))
            .task { session.start { openWindow(id: "release-chrome", value: $0) } }
    }
}

private struct ReleaseChromeFixtureAttachment: NSViewRepresentable {
    let index: Int

    final class AttachmentView: NSView {
        let index: Int
        init(index: Int) { self.index = index; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ReleaseChromeFixtureSession.shared.attach(window, index: index) }
        }
    }

    func makeNSView(context: Context) -> AttachmentView { AttachmentView(index: index) }
    func updateNSView(_ view: AttachmentView, context: Context) {}
}

@MainActor private final class ReleaseChromeFixtureSession {
    static let shared = ReleaseChromeFixtureSession()
    let stores: [RepoStore]
    private var windows: [Int: NSWindow] = [:]
    private var started = false
    private var initialOpener: (() -> Void)?
    private var initialWindowRequested = false
    private var initialWindowPending = false
    private var checks: [[String: Any]] = []
    private let output: URL?

    private init() {
        output = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let account = HostAccount(id: "release-chrome-github", provider: .github, server: "https://github.com",
                                  username: "fixture-user", name: "Fixture account", avatarURL: nil)
        AccountStore.shared.windowFixtureSetAccounts([account])
        stores = (0..<4).map { index in
            let store = RepoStore()
            store.windowFixtureSetURL(windowFixtureLocalStorageURL.deletingLastPathComponent()
                .appendingPathComponent("synthetic-repository-\(index)", isDirectory: true))
            store.target = RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.example.invalid", path: "fixture/repository-\(index)")
            store.booted = true
            store.hostingHub.selectedAccountID = account.id
            store.navigate(.repository, prepare: false)
            return store
        }
    }

    func installInitialOpener(_ open: @escaping () -> Void) {
        initialOpener = open
        if initialWindowPending { DispatchQueue.main.async { self.requestInitialWindow() } }
    }

    func requestInitialWindow() {
        guard windows.isEmpty, !initialWindowRequested else { return }
        guard let initialOpener else { initialWindowPending = true; return }
        initialWindowPending = false
        initialWindowRequested = true
        initialOpener()
    }

    func attach(_ window: NSWindow, index: Int) {
        guard windows[index] !== window else { return }
        windows[index] = window
        stores[index].window = window
        window.title = "Synthetic repository \(index + 1)"
        window.tabbingIdentifier = "GitrochiReleaseChromeFixture"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        // Someone working at the Mac must not drag the windows or scroll the measured lists.
        window.ignoresMouseEvents = true
        RepositoryWindowLayout.configure(window)
        if let first = windows[0], first !== window {
            window.alphaValue = 0
            DispatchQueue.main.async {
                if first.tabbedWindows?.contains(window) != true { first.addTabbedWindow(window, ordered: .above) }
                window.alphaValue = 1
            }
        }
    }

    func start(open: @escaping (Int) -> Void) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            do {
                for index in 1..<4 {
                    open(index)
                    try await Task.sleep(for: .milliseconds(120))
                }
                try await wait("four SwiftUI repository windows") { self.windows.count == 4 }
                try await run()
                try finish(ok: true)
            } catch {
                try? finish(ok: false, error: String(describing: error))
                fputs("Release chrome fixture failed: \(error)\n", stderr)
                cleanup()
                exit(1)
            }
            cleanup()
            NSApp.terminate(nil)
        }
    }

    private func run() async throws {
        // The first credential read, which also starts when the app becomes active, bumps AccountStore.revision:
        // every hub then reloads and drops the seeded releases. Settle it before the checks.
        for account in AccountStore.shared.accounts { _ = await AccountStore.shared.loadToken(for: account) }
        guard let first = windows[0], let selected = windows[1], let other = windows[3] else { throw Failure("Missing fixture windows") }
        for index in 1..<4 {
            guard let window = windows[index] else { throw Failure("Missing tab \(index)") }
            if first.tabbedWindows?.contains(window) != true { first.addTabbedWindow(window, ordered: .above) }
        }
        first.tabGroup?.selectedWindow = selected
        selected.makeKeyAndOrderFront(nil)
        if selected.tabGroup?.isTabBarVisible == false { selected.toggleTabBar(nil) }
        try await wait("four native repository tabs") { selected.tabGroup?.windows.count == 4 && selected.tabGroup?.selectedWindow === selected }
        await settle(0.7)
        let original = selected.frame
        try require(selected.toolbar != nil, "WindowGroup must install the real RepoView toolbar")

        for (scheme, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: scheme)
            NSApp.appearance = appearance
            for window in windows.values { window.appearance = appearance }
            stores[1].navigate(.repository, prepare: false)
            await settle(0.3)
            stores[1].navigate(.releases, prepare: false)
            await settle(0.7)
            try require(stores[1].cameFromRepository, "Release navigation must retain the repository back link")
            seedReleases()
            await settle(0.3)
            try await capture("swiftui-releases-\(name)-wide", window: selected, expectedFrame: original)

            selected.tabGroup?.selectedWindow = other
            await settle(0.25)
            selected.tabGroup?.selectedWindow = selected
            selected.makeKeyAndOrderFront(nil)
            await settle(0.4)
            try require(equal(selected.frame, original), "Selecting a restored tab changed its outer frame")

            var minimum = original
            minimum.size = selected.minSize
            minimum.origin.y = original.maxY - minimum.height
            selected.setFrame(minimum, display: true)
            await settle(0.6)
            try await capture("swiftui-releases-\(name)-minimum", window: selected, expectedFrame: minimum)

            selected.setFrame(original, display: true)
            await settle(0.6)
            try await capture("swiftui-releases-\(name)-restored", window: selected, expectedFrame: original)
        }
    }

    private func seedReleases() {
        let items = (0..<30).map { index in
            HubItem(id: "release-chrome-\(index)", title: "Synthetic release \(index + 1)",
                    subtitle: "v0.0.\(index + 1) · Fixture only", body: "A synthetic release used to measure the real scrolling list.")
        }
        stores[1].hostingHub.items = items
        stores[1].hostingHub.more = true
        var selected = items[0]
        selected.body = (1...90).map { "Release note \($0): Synthetic content verifies that the complete release can be read in the detail pane." }.joined(separator: "\n\n")
        stores[1].hostingHub.detail = HubDetail(item: selected)
    }

    private func capture(_ scenario: String, window: NSWindow, expectedFrame: NSRect) async throws {
        await settle(0.15)
        guard let content = window.contentView else { throw Failure("Missing native content view") }
        let safe = window.contentLayoutRect
        let measured = probes(in: content)
        let required = ["workspace-header", "page-title:releases", "hub-title:releases", "rail-control"]
        var frames: [String: Any] = [:]
        var failures: [String] = []
        for identifier in required {
            guard let probe = measured.first(where: { $0.identifierForFixture == identifier }) else {
                failures.append("Missing actual \(identifier)")
                continue
            }
            let frame = probe.convert(probe.bounds, to: nil)
            let visible = probe.convert(probe.visibleRect, to: nil)
            frames[identifier] = ["frame": rect(frame), "visibleFrame": rect(visible)]
            if frame.width < 1 || frame.height < 1 || !contains(safe, frame) || !contains(visible, frame) {
                failures.append("\(identifier) is clipped: \(frame), visible \(visible), safe \(safe)")
            }
            if identifier == "workspace-header", !frame.height.isFinite || frame.height > safe.height + 1 {
                failures.append("The workspace must have a finite height within the native viewport")
            }
            if identifier == "rail-control" {
                let center = content.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)
                if frame.width < 36 || frame.height < 30 || content.hitTest(center) == nil {
                    failures.append("The rail expand button has no visible hit target")
                }
            }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.window === window,
                   !button.isHiddenOrHasHiddenAncestor, button.convert(button.bounds, to: nil).intersects(frame) {
                    failures.append("\(identifier) overlaps a native window control")
                }
            }
        }
        if !equal(window.frame, expectedFrame) { failures.append("Outer window frame drift: expected \(expectedFrame), actual \(window.frame)") }
        if window.styleMask.contains(.fullSizeContentView) { failures.append("Full-size content returned") }
        if window.tabGroup?.windows.count != 4 || window.tabGroup?.selectedWindow !== window {
            failures.append("The second of four native tabs must remain selected")
        }
        var check: [String: Any] = ["scenario": scenario, "windowFrame": rect(window.frame), "expectedFrame": rect(expectedFrame),
                                    "contentLayoutRect": rect(safe), "contentFrames": frames,
                                    "nativeTabCount": window.tabGroup?.windows.count ?? 0, "failures": failures]
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let view = content.superview ?? content
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("Cannot capture native window") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Cannot encode native screenshot") }
            let name = scenario + ".png"
            try data.write(to: output.appendingPathComponent(name))
            check["screenshot"] = name
        }
        checks.append(check)
        try require(failures.isEmpty, "\(scenario): \(failures.joined(separator: "; "))")
        try await captureBottom(scenario, window: window)
    }

    private func captureBottom(_ scenario: String, window: NSWindow) async throws {
        guard let content = window.contentView else { throw Failure("Missing native content view") }
        let initial = probes(in: content)
        guard let listProbe = initial.first(where: { $0.identifierForFixture.hasPrefix("hub-item:") }),
              let list = listProbe.enclosingScrollView,
              let detailProbe = initial.first(where: { $0.identifierForFixture == "hub-detail-end" }),
              let detail = detailProbe.enclosingScrollView, list !== detail else {
            throw Failure("The release list and details must use separate actual native scroll views")
        }
        let originalList = list.contentView.bounds.origin, originalDetail = detail.contentView.bounds.origin
        defer {
            list.contentView.scroll(to: originalList); list.reflectScrolledClipView(list.contentView)
            detail.contentView.scroll(to: originalDetail); detail.reflectScrolledClipView(detail.contentView)
        }
        for _ in 0..<8 {
            scrollToBottom(list)
            scrollToBottom(detail)
            await settle(0.1)
        }
        let safe = window.contentLayoutRect
        var failures: [String] = [], frames: [String: Any] = [:]
        // Probes of a reloaded list linger outside the viewport and would read as unreachable.
        if stores[1].hostingHub.items.isEmpty { failures.append("The hub reloaded and dropped the seeded releases") }
        let measured = probes(in: content)
        for (identifier, scroll) in [("hub-item:release-chrome-29", list), ("hub-pagination", list), ("hub-detail-end", detail)] {
            guard let probe = measured.first(where: { $0.identifierForFixture == identifier }) else {
                failures.append("Missing actual bottom control \(identifier)")
                continue
            }
            let frame = probe.convert(probe.bounds, to: nil)
            let clip = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            frames[identifier] = ["frame": rect(frame), "scrollViewport": rect(clip)]
            if frame.width < 1 || frame.height < 0.5 || !contains(clip, frame) || !contains(safe, frame) {
                failures.append("\(identifier) is unreachable at the bottom: \(frame), clip \(clip), safe \(safe)")
            }
        }
        var check: [String: Any] = ["scenario": scenario + "-bottom", "windowFrame": rect(window.frame),
                                    "contentLayoutRect": rect(safe), "contentFrames": frames, "failures": failures]
        if let output {
            let view = content.superview ?? content
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("Cannot capture scrolling reachability") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Cannot encode scrolling reachability") }
            let name = scenario + "-bottom.png"
            try data.write(to: output.appendingPathComponent(name))
            check["screenshot"] = name
        }
        checks.append(check)
        try require(failures.isEmpty, "\(scenario): \(failures.joined(separator: "; "))")
    }

    private func scrollToBottom(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private func wait(_ description: String, ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !ready(), Date() < deadline { await settle(0.05) }
        try require(ready(), "Timed out waiting for \(description)")
    }

    private func settle(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            for window in windows.values { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            NSApp.updateWindows()
            try? await Task.sleep(for: .milliseconds(15))
        } while Date() < deadline
    }

    private func finish(ok: Bool, error: String? = nil) throws {
        let attempts = windowFixtureNetworkAttempts()
        if ok { try require(attempts == 0, "The isolated WindowGroup requested remote data") }
        var result: [String: Any] = ["ok": ok, "actualWindowGroup": true, "networkAttempts": attempts,
                                    "actualViews": ["RepoContainer", "RepoView", "PageHeader", "HostingHubPanel", "NavigationSidebarRail"], "checks": checks]
        if let error { result["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("swiftui-releases-result.json"))
        }
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    private func cleanup() {
        windowFixtureDefaults.removePersistentDomain(forName: windowFixtureSuite)
        try? FileManager.default.removeItem(at: windowFixtureLocalStorageURL.deletingLastPathComponent())
    }

    private func probes(in view: NSView) -> [WindowContentProbe.ProbeView] {
        ((view as? WindowContentProbe.ProbeView).map { [$0] } ?? [])
            + view.subviews.flatMap { probes(in: $0) }
    }
    private func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        inner.minX >= outer.minX - 1 && inner.minY >= outer.minY - 1 && inner.maxX <= outer.maxX + 1 && inner.maxY <= outer.maxY + 1
    }
    private func equal(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
    private func rect(_ value: NSRect) -> [String: CGFloat] { ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height] }
    private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
