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
            Section {
                CLIWorkflowGuide()
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

/// Windows: CLISettings.tsx presents the same examples without running them.
private struct CLIWorkflowGuide: View {
    private let commands = [
        "gitch workspace create product ../api ../web",
        "gitch workspace status product --json",
        "gitch work start feature-name --workspace product",
        "gitch work info feature-name --json",
        "gitch work commit --work feature-name -m \"Area: Describe change\"",
        "gitch work push --work feature-name",
        "gitch work pr --work feature-name --title \"Describe change\" --body-file pr.md",
        "gitch work end feature-name",
        "gitch issue list --json",
        "gitch issue show 123 --json",
        "gitch pr list --json"
    ]

    var body: some View {
        DisclosureGroup("Multi-repository CLI workflows") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Group local repositories and manage one task across them. Replace the example paths, names and issue number before running a command.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(commands, id: \.self) { command in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy command")
                            .accessibilityLabel("Copy command")
                            .accessibilityValue(command)
                    }
                }
                Text("Commit uses staged files. End returns to the recorded branch, keeps task branches, and stops if changes or an unexpected branch need attention.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("CLI repository groups are stored locally, separately from app workspaces. Use gitch workspace --help or gitch work --help for options, and gitch completion for shell suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }
}
