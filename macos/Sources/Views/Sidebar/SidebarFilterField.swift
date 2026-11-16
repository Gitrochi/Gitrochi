import SwiftUI

/// The board's Filter branches field at the top of the Branches tab: 28 pt, a 6 pt radius, a 1 pt border and a 13 pt
/// magnifier. (Windows: `.side-filter` in widgets/sidebar/ui/Sidebar.tsx)
struct SidebarFilterField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// Escape in the field; false leaves the key to whoever is next (RepositoryEscape has the order)
    var onEscape: () -> Bool = { false }

    var body: some View {
        HStack(spacing: 6) {
            DesignIconImage(icon: .search, size: 13).foregroundStyle(StudioStyle.Rail.icon)
                .accessibilityHidden(true)
            TextField("Filter branches", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .autocorrectionDisabled()
                .focused(focused)
                .onKeyPress(.escape) { onEscape() ? .handled : .ignored }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.16)))
    }
}
