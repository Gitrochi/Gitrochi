import AppKit

/// Gitrochi in the background: with its windows closed it keeps running in the menu bar, so runs scheduled for later
/// still start and terminals keep running. The Dock icon shows only while a window is open, and quitting asks once
/// when that stops scheduled runs or busy terminals. (Windows: app/lib/tray.ts and src-tauri/src/tray.rs)
@MainActor
final class BackgroundMode: NSObject, NSMenuDelegate {
    static let shared = BackgroundMode()
    /// On unless turned off in Settings › Update (Windows: the same settings key)
    static let keepRunningKey = "keepRunningInBackground"

    static var keepRunning: Bool { UserDefaults.standard.object(forKey: keepRunningKey) as? Bool ?? true }

    private var item: NSStatusItem?
    private var quitConfirmed = false
    /// The last window closed with background mode off: Gitrochi quits as it always did, without asking
    private var quittingWithLastWindow = false

    /// Called once at launch
    func start() {
        UserDefaults.standard.register(defaults: [Self.keepRunningKey: true])
        AppLanguage.quitToRestart = { BackgroundMode.shared.quitToRestart() }
        update()
        // a window coming forward (Settings too) brings the Dock icon back
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundMode.shared.showInDock(true) }
        }
        // and the last one closing takes it away; the window is gone only after this notification
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { BackgroundMode.shared.windowsClosed() } }
        }
    }

    /// The setting changed: shows or removes the menu bar item. Turned off with tabs in the background, those open
    /// again, since nothing else would reach them.
    func update() {
        if Self.keepRunning {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let image = DesignSymbols.image("arrow.triangle.branch")?.copy() as? NSImage {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                item.button?.image = image
            }
            item.button?.toolTip = "Gitrochi"
            item.button?.setAccessibilityLabel("Gitrochi")
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            if !Workspace.shared.backgroundTabs.isEmpty { Workspace.shared.reopen() }
            showInDock(true)
        }
    }

    /// A window is about to open from the menu bar: the app takes the Dock icon and comes forward first
    func windowWillOpen() {
        showInDock(true)
        NSApp.activate()
    }

    /// A window closed; with none left the Dock icon goes while Gitrochi keeps running
    func windowsClosed() {
        guard Self.keepRunning, !RestoreState.shared.active else { return }
        let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        if !open { showInDock(false) }
    }

    private func showInDock(_ shown: Bool) {
        let policy: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func quitsAfterLastWindow() -> Bool {
        // while launching, the extra empty window closing is not the last one: the real ones are still invisible
        guard !RestoreState.shared.active, !Self.keepRunning else { return false }
        quittingWithLastWindow = true
        return true
    }

    /// Asks once before quitting stops scheduled runs or busy terminals ("2 scheduled runs won't start. …")
    func confirmQuit() -> Bool {
        if quitConfirmed || quittingWithLastWindow { return true }
        let scheduled = BackgroundMenu.pendingRuns(ScheduledRunStore.shared.runs)
        guard let message = BackgroundMenu.quitWarning(scheduled: scheduled, terminals: Workspace.shared.busyTerminalCount) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Gitrochi?")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        quitConfirmed = alert.runModal() == .alertFirstButtonReturn
        return quitConfirmed
    }

    /// Quits to restart (an update, another language): the user asked for it, and a helper waiting for this process to
    /// end would open the app again at a later quit if this one were cancelled
    func quitToRestart() {
        quitConfirmed = true
        NSApp.terminate(nil)
    }

    // MARK: The menu

    /// Built each time it opens, so times, repositories and terminal states are current
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let repositories = Workspace.shared.menuRepositories.map { entry in
            BackgroundMenu.Repository(path: entry.url.path, name: entry.url.lastPathComponent,
                                      terminals: entry.terminals.filter(\.running).map { BackgroundMenu.Terminal(id: $0.id, title: $0.title, state: $0.tabStatus.title) })
        }
        let items = BackgroundMenu.items(runs: ScheduledRunStore.shared.runs, time: { ScheduledRuns.time($0, now: now) },
                                         repositories: repositories, recents: Recents.load().map(\.path), same: RepoStore.samePath)
        for entry in items { menu.addItem(menuItem(entry)) }
    }

    private final class Choice: NSObject {
        let item: BackgroundMenu.Item
        init(_ item: BackgroundMenu.Item) { self.item = item }
    }

    private func menuItem(_ entry: BackgroundMenu.Item) -> NSMenuItem {
        func command(_ title: String, key: String = "", indent: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = Choice(entry)
            item.indentationLevel = indent
            return item
        }
        switch entry {
        case .header(let title): return NSMenuItem.sectionHeader(title: title)
        case .note(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .separator: return .separator()
        case .run(let title, _), .repository(let title, _), .recent(let title, _): return command(title)
        case .terminal(let title, _, _): return command(title, indent: 1)
        case .open: return command(String(localized: "Open Gitrochi"))
        case .settings: return command(String(localized: "Settings…"), key: ",")
        case .quit: return command(String(localized: "Quit Gitrochi"), key: "q")
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let entry = (sender.representedObject as? Choice)?.item else { return }
        let workspace = Workspace.shared
        switch entry {
        case .run(_, let path): workspace.reveal(path: path) { $0.navigate(.actions) }
        case .repository(_, let path), .recent(_, let path): workspace.reveal(path: path)
        case .terminal(_, let path, let id):
            workspace.reveal(path: path) { store in
                if let session = store.terminals.first(where: { $0.id == id }) { store.focusTerminal(session) }
            }
        case .open: workspace.reopen()
        case .settings: openSettings()
        case .quit: NSApp.terminate(nil)
        case .header, .note, .separator: break
        }
    }

    /// The app menu's own Settings… item opens the Settings scene, also while no window is open
    private func openSettings() {
        windowWillOpen()
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) else { return }
        menu.performActionForItem(at: index)
    }
}
