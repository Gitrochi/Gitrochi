import AppKit
import Observation
import UserNotifications

/// Settings › Ledger › Notifications and the Dock badge (DESIGN.md §10.11). While the Ledger is shown and a person turned
/// one of them on, the ledger is read every 2 s; each read that brings news posts a native notification, and the Dock
/// icon shows the Inbox's count (`attention.total`). Nothing is announced for what the first read finds. Clicking a
/// notification opens the Ledger at its session. Permission is asked for only when a person turns notifications on.
/// (Windows: the Tauri notification plugin and the taskbar overlay)
@MainActor
final class LedgerNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LedgerNotifier()
    static let notifyKey = "ledgerNotifications"
    static let badgeKey = "ledgerDockBadge"

    static var notifies: Bool { WorkspaceDestination.ledgerPreview && UserDefaults.standard.bool(forKey: notifyKey) }
    static var badges: Bool { WorkspaceDestination.ledgerPreview && UserDefaults.standard.bool(forKey: badgeKey) }

    private let ledger = LedgerStore.shared
    private var seen: LedgerSeen?
    private var watching = false
    private var delegateSet = false

    /// Starts or stops following the ledger as the switches say; Settings calls it when one changes
    func refresh() {
        if Self.notifies, !delegateSet {
            UNUserNotificationCenter.current().delegate = self
            delegateSet = true
        }
        if Self.notifies || Self.badges {
            ledger.activate()
            if !watching {
                watching = true
                observe()
            }
            update()
        }
        if !Self.badges { NSApp.dockTile.badgeLabel = nil }
    }

    /// Asks macOS for permission to notify; answers whether Gitrochi may
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Whether macOS lets Gitrochi show notifications now
    func permitted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func observe() {
        withObservationTracking { _ = ledger.state } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        guard let state = ledger.state else { return }
        if Self.badges {
            let total = state.attention.total
            NSApp.dockTile.badgeLabel = total > 0 ? (total > 999 ? "999+" : String(total)) : nil
        }
        let next = LedgerSeen(state)
        defer { seen = next }
        guard let before = seen, Self.notifies else { return }
        for notice in LedgerNotices.notices(state, since: before, now: state.now) { post(notice) }
    }

    private func post(_ notice: LedgerNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = "ledger." + notice.kind.rawValue
        if notice.kind == .prompt { content.sound = .default }
        content.userInfo = ["ledgerSession": notice.sessionId ?? ""]
        let request = UNNotificationRequest(identifier: "ledger." + notice.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let session = (response.notification.request.content.userInfo["ledgerSession"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        completionHandler()
        Task { @MainActor in LedgerNotifier.shared.open(session: session) }
    }

    /// The Ledger at the session, in the front repository window
    func open(session: String?) {
        NSApp.activate()
        ledger.page = .inbox
        if let session { ledger.selection = session }
        let stores = Workspace.shared.openRepositories
        let store = stores.first { $0.window?.isKeyWindow == true } ?? stores.first { $0.window?.isVisible == true } ?? stores.first
        store?.navigate(.ledger)
        store?.window?.makeKeyAndOrderFront(nil)
    }
}
