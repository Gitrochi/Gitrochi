import SwiftUI
import AppKit

/// 열린 저장소 창(=탭) 목록. macOS 기본 창 탭으로 여러 저장소·워크트리를 열어 두고 오간다.
/// 앱을 다시 켜면 지난번에 열어 둔 탭들을 복원한다.
@MainActor
final class Workspace {
    static let shared = Workspace()

    private static let tabsKey = "openTabs"
    private static let selectedKey = "selectedTab"
    private final class Weak { weak var store: RepoStore?; init(_ s: RepoStore) { store = s } }
    private var stores: [Weak] = []
    var openRepositories: [RepoStore] { stores.compactMap(\.store).filter { $0.url != nil } }
    private var restoreTaken = false
    private var terminating = false
    private let launchedAt = Date()

    /// 복원하느라 열어 달라고 한 뒤 아직 저장소 경로를 받지 못한 창 수
    private(set) var awaitingWindows = 0


    func expectWindow() { awaitingWindows += 1 }
    func windowArrived() { if awaitingWindows > 0 { awaitingWindows -= 1 } }

    // MARK: 창 묶기 — 실행할 때 깜빡임 없이 탭 복원

    /// 첫 창(복원 중에는 계속 이 탭이 보인다)
    private weak var hostWindow: NSWindow?
    private var duplicates = Set<ObjectIdentifier>()

    private var openWindow: (() -> Void)?
    func setWindowOpener(_ open: @escaping () -> Void) { openWindow = open }
    private var routeOpener: ((String) -> Void)?
    private var pendingRoutes: [AppRoute] = []
    private var requestedRoutes = Set<String>()
    private var routingStores = Set<ObjectIdentifier>()
    private var requestedSelection: String?
    /// Launched to open a folder or link: SwiftUI makes no window of its own then; the one ensureWindow opens a moment
    /// later is shown right away instead of waiting invisibly behind a splash
    private var openedByEvent = false
    var launchedByEvent: Bool { openedByEvent }
    func setRouteOpener(_ open: @escaping (String) -> Void) { routeOpener = open }

    func receive(_ url: URL) {
        do {
            let route = try url.isFileURL ? AppRoute(opening: url) : AppRoute(url: url)
            if RestoreState.shared.active, stores.isEmpty, hostWindow == nil { openedByEvent = true }
            requestedSelection = route.repo.path
            pendingRoutes.append(route)
            if let store = stores.compactMap(\.store).first(where: { $0.booted && $0.url?.resolvingSymlinksInPath().path == route.repo.path }) {
                Task { await applyPendingRoutes(to: store) }
            } else if let empty = stores.compactMap(\.store).first(where: { $0.booted && $0.url == nil && $0.loading == nil }) {
                // Reserve before scheduling: two links may arrive in the same run loop turn.
                empty.booted = false
                Task {
                    await empty.openInPlace(route.repo)
                    empty.booted = true
                    await applyPendingRoutes(to: empty)
                }
            } else if stores.compactMap(\.store).contains(where: { $0.booted }) {
                requestRouteWindow(route.repo.path)
            }
            // 첫 창이 아직 준비 중이면 RepoWindow.setUp 이 대기 중인 URL 을 받는다.
        } catch {
            // During launch the windows are still invisible behind the splash; a modal alert then would leave them so
            Task { @MainActor in
                while RestoreState.shared.active { try? await Task.sleep(for: .milliseconds(200)) }
                NSAlert(error: error).runModal()
            }
        }
    }

    func takeInitialRoute() -> AppRoute? { pendingRoutes.first }

    private func requestRouteWindow(_ path: String) {
        guard let routeOpener, requestedRoutes.insert(path).inserted else { return }
        expectWindow()
        routeOpener(path)
    }

    func applyPendingRoutes(to store: RepoStore) async {
        guard let path = store.url?.resolvingSymlinksInPath().path else { return }
        let key = ObjectIdentifier(store)
        guard routingStores.insert(key).inserted else { return }
        defer { routingStores.remove(key) }
        requestedRoutes.remove(path)
        var applied = false
        // Links arriving while a graph is generated stay queued for this same tab.
        while let index = pendingRoutes.firstIndex(where: { $0.repo.path == path }) {
            let route = pendingRoutes.remove(at: index)
            await store.applyAppRoute(route)
            applied = true
        }
        // During launch the windows are still hidden behind the splash; revealWindows shows this tab when it ends
        if applied, !RestoreState.shared.active {
            store.window?.tabGroup?.selectedWindow = store.window
            store.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        // 처음 읽는 동안 다른 저장소 링크가 도착했으면 나머지도 각 탭에서 연다.
        if let next = pendingRoutes.first {
            requestRouteWindow(next.repo.path)
        }
    }

    /// 저장소 창이 하나도 없으면 하나 연다(실행 직후 시스템이 첫 창을 건너뛰었을 때)
    func ensureWindow() {
        let any = hostWindow != nil || NSApp.windows.contains { $0.tabbingIdentifier == WindowTabbing.identifier }
        guard !any else { return }
        openWindow?()
    }

    /// Selects the tab (other than except) already showing folder; false if there is none
    func bringForward(showing folder: URL, except: RepoStore) -> Bool {
        let path = folder.resolvingSymlinksInPath().path
        guard let other = stores.compactMap(\.store).first(where: { $0 !== except && $0.url?.resolvingSymlinksInPath().path == path }) else { return false }
        other.window?.tabGroup?.selectedWindow = other.window
        other.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func isDuplicate(_ w: NSWindow?) -> Bool { w.map { duplicates.contains(ObjectIdentifier($0)) } ?? false }

    /// 창이 화면에 뜨기 전에 불린다.
    func attach(_ w: NSWindow) {
        RepositoryWindowLayout.configure(w)
        w.tabbingIdentifier = WindowTabbing.identifier
        w.tabbingMode = .preferred
        let launching = RestoreState.shared.active
        // after a launch by an opened folder or link the window is not hidden (see openedByEvent)
        if launching, !openedByEvent {
            // 스플래시가 떠 있는 동안 저장소 창은 보이지 않게 준비만 한다
            w.alphaValue = 0
            w.animationBehavior = .none
        }
        guard let host = hostWindow, host !== w else {
            hostWindow = w
            // 스플래시는 작업 창이 나타날 바로 그 자리 가운데에 띄운다(창 위치가 정해진 뒤)
            if launching, !openedByEvent { DispatchQueue.main.async { Splash.shared.show(centeredOn: w.frame) } }
            return
        }
        if awaitingWindows == 0 && Date().timeIntervalSince(launchedAt) < 1.5 && !restoreTaken {
            // 실행 직후 시스템이 하나 더 띄운 빈 창 — 보이지 않은 채로 닫는다
            duplicates.insert(ObjectIdentifier(w))
            w.alphaValue = 0
            DispatchQueue.main.async { w.close() }
            return
        }
        // The window joins the tab group on the next turn; until then keep it invisible so no separate window flashes up
        w.alphaValue = 0
        DispatchQueue.main.async {
            if host.tabbedWindows?.contains(w) != true { host.addTabbedWindow(w, ordered: .above) }
            if !launching {
                w.alphaValue = 1
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// 스플래시를 끝내며 작업 창을 보여 준다: 마지막에 보던 탭(없으면 첫 탭)을 고르고 부드럽게 나타나게
    func revealWindows() {
        let windows = stores.compactMap { $0.store?.window } + [hostWindow].compactMap { $0 }
        let path = requestedSelection ?? UserDefaults.standard.string(forKey: Self.selectedKey)
        let target = stores.compactMap(\.store).first { $0.url?.resolvingSymlinksInPath().path == path }?.window ?? hostWindow
        for w in windows where w !== target {
            w.alphaValue = 1          // 뒤쪽 탭 — 선택되기 전엔 화면에 안 보인다
            w.animationBehavior = .default
        }
        guard let target else { Splash.shared.dismiss(revealing: nil); return }
        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
        // 스플래시는 늘 맨 위에 뜨지만, 준비하는 사이 다른 앱이 앞에 오면 창이 그 뒤에 숨는다.
        // 앱이 비활성이어도 창을 맨 앞으로 올리고(orderFrontRegardless) 활성화를 요청한다.
        target.orderFrontRegardless()
        NSApp.activate()
        target.animationBehavior = .default
        Splash.shared.dismiss(revealing: target)
    }

    /// 보고 있는 탭 기억(복원 중의 잠깐 선택은 기록하지 않음)
    func rememberSelected(_ store: RepoStore) {
        guard !RestoreState.shared.active, !terminating, let path = store.url?.path else { return }
        UserDefaults.standard.set(path, forKey: Self.selectedKey)
    }

    func detach(_ w: NSWindow) {
        duplicates.remove(ObjectIdentifier(w))
        if hostWindow === w {
            hostWindow = w.tabbedWindows?.first { $0 !== w }
                ?? NSApp.windows.first { $0 !== w && $0.tabbingIdentifier == WindowTabbing.identifier && $0.isVisible }
        }
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminating = true }
        }
    }

    func register(_ s: RepoStore) {
        stores.removeAll { $0.store == nil || $0.store === s }
        stores.append(Weak(s))
    }

    func unregister(_ s: RepoStore) {
        stores.removeAll { $0.store == nil || $0.store === s }
        persist()
    }

    func persist() {
        guard !terminating else { return }   // 종료하며 창이 닫히는 건 기록하지 않는다
        var seen = Set<String>()
        let paths = stores.compactMap { $0.store?.url?.path }.filter { seen.insert($0).inserted }
        UserDefaults.standard.set(paths, forKey: Self.tabsKey)
    }

    /// 첫 창만 한 번 받아 간다: 지난번 탭들의 경로
    func takeRestoreList() -> [URL] {
        guard !restoreTaken else { return [] }
        restoreTaken = true
        let d = UserDefaults.standard
        var paths = d.stringArray(forKey: Self.tabsKey) ?? []
        if paths.isEmpty, let last = d.string(forKey: "lastRepository") { paths = [last] }
        var seen = Set<String>()
        return paths.filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// 창이 만들어지는 순간(화면에 뜨기 전)에 탭 묶음 설정을 해 두고, 창이 정말 닫힐 때를 알려 준다.
/// 뒤로 간 탭은 창이 숨겨질 뿐이라 onDisappear 대신 willClose 로만 정리한다.
struct WindowTabbing: NSViewRepresentable {
    static let identifier = "GitrochiRepository"
    let onAttach: (NSWindow) -> Void
    let onClose: () -> Void

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window, let f = onWindow {
                onWindow = nil
                f(w)
            }
        }
    }

    final class Coordinator {
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = ProbeView()
        let coordinator = context.coordinator
        let onAttach = self.onAttach, onClose = self.onClose
        v.onWindow = { w in
            MainActor.assumeIsolated {
                Workspace.shared.attach(w)
                onAttach(w)
            }
            coordinator.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Workspace.shared.detach(w)
                    onClose()
                }
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct RepoStoreKey: FocusedValueKey {
    typealias Value = RepoStore
}

extension FocusedValues {
    var repoStore: RepoStore? {
        get { self[RepoStoreKey.self] }
        set { self[RepoStoreKey.self] = newValue }
    }
}

/// 앱 시작부터 스플래시가 끝날 때까지의 상태. 그동안 저장소 창은 투명하게 준비되고,
/// 스플래시 창이 로고 애니메이션과 진행 상황을 보여 준다.
@MainActor @Observable
final class RestoreState {
    static let shared = RestoreState()

    /// 앱이 켜질 때 true 로 시작해 작업 창을 보여 주면 false
    private(set) var active = true
    private(set) var total = 0
    private(set) var done = 0
    private(set) var current = ""
    private var planned = false
    private let launchedAt = Date()
    /// 로고 애니메이션이 한 호흡은 보이도록
    private let minimumSplash: TimeInterval = 1.3

    var step: String {
        guard planned else { return String(localized: "Preparing…") }
        if total <= 1 { return current.isEmpty ? String(localized: "Opening repository…") : String(localized: "Opening \(current)…") }
        return String(localized: "Opening tab \(min(done + 1, total))/\(total)\(current.isEmpty ? "…" : " · " + current)")
    }

    private init() {
        // 어떤 탭이 끝을 알리지 못해도 스플래시에 갇히지 않게
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            self.end()
        }
    }

    /// 첫 창이 복원할 탭 수를 정하면 부른다(복원할 게 없으면 0)
    func begin(total: Int) {
        self.total = total
        planned = true
        finishIfReady()
    }

    func finished(_ name: String) {
        guard active else { return }
        done += 1
        current = name
        finishIfReady()
    }

    private func finishIfReady() {
        guard active, planned, done >= total else { return }
        let wait = max(0, minimumSplash - Date().timeIntervalSince(launchedAt))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            self.end()
        }
    }

    private func end() {
        guard active else { return }
        active = false
        // 창 안의 로딩 화면이 내용으로 바뀐 뒤에 보여 준다
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            Workspace.shared.revealWindows()
        }
    }
}

/// 실행할 때 잠깐 뜨는 로고 창(테두리 없는 둥근 창)
@MainActor
final class Splash {
    static let shared = Splash()
    private var window: NSWindow?

    func show(centeredOn anchor: NSRect? = nil) {
        guard window == nil, RestoreState.shared.active else { return }
        let size = NSSize(width: 380, height: 360)
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = (anchor?.isEmpty == false) ? anchor! : screen
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.animationBehavior = .none
        // 앱이 아직 앞으로 나오기 전이라도 다른 앱 창에 가려지지 않게
        w.level = .floating
        w.contentView = NSHostingView(rootView: SplashView())
        // 실행 중엔 메인 스레드가 바빠 페이드인이 밀리므로 바로 보이게 띄운다
        w.alphaValue = 1
        w.orderFrontRegardless()
        window = w
    }

    /// 스플래시는 사라지고 작업 창은 나타나게 동시에
    func dismiss(revealing target: NSWindow?) {
        let splash = window
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            target?.animator().alphaValue = 1
            splash?.animator().alphaValue = 0
        }, completionHandler: {
            splash?.orderOut(nil)
            if let target, target.alphaValue < 1 { target.alphaValue = 1 }
        })
    }
}

private struct SplashView: View {
    var body: some View {
        LoadingView(title: "Gitrochi", step: RestoreState.shared.step)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}
