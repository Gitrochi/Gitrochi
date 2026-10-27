import AppKit
import SwiftUI

let projectCreationFixtureSuite = "dev.gitrochi.project-creation-fixture." + UUID().uuidString
let projectCreationFixtureDefaults = UserDefaults(suiteName: projectCreationFixtureSuite)!
let projectCreationFixtureCase = CommandLine.arguments.dropFirst(2).first ?? "local"
let projectCreationFixtureReview = projectCreationFixtureCase.hasSuffix("-review")
let projectCreationFixtureScenario = projectCreationFixtureReview ? String(projectCreationFixtureCase.dropLast("-review".count)) : projectCreationFixtureCase
let projectCreationFixtureNeedsRecovery = ["unavailable", "authorization-required"].contains(projectCreationFixtureScenario)
let projectCreationFixtureMode = projectCreationFixtureScenario == "local" ? "local" : projectCreationFixtureScenario == "public-pro" ? "public" : "private"
let projectCreationFixtureSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProjectCreationFixtureNetworkBlocker.self]
    return URLSession(configuration: configuration)
}()

actor ProjectCreationFixtureStorage: LocalProjectPersistence {
    func read() -> String? { nil }
    func write(expected: String?, content: String) throws { fatalError("Creation layout must never save local data") }
}

/// Probes attach to temporary source copies, so the production chooser needs no test-only properties.
struct ProjectCreationProbe: NSViewRepresentable {
    let identifier: String
    final class ProbeView: NSView {
        var fixtureIdentifier: String
        init(identifier: String) { fixtureIdentifier = identifier; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    func makeNSView(context: Context) -> NSView { ProbeView(identifier: identifier) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ProbeView)?.fixtureIdentifier = identifier }
}

/// Only the exact capability reads are answered. Mutations and every other request fail before networking.
final class ProjectCreationFixtureNetworkBlocker: URLProtocol {
    private static let lock = NSLock()
    private static var blocked = 0, users = 0, owners = 0, credentials = 0
    static var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return ["blocked": blocked, "users": users, "owners": owners, "credentials": credentials] }
    static func credentialRead() -> CredentialReadResult {
        lock.lock(); credentials += 1; lock.unlock()
        if projectCreationFixtureScenario == "unavailable" { return CredentialReadResult(value: nil, status: -25300) }
        if projectCreationFixtureScenario == "authorization-required" { return CredentialReadResult(value: nil, status: -25308) }
        return CredentialReadResult(value: "fixture-credential", status: 0)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var payload: [String: Any]?
        if request.url?.host == "api.github.com", request.httpMethod == "GET", request.url?.path == "/user" {
            Self.lock.lock(); Self.users += 1; Self.lock.unlock()
            var viewer: [String: Any] = ["login": "demo-developer"]
            if projectCreationFixtureScenario != "unknown" { viewer["plan"] = ["name": projectCreationFixtureScenario == "public-pro" ? "pro" : "free"] }
            payload = viewer
        } else if request.url?.host == "api.github.com", request.httpMethod == "POST", request.url?.path == "/graphql",
                  let body = requestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  json["query"] as? String == "query($owner:String!){repositoryOwner(login:$owner){__typename id login}}",
                  (json["variables"] as? [String: Any])?["owner"] as? String == "demo-developer" {
            Self.lock.lock(); Self.owners += 1; Self.lock.unlock()
            payload = ["data": ["repositoryOwner": ["__typename": "User", "id": "fixture-owner", "login": "demo-developer"]]]
        }
        guard let payload, let url = request.url else {
            Self.lock.lock(); Self.blocked += 1; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private func requestBody() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable && result.count < 65_536 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }; result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

@main struct ProjectCreationLayoutFixture {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
        let appearance = CommandLine.arguments.dropFirst(3).first ?? "light"
        let sheetHeight: CGFloat = projectCreationFixtureReview ? 520 : 680
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        precondition(URLProtocol.registerClass(ProjectCreationFixtureNetworkBlocker.self), "Network blocker must install before account access")
        defer { URLProtocol.unregisterClass(ProjectCreationFixtureNetworkBlocker.self); projectCreationFixtureSession.invalidateAndCancel(); projectCreationFixtureDefaults.removePersistentDomain(forName: projectCreationFixtureSuite) }
        projectCreationFixtureDefaults.set(false, forKey: "avatarFetch")
        projectCreationFixtureDefaults.set("en", forKey: "appLanguage")
        let account = HostAccount(id: "fixture-account", provider: .github, server: "https://github.com", username: "demo-developer", name: "Demo developer", avatarURL: nil)
        projectCreationFixtureDefaults.set(try JSONEncoder().encode(projectCreationFixtureScenario == "local" ? [] : [account]), forKey: "accounts")
        let accounts = AccountStore.shared
        func settle(_ duration: TimeInterval = 0.05, host: NSView? = nil, window: NSWindow? = nil) {
            let deadline = Date().addingTimeInterval(duration)
            repeat {
                host?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
                app.updateWindows(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
        }
        if projectCreationFixtureScenario != "local" {
            let deadline = Date().addingTimeInterval(3)
            while accounts.credentialState(for: account) == .loading && Date() < deadline { settle() }
            let expected: CredentialCache.State = projectCreationFixtureScenario == "unavailable" ? .unavailable : projectCreationFixtureScenario == "authorization-required" ? .authorizationRequired : .ready
            precondition(accounts.credentialState(for: account) == expected, "Fixture credential state must settle without real Keychain access")
        } else { precondition(accounts.accounts.isEmpty, "Local chooser must work with no account") }
        let store = RepoStore(); store.booted = true
        let host = NSHostingController(rootView: ProjectCreationSheet(store: store) { _ in fatalError("Layout fixture must never create a project") }
            .environment(store).defaultAppStorage(projectCreationFixtureDefaults)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
            .preferredColorScheme(appearance == "dark" ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 100, width: 760, height: sheetHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentViewController = host; window.setContentSize(NSSize(width: 760, height: sheetHeight)); window.orderBack(nil)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func probes() -> [ProjectCreationProbe.ProbeView] { descendants(host.view).compactMap { $0 as? ProjectCreationProbe.ProbeView } }
        let deadline = Date().addingTimeInterval(5)
        let reviewIdentifier = "creation-review:" + String(!projectCreationFixtureNeedsRecovery)
        while !probes().contains(where: { $0.fixtureIdentifier == reviewIdentifier }) && Date() < deadline { settle(0.05, host: host.view, window: window) }
        settle(0.25, host: host.view, window: window)
        let measured = probes(), state = measured.first { $0.fixtureIdentifier.hasPrefix("creation-state:") }?.fixtureIdentifier ?? "missing"
        precondition(measured.contains { $0.fixtureIdentifier == reviewIdentifier }, "Creation readiness must match actual saved-account access: " + state)
        let choices = measured.filter { $0.fixtureIdentifier.hasPrefix("creation-choice:") }
        precondition(choices.count == (projectCreationFixtureReview ? 0 : 3), "Form offers all project types; review presents the chosen destination")
        let bounds = host.view.bounds
        for choice in choices {
            let frame = choice.convert(choice.bounds, to: host.view)
            precondition(frame.width >= 200 && frame.height >= 144 && bounds.insetBy(dx: -1, dy: -1).contains(frame), "Creation choice must fit and remain readable")
        }
        if projectCreationFixtureReview {
            guard let review = measured.first(where: { $0.fixtureIdentifier == "creation-review-content" }) else { fatalError("Inline creation review must render") }
            let frame = review.convert(review.bounds, to: host.view)
            precondition(frame.width >= 650 && frame.height >= 160 && bounds.insetBy(dx: -1, dy: -1).contains(frame), "Creation review must fit and keep its destination readable")
        }
        if projectCreationFixtureNeedsRecovery {
            guard let notice = measured.first(where: { $0.fixtureIdentifier == "creation-saved-access-notice" }),
                  let restore = measured.first(where: { $0.fixtureIdentifier == "creation-restore-access" }) else { fatalError("Every unreadable saved account must offer the actual restore action") }
            let noticeFrame = notice.convert(notice.bounds, to: host.view), restoreFrame = restore.convert(restore.bounds, to: host.view)
            precondition(bounds.insetBy(dx: -1, dy: -1).contains(noticeFrame) && noticeFrame.insetBy(dx: -1, dy: -1).contains(restoreFrame) && restoreFrame.width >= 100 && restoreFrame.height >= 16, "Saved-account recovery must remain visible inside the creation viewport")
            let settings = measured.first(where: { $0.fixtureIdentifier == "creation-account-settings" })
            precondition((settings != nil) == (projectCreationFixtureScenario == "unavailable"), "Unavailable credentials must offer account settings while authorization recovery keeps the saved-account action")
            if let settings {
                precondition(bounds.insetBy(dx: -1, dy: -1).contains(settings.convert(settings.bounds, to: host.view)), "The actual account-settings action must remain visible")
            }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            _ = window.performKeyEquivalent(with: event)
            settle(0.12, host: host.view, window: window)
            precondition(probes().contains { $0.fixtureIdentifier == "creation-review:false" } && !probes().contains { $0.fixtureIdentifier == "creation-review-content" }, "Return must not advance into review without a usable saved credential")
        }
        let expectedPlan = projectCreationFixtureScenario == "local" || projectCreationFixtureNeedsRecovery ? "none" : projectCreationFixtureScenario == "unknown" ? "unknown" : projectCreationFixtureScenario == "public-pro" ? "pro" : "free"
        precondition(state.contains(":" + expectedPlan + ":" + expectedPlan + ":"), "Account/owner plan must match the actual capability probe")
        if projectCreationFixtureScenario != "local", !projectCreationFixtureNeedsRecovery { precondition(state.hasSuffix(expectedPlan == "unknown" ? ":50:unknown" : expectedPlan == "pro" ? ":50:5" : ":50:1"), "Field/workflow limits must match the exposed plan") }
        let counts = ProjectCreationFixtureNetworkBlocker.counts
        precondition(counts["blocked"] == 0, "Unexpected network operation during creation rendering")
        let expectedReads = projectCreationFixtureScenario == "local" || projectCreationFixtureNeedsRecovery ? 0 : 1
        precondition(counts["users"] == expectedReads && counts["owners"] == expectedReads, "Capability reads must be skipped until the saved account is ready")
        if projectCreationFixtureScenario == "local" { precondition(counts["credentials"] == 0, "Local creation must not read saved credentials") }
        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("Could not allocate creation screenshot") }
        host.view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode creation screenshot") }
        let scenario = projectCreationFixtureCase + "-" + appearance
        try png.write(to: output.appendingPathComponent(scenario + ".png"))
        let result: [String: Any] = ["ok": true, "scenario": scenario, "state": state, "choices": choices.count, "reviewStage": projectCreationFixtureReview, "reviewEnabled": !projectCreationFixtureNeedsRecovery, "savedAccessRecovery": projectCreationFixtureNeedsRecovery, "restoreActionVisible": measured.contains { $0.fixtureIdentifier == "creation-restore-access" }, "settingsActionVisible": measured.contains { $0.fixtureIdentifier == "creation-account-settings" }, "network": counts, "screenshot": scenario + ".png"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: output.appendingPathComponent(scenario + ".json")); print(String(decoding: data, as: UTF8.self))
        window.orderOut(nil); window.contentViewController = nil
    }
}
