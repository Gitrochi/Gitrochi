import SwiftUI
import AppKit
import Observation

enum SettingsTab: Hashable, CaseIterable {
    case accounts, ai, rules, tools, cli, appearance, update
}

/// Which pane Settings shows, so "Manage accounts…" lands on Accounts whatever was open last
@MainActor @Observable
final class SettingsRoute {
    static let shared = SettingsRoute()
    var tab = SettingsTab.accounts
}

/// Settings use a compact, monochrome navigation strip on both platforms.
struct SettingsView: View {
    @Bindable private var route = SettingsRoute.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigation(selection: $route.tab)
            Divider()
            Group {
                switch route.tab {
                case .accounts: AccountsSettings()
                case .ai: AISettings()
                case .rules: RulesSettings()
                case .tools: ToolsSettings()
                case .cli: CLISettings()
                case .appearance: AppearanceSettings()
                case .update: UpdateSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 560)
    }
}

private extension SettingsTab {
    var title: LocalizedStringKey {
        switch self {
        case .accounts: "Accounts"
        case .ai: "AI"
        case .rules: "Rules"
        case .tools: "Tool locations"
        case .cli: "CLI"
        case .appearance: "Appearance"
        case .update: "Update"
        }
    }

    var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .ai: "cpu"
        case .rules: "checkmark.shield"
        case .tools: "slider.horizontal.3"
        case .cli: "terminal"
        case .appearance: "circle.lefthalf.filled"
        case .update: "arrow.triangle.2.circlepath"
        }
    }
}

private struct SettingsNavigation: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { category in
                Button {
                    selection = category
                } label: {
                    VStack(spacing: 5) {
                        DesignSymbols.labelImage(category.symbol)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .frame(width: 26, height: 26)
                            .accessibilityHidden(true)
                        Text(category.title)
                            .font(.system(size: 11, weight: selection == category ? .semibold : .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .top)
                    .padding(.vertical, 7)
                    .foregroundStyle(selection == category ? .primary : .secondary)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .opacity(selection == category ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(category.title))
                .accessibilityAddTraits(selection == category ? .isSelected : [])
            }
        }
        .padding(10)
        .background(.bar)
    }
}
