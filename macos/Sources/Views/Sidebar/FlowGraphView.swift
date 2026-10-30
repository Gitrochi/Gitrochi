import SwiftUI

/// A selectable dependency canvas shared by flow previews and live or saved runs.
struct FlowGraphView: View {
    struct Node: Identifiable {
        let id: String
        let title: String
        let block: String
        let needs: [String]
        let state: String?
        let subtitle: String

        init(_ node: FlowPlan.Node) {
            id = node.id
            title = node.title ?? node.id
            block = node.block
            needs = node.needs
            state = node.decision == "skip" ? "SKIPPED" : nil
            subtitle = node.run?.split(separator: "\n").first.map(String.init) ?? node.executor ?? node.block
        }

        init(_ node: FlowRunView.Node) {
            id = node.id
            title = node.title
            block = node.block
            needs = node.needs
            state = node.state.rawValue
            subtitle = node.durationMs.map(FlowFormat.duration) ?? FlowFormat.stateTitle(node.state.rawValue)
        }
    }

    let nodes: [Node]
    @Binding var selected: String?
    @ViewState private var zoom: CGFloat? = 1

    var body: some View {
        let layout = FlowGraphLayout.make(nodes.map { .init(id: $0.id, needs: $0.needs) })
        GeometryReader { geometry in
            let fit = min(1, max(0.35, min((geometry.size.width - 12) / layout.width, (geometry.size.height - 48) / layout.height)))
            let scale = zoom ?? fit
            VStack(spacing: 0) {
                controls(scale: scale)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        connections(layout)
                        ForEach(layout.items, id: \.id) { item in
                            if let node = nodes.first(where: { $0.id == item.id }) {
                                card(node)
                                    .frame(width: FlowGraphLayout.cardWidth, height: FlowGraphLayout.cardHeight)
                                    .offset(x: item.x, y: item.y)
                            }
                        }
                    }
                    .frame(width: layout.width, height: layout.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
                    .frame(minWidth: max(0, geometry.size.width - 2), minHeight: max(0, geometry.size.height - 40), alignment: .center)
                }
                .background {
                    Canvas { context, size in
                        for x in stride(from: CGFloat(12), to: size.width, by: 20) {
                            for y in stride(from: CGFloat(12), to: size.height, by: 20) {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.18)))
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("flow-dependency-graph")
    }

    private func controls(scale: CGFloat) -> some View {
        HStack(spacing: 8) {
            Label("Dependency graph", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Button { zoom = max(0.25, scale - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text(scale, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34)
            Button { zoom = min(1.75, scale + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button("Fit") { zoom = nil }.help("Fit graph to view")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }

    private func connections(_ layout: FlowGraphLayout.Layout) -> some View {
        Canvas { context, _ in
            let positions = Dictionary(uniqueKeysWithValues: layout.items.map { ($0.id, $0) })
            for node in nodes {
                guard let target = positions[node.id] else { continue }
                for dependency in Set(node.needs) {
                    guard let source = positions[dependency] else { continue }
                    let start = CGPoint(x: source.x + FlowGraphLayout.cardWidth, y: source.y + FlowGraphLayout.cardHeight / 2)
                    let end = CGPoint(x: target.x, y: target.y + FlowGraphLayout.cardHeight / 2)
                    let bend = max(28, abs(end.x - start.x) / 2)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
                    let color = node.state == "RUNNING" ? Color.accentColor : Color.secondary.opacity(0.4)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: node.state == "RUNNING" ? 2.5 : 1.5))
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: end.x - 6, y: end.y - 3))
                    arrow.addLine(to: end)
                    arrow.addLine(to: CGPoint(x: end.x - 6, y: end.y + 3))
                    context.stroke(arrow, with: .color(color), lineWidth: 1.5)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func card(_ node: Node) -> some View {
        let active = selected == node.id
        let color = node.state.map { FlowStateIcon.look($0).1 } ?? Color.accentColor
        return Button { selected = node.id } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: node.block.hasPrefix("test") ? "checkmark.seal" : "terminal")
                        .font(.system(size: 14)).foregroundStyle(color)
                        .frame(width: 28, height: 28).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.id).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(node.block).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if node.state == "RUNNING" { ProgressView().controlSize(.mini) }
                    else { FlowStateIcon(state: node.state, size: 14) }
                }
                Text(node.subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(node.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(color).frame(width: 3).padding(.vertical, 10) }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: active ? 2 : 1))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help(node.id + " · " + node.title + " · " + FlowFormat.stateTitle(node.state))
        .accessibilityLabel(node.id + ", " + node.title + ", " + FlowFormat.stateTitle(node.state))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
