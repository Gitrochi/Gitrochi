import AppKit
import SwiftUI

let projectFixtureSuite = "dev.gitrochi.project-workspace-fixture." + UUID().uuidString
let projectFixtureDefaults = UserDefaults(suiteName: projectFixtureSuite)!

/// Measurements are attached only to temporary copies of production view sources.
struct ProjectWorkspaceProbe: NSViewRepresentable {
    let identifier: String

    final class ProbeView: NSView {
        let fixtureIdentifier: String
        init(identifier: String) {
            fixtureIdentifier = identifier
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    func makeNSView(context: Context) -> NSView { ProbeView(identifier: identifier) }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        precondition(URLProtocol.registerClass(ProjectFixtureNetworkBlocker.self), "Network isolation must be installed")
        defer {
            URLProtocol.unregisterClass(ProjectFixtureNetworkBlocker.self)
            projectFixtureDefaults.removePersistentDomain(forName: projectFixtureSuite)
        }
        projectFixtureDefaults.set(false, forKey: "avatarFetch")
        projectFixtureDefaults.set("en", forKey: "appLanguage")
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
        func rect(_ value: NSRect) -> [String: CGFloat] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        var checks: [[String: Any]] = []
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
                    precondition(columns.allSatisfy { $0.value.maxY <= board.maxY + 1 && $0.value.height >= 280 },
                                 "Board columns are clipped or compressed during \(scenario)")
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
                    precondition(labelPixels > 50, "Native Add item menu label disappeared against its accent background during \(scenario)")
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode project screenshot") }
                    let name = scenario + ".png"
                    try png.write(to: output.appendingPathComponent(name))
                    checks.append(["scenario": scenario, "screenshot": name, "contentLayoutRect": rect(safe),
                                   "projectHeader": rect(header), "controls": rect(controls), "board": rect(board), "columnCount": columns.count,
                                   "addItemLabelPixels": labelPixels,
                                   "taskCount": cards.count, "contentSize": ["width": host.view.bounds.width, "height": host.view.bounds.height]])
                    window.orderOut(nil)
                    window.contentViewController = nil
                }
            }
        }
        let result: [String: Any] = ["ok": true, "productionViews": ["ProjectWorkspace", "ProjectTaskCard"],
                                     "syntheticAccount": true, "networkRequests": ProjectFixtureNetworkBlocker.attempts,
                                     "syntheticSharedViewReads": ProjectFixtureNetworkBlocker.viewReads,
                                     "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("result.json"))
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
