#!/usr/bin/env bash
# Exercises the actual authoring store without credentials, app launch or script execution.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
cat > "$FIXTURE/Fixture.swift" <<'SWIFT'
import Foundation

struct FlowGraphView {
    struct Node {
        let id: String
        let title: String
        let block: String
        let needs: [String]
        let state: String?
        let subtitle: String
    }
}
@MainActor final class FlowStore {
    let repo = FileManager.default.temporaryDirectory
    func refresh() async {}
}
@MainActor enum FlowEngine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static var renderDelay = false
    static var inspectDelay = false
    static var inspectDocument: FlowJSON = .object(["flows": .object([:])])
    static var sourceFiles = ["scripts/check.sh": "original\n"]
    static var lastCreateParents = false
    static var lastExpected: String?
    static var scriptExample = "version: 1\nflows: {}\n"
    static func configurationFiles(in repo: URL) -> [String] { [] }
    static func blockCatalog(in repo: URL) async throws -> FlowBlockCatalog { try JSONDecoder().decode(FlowBlockCatalog.self, from: Data("{\"blocks\":[]}".utf8)) }
    static func proposeInit(in repo: URL) async throws -> FlowInitProposal { fatalError("not used") }
    static func inspectDesign(_ yaml: String, file: String, in repo: URL) async throws -> FlowDesignInspection {
        if inspectDelay { try await Task.sleep(for: .milliseconds(60)) }
        return FlowDesignInspection(document: inspectDocument, yaml: yaml, format: "flow", diagnostics: [], editable: true, proposal: nil)
    }
    static func renderDesign(_ document: FlowJSON, original: String?, in repo: URL) async throws -> FlowDesignRendered {
        if renderDelay { try await Task.sleep(for: .milliseconds(60)) }
        return try JSONDecoder().decode(FlowDesignRendered.self, from: Data("{\"yaml\":\"rendered old source\",\"diagnostics\":[],\"formattingChanged\":true}".utf8))
    }
    static func saveConfiguration(_ content: String, original: String?, file: String, in repo: URL) async throws { fatalError("not used") }
    static func readSource(_ path: String, in repo: URL) async throws -> FlowSourceResult {
        if path.contains("..") { return sourceError(path, "SOURCE_PATH") }
        guard let text = sourceFiles[path] else { return sourceError(path, path.hasPrefix(".gitch/") ? "SOURCE_PARENT_NOT_FOUND" : "SOURCE_NOT_FOUND") }
        return FlowSourceResult(path: path, content: text, fingerprint: "fingerprint:" + text, exists: true, saved: false, diagnostics: [])
    }
    static func writeSource(_ path: String, content: String, expected: String?, createParents: Bool = false, in repo: URL) async throws -> FlowSourceResult {
        lastCreateParents = createParents; lastExpected = expected
        if let current = sourceFiles[path] {
            guard expected == "fingerprint:" + current else { return sourceError(path, "SOURCE_CONFLICT") }
        } else if expected != nil { return sourceError(path, "SOURCE_CONFLICT") }
        sourceFiles[path] = content
        return FlowSourceResult(path: path, content: content, fingerprint: "fingerprint:" + content, exists: true, saved: true, diagnostics: [])
    }
    static func sourceError(_ path: String, _ code: String) -> FlowSourceResult {
        FlowSourceResult(path: path, content: nil, fingerprint: nil, exists: false, saved: false,
                         diagnostics: [FlowDesignDiagnostic(severity: "error", code: code, message: code, path: path, line: nil)])
    }
}
@main struct AuthoringTests {
    @MainActor static func main() async throws {
        let warnings = (0..<6).map { FlowDesignDiagnostic(severity: "warning", code: "CI_PROVIDER_SEMANTICS", message: "Preserved provider field", path: "jobs.checks.step\($0)", line: nil) }
        let grouped = FlowDesignDiagnostic.grouped(warnings)
        precondition(warnings.count == 6 && grouped.count == 1)
        precondition(grouped[0].diagnostics.count == 6 && grouped[0].paths.count == 6)
        let different = FlowDesignDiagnostic(severity: "info", code: "FORMAT_NORMALIZED", message: "Review formatting", path: nil, line: nil)
        precondition(FlowDesignDiagnostic.grouped(warnings + [different]).count == 2)
        let wide = FlowGraphLayout.make((0..<6).map { .init(id: "stage-\($0)", needs: $0 == 0 ? [] : ["stage-\($0 - 1)"]) })
        let fit = FlowGraphLayout.fit(wide, viewport: CGSize(width: 500, height: 300))
        precondition(fit < 0.35 && wide.width * fit <= 488.001)
        let tall = FlowGraphLayout.make((0..<6).map { .init(id: "parallel-\($0)", needs: []) })
        let verticalFit = FlowGraphLayout.fit(tall, viewport: CGSize(width: 500, height: 220))
        precondition(tall.height * verticalFit <= 172.001)
        let unresolved = FlowGraphLayout.make([.init(id: "a", needs: ["b"]), .init(id: "b", needs: ["a"]), .init(id: "missing", needs: ["absent"])])
        precondition(Set(unresolved.unresolved) == Set(["a", "b"]))
        precondition(unresolved.missingDependencies == ["missing → absent"])
        let block = "  first\n  second\nnext\n"
        let selectedBlock = NSRange(location: 0, length: ("  first\n  second\n" as NSString).length)
        let outdent = RepositoryCodeEditing.indent(block, selection: selectedBlock, outdent: true)!
        precondition((block as NSString).replacingCharacters(in: outdent.range, with: outdent.replacement) == "first\nsecond\nnext\n")
        let unicode = "  🧭 next"
        let newline = RepositoryCodeEditing.newline(unicode, selection: NSRange(location: (unicode as NSString).length, length: 0))!
        precondition(newline.replacement == "\n  " && newline.selection.location == (unicode as NSString).length + 3)
        precondition(RepositoryCodeEditing.newline("  a\r\n  b", selection: NSRange(location: 8, length: 0))?.replacement == "\r\n  ")
        precondition(RepositoryCodeEditing.indent("x", selection: NSRange(location: 20, length: 0), outdent: false) == nil)
        let references: FlowJSON = .object(["cwd": .string("work"), "run": .string("bash 'scripts/test file.sh' && python3 tools/check.py && node $DYNAMIC.js && sh /outside.sh"), "with": .object(["file": .string("compose.yml")])])
        precondition(FlowRelatedReferences.paths(node: references) == ["work/compose.yml", "work/scripts/test file.sh", "work/tools/check.py"])
        let related = FlowRelatedFileStore(repo: FileManager.default.temporaryDirectory)
        await related.open("scripts/check.sh")
        related.edit("local draft\n")
        FlowEngine.sourceFiles["scripts/check.sh"] = "external edit\n"
        let conflict = await related.save()
        precondition(!conflict && related.text == "local draft\n" && related.dirty)
        await related.open("scripts/check.sh", create: true)
        precondition(related.text == "local draft\n" && related.error != nil)
        await related.open("../outside.sh", create: true)
        precondition(related.path == "scripts/check.sh")
        await related.open(".gitch/blocks/custom.yml", create: true)
        precondition(related.path == ".gitch/blocks/custom.yml" && related.dirty)
        related.edit("use: cmd\n")
        let created = await related.save()
        precondition(created && !related.dirty && FlowEngine.lastCreateParents && FlowEngine.lastExpected == nil)
        related.edit("use: test.junit\n")
        let updated = await related.save()
        precondition(updated && !FlowEngine.lastCreateParents && FlowEngine.lastExpected != nil)
        let store = FlowAuthoringStore(flows: FlowStore())
        store.document = try JSONDecoder().decode(FlowJSON.self, from: Data("""
        {"version":1,"custom":{"keep":true},"suites":{"unit":{"use":"test.junit","with":{"report":"results.xml","run":"test-command"}}},"flows":{"verify":{"nodes":{
        "explicit":{"use":"cmd","with":{"run":"echo explicit","customInput":"keep"},"futureOption":{"keep":true}},
        "short":"echo shorthand",
        "a":{"run":"echo a"},
        "b":{"needs":["a"],"run":"echo b"},
        "c":{"needs":["b"],"run":"echo c"},
        "suite":{"suite":"unit"},
        "nested":{"flow":"another"}
        }}}}
        """.utf8))
        store.selectedFlow = "verify"
        store.selectedNode = "explicit"
        precondition(store.nodeValue("run", inputs: true).string == "echo explicit")
        store.setNodeValue("run", .string("echo changed"), inputs: true)
        precondition(store.selected["with"]["run"].string == "echo changed")
        precondition(store.selected["run"] == .null)
        precondition(store.selected["with"]["customInput"].string == "keep")
        precondition(store.selected["futureOption"]["keep"].bool == true)
        precondition(store.document["custom"]["keep"].bool == true)
        store.selectedNode = "short"
        store.setNodeValue("run", .string("echo changed shorthand"), inputs: true)
        precondition(store.selected["run"].string == "echo changed shorthand")
        precondition(store.selected["with"] == .null)
        precondition(store.blockID(store.nodes["nested"]!) == "flow")
        store.selectedNode = "suite"
        precondition(store.suiteDefinition["use"].string == "test.junit")
        precondition(store.graphNodes.first { $0.id == "suite" }?.block == "test.junit")
        let suiteBefore = store.document["suites"]
        store.setNodeValue("timeout", .string("5m"))
        precondition(store.document["suites"] == suiteBefore)
        store.selectedNode = "a"
        precondition(!store.canDepend(on: "c"))
        precondition(!store.canDepend(on: "a"))
        store.toggleDependency("c", enabled: true)
        precondition(store.selected["needs"] == .null)
        store.selectedNode = "b"
        store.removeNode()
        precondition(store.nodes["b"] == nil)
        precondition(store.nodes["c"]?["needs"].dependencyIDs == [])
        store.saving = true
        let frozen = store.document
        store.selectedNode = "a"
        store.setNodeValue("run", .string("must not change"), inputs: true)
        store.removeNode()
        precondition(store.document == frozen)
        store.saving = false
        store.editable = true
        store.source = "source"
        store.yaml = "source"
        FlowEngine.renderDelay = true
        let render = Task { await store.updatePreview() }
        try await Task.sleep(for: .milliseconds(10))
        store.yaml = "newly typed YAML"
        await render.value
        precondition(store.yaml == "newly typed YAML")
        FlowEngine.inspectDelay = true
        let inspection = Task { try await store.inspect() }
        try await Task.sleep(for: .milliseconds(10))
        store.yaml = "even newer YAML"
        do { try await inspection.value; preconditionFailure("stale inspection accepted") } catch {}
        precondition(store.yaml == "even newer YAML")
        precondition(store.document == frozen)
        FlowEngine.inspectDelay = false
        FlowEngine.inspectDocument = frozen
        store.yaml = "# exact code source\n"
        await store.previewCode()
        precondition(store.yaml == "# exact code source\n" && store.sourcePreviewCurrent)
        store.addForkJoin()
        precondition(!store.sourcePreviewCurrent)
        precondition(store.nodes["finish"]?["needs"].dependencyIDs == ["check-a", "check-b"])
        print("PASS: authoring, live-source identity, dependency warnings, editing, related-file conflicts/create and source preservation")
    }
}
SWIFT
swiftc -parse-as-library -module-cache-path "$FIXTURE/modules" \
    "$REPO_ROOT/macos/Sources/Core/FlowModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowDesignModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowGraphLayout.swift" \
    "$REPO_ROOT/macos/Sources/Core/RepositoryCodeEditing.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowRelatedReferences.swift" \
    "$REPO_ROOT/macos/Sources/Store/FlowRelatedFileStore.swift" \
    "$REPO_ROOT/macos/Sources/Store/FlowAuthoringStore.swift" "$FIXTURE/Fixture.swift" -o "$FIXTURE/test-authoring"
"$FIXTURE/test-authoring"

# Optional AppKit regression for a local GUI session; normal CI remains headless.
if [[ "${1:-}" == "--ui" ]]; then
cat > "$FIXTURE/EditorUndo.swift" <<'SWIFT_UI'
import SwiftUI
import AppKit
import Observation
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor @Observable final class CodeBuffer {
    var text: String
    init(_ text: String) { self.text = text }
}
struct CodeFixture: View {
    @Bindable var buffer: CodeBuffer
    var editable = true
    @ViewState private var font: CGFloat = 12
    @ViewState private var wraps = false
    @ViewState private var find = ""
    @ViewState private var index = 0
    var body: some View {
        RepositoryCodeReader(text: buffer.text, path: "flow.yml", syntax: true, fontSize: $font, wraps: $wraps, findText: $find, matchIndex: $index,
                             editableText: editable ? Binding(get: { buffer.text }, set: { buffer.text = $0 }) : nil)
            .frame(width: 540, height: 700)
    }

}
@main struct UndoFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = "version: 1\nflows:\n  verify:\n    description: " + String(repeating: "example ", count: 20) + "\n    nodes:\n      prepare:\n        run: echo before\n" + String(repeating: "# example comment\n", count: 35)
        let buffer = CodeBuffer(original)
        let host = NSHostingView(rootView: CodeFixture(buffer: buffer))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 540, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil)
        spin()
        guard let view = findTextView(host) else { fatalError("No editable text view") }
        window.makeFirstResponder(view)
        if let layout = view.layoutManager, let container = view.textContainer, let ruler = view.enclosingScrollView?.verticalRulerView {
            layout.ensureLayout(for: container)
            let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            precondition(view.convert(glyph, to: host).minX >= ruler.convert(ruler.bounds, to: host).maxX + 8, "first source glyph is clipped by the ruler")
        }
        view.undoManager?.removeAllActions()
        view.insertText(" # typed", replacementRange: NSRange(location: (original as NSString).length - 1, length: 0))
        view.breakUndoCoalescing(); spin()
        precondition(buffer.text.contains("typed") && view.undoManager?.canUndo == true)
        view.undoManager?.undo(); spin()
        precondition(buffer.text == original, "syntax refresh lost typing undo")
        view.undoManager?.redo(); spin()
        let beforeTemplate = buffer.text
        buffer.text += "next:\n  needs: [prepare]\n"
        spin()
        precondition(view.string == buffer.text && view.undoManager?.canUndo == true)
        view.undoManager?.undo(); spin()
        precondition(buffer.text == beforeTemplate, "external template replacement was not undoable")
        view.undoManager?.redo(); spin()
        precondition(buffer.text.contains("needs: [prepare]"))
        host.rootView = CodeFixture(buffer: buffer, editable: false)
        spin()
        precondition(findTextView(host)?.isEditable == false)
        window.orderOut(nil)
        print("PASS: native code gutter, typing/style undo, external template undo/redo and read-only defaults")
    }
    @MainActor static func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    @MainActor static func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let match = findTextView(child) { return match } }
        return nil
    }
}
SWIFT_UI
swiftc -parse-as-library -swift-version 5 -module-cache-path "$FIXTURE/modules" \
    "$REPO_ROOT/macos/Sources/Core/RepositoryCodeReading.swift" \
    "$REPO_ROOT/macos/Sources/Core/RepositoryCodeNavigation.swift" \
    "$REPO_ROOT/macos/Sources/Core/RepositoryCodeEditing.swift" \
    "$REPO_ROOT/macos/Sources/Views/Workbench/RepositorySourceView.swift" \
    "$REPO_ROOT/macos/Sources/Views/Workbench/RepositoryCodeReader.swift" \
    "$REPO_ROOT/macos/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" \
    "$FIXTURE/EditorUndo.swift" -o "$FIXTURE/test-editor-undo"
"$FIXTURE/test-editor-undo"
fi
