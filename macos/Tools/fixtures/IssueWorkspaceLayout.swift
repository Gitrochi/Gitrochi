import AppKit
import SwiftUI
import Observation
import Vision

typealias ViewState<Value> = SwiftUI.State<Value>
struct Avatar: View { let name: String; let email: String; var size: CGFloat = 28; var body: some View { Text(String(name.prefix(1)).uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).frame(width: size, height: size).background(Color.accentColor.opacity(0.15), in: Circle()) } }
@MainActor final class AccountStore { static let shared = AccountStore(); var revision = 0 }
@MainActor enum CollaborationAPI {
    static func issueLinkedRequests(_ access: ReviewAccess, item: CollaborationInboxItem, page: Int) async throws -> ([IssueLinkedRequest], Bool) { (fixtureLinkedRequests, false) }
}
struct IssueLinkedRequest: Identifiable { var id: String { url }; let number: Int; let title: String; let url: String; let state: String }
let fixtureLinkedRequests = [IssueLinkedRequest(number: 58, title: "Preserve search state across repositories", url: "https://github.com/sample-studio/desktop/pull/58", state: "open")]
@MainActor @Observable final class RepoStore {
    var collaboration = CollaborationState()
    var target: RepoTarget? = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
    var url: URL? = URL(fileURLWithPath: "/fixture/desktop")
    var headBranch: String? = "feature/42-workspace-search"
    var headHash: String? = "fixture-head"
    var busy: String? = nil
    var localBranches: [Branch] = []
    var hostingAccount: HostAccount? = nil
    var issueContextKey = "fixture"
    var sheet: SheetKind?
    var issueAccess: ReviewAccess? { ReviewAccess(target: target!, token: "fixture", apiBase: "", me: "demo-maintainer") }
    func issueTask(_ item: CollaborationInboxItem) -> ProjectTaskReference? { IssueWorkflow.task(target: target, number: item.number, title: item.title, url: item.url) }
    func requestIssueBranch(_ item: CollaborationInboxItem) {}
    func requestIssuePullRequest(_ item: CollaborationInboxItem) {}
    func confirmIssueState(_ item: CollaborationInboxItem) {}
    func confirmDeleteIssueComment(_ item: CollaborationInboxItem, comment: CollaborationInboxComment) {}
    func changeIssueComment(_ item: CollaborationInboxItem, comment: CollaborationInboxComment, body: String?) async -> Bool { false }
    func openInboxItem(_ item: CollaborationInboxItem, append: Bool = false) async {}
    func inboxAction(_ item: CollaborationInboxItem, action: String, body: String) async -> Bool { false }
    func checkout(_ branch: Branch) async {}
}
@main struct IssueWorkspaceLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [400.0, 660.0] {
            for dark in [false, true] {
                let store = RepoStore()
                let item = CollaborationInboxItem(id: "issue-42", kind: "issue", number: 42, title: "Make workspace search easier to use", url: "https://github.com/sample-studio/desktop/issues/42", body: "## A faster path to your project\n\nKeep search results clear and make keyboard navigation predictable.\n\n- [x] Group results by repository\n- [ ] Keep the current selection", state: "open", author: "demo-maintainer", createdAt: "2026-10-27T09:00:00Z")
                let detail = CollaborationInboxDetail(item: item, comments: [CollaborationInboxComment(id: "12", author: "demo-reviewer", body: "The **keyboard shortcuts** feel much clearer now. Could we keep the search query when switching repositories?", createdAt: "2026-10-28T09:00:00Z"), CollaborationInboxComment(id: "13", author: "demo-maintainer", body: "Yes, that is covered by the linked pull request.\n\n> Keep the query and the active selection together.", createdAt: "2026-10-28T10:00:00Z", editable: true)])
                store.collaboration.inboxDetail = detail
                let bounds = NSRect(x: 0, y: 0, width: width, height: 1100)
                let host = NSHostingView(rootView: IssueDetailView(detail: detail).environment(store).frame(width: width, height: 1100).background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, Locale(identifier: "en_US")).preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0)); window.contentView = host; host.frame = bounds; window.orderBack(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }; host.cacheDisplay(in: bounds, to: bitmap)
                guard let image = bitmap.representation(using: .png, properties: [:]) else { fatalError("No image") }
                let name = "macos-issues-\(Int(width))-\(dark ? "dark" : "light").png"; try image.write(to: output.appendingPathComponent(name))
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; try VNImageRequestHandler(data: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                precondition(text.contains("Make workspace search") && text.contains("Development") && text.contains("Create branch"), "Issue workflow missing: \(name)\n\(text)")
                window.orderOut(nil)
            }
        }
        print("Issue workspace: production issue, development and comment layouts rendered at 400/660 points in light/dark with isolated data")
    }
}
