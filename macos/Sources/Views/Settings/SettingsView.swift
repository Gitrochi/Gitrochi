import SwiftUI
import AppKit
import Observation

enum SettingsTab: Hashable {
    case accounts, ai, rules, tools, cli, appearance, update, ledger
}

/// Which pane Settings shows, so "Manage accounts…" lands on Accounts whatever was open last
@MainActor @Observable
final class SettingsRoute {
    static let shared = SettingsRoute()
    var tab = SettingsTab.accounts
}

/// ⌘, 설정: 계정(GitHub·GitLab), AI, 규칙, 도구(실행 파일 위치), CLI(gitch), 화면(테마), 업데이트
struct SettingsView: View {
    @Bindable private var route = SettingsRoute.shared

    var body: some View {
        TabView(selection: $route.tab) {
            AccountsSettings()
                .tabItem { Label("Accounts", symbol: "person.crop.circle") }.tag(SettingsTab.accounts)
            AISettings()
                .tabItem { Label("AI", symbol: "sparkles") }.tag(SettingsTab.ai)
            RulesSettings()
                .tabItem { Label("Rules", symbol: "text.badge.checkmark") }.tag(SettingsTab.rules)
            ToolsSettings()
                .tabItem { Label("Tool locations", symbol: "wrench.and.screwdriver") }.tag(SettingsTab.tools)
            CLISettings()
                .tabItem { Label { Text(verbatim: "CLI") } icon: { DesignIconImage(icon: .terminal) } }.tag(SettingsTab.cli)
            AppearanceSettings()
                .tabItem { Label("Appearance", symbol: "paintpalette") }.tag(SettingsTab.appearance)
            UpdateSettings()
                .tabItem { Label("Update", symbol: "arrow.down.circle") }.tag(SettingsTab.update)
            // Added after the others, and only while the Ledger is shown
            if LedgerSettings.isShown {
                LedgerSettings()
                    .tabItem { Label("Ledger", symbol: WorkspaceDestination.ledger.symbol) }.tag(SettingsTab.ledger)
            }
        }
        .frame(width: 600, height: 560)
    }
}
