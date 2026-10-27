import SwiftUI
import AppKit

/// Toolbar text is a Gitrochi setting (Settings > Appearance): ToolLabel draws each title beside its icon.
/// AppKit's own "Icon and Text" would put titles under the icons, and SwiftUI resets that mode anyway, so the toolbar
/// keeps icons only and its context menu no longer offers display modes. (Windows has no toolbar text option.)
enum ToolbarTitles {
    static let key = "toolbarShowsTitles"

    struct Observer: NSViewRepresentable {
        func makeNSView(context: Context) -> ObserverView { ObserverView() }
        func updateNSView(_ view: ObserverView, context: Context) {}
    }

    final class ObserverView: NSView {
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.toolbar, options: [.initial, .new]) { window, _ in
                MainActor.assumeIsolated { ToolbarTitles.configure(window.toolbar) }
            }
            // SwiftUI may install the toolbar after the view joins the window
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { ToolbarTitles.configure(self?.window?.toolbar) }
            }
        }
    }

    @MainActor static func configure(_ toolbar: NSToolbar?) {
        guard let toolbar else { return }
        if toolbar.allowsDisplayModeCustomization { toolbar.allowsDisplayModeCustomization = false }
        if toolbar.displayMode != .iconOnly { toolbar.displayMode = .iconOnly }
    }
}
