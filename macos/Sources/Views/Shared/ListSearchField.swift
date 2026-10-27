import SwiftUI

/// The search row of a list section: a field with a magnifier, a clear button and a filter icon next to it.
/// (Windows: shared/ui/ListSearchRow.tsx)
struct ListSearchRow<Value: Hashable>: View {
    let prompt: String
    @Binding var text: String
    let filters: [(value: Value, title: String)]
    let selection: Value
    /// The filter that counts as "no filter"; any other choice fills the icon
    let defaultFilter: Value
    let onSearch: () -> Void
    let onFilter: (Value) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused)
                    .onSubmit(onSearch)
                    .onKeyPress(.escape) {
                        guard !text.isEmpty else { return .ignored }
                        text = ""; onSearch()
                        return .handled
                    }
                if !text.isEmpty {
                    Button { text = ""; onSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
            Menu {
                ForEach(filters, id: \.value) { filter in
                    Button { onFilter(filter.value) } label: {
                        if filter.value == selection { Label(filter.title, systemImage: "checkmark") } else { Text(filter.title) }
                    }
                }
            } label: {
                Image(systemName: selection == defaultFilter ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(selection == defaultFilter ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Filter") + ": " + (filters.first { $0.value == selection }?.title ?? ""))
            .accessibilityLabel("Filter")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

/// In the repository sidebar a list carries no search row; when the page left a filter on, this one line says so and clears it
struct ListFilterCaption: View {
    let filter: String
    let search: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
            Text("Filtered: \(search.isEmpty ? filter : filter + " · “" + search + "”")")
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Button(action: onClear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Clear filter").accessibilityLabel("Clear filter")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}
