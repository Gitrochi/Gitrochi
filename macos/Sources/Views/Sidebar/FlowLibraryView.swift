import SwiftUI

/// The list column: every flow in the repository with how its latest run ended and when. Choosing one fills the
/// rest of the workspace. (Windows: FlowLibrary.tsx)
struct FlowLibraryView: View {
    let flows: [FlowList.Flow]
    let runs: [FlowRunRow]
    let selected: String?
    @Binding var search: String
    let onChoose: (String) -> Void
    let onCreate: () -> Void

    var body: some View {
        let visible = FlowWorkspaceSummary.matchingFlows(flows, search: search)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FlowSearchField(prompt: "Find flows", text: $search)
                Button(action: onCreate) { Label("New flow…", symbol: "plus") }
                    .buttonStyle(HostedListButtonStyle()).fixedSize()
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visible) { flow in
                        FlowLibraryRow(flow: flow, latest: runs.first { $0.flow == flow.name }, selected: flow.name == selected) {
                            onChoose(flow.name)
                        }
                    }
                    if visible.isEmpty, !flows.isEmpty { noMatch }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(StudioStyle.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flows")
    }

    private var noMatch: some View {
        VStack(spacing: 8) {
            DesignIconImage(icon: .search, size: 24).foregroundStyle(HostedList.caption)
            Text("No matching flows").font(.system(size: 12)).foregroundStyle(HostedList.caption)
            Button("Clear search") { search = "" }.buttonStyle(HostedListButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

/// One flow: its name, how the latest run ended (nothing before any run), when that was, and what the flow is for.
/// The selected row is the soft accent tint alone, with its name semibold.
private struct FlowLibraryRow: View {
    let flow: FlowList.Flow
    let latest: FlowRunRow?
    let selected: Bool
    let choose: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        let status = FlowWorkspaceSummary.libraryStatus(flow, latest: latest)
        let when = ListDate.parse(status.at).map { ListDate.when($0) } ?? String(localized: "Not run yet")
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: flow.name).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if let state = status.state { FlowStateIcon(state: state, size: 12, spins: true) }
                    Text(verbatim: when).font(.system(size: 12)).foregroundStyle(HostedList.secondary(selected: selected)).fixedSize()
                }
                if let description = flow.description, !description.isEmpty {
                    Text(verbatim: description).font(.system(size: 12)).foregroundStyle(HostedList.secondary(selected: selected))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.16) : hovered ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(flow.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The 28 pt search field of the list column and the History tab: it filters as you type, and Escape clears it
struct FlowSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            DesignIconImage(icon: .search, size: 12).foregroundStyle(HostedList.caption)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: { SymbolIcon("xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(HostedList.caption)
                    .help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.7) : HostedList.edge))
    }
}
