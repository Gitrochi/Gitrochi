import AppKit

private final class KeySink: NSView {
    var downs: [UInt16] = []
    var ups: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { downs.append(event.keyCode) }
    override func keyUp(with event: NSEvent) { ups.append(event.keyCode) }
}

private final class EventWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Native local-monitor coverage; posted events never enter the system keyboard stream.
@main private struct TerminalHoldEvents {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        func makeWindow() -> (EventWindow, KeySink) {
            let window = EventWindow(contentRect: NSRect(x: -4000, y: 100, width: 240, height: 120),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let sink = KeySink(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
            window.contentView = sink
            window.orderBack(nil)
            window.makeFirstResponder(sink)
            return (window, sink)
        }
        let (host, sink) = makeWindow()
        let (other, otherSink) = makeWindow()
        guard host.windowNumber > 0, other.windowNumber > 0 else {
            print("SKIP: Native terminal hold events require a WindowServer connection.")
            exit(77)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }
        func send(_ type: NSEvent.EventType, code: UInt16 = 49,
                  flags: NSEvent.ModifierFlags = [.control, .shift], repeatEvent: Bool = false, in window: NSWindow) {
            let characters = code == 53 ? "\u{1B}" : code == 0 ? "a" : " "
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeatEvent, keyCode: code) else { fatalError("Could not create an app-local key event") }
            app.postEvent(event, atStart: false)
            let deadline = Date().addingTimeInterval(0.03)
            while let next = app.nextEvent(matching: [.keyDown, .keyUp], until: deadline, inMode: .default, dequeue: true) {
                app.sendEvent(next)
                if Date() >= deadline { break }
            }
        }
        var eligible = true
        var actions: [String] = []
        let hold = TerminalHoldToTalk(isEligible: { eligible }, begin: { actions.append("begin") },
                                      finish: { actions.append("finish") }, cancel: { actions.append("cancel") })
        host.makeKey()
        hold.activate(in: host)
        send(.keyDown, code: 0, flags: [], in: host)
        check(sink.downs == [0], "Ordinary keys reach the window's real first responder")
        send(.keyDown, in: host)
        check(actions == ["begin"] && hold.isHolding, "The native local monitor begins on Ctrl-Shift-Space")
        check(sink.downs == [0], "The hold chord is consumed before terminal input")
        send(.keyDown, repeatEvent: true, in: host)
        send(.keyDown, flags: [], repeatEvent: true, in: host)
        check(actions == ["begin"] && sink.downs == [0], "Repeats are consumed after early modifier release")
        send(.keyUp, flags: [], in: host)
        check(actions == ["begin", "finish"] && !hold.isHolding, "Space release finalizes with no modifiers left")
        check(sink.ups.isEmpty, "The matching keyup is consumed too")

        actions.removeAll()
        send(.keyDown, flags: [.control, .option], in: host)
        check(actions.isEmpty && sink.downs.last == 49, "Input-source and VoiceOver chords are left alone")
        other.makeKey()
        send(.keyDown, in: other)
        check(actions.isEmpty && otherSink.downs == [49], "Events in another window never start a hold")
        host.makeKey()
        send(.keyDown, in: host)
        send(.keyDown, code: 53, flags: [], in: host)
        check(actions == ["begin", "cancel"] && !hold.isHolding, "Escape cancels native held input")
        send(.keyUp, flags: [], in: host)
        check(actions == ["begin", "cancel"], "Release after Escape cannot finalize")

        actions.removeAll()
        send(.keyDown, in: host)
        other.makeKey()
        // A prohibited fixture never activates over the user's app, so send the lifecycle notification explicitly.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        check(actions == ["begin", "cancel"], "The key-window notification cancels the held recording")

        actions.removeAll()
        let (sheet, _) = makeWindow()
        host.makeKey()
        send(.keyDown, in: host)
        host.beginSheet(sheet)
        check(hold.isHolding && sheet.sheetParent === host, "The composer sheet keeps the existing hold latched")
        send(.keyUp, flags: [], in: sheet)
        check(actions == ["begin", "finish"], "Keyup in the attached sheet finalizes the original hold")
        host.endSheet(sheet)
        sheet.orderOut(nil)

        actions.removeAll()
        send(.keyDown, in: host)
        eligible = false
        send(.keyDown, repeatEvent: true, in: host)
        check(actions == ["begin", "cancel"], "Losing pane eligibility cancels the native hold")
        eligible = true
        actions.removeAll()
        send(.keyDown, in: host)
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: app)
        check(actions == ["begin", "cancel"], "Application-deactivation notification cancels the native hold")

        actions.removeAll()
        send(.keyDown, in: host)
        hold.deactivate()
        check(actions == ["begin", "cancel"], "Deactivating removes an active hold safely")
        actions.removeAll()
        send(.keyDown, in: host)
        check(actions.isEmpty, "Removed local monitors cannot observe later events")
        hold.activate(in: host)
        send(.keyDown, in: host)
        host.close()
        check(actions == ["begin", "cancel"], "Closing the host cancels before its event target disappears")
        hold.deactivate()
        other.close()
        sheet.close()
        print("Native terminal hold events: \(checks) checks passed; no audio, permissions or global events used")
    }
}
