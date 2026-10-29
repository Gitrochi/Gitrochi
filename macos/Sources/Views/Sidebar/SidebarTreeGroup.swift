import SwiftUI

/// Explicit tree spacing also works outside a List (Windows: sidebar/ui/Sidebar.tsx).
struct SidebarTreeGroup: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12, height: 16)
                    configuration.label
                }
                .sidebarTreeRow()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                DisclosureGroup(isExpanded: configuration.$isExpanded) {
                    EmptyView()
                } label: {
                    configuration.label
                }
                .disclosureGroupStyle(.automatic)
            }
            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    configuration.content
                }
                .padding(.leading, 18)
            }
        }
    }
}

extension View {
    /// Leaves reserve the same disclosure column as their sibling folders.
    func sidebarTreeRow() -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
    }
}
