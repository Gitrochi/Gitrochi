import SwiftUI
import AppKit
import Observation

typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor @Observable private final class InspectorRecorder {
    var collapsed = false
    var width = 380.0
    var writeRequest = 0
    var draft = ""
    var mounts: [String: Int] = [:]
    var identities: [String: UUID] = [:]
    var sizes: [String: CGSize] = [:]
}

private final class ColumnIdentity: ObservableObject {
    let value = UUID()
}

private struct ColumnProbe: View {
    let name: String
    let recorder: InspectorRecorder
    @StateObject private var identity = ColumnIdentity()
    @ViewState private var draft = ""

    var body: some View {
        TextEditor(text: $draft)
            .onAppear {
                recorder.mounts[name, default: 0] += 1
                recorder.identities[name] = identity.value
            }
            .onChange(of: recorder.writeRequest) { _, _ in draft = "Unsent commit notes" }
            .onChange(of: draft) { _, value in if name == "inspector" { recorder.draft = value } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { recorder.sizes[name] = $0 }
    }
}

private struct InspectorColumnsFixture: View {
    @Bindable var recorder: InspectorRecorder

    var body: some View {
        WorkspaceColumns(width: $recorder.width, fixedTrailing: true, minimumFlexible: 480, trailingCollapsed: recorder.collapsed) {
            ColumnProbe(name: "center", recorder: recorder)
        } trailing: {
            ColumnProbe(name: "inspector", recorder: recorder)
        }
    }
}

@main struct InspectorVisibilityTest {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let recorder = InspectorRecorder()
        let host = NSHostingView(rootView: InspectorColumnsFixture(recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1200, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderBack(nil)
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        recorder.writeRequest += 1
        settle()
        let identities = recorder.identities
        precondition(identities.count == 2 && recorder.draft == "Unsent commit notes")
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [1200, 1000, 800] {
                window.setContentSize(NSSize(width: width, height: 600))
                settle()
                let panelWidth = recorder.sizes["inspector"]!.width
                let centerWidth = recorder.sizes["center"]!.width
                recorder.collapsed = true
                settle()
                precondition(recorder.sizes["inspector"]!.width == 0, "The hidden panel must take no space")
                precondition(abs(recorder.sizes["center"]!.width - width) <= 1, "The center must take all available width")
                precondition(abs(recorder.sizes["center"]!.width - centerWidth - panelWidth - 1) <= 1, "The divider must release its width too")
                precondition(recorder.width == 380, "Hiding must not change the saved width")
                recorder.collapsed = false
                settle()
                precondition(abs(recorder.sizes["inspector"]!.width - panelWidth) <= 1, "Reopening must restore the panel width")
                precondition(recorder.identities == identities && recorder.mounts.values.allSatisfy { $0 == 1 }, "Both columns must retain their view identity")
                precondition(recorder.draft == "Unsent commit notes", "An unsent draft must survive hiding and reopening")
            }
        }
        window.orderOut(nil)
        print("PASS: right panel closes and restores its width at 800/1000/1200 pt, light/dark; the center uses all freed space, and both columns keep their identity and draft")
    }
}
