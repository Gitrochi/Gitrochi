import SwiftUI
import AppKit
import Observation

@MainActor @Observable private final class SidebarRecorder {
    var presentation = SidebarPresentationState()
    var suppressNativeVisibilityEcho = false
    var expandRequest = 0
    var visibility: NavigationSplitViewVisibility {
        get { presentation.visibility }
        set { if !suppressNativeVisibilityEcho { presentation.setVisibility(newValue) } }
    }
    var collapsed = false
    var reports: [Bool] = []
    var identity: UUID?
    var mounted = 0
    var draft = ""
    var writeRequest = 0
    var requestedDraft = ""
    var railVisible = false

    func measure(_ value: Bool) {
        collapsed = value
        reports.append(value)
    }
}

private final class DetailIdentity: ObservableObject {
    let value = UUID()
}

private struct DetailStateProbe: View {
    let recorder: SidebarRecorder
    @StateObject private var identity = DetailIdentity()
    @State private var draft = ""

    var body: some View {
        VStack {
            Text("Commit details").font(.headline)
            TextEditor(text: $draft)
        }
        .onAppear {
            recorder.identity = identity.value
            recorder.mounted += 1
        }
        .onChange(of: recorder.writeRequest) { _, _ in draft = recorder.requestedDraft }
        .onChange(of: draft) { _, value in recorder.draft = value }
    }
}

private struct SidebarFixture: View {
    @Bindable var recorder: SidebarRecorder

    private var railShown: Bool { recorder.visibility == .detailOnly || recorder.collapsed }

    var body: some View {
        NavigationSplitView(columnVisibility: $recorder.visibility) {
            List {
                Label("Repository", systemImage: "folder")
                Label("Pull requests", systemImage: "arrow.triangle.pull")
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
            .background(SidebarVisibilityObserver(expandRequest: recorder.expandRequest) { recorder.measure($0) })
            .disabled(railShown)
            .accessibilityHidden(railShown)
        } detail: {
            HStack(spacing: 0) {
                if railShown {
                    VStack { Image(systemName: "folder"); Image(systemName: "arrow.triangle.pull"); Spacer() }
                        .padding(.top, 12).frame(width: 48)
                }
                DetailStateProbe(recorder: recorder)
            }
            .onAppear { recorder.railVisible = railShown }
            .onChange(of: railShown) { _, value in recorder.railVisible = value }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 1180 } action: { narrow in
            recorder.presentation.setNarrow(narrow)
        }
    }
}

@main struct SidebarVisibilityTest {
    @MainActor static func main() {
        var automatic = SidebarPresentationState()
        automatic.setNarrow(true)
        precondition(automatic.isNarrow && automatic.visibility == .detailOnly)
        automatic.setVisibility(.detailOnly)
        automatic.setNarrow(false)
        precondition(automatic.visibility == .automatic, "An unchanged native echo must preserve automatic restoration")
        var manual = SidebarPresentationState()
        manual.setVisibility(.detailOnly)
        manual.setNarrow(true)
        manual.setNarrow(false)
        precondition(manual.visibility == .detailOnly, "Manual collapse must never be automatically expanded")
        manual.expand()
        manual.setNarrow(true)
        manual.expand()
        manual.setNarrow(false)
        precondition(manual.visibility == .all, "Explicit narrow expansion must survive widening")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let recorder = SidebarRecorder()
        let host = NSHostingView(rootView: SidebarFixture(recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1440, height: 650),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)

        func settle(_ duration: TimeInterval = 0.15) {
            let end = Date().addingTimeInterval(duration)
            repeat {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            } while Date() < end
            host.layoutSubtreeIfNeeded()
        }

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }

        func navigationSplit() -> NSSplitView {
            let splits = descendants(host).compactMap { $0 as? NSSplitView }
            guard let split = splits.first(where: { $0.isVertical && $0.arrangedSubviews.count == 2 }) else {
                fatalError("Actual NavigationSplitView did not create an NSSplitView")
            }
            return split
        }

        func splitController(_ split: NSSplitView) -> NSSplitViewController {
            var responder: NSResponder? = split
            while let value = responder {
                if let controller = value as? NSSplitViewController { return controller }
                responder = value.nextResponder
            }
            fatalError("The real navigation split view has no public NSSplitViewController responder")
        }

        func sidebarView(_ split: NSSplitView) -> NSView {
            guard let item = splitController(split).splitViewItems.first(where: { $0.behavior == .sidebar }) else {
                fatalError("Native split view must expose a sidebar item")
            }
            return item.viewController.view
        }

        func sidebarContainer(_ split: NSSplitView) -> NSView {
            var view = sidebarView(split)
            while let parent = view.superview, parent !== split { view = parent }
            precondition(view.superview === split, "The sidebar must belong to the native split view")
            return view
        }

        func checkRetainedState() {
            precondition(recorder.mounted == 1, "Sidebar changes must not remount the detail screen")
            precondition(recorder.identity == initialIdentity, "Sidebar changes replaced the detail identity")
            precondition(recorder.draft == recorder.requestedDraft, "Sidebar changes discarded the unsent draft")
        }

        settle(0.3)
        precondition(recorder.reports.last == false, "Expanded sidebar must be reported as visible")
        precondition(!recorder.railVisible, "Expanded sidebar must not duplicate navigation in a rail")
        let initialIdentity = recorder.identity
        precondition(initialIdentity != nil && recorder.mounted == 1)
        recorder.requestedDraft = "Unsent commit review — keep me across sidebar changes"
        recorder.writeRequest += 1
        settle()

        var checks: [[String: Any]] = []
        func capture(_ scenario: String) {
            checkRetainedState()
            let split = navigationSplit()
            checks.append(["scenario": scenario, "railVisible": recorder.railVisible,
                           "observerCollapsed": recorder.collapsed, "sidebarWidth": sidebarView(split).frame.width,
                           "bindingDetailOnly": recorder.visibility == .detailOnly])
        }

        recorder.visibility = .detailOnly
        settle(0.3)
        precondition(recorder.railVisible, "Explicit collapse must keep the icon rail visible")
        capture("binding-detail-only")
        recorder.visibility = .all
        settle(0.3)
        precondition(!recorder.railVisible, "Expanding the sidebar must remove the duplicate rail")
        capture("binding-expanded")

        let split = navigationSplit()
        let controller = splitController(split)
        controller.toggleSidebar(nil)
        settle(0.4)
        precondition(recorder.railVisible, "Native sidebar toggle must keep the icon rail visible")
        capture("native-sidebar-toggle")
        controller.toggleSidebar(nil)
        settle(0.4)
        precondition(!recorder.railVisible, "Native sidebar expand must remove the duplicate rail")
        capture("native-sidebar-expand")

        // 자동 레이아웃이 바인딩을 갱신하지 않고 뷰만 접는 경로도 별도로 검증한다.
        let nativeSidebar = sidebarContainer(navigationSplit())
        nativeSidebar.isHidden = true
        settle(0.25)
        precondition(recorder.visibility != .detailOnly, "The visibility-only case must not rely on the SwiftUI binding")
        precondition(recorder.collapsed && recorder.railVisible, "Actual hidden sidebar must reveal icons without a binding update")
        capture("native-visibility-only-collapse")
        nativeSidebar.isHidden = false
        settle(0.25)
        precondition(!recorder.collapsed && !recorder.railVisible, "Restored native visibility must remove the duplicate icons")
        capture("native-visibility-only-expand")

        recorder.suppressNativeVisibilityEcho = true
        let sidebarItem = controller.splitViewItems.first(where: { $0.behavior == .sidebar })!
        sidebarItem.isCollapsed = true
        settle(0.3)
        precondition(recorder.visibility == .all && recorder.collapsed && recorder.railVisible,
                     "The native-only collapse must retain an expanded binding for this regression")
        recorder.presentation.expand()
        recorder.expandRequest += 1
        settle(0.3)
        precondition(!sidebarItem.isCollapsed && !recorder.collapsed && !recorder.railVisible,
                     "The icon rail expansion must open the actual sidebar even when the binding was already expanded")
        recorder.suppressNativeVisibilityEcho = false
        capture("rail-expands-native-only-collapse")

        window.setContentSize(NSSize(width: 1100, height: 650))
        settle(0.4)
        precondition(recorder.visibility == .detailOnly && recorder.railVisible,
                     "A narrow window must automatically retain navigation as an icon rail")
        let narrowedSplit = navigationSplit()
        let narrowedSidebar = sidebarView(narrowedSplit)
        let actuallyCollapsed = narrowedSidebar.isHiddenOrHasHiddenAncestor || narrowedSidebar.frame.width <= 1
        precondition(recorder.collapsed == actuallyCollapsed, "Observer must follow actual native geometry at narrow widths")
        precondition(recorder.railVisible == (actuallyCollapsed || recorder.visibility == .detailOnly),
                     "Narrow windows must retain navigation whenever the sidebar is actually hidden")
        capture("automatic-narrow-1100")

        window.setContentSize(NSSize(width: 1440, height: 650))
        settle(0.4)
        precondition(!recorder.railVisible, "Wide expanded windows must restore the sidebar without duplicate icons")
        capture("automatic-restore-wide-1440")

        recorder.visibility = .detailOnly
        settle(0.25)
        window.setContentSize(NSSize(width: 1100, height: 650))
        settle(0.25)
        window.setContentSize(NSSize(width: 1440, height: 650))
        settle(0.3)
        precondition(recorder.visibility == .detailOnly && recorder.railVisible,
                     "Manual sidebar collapse must survive narrow and wide resizing")
        capture("manual-collapse-retained-wide")

        recorder.presentation.expand()
        settle(0.25)
        window.setContentSize(NSSize(width: 1100, height: 650))
        settle(0.3)
        recorder.presentation.expand()
        settle(0.3)
        precondition(recorder.visibility == .all && !recorder.railVisible,
                     "Users must be able to expand navigation while the window is narrow")
        capture("manual-expand-narrow")
        window.setContentSize(NSSize(width: 1440, height: 650))
        settle(0.3)
        precondition(recorder.visibility == .all && !recorder.railVisible,
                     "Widening must preserve the explicit narrow-window expansion")
        capture("manual-expand-retained-wide")
        let result: [String: Any] = ["ok": true, "checks": checks, "presentationStateChecks": 3, "detailMounts": recorder.mounted,
                                     "draftPreserved": recorder.draft == recorder.requestedDraft,
                                     "reports": recorder.reports]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        window.orderOut(nil)
    }
}
