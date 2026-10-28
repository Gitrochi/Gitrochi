import SwiftUI

/// A focused predecessor → task → successor view keeps a large DAG readable.
struct ProjectDependencyView: View {
    let rows: [HubProjectRow]
    let select: (HubProjectRow) -> Void
    var selectedID: String? = nil
    @ViewState private var focusID = ""
    @ViewState private var query = ""
    @ViewState private var width: CGFloat = 0
    private var graph: LocalProjectDependencies.Graph { LocalProjectDependencies.graph(rows) }
    private var matches: [LocalProjectDependencies.Node] { graph.nodes.filter { query.trimmed.isEmpty || $0.row.title.localizedCaseInsensitiveContains(query.trimmed) } }
    private var focus: LocalProjectDependencies.Node? { graph.nodes.first { $0.id == (selectedID ?? focusID) } ?? matches.first }
    private var predecessors: [LocalProjectDependencies.Node] { let selected = Set(focus?.row.predecessorIDs ?? []); return graph.nodes.filter { selected.contains($0.id) } }
    private var successors: [LocalProjectDependencies.Node] { let selected = focus?.id ?? ""; return graph.nodes.filter { $0.row.predecessorIDs?.contains(selected) == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task dependency graph").font(.headline)
            Text(verbatim: summary).font(.caption).foregroundStyle(.secondary)
            Text("All local tasks are included. Roadmap filters do not hide predecessor links.").font(.caption).foregroundStyle(.secondary)
            if graph.invalid { Text("Task dependencies are invalid. Saved data has not been changed.").font(.caption).foregroundStyle(.red) }
            else {
                if let days = graph.durationDays { Text(verbatim: String(localized: "Critical path: {0} days").replacingOccurrences(of: "{0}", with: days.formatted())).font(.callout.weight(.medium)) }
                else { Text("A critical path needs an explicit duration for every active task and no unfinished archived predecessor.").font(.caption).foregroundStyle(.secondary) }
                Text("Critical paths use stated durations and completion states, without calendar or capacity estimates. Task dates stay unchanged.").font(.caption).foregroundStyle(.secondary)
                TextField("Find a task in the graph", text: $query).textFieldStyle(.roundedBorder).onChange(of: query) { _, _ in focusID = "" }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .top)], alignment: .leading, spacing: 8) {
                        ForEach(Array(matches.prefix(40))) { node in task(node) }
                    }
                }.frame(height: min(190, max(48, CGFloat((min(40, matches.count) + 2) / 3) * 76)))
                if matches.count > 40 { Text(verbatim: String(localized: "Showing {0} of {1} tasks. Refine the search to find more.").replacingOccurrences(of: "{0}", with: "40").replacingOccurrences(of: "{1}", with: matches.count.formatted())).font(.caption).foregroundStyle(.secondary) }
                if let focus {
                    if width >= 680 {
                        HStack(alignment: .top, spacing: 12) {
                            column("Predecessors", nodes: predecessors)
                            arrow
                            column("Selected task", nodes: [focus])
                            arrow
                            column("Successors", nodes: successors)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            column("Predecessors", nodes: predecessors)
                            Image(systemName: "arrow.down").foregroundStyle(.secondary).accessibilityLabel("Precedes")
                            column("Selected task", nodes: [focus])
                            Image(systemName: "arrow.down").foregroundStyle(.secondary).accessibilityLabel("Precedes")
                            column("Successors", nodes: successors)
                        }
                    }
                }
                if matches.isEmpty { Text("No matching tasks").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .contain).accessibilityLabel("Task dependency graph")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    private var arrow: some View { Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 34).accessibilityLabel("Precedes") }
    private var summary: String {
        let ready = graph.nodes.filter { !$0.completed && !$0.row.archived && $0.blockedBy.isEmpty }.count
        let blocked = graph.nodes.filter { !$0.completed && !$0.row.archived && !$0.blockedBy.isEmpty }.count
        return String(localized: "{0} ready · {1} blocked").replacingOccurrences(of: "{0}", with: ready.formatted()).replacingOccurrences(of: "{1}", with: blocked.formatted())
    }
    private func column(_ title: LocalizedStringKey, nodes: [LocalProjectDependencies.Node]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(nodes.prefix(60))) { node in task(node) }
            if nodes.isEmpty { Text("None").font(.caption).foregroundStyle(.secondary) }
            if nodes.count > 60 { Text(verbatim: String(localized: "Showing {0} of {1} tasks. Refine the search to find more.").replacingOccurrences(of: "{0}", with: "60").replacingOccurrences(of: "{1}", with: nodes.count.formatted())).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func task(_ node: LocalProjectDependencies.Node) -> some View {
        Button { focusID = node.id; select(node.row) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(node.row.title).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Text(verbatim: state(node) + (node.critical ? " · " + String(localized: "Critical path") : "")).font(.caption2).foregroundStyle(.secondary)
                if let days = node.row.durationDays { Text(verbatim: String(localized: "{0} days").replacingOccurrences(of: "{0}", with: days.formatted())).font(.caption2).foregroundStyle(.secondary) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke((selectedID ?? focusID) == node.id || node.critical ? Color.accentColor : Color.secondary.opacity(0.2)))
        }.buttonStyle(.plain).accessibilityAddTraits((selectedID ?? focusID) == node.id ? .isSelected : [])
    }
    private func state(_ node: LocalProjectDependencies.Node) -> String {
        if node.completed { return String(localized: "Done") }
        if node.row.archived { return String(localized: "Archived") }
        return node.blockedBy.isEmpty ? String(localized: "Ready") : String(localized: "Blocked")
    }
}
