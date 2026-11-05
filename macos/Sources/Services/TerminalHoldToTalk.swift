import AppKit
import Combine

/// Ctrl-Shift-Space is local to one Gitrochi window and its attached voice-input sheet.
@MainActor final class TerminalHoldToTalk {
    enum Action: Equatable { case begin, finish, cancel }

    /// A latched Space key survives modifier releases and ignores keyboard auto-repeat.
    struct Gesture {
        enum Input { case press(isRepeat: Bool), release, escape, lostContext }
        private(set) var isHolding = false

        mutating func handle(_ input: Input) -> Action? {
            switch input {
            case .press(let repeatEvent):
                guard !isHolding, !repeatEvent else { return nil }
                isHolding = true
                return .begin
            case .release:
                guard isHolding else { return nil }
                isHolding = false
                return .finish
            case .escape, .lostContext:
                guard isHolding else { return nil }
                isHolding = false
                return .cancel
            }
        }
    }

    private let isEligible: () -> Bool
    private let begin: () -> Void
    private let finish: () -> Void
    private let cancel: () -> Void
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observations: [AnyCancellable] = []
    private var gesture = Gesture()

    var isHolding: Bool { gesture.isHolding }

    init(isEligible: @escaping () -> Bool = { true }, begin: @escaping () -> Void,
         finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.isEligible = isEligible
        self.begin = begin
        self.finish = finish
        self.cancel = cancel
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func activate(in window: NSWindow?) {
        guard let window else { deactivate(); return }
        if self.window === window, monitor != nil {
            if !isEligible() { cancelHold() }
            return
        }
        deactivate()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        observations = [
            center.publisher(for: NSApplication.willResignActiveNotification).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelHold() }
            },
            center.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.belongs(notification.object as? NSWindow) else { return }
                    self.cancelHold()
                }
            },
            center.publisher(for: NSWindow.willCloseNotification).sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongs(notification.object as? NSWindow) else { return }
                    self.cancelHold()
                }
            },
            center.publisher(for: NSWindow.didMiniaturizeNotification).sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongs(notification.object as? NSWindow) else { return }
                    self.cancelHold()
                }
            }
        ]
    }

    func deactivate() {
        cancelHold()
        if let monitor {
            self.monitor = nil
            NSEvent.removeMonitor(monitor)
        }
        observations.removeAll()
        window = nil
    }

    static func matchesChord(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 49 && modifiers.intersection([.control, .option, .command, .shift]) == [.control, .shift]
    }

    private func belongs(_ candidate: NSWindow?) -> Bool {
        guard let window, let candidate else { return false }
        return candidate === window || candidate === window.attachedSheet || candidate.sheetParent === window
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let eligible = isEligible() && belongs(event.window ?? NSApp.keyWindow)
        if isHolding && !eligible { cancelHold(); return event }
        guard eligible else { return event }
        if event.type == .keyDown, event.keyCode == 53, isHolding {
            perform(gesture.handle(.escape))
            return nil
        }
        if event.type == .keyUp, event.keyCode == 49, isHolding {
            perform(gesture.handle(.release))
            return nil
        }
        if event.type == .keyDown, event.keyCode == 49 {
            // Once latched, repeats remain consumed even if Control or Shift was released first.
            if isHolding { return nil }
            if Self.matchesChord(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                perform(gesture.handle(.press(isRepeat: event.isARepeat)))
                return nil
            }
        }
        return event
    }

    private func cancelHold() { perform(gesture.handle(.lostContext)) }

    private func perform(_ action: Action?) {
        switch action {
        case .begin: begin()
        case .finish: finish()
        case .cancel: cancel()
        case nil: break
        }
    }
}
