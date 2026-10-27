import SwiftUI
import AppKit
import Vision

let requestFixtureSuite = "dev.gitrochi.request-layout." + UUID().uuidString
let requestFixtureDefaults = UserDefaults(suiteName: requestFixtureSuite)!
@MainActor var requestFixtureDetailTab = "conversation"
@MainActor let requestFixtureChecks = RequestCheckResults(checks: [
    RequestCheck(id: "build", name: "Build macOS", status: .success, detail: "All 128 tests passed", url: "https://github.com/team/repo/actions/runs/1/job/101", jobID: 101),
    RequestCheck(id: "security", name: "External security", status: .failed, detail: "One dependency needs an update", url: "https://ci.example.invalid/security"),
    RequestCheck(id: "lint", name: "Swift formatting", status: .running, detail: "Checking changed files")
])
@MainActor let requestFixtureImage: NSImage = {
    NSImage(size: NSSize(width: 560, height: 125), flipped: false) { bounds in
        NSColor(calibratedRed: 0.91, green: 0.89, blue: 0.99, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27, weight: .semibold), .foregroundColor: NSColor(calibratedRed: 0.27, green: 0.19, blue: 0.52, alpha: 1)]
        ("Review preview image" as NSString).draw(at: NSPoint(x: 28, y: 48), withAttributes: attributes)
        return true
    }
}()

@MainActor let requestFixtureAvatar: NSImage = {
    NSImage(size: NSSize(width: 84, height: 84), flipped: false) { bounds in
        NSColor(calibratedRed: 0.76, green: 0.84, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.53, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 15, y: -15, width: 54, height: 52)).fill()
        NSColor(calibratedRed: 0.91, green: 0.68, blue: 0.53, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 27, y: 33, width: 30, height: 36)).fill()
        NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 26, y: 55, width: 33, height: 18), xRadius: 9, yRadius: 9).fill()
        return true
    }
}()

/// Deterministic stand-in that preserves the loaded-image and initials branches of HostingAvatar.
struct RequestFixtureAvatarImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url; self.content = content
    }

    var body: some View {
        if let url {
            content(.success(Image(nsImage: url.lastPathComponent == "organization.png" ? requestFixtureOrganizationLogo : requestFixtureAvatar)))
        } else {
            content(.empty)
        }
    }
}

@MainActor let requestFixtureOrganizationLogo: NSImage = {
    NSImage(size: NSSize(width: 128, height: 128), flipped: false) { bounds in
        NSColor(calibratedRed: 0.39, green: 0.25, blue: 0.88, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.setStroke()
        let connections = NSBezierPath()
        connections.lineWidth = 10
        connections.move(to: NSPoint(x: 38, y: 30)); connections.line(to: NSPoint(x: 38, y: 94))
        connections.move(to: NSPoint(x: 38, y: 62)); connections.curve(to: NSPoint(x: 91, y: 94), controlPoint1: NSPoint(x: 73, y: 62), controlPoint2: NSPoint(x: 91, y: 62))
        connections.stroke()
        NSColor.white.setFill()
        for point in [NSPoint(x: 38, y: 30), NSPoint(x: 38, y: 94), NSPoint(x: 91, y: 94)] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)).fill()
        }
        return true
    }
}()

/// Actual PR browser/detail and organization lists, headers and member cards, isolated from accounts and network services.
@main struct RequestLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        requestFixtureDefaults.set(true, forKey: "avatarFetch")
        defer { requestFixtureDefaults.removePersistentDomain(forName: requestFixtureSuite) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let account = HostAccount(id: "fixture", provider: .github, server: "https://github.com", username: "alex", name: "Alex Kim", avatarURL: nil)
        AccountStore.shared.fixtureAccounts([account])
        let target = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/Gitrochi")
        let sha = String(repeating: "a", count: 40)
        var results: [[String: Any]] = []
        let allScenarios = ["conversation", "checks", "organizations", "members", "empty"]
        let requestedScenarios = ProcessInfo.processInfo.environment["GITROCHI_REQUEST_LAYOUT_SCENARIOS"]
            .map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        if let requestedScenarios {
            precondition(!requestedScenarios.isEmpty && requestedScenarios.isSubset(of: Set(allScenarios)), "Unknown or empty fixture scenario filter")
        }
        let scenarios = allScenarios.filter { requestedScenarios?.contains($0) ?? true }
        for scenario in scenarios {
            requestFixtureDetailTab = scenario == "checks" ? "checks" : "conversation"
            for width: CGFloat in [1080, 700] {
                for dark in [false, true] {
                    let store = RepoStore()
                    store.fixtureRepository(); store.target = target
                    store.destination = .pullRequests
                    store.pullRequests = [
                        PullRequest(number: 42, title: "Review workspace refresh", author: "alex", source: "codex/member-profiles", target: "main", url: "https://github.com/team/Gitrochi/pull/42", isDraft: false, updated: Date(timeIntervalSince1970: 1_792_973_000), body: "## Implementation notes\n\nShow **member profiles** and keep requests easy to review.\n\n![Review preview](https://example.invalid/review.png)\n\n- [x] Member profiles\n- [x] Readable conversations", headSHA: sha, fromFork: false),
                        PullRequest(number: 41, title: "Fix a very long organization member display name in narrow panels", author: "sam", source: "fix/member-display", target: "main", url: "https://github.com/team/Gitrochi/pull/41", isDraft: false, updated: nil, body: "", headSHA: "b", fromFork: true),
                        PullRequest(number: 40, title: "Improve request checks", author: "morgan", source: "ci/checks", target: "main", url: "https://github.com/team/Gitrochi/pull/40", isDraft: true, updated: nil, body: "", headSHA: "c", fromFork: false)
                    ]
                    store.prState = .loaded; store.selection = .pullRequest(42)
                    if scenario == "empty" { store.pullRequests = []; store.selection = nil }
                    store.review = PullRequestReview(number: 42, repositoryKey: ReviewAPI.repositoryKey(target), refs: ReviewRefs(headSHA: sha, baseSHA: "b", startSHA: "b"), comments: [
                        ReviewComment(id: "one", author: "sam", body: "Looks ready. The **profile cards** read clearly.", date: nil, threadID: "one", replyID: 1),
                        ReviewComment(id: "two", author: "morgan", body: "Please keep the fallback initials for missing avatars.", date: nil, path: "HostingHubPanel.swift", line: 154, threadID: "two", replyID: 2, resolvable: true),
                    ], state: ReviewState(approvedBy: ["sam"]))
                    store.collaboration.lifecycle = RequestLifecycle(number: 42, headSHA: sha, state: "open", title: "Review workspace refresh", body: "", base: "main", reviewers: ["sam", "morgan"], methods: ["squash", "merge"], blockers: ["One check still needs attention."], checks: "2 checks complete", policy: "The server enforces branch rules.", canEdit: true, canRebase: false)
                    var organization = HubItem(id: "team", title: "Gitrochi team", subtitle: "team", body: "The people building Gitrochi.", url: "https://github.com/team")
                    organization.avatarURL = URL(string: "https://example.invalid/organization.png")
                    store.hostingHub.section = .organizations; store.hostingHub.page = 1; store.hostingHub.selectedAccountID = account.id
                    store.hostingHub.items = [
                        organization,
                        HubItem(id: "studio", title: "Studio", subtitle: "studio"),
                        HubItem(id: "design", title: "Studio with a very long organization display name", subtitle: "studio-design"),
                        HubItem(id: "orchard", title: "Orchard-Team", subtitle: "Orchard-Team"),
                        HubItem(id: "daily", title: "DailyStudio", subtitle: "DailyStudio"),
                        HubItem(id: "cloud", title: "CloudWorkshop", subtitle: "CloudWorkshop"),
                        HubItem(id: "ios", title: "Demo-iOS", subtitle: "Demo-iOS"),
                        HubItem(id: "canvas", title: "Canvas-Lab", subtitle: "Canvas-Lab"),
                    ]
                    store.hostingHub.tab = scenario == "members" ? "members" : "repositories"
                    store.hostingHub.detail = HubDetail(item: organization, members: [
                        HubMember(id: "alex", name: "Alex Kim", role: "Maintainer", username: "alex", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"), profileURL: URL(string: "https://github.com/alex")),
                        HubMember(id: "sam", name: "Sam Lee", role: "Member", username: "sam", profileURL: URL(string: "https://github.com/sam")),
                        HubMember(id: "morgan", name: "Morgan Rivera with a long display name", role: "Developer", username: "morgan-rivera", profileURL: URL(string: "https://github.com/morgan-rivera")),
                    ], repositories: scenario == "organizations" ? [
                        HubRepository(id: "gitrochi", name: "team/Gitrochi", description: "Desktop Git client for clear collaboration.", cloneURL: "https://github.com/team/Gitrochi.git", url: "https://github.com/team/Gitrochi"),
                        HubRepository(id: "ios", name: "team/Gitrochi-iOS", description: "Companion app for iOS.", cloneURL: "https://github.com/team/Gitrochi-iOS.git", url: "https://github.com/team/Gitrochi-iOS"),
                        HubRepository(id: "design", name: "team/Design", description: "Shared design resources.", cloneURL: "https://github.com/team/Design.git", url: "https://github.com/team/Design"),
                    ] : [])
                    let view = ["organizations", "members"].contains(scenario) ? AnyView(HostingHubPanel(store: store, section: .organizations)) : AnyView(WorkspaceDestinationContent())
                    let bounds = NSRect(x: 0, y: 0, width: width, height: 1200)
                    let host = NSHostingView(rootView: view.environment(store).defaultAppStorage(requestFixtureDefaults)
                        .frame(width: width, height: bounds.height).background(Color(nsColor: .windowBackgroundColor))
                        .preferredColorScheme(dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: bounds.height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host; host.frame = bounds; window.orderBack(nil)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
                    host.cacheDisplay(in: bounds, to: bitmap)
                    let data = bitmap.representation(using: .png, properties: [:])!
                    let name = "request-\(scenario)-\(Int(width))-\(dark ? "dark" : "light").png"
                    try data.write(to: output.appendingPathComponent(name))
                    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(data: data).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    let expected = scenario == "organizations" ? ["Gitrochi team", "Studio", "Repositories", "team/Gitrochi", "Desktop Git client", "Copy clone URL"] : scenario == "members" ? ["Alex Kim", "Sam Lee", "Maintainer", "Members"] : scenario == "checks" ? ["Review workspace refresh", "Build macOS", "External security", "TESTS PASSED"] : scenario == "empty" ? ["No pull requests match this filter", "Select a pull request"] : ["Review workspace refresh", "Implementation notes", "Review preview image", "Looks ready", "Approve"]
                    try text.write(to: output.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                    for value in expected { precondition(text.localizedCaseInsensitiveContains(value), "Missing \(value): \(name)\n\(text)") }
                    results.append(["scenario": scenario, "width": width, "theme": dark ? "dark" : "light", "screenshot": name, "expectedTextVisible": true])
                    window.orderOut(nil); window.contentView = nil
                }
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print("PASS: \(scenarios.joined(separator: ", ")) at 1080/700 points, light/dark. \(output.path)")
    }
}
