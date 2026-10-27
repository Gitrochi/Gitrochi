import AppKit
import SwiftUI

let windowFixtureSuite = "dev.gitrochi.window-content-fixture." + UUID().uuidString
let windowFixtureDefaults = UserDefaults(suiteName: windowFixtureSuite)!
let windowFixtureLocalStorageURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("gitrochi-window-planner-" + UUID().uuidString + "/projects.json")

/// A layout regression never contacts a provider, even if a new view starts a read.
private final class WindowFixtureNetworkBlocker: URLProtocol {
    private static let lock = NSLock()
    private static var attempted = 0
    static var attempts: Int { lock.lock(); defer { lock.unlock() }; return attempted }
    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempted += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

func windowFixtureNetworkAttempts() -> Int { WindowFixtureNetworkBlocker.attempts }

/// 실제 사이드바와 작업 영역 헤더의 임시 사본에만 붙이는 측정기.
struct WindowContentProbe: NSViewRepresentable {
    let identifier: String

    final class ProbeView: NSView {
        let identifierForFixture: String
        init(identifier: String) {
            identifierForFixture = identifier
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    func makeNSView(context: Context) -> NSView { ProbeView(identifier: identifier) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowContentFixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Models AppKit rejecting the first frame restoration while a style change is still settling.
private final class DeferredFrameFixtureWindow: NSWindow {
    var frameToReject: NSRect?
    var rejectedRestorations = 0
    var afterRejection: (() -> Void)?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if frameToReject == frameRect && !styleMask.contains(.fullSizeContentView) {
            frameToReject = nil
            rejectedRestorations += 1
            afterRejection?()
            return
        }
        super.setFrame(frameRect, display: flag)
    }
}

@main struct WindowContentLayoutFixture {
    @MainActor static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let fullscreen = arguments.contains("--fullscreen")
        let inspect = arguments.contains("--inspect")
        let output = arguments.first(where: { !$0.hasPrefix("--") }).map { URL(fileURLWithPath: $0, isDirectory: true) }
        _ = URLProtocol.registerClass(WindowFixtureNetworkBlocker.self)
        defer {
            URLProtocol.unregisterClass(WindowFixtureNetworkBlocker.self)
            try? FileManager.default.removeItem(at: windowFixtureLocalStorageURL.deletingLastPathComponent())
        }
        if arguments.contains("--swiftui-releases") {
            ReleaseChromeFixtureApp.main()
            return
        }
        let app = NSApplication.shared
        let applicationDelegate = WindowContentFixtureDelegate()
        app.delegate = applicationDelegate
        app.setActivationPolicy(fullscreen || inspect ? .regular : .prohibited)
        if fullscreen || inspect {
            let mainMenu = NSMenu()
            let applicationItem = NSMenuItem()
            let applicationMenu = NSMenu()
            applicationMenu.addItem(withTitle: "Quit Window Layout Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            applicationItem.submenu = applicationMenu
            mainMenu.addItem(applicationItem)
            app.mainMenu = mainMenu
        }
        app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        windowFixtureDefaults.set(false, forKey: "avatarFetch")
        defer { windowFixtureDefaults.removePersistentDomain(forName: windowFixtureSuite) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

        let store = RepoStore()
        let host = NSHostingController(rootView: AnyView(RepoContainer().environment(store)
            .defaultAppStorage(windowFixtureDefaults).frame(minWidth: 1080, minHeight: 640)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 100, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Gitrochi window layout regression fixture"
        window.toolbarStyle = .unified
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1440, height: 900))
        let originalFrame = window.frame
        RepositoryWindowLayout.configure(window)
        precondition(!window.styleMask.contains(.fullSizeContentView), "Repository content must not extend under the native titlebar")
        precondition(equal(window.frame, originalFrame), "Configuring content safety must preserve the outer window frame")
        RepositoryWindowLayout.configure(window)
        precondition(equal(window.frame, originalFrame), "Repeated attachment must preserve the outer window frame")
        window.orderBack(nil)
        var fixtureWindows = [window]

        func settle(_ duration: TimeInterval = 0.2) {
            let end = Date().addingTimeInterval(duration)
            repeat {
                for fixtureWindow in fixtureWindows {
                    fixtureWindow.contentView?.layoutSubtreeIfNeeded()
                    fixtureWindow.displayIfNeeded()
                }
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
                app.updateWindows()
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            } while Date() < end
            host.view.layoutSubtreeIfNeeded()
        }

        // Native zoom can outlast a fixed delay while SwiftUI is laying out the repository.
        func waitForNativeFrame(_ scenario: String, expected: NSRect? = nil, _ ready: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var previous = window.frame
            var stableSince = ProcessInfo.processInfo.systemUptime
            repeat {
                settle(0.025)
                let now = ProcessInfo.processInfo.systemUptime
                if !equal(window.frame, previous) {
                    previous = window.frame
                    stableSince = now
                }
                if ready() && now - stableSince >= 0.15 {
                    FileHandle.standardError.write(Data("Window frame passed: \(scenario) frame=\(window.frame) zoomed=\(window.isZoomed)\n".utf8))
                    return
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            preconditionFailure("Native frame did not settle during \(scenario): expected=\(String(describing: expected)) actual=\(window.frame) content=\(host.view.frame) zoomed=\(window.isZoomed) screen=\(window.screen?.visibleFrame ?? .zero)")
        }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func navigationSplitController(in view: NSView) -> NSSplitViewController {
            guard let split = descendants(view).compactMap({ $0 as? NSSplitView })
                .first(where: { $0.isVertical && $0.arrangedSubviews.count == 2 }) else {
                fatalError("Actual repository NavigationSplitView was not mounted")
            }
            var responder: NSResponder? = split
            while let current = responder {
                if let controller = current as? NSSplitViewController { return controller }
                responder = current.nextResponder
            }
            fatalError("Actual navigation sidebar has no public split controller")
        }
        func sidebarItem(in controller: NSSplitViewController) -> NSSplitViewItem {
            guard let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else {
                fatalError("Actual navigation split controller must have a sidebar item")
            }
            return item
        }
        func probes(in view: NSView) -> [WindowContentProbe.ProbeView] {
            descendants(view).compactMap { $0 as? WindowContentProbe.ProbeView }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.width > 1 && $0.visibleRect.height > 1 }
        }
        func controls(for window: NSWindow) -> [NSButton] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window?.isVisible == true }
        }
        func rect(_ frame: NSRect) -> [String: CGFloat] {
            ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        }
        var checks: [[String: Any]] = []
        let constrainedBefore = NSRect(x: 0, y: 45, width: 1080, height: 692)
        let constrainedAfter = NSRect(x: 0, y: 45, width: 1080, height: 640)
        let constrainedReflow = NSRect(x: 0, y: -7, width: 1080, height: 692)
        let constrainedMinimum = constrainedBefore.size
        precondition(RepositoryWindowLayout.restorationFrame(before: constrainedBefore, after: constrainedAfter,
            current: constrainedReflow, minimum: constrainedMinimum) == constrainedBefore,
            "Minimum-size reflow must preserve the original origin instead of the temporary content top")
        precondition(RepositoryWindowLayout.restorationFrame(before: constrainedBefore, after: constrainedAfter,
            current: constrainedReflow, minimum: constrainedMinimum, inLiveResize: true) == constrainedReflow,
            "A live resize must take precedence even when its geometry matches minimum-size reflow")
        checks.append(["scenario": "minimum-size-origin-restored", "windowFrame": rect(constrainedBefore)])
        let explicitMove = constrainedBefore.offsetBy(dx: 20, dy: 12)
        precondition(RepositoryWindowLayout.restorationFrame(before: constrainedBefore, after: constrainedAfter,
            current: explicitMove, minimum: constrainedMinimum) == explicitMove, "An explicit move must retain its chosen origin")
        checks.append(["scenario": "explicit-move-preserved", "windowFrame": rect(explicitMove)])
        let explicitResize = NSRect(x: 0, y: 45, width: 1200, height: 760)
        precondition(RepositoryWindowLayout.restorationFrame(before: constrainedBefore, after: constrainedAfter,
            current: explicitResize, minimum: constrainedMinimum) == explicitResize, "An explicit resize must retain its chosen frame")
        checks.append(["scenario": "explicit-resize-preserved", "windowFrame": rect(explicitResize)])
        let normalBefore = NSRect(x: 100, y: 100, width: 1440, height: 900)
        let normalAfter = NSRect(x: 100, y: 100, width: 1440, height: 848)
        let normalRestored = NSRect(x: 100, y: 48, width: 1440, height: 900)
        precondition(RepositoryWindowLayout.restorationFrame(before: normalBefore, after: normalAfter,
            current: normalRestored, minimum: constrainedMinimum) == normalRestored,
            "A normal-size restored frame must not be classified as minimum-size reflow")
        checks.append(["scenario": "normal-restored-frame-preserved", "windowFrame": rect(normalRestored)])
        let deferredWindow = DeferredFrameFixtureWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        deferredWindow.isReleasedWhenClosed = false
        deferredWindow.contentView = NSView()
        deferredWindow.toolbar = NSToolbar(identifier: "DeferredFrameFixture")
        RepositoryWindowLayout.configure(deferredWindow)
        deferredWindow.orderBack(nil)
        settle(0.1)
        let deferredBaseline = deferredWindow.frame
        deferredWindow.styleMask.insert(.fullSizeContentView)
        deferredWindow.setFrame(deferredBaseline, display: false)
        deferredWindow.frameToReject = deferredBaseline
        settle(0.2)
        precondition(deferredWindow.rejectedRestorations == 1, "The deferred-frame regression must reject a real restoration attempt")
        precondition(equal(deferredWindow.frame, deferredBaseline), "A frame rejected during style layout must restore on the next turn: expected=\(deferredBaseline) actual=\(deferredWindow.frame)")
        checks.append(["scenario": "deferred-frame-restored", "windowFrame": rect(deferredWindow.frame), "rejectedRestorations": deferredWindow.rejectedRestorations])

        let explicitFrame = NSRect(x: deferredBaseline.minX + 20, y: deferredBaseline.minY + 12,
                                   width: deferredBaseline.width + 32, height: deferredBaseline.height + 18)
        deferredWindow.styleMask.insert(.fullSizeContentView)
        deferredWindow.setFrame(deferredBaseline, display: false)
        deferredWindow.frameToReject = deferredBaseline
        deferredWindow.afterRejection = { DispatchQueue.main.async { deferredWindow.setFrame(explicitFrame, display: false) } }
        settle(0.2)
        precondition(deferredWindow.rejectedRestorations == 2, "The explicit-resize regression must interrupt a pending restoration")
        precondition(equal(deferredWindow.frame, explicitFrame), "An explicit resize must take precedence over deferred restoration: expected=\(explicitFrame) actual=\(deferredWindow.frame)")
        checks.append(["scenario": "deferred-frame-explicit-resize", "windowFrame": rect(deferredWindow.frame), "rejectedRestorations": deferredWindow.rejectedRestorations])
        deferredWindow.afterRejection = nil
        deferredWindow.orderOut(nil)
        func capture(_ scenario: String, expectContent: Bool = true,
                     targetWindow: NSWindow? = nil, targetHost: NSHostingController<AnyView>? = nil) throws {
            settle()
            let window = targetWindow ?? fixtureWindows[0]
            let measuredHost = targetHost ?? host
            precondition(!window.styleMask.contains(.fullSizeContentView), "Full-size content returned during \(scenario)")
            let safe = window.contentLayoutRect
            let measured = probes(in: measuredHost.view)
            let header = measured.first { $0.identifierForFixture == "workspace-header" }
            precondition(!expectContent || header != nil, "Actual workspace header was not measured during \(scenario)")
            var measuredFrames: [String: Any] = [:]
            let visibleControls = controls(for: window)
            let traffic = visibleControls.map { button in
                window.convertFromScreen(button.window!.convertToScreen(button.convert(button.bounds, to: nil)))
            }
            let ownTraffic = zip(visibleControls, traffic).filter { $0.0.window === window }.map { $0.1 }
            let nativeOverlays = zip(visibleControls, traffic).filter { $0.0.window !== window }.map { $0.1 }
            let ownership: [[String: Any]] = visibleControls.enumerated().map { index, button in
                ["mainWindow": button.window === window, "windowNumber": button.window!.windowNumber, "frame": rect(traffic[index])]
            }
            for probe in measured {
                let frame = probe.convert(probe.bounds, to: nil)
                precondition(frame.maxY <= safe.maxY + 1,
                             "\(probe.identifierForFixture) enters native titlebar during \(scenario): \(frame), safe \(safe)")
                if probe.identifierForFixture == "workspace-header" {
                    precondition(abs(frame.maxY - safe.maxY) <= 1,
                                 "Workspace header leaves an extra titlebar gap during \(scenario): \(frame), safe \(safe)")
                    precondition(frame.minY >= safe.minY - 1 && frame.height <= safe.height + 1,
                                 "Workspace content grows outside its finite viewport during \(scenario): \(frame), safe \(safe)")
                }
                // 다른 네이티브 창에 속한 전체화면 제목 막대는 시스템 오버레이로 별도 기록한다.
                precondition(ownTraffic.allSatisfy { !$0.intersects(frame) }, "Content overlaps a traffic-light button during \(scenario)")
                measuredFrames[probe.identifierForFixture] = rect(frame)
            }
            for item in window.toolbar?.items ?? [] {
                guard let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 1 else { continue }
                let frame = view.convert(view.bounds, to: nil)
                precondition(ownTraffic.allSatisfy { !$0.intersects(frame) }, "Native toolbar item overlaps a traffic-light button during \(scenario)")
            }
            var check: [String: Any] = ["scenario": scenario, "contentLayoutRect": rect(safe), "windowFrame": rect(window.frame),
                                        "contentFrames": measuredFrames, "trafficLightButtons": traffic.map(rect),
                                        "trafficLightWindowOwnership": ownership, "nativeOverlayRectangles": nativeOverlays.map(rect),
                                        "fullscreen": window.styleMask.contains(.fullScreen), "zoomed": window.isZoomed,
                                        "nativeTabCount": window.tabGroup?.windows.count ?? 1]
            if let output {
                let captureView = window.contentView?.superview ?? measuredHost.view
                let bounds = captureView.bounds
                guard let bitmap = captureView.bitmapImageRepForCachingDisplay(in: bounds),
                      let data = { () -> Data? in
                          captureView.cacheDisplay(in: bounds, to: bitmap)
                          return bitmap.representation(using: .png, properties: [:])
                      }() else { fatalError("Could not capture actual repository content") }
                let name = scenario + ".png"
                try data.write(to: output.appendingPathComponent(name))
                check["screenshot"] = name
            }
            checks.append(check)
        }

        try capture("initial-loading", expectContent: false)
        store.booted = true
        settle(0.6)
        try capture("loaded-wide")
        precondition(window.toolbar != nil, "Actual RepoView toolbar must be installed by NSHostingController")

        // SwiftUI can restore this style after the initial window attachment.
        // The lifetime attachment must contain it without another configure call.
        let beforeLateStyle = window.frame
        window.styleMask.insert(.fullSizeContentView)
        waitForNativeFrame("late-toolbar-style-restored", expected: beforeLateStyle) { equal(window.frame, beforeLateStyle) && !window.styleMask.contains(.fullSizeContentView) }
        try capture("late-toolbar-style-restored")
        precondition(equal(window.frame, beforeLateStyle), "Late toolbar changes must preserve the outer window frame: expected=\(beforeLateStyle) actual=\(window.frame) screen=\(window.screen?.visibleFrame ?? .zero)")

        store.loading = LoadingInfo(title: "Opening fixture", step: "Rendering the actual loading overlay")
        settle(0.6)
        try capture("repository-loading-overlay")
        store.loading = nil
        settle(0.6)
        try capture("loading-overlay-dismissed")

        for size in [NSSize(width: 1080, height: 640), NSSize(width: 1680, height: 980), NSSize(width: 1440, height: 900)] {
            window.setContentSize(size)
            settle(0.4)
            try capture("resize-\(Int(size.width))-\(Int(size.height))")
        }
        let splitController = navigationSplitController(in: host.view)
        let sidebar = sidebarItem(in: splitController)
        let initialCollapsed = sidebar.isCollapsed
        splitController.toggleSidebar(nil)
        settle(0.45)
        precondition(sidebar.isCollapsed != initialCollapsed, "The native sidebar toggle must change its actual collapsed state")
        try capture("sidebar-toggled")
        splitController.toggleSidebar(nil)
        settle(0.45)
        precondition(sidebar.isCollapsed == initialCollapsed, "The native sidebar toggle must restore its actual collapsed state")
        try capture("sidebar-restored")

        let fullFixtureFrame = window.frame, fullFixtureMinimum = window.contentMinSize
        guard let zoomScreen = window.screen ?? NSScreen.main else { fatalError("Native zoom needs a screen") }
        let zoomScreenFrame = zoomScreen.visibleFrame
        let zoomMinimum = NSSize(width: min(700, zoomScreenFrame.width * 0.6),
                                 height: min(400, zoomScreenFrame.height * 0.5))
        // AppKit cannot toggle zoom when the fixture minimum exceeds the runner's screen.
        // Keep the full production minimum for the other layout scenarios.
        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: zoomMinimum.width, minHeight: zoomMinimum.height))
        window.contentMinSize = zoomMinimum
        settle()
        let zoomBaseline = NSRect(x: zoomScreenFrame.minX + 60, y: zoomScreenFrame.minY + 60,
                                  width: min(900, zoomScreenFrame.width - 120),
                                  height: min(540, zoomScreenFrame.height - 120))
        window.setFrame(zoomBaseline, display: true)
        settle()
        let beforeZoom = window.frame
        precondition(zoomScreenFrame.contains(beforeZoom), "The native zoom baseline must fit its screen: \(beforeZoom), screen \(zoomScreenFrame)")
        precondition(!window.isZoomed, "The native zoom baseline must leave room to zoom")
        window.zoom(nil)
        waitForNativeFrame("native-zoom") { window.isZoomed && !equal(window.frame, beforeZoom) }
        precondition(window.isZoomed && !equal(window.frame, beforeZoom), "Native zoom must actually enter the zoomed state")
        try capture("native-zoom")
        window.zoom(nil)
        waitForNativeFrame("native-zoom-restored", expected: beforeZoom) { !window.isZoomed && equal(window.frame, beforeZoom) }
        precondition(!window.isZoomed && equal(window.frame, beforeZoom), "Unzoom must restore the outer window frame")
        try capture("native-zoom-restored")

        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: 1080, minHeight: 640))
        window.contentMinSize = fullFixtureMinimum
        window.setFrame(fullFixtureFrame, display: true)
        waitForNativeFrame("full-fixture-restored", expected: fullFixtureFrame) { equal(window.frame, fullFixtureFrame) }

        // AppKit fits an oversized tab group to the display, independently of content-style repair.
        // Use a legal baseline for exact native-tab geometry checks on small runners.
        let fittingNativeTabs = !zoomScreenFrame.contains(fullFixtureFrame)
        let nativeTabMinimum = fittingNativeTabs ? zoomMinimum : fullFixtureMinimum
        if fittingNativeTabs {
            host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
                .frame(minWidth: nativeTabMinimum.width, minHeight: nativeTabMinimum.height))
            window.contentMinSize = nativeTabMinimum
            settle()
            window.setFrame(zoomBaseline, display: true)
            waitForNativeFrame("native-tab-baseline", expected: zoomBaseline) { equal(window.frame, zoomBaseline) }
            precondition(zoomScreenFrame.contains(window.frame), "Native-tab baseline must fit the runner's screen")
        }

        let secondStore = RepoStore()
        secondStore.booted = true
        let secondHost = NSHostingController(rootView: AnyView(RepoContainer().environment(secondStore)
            .defaultAppStorage(windowFixtureDefaults).frame(minWidth: nativeTabMinimum.width, minHeight: nativeTabMinimum.height)))
        let secondWindow = NSWindow(contentRect: window.contentLayoutRect,
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        secondWindow.isReleasedWhenClosed = false
        secondWindow.toolbarStyle = .unified
        secondWindow.contentViewController = secondHost
        fixtureWindows.append(secondWindow)
        RepositoryWindowLayout.configure(secondWindow)
        for tab in fixtureWindows {
            tab.tabbingIdentifier = "GitrochiWindowLayoutFixture"
            tab.tabbingMode = .preferred
        }
        secondWindow.orderBack(nil)
        settle(0.2)
        secondWindow.setFrame(window.frame, display: false)
        settle(0.2)
        let beforeTabs = window.frame
        window.addTabbedWindow(secondWindow, ordered: .above)
        window.tabGroup?.selectedWindow = window
        settle(0.4)
        precondition(window.tabbedWindows?.count == 2, "Fixture must install a real AppKit tab bar")
        precondition(equal(window.frame, beforeTabs), "Adding native tabs must preserve the outer frame: expected=\(beforeTabs) actual=\(window.frame) minimum=\(window.minSize) screen=\(window.screen?.visibleFrame ?? .zero)")
        try capture("native-tab-group")
        window.tabGroup?.selectedWindow = secondWindow
        settle(0.3)
        window.tabGroup?.selectedWindow = window
        settle(0.3)
        window.styleMask.insert(.fullSizeContentView)
        try capture("native-tab-switch-restored")

        let beforeFrameRestore = window.frame
        let restoredFrame = NSRect(x: beforeFrameRestore.minX + 24, y: beforeFrameRestore.minY + 16,
                                   width: beforeFrameRestore.width - 40, height: beforeFrameRestore.height - 20)
        window.styleMask.insert(.fullSizeContentView)
        window.setFrame(restoredFrame, display: false)
        try capture("native-tab-frame-restored")
        precondition(equal(window.frame, restoredFrame), "A restored frame must take precedence over the previous style geometry")
        window.setFrame(beforeFrameRestore, display: false)
        settle(0.3)

        // 루트 뷰가 안전 영역을 무시해도 네이티브 콘텐츠 경계가 헤더를 보호해야 한다.
        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: nativeTabMinimum.width, minHeight: nativeTabMinimum.height).ignoresSafeArea())
        let beforeRepair = window.frame
        window.styleMask.insert(.fullSizeContentView)
        RepositoryWindowLayout.configure(window)
        precondition(equal(window.frame, beforeRepair), "Repairing an unsafe root must preserve the outer frame: expected=\(beforeRepair) actual=\(window.frame)")
        window.styleMask.insert(.fullSizeContentView)
        try capture("safe-area-ignoring-root-contained")
        precondition(equal(window.frame, beforeRepair), "A repeated style refresh must preserve the directly configured frame")
        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: nativeTabMinimum.width, minHeight: nativeTabMinimum.height))
        settle(0.5)

        // SwiftUI can reinstall this option after the initial window attachment.
        let beforeStyleRefresh = window.frame
        window.styleMask.insert(.fullSizeContentView)
        try capture("toolbar-style-reinstalled")
        precondition(equal(window.frame, beforeStyleRefresh), "A later toolbar style refresh must preserve the outer frame")

        var explicitToolbarFrame = window.frame
        explicitToolbarFrame.size.width += 40
        // Resize from the safe outer frame; the style mutation can temporarily shrink its height.
        window.styleMask.insert(.fullSizeContentView)
        window.setFrame(explicitToolbarFrame, display: false)
        window.styleMask.insert(.fullSizeContentView)
        try capture("toolbar-style-before-explicit-resize")
        precondition(equal(window.frame, explicitToolbarFrame), "Content repair must honor a subsequent explicit resize")
        window.setFrame(beforeStyleRefresh, display: false)

        // Check both mounted repository views across the native tab bar, themes and sidebars.
        precondition(window.tabGroup?.windows.count == 2 && secondWindow.tabGroup === window.tabGroup,
                     "The header regression must use two real native window tabs")
        let tabbedFrame = window.frame
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for tab in fixtureWindows { tab.appearance = NSAppearance(named: appearance) }
            window.tabGroup?.selectedWindow = window
            try capture("native-tabs-\(name)")
            // The safe-area scenario replaced the root; locate the currently mounted controller.
            let tabbedSplitController = navigationSplitController(in: host.view)
            let tabbedSidebar = sidebarItem(in: tabbedSplitController)
            let tabbedCollapsed = tabbedSidebar.isCollapsed
            tabbedSplitController.toggleSidebar(nil)
            settle(0.45)
            precondition(tabbedSidebar.isCollapsed != tabbedCollapsed, "A tabbed sidebar must actually change its collapsed state")
            try capture("native-tabs-sidebar-toggled-\(name)")
            tabbedSplitController.toggleSidebar(nil)
            settle(0.45)
            precondition(tabbedSidebar.isCollapsed == tabbedCollapsed, "A tabbed sidebar must restore its original collapsed state")
            try capture("native-tabs-sidebar-restored-\(name)")
            window.tabGroup?.selectedWindow = secondWindow
            try capture("native-tabs-selected-second-\(name)", targetWindow: secondWindow, targetHost: secondHost)
            let secondFrame = secondWindow.frame
            secondWindow.styleMask.insert(.fullSizeContentView)
            try capture("native-tabs-style-reinstalled-\(name)", targetWindow: secondWindow, targetHost: secondHost)
            precondition(equal(secondWindow.frame, secondFrame), "A tab's later toolbar refresh must preserve its frame")
            window.tabGroup?.selectedWindow = window
            try capture("native-tabs-selected-first-\(name)")
            precondition(equal(window.frame, tabbedFrame), "Changing tabs and appearance must preserve the outer frame")
        }
        for tab in fixtureWindows { tab.appearance = nil }

        // Restore four real window tabs, then enter Releases from the compact repository rail.
        // The selected GitHub account deliberately differs from the repository's GitLab provider.
        let account = HostAccount(id: "window-fixture-account", provider: .github, server: "https://github.com", username: "demo-reader", name: nil, avatarURL: nil)
        AccountStore.shared.windowFixtureSetAccounts([account])
        var extraWindows: [NSWindow] = []
        for index in 3...4 {
            let peerStore = RepoStore()
            peerStore.booted = true
            let peerHost = NSHostingController(rootView: AnyView(RepoContainer().environment(peerStore).defaultAppStorage(windowFixtureDefaults)
                .frame(minWidth: nativeTabMinimum.width, minHeight: nativeTabMinimum.height)))
            let peer = NSWindow(contentRect: window.contentLayoutRect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            peer.isReleasedWhenClosed = false
            peer.title = "Synthetic repository \(index)"
            peer.toolbarStyle = .unified
            peer.contentViewController = peerHost
            RepositoryWindowLayout.configure(peer)
            peer.tabbingIdentifier = window.tabbingIdentifier
            peer.tabbingMode = .preferred
            peer.contentMinSize = nativeTabMinimum
            fixtureWindows.append(peer)
            extraWindows.append(peer)
            peer.orderBack(nil)
            settle(0.2)
            peer.setFrame(window.frame, display: false)
            window.addTabbedWindow(peer, ordered: .above)
        }
        window.tabGroup?.selectedWindow = window
        store.windowFixtureSetURL(URL(fileURLWithPath: "/fixture/synthetic-repository", isDirectory: true))
        store.target = RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.example.com", path: "demo/repository")
        store.navigate(.repository, prepare: false)
        settle(0.4)
        store.hostingHub.selectedAccountID = account.id
        store.navigate(.releases, prepare: false)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for tab in fixtureWindows { tab.appearance = NSAppearance(named: appearance) }
            settle(0.5)
            precondition(window.tabGroup?.windows.count == 4, "Releases regression must retain four real native tabs")
            FileHandle.standardError.write(Data("Release geometry: selected=\(window.tabGroup?.selectedWindow === window) window=\(window.windowNumber) frame=\(window.frame) hostWindow=\(host.view.window?.windowNumber ?? -1) host=\(host.view.frame) bounds=\(host.view.bounds) content=\(String(describing: window.contentView?.frame)) safe=\(window.contentLayoutRect)\n".utf8))
            if let output, let captureView = window.contentView?.superview,
               let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) {
                captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("releases-diagnostic-\(name).png"))
            }
            let measured = probes(in: host.view)
            for probe in measured {
                FileHandle.standardError.write(Data("Release probe: \(probe.identifierForFixture) window=\(probe.window?.windowNumber ?? -1) frame=\(probe.convert(probe.bounds, to: nil)) visible=\(probe.visibleRect)\n".utf8))
            }
            for identifier in ["page-title:releases", "hub-title:releases", "rail-control"] {
                guard let probe = measured.first(where: { $0.identifierForFixture == identifier }) else { fatalError("Missing actual Releases control: \(identifier)") }
                let frame = probe.convert(probe.bounds, to: nil)
                precondition(frame.height >= 15 && window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(frame),
                             "Actual Releases control is clipped: \(identifier) frame=\(frame) safe=\(window.contentLayoutRect)")
            }
            try capture("releases-four-tabs-\(name)")
        }
        store.navigate(.home, prepare: false)
        store.windowFixtureSetURL(nil); store.target = nil
        AccountStore.shared.windowFixtureSetAccounts([])
        for peer in extraWindows { peer.tabGroup?.removeWindow(peer); peer.orderOut(nil) }
        fixtureWindows.removeAll { extraWindows.contains($0) }
        settle(0.3)

        if fullscreen {
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.center()
            window.makeKeyAndOrderFront(nil)
            if window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
            app.activate(ignoringOtherApps: true)
            settle(0.3)
            let beforeFullscreen = window.frame
            var entered = false
            var exited = false
            let enterToken = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in entered = true }
            let exitToken = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in exited = true }
            defer {
                NotificationCenter.default.removeObserver(enterToken)
                NotificationCenter.default.removeObserver(exitToken)
            }
            window.toggleFullScreen(nil)
            var deadline = Date().addingTimeInterval(12)
            while !entered && Date() < deadline { settle(0.05) }
            precondition(entered && window.styleMask.contains(.fullScreen), "Native fullscreen must really enter, not be simulated")
            try capture("native-fullscreen")
            window.toggleFullScreen(nil)
            deadline = Date().addingTimeInterval(12)
            while !exited && Date() < deadline { settle(0.05) }
            precondition(exited && !window.styleMask.contains(.fullScreen), "Native fullscreen must really exit")
            precondition(equal(window.frame, beforeFullscreen), "Leaving fullscreen must restore the outer window frame")
            try capture("native-fullscreen-restored")
        }

        window.tabGroup?.removeWindow(secondWindow)
        secondWindow.orderOut(nil)
        settle(0.3)
        if fittingNativeTabs {
            host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
                .frame(minWidth: 1080, minHeight: 640))
            window.contentMinSize = fullFixtureMinimum
            settle()
            let minimumFrame = NSRect(x: zoomScreenFrame.minX, y: zoomScreenFrame.maxY - window.minSize.height,
                                      width: window.minSize.width, height: window.minSize.height)
            precondition(equal(window.constrainFrameRect(minimumFrame, to: zoomScreen), minimumFrame), "The restored production minimum must be a legal native frame")
            window.setFrame(minimumFrame, display: true)
            waitForNativeFrame("production-minimum-restored-after-tabs", expected: minimumFrame) {
                equal(window.frame, minimumFrame) && window.contentMinSize == fullFixtureMinimum
            }
            precondition(window.contentLayoutRect.width >= fullFixtureMinimum.width - 1 && window.contentLayoutRect.height >= fullFixtureMinimum.height - 1,
                         "The final viewport must restore the full production content minimum")
        }
        try capture("native-tabs-detached")

        for tab in fixtureWindows { tab.orderOut(nil) }
        precondition(WindowFixtureNetworkBlocker.attempts == 0, "Window layout must not request remote account or project data")
        let result: [String: Any] = ["ok": true, "actualViews": ["RepoContainer", "RepoView", "NavigationSidebar", "LoadingView"],
                                     "safeAreaIgnoringRootContained": true, "framePreserved": true,
                                     "lateToolbarStyleContained": true, "nativeTabsChecked": true,
                                     "nativeTabsFittedToScreen": fittingNativeTabs,
                                     "fullscreenRequested": fullscreen, "inspectionRequested": inspect, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let output { try data.write(to: output.appendingPathComponent("result.json")) }
        print(String(decoding: data, as: UTF8.self))
        if inspect {
            // Keep the actual two-repository tab group available for manual inspection.
            secondWindow.setFrame(window.frame, display: false)
            window.addTabbedWindow(secondWindow, ordered: .above)
            window.tabGroup?.selectedWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            if window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
            app.activate(ignoringOtherApps: true)
            settle(0.3)
            windowFixtureDefaults.removePersistentDomain(forName: windowFixtureSuite)
            print("INSPECT_READY: Gitrochi window layout fixture; close the window or quit the app after inspection.")
            fflush(stdout)
            app.run()
        }
    }

    private static func equal(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}
