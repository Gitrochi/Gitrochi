#!/usr/bin/env bash
# Renders the Ledger page off screen on demo data, in light and dark: Inbox, Board, Graph, Streams, the inspector, the
# empty state, a narrow and a stacked window, the two sheets, and the large demo (1,000 sessions, 50,000 events). Then
# the page, Settings › Ledger and Import from claude-ledger on the core itself, through its C ABI, with the core's demo
# in a temporary database.
# Text recognition checks that each part is drawn (on its larger text: small labels are read unreliably), and the
# large demo reports frame and filter timings.
#   macos/Tools/test-ledger-layout.sh [output folder for the screenshots]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-ledger-layout.XXXXXX")}"
mkdir -p "$TASK_OUTPUT"
ARCH="$(uname -m)"
ST="${GITROCHI_SWIFTTERM_DIR:-$ROOT/.build/swiftterm/$ARCH}"
[[ -f "$ST/libSwiftTerm.a" ]] || { echo 'Run macos/build.sh once to build SwiftTerm.' >&2; exit 1; }
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text()
    if relative == 'App/App.swift':
        # the fixture brings its own entry point
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
cat > "$TASK_TMP/LedgerLayout.swift" <<'SWIFT'
import SwiftUI
import AppKit
import Vision

@MainActor func settle(_ seconds: Double = 0.35) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

@MainActor func wait(_ work: @escaping @MainActor () async -> Void) {
    var done = false
    Task { @MainActor in await work(); done = true }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}

@MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
}

@MainActor final class Shot {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    init<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, dark: Bool) {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        // an opaque window background, as in the app: text on a transparent one reads as text on black
        host = NSHostingView(rootView: AnyView(content.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light)))
        window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.contentView = host
        host.frame = bounds
        window.orderBack(nil)
        settle()
    }

    /// Lays out and draws one frame; seconds it took
    @discardableResult func frame() -> Double {
        let start = Date()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        return Date().timeIntervalSince(start)
    }

    func png() -> Data {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        return data
    }

    func close() { window.orderOut(nil) }
}

/// Text recognition misreads a letter now and then ("flaky" as "tlaky"): a label of three words or more counts as seen
/// when all but one of its words are
func seen(_ label: String, in text: String) -> Bool {
    let text = text.lowercased(), words = label.lowercased().split(separator: " ")
    if text.contains(label.lowercased()) { return true }
    return words.count > 2 && words.filter { text.contains($0) }.count >= words.count - 1
}

@MainActor func text(in png: Data) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(data: png).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

@main struct LedgerLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "dev.gitrochi.ledger-layout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var shots = 0

        func store(_ mode: DemoLedgerBackend.Mode) -> LedgerStore {
            let ledger = LedgerStore(client: LedgerClient(backend: DemoLedgerBackend(mode: mode)), defaults: defaults, interval: .seconds(600))
            wait { await ledger.reload() }
            return ledger
        }

        func shoot<Content: View>(_ name: String, _ content: Content, width: CGFloat, height: CGFloat, expect: [String], absent: [String] = []) throws {
            for dark in [false, true] {
                let shot = Shot(content, width: width, height: height, dark: dark)
                settle(0.4)
                let png = shot.png()
                let file = "ledger-\(name)-\(dark ? "dark" : "light").png"
                try png.write(to: output.appendingPathComponent(file))
                let recognized = try text(in: png)
                for label in expect where !seen(label, in: recognized) {
                    fatalError("\(file): “\(label)” is not on screen\n\(recognized)")
                }
                for label in absent where recognized.localizedCaseInsensitiveContains(label) {
                    fatalError("\(file): “\(label)” should not be on screen")
                }
                shot.close()
                shots += 1
            }
        }

        let ledger = store(.standard)
        let sessions = ledger.state!.sessions
        let retry = sessions.first { $0.verdict == .needsHuman && $0.project == "harbor" }!
        let decision = sessions.first { $0.role == .decision }!

        ledger.selection = retry.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("inbox", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 2100,
                  expect: ["Inbox", "How many times should sign-in retry", "Retry sign-in after a timeout", "Outline the onboarding chapter",
                           "offline drafts be kept", "Choose the cache eviction policy", "Write the export guide", "Investigate the flaky upload test"])

        ledger.page = .board
        ledger.selection = decision.id
        ledger.boardSelection = Set(sessions.filter { $0.verdict == .pendingMerge }.map(\.id))
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("board", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 940,
                  expect: ["Board", "selected", "Choose the cache eviction policy", "Add CSV export"])
        ledger.boardSelection = []

        wait { await ledger.setRange(.month) }
        ledger.page = .graph
        ledger.selection = retry.id
        wait { await ledger.loadGraph(); try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("graph", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 940,
                  expect: ["Graph", "v1.4.2", "v1.4.1"])

        ledger.page = .streams
        wait { try? await Task.sleep(for: .milliseconds(300)) }
        try shoot("streams", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 940,
                  expect: ["Streams", "Core implementation channel", "v1.4.2", "v1.4.0"])

        ledger.page = .inbox
        try shoot("narrow", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 980, height: 760,
                  expect: ["Inbox", "Retry sign-in after a timeout"], absent: ["Answer or dismiss the open questions"])
        try shoot("stacked", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 620, height: 820,
                  expect: ["Inbox", "Board", "Graph"])

        ledger.selection = decision.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("inspector", LedgerInspector(ledger: ledger, open: { _ in }, close: {}), width: 480, height: 900,
                  expect: ["Choose the cache eviction policy", "Decision", "200 MB"])
        // a session that may auto-continue: its own switch and wait
        ledger.selection = retry.id
        wait { await ledger.loadAutoContinueDefault(); try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("inspector-auto-continue", LedgerInspector(ledger: ledger, open: { _ in }, close: {}), width: 480, height: 1100,
                  expect: ["Retry sign-in after a timeout", "Continue automatically when nobody answers"])

        try shoot("connect", LedgerConnectSheet(ledger: ledger, binaryPath: "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger"), width: 640, height: 330,
                  expect: ["Connect Claude Code", "claude mcp add", "Copy command", "Test connection"])
        try shoot("import", LedgerImportSheet(ledger: ledger), width: 620, height: 380, expect: ["Paste reports", "Import"])

        let empty = store(.empty)
        try shoot("empty", LedgerWorkspaceView(repositoryPath: nil, ledger: empty), width: 1200, height: 760,
                  expect: ["Keep track of your agent sessions", "Connect Claude Code", "Paste reports"])

        // the core itself, through its C ABI, as the app reads it
        let core = LedgerStore(client: LedgerClient(backend: NativeLedgerBackend(database: CommandLine.arguments[2])), defaults: defaults, interval: .seconds(600))
        wait { await core.setRange(.all); await core.reload() }
        let asking = core.state!.sessions.first { $0.verdict == .needsHuman }!
        core.selection = asking.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("core-inbox", LedgerWorkspaceView(repositoryPath: nil, ledger: core), width: 1440, height: 940, expect: ["Inbox", asking.title])
        let confirm = core.state!.sessions.first { $0.verdict == .confirm }!
        core.page = .board
        core.selection = confirm.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("core-board", LedgerWorkspaceView(repositoryPath: nil, ledger: core), width: 1440, height: 940, expect: ["Board", confirm.title])
        core.page = .graph
        wait { await core.loadGraph(); try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("core-graph", LedgerWorkspaceView(repositoryPath: nil, ledger: core), width: 1440, height: 940, expect: ["Graph", "1.4.2"])
        // a repository with its own auto-continue policy, so Settings shows the switch and the wait
        wait {
            if let stored = try? await core.settings() {
                _ = try? await core.saveSettings(["autoContinue": stored.autoContinueArgument(repository: "/Volumes/Work/harbor-app", .init(enabled: true, delaySec: 45))])
            }
        }
        try shoot("settings", LedgerSettings(ledger: core), width: 600, height: 2000,
                  expect: ["Track agents I start", "Agents Gitrochi starts", "Continue automatically when nobody answers", "harbor-app",
                           "Stale after", "Roles and stream lines", "implementation", "Version pattern", "Back up now", "Connect Claude Code"])
        try shoot("import-legacy", LedgerLegacyImportSheet(ledger: core, path: CommandLine.arguments[3]), width: 620, height: 380,
                  expect: ["Import from claude-ledger", "Ready to import", "Sessions"])

        // the large demo: one frame at the top, then frames while scrolling, and the filter while typing
        let big = store(.large)
        wait { await big.setRange(.all) }
        big.page = .board
        let shot = Shot(LedgerWorkspaceView(repositoryPath: nil, ledger: big), width: 1440, height: 940, dark: false)
        settle(0.5)
        let first = shot.frame()
        let list = scrollViews(in: shot.host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }!
        var frames: [Double] = []
        let content = list.documentView?.frame.height ?? 0
        for step in 1...40 {
            let y = content * Double(step) / 40 - list.contentView.bounds.height
            list.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            list.reflectScrolledClipView(list.contentView)
            frames.append(shot.frame())
        }
        let png = shot.png()
        try png.write(to: output.appendingPathComponent("ledger-large-board-light.png"))
        var filter = big.filter
        filter.text = "cache"
        let typed = Date()
        big.filter = filter
        let before = big.boardRows.count
        while big.boardRows.count == before { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        let filterTime = Date().timeIntervalSince(typed) + shot.frame()
        filter.text = ""
        big.filter = filter
        settle(0.2)
        shot.close()
        big.page = .graph
        let graphShot = Shot(LedgerWorkspaceView(repositoryPath: nil, ledger: big), width: 1440, height: 940, dark: true)
        wait { await big.loadGraph() }
        settle(0.5)
        let graphFirst = graphShot.frame()
        let graphList = scrollViews(in: graphShot.host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }!
        var graphFrames: [Double] = []
        for step in 1...40 {
            graphList.contentView.scroll(to: NSPoint(x: 0, y: (graphList.documentView?.frame.height ?? 0) * Double(step) / 41))
            graphList.reflectScrolledClipView(graphList.contentView)
            graphFrames.append(graphShot.frame())
        }
        try graphShot.png().write(to: output.appendingPathComponent("ledger-large-graph-dark.png"))
        graphShot.close()
        func report(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.1f ms, slowest %.1f ms", sorted[sorted.count / 2] * 1000, (sorted.last ?? 0) * 1000)
        }
        print(String(format: "Large demo: Board first frame %.0f ms; scrolling %@ over %d frames; filter to a drawn frame %.0f ms; Graph (%d rows drawn of %d) first frame %.0f ms; scrolling %@",
                     first * 1000, report(frames), frames.count, filterTime * 1000, big.plot.rows.count, big.graph?.nodes.count ?? 0, graphFirst * 1000, report(graphFrames)))
        precondition(report(frames).isEmpty == false && (frames.sorted()[frames.count / 2]) < 0.25, "Board scrolling is too slow")
        print("PASS: \(shots) screenshots in light and dark with the labels on screen. \(output.path)")
    }
}
SWIFT
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
xcrun swiftc -parse-as-library -swift-version 5 -O -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/LedgerLayout.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/ledger-layout"
# The core's own demo in a temporary database, and a claude-ledger file to import; a call that names no database
# would use another temporary one, never the person's ledger
"$(dirname "$TASK_CORE")/gitrochi-ledger" demo "$TASK_TMP/ledger.sqlite3" > /dev/null
sqlite3 "$TASK_TMP/claude-ledger.db" < "$ROOT/Tools/fixtures/claude-ledger.sql"
export GITROCHI_LEDGER_DB="$TASK_TMP/default.sqlite3"
"$TASK_TMP/ledger-layout" "$TASK_OUTPUT" "$TASK_TMP/ledger.sqlite3" "$TASK_TMP/claude-ledger.db"
