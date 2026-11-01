import AppKit
import CryptoKit
import SwiftUI
import Vision

private func flowRequire(_ condition: Bool, _ message: String = "Flow fixture invariant failed") {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        fatalError(message)
    }
}

@MainActor private func flowSettle(_ seconds: Double = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor private func flowWait(_ work: @escaping @MainActor () async throws -> Void) throws {
    var finished = false
    var failure: Error?
    Task { @MainActor in
        do { try await work() } catch { failure = error }
        finished = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !finished, Date() < deadline { flowSettle(0.01) }
    flowRequire(finished, "The isolated flow engine request timed out")
    if let failure { throw failure }
}

@MainActor private func flowDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(flowDescendants)
}

@MainActor private final class FlowShot {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    init<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, dark: Bool) {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light)))
        window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.contentView = host
        host.frame = bounds
        window.orderBack(nil)
    }
    func ready(text: String) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            flowSettle(0.08)
            if editors.contains(where: { $0.string == text }) { flowSettle(0.4); return }
        }
        fatalError("The production source editor did not load the fixture text")
    }
    var editors: [NSTextView] { flowDescendants(host).compactMap { $0 as? NSTextView }.filter(\.isEditable) }
    func png() -> Data {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No flow bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No flow PNG") }
        return data
    }
    func close() { window.orderOut(nil) }
}

private func flowRecognize(_ png: Data) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(data: png).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private let flowLayoutYAML = """
# Code defines order; the diagram follows this source.
version: 1
flows:
  verify:
    trigger: [manual]
    nodes:
      prepare:
        description: Prepare workspace
        run: echo Prepare workspace
      lint:
        description: Check source style
        needs: [prepare]
        run: bash scripts/check.sh
      tests:
        description: Check application behavior
        needs: [prepare]
        run: echo Review application tests
      package:
        description: Review build output
        needs: [lint, tests]
        run: echo Review build output
""" + "\n"

private let flowLayoutScript = """
#!/usr/bin/env bash
# A source file for editing; this fixture never executes it.
set -euo pipefail

check_source() {
    printf '%s\\n' 'Review the source before running checks'
}

check_source
""" + "\n"

@main struct FlowCodeLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repo = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let common = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let marker = try String(contentsOf: repo.appendingPathComponent(".gitrochi-flow-layout-fixture"), encoding: .utf8)
        flowRequire(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "flow-layout-fixture")
        let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gitch-flow").path
        flowRequire(FlowEngine.executable == engine, "The fixture must use its own bundled current engine")
        let manager = FileManager.default
        let yamlURL = repo.appendingPathComponent(".gitch/flow.yml")
        let scriptURL = repo.appendingPathComponent("scripts/check.sh")
        try manager.createDirectory(at: yamlURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try flowLayoutYAML.write(to: yamlURL, atomically: true, encoding: .utf8)
        try flowLayoutScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        let beforeYAML = try Data(contentsOf: yamlURL), beforeScript = try Data(contentsOf: scriptURL)
        let settings = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GITSW_CONFIG"]!).deletingLastPathComponent()
        let trust = settings.appendingPathComponent("flow/trust")
        let trustedBefore = ((try? manager.contentsOfDirectory(atPath: trust.path)) ?? []).sorted()
        let digest = SHA256.hash(data: Data(repo.resolvingSymlinksInPath().path.utf8))
        let worktreeID = String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
        let runs = common.appendingPathComponent("gitch/flow/runs/" + worktreeID)
        let runsBefore = ((try? manager.contentsOfDirectory(atPath: runs.path)) ?? []).sorted()
        let flows = FlowStore(repo: repo)
        var results: [[String: Any]] = []

        func model() throws -> FlowAuthoringStore {
            let design = FlowAuthoringStore(flows: flows, initialFlow: "verify", initialNode: "lint")
            try flowWait { await design.initialize() }
            flowRequire(design.error == nil && design.sourcePreviewCurrent, "The real engine must inspect valid fixture YAML: \(design.error ?? "")")
            flowRequire(design.graphNodes.count == 4 && design.graphNodes.first(where: { $0.id == "package" })?.needs == ["lint", "tests"])
            return design
        }
        func record(_ shot: FlowShot, name: String, dark: Bool, expect: [String], absent: [String] = []) throws {
            let png = shot.png(), file = "flow-code-\(name)-\(dark ? "dark" : "light").png"
            try png.write(to: output.appendingPathComponent(file))
            let recognized = try flowRecognize(png)
            try recognized.write(to: output.appendingPathComponent(file.replacingOccurrences(of: ".png", with: ".txt")), atomically: true, encoding: .utf8)
            let normalized = recognized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for label in expect {
                flowRequire(normalized.localizedCaseInsensitiveContains(label), "\(file): missing \(label)\n\(recognized)")
            }
            for label in absent {
                flowRequire(!normalized.localizedCaseInsensitiveContains(label), "\(file): unexpected \(label)\n\(recognized)")
            }
            results.append(["screenshot": file, "theme": dark ? "dark" : "light", "labels": expect, "productionView": true])
            shot.close()
        }
        for dark in [false, true] {
            let sheet = FlowShot(FlowEditorSheet(flows: flows, initialFlow: "verify", initialNode: "lint"), width: 1280, height: 880, dark: dark)
            sheet.ready(text: flowLayoutYAML)
            try record(sheet, name: "wide", dark: dark, expect: ["Edit flow code", "Source preview", "Related files", "Modules", "Validate and save"])

            let compactDesign = try model(), compactFiles = FlowRelatedFileStore(repo: repo)
            let compact = FlowShot(FlowCodeAuthoringView(design: compactDesign, related: compactFiles), width: 980, height: 760, dark: dark)
            compact.ready(text: flowLayoutYAML)
            try record(compact, name: "compact", dark: dark, expect: ["Flow definition", "Related files", "Source preview", "Insert template"])

            let invalidDesign = try model(), invalidFiles = FlowRelatedFileStore(repo: repo)
            let invalid = "version: 1\nflows: [\n  verify: invalid draft\n"
            invalidDesign.editCode(invalid)
            try flowWait { await invalidDesign.previewCode() }
            flowRequire(!invalidDesign.sourcePreviewCurrent && invalidDesign.diagnostics.contains { $0.severity == "error" })
            let invalidShot = FlowShot(FlowCodeAuthoringView(design: invalidDesign, related: invalidFiles), width: 1100, height: 760, dark: dark)
            invalidShot.ready(text: invalid)
            try record(invalidShot, name: "invalid", dark: dark, expect: ["Preview is out of date", "Fix the source errors", "Source preview"])

            let relatedDesign = try model(), files = FlowRelatedFileStore(repo: repo)
            try flowWait { await files.open("scripts/check.sh") }
            flowRequire(files.active && files.text == flowLayoutScript && !files.dirty && files.error == nil)
            let relatedShot = FlowShot(FlowCodeAuthoringView(design: relatedDesign, related: files), width: 1100, height: 760, dark: dark)
            relatedShot.ready(text: flowLayoutScript)
            guard let editor = relatedShot.editors.first(where: { $0.string == flowLayoutScript }) else { fatalError("No editable related source") }
            // Exercise the real NSTextView delegate/binding; the draft must remain only in memory.
            editor.insertText("# Local review note\n", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
            flowSettle(0.25)
            flowRequire(files.dirty && files.text.contains("# Local review note"), "Native typing must update the independent draft")
            let untouchedScript = try Data(contentsOf: scriptURL)
            flowRequire(untouchedScript == beforeScript, "Editing a draft must not save or execute it")
            try record(relatedShot, name: "related-file", dark: dark, expect: ["scripts/check.sh", "Save file", "Unsaved changes", "Local review note"])

            let modulesDesign = try model()
            let modules = FlowShot(FlowVisualEditor(design: modulesDesign), width: 1100, height: 760, dark: dark)
            flowSettle(0.8)
            try record(modules, name: "modules", dark: dark, expect: ["Add module", "Inputs", "Dependencies", "Execution settings"])
        }
        let finalYAML = try Data(contentsOf: yamlURL), finalScript = try Data(contentsOf: scriptURL)
        flowRequire(finalYAML == beforeYAML && finalScript == beforeScript, "Snapshot QA must not save any source")
        flowRequire(((try? manager.contentsOfDirectory(atPath: trust.path)) ?? []).sorted() == trustedBefore, "Snapshot QA must not approve trust")
        flowRequire(((try? manager.contentsOfDirectory(atPath: runs.path)) ?? []).sorted() == runsBefore, "Snapshot QA must not run a flow")
        let report: [String: Any] = ["screenshots": results, "count": results.count, "engine": "bundled gitch-flow", "nativeEditorTyping": true, "sourcesUnchanged": true, "noTrustOrRun": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("flow-code-native-result.json"))
        print("PASS: \(results.count) native production flow screenshots; typed draft retained; no source saved, trust approved or flow run.")
    }
}
