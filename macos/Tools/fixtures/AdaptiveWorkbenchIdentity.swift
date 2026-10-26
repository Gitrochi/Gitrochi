import SwiftUI
import AppKit
import Observation

typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor @Observable private final class Recorder {
    var writeRequest = 0
    var requestedDraft = ""
    var appeared: [UUID] = []
    var samples: [(UUID, String, CGSize)] = []

    func capture(_ identity: UUID, _ draft: String, _ size: CGSize) {
        samples.append((identity, draft, size))
    }
}

private struct DraftProbe: View {
    let recorder: Recorder
    @StateObject private var identity = ProbeIdentity()
    @ViewState private var draft = ""
    @ViewState private var size = CGSize.zero

    var body: some View {
        VStack {
            TextEditor(text: $draft).font(.body)
            Text(draft)
        }
        .onAppear {
            recorder.appeared.append(identity.value)
            recorder.capture(identity.value, draft, size)
        }
        .onChange(of: recorder.writeRequest) { _, _ in draft = recorder.requestedDraft }
        .onChange(of: draft) { _, value in recorder.capture(identity.value, value, size) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { value in
            size = value
            recorder.capture(identity.value, draft, value)
        }
    }
}

private final class ProbeIdentity: ObservableObject {
    let value = UUID()
}

@main struct AdaptiveWorkbenchIdentityTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let recorder = Recorder()
        let host = NSHostingView(rootView: AdaptiveWorkbenchSplit(listWidth: 260) {
            Text("Pull requests").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            DraftProbe(recorder: recorder)
        })
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 620, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        precondition(recorder.appeared.count == 1, "The draft probe must mount once")
        let initialIdentity = recorder.appeared[0]
        recorder.requestedDraft = "Unsent review comment — keep my metadata edits"
        recorder.writeRequest += 1
        settle()
        precondition(recorder.samples.last?.1 == recorder.requestedDraft, "The simulated draft edit must reach local State")
        var widths: [Int] = []
        for width in [800, 620, 800, 620] {
            window.setContentSize(NSSize(width: width, height: 600))
            settle()
            precondition(recorder.appeared.count == 1, "Changing layout must not remount the draft editor")
            precondition(recorder.samples.allSatisfy { $0.0 == initialIdentity }, "Local State identity changed at the responsive boundary")
            precondition(recorder.samples.last?.1 == recorder.requestedDraft, "Resizing discarded an unsent draft")
            widths.append(width)
        }
        let result: [String: Any] = ["ok": true, "initialWidth": 620, "resizedWidths": widths,
                                     "probeMounts": recorder.appeared.count, "uniqueStateIdentities": Set(recorder.samples.map { $0.0 }).count,
                                     "draftPreserved": recorder.samples.last?.1 == recorder.requestedDraft,
                                     "sampleCount": recorder.samples.count]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        window.orderOut(nil)
    }
}
