import AppKit
import SwiftUI
import Observation
import Vision

typealias ViewState<Value> = SwiftUI.State<Value>
enum FixtureCredentialState { case ready, loading }
struct CredentialAccessNotice: View { let account: HostAccount; var body: some View { EmptyView() } }
struct GitResult { let status: Int32; let output: String }
enum Git {
    static func run(_ args: [String], in directory: URL, ok: Set<Int32>) async throws -> GitResult {
        precondition(args.first == "rev-list")
        return GitResult(status: 0, output: args.contains("--left-right") ? "0\t42" : "12")
    }
}
@MainActor enum HostingHubAPI {
    static func safeURL(provider: Provider, host: String, _ value: String, asset: Bool = false) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == host, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func delete(_ access: HubAccess, section: HostingHubSection, item: HubItem) async throws { fatalError("Fixture attempted a write") }
    static func saveRelease(_ access: HubAccess, _ input: HubReleaseInput, previous: HubItem?) async throws { fatalError("Fixture attempted a write") }
}
@MainActor @Observable final class RepoStore {
    var hostingHub = HostingHubState()
    var target: RepoTarget? = RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "sample-studio/desktop")
    var tags = [Tag(name: "v1.9.0", target: "fixture-head")]
    var headHash: String? = "fixture-head"
    var headBranch: String? = "feature/workspace-search-results"
    var url: URL? = URL(fileURLWithPath: "/fixture/desktop")
    var hubAccount: HostAccount? = nil
    var hubCredentialState: FixtureCredentialState? = .ready
    var pendingHubCredentialAccount: HostAccount? = nil
    var hubProvider: Provider = .github
    var hubActionStamp = "fixture"
    var confirm: ConfirmRequest?
    func hubContextStamp(in section: HostingHubSection) -> String { "fixture" }
    func activateHostingHub(_ section: HostingHubSection) async { hostingHub.section = section }
    func loadHostingHub(append: Bool = false) async {}
    func selectHostingHubItem(_ item: HubItem) async { hostingHub.detail = HubDetail(item: item) }
    func showRevisionComparison(left: String, right: String) { fatalError("Fixture opened the Compare page") }
    func hostingHubAction(expected: String, refreshList: Bool, action: @escaping (HubAccess) async throws -> Void) async { fatalError("Fixture attempted a write") }
}

@main struct ReleaseWorkspaceLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let notes = """
        ## Release highlights

        Read **Markdown** notes and compare release versions.

        - [x] Shared preview and reading
        - [x] Independent project checks

        | Platform | Architecture |
        | --- | --- |
        | macOS | Apple silicon / Intel |
        | Windows | x64 |

        > Check the guide before updating your workspace.

        ```sh
        example-cli --version
        ```
        """
        for width in [560.0, 1100.0] {
            for dark in [false, true] {
                let store = RepoStore()
                let item = HubItem(id: "1", title: "A clearer release workspace", subtitle: "v1.10.0", body: notes, url: "https://github.com/sample-studio/desktop/releases/tag/v1.10.0", data: ["tag_name": "v1.10.0", "published_at": "2026-10-28T09:00:00Z"])
                store.hostingHub.items = [item, HubItem(id: "2", title: "Faster navigation", subtitle: "v1.9.0", data: ["tag_name": "v1.9.0", "published_at": "2026-10-20T09:00:00Z"])]
                store.hostingHub.page = 1
                store.hostingHub.detail = HubDetail(item: item, assets: [HubAsset(id: "asset", name: "Example-desktop-1.10.0-macOS-universal.zip", size: 12_582_912, downloads: 142, url: "https://github.com/sample-studio/desktop/releases/download/v1.10.0/example.zip")])
                let bounds = NSRect(x: 0, y: 0, width: width, height: 900)
                let host = NSHostingView(rootView: ReleaseWorkspace(store: store).frame(width: width, height: 900).background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, Locale(identifier: "en_US")).preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0)); window.contentView = host; host.frame = bounds; window.orderBack(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let image = bitmap.representation(using: .png, properties: [:]) else { fatalError("No image") }
                let name = "macos-releases-\(Int(width))-\(dark ? "dark" : "light").png"
                try image.write(to: output.appendingPathComponent(name))
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                try VNImageRequestHandler(data: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                precondition(text.contains("v1.10.0") && text.contains("A clearer release workspace"), "Release identity missing: \(name)")
                if width > 680 {
                    precondition(text.contains("Release highlights") && text.contains("Platform"), "Markdown missing: \(name)")
                    precondition(text.contains("Latest release") && text.contains("42 unreleased commits") && text.contains("v1.9.0"), "Release timeline missing: \(name)")
                }
                window.orderOut(nil)
            }
        }
        print("Release workspace: production layout verified at 560/1100 points in light and dark; all data and actions isolated")
    }
}
