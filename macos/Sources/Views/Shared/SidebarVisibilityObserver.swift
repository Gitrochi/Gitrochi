import SwiftUI
import AppKit

/// SwiftUI의 열 바인딩이 갱신되지 않는 자동 접힘도 실제 분할 화면에서 확인한다.
struct SidebarVisibilityObserver: NSViewRepresentable {
    var expandRequest = 0
    var animateExpansion = false
    var expansionAllowed = true
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarVisibilityProbe {
        SidebarVisibilityProbe(onChange: onChange)
    }

    func updateNSView(_ view: SidebarVisibilityProbe, context: Context) {
        view.onChange = onChange
        view.animateExpansion = animateExpansion
        view.expansionAllowed = expansionAllowed
        view.requestExpansion(expandRequest, allowed: expansionAllowed)
        view.scheduleMeasurement()
    }
}

@MainActor final class SidebarVisibilityProbe: NSView {
    var onChange: (Bool) -> Void
    var animateExpansion = false
    /// False while the app wants the list folded; the width fix must not touch a list that is folding
    var expansionAllowed = true
    private var lastValue: Bool?
    private var measurementScheduled = false
    private var wasAttachedToWindow = false
    private var ancestorIDs: [ObjectIdentifier] = []
    private var notifications: [NSObjectProtocol] = []
    private var hiddenObservers: [NSKeyValueObservation] = []
    private var lastExpandRequest = 0
    private var pendingExpansion = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshObservers()
        scheduleMeasurement()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wasAttachedToWindow = true }
        refreshObservers()
        if pendingExpansion { expandContainingSidebar() }
        scheduleMeasurement()
    }

    override func layout() {
        super.layout()
        refreshObservers()
        scheduleMeasurement()
    }

    /// SwiftUI의 렌더링 중 State를 바꾸지 않고 한 번의 배치가 끝난 뒤 측정한다.
    func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            self.refreshObservers()
            guard let collapsed = self.measuredCollapse() else { return }
            if !collapsed { self.scheduleWidthCorrection() }
            guard collapsed != self.lastValue else { return }
            self.lastValue = collapsed
            self.onChange(collapsed)
        }
    }

    private var widthCorrectionScheduled = false
    /// AppKit opens a window's page list at 144pt, below its 210pt minimum, and SwiftUI's column width does not move it.
    /// A list that has settled that narrow opens at the design's 240pt. The width must hold still for a moment first,
    /// so a collapse or expand animation passing through a narrow width is left alone, and a list the app is folding
    /// is never touched: moving its divider mid-collapse would open it again.
    private func scheduleWidthCorrection() {
        guard expansionAllowed, !widthCorrectionScheduled, let (split, column) = sidebarColumn() else { return }
        let width = column.frame.width
        guard !split.isSubviewCollapsed(column), width > 1, width < 210 else { return }
        widthCorrectionScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.widthCorrectionScheduled = false
            guard self.expansionAllowed, let (split, column) = self.sidebarColumn(), !split.isSubviewCollapsed(column) else { return }
            if column.frame.width == width {
                split.setPosition(240, ofDividerAt: 0)
            } else {
                self.scheduleWidthCorrection()
            }
        }
    }

    /// The split view's leading column that holds this probe
    private func sidebarColumn() -> (NSSplitView, NSView)? {
        var child: NSView = self
        while let parent = child.superview {
            if let split = parent as? NSSplitView, split.isVertical, split.arrangedSubviews.first === child {
                return (split, child)
            }
            child = parent
        }
        return nil
    }

    /// 바인딩이 이미 .all인 채 네이티브 화면만 접혀도 이 창의 사이드바를 펼친다.
    func requestExpansion(_ request: Int, allowed: Bool = true) {
        // A quick collapse must cancel an expansion queued before the next layout.
        guard allowed else {
            lastExpandRequest = request
            pendingExpansion = false
            return
        }
        guard request != lastExpandRequest else { return }
        lastExpandRequest = request
        pendingExpansion = true
        DispatchQueue.main.async { [weak self] in self?.expandContainingSidebar() }
    }

    private func expandContainingSidebar() {
        guard pendingExpansion, window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical {
                var responder: NSResponder? = split
                while let current = responder {
                    if let controller = current as? NSSplitViewController,
                       let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) }) {
                        if item.isCollapsed {
                            if animateExpansion {
                                NSAnimationContext.runAnimationGroup { context in
                                    context.duration = 0.24
                                    item.animator().isCollapsed = false
                                }
                            } else {
                                item.isCollapsed = false
                            }
                        }
                        pendingExpansion = false
                        scheduleMeasurement()
                        return
                    }
                    responder = current.nextResponder
                }
            }
            ancestor = view.superview
        }
    }

    private func measuredCollapse() -> Bool? {
        guard window != nil else { return wasAttachedToWindow ? true : nil }
        var child: NSView = self
        while let parent = child.superview {
            if let split = parent as? NSSplitView, split.isVertical,
               split.arrangedSubviews.contains(where: { $0 === child }) {
                return split.isSubviewCollapsed(child) || child.isHiddenOrHasHiddenAncestor
                    || child.frame.width <= 1 || child.bounds.width <= 1
            }
            child = parent
        }
        // 접혔던 사이드바가 임시 오버레이로 나타나는 경우에도 실제 표시 상태를 따른다.
        if isHiddenOrHasHiddenAncestor { return true }
        return bounds.width > 1 ? false : nil
    }

    private func refreshObservers() {
        var ancestors: [NSView] = []
        var current: NSView? = self
        while let view = current {
            ancestors.append(view)
            current = view.superview
        }
        let ids = ancestors.map(ObjectIdentifier.init)
        guard ids != ancestorIDs else { return }
        ancestorIDs = ids
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        hiddenObservers.removeAll()
        let center = NotificationCenter.default
        for view in ancestors {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                notifications.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.scheduleMeasurement() }
                })
            }
            hiddenObservers.append(view.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.scheduleMeasurement() }
            })
        }
        // 분할 뷰가 sidebar 컨테이너를 재배치할 때도 새 조상을 찾아낸다.
        notifications.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleMeasurement() }
        })
        if let window {
            notifications.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                    object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.scheduleMeasurement() }
            })
        }
    }

    deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
}
