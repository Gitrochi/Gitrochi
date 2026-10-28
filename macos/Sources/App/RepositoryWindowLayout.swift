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

    /// Distinguishes SwiftUI's minimum-size reflow from a later restored frame.
    static func restorationFrame(before: NSRect?, after: NSRect?, current: NSRect, minimum: NSSize, inLiveResize: Bool = false) -> NSRect {
        guard let before else { return current }
        guard let after, after != current else { return before }
        // The style change shrinks the frame in place and SwiftUI grows it back to its minimum height, keeping the
        // temporary content top. A tab bar's extra height makes this happen above the minimum too.
        let reflowedMinimum = !inLiveResize
            && before.origin == after.origin && before.width == after.width && after.height < before.height
            && current.minX == before.minX && current.width == before.width && current.maxY == after.maxY
            && current.height == minimum.height && current.height <= before.height
        return reflowedMinimum ? before : current
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
                // Honor a resize or restored frame between coalesced style changes.
                if frameBeforeStyleChange == nil || frameAfterStyleChange.map({ $0 != window.frame }) == true {
                    restorationID = UUID()
                    frameBeforeStyleChange = RepositoryWindowLayout.restorationFrame(before: frameBeforeStyleChange, after: frameAfterStyleChange,
                        current: window.frame, minimum: window.minSize, inLiveResize: window.inLiveResize)
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

        func containContent(preserving requestedFrame: NSRect? = nil) {
            let preservedFrame = requestedFrame.map { frame in
                guard let window, window.styleMask.contains(.fullSizeContentView) else { return frame }
                return RepositoryWindowLayout.restorationFrame(before: frameBeforeStyleChange, after: frameAfterStyleChange,
                    current: frame, minimum: window.minSize, inLiveResize: window.inLiveResize)
            }
            if let preservedFrame {
                restorationID = UUID()
                frameBeforeStyleChange = preservedFrame
                frameAfterStyleChange = preservedFrame
            }
            guard let window, !applying, !transitioning, window.styleMask.contains(.fullSizeContentView) else { return }
            applying = true
            defer { applying = false }
            restorationID = UUID()
            // Prefer an explicit resize while excluding SwiftUI's minimum-size reflow.
            let frame = preservedFrame ?? RepositoryWindowLayout.restorationFrame(before: frameBeforeStyleChange, after: frameAfterStyleChange,
                current: window.frame, minimum: window.minSize, inLiveResize: window.inLiveResize)
            window.styleMask.remove(.fullSizeContentView)
            if window.frame != frame { window.setFrame(frame, display: false) }
            if preservedFrame != nil {
                frameBeforeStyleChange = window.frame
                frameAfterStyleChange = window.frame
            }
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
