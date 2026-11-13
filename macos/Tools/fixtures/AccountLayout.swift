import AppKit
import SwiftUI

let accountFixtureSuite = "dev.gitrochi.account-layout-fixture." + UUID().uuidString
let accountFixtureDefaults = UserDefaults(suiteName: accountFixtureSuite)!
let accountFixtureScenario = CommandLine.arguments.dropFirst(2).first ?? "repository"
let accountFixtureSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AccountFixtureNetworkBlocker.self]
    return URLSession(configuration: configuration)
}()
let accountFixtureIdentities = [
    Gitch.Account(id: "demo-alex", email: "alex@example.com", hosts: "github.com, ssh.github.com(port 443)", rules: "~/Develop/personal", sshKey: true),
    Gitch.Account(id: "alex-studio", email: "alex@studio.example", hosts: "github.com", rules: "organization github.com/studio", sshKey: true),
]

/// Probes attach to temporary source copies, so the production views need no test-only properties.
struct AccountLayoutProbe: NSViewRepresentable {
    let identifier: String
    final class ProbeView: NSView {
        var fixtureIdentifier: String
        init(identifier: String) { fixtureIdentifier = identifier; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    func makeNSView(context: Context) -> NSView { ProbeView(identifier: identifier) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ProbeView)?.fixtureIdentifier = identifier }
}

/// One drawn profile photo is served for the fixture's avatar address. Everything else fails before networking, and
/// saved credentials are answered from the account's fixture name instead of the Keychain.
final class AccountFixtureNetworkBlocker: URLProtocol {
    private static let lock = NSLock()
    private static var blocked = 0, photos = 0
    static var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return ["blocked": blocked, "photos": photos] }
    static let photoURL = "https://avatars.example.com/demo-alex.png"
    /// A Git identity on github.com without a connected profile takes the public one
    static let publicPhotoURL = "https://github.com/alex-studio.png?size=64"
    static func credentialRead(_ name: String) -> CredentialReadResult {
        if name.hasSuffix("-approval") { return CredentialReadResult(value: nil, status: -25308) }
        if name.hasSuffix("-expired") { return CredentialReadResult(value: nil, status: -25300) }
        return CredentialReadResult(value: "fixture-credential", status: 0)
    }
    private static let photo: Data = {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(calibratedRed: 0.87, green: 0.89, blue: 0.92, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedRed: 0.56, green: 0.60, blue: 0.65, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 21, y: 26, width: 22, height: 22)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10, y: -24, width: 44, height: 44)).fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, [Self.photoURL, Self.publicPhotoURL].contains(url.absoluteString), request.httpMethod == "GET" else {
            Self.lock.lock(); Self.blocked += 1; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        Self.lock.lock(); Self.photos += 1; Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.photo)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct AccountLayoutFixture {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
        let appearance = CommandLine.arguments.dropFirst(3).first ?? "light"
        let scenario = accountFixtureScenario
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        precondition(URLProtocol.registerClass(AccountFixtureNetworkBlocker.self), "Network blocker must install before account access")
        defer { URLProtocol.unregisterClass(AccountFixtureNetworkBlocker.self); accountFixtureSession.invalidateAndCancel(); accountFixtureDefaults.removePersistentDomain(forName: accountFixtureSuite) }
        accountFixtureDefaults.set("en", forKey: "appLanguage")

        // the rules the views draw from (Windows: tests/account-presentation.test.ts)
        let alice = HostAccount(id: "alice", provider: .github, server: "https://github.com", username: "alice", name: nil, avatarURL: nil)
        let bob = HostAccount(id: "bob", provider: .github, server: "https://github.com", username: "bob", name: nil, avatarURL: nil)
        let mirror = HostAccount(id: "carol", provider: .github, server: "https://git.example.com", username: "carol", name: nil, avatarURL: nil)
        let rules = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
        precondition(!AccountPresentation.toolbarBadge(nil) && !AccountPresentation.toolbarBadge(.signedIn), "No badge without a repository account or while it is signed in")
        precondition([.needsApproval, .needsYourApproval, .expired].allSatisfy { AccountPresentation.toolbarBadge($0) }, "Every state that needs the user badges the button")
        precondition(AccountPresentation.reason(account: alice, target: rules, candidates: [alice], preferredID: nil) == .matches(repository: "sample-studio/desktop"), "The only account matches the repository")
        precondition(AccountPresentation.reason(account: alice, target: rules, candidates: [alice, bob], preferredID: nil) == .first(host: "github.com"), "The first of several accounts")
        precondition(AccountPresentation.reason(account: bob, target: rules, candidates: [alice, bob], preferredID: "bob") == .chosen, "The user's choice wins")
        precondition(AccountPresentation.reason(account: alice, target: rules, candidates: [alice, bob], preferredID: "gone") == .first(host: "github.com"), "A choice for another account does not explain this one")
        precondition(AccountPresentation.reason(account: mirror, target: rules, candidates: [mirror], preferredID: nil) == .sameServer(host: "github.com"), "Another address of the same server")
        precondition(AccountPresentation.initial(name: "Alex Kim", username: "demo-alex") == "A" && AccountPresentation.initial(name: nil, username: "demo-alex") == "D"
            && AccountPresentation.initial(name: "  ", username: "zoe") == "Z" && AccountPresentation.initial(name: "", username: "") == "?", "The initial comes from the name, else the username")
        let statuses: [AccountStatus] = [.signedIn, .needsApproval, .needsYourApproval, .expired]
        precondition(Set(statuses.map(\.symbol) + ["lock"]).count == 5 && Set(statuses.map(\.title)).count == 4, "Each state has its own icon and words")
        let drawings = ["lock.shield", "key", "lock"].compactMap { DesignSymbols.image($0)?.tiffRepresentation }
        precondition(drawings.count == 3 && Set(drawings).count == 3, "Needs approval, Needs your approval and Locked must each have their own drawing")

        let demo = HostAccount(id: "fixture-demo", provider: .github, server: "https://github.com", username: "demo-alex", name: "Personal", avatarURL: AccountFixtureNetworkBlocker.photoURL)
        let studio = HostAccount(id: "fixture-studio-approval", provider: .github, server: "https://github.com", username: "alex-studio", name: "Studio organization", avatarURL: nil)
        let lab = HostAccount(id: "fixture-lab-expired", provider: .gitlab, server: "https://gitlab.example.com", username: "alex", name: nil, avatarURL: nil)
        let long = HostAccount(id: "fixture-long", provider: .gitlab, server: "https://gitlab-with-a-long-server-name.example.com", username: "a-very-long-account-name-that-wraps", name: nil, avatarURL: nil)
        let saved = scenario == "no-account" ? [] : scenario == "locked" ? [demo, studio, lab, long] : [demo, studio, lab]
        accountFixtureDefaults.set(try JSONEncoder().encode(saved), forKey: "accounts")
        let accounts = AccountStore.shared

        func settle(_ duration: TimeInterval = 0.05, host: NSView? = nil, window: NSWindow? = nil) {
            let deadline = Date().addingTimeInterval(duration)
            repeat {
                host?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
                app.updateWindows(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
        }
        let loaded = Date().addingTimeInterval(3)
        while saved.contains(where: { accounts.credentialState(for: $0) == .loading }) && Date() < loaded { settle() }
        if !saved.isEmpty {
            precondition(accounts.status(for: demo) == .signedIn && accounts.status(for: studio) == .needsYourApproval && accounts.status(for: lab) == .expired,
                         "Fixture credential states must settle without real Keychain access")
        }

        let connected = accounts.accounts(for: .github) + accounts.accounts(for: .gitlab)
        let own: HostAccount? = scenario == "attention" ? studio : scenario == "expired" ? lab : ["repository", "locked"].contains(scenario) ? demo : nil
        let target = own.map { RepoTarget(provider: $0.provider, remote: "origin", host: $0.host, path: "sample-studio/desktop") }
        let repository: AccountPopoverRepository? = own.map { account in
            AccountPopoverRepository(target: target, account: account, candidates: connected.filter { $0.provider == account.provider && $0.host == account.host },
                                     preferredID: scenario == "attention" ? account.id : nil, identity: Identity(name: "Alex Kim", email: "alex@example.com"),
                                     managed: true, locked: scenario == "locked")
        }
        let badge = AccountPresentation.toolbarBadge(own.map { accounts.status(for: $0) })
        var resolved: [String] = []
        let size: CGSize
        let content: AnyView
        switch scenario {
        case "settings":
            size = CGSize(width: 600, height: 560)
            content = AnyView(AccountsSettings().frame(width: size.width, height: size.height))
        case "add-account", "add-gitlab":
            let sheet = AddAccountSheet(provider: scenario == "add-gitlab" ? .gitlab : .github, server: scenario == "add-gitlab" ? "https://gitlab.example.com" : nil,
                                        signInWithBrowser: { resolved.append("browser") })
            content = AnyView(sheet)
            size = NSHostingController(rootView: sheet).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        default:
            // the toolbar button over its popover, as the window shows them
            let view = VStack(alignment: .trailing, spacing: 8) {
                AccountButtonPhoto(account: own ?? connected.first, badge: badge).frame(width: 36, height: 36)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.08), radius: 3, y: 2))
                    .padding(.trailing, 8)
                AccountPopover(repository: repository, accounts: connected, status: { accounts.status(for: $0) },
                               actions: AccountPopoverActions(resolve: { account, _ in resolved.append(account.id) }))
                    .background(RoundedRectangle(cornerRadius: 12).fill(StudioStyle.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.border))
            }
            .padding(12)
            content = AnyView(view)
            size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        }
        let host = NSHostingController(rootView: content
            .defaultAppStorage(accountFixtureDefaults)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(Color(red: 0.43, green: 0.33, blue: 0.89)).accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
            .preferredColorScheme(appearance == "dark" ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func probes() -> [AccountLayoutProbe.ProbeView] { descendants(host.view).compactMap { $0 as? AccountLayoutProbe.ProbeView } }
        func frame(_ identifier: String) -> CGRect? {
            probes().first { $0.fixtureIdentifier == identifier }.map { $0.convert($0.bounds, to: host.view) }
        }
        func has(_ prefix: String) -> Bool { probes().contains { $0.fixtureIdentifier.hasPrefix(prefix) } }
        settle(0.4, host: host.view, window: window)
        // the one profile photo arrives off the main thread and is then drawn from the cache everywhere
        let pictured = Date().addingTimeInterval(3)
        if !saved.isEmpty, scenario != "add-account", scenario != "add-gitlab" {
            // Settings also shows the identity that has only a public profile
            let expected = scenario == "settings" ? 2 : 1
            while AccountPhotoStore.shared.version < expected && Date() < pictured { settle(0.05, host: host.view, window: window) }
            precondition(AccountPhotoStore.shared.version == expected && AccountFixtureNetworkBlocker.counts["photos"] == expected, "Each profile photo must be fetched once and reused")
            settle(0.2, host: host.view, window: window)
        }
        let bounds = host.view.bounds.insetBy(dx: -1, dy: -1)
        for probe in probes() {
            let rect = probe.convert(probe.bounds, to: host.view)
            precondition(bounds.contains(rect), "Nothing may be clipped: \(probe.fixtureIdentifier) \(rect) in \(host.view.bounds)")
        }

        switch scenario {
        case "settings":
            for account in saved { precondition(frame("settings-status:" + account.id) != nil && frame("settings-more:" + account.id) != nil, "Each hosting account shows its state and its ⋯ menu") }
            precondition(frame("accounts-settings-add") != nil && frame("accounts-settings-add-identity") != nil, "Both lists keep their add button")
            precondition(!has("action:"), "Settings rows draw their own actions")
        case "add-account", "add-gitlab":
            guard let sheet = frame("sheet") else { fatalError("The Add account sheet must use the shared sheet layout") }
            precondition(abs(sheet.width - 520) <= 1, "The Add account sheet keeps its width: \(sheet.width)")
            precondition(frame(scenario == "add-gitlab" ? "primary:Connect" : "primary:Sign in with the browser…") != nil, "The sheet's one filled button must be the next step")
        default:
            guard let popover = frame("popover") else { fatalError("The popover must render") }
            precondition(abs(popover.width - AccountPopover.width) <= 1, "The popover is 360 pt wide: \(popover.width)")
            precondition((frame("badge") != nil) == badge && badge == ["attention", "expired"].contains(scenario), "The badge is for the repository's own account only")
            precondition((frame("change") != nil) == (own != nil), "Change… belongs to the repository's account")
            precondition((frame("identity") != nil) == (own != nil), "The Git identity is shown with a repository")
            for probe in probes() where probe.fixtureIdentifier.hasPrefix("words:") {
                precondition(probe.bounds.width >= 120, "A row's words must not be squeezed: \(probe.fixtureIdentifier) \(probe.bounds.width)")
            }
            if let own {
                // the notice above carries the repository account's action; other rows carry their own
                precondition(frame("action:" + own.id) == nil, "The repository's row keeps Change… only")
                precondition(has("notice-action:") == badge, "A repository account that needs the user gets the notice")
                if scenario == "attention" { precondition(frame("notice-action:Approve…") != nil, "The saved sign-in is approved from the notice") }
                if scenario == "expired" { precondition(frame("notice-action:Sign in again…") != nil, "An expired sign-in offers to sign in again") }
            }
            if scenario == "repository" {
                precondition(frame("action:" + studio.id) != nil && frame("action:" + lab.id) != nil, "Another account's state comes with its action")
                precondition(frame("status:key") != nil && frame("status:exclamationmark.triangle.fill") != nil, "Each state draws its own icon")
            }
            if scenario == "locked" {
                precondition(frame("status:lock") != nil, "A locked identity shows the lock")
                guard let row = frame("row:" + long.id), let short = frame("row:" + demo.id) else { fatalError("The long account row must render") }
                precondition(row.height > 44 && short.height >= 52, "A long name wraps and the row grows: \(row.height)")
            }
            if scenario == "no-account" { precondition(probes().allSatisfy { !$0.fixtureIdentifier.hasPrefix("row:") }, "Without an account there are no rows") }
        }
        precondition(AccountFixtureNetworkBlocker.counts["blocked"] == 0, "Unexpected network operation while rendering accounts")
        precondition(resolved.isEmpty, "Rendering must not run an action")

        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not allocate the screenshot") }
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode the screenshot") }
        try png.write(to: output.appendingPathComponent("account-" + scenario + "-" + appearance + ".png"))
        print("PASS account " + scenario + " " + appearance)
        fflush(stdout)
        window.orderOut(nil); window.contentViewController = nil
    }
}
