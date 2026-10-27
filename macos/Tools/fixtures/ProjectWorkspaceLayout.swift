import AppKit
import SwiftUI
import Vision

let projectFixtureSuite = "dev.gitrochi.project-workspace-fixture." + UUID().uuidString
let projectFixtureDefaults = UserDefaults(suiteName: projectFixtureSuite)!
let projectFixtureLocalStorageURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("local-fixture-storage-" + UUID().uuidString + "/projects.json")

final class ProjectFixtureCredentialCounter {
    private static let lock = NSLock()
    private static var count = 0
    static var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func read() -> CredentialReadResult {
        lock.lock(); count += 1; lock.unlock()
        return CredentialReadResult(value: "fixture-credential", status: 0)
    }
}

@MainActor private final class ProjectQuickAddFixtureGate {
    var titles: [String] = []
    private var continuation: CheckedContinuation<String?, Never>?
    func submit(_ title: String) async -> String? {
        titles.append(title)
        return await withCheckedContinuation { continuation = $0 }
    }
    func fail(_ error: String) { let pending = continuation; continuation = nil; pending?.resume(returning: error) }
}

/// Measurements are attached only to temporary copies of production view sources.
struct ProjectWorkspaceProbe: NSViewRepresentable {
    let identifier: String

    final class ProbeView: NSView {
        var fixtureIdentifier: String
        init(identifier: String) {
            fixtureIdentifier = identifier
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    func makeNSView(context: Context) -> NSView { ProbeView(identifier: identifier) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.fixtureIdentifier = identifier
    }
}

private struct ProjectScheduleFixtureHost: View {
    let detail: HubDetail
    let calendar: Bool
    @ViewState private var settings = ProjectScheduleSettings(completedOptionIDs: ["done"])
    var body: some View {
        if calendar {
            ProjectCalendar(rows: detail.rows, fields: detail.fields, settings: $settings, locked: false,
                            select: { _ in }, editDate: { _, _ in }, complete: { _ in }, reschedule: { _, _ in }, manageFields: {})
        } else {
            ProjectDashboard(rows: detail.rows, fields: detail.fields, settings: $settings, locked: false,
                             select: { _ in }, editDate: { _, _ in }, complete: { _ in }, manageFields: {})
        }
    }
}

/// Accidental requests fail locally, before any synthetic credential can reach a server.
private final class ProjectFixtureNetworkBlocker: URLProtocol {
    private static let lock = NSLock()
    private static var attempted = 0
    private static var fixtureReads = 0
    static var attempts: Int { lock.lock(); defer { lock.unlock() }; return attempted }
    static var viewReads: Int { lock.lock(); defer { lock.unlock() }; return fixtureReads }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "api.github.com", request.httpMethod == "GET",
           ["/repos/sample-studio/desktop/issues/401", "/repos/sample-studio/desktop/issues/401/comments"].contains(request.url?.path ?? "") {
            let payload: Any
            if request.url?.path.hasSuffix("/comments") == true {
                payload = [
                    ["id": 701, "user": ["login": "demo-reviewer"], "body": "The inline task flow keeps the next step clear.", "created_at": "2026-10-27T09:00:00Z"],
                    ["id": 702, "user": ["login": "demo-maintainer"], "body": "Verified the status, priority, and schedule controls.", "created_at": "2026-10-27T10:30:00Z"]
                ]
            } else {
                payload = ["number": 401, "title": "Review the project workflow", "body": "Plan the release together and keep the work easy to follow.", "state": "open", "user": ["login": "demo-maintainer"], "created_at": "2026-10-27T08:00:00Z"]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let body = requestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let query = json["query"] as? String, query.hasPrefix("query("), query.contains("views(first:30"),
           let variables = json["variables"] as? [String: Any], variables["id"] as? String == "fixture-project",
           request.url?.host == "api.github.com", request.url?.path == "/graphql", request.httpMethod == "POST" {
            Self.lock.lock(); Self.fixtureReads += 1; Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            let payload: [String: Any] = ["data": ["node": ["id": "fixture-project", "views": ["nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]]]
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.lock.lock(); Self.attempted += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}

    private func requestBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable && result.count < 65_536 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

@main struct ProjectWorkspaceLayoutFixture {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
        let fixtureLanguage = ProcessInfo.processInfo.environment["GITROCHI_PROJECT_LAYOUT_LANGUAGE"] ?? "en"
        let translationOnly = fixtureLanguage != "en"
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        precondition(URLProtocol.registerClass(ProjectFixtureNetworkBlocker.self), "Network isolation must be installed")
        defer {
            URLProtocol.unregisterClass(ProjectFixtureNetworkBlocker.self)
            projectFixtureDefaults.removePersistentDomain(forName: projectFixtureSuite)
            try? FileManager.default.removeItem(at: projectFixtureLocalStorageURL.deletingLastPathComponent())
        }
        projectFixtureDefaults.set(false, forKey: "avatarFetch")
        projectFixtureDefaults.set(fixtureLanguage, forKey: "appLanguage")
        precondition(Bundle.main.preferredLocalizations.first == fixtureLanguage, "Native fixture must launch in its requested language: \(Bundle.main.preferredLocalizations)")
        let account = HostAccount(id: "fixture-account", provider: .github, server: "https://github.com",
                                  username: "demo-developer", name: "Demo developer", avatarURL: nil)
        projectFixtureDefaults.set(try JSONEncoder().encode([account]), forKey: "accounts")
        let accounts = AccountStore.shared

        func settle(_ duration: TimeInterval = 0.2, host: NSView? = nil, window: NSWindow? = nil) {
            let deadline = Date().addingTimeInterval(duration)
            repeat {
                host?.layoutSubtreeIfNeeded()
                window?.displayIfNeeded()
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
                app.updateWindows()
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            } while Date() < deadline
            host?.layoutSubtreeIfNeeded()
        }
        let credentialDeadline = Date().addingTimeInterval(3)
        while accounts.credentialState(for: account) == .loading && Date() < credentialDeadline { settle(0.03) }
        precondition(accounts.credentialState(for: account) == .ready, "Synthetic credential must settle before context seeding")
        precondition(accounts.token(for: account) == "fixture-credential", "AccountStore must use the fixture reader")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func runAsync<T>(_ work: @escaping @MainActor () async throws -> T) throws -> T {
            var result: Result<T, Error>?
            Task { @MainActor in
                do { result = .success(try await work()) } catch { result = .failure(error) }
            }
            let deadline = Date().addingTimeInterval(12)
            while result == nil && Date() < deadline { settle(0.02) }
            guard let result else { fatalError("Isolated async fixture action did not settle") }
            return try result.get()
        }
        func rect(_ value: NSRect) -> [String: CGFloat] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        var checks: [[String: Any]] = []
        func fixtureWindow(_ root: AnyView, appearance: String, size: NSSize) -> (NSHostingController<AnyView>, NSWindow) {
            let host = NSHostingController(rootView: AnyView(root.tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89)).defaultAppStorage(projectFixtureDefaults).preferredColorScheme(appearance == "dark" ? .dark : .light)))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 100), size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Project interaction · Gitrochi"
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
            settle(0.3, host: host.view, window: window)
            return (host, window)
        }
        func keyEvent(_ window: NSWindow, code: UInt16 = 36, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            let characters = code == 53 ? "\u{1b}" : "\r"
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func fixtureFrames(_ view: NSView) -> [String: NSRect] {
            Dictionary(uniqueKeysWithValues: descendants(view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
        }
        @discardableResult func recordInteraction(_ scenario: String, view: NSView, extra: [String: Any] = [:]) throws -> NSBitmapImageRep {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Could not capture native interaction") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode native interaction") }
            let name = scenario + ".png"; try png.write(to: output.appendingPathComponent(name))
            var check = extra; check["scenario"] = scenario; check["screenshot"] = name; checks.append(check)
            return bitmap
        }
        func recognizedText(_ bitmap: NSBitmapImageRep) throws -> [String] {
            guard let image = bitmap.cgImage else { fatalError("Could not read native inspector pixels") }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        let localOnly = ProcessInfo.processInfo.environment["GITROCHI_PROJECT_LAYOUT_LOCAL_ONLY"] == "1" || translationOnly
        if !localOnly {
        for appearance in ["light", "dark"] {
            for size in [NSSize(width: 1080, height: 800), NSSize(width: 1440, height: 900)] {
                for empty in [false, true] {
                    let store = RepoStore()
                    store.target = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
                    store.booted = true
                    var detail = project()
                    if empty { detail.rows = [] }
                    store.hostingHub.section = .projects
                    store.hostingHub.selectedAccountID = account.id
                    store.hostingHub.items = [detail.item]
                    store.hostingHub.detail = detail
                    store.hostingHub.page = 1
                    store.hostingHub.context = store.hubContextStamp
                    projectFixtureDefaults.set("board", forKey: "projectWorkbench." + account.id + "." + detail.item.id + ".layout")
                    ProjectSchedulePreferences.save(ProjectScheduleSettings(startFieldID: "", dueFieldID: "due", statusFieldID: "status", completedOptionIDs: ["done"]), accountID: account.id, projectID: detail.item.id, defaults: projectFixtureDefaults)
                    let stamp = store.hubContextStamp
                    let scheme: ColorScheme = appearance == "dark" ? .dark : .light
                    let host = NSHostingController(rootView: ProjectWorkspace(store: store).environment(store)
                        .tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
                        .defaultAppStorage(projectFixtureDefaults).preferredColorScheme(scheme))
                    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 100), size: size),
                                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.title = "Projects · Gitrochi"
                    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                    window.toolbarStyle = .unified
                    window.toolbar = NSToolbar(identifier: "ProjectWorkspaceFixture")
                    window.contentViewController = host
                    RepositoryWindowLayout.configure(window)
                    window.setContentSize(size)
                    window.orderBack(nil)
                    settle(0.7, host: host.view, window: window)
                    let scenario = "\(empty ? "empty" : "board")-\(appearance)-\(Int(size.width))-\(Int(size.height))"
                    precondition(store.hubContextStamp == stamp && store.hostingHub.context == stamp,
                                 "Fixture context unexpectedly changed during \(scenario)")
                    precondition(store.hostingHub.error == nil && !store.hostingHub.loading && !store.hostingHub.detailLoading,
                                 "Synthetic project unexpectedly attempted to reload during \(scenario)")
                    precondition(ProjectFixtureNetworkBlocker.attempts == 0, "Rendering must not make any network requests")
                    precondition(ProjectFixtureNetworkBlocker.viewReads == checks.count + 1,
                                 "Shared views must load through the isolated fixture transport")
                    let probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                    let frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
                    precondition(frames["schedule-settings:done"] != nil, "A preloaded project must restore its persisted completion settings on first appearance")
                    guard let header = frames["project-header"], let board = frames["project-board"], let controls = frames["project-controls"], let addItem = frames["project-add-item"] else {
                        fatalError("Production project header, controls and board must render during \(scenario)")
                    }
                    let safe = window.contentLayoutRect
                    precondition(header.height >= 95 && header.width >= size.width - 2,
                                 "Project header is compressed during \(scenario): \(header)")
                    precondition(header.maxY <= safe.maxY + 1 && abs(header.maxY - safe.maxY) <= 1 && header.minY >= safe.minY,
                                 "Project header is clipped by native chrome during \(scenario): \(header), safe \(safe)")
                    precondition(header.minX >= safe.minX - 1 && header.maxX <= safe.maxX + 1,
                                 "Project header exceeds the content width during \(scenario)")
                    precondition(header.contains(addItem), "Add item must remain inside the visible project header")
                    precondition(board.height >= 280 && board.maxY <= header.minY && board.minY >= safe.minY,
                                 "Project controls leave too little board space during \(scenario): \(board)")
                    precondition(controls.height >= 50 && controls.height <= 180 && controls.minX >= safe.minX - 1 && controls.maxX <= safe.maxX + 1 && controls.maxY <= header.minY && controls.minY >= board.maxY,
                                 "Project controls are clipped or overlap the board during \(scenario): \(controls)")
                    let columns = frames.filter { $0.key.hasPrefix("column:") }.sorted { $0.value.minX < $1.value.minX }
                    precondition(columns.count == 4, "All four actual status columns must exist, including empty columns")
                    precondition(columns.prefix(3).allSatisfy { $0.value.minX >= safe.minX - 1 && $0.value.maxX <= safe.maxX + 1 },
                                 "The first three board columns must fit at the supported window sizes")
                    precondition(columns.allSatisfy { $0.value.maxY <= board.maxY + 1 && $0.value.height >= 180 },
                                 "Board columns are clipped or compressed during \(scenario)")
                    let emptyColumns = columns.filter { entry in
                        !detail.rows.contains { ($0.statuses["status"] ?? "") == String(entry.key.dropFirst("column:".count)) }
                    }
                    precondition(emptyColumns.allSatisfy { $0.value.height <= 240 }, "Empty board columns must keep a natural height during \(scenario)")
                    let cards = frames.filter { $0.key.hasPrefix("task:") }
                    precondition(cards.count == (empty ? 0 : detail.rows.count), "All synthetic task cards must be rendered")
                    precondition(cards.values.allSatisfy { $0.width >= 225 && $0.height >= 70 }, "Task cards must retain a readable size")
                    guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else {
                        fatalError("Could not allocate project screenshot")
                    }
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    let addLabel = host.view.convert(addItem, from: nil).insetBy(dx: 8, dy: 5)
                    let scaleX = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
                    let scaleY = CGFloat(bitmap.pixelsHigh) / host.view.bounds.height
                    let labelTop = host.view.isFlipped ? addLabel.minY : host.view.bounds.maxY - addLabel.maxY
                    var labelPixels = 0
                    for pixelY in max(0, Int(labelTop * scaleY))..<min(bitmap.pixelsHigh, Int((labelTop + addLabel.height) * scaleY)) {
                        for pixelX in max(0, Int(addLabel.minX * scaleX))..<min(bitmap.pixelsWide, Int(addLabel.maxX * scaleX)) {
                            if let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB),
                               color.redComponent > 0.82 && color.greenComponent > 0.82 && color.blueComponent > 0.82 {
                                labelPixels += 1
                            }
                        }
                    }
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode project screenshot") }
                    let name = scenario + ".png"
                    try png.write(to: output.appendingPathComponent(name))
                    precondition(labelPixels > 50, "Native Add item menu label disappeared against its accent background during \(scenario): \(labelPixels) white pixels")
                    checks.append(["scenario": scenario, "screenshot": name, "contentLayoutRect": rect(safe),
                                   "projectHeader": rect(header), "controls": rect(controls), "board": rect(board), "columnCount": columns.count,
                                   "addItemLabelPixels": labelPixels,
                                   "taskCount": cards.count, "contentSize": ["width": host.view.bounds.width, "height": host.view.bounds.height]])
                    window.orderOut(nil)
                    window.contentViewController = nil
                }
            }
        }
        for kind in ["overview", "calendar", "home", "home-week", "home-projects"] {
            let isHome = kind.hasPrefix("home")
            for appearance in ["light", "dark"] {
                for size in [NSSize(width: 1080, height: 800), NSSize(width: 1440, height: 900)] {
                    for empty in [false, true] {
                        var detail = project()
                        if empty { detail.rows = []; detail.fields = [] }
                        let today = ProjectSchedule.today()
                        for index in detail.rows.indices {
                            if index == 1 { detail.rows[index].values.removeValue(forKey: "due") }
                            else { detail.rows[index].values["due"] = ProjectSchedule.addDays(today, [-2, 0, 0, 1, 3, 5, 7, 0][index]) }
                        }
                        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
                        let root: AnyView
                        if isHome {
                            projectFixtureDefaults.set(kind == "home-week" ? "week" : kind == "home-projects" ? "projects" : "agenda", forKey: "homeFixtureMode")
                            let store = RepoStore()
                            store.booted = true
                            store.target = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
                            let portfolio = ProjectPortfolioState()
                            if !empty {
                                var secondary = detail
                                secondary.item.id = "fixture-secondary"; secondary.item.title = "Release readiness"
                                secondary.rows = Array(detail.rows.suffix(2))
                                secondary.rows.append(HubProjectRow(id: "secondary-draft", title: "Prepare a clear handoff for the next release", body: "", url: "", contentID: "", statuses: ["status": "progress"], kind: .draft,
                                                                    assignees: [], values: ["due": ProjectSchedule.addDays(today, 1) ?? today]))
                                portfolio.projects = [detail.item, secondary.item]
                                portfolio.details = [detail, secondary]
                                portfolio.selectedIDs = Set(portfolio.projects.map(\.id))
                                for project in portfolio.details { ProjectSchedulePreferences.save(ProjectScheduleSettings(completedOptionIDs: ["done"]), accountID: account.id, projectID: project.item.id, defaults: projectFixtureDefaults) }
                            }
                            root = AnyView(ScrollView { WorkspacePlanningDashboard(fixture: portfolio).padding(24) }.environment(store))
                        } else {
                            root = AnyView(ProjectScheduleFixtureHost(detail: detail, calendar: kind == "calendar"))
                        }
                        let host = NSHostingController(rootView: root
                            .tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
                            .defaultAppStorage(projectFixtureDefaults).preferredColorScheme(scheme))
                        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 100), size: size),
                                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.title = "Schedule · Gitrochi"
                        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "ProjectScheduleFixture")
                        window.contentViewController = host
                        RepositoryWindowLayout.configure(window)
                        window.setContentSize(size); window.orderBack(nil)
                        settle(0.55, host: host.view, window: window)
                        let scenario = "\(kind)-\(empty ? "empty" : "tasks")-\(appearance)-\(Int(size.width))-\(Int(size.height))"
                        let probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                        let frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
                        guard let workspace = frames["schedule-" + (isHome ? "home" : kind)] else { fatalError("Production schedule must render during \(scenario)") }
                        let safe = window.contentLayoutRect
                        if isHome {
                            precondition(workspace.width >= size.width - 50 && workspace.height >= 300, "Home planning must use its available content width")
                            precondition(workspace.maxY <= safe.maxY + 1 && workspace.minX >= safe.minX && workspace.maxX <= safe.maxX, "Native chrome clips Home planning during \(scenario)")
                        } else {
                            precondition(workspace.width >= size.width - 2 && workspace.height >= size.height - 2, "Schedule workspace must fill its viewport")
                            precondition(workspace.maxY <= safe.maxY + 1 && workspace.minY >= safe.minY - 1, "Native chrome clips schedule workspace during \(scenario)")
                        }
                        let cells = frames.filter { $0.key.hasPrefix("calendar-day:") }
                        let weekDays = frames.filter { $0.key.hasPrefix("home-week:") }
                        let projectCards = frames.filter { $0.key.hasPrefix("home-project:") }
                        if kind == "home-week" {
                            precondition(weekDays.count == 7, "Home week must expose all seven actual calendar days")
                            precondition(weekDays.values.allSatisfy { $0.width >= 170 && $0.height >= 165 }, "Home week columns must remain readable at narrow widths")
                            if size.width >= 1440 { precondition(weekDays.values.allSatisfy { $0.minX >= safe.minX && $0.maxX <= safe.maxX }, "All seven Home week columns must fit the wide viewport") }
                        }
                        if kind == "home-projects" { precondition(projectCards.count == (empty ? 0 : 2), "Home projects must show each selected synthetic project") }
                        if kind == "calendar", !empty {
                            precondition(cells.count >= 28, "A real calendar month must expose its days")
                            precondition(cells.values.allSatisfy { $0.width >= 88 && $0.height >= 100 }, "Calendar days must retain readable task space")
                            let firstWeek = cells.sorted { $0.key < $1.key }.prefix(7)
                            precondition(firstWeek.allSatisfy { $0.value.minX >= safe.minX - 1 && $0.value.maxX <= safe.maxX + 1 }, "The whole week must fit at supported widths")
                        }
                        precondition(ProjectFixtureNetworkBlocker.attempts == 0, "Schedule rendering must not make a network request")
                        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not allocate schedule screenshot") }
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode schedule screenshot") }
                        let name = scenario + ".png"; try png.write(to: output.appendingPathComponent(name))
                        checks.append(["scenario": scenario, "screenshot": name, "contentLayoutRect": rect(safe), "workspace": rect(workspace), "calendarDayCount": cells.count, "homeWeekDayCount": weekDays.count, "homeProjectCardCount": projectCards.count,
                                       "taskCount": detail.rows.count, "contentSize": ["width": host.view.bounds.width, "height": host.view.bounds.height]])
                        window.orderOut(nil); window.contentViewController = nil
                    }
                }
            }
        }
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1000, height: 800)] {
            let compact = size.width < 1080
            let store = RepoStore()
            store.booted = true
            store.target = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
            var detail = project()
            if let index = detail.fields.firstIndex(where: { $0.id == "due" }) { detail.fields[index].name = "Release checkpoint" }
            detail.fields.append(HubProjectField(id: "alternate-date", name: "Planning marker", options: [], kind: .date))
            for index in detail.rows.indices { detail.rows[index].values["due"] = ProjectSchedule.addDays(ProjectSchedule.today(), 2) }
            let settings = ProjectScheduleSettings(startFieldID: "", dueFieldID: "due", statusFieldID: "status", completedOptionIDs: ["done"])
            precondition(ProjectSchedule.fields(detail.fields).due == nil, "Fixture date fields must require an explicit choice")
            ProjectSchedulePreferences.save(settings, accountID: account.id, projectID: detail.item.id, defaults: projectFixtureDefaults)
            projectFixtureDefaults.set("overview", forKey: "projectWorkbench." + account.id + "." + detail.item.id + ".layout")
            store.hostingHub.section = .projects; store.hostingHub.selectedAccountID = account.id
            store.hostingHub.items = [detail.item]; store.hostingHub.detail = detail; store.hostingHub.page = 1
            store.hostingHub.context = store.hubContextStamp
            let requested = detail.rows.first { $0.kind == .draft }!
            store.hostingHub.requestedProjectRowID = requested.id
            let host = NSHostingController(rootView: ProjectWorkspace(store: store).environment(store)
                .tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
                .defaultAppStorage(projectFixtureDefaults).preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 100), size: size),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Preloaded project · Gitrochi"
            window.appearance = NSAppearance(named: .aqua); window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "PreloadedProjectFixture")
            window.contentViewController = host; RepositoryWindowLayout.configure(window); window.setContentSize(size); window.orderBack(nil)
            settle(0.8, host: host.view, window: window)
            let probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
            var frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
            if compact {
                precondition(window.sheets.count == 1, "A compact Home-preloaded task must open exactly one native inspector sheet")
                for sheet in window.sheets {
                    if let content = sheet.contentView {
                        for probe in descendants(content).compactMap({ $0 as? ProjectWorkspaceProbe.ProbeView }) {
                            frames[probe.fixtureIdentifier] = probe.convert(probe.bounds, to: nil)
                        }
                    }
                }
            }
            let capture = compact ? window.sheets.first?.contentView ?? host.view : host.view
            guard let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { fatalError("Could not allocate preloaded project screenshot") }
            capture.cacheDisplay(in: capture.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode preloaded project screenshot") }
            let name = compact ? "preloaded-overview-requested-draft-compact-light-1000-800.png" : "preloaded-overview-requested-draft-light-1440-900.png"
            try png.write(to: output.appendingPathComponent(name))
            precondition(frames["schedule-settings:done"] != nil && frames["schedule-config:due:6"] != nil,
                         "A Home-preloaded project must restore explicit date/completion preferences and show the real scheduled count")
            precondition(store.hostingHub.requestedProjectRowID == nil, "A preloaded task request must be consumed on first appearance")
            guard let inspector = frames["project-inspector:" + requested.id] else { fatalError("Home-preloaded draft must open its real inspector: " + frames.keys.sorted().joined(separator: ", ")) }
            precondition(inspector.width >= 300 && inspector.height >= 300 && inspector.maxX <= window.contentLayoutRect.maxX + 1,
                         "The preloaded task inspector must remain visible and readable")
            precondition(ProjectFixtureNetworkBlocker.attempts == 0, "Preloaded draft rendering must not request conversation or other live data")
            checks.append(["scenario": compact ? "preloaded-overview-requested-draft-compact" : "preloaded-overview-requested-draft", "screenshot": name, "restoredDueField": "due", "upcomingTasks": 6,
                           "requestedDraft": requested.id, "inspector": rect(inspector), "nativeSheetCount": window.sheets.count])
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil); window.contentViewController = nil
        }
        }
        accounts.fixtureClearAccounts()
        precondition(accounts.accounts.isEmpty, "Local planner scenarios must have no connected account")
        let localCredentialBaseline = ProjectFixtureCredentialCounter.reads
        let localNetworkBaseline = ProjectFixtureNetworkBlocker.attempts
        precondition(projectFixtureLocalStorageURL.path.hasPrefix(output.path + "/"), "Fixture local storage must never use real application data")
        let localStore = LocalProjectStore.shared
        let localItem = try runAsync { try await localStore.create(title: "Device launch plan", description: "A private plan, available without a GitHub account.") }
        var localDetail = try runAsync { try await localStore.detail(projectID: localItem.id) }
        for title in ["Prepare the release checklist", "Polish the planning workspace", "Verify the delivery notes", "Explore the next improvement"] {
            let previous = localDetail
            localDetail = try runAsync { try await localStore.saveDraft(detail: previous, title: title, body: "Keep the implementation focused and verify the result.") }
        }
        for (index, offset) in [(0, -1), (1, 2), (2, 1)] {
            let previous = localDetail, row = previous.rows[index], field = previous.fields.first { $0.id == "local-due" }!
            localDetail = try runAsync { try await localStore.updateField(detail: previous, row: row, field: field, value: ProjectSchedule.addDays(ProjectSchedule.today(), offset)) }
        }
        do {
            let previous = localDetail, row = previous.rows[2], field = previous.fields.first { $0.id == "local-status" }!
            localDetail = try runAsync { try await localStore.updateField(detail: previous, row: row, field: field, value: "local-done") }
        }
        let reloadedLocal = try runAsync { try await LocalProjectStore(storage: LocalProjectFileStorage(url: projectFixtureLocalStorageURL)).detail(projectID: localItem.id) }
        precondition(reloadedLocal.rows.count == 4 && reloadedLocal.rows[0].values["local-due"] == localDetail.rows[0].values["local-due"], "Actual local planner tasks must survive an independent store reload")
        if !translationOnly {
        for kind in ["overview", "calendar", "home"] {
            for appearance in ["light", "dark"] {
                let size = NSSize(width: 1440, height: 900), store = RepoStore()
                store.booted = true
                projectFixtureDefaults.set("local", forKey: "planningHome.projectSource")
                projectFixtureDefaults.set("agenda", forKey: "homeFixtureMode")
                let currentDetail = try runAsync { try await localStore.detail(projectID: localItem.id) }
                let requested = currentDetail.rows[1]
                let root: AnyView
                if kind == "home" {
                    store.navigate(.home, prepare: false)
                    root = AnyView(WorkspaceHomePanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(store))
                } else {
                    // Reproduce Home navigation from a non-project section before the actual workspace mounts.
                    store.hostingHub.section = .releases
                    store.hostingHub.projectSource = "local"
                    try runAsync {
                        await store.activateHostingHub(.projects)
                        await store.selectHostingHubItem(localItem)
                    }
                    precondition(store.hostingHub.context == store.hubContextStamp && store.hubAccount == nil && store.hubCredentialState == nil, "Entering local projects from another section must keep its account-free context")
                    projectFixtureDefaults.set(kind, forKey: "projectWorkbench.local." + localItem.id + ".layout")
                    if kind == "overview" { store.hostingHub.requestedProjectRowID = requested.id }
                    store.navigate(.projects, prepare: false)
                    root = AnyView(ProjectWorkspace(store: store).environment(store))
                }
                let host = NSHostingController(rootView: root.tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
                    .defaultAppStorage(projectFixtureDefaults).preferredColorScheme(appearance == "dark" ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 100), size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.title = "Local planning · Gitrochi"
                window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "LocalProjectFixture")
                window.contentViewController = host; RepositoryWindowLayout.configure(window); window.setContentSize(size); window.orderBack(nil)
                settle(0.8, host: host.view, window: window)
                var probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                var frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
                if kind == "home" {
                    precondition(frames["home-source:local"] != nil && frames["home-project-count:1"] != nil && frames["home-task-count:4"] != nil, "Home must load durable local tasks with no account and without an injected portfolio: " + frames.keys.sorted().joined(separator: ", "))
                    let fresh = try runAsync { try await localStore.detail(projectID: localItem.id) }
                    let updated = try runAsync { try await localStore.saveDraft(detail: fresh, title: "Confirm live local refresh", body: "") }
                    settle(0.5, host: host.view, window: window)
                    probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                    precondition(probes.contains { $0.fixtureIdentifier == "home-task-count:5" }, "Home must refresh after a durable local project revision changes")
                    _ = try runAsync { try await localStore.removeItem(detail: updated, row: updated.rows.last!) }
                    settle(0.5, host: host.view, window: window)
                    probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                    frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
                    precondition(frames["home-task-count:4"] != nil, "Home must settle back to the actual four local tasks")
                } else {
                    precondition(store.hostingHub.error == nil && frames["schedule-settings:local-done"] != nil && frames["schedule-config:local-due:1"] != nil, "Local workspace must restore useful date/completion defaults without setup")
                    precondition(frames[kind == "overview" ? "schedule-overview" : "schedule-calendar"] != nil, "The actual local scheduling view must render")
                    if kind == "overview" {
                        precondition(frames["project-inspector:" + requested.id] != nil && store.hostingHub.requestedProjectRowID == nil, "The exact local task must open and consume its navigation request after crossing sections")
                    }
                }
                precondition(ProjectFixtureCredentialCounter.reads == localCredentialBaseline && ProjectFixtureNetworkBlocker.attempts == localNetworkBaseline, "No-account local planning must never read credentials or attempt HTTP")
                guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not capture local planning") }
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                if kind == "home" {
                    guard let background = bitmap.colorAt(x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4)?.usingColorSpace(.deviceRGB) else { fatalError("Could not inspect Home background") }
                    precondition(background.alphaComponent > 0.99, "The actual Home host must provide an opaque native window background below its content")
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode local planning") }
                let name = "local-\(kind)-\(appearance)-1440-900.png"
                try png.write(to: output.appendingPathComponent(name))
                checks.append(["scenario": "local-\(kind)-\(appearance)", "screenshot": name, "connectedAccounts": accounts.accounts.count, "credentialReads": ProjectFixtureCredentialCounter.reads - localCredentialBaseline, "networkAttempts": ProjectFixtureNetworkBlocker.attempts - localNetworkBaseline, "durableTaskCount": 4, "storageIsolated": true])
                window.orderOut(nil); window.contentViewController = nil
            }
        }
        }
        let sparseItem = try runAsync { try await localStore.create(title: "Personal release plan", description: "A focused workspace with one task.") }
        let sparseEmpty = try runAsync { try await localStore.detail(projectID: sparseItem.id) }
        let sparseDetail = try runAsync { try await localStore.saveDraft(detail: sparseEmpty, title: "Prepare the draft", body: "Add the first useful task before choosing a date.") }
        precondition(sparseDetail.rows.count == 1 && ProjectSchedule.entries(sparseDetail.rows, fields: sparseDetail.fields).allSatisfy { $0.date == nil }, "Sparse fixture must contain exactly one durable, unscheduled task")
        for language in [fixtureLanguage] {
            precondition(language == "en" || Bundle.main.path(forResource: language, ofType: "lproj") != nil, "Sparse translated scenarios require real localization resources")
            for kind in ["board", "table", "roadmap"] {
                for appearance in ["light", "dark"] {
                    for size in [NSSize(width: 1080, height: 800), NSSize(width: 1440, height: 900)] {
                        let store = RepoStore()
                        store.booted = true
                        store.hostingHub.projectSource = "local"
                        try runAsync {
                            await store.activateHostingHub(.projects)
                            await store.selectHostingHubItem(sparseItem)
                        }
                        projectFixtureDefaults.set(kind, forKey: "projectWorkbench.local." + sparseItem.id + ".layout")
                        store.navigate(.projects, prepare: false)
                        let host = NSHostingController(rootView: ProjectWorkspace(store: store).environment(store)
                            .tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
                            .defaultAppStorage(projectFixtureDefaults).environment(\.locale, Locale(identifier: language))
                            .preferredColorScheme(appearance == "dark" ? .dark : .light))
                        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 100), size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.title = "Sparse project · Gitrochi"
                        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "SparseProjectFixture")
                        window.contentViewController = host; RepositoryWindowLayout.configure(window); window.setContentSize(size); window.orderBack(nil)
                        settle(0.65, host: host.view, window: window)
                        let scenario = "sparse-\(kind)-\(language)-\(appearance)-\(Int(size.width))-\(Int(size.height))"
                        let probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                        let frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
                        guard let header = frames["project-header"], let controls = frames["project-controls"], let addTask = frames["project-add-item"],
                              let surface = frames["project-" + kind] else { fatalError("Actual sparse project workspace is missing during \(scenario): " + frames.keys.sorted().joined(separator: ", ")) }
                        let safe = window.contentLayoutRect
                        precondition(header.maxY <= safe.maxY + 1 && abs(header.maxY - safe.maxY) <= 1 && header.minX >= safe.minX - 1 && header.maxX <= safe.maxX + 1 && header.contains(addTask), "Native chrome clips the sparse project header or new-task action during \(scenario)")
                        precondition(controls.maxY <= header.minY + 1 && controls.minY >= surface.maxY - 1 && controls.minX >= safe.minX - 1 && controls.maxX <= safe.maxX + 1, "Sparse project controls overlap another surface during \(scenario)")
                        precondition(surface.minY >= safe.minY - 1 && surface.maxY <= controls.minY + 1 && surface.width >= size.width - 2, "Sparse task surface is clipped during \(scenario)")
                        var measurements: [String: Any] = ["scenario": scenario, "language": language, "projectHeader": rect(header), "controls": rect(controls), "surface": rect(surface), "connectedAccounts": accounts.accounts.count, "taskCount": 1, "storageIsolated": true]
                        if kind == "board" {
                            let columns = frames.filter { $0.key.hasPrefix("column:") }
                            let cards = frames.filter { $0.key.hasPrefix("task:") }
                            let emptyColumns = columns.filter { $0.key != "column:local-todo" }
                            precondition(columns.count == 3 && cards.count == 1 && emptyColumns.count == 2, "Sparse board must show one card and both actual empty status columns")
                            precondition(emptyColumns.values.allSatisfy { $0.height >= 180 && $0.height <= 240 }, "Empty sparse board columns fill unused window height during \(scenario)")
                            precondition(columns.values.allSatisfy { $0.maxY <= surface.maxY + 1 && $0.minX >= safe.minX - 1 && $0.maxX <= safe.maxX + 1 }, "Sparse board columns are clipped during \(scenario)")
                            measurements["emptyColumnHeights"] = emptyColumns.values.map(\.height).sorted()
                            measurements["columnCount"] = columns.count
                        } else if kind == "table" {
                            guard let tableHeader = frames["project-table-header"], let row = frames["table-row:" + sparseDetail.rows[0].id] else { fatalError("Sparse table header and actual task row must render") }
                            let topGap = controls.minY - tableHeader.maxY
                            precondition(topGap >= 0 && topGap <= 36, "Sparse table header leaves a large blank area above its first row during \(scenario): \(topGap)")
                            precondition(abs(tableHeader.minY - row.maxY) <= 2 && row.height >= 44 && row.height <= 48, "Sparse table row must remain directly under its pinned header during \(scenario)")
                            measurements["tableHeader"] = rect(tableHeader); measurements["tableRow"] = rect(row); measurements["controlsToTableHeaderGap"] = topGap
                        } else {
                            guard let task = frames["roadmap-task:" + sparseDetail.rows[0].id], let action = frames["roadmap-schedule:" + sparseDetail.rows[0].id] else { fatalError("Sparse roadmap must render the actual unscheduled task and inline date action") }
                            let gap = action.minX - task.maxX
                            precondition(gap >= 0 && gap <= 24 && abs(action.midY - task.midY) <= 2 && action.maxX <= safe.maxX, "Sparse roadmap Schedule action must stay beside its task during \(scenario): \(gap)")
                            measurements["roadmapTask"] = rect(task); measurements["scheduleAction"] = rect(action); measurements["taskToScheduleActionGap"] = gap
                        }
                        precondition(ProjectFixtureCredentialCounter.reads == localCredentialBaseline && ProjectFixtureNetworkBlocker.attempts == localNetworkBaseline, "Sparse local scenarios must never read credentials or attempt HTTP")
                        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not capture sparse planning") }
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode sparse planning") }
                        let name = scenario + ".png"; try png.write(to: output.appendingPathComponent(name)); measurements["screenshot"] = name
                        checks.append(measurements)
                        window.orderOut(nil); window.contentViewController = nil
                    }
                }
            }
        }
        if !translationOnly {
        for appearance in ["light", "dark"] {
            for kind in ["date-editor", "destructive-review"] {
                var submittedValue: String?, submissionCount = 0
                let failure = "The change could not be saved. Your input is ready to retry."
                let root: AnyView
                let width: CGFloat
                if kind == "date-editor" {
                    let request = ProjectFieldRequest(row: sparseDetail.rows[0], field: sparseDetail.fields.first { $0.id == "local-due" }!)
                    root = AnyView(ProjectFieldEditor(request: request) { value in
                        await Task.yield(); submittedValue = value; submissionCount += 1; return failure
                    })
                    width = 500
                } else {
                    root = AnyView(ProjectActionReviewSheet(title: "Remove item from project?", project: sparseItem.title,
                        summary: "This removes the selected task from this local project.", items: [sparseDetail.rows[0].title], actionTitle: "Remove item", destructive: true) {
                            await Task.yield(); submissionCount += 1; return failure
                        })
                    width = 540
                }
                let host = NSHostingController(rootView: root.tint(Color(red: 0.43, green: 0.33, blue: 0.89))
                    .accentColor(Color(red: 0.43, green: 0.33, blue: 0.89)).defaultAppStorage(projectFixtureDefaults)
                    .preferredColorScheme(appearance == "dark" ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: -4000, y: 100, width: width, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.title = "Project action · Gitrochi"
                window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                window.contentViewController = host; window.orderBack(nil)
                settle(0.3, host: host.view, window: window)
                window.setContentSize(NSSize(width: width, height: host.view.fittingSize.height))
                settle(0.2, host: host.view, window: window)
                if kind == "date-editor" {
                    guard let field = descendants(host.view).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "YYYY-MM-DD" }) else { fatalError("The real typed-date text field must be exposed to native editing") }
                    precondition(window.makeFirstResponder(field), "The actual typed-date field must accept focus")
                    guard let editor = window.fieldEditor(true, for: field) as? NSTextView else { fatalError("The typed-date field must use the native text editor") }
                    editor.insertText("2026-11-05", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    window.makeFirstResponder(nil)
                    settle(0.2, host: host.view, window: window)
                    precondition(descendants(host.view).compactMap({ $0 as? ProjectWorkspaceProbe.ProbeView }).contains { $0.fixtureIdentifier == "field-editor-value:2026-11-05" }, "Typing YYYY-MM-DD must update the production date editor value")
                }
                for failed in [false, true] {
                    if failed {
                        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { fatalError("Could not construct the native default-action key event") }
                        precondition(window.performKeyEquivalent(with: event), "The valid native action must accept its Return keyboard shortcut")
                        settle(0.3, host: host.view, window: window)
                        window.setContentSize(NSSize(width: width, height: host.view.fittingSize.height))
                        settle(0.2, host: host.view, window: window)
                        precondition(submissionCount == 1 && (kind != "date-editor" || submittedValue == "2026-11-05"), "The actual editor must submit exactly one parsed date through its async callback")
                    }
                    let probes = descendants(host.view).compactMap { $0 as? ProjectWorkspaceProbe.ProbeView }
                    let frames = Dictionary(uniqueKeysWithValues: probes.map { ($0.fixtureIdentifier, $0.convert($0.bounds, to: nil)) })
                    let identifier = kind == "date-editor" ? "field-editor" : "action-review"
                    guard let content = frames[identifier] else { fatalError("The actual project action content must render") }
                    precondition(content.width == width && content.height >= 220 && content.maxY <= window.contentLayoutRect.maxY + 1 && content.minY >= window.contentLayoutRect.minY - 1, "Project action content must fit its native window")
                    precondition(frames[identifier + "-error:" + (failed ? failure : "none")] != nil, "An async failure must keep the editor and its input open with actionable feedback")
                    guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not capture project action") }
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode project action") }
                    let scenario = kind + (failed ? "-error-" : "-") + appearance, name = scenario + ".png"
                    try png.write(to: output.appendingPathComponent(name))
                    checks.append(["scenario": scenario, "screenshot": name, "content": rect(content), "submissionCount": submissionCount, "typedDate": submittedValue ?? "", "asyncFailurePreservesInput": failed])
                }
                window.orderOut(nil); window.contentViewController = nil
            }
        }
        }
        if !translationOnly {
            for appearance in ["light", "dark"] {
                projectFixtureDefaults.set(true, forKey: "quickAddFixtureOpen")
                let gate = ProjectQuickAddFixtureGate(), failure = "The task could not be saved. Keep the title and try again."
                let column = HubProjectColumn(id: "local-progress", title: "In progress", rows: [])
                let root = AnyView(ProjectBoardColumn(column: column, index: 1, width: 340, height: 210, localRepository: "", selectedID: nil,
                    fields: sparseDetail.fields, select: { _ in }, add: { fatalError("An available inline action must not open the full composer") }, move: { _ in false },
                    quickAdd: { await gate.submit($0) }, canEdit: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20).background(Color(nsColor: .windowBackgroundColor)))
                let (host, window) = fixtureWindow(root, appearance: appearance, size: NSSize(width: 380, height: 520))
                precondition(fixtureFrames(host.view)["quick-add-form:local-progress"] != nil, "The actual In progress column must expose its inline form")
                try recordInteraction("quick-add-editing-" + appearance, view: host.view, extra: ["column": column.id, "submissionCount": gate.titles.count])
                guard let field = descendants(host.view).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Task title" }) else { fatalError("The actual inline Task title field must render") }
                precondition(window.makeFirstResponder(field), "Quick-add title must accept native focus")
                guard let editor = window.fieldEditor(true, for: field) as? NSTextView else { fatalError("Quick-add must use native text editing") }
                editor.insertText("  Plan the next checkpoint  ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                window.sendEvent(keyEvent(window)); settle(0.18, host: host.view, window: window)
                precondition(gate.titles == ["Plan the next checkpoint"] && fixtureFrames(host.view)["quick-add-saving:true"] != nil, "Return must create one trimmed title in the chosen column and show its pending state")
                window.sendEvent(keyEvent(window)); settle(0.1, host: host.view, window: window)
                precondition(gate.titles.count == 1, "A second Return while saving must not create a duplicate task")
                try recordInteraction("quick-add-saving-" + appearance, view: host.view, extra: ["column": column.id, "submissionCount": gate.titles.count, "submittedTitle": gate.titles[0]])
                gate.fail(failure); settle(0.2, host: host.view, window: window)
                let failed = fixtureFrames(host.view)
                precondition(failed["quick-add-error:" + failure] != nil && failed["quick-add-title:  Plan the next checkpoint  "] != nil && failed["quick-add-saving:false"] != nil, "A failed inline write must retain its title and actionable error")
                try recordInteraction("quick-add-error-" + appearance, view: host.view, extra: ["submissionCount": gate.titles.count, "inputPreserved": true])
                guard let freshField = descendants(host.view).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Task title" }) else { fatalError("Failed quick-add input must remain editable") }
                window.makeFirstResponder(freshField); window.sendEvent(keyEvent(window, code: 53)); settle(0.2, host: host.view, window: window)
                precondition(fixtureFrames(host.view)["quick-add-form:local-progress"] == nil && gate.titles.count == 1, "Escape must cancel the retained inline form without another write")
                try recordInteraction("quick-add-cancelled-" + appearance, view: host.view, extra: ["submissionCount": gate.titles.count, "escapeClosedForm": true])
                window.orderOut(nil); window.contentViewController = nil
                projectFixtureDefaults.set(false, forKey: "quickAddFixtureOpen")
            }
            for appearance in ["light", "dark"] {
                let store = RepoStore(); store.booted = true; store.hostingHub.projectSource = "local"
                var detail = sparseDetail, row = sparseDetail.rows[0]
                row.assignees = ["demo-developer"]; row.values["local-assignees"] = "demo-developer"; row.state = "OPEN"; detail.rows = [row]
                let root = AnyView(ProjectTaskInspector(store: store, detail: detail, row: row, close: {}, editField: { _ in }, editDraft: {}, archive: {}, remove: {}, reorder: { _ in }, convert: { _ in }, setField: { _, _ in nil }).environment(store))
                let (host, window) = fixtureWindow(root, appearance: appearance, size: NSSize(width: 390, height: 740))
                let frames = fixtureFrames(host.view)
                precondition(frames["inspector-field:local-status:options:3"] != nil && frames["inspector-field:local-priority:options:4"] != nil && frames["inspector-field:local-due:sheet"] != nil, "Local inspector must use actual status/priority options while dates retain the date editor")
                let bitmap = try recordInteraction("inspector-local-" + appearance, view: host.view, extra: ["actualStatusOptions": 3, "actualPriorityOptions": 4, "localRawStateHidden": true])
                let labels = try recognizedText(bitmap)
                precondition(!labels.contains("State") && !labels.contains("Open") && !labels.contains("OPEN") && labels.filter { $0 == "Assignees" }.count == 1, "Local metadata must hide raw Open state and show the built-in assignees field once: " + labels.joined(separator: ", "))
                window.orderOut(nil); window.contentViewController = nil
            }
            accounts.fixtureSetAccounts([account])
            for appearance in ["light", "dark"] {
                let store = RepoStore(); store.booted = true
                store.target = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
                store.hostingHub.section = .projects; store.hostingHub.projectSource = "remote"; store.hostingHub.selectedAccountID = account.id
                var detail = project()
                var row = detail.rows[0]; row.id = "fixture-conversation"; row.number = 401; row.title = "Review the project workflow"; row.body = "Plan the release together and keep the work easy to follow."
                row.url = "https://github.com/sample-studio/desktop/issues/401"; row.author = "demo-maintainer"; row.createdAt = "2026-10-27T08:00:00Z"
                detail.fields = Array(detail.fields.prefix(2)); detail.rows = [row]
                store.hostingHub.items = [detail.item]; store.hostingHub.detail = detail; store.hostingHub.context = store.hubContextStamp
                var postCount = 0, postSucceeds = false
                let failure = "The comment could not be saved. Your text is ready to retry."
                let root = AnyView(ProjectTaskInspector(store: store, detail: detail, row: row, close: {}, editField: { _ in }, editDraft: {}, archive: {}, remove: {}, reorder: { _ in }, convert: { _ in }, setField: { _, _ in nil }, postComment: { _ in await Task.yield(); postCount += 1; return postSucceeds ? nil : failure }).environment(store))
                let (host, window) = fixtureWindow(root, appearance: appearance, size: NSSize(width: 420, height: 1000))
                settle(0.3, host: host.view, window: window)
                precondition(fixtureFrames(host.view)["inspector-comments:2"] != nil, "The actual API must read both synthetic comments with author and created-at metadata")
                try recordInteraction("conversation-loaded-" + appearance, view: host.view, extra: ["actualReadComments": 2, "commentPosts": postCount, "syntheticTransport": true])
                guard let editor = descendants(host.view).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && !$0.isFieldEditor }) else { fatalError("The actual linked-issue comment editor must render") }
                window.makeFirstResponder(editor)
                editor.insertText("Keep this comment until the server accepts it.", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                settle(0.12, host: host.view, window: window)
                precondition(window.performKeyEquivalent(with: keyEvent(window, modifiers: .command)), "Cmd+Return must invoke the actual Comment action")
                settle(0.25, host: host.view, window: window)
                let failed = fixtureFrames(host.view)
                precondition(postCount == 1 && failed["inspector-comments:2"] != nil && failed["inspector-comment-text:Keep this comment until the server accepts it."] != nil && failed["inspector-comment-error:" + failure] != nil, "A failed post must retain existing comments, typed text, and its error without an automatic retry")
                try recordInteraction("conversation-error-" + appearance, view: host.view, extra: ["actualReadComments": 2, "commentPosts": postCount, "inputPreserved": true, "syntheticTransport": true])
                postSucceeds = true
                precondition(window.performKeyEquivalent(with: keyEvent(window, modifiers: .command)), "A deliberate retry must use the actual Comment action")
                settle(0.4, host: host.view, window: window)
                let posted = fixtureFrames(host.view)
                precondition(postCount == 2 && posted["inspector-comment-text:"] != nil && posted["inspector-comment-posted:true"] != nil && posted["inspector-comments:2"] != nil, "A successful post must clear the draft and show factual confirmation without inventing an appended comment")
                try recordInteraction("conversation-success-" + appearance, view: host.view, extra: ["actualReadComments": 2, "commentPosts": postCount, "successNoticeVerified": true, "syntheticTransport": true])
                guard let freshEditor = descendants(host.view).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && !$0.isFieldEditor }) else { fatalError("A successful post must leave its editor available") }
                window.makeFirstResponder(freshEditor)
                freshEditor.insertText("Start another comment.", replacementRange: NSRange(location: 0, length: freshEditor.string.utf16.count))
                settle(0.12, host: host.view, window: window)
                precondition(fixtureFrames(host.view)["inspector-comment-posted:false"] != nil, "Typing the next comment must clear the previous success notice")
                window.orderOut(nil); window.contentViewController = nil
            }
        }
        precondition(ProjectFixtureCredentialCounter.reads == localCredentialBaseline && ProjectFixtureNetworkBlocker.attempts == localNetworkBaseline, "Project interaction checks must stay isolated from real credentials and HTTP")
        let result: [String: Any] = ["ok": true, "productionViews": ["ProjectWorkspace", "ProjectWorkspaceHeader", "ProjectTaskCard", "ProjectTaskTable", "ProjectRoadmap", "ProjectDashboard", "ProjectCalendar", "WorkspaceHomePanel", "WorkspacePlanningDashboard", "ProjectFieldEditor", "ProjectActionReviewSheet"],
                                     "syntheticAccount": true, "networkRequests": ProjectFixtureNetworkBlocker.attempts,
                                     "syntheticSharedViewReads": ProjectFixtureNetworkBlocker.viewReads,
                                     "localOnly": localOnly,
                                     "language": fixtureLanguage,
                                     "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("result-" + fixtureLanguage + ".json"))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func project() -> HubDetail {
        let item = HubItem(id: "fixture-project", title: "Desktop experience", subtitle: "#12",
                           body: "A calmer workspace from planning to the next pull request.",
                           url: "https://github.com/users/demo-developer/projects/12", editable: true,
                           data: ["readme": "## Release goals\nKeep planning close to the code.\n\n- Smooth project navigation\n- Confident local Git actions"])
        let status = HubProjectField(id: "status", name: "Status", options: [
            HubProjectOption(id: "backlog", name: "Backlog"), HubProjectOption(id: "progress", name: "In progress"),
            HubProjectOption(id: "review", name: "In review"), HubProjectOption(id: "done", name: "Done")])
        let priority = HubProjectField(id: "priority", name: "Priority", options: [
            HubProjectOption(id: "high", name: "High"), HubProjectOption(id: "normal", name: "Normal")])
        var detail = HubDetail(item: item)
        detail.fields = [status, priority, HubProjectField(id: "points", name: "Points", options: [], kind: .number),
                         HubProjectField(id: "due", name: "Target date", options: [], kind: .date),
                         HubProjectField(id: "notes", name: "Notes", options: [], kind: .text)]
        let tasks: [(String, String, HubProjectRowKind, String, [String], String)] = [
            ("101", "Add keyboard shortcuts for planning and local work", .issue, "backlog", ["enhancement", "accessibility"], "demo-developer"),
            ("102", "Explore a compact task detail panel", .draft, "backlog", ["design"], "demo-designer"),
            ("103", "Keep restored project workspaces below the native tab bar", .issue, "progress", ["bug", "macOS"], "demo-developer"),
            ("104", "Bring local branches into the project workflow", .pullRequest, "progress", ["feature", "workflow"], "demo-maintainer"),
            ("105", "Polish task cards in light and dark appearances", .pullRequest, "review", ["design", "ready for review"], "demo-designer"),
            ("106", "Make empty status columns useful from the first task", .issue, "review", ["good first issue"], "demo-developer"),
            ("107", "Keep account access responsive while projects load", .issue, "done", ["reliability"], "demo-maintainer"),
            ("108", "Document the release checklist", .draft, "done", ["documentation"], "demo-designer")]
        detail.rows = tasks.enumerated().map { index, task in
            let (number, title, kind, state, labels, assignee) = task
            return HubProjectRow(id: "task-" + number, title: title, body: "A focused task with the context needed to start work.\n\n- Review the current behavior\n- Verify the result in both appearances", url: kind == .draft ? "" : "https://github.com/sample-studio/desktop/\(kind == .pullRequest ? "pull" : "issues")/\(number)", contentID: "content-" + number,
                                 statuses: ["status": state], labels: kind == .draft ? [] : labels, kind: kind, number: kind == .draft ? nil : Int(number),
                                 repository: kind == .draft ? "" : "sample-studio/desktop", state: kind == .draft ? "" : (state == "done" ? "CLOSED" : "OPEN"),
                                 assignees: [assignee], updatedAt: "2026-10-26T12:\(String(format: "%02d", index)):00Z",
                                 headRefName: kind == .pullRequest ? "feature/task-" + number : "",
                                 values: ["status": state, "priority": index % 2 == 0 ? "high" : "normal", "points": String(index % 5 + 1), "due": "2026-11-02", "notes": "Ready for implementation"])
        }
        return detail
    }
}
