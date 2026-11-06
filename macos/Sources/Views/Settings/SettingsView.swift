import SwiftUI
import AppKit

/// ⌘, 설정: 계정(GitHub·GitLab), AI, 규칙, 도구(실행 파일 위치), CLI(gitch), 화면(테마), 업데이트
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", symbol: "person.crop.circle") }
            AISettings()
                .tabItem { Label("AI", symbol: "sparkles") }
            RulesSettings()
                .tabItem { Label("Rules", symbol: "text.badge.checkmark") }
            ToolsSettings()
                .tabItem { Label("Tool locations", symbol: "wrench.and.screwdriver") }
            CLISettings()
                .tabItem { Label { Text(verbatim: "CLI") } icon: { DesignIconImage(icon: .terminal) } }
            AppearanceSettings()
                .tabItem { Label("Appearance", symbol: "paintpalette") }
            UpdateSettings()
                .tabItem { Label("Update", symbol: "arrow.down.circle") }
            // Added after the others, and only while the Ledger is shown
            if LedgerSettings.isShown {
                LedgerSettings()
                    .tabItem { Label("Ledger", symbol: WorkspaceDestination.ledger.symbol) }
            }
        }
        .frame(width: 600, height: 560)
    }
}
