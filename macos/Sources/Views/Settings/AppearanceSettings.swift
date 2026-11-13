import SwiftUI
import AppKit

/// 화면: 언어, 테마(시스템·라이트·다크)
struct AppearanceSettings: View {
    @AppStorage(AppTheme.key) private var theme = AppTheme.system.rawValue
    @AppStorage(AppLanguage.key) private var language = AppLanguage.defaultCode
    @AppStorage(ToolbarTitles.key) private var toolbarTitles = false
    @ViewState private var askRestart = false

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $language) {
                    Text("Follow system language").tag("system")
                    Divider()
                    ForEach(AppLanguage.options) { Text(verbatim: $0.name).tag($0.code) }
                }
                Text("Gitrochi restarts to apply the change. When there's no commit history to follow, the AI also writes in this language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Theme") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("System follows your macOS setting (light, dark or auto). The graph and terminal change with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Toolbar") {
                Picker("Toolbar buttons", selection: $toolbarTitles) {
                    Text("Icons only").tag(false)
                    Text("Icons and text").tag(true)
                }
                .pickerStyle(.segmented)
                Text("With text, each button's name sits to the right of its icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Commit graph") {
                Toggle("Show author profile pictures", isOn: Binding(get: { AvatarStore.shared.enabled }, set: { AvatarStore.shared.enabled = $0 }))
                HStack {
                    Text("Looks for a GitHub profile, then a connected self-hosted GitLab profile, then Gravatar, and uses initials if none is found. An email hash is sent to Gravatar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Download again") { AvatarStore.shared.refresh() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: theme) { _, value in AppTheme.apply(AppTheme(rawValue: value) ?? .system) }
        .onChange(of: language) { _, value in
            AppLanguage.select(value)
            askRestart = true
        }
        .alert("Restart now?", isPresented: $askRestart) {
            Button("Later", role: .cancel) {}
            Button("Restart now") { AppLanguage.relaunch() }
        } message: {
            Text("The language changes when Gitrochi restarts.")
        }
    }
}
