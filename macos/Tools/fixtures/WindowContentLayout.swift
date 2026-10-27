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

        func settle(_ duration: TimeInterval = 0.2) {
            let end = Date().addingTimeInterval(duration)
            repeat {
                host.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
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
        func probes() -> [WindowContentProbe.ProbeView] {
            descendants(host.view).compactMap { $0 as? WindowContentProbe.ProbeView }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.width > 1 && $0.visibleRect.height > 1 }
        }
        func controls() -> [NSButton] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window?.isVisible == true }
        }
        func rect(_ frame: NSRect) -> [String: CGFloat] {
            ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        }
        var checks: [[String: Any]] = []
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
        func capture(_ scenario: String, expectContent: Bool = true) throws {
            settle()
            precondition(!window.styleMask.contains(.fullSizeContentView), "Full-size content returned during \(scenario)")
            let safe = window.contentLayoutRect
            let measured = probes()
            let header = measured.first { $0.identifierForFixture == "workspace-header" }
            precondition(!expectContent || header != nil, "Actual workspace header was not measured during \(scenario)")
            var measuredFrames: [String: Any] = [:]
            let visibleControls = controls()
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
                                        "fullscreen": window.styleMask.contains(.fullScreen), "zoomed": window.isZoomed]
            if let output {
                let captureView = window.contentView?.superview ?? host.view
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
        guard let split = descendants(host.view).compactMap({ $0 as? NSSplitView }).first(where: { $0.isVertical && $0.arrangedSubviews.count == 2 }) else {
            fatalError("Actual repository NavigationSplitView was not mounted")
        }
        var responder: NSResponder? = split
        var splitController: NSSplitViewController?
        while let current = responder {
            if let controller = current as? NSSplitViewController { splitController = controller; break }
            responder = current.nextResponder
        }
        guard let splitController else { fatalError("Actual navigation sidebar has no public split controller") }
        splitController.toggleSidebar(nil)
        settle(0.45)
        try capture("sidebar-toggled")
        splitController.toggleSidebar(nil)
        settle(0.45)
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

        let secondWindow = NSWindow(contentRect: window.contentLayoutRect,
                                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        secondWindow.isReleasedWhenClosed = false
        secondWindow.title = "Second repository tab"
        secondWindow.contentView = NSView()
        RepositoryWindowLayout.configure(secondWindow)
        window.tabbingIdentifier = "GitrochiWindowLayoutFixture"
        secondWindow.tabbingIdentifier = window.tabbingIdentifier
        window.tabbingMode = .preferred
        secondWindow.tabbingMode = .preferred
        secondWindow.orderBack(nil)
        let beforeTabs = window.frame
        window.addTabbedWindow(secondWindow, ordered: .above)
        window.tabGroup?.selectedWindow = window
        settle(0.4)
        precondition(window.tabbedWindows?.count == 2, "Fixture must install a real AppKit tab bar")
        precondition(equal(window.frame, beforeTabs), "Adding native tabs must preserve the outer frame")
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
            .frame(minWidth: 1080, minHeight: 640).ignoresSafeArea())
        let beforeRepair = window.frame
        window.styleMask.insert(.fullSizeContentView)
        RepositoryWindowLayout.configure(window)
        precondition(equal(window.frame, beforeRepair), "Repairing an unsafe root must preserve the outer frame")
        try capture("safe-area-ignoring-root-contained")
        host.rootView = AnyView(RepoContainer().environment(store).defaultAppStorage(windowFixtureDefaults)
            .frame(minWidth: 1080, minHeight: 640))
        settle(0.5)

        if fullscreen {
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.center()
            window.makeKeyAndOrderFront(nil)
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
        try capture("native-tabs-detached")

        window.orderOut(nil)
        let result: [String: Any] = ["ok": true, "actualViews": ["RepoContainer", "RepoView", "NavigationSidebar", "LoadingView"],
                                     "safeAreaIgnoringRootContained": true, "framePreserved": true,
                                     "lateToolbarStyleContained": true, "nativeTabsChecked": true,
                                     "fullscreenRequested": fullscreen, "inspectionRequested": inspect, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let output { try data.write(to: output.appendingPathComponent("result.json")) }
        print(String(decoding: data, as: UTF8.self))
        if inspect {
            // 화면에 표시한 실제 합성 결과는 컴퓨터 사용 도구로 확인한다.
            window.center()
            window.makeKeyAndOrderFront(nil)
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
