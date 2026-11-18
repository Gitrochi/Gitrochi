import SwiftUI
import AppKit
import ServiceManagement

/// Startup and background, in Settings › Update: open at login, and keep running in the menu bar with the windows
/// closed. (Windows: widgets/settings/ui/BackgroundSettings.tsx)
struct BackgroundSettings: View {
    @AppStorage(BackgroundMode.keepRunningKey) private var keepRunning = true
    @ViewState private var login = SMAppService.mainApp.status
    @ViewState private var failure: String?

    var body: some View {
        Section("Startup and background") {
            // a login item waiting for approval is on as far as the user is concerned: it opens once allowed
            Toggle("Open at login", isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: setOpenAtLogin))
            if login == .requiresApproval {
                HStack {
                    Text("Allow Gitrochi in System Settings › General › Login Items to open it at login.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled)
            }
            Toggle("Keep running in the menu bar when windows are closed", isOn: $keepRunning)
            Text("Scheduled runs still start and terminals keep running while no window is open. Quit from the menu bar to stop them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: keepRunning) { _, _ in BackgroundMode.shared.update() }
        // the user may change it in System Settings meanwhile
        .onAppear { login = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login = SMAppService.mainApp.status
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            failure = nil
        } catch {
            failure = on ? String(localized: "Couldn't add Gitrochi to the login items: \(error.localizedDescription)")
                         : String(localized: "Couldn't remove Gitrochi from the login items: \(error.localizedDescription)")
        }
        login = SMAppService.mainApp.status
    }
}
