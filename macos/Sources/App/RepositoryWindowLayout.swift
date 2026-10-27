import AppKit
import ObjectiveC

/// Keep repository content below the native titlebar, toolbar, and tab bar.
@MainActor
enum RepositoryWindowLayout {
    private static var attachmentKey: UInt8 = 0

    static func configure(_ window: NSWindow) {
        if let attachment = objc_getAssociatedObject(window, &attachmentKey) as? Attachment {
            attachment.containContent(preserving: window.frame)
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

        init(window: NSWindow) {
            self.window = window
            // SwiftUI can restore full-size content when its toolbar or hosting root changes.
            // Keep the sidebar below the native header for the lifetime of each window.
            styleObservation = window.observe(\.styleMask, options: [.prior]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.styleChanged(prior: change.isPrior) }
            }
            let center = NotificationCenter.default
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.transitioning = true
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
                // Honor a resize or restored frame between coalesced style changes.
                if frameBeforeStyleChange == nil || frameAfterStyleChange.map({ $0 != window.frame }) == true {
                    frameBeforeStyleChange = window.frame
                }
                return
            }
            frameAfterStyleChange = window.frame
            guard !scheduled else { return }
            scheduled = true
            // Let AppKit finish the style change and coalesce repeated updates.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.containContent()
                self.frameBeforeStyleChange = nil
                self.frameAfterStyleChange = nil
            }
        }

        func containContent(preserving preservedFrame: NSRect? = nil) {
            if let preservedFrame {
                frameBeforeStyleChange = preservedFrame
                frameAfterStyleChange = preservedFrame
            }
            guard let window, !applying, !transitioning, window.styleMask.contains(.fullSizeContentView) else { return }
            applying = true
            defer { applying = false }
            // Prefer any explicit resize or restored frame applied after the style update.
            let frame = preservedFrame ?? (frameAfterStyleChange.map { $0 != window.frame } == true
                ? window.frame : (frameBeforeStyleChange ?? window.frame))
            window.styleMask.remove(.fullSizeContentView)
            if window.frame != frame { window.setFrame(frame, display: false) }
            if preservedFrame != nil {
                frameBeforeStyleChange = window.frame
                frameAfterStyleChange = window.frame
            }
        }
    }
}
