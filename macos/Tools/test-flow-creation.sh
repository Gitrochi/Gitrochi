#!/usr/bin/env bash
# New flow drafts retain exact commands and reject ambiguous or unsafe names.
# Add --ui in a local GUI session for the offscreen native command-editor regression.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
export CLANG_MODULE_CACHE_PATH="$FIXTURE/modules"
export SWIFT_MODULECACHE_PATH="$FIXTURE/modules"

cat > "$FIXTURE/CreationTests.swift" <<'SWIFT_MODEL'
import Foundation
@main struct CreationTests {
    static func main() {
        var draft = FlowCreationDraft()
        precondition(draft.problem(existingNames: []) == .missingName && !draft.hasChanges)
        draft.name = "  verify  "
        precondition(draft.file == ".gitch/flows/verify.yml")
        precondition(draft.problem(existingNames: ["VERIFY"]) == .duplicateName)
        precondition(draft.problem(existingNames: []) == .missingCommand)
        draft.steps[0].command = "  printf '%s\\n' \"quoted\"\nnext --flag\n"
        draft.steps[0].title = " First check "
        draft.description = " Repository checks "
        draft.steps.append(.init(title: "", command: "second command\n"))
        precondition(draft.problem(existingNames: []) == nil && draft.hasChanges)
        let sequential = draft.document()["flows"]["verify"]
        precondition(sequential["description"].string == "Repository checks")
        precondition(sequential["trigger"].array == [.string("manual")])
        precondition(sequential["nodes"]["step-1"]["run"].string == draft.steps[0].command)
        precondition(sequential["nodes"]["step-1"]["description"].string == "First check")
        precondition(sequential["nodes"]["step-1"]["needs"] == .null)
        precondition(sequential["nodes"]["step-2"]["needs"].array == [.string("step-1")])
        draft.execution = .inParallel
        precondition(draft.document()["flows"]["verify"]["nodes"]["step-2"]["needs"] == .null)
        draft.steps.swapAt(0, 1)
        precondition(draft.document()["flows"]["verify"]["nodes"]["step-1"]["run"].string == "second command\n")
        draft.steps[0].command = " \n\t"
        precondition(draft.problem(existingNames: []) == .missingCommand)
        draft.steps = []
        precondition(draft.problem(existingNames: []) == .missingSteps)
        for name in ["../bad", "UPPER", "1flow", "a/b", "a.b", String(repeating: "a", count: 65)] {
            draft.name = name
            precondition(draft.problem(existingNames: []) == .invalidName)
        }
        draft.name = String(repeating: "a", count: 64)
        precondition(draft.problem(existingNames: []) == .missingSteps)
        print("PASS: Swift creation draft validation, exact commands, titles, trimmed names, boundaries, reordered steps and dependencies")
    }
}
SWIFT_MODEL
swiftc -parse-as-library -swift-version 5 -module-cache-path "$FIXTURE/modules" \
    "$REPO_ROOT/macos/Sources/Core/FlowModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowDesignModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowCreation.swift" \
    "$FIXTURE/CreationTests.swift" -o "$FIXTURE/test-creation"
"$FIXTURE/test-creation"

# The default contract check stays headless; this explicitly requested harness creates only its own offscreen window.
if [[ "${1:-}" == "--ui" ]]; then
# Keep tests in the source file's scope so they exercise the production private editor.
cat "$REPO_ROOT/macos/Sources/Views/Sheets/FlowCreateSheet.swift" > "$FIXTURE/EditorTests.swift"
cat >> "$FIXTURE/EditorTests.swift" <<'SWIFT_UI'
import Observation

typealias ViewState<Value> = SwiftUI.State<Value>
@MainActor @Observable final class FlowStore {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("flow-creation-fixture")
    var list: FlowList?
    func refresh() async {}
}
enum FlowEngine {
    struct Failure: LocalizedError {
        let message: String
        var code: String? = nil
        var action: String? = nil
        var errorDescription: String? { message }
    }
    static func hasFlowFile(in repo: URL) -> Bool { false }
    static func list(in repo: URL) async throws -> FlowList { fatalError("Fixture does not save") }
    static func renderDesign(_ document: FlowJSON, original: String?, in repo: URL) async throws -> FlowDesignRendered { fatalError("Fixture does not save") }
    static func saveConfiguration(_ content: String, original: String?, file: String, in repo: URL) async throws { fatalError("Fixture does not save") }
}


@MainActor @Observable final class CommandBuffer {
    var text = "printf "
    var submissions = 0
}
private struct CommandFixture: View {
    @Bindable var buffer: CommandBuffer
    var editable = true
    var body: some View {
        VStack {
            FlowCreationCommandEditor(text: $buffer.text).disabled(!editable)
            Button("Create flow") { buffer.submissions += 1 }.keyboardShortcut(.defaultAction)
        }.frame(width: 580, height: 220)
    }
}
@main struct CommandTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let buffer = CommandBuffer()
        let host = NSHostingView(rootView: CommandFixture(buffer: buffer))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 580, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil); spin()
        guard let view = find(host) else { fatalError("No command text view") }
        window.makeFirstResponder(view)
        precondition(!view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled && !view.isAutomaticTextReplacementEnabled && !view.isAutomaticSpellingCorrectionEnabled)
        view.undoManager?.removeAllActions()
        view.insertText("'%s' --flag", replacementRange: NSRange(location: (buffer.text as NSString).length, length: 0))
        view.breakUndoCoalescing(); spin()
        precondition(buffer.text == "printf '%s' --flag" && view.undoManager?.canUndo == true, "Typed command changed or cannot undo")
        view.undoManager?.undo(); spin()
        precondition(buffer.text == "printf ", "Undo did not preserve command binding")
        view.undoManager?.redo(); spin()
        precondition(buffer.text == "printf '%s' --flag", "Redo did not restore command")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(event); spin()
        precondition(buffer.text == "printf '%s' --flag\n" && buffer.submissions == 0, "Return triggered Create flow instead of a command newline")
        host.rootView = CommandFixture(buffer: buffer, editable: false); spin()
        precondition(find(host)?.isEditable == false, "Saving did not disable editing")
        window.orderOut(nil)
        print("PASS: native command typing, literal quotes/dashes, undo/redo, Return newline and disabled editing")
    }
    @MainActor static func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
    @MainActor static func find(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let match = find(child) { return match } }
        return nil
    }
}
SWIFT_UI
swiftc -parse-as-library -swift-version 5 -module-cache-path "$FIXTURE/modules" \
    "$REPO_ROOT/macos/Sources/Core/FlowModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowDesignModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowCreation.swift" \
    "$FIXTURE/EditorTests.swift" -o "$FIXTURE/test-command-editor"
"$FIXTURE/test-command-editor"
fi
