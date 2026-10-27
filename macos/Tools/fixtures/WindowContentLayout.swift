import AppKit
import SwiftUI

let windowFixtureSuite = "dev.gitrochi.window-content-fixture." + UUID().uuidString
let windowFixtureDefaults = UserDefaults(suiteName: windowFixtureSuite)!

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

@main struct WindowContentLayoutFixture {
    @MainActor static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let fullscreen = arguments.contains("--fullscreen")
        let inspect = arguments.contains("--inspect")
        let output = arguments.first(where: { !$0.hasPrefix("--") }).map { URL(fileURLWithPath: $0, isDirectory: true) }
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

        // 루트 뷰가 안전 영역을 무시해도 네이티브 콘텐츠 경계가 헤더를 보호해야 한다.
        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: 1080, minHeight: 640).ignoresSafeArea())
        window.styleMask.insert(.fullSizeContentView)
        let beforeRepair = window.frame
        RepositoryWindowLayout.configure(window)
        precondition(equal(window.frame, beforeRepair), "Repairing an unsafe root must preserve the outer frame")
        window.styleMask.insert(.fullSizeContentView)
        try capture("safe-area-ignoring-root-contained")
        precondition(equal(window.frame, beforeRepair), "A repeated style refresh must preserve the directly configured frame")
        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: 1080, minHeight: 640))
        settle(0.5)

        // SwiftUI can reinstall this option after the initial window attachment.
        let beforeStyleRefresh = window.frame
        window.styleMask.insert(.fullSizeContentView)
        try capture("toolbar-style-reinstalled")
        precondition(equal(window.frame, beforeStyleRefresh), "A later toolbar style refresh must preserve the outer frame")

        window.styleMask.insert(.fullSizeContentView)
        var explicitFrame = window.frame
        explicitFrame.size.width += 40
        window.setFrame(explicitFrame, display: false)
        window.styleMask.insert(.fullSizeContentView)
        try capture("toolbar-style-before-explicit-resize")
        precondition(equal(window.frame, explicitFrame), "Content repair must honor a subsequent explicit resize")
        window.setFrame(beforeStyleRefresh, display: false)

        // Use real repository tabs to check the toolbar, tab bar and sidebar together.
        let secondStore = RepoStore()
        secondStore.booted = true
        let secondHost = NSHostingController(rootView: AnyView(RepoContainer().environment(secondStore)
            .defaultAppStorage(windowFixtureDefaults).frame(minWidth: 1080, minHeight: 640)))
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
        window.addTabbedWindow(secondWindow, ordered: .above)
        settle(0.5)
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

        for tab in fixtureWindows { tab.orderOut(nil) }
        let result: [String: Any] = ["ok": true, "actualViews": ["RepoContainer", "RepoView", "NavigationSidebar", "LoadingView"],
                                     "safeAreaIgnoringRootContained": true, "framePreserved": true, "nativeTabsChecked": true,
                                     "fullscreenRequested": fullscreen, "inspectionRequested": inspect, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let output { try data.write(to: output.appendingPathComponent("result.json")) }
        print(String(decoding: data, as: UTF8.self))
        if inspect {
            // 화면에 표시한 실제 합성 결과는 컴퓨터 사용 도구로 확인한다.
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
