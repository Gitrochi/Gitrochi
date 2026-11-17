import SwiftUI

/// Explicit tree spacing also works outside a List (Windows: sidebar/ui/Sidebar.tsx).
struct SidebarTreeGroup: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    DesignIconImage(icon: .chevronRight, size: 10)
                        .foregroundStyle(StudioStyle.Rail.icon)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 10, height: 16)
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
    /// The board's row: 26 pt, 8 pt at each side (Windows: `.side-branches .side-row`).
    func sidebarTreeRow() -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .sidebarRowHover()
    }

    /// The hover fill of a row that answers a click, on the rows' 6 pt radius.
    func sidebarRowHover() -> some View { modifier(SidebarRowHover()) }
}

private struct SidebarRowHover: ViewModifier {
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? StudioStyle.hover : Color.clear))
            .onHover { hovering = $0 }
    }
}
