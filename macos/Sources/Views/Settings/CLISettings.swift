import SwiftUI
import AppKit

/// 설정 > CLI: 앱에 든 셸 명령(gitch) 설치·계정
struct CLISettings: View {
    @ViewState private var generation = 0
    @ViewState private var logoEnabled: Bool?
    @ViewState private var logoSaving = false
    @ViewState private var logoError: String?
    @ViewState private var logoRequest = 0

    var body: some View {
        Form {
            Section("CLI appearance") {
                Toggle("Show the small eye logo", isOn: Binding(
                    get: { logoEnabled ?? true },
                    set: { saveLogo($0) }
                ))
                .disabled(logoEnabled == nil || logoSaving)
                Text("Show Gitrochi's small eye logo beside command titles. You can also use gitch logo off or gitch logo on in the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                if (logoEnabled == nil && logoError == nil) || logoSaving {
                    ProgressView().controlSize(.small)
                }
                if let logoError {
                    Text(logoError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("Try again") { generation += 1 }
                        .disabled(logoSaving)
                }
            }
            GitchSection()
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in generation += 1 }
        .task(id: generation) { await loadLogo() }
    }

    @MainActor
    private func loadLogo() async {
        guard !logoSaving else { return }
        logoRequest += 1
        let request = logoRequest
        do {
            let setting = try await Gitch.logoSetting()
            guard request == logoRequest, !Task.isCancelled else { return }
            logoEnabled = setting.enabled
            logoError = nil
        } catch {
            guard request == logoRequest, !Task.isCancelled else { return }
            logoError = error.localizedDescription
        }
    }

    @MainActor
    private func saveLogo(_ enabled: Bool) {
        guard !logoSaving, logoEnabled != nil else { return }
        logoRequest += 1
        logoSaving = true
        logoError = nil
        Task {
            do {
                logoEnabled = try await Gitch.setLogoEnabled(enabled).enabled
            } catch {
                logoError = error.localizedDescription
            }
            logoSaving = false
        }
    }
}
