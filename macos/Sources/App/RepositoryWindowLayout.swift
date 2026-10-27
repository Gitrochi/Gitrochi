import AppKit
import ObjectiveC

/// Keeps repository content inside AppKit's toolbar and native-tab layout boundary.
@MainActor
enum RepositoryWindowLayout {
    private static var attachmentKey: UInt8 = 0

    static func configure(_ window: NSWindow) {
        if let attachment = objc_getAssociatedObject(window, &attachmentKey) as? Attachment {
            attachment.containContent()
            return
        }
        let attachment = Attachment(window: window)
        objc_setAssociatedObject(window, &attachmentKey, attachment, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        attachment.containContent()
    }

    @MainActor private final class Attachment {
        private weak var window: NSWindow?
        private var styleObservation: NSKeyValueObservation?
        private var tokens: [NSObjectProtocol] = []
        private var transitioning = false
        private var applying = false
        private var scheduled = false
        private var frameBeforeStyleChange: NSRect?
        private var frameAfterStyleChange: NSRect?
        private var restorationID = UUID()

        init(window: NSWindow) {
            self.window = window
            // SwiftUI reinstalls full-size content when its toolbar or hosting root changes.
            // Observe the window for its lifetime, including restored tabs attached later.
            styleObservation = window.observe(\.styleMask, options: [.prior]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.styleChanged(prior: change.isPrior) }
            }
            let center = NotificationCenter.default
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.transitioning = true
                        self?.restorationID = UUID()
                        self?.frameBeforeStyleChange = nil
                        self?.frameAfterStyleChange = nil
                    }
                })
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.transitioning = false
                        self?.containContent()
                    }
                })
            }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

        private func styleChanged(prior: Bool) {
            guard let window, !applying, !transitioning else { return }
            if prior {
                if frameBeforeStyleChange == nil {
                    restorationID = UUID()
                    frameBeforeStyleChange = window.frame
                }
                return
            }
            guard !scheduled else { return }
            frameAfterStyleChange = window.frame
            scheduled = true
            // Let AppKit finish the original style change before repairing its geometry.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.containContent()
                self.frameBeforeStyleChange = nil
                self.frameAfterStyleChange = nil
            }
        }

        func containContent() {
            guard let window, !applying, !transitioning, window.styleMask.contains(.fullSizeContentView) else { return }
            applying = true
            defer { applying = false }
            restorationID = UUID()
            // Honor a subsequent restored frame or explicit resize before this turn runs.
            let frame = frameAfterStyleChange.map { $0 != window.frame } == true
                ? window.frame : (frameBeforeStyleChange ?? window.frame)
            window.styleMask.remove(.fullSizeContentView)
            // Changing the style must not resize or reposition a restored window.
            if window.frame != frame { window.setFrame(frame, display: false) }
            let pendingFrame = window.frame
            guard pendingFrame != frame else { return }
            let restoration = restorationID
            // Constrained windows can reject this resize until AppKit finishes the style layout.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.restorationID == restoration,
                      !self.applying, !self.transitioning, !window.styleMask.contains(.fullSizeContentView),
                      window.frame == pendingFrame else { return }
                window.setFrame(frame, display: false)
            }
        }
    }
}
