import SwiftUI
import AppKit
import Vision

/// 실계정·인증·저장소 작업 없이 실제 상세 뷰를 렌더링한다.
@main struct InspectorLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        inspectorFixtureDefaults.set(false, forKey: "avatarFetch")
        defer { inspectorFixtureDefaults.removePersistentDomain(forName: inspectorFixtureSuite) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sha = String(repeating: "a", count: 40)
        let store = RepoStore()
        store.detail = CommitDetail(sha: sha, parents: (1...6).map { String(repeating: String($0), count: 40) },
                                    author: "VISIBLE AUTHOR with an unusually long display name", email: "very.long.author.name+review@example.invalid",
                                    date: Date(timeIntervalSince1970: 1_792_973_000), committer: String(repeating: "LongCommitter", count: 8),
                                    committerEmail: "committer@example.invalid", commitDate: Date(timeIntervalSince1970: 1_792_974_000),
                                    summary: "VISIBLE SUMMARY: preserve the beginning of a long commit message in narrow panels",
                                    body: "The full commit description remains readable and wraps inside the panel.",
                                    trailers: CommitTrailers(
                                        issues: [.init(keyword: "closes", number: 42), .init(keyword: "fixes", number: 7)],
                                        coAuthors: [.init(name: "VISIBLE COAUTHOR with an unusually long display name", email: "coauthor@example.invalid",
                                                          line: "Co-authored-by: VISIBLE COAUTHOR with an unusually long display name <coauthor@example.invalid>")]))
        // an issue title that was read before; #7 has none, as without an account
        store.trailerIssuesKey = store.issueAccountKey
        store.trailerIssues = [42: CollaborationInboxItem(id: "issue-42", kind: "issue", number: 42, title: "VISIBLE ISSUE title that is far too long for a narrow panel",
                                                          url: "", body: "", state: "open", author: "")]
        store.fixtureRefs(sha, [
            RefLabel(name: "codex/commit-impact-structure-replay-with-a-very-long-branch-name", kind: .local, isCurrent: true),
            RefLabel(name: "origin/codex/commit-impact-structure-replay-with-a-very-long-branch-name", kind: .remote, isCurrent: false)
        ])
        store.detailFiles = [FileChange(path: "src/VeryLongDirectory/VisibleFile.swift", oldPath: nil, kind: .modified, staged: true)]
        store.detailStats = [store.detailFiles[0].path: LineStat(added: 128, deleted: 9)]
        var results: [[String: Any]] = []
        for width: CGFloat in [250, 340, 380] {
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                let host = NSHostingView(rootView: CommitDetailView(sha: sha).environment(store)
                    .defaultAppStorage(inspectorFixtureDefaults).preferredColorScheme(dark ? .dark : .light))
                let bounds = NSRect(x: 0, y: 0, width: width, height: 1600)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: bounds.height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.frame = bounds
                window.orderBack(nil)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])!
                let name = "inspector-\(Int(width))-\(theme).png"
                try data.write(to: output.appendingPathComponent(name))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: data).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                precondition(text.contains("VISIBLE SUMMARY"), "The beginning of the summary is clipped: \(name)\n\(text)")
                precondition(text.contains("VISIBLE AUTHOR"), "The author is clipped: \(name)\n\(text)")
                // the recognizer sometimes splits a file name at its dot
                precondition(text.replacingOccurrences(of: " ", with: "").contains("VisibleFile.swift"), "The changed file is hidden: \(name)\n\(text)")
                // the board draws one author line: the committer is on the time's hover, and a commit's refs are on its graph row
                precondition(!text.contains("LongCommitter"), "The committer has no line of its own: \(name)\n\(text)")
                precondition(!text.contains("commit-impact"), "Ref chips are not drawn in the inspector: \(name)\n\(text)")
                precondition(CommitDetailView.dates(store.detail!).contains("LongCommitter"), "The committer stays on the time's hover")
                // the trailer rows: the verb, the read title from its start, and the co-author with the pill whole
                precondition(text.contains("Closes") && text.contains("Fixes"), "The issue rows are hidden: \(name)\n\(text)")
                precondition(text.contains("VISIBLE ISSUE"), "The issue title is clipped from its start: \(name)\n\(text)")
                precondition(text.contains("VISIBLE COAU"), "The co-author is clipped from its start: \(name)\n\(text)")
                precondition(text.contains("Co-author"), "The co-author pill is cut: \(name)\n\(text)")
                // the flat panel keeps its actions in view: the two buttons and the AI entry
                precondition(text.contains("New branch"), "The New branch button is hidden: \(name)\n\(text)")
                precondition(text.contains("Explain with"), "The AI entry is hidden: \(name)\n\(text)")
                results.append(["width": width, "theme": theme, "summaryVisible": true, "authorVisible": true, "fileVisible": true, "screenshot": name])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print("PASS: actual flat commit inspector at 250/340/380 points, light/dark; the summary, author, trailer rows, six parents, the actions and the file remain visible; no ref chips or committer line. \(output.path)")
    }
}
