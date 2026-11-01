import SwiftUI
import AppKit

/// ⌘, 설정: 계정(GitHub·GitLab), AI, 규칙, 도구(실행 파일 위치), CLI(gitch), 화면(테마), 업데이트
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
            RulesSettings()
                .tabItem { Label("Rules", systemImage: "text.badge.checkmark") }
            ToolsSettings()
                .tabItem { Label("Tool locations", systemImage: "wrench.and.screwdriver") }
            CLISettings()
                .tabItem { Label { Text(verbatim: "CLI") } icon: { Image(systemName: "terminal") } }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            UpdateSettings()
                .tabItem { Label("Update", systemImage: "arrow.down.circle") }
            // Added after the others, and only while the Ledger is shown
            if LedgerSettings.isShown {
                LedgerSettings()
                    .tabItem { Label("Ledger", systemImage: WorkspaceDestination.ledger.symbol) }
            }
        }
        .frame(width: 600, height: 560)
    }
}
