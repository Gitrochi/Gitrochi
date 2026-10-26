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

/// Actual PR browser/detail and organization member cards, isolated from accounts and network services.
@main struct RequestLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        requestFixtureDefaults.set(false, forKey: "avatarFetch")
        defer { requestFixtureDefaults.removePersistentDomain(forName: requestFixtureSuite) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let account = HostAccount(id: "fixture", provider: .github, server: "https://github.com", username: "alex", name: "Alex Kim", avatarURL: nil)
        AccountStore.shared.fixtureAccounts([account])
        let target = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/Gitrochi")
        let sha = String(repeating: "a", count: 40)
        var results: [[String: Any]] = []
        for scenario in ["conversation", "checks", "members", "empty"] {
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
                    let organization = HubItem(id: "team", title: "Gitrochi team", subtitle: "team", body: "The people building Gitrochi.", url: "https://github.com/team")
                    store.hostingHub.section = .organizations; store.hostingHub.page = 1; store.hostingHub.selectedAccountID = account.id
                    store.hostingHub.items = [organization, HubItem(id: "studio", title: "Studio", subtitle: "studio")]
                    store.hostingHub.tab = "members"
                    store.hostingHub.detail = HubDetail(item: organization, members: [
                        HubMember(id: "alex", name: "Alex Kim", role: "Maintainer", username: "alex", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"), profileURL: URL(string: "https://github.com/alex")),
                        HubMember(id: "sam", name: "Sam Lee", role: "Member", username: "sam", profileURL: URL(string: "https://github.com/sam")),
                        HubMember(id: "morgan", name: "Morgan Rivera with a long display name", role: "Developer", username: "morgan-rivera", profileURL: URL(string: "https://github.com/morgan-rivera")),
                    ])
                    let view = scenario == "members" ? AnyView(HostingHubPanel(store: store, section: .organizations)) : AnyView(WorkspaceDestinationContent())
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
                    let expected = scenario == "members" ? ["Alex Kim", "Sam Lee", "Maintainer", "Members"] : scenario == "checks" ? ["Review workspace refresh", "Build macOS", "External security", "TESTS PASSED"] : scenario == "empty" ? ["No matching requests", "Try another filter", "Select a pull request"] : ["Review workspace refresh", "Implementation notes", "Review preview image", "Looks ready", "Approve"]
                    try text.write(to: output.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                    for value in expected { precondition(text.localizedCaseInsensitiveContains(value), "Missing \(value): \(name)\n\(text)") }
                    results.append(["scenario": scenario, "width": width, "theme": dark ? "dark" : "light", "screenshot": name, "expectedTextVisible": true])
                    window.orderOut(nil); window.contentView = nil
                }
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print("PASS: actual PR conversations/checks/logs and organization cards at 1080/700 points, light/dark. \(output.path)")
    }
}
