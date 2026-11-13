import AppKit
import Observation
import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>

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
    var open = false
    var reason: String? = "Enter a new branch name"
    var confirmed = 0
    var tested = 0
    var behind = 0
    var dismissed = 0
    var name = ""
    var search = ""
}

private struct FixtureSheet: View {
    @Bindable var model: SheetFixtureModel
    @Environment(\.closeSheet) private var closeSheet

    var body: some View {
        SharedSheet(title: "Start agent session", context: "desktop · feature/shared-sheet", width: 480,
                    primary: SheetPrimary(title: "Start", disabledReason: model.reason) { model.confirmed += 1 },
                    cancel: { closeSheet() }) {
            Button("Test") { model.tested += 1 }.background(SheetLayoutProbe(identifier: "secondary"))
        } content: {
            // a scrolling body, as most sheets have: the sheet is as tall as what it holds, not as the window
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "Sheet content")
                    TextField("New branch name", text: $model.name).textFieldStyle(.roundedBorder).background(SheetLayoutProbe(identifier: "field"))
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
    }
}

/// A window's content with a control behind where the sheet hangs
private struct FixtureWindow: View {
    @Bindable var model: SheetFixtureModel
    /// Settings and the system's own sheets have no host
    var hosted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<6, id: \.self) { row in
                Text(verbatim: "Commit \(row + 1)").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                    .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 200).background(SheetLayoutProbe(identifier: "search"))
            Button("Behind") { model.behind += 1 }.background(SheetLayoutProbe(identifier: "behind"))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioStyle.canvas)
        .attachedSheet(isPresented: $model.open, onDismiss: { model.dismissed += 1 }) { FixtureSheet(model: model) }
        .modifier(FixtureHost(hosted: hosted))
    }
}

private struct FixtureHost: ViewModifier {
    let hosted: Bool

    func body(content: Content) -> some View {
        if hosted { content.sharedSheetHost() } else { content }
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
            let size = CGSize(width: 900, height: 560)
            let host = NSHostingController(rootView: FixtureWindow(model: model)
                .tint(Color(nsColor: .systemBlue)).preferredColorScheme(appearance == "dark" ? .dark : .light))
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
            /// A probe's frame with the origin at the window content's top left
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
            func bitmap() -> NSBitmapImageRep {
                guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { fatalError("Could not allocate the preview") }
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                return bitmap
            }
            /// The page's colour beside where the sheet hangs
            func page(_ bitmap: NSBitmapImageRep) -> [Int] {
                let scale = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
                guard let color = bitmap.colorAt(x: Int(60 * scale), y: Int(8 * scale))?.usingColorSpace(.sRGB) else { fatalError("Could not read the page colour") }
                return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
            }
            /// Where the field being edited is, with the origin at the window content's top left
            func caret() -> CGRect? {
                guard let editor = window.firstResponder as? NSView, editor !== host.view else { return nil }
                let frame = editor.convert(editor.bounds, to: host.view)
                return host.view.isFlipped ? frame : CGRect(x: frame.minX, y: host.view.bounds.maxY - frame.maxY, width: frame.width, height: frame.height)
            }
            func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1) -> Bool { abs(a - b) <= tolerance }

            settle()
            precondition(frame("sheet") == nil && !SharedSheetPresenter.isPresenting(in: window), "No sheet before one is asked for")
            let before = page(bitmap())
            click("behind")
            precondition(model.behind == 1, "The page takes clicks while no sheet is open")

            // the caret is in the page's field before the sheet opens
            click("search")
            precondition(caret().map { $0.intersects(frame("search")!) } == true, "The page's field takes the keys: \(String(describing: window.firstResponder))")
            model.open = true
            settle(0.5)
            // like the system's sheets, the caret moves to the sheet's first field
            precondition(caret().map { $0.intersects(frame("field")!) } == true, "The sheet's first field must take the keys: \(String(describing: window.firstResponder))")
            guard let sheet = frame("sheet"), let title = frame("title"), let context = frame("context"), let secondary = frame("secondary"),
                  let cancel = frame("cancel"), let reason = frame("reason"), let primary = frame("primary") else { fatalError("The sheet or one of its parts is missing") }
            let bounds = host.view.bounds
            // attached: it hangs from the content's top edge (under the toolbar), centred, and the page is not dimmed
            precondition(near(sheet.minY, 0), "The sheet must hang from the top edge: \(sheet.minY)")
            precondition(near(sheet.midX, bounds.midX), "The sheet must be horizontally centred: \(sheet.midX) in \(bounds.width)")
            precondition(near(sheet.width, 480), "The sheet keeps its width: \(sheet.width)")
            precondition(sheet.height > 200 && sheet.height < 320, "The sheet is as tall as what it holds: \(sheet.height)")
            let shown = bitmap()
            precondition(zip(before, page(shown)).allSatisfy { abs($0 - $1) <= 1 }, "The window behind a sheet must not be dimmed: \(before) became \(page(shown))")
            precondition(SharedSheetPresenter.isPresenting(in: window), "Key handlers must be able to tell that a sheet is open")
            // header: the title and one context line in 20 pt of padding
            precondition(near(title.minX - sheet.minX, 20) && near(title.minY - sheet.minY, 20), "The header needs 20 pt of padding: \(title)")
            precondition(title.height >= 18 && title.height <= 22 && context.height >= 14 && context.height <= 18 && context.minY >= title.maxY - 1, "A 15 pt title over one 12 pt context line: \(title) \(context)")
            // footer: secondary on the left; on the right Cancel, the reason, then the one primary
            precondition(near(secondary.minX - sheet.minX, 20, 2) && near(sheet.maxX - primary.maxX, 20, 2), "The footer keeps 20 pt at both sides: \(secondary) \(primary)")
            precondition(secondary.maxX <= cancel.minX - 40 && cancel.maxX <= reason.minX && reason.maxX <= primary.minX, "Footer order must be secondary · Cancel · reason · primary")
            precondition(near(primary.minX - reason.maxX, 8, 3), "The reason sits 8 pt before its button: \(primary.minX - reason.maxX)")
            precondition(near(sheet.maxY - primary.midY, 28, 3), "The footer is 56 pt tall: \(sheet.maxY - primary.midY)")
            try shown.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("shared-sheet-reason-\(appearance).png"))

            // a blocked primary does nothing, and nothing behind the sheet takes a click
            click("primary")
            click("behind")
            precondition(model.confirmed == 0 && model.behind == 1, "A blocked primary and the page behind must not act: \(model.confirmed) \(model.behind)")
            model.reason = nil
            settle()
            precondition(frame("reason") == nil, "The reason goes once the primary can be used")
            click("secondary"); click("primary")
            precondition(model.tested == 1 && model.confirmed == 1, "The footer's actions must run: \(model.tested) \(model.confirmed)")
            try bitmap().representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("shared-sheet-ready-\(appearance).png"))

            // Cancel closes it through closeSheet, and the page works again
            click("cancel")
            settle(0.5)
            precondition(!model.open && model.dismissed == 1 && frame("sheet") == nil, "Cancel must close the sheet once: \(model.open) \(model.dismissed)")
            precondition(!SharedSheetPresenter.isPresenting(in: window), "A closed sheet must give the keys back")
            precondition(caret().map { $0.intersects(frame("search")!) } == true, "The keys go back to where they were: \(String(describing: window.firstResponder))")
            click("behind")
            precondition(model.behind == 2, "The page takes clicks again after the sheet closes")
            // a window without a host shows the same sheet as the system's
            let plain = SheetFixtureModel()
            let plainHost = NSHostingController(rootView: FixtureWindow(model: plain, hosted: false))
            let plainWindow = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 800), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            plainWindow.isReleasedWhenClosed = false
            plainWindow.contentViewController = plainHost; plainWindow.setContentSize(size); plainWindow.orderBack(nil)
            settle()
            plain.open = true
            settle(1)
            precondition(plainWindow.attachedSheet != nil && !SharedSheetPresenter.isPresenting(in: plainWindow), "Without a host the sheet must be the system's")
            plain.open = false
            settle(1)
            precondition(plainWindow.attachedSheet == nil && plain.dismissed == 1, "The system's sheet must close with its binding: \(plain.dismissed)")
            plainWindow.orderOut(nil); plainWindow.contentViewController = nil
            print("PASS shared sheet " + appearance)
            fflush(stdout)
            window.orderOut(nil); window.contentViewController = nil
        }
        print("Shared sheet layout previews: " + output.path)
    }
}
