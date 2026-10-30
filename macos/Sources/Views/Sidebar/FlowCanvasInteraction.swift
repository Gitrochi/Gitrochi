import SwiftUI
import AppKit

/// Background dragging pans the native scroll view; pinch and modified wheel events zoom this canvas only.
struct FlowCanvasInteraction: NSViewRepresentable {
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> Surface { Surface(onZoom: onZoom) }
    func updateNSView(_ view: Surface, context: Context) { view.onZoom = onZoom }

    final class Surface: NSView {
        var onZoom: (CGFloat) -> Void
        private var monitor: Any?
        private var anchor: NSPoint?
        private var scrollOrigin: NSPoint?

        init(onZoom: @escaping (CGFloat) -> Void) { self.onZoom = onZoom; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .magnify {
                    self.onZoom(max(0.5, 1 + event.magnification))
                    return nil
                }
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                    self.onZoom(exp(-event.scrollingDeltaY * 0.015))
                    return nil
                }
                return event
            }
        }

        override func mouseDown(with event: NSEvent) {
            anchor = event.locationInWindow
            scrollOrigin = enclosingScrollView?.contentView.bounds.origin
            NSCursor.closedHand.push()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let anchor, let scrollOrigin, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let dx = event.locationInWindow.x - anchor.x
            let dy = event.locationInWindow.y - anchor.y
            let point = NSPoint(x: min(max(0, scrollOrigin.x - dx), max(0, document.frame.width - clip.bounds.width)),
                                y: min(max(0, scrollOrigin.y + dy), max(0, document.frame.height - clip.bounds.height)))
            clip.scroll(to: point)
            scroll.reflectScrolledClipView(clip)
        }
        override func mouseUp(with event: NSEvent) { anchor = nil; scrollOrigin = nil; NSCursor.pop() }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
