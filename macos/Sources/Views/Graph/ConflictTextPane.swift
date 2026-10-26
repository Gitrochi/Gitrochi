import SwiftUI
import AppKit

/// 줄 길이가 다른 결과도 같은 상대 위치로 스크롤해 세 파일을 함께 비교한다.
@MainActor final class ConflictScrollGroup {
    private let views = NSHashTable<NSScrollView>.weakObjects()
    private var syncing = false
    func add(_ view: NSScrollView) { views.add(view) }
    func scroll(_ source: NSScrollView) {
        guard !syncing, let document = source.documentView else { return }
        syncing = true
        defer { syncing = false }
        let ratio = source.contentView.bounds.origin.y / max(1, document.bounds.height - source.contentView.bounds.height)
        for view in views.allObjects where view !== source {
            guard let target = view.documentView else { continue }
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.origin.x, y: ratio * max(0, target.bounds.height - view.contentView.bounds.height)))
            view.reflectScrolledClipView(view.contentView)
        }
    }
}

struct ConflictTextPane: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let group: ConflictScrollGroup
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero)
        view.isEditable = editable; view.isSelectable = true; view.isRichText = false; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true; view.autoresizingMask = []
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false; view.textContainerInset = NSSize(width: 7, height: 7)
        view.string = text; view.delegate = context.coordinator
        scroll.documentView = view; scroll.contentView.postsBoundsChangedNotifications = true
        group.add(scroll)
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll, weak group] _ in
            MainActor.assumeIsolated { if let scroll { group?.scroll(scroll) } }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { let selection = view.selectedRange(); view.string = text; if NSMaxRange(selection) <= (text as NSString).length { view.setSelectedRange(selection) } }
        view.isEditable = editable
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConflictTextPane
        var observer: NSObjectProtocol?
        init(_ parent: ConflictTextPane) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
    }
}
