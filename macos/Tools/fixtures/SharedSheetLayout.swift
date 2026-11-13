import AppKit
import Observation
import SwiftUI

struct SheetLayoutProbe: NSViewRepresentable {
    let identifier: String
    final class Probe: NSView {
        var fixtureIdentifier = ""
    }
    func makeNSView(context: Context) -> NSView {
        let view = Probe(); view.fixtureIdentifier = identifier; return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.fixtureIdentifier = identifier }
}

@MainActor @Observable private final class SheetFixtureModel {
    var reason: String? = "Enter a new branch name"
    var confirmed = 0
    var tested = 0
    var cancelled = 0
    var name = ""
}

/// The production layout as a system sheet holds it: nothing around it, so its own size is the sheet's size
private struct FixtureSheet: View {
    @Bindable var model: SheetFixtureModel

    var body: some View {
        SharedSheet(title: "Start agent session", context: "desktop · feature/shared-sheet", width: 480,
                    primary: SheetPrimary(title: "Start", disabledReason: model.reason) { model.confirmed += 1 },
                    cancel: { model.cancelled += 1 }) {
            Button("Test") { model.tested += 1 }.background(SheetLayoutProbe(identifier: "secondary"))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Sheet content")
                TextField("New branch name", text: $model.name).textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(SheetLayoutProbe(identifier: "sheet"))
    }
}

@main private struct SharedSheetLayoutFixture {
    @MainActor static func main() throws {
        precondition(CommandLine.arguments.count >= 2, "Pass the output folder")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        for appearance in ["light", "dark"] {
            let model = SheetFixtureModel()
            let host = NSHostingController(rootView: FixtureSheet(model: model)
                .background(Color(nsColor: .windowBackgroundColor))
                .tint(Color(nsColor: .systemBlue)).preferredColorScheme(appearance == "dark" ? .dark : .light))
            // a system sheet is as large as its content asks to be
            let size = host.sizeThatFits(in: CGSize(width: 2000, height: 2000))
            precondition(abs(size.width - 480) <= 1, "The sheet keeps its width: \(size.width)")
            precondition(size.height > 240 && size.height < 320, "The sheet is as tall as what it holds: \(size.height)")
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func probes() -> [SheetLayoutProbe.Probe] { descendants(host.view).compactMap { $0 as? SheetLayoutProbe.Probe } }
            func settle(_ duration: TimeInterval = 0.3) {
                let deadline = Date().addingTimeInterval(duration)
                repeat {
                    host.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
                    app.updateWindows(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                } while Date() < deadline
            }
            /// A probe's frame with the origin at the sheet's top left
            func frame(_ identifier: String) -> CGRect? {
                guard let probe = probes().first(where: { $0.fixtureIdentifier == identifier }) else { return nil }
                let frame = probe.convert(probe.bounds, to: host.view)
                return host.view.isFlipped ? frame : CGRect(x: frame.minX, y: host.view.bounds.maxY - frame.maxY, width: frame.width, height: frame.height)
            }
            func click(_ identifier: String) {
                guard let probe = probes().first(where: { $0.fixtureIdentifier == identifier }) else { fatalError("Missing control: " + identifier) }
                let point = probe.convert(NSPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                }
                // native buttons track until mouse-up; queue it before delivering mouse-down
                app.postEvent(events[1], atStart: true)
                window.sendEvent(events[0])
                settle()
            }
            func shoot(_ name: String) throws {
                guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not allocate the preview") }
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + "-" + appearance + ".png"))
            }
            func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1) -> Bool { abs(a - b) <= tolerance }

            settle()
            guard let sheet = frame("sheet"), let title = frame("title"), let context = frame("context"), let secondary = frame("secondary"),
                  let cancel = frame("cancel"), let reason = frame("reason"), let primary = frame("primary") else { fatalError("One of the sheet's parts is missing") }
            // header: the title and one context line in 20 pt of padding
            precondition(near(title.minX - sheet.minX, 20) && near(title.minY - sheet.minY, 20), "The header needs 20 pt of padding: \(title)")
            precondition(title.height >= 18 && title.height <= 22 && context.height >= 14 && context.height <= 18 && context.minY >= title.maxY - 1, "A 15 pt title over one 12 pt context line: \(title) \(context)")
            // footer: secondary on the left; on the right Cancel, the reason, then the one primary
            precondition(near(secondary.minX - sheet.minX, 20, 2) && near(sheet.maxX - primary.maxX, 20, 2), "The footer keeps 20 pt at both sides: \(secondary) \(primary)")
            precondition(secondary.maxX <= cancel.minX - 40 && cancel.maxX <= reason.minX && reason.maxX <= primary.minX, "Footer order must be secondary · Cancel · reason · primary")
            precondition(near(primary.minX - reason.maxX, 8, 3), "The reason sits 8 pt before its button: \(primary.minX - reason.maxX)")
            precondition(near(sheet.maxY - primary.midY, 28, 3), "The footer is 56 pt tall: \(sheet.maxY - primary.midY)")
            try shoot("shared-sheet-reason")

            // a blocked primary does nothing; without a reason it stands alone and works
            click("primary")
            precondition(model.confirmed == 0, "A blocked primary must not act")
            model.reason = nil
            settle()
            precondition(frame("reason") == nil, "The reason goes once the primary can be used")
            click("secondary"); click("primary"); click("cancel")
            precondition(model.tested == 1 && model.confirmed == 1 && model.cancelled == 1, "The footer's actions must run: \(model.tested) \(model.confirmed) \(model.cancelled)")
            try shoot("shared-sheet-ready")
            print("PASS shared sheet " + appearance)
            fflush(stdout)
            window.orderOut(nil); window.contentViewController = nil
        }
        print("Shared sheet layout previews: " + output.path)
    }
}
