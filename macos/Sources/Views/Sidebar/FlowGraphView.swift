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

        init(id: String, title: String, block: String, needs: [String], state: String?, subtitle: String) {
            self.id = id; self.title = title; self.block = block; self.needs = needs; self.state = state; self.subtitle = subtitle
        }

        init(_ node: FlowPlan.Node) {
            id = node.id
            title = node.title ?? node.id
            block = node.block
            needs = node.needs
            state = node.decision == "skip" ? "SKIPPED" : node.decision == "rejected" ? "REJECTED" : nil
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
    @ViewState private var offsets: [String: CGSize] = [:]
    @ViewState private var dragStarts: [String: CGSize] = [:]
    @FocusState private var graphFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(nodes: [Node], selected: Binding<String?>, initialFit: Bool = false) {
        self.nodes = nodes
        _selected = selected
        _zoom = ViewState(initialValue: initialFit ? nil : 1)
    }

    var body: some View {
        let layout = positionedLayout()
        GeometryReader { geometry in
            let fit = FlowGraphLayout.fit(layout, viewport: geometry.size)
            let scale = zoom ?? fit
            VStack(spacing: 0) {
                controls(scale: scale)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        FlowCanvasInteraction(onZoom: { factor in
                            if factor < 1, scale <= 0.1 { return }
                            zoom = min(2.5, max(0.1, scale * factor))
                        })
                        connections(layout)
                        ForEach(layout.items, id: \.id) { item in
                            if let node = nodes.first(where: { $0.id == item.id }) {
                                card(node)
                                    .frame(width: FlowGraphLayout.cardWidth, height: FlowGraphLayout.cardHeight)
                                    .offset(x: item.x, y: item.y)
                                    .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                                        selected = item.id
                                        graphFocused = true
                                        if dragStarts[item.id] == nil { dragStarts[item.id] = offsets[item.id] ?? .zero }
                                        let start = dragStarts[item.id] ?? .zero
                                        offsets[item.id] = boundedOffset(id: item.id, x: start.width + value.translation.width / scale, y: start.height + value.translation.height / scale)
                                    }.onEnded { _ in dragStarts[item.id] = nil })
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
                        for x in stride(from: CGFloat(12), to: size.width, by: 24) {
                            for y in stride(from: CGFloat(12), to: size.height, by: 24) {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.14)))
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($graphFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { event in
            guard event.modifiers.contains(.option), selected != nil else { return .ignored }
            let step: CGFloat = event.modifiers.contains(.shift) ? 48 : 16
            switch event.key {
            case .leftArrow: moveSelected(x: -step, y: 0)
            case .rightArrow: moveSelected(x: step, y: 0)
            case .upArrow: moveSelected(x: 0, y: -step)
            case .downArrow: moveSelected(x: 0, y: step)
            default: return .ignored
            }
            return .handled
        }
        .accessibilityAction(named: Text("Move left")) { moveSelected(x: -16, y: 0) }
        .accessibilityAction(named: Text("Move right")) { moveSelected(x: 16, y: 0) }
        .accessibilityAction(named: Text("Move up")) { moveSelected(x: 0, y: -16) }
        .accessibilityAction(named: Text("Move down")) { moveSelected(x: 0, y: 16) }
        .help("Drag modules to move them. Drag the background to pan; pinch or Option-scroll to zoom. Option-arrow keys move the selected module.")
        .accessibilityIdentifier("flow-dependency-graph")
    }

    private func controls(scale: CGFloat) -> some View {
        HStack(spacing: 8) {
            Label("Dependency graph", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            HStack(spacing: 8) {
                Button { zoom = max(0.1, scale - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out").disabled(scale <= 0.1)
                Text(scale, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34)
                Button { zoom = min(2.5, scale + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in").disabled(scale >= 2.5)
                Divider().frame(height: 12)
                Button("Fit") { zoom = nil }.help("Fit graph to view")
                Button { offsets = [:]; zoom = 1 } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset layout")
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private func positionedLayout() -> FlowGraphLayout.Layout {
        let original = FlowGraphLayout.make(nodes.map { .init(id: $0.id, needs: $0.needs) })
        let items = original.items.map { item in
            let offset = offsets[item.id] ?? .zero
            return FlowGraphLayout.Item(id: item.id, x: max(12, item.x + offset.width), y: max(12, item.y + offset.height))
        }
        return .init(items: items, width: max(original.width, (items.map(\.x).max() ?? 0) + FlowGraphLayout.cardWidth + 28),
                     height: max(original.height, (items.map(\.y).max() ?? 0) + FlowGraphLayout.cardHeight + 28))
    }

    private func moveSelected(x: CGFloat, y: CGFloat) {
        guard let selected else { return }
        let current = offsets[selected] ?? .zero
        offsets[selected] = boundedOffset(id: selected, x: current.width + x, y: current.height + y)
    }

    private func boundedOffset(id: String, x: CGFloat, y: CGFloat) -> CGSize {
        let base = FlowGraphLayout.make(nodes.map { .init(id: $0.id, needs: $0.needs) }).items.first { $0.id == id }
        return CGSize(width: max(12 - (base?.x ?? 28), x), height: max(12 - (base?.y ?? 28), y))
    }

    private func connections(_ layout: FlowGraphLayout.Layout) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !nodes.contains { $0.state == "RUNNING" })) { timeline in
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
                        let color = connectionColor(node, source: dependency)
                        context.stroke(path, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        if node.state == "RUNNING" {
                            let phase = reduceMotion ? 0 : -CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) * 15)
                            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 7], dashPhase: phase))
                        }
                        var arrow = Path()
                        arrow.move(to: CGPoint(x: end.x - 7, y: end.y - 3.5))
                        arrow.addLine(to: end)
                        arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y + 3.5))
                        context.stroke(arrow, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func connectionColor(_ node: Node, source: String) -> Color {
        if let state = node.state, !["PENDING", "SKIPPED"].contains(state) { return FlowStateIcon.look(state).1 }
        if let state = nodes.first(where: { $0.id == source })?.state, ["PASSED", "SUCCEEDED", "CACHED"].contains(state) { return .green }
        return selected == node.id || selected == source ? .accentColor : .secondary.opacity(0.6)
    }

    private func card(_ node: Node) -> some View {
        let active = selected == node.id
        let category = FlowBlockStyle.look(node.block)
        let stateColor = node.state.map { FlowStateIcon.look($0).1 } ?? category.color
        return Button { selected = node.id; graphFocused = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: category.icon)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(category.color)
                        .frame(width: 28, height: 28).background(category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.id).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(category.title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    FlowStatusBadge(state: node.state, compact: true)
                }
                Text(node.subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(node.title != "Command" && node.title != node.id ? node.title : node.block)
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if !node.needs.isEmpty {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                        Text("\(node.needs.count)").font(.system(size: 9, design: .monospaced))
                    }
                }.foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.025))
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [category.color.opacity(0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(alignment: .leading) { Capsule().fill(category.color.opacity(0.8)).frame(width: 3).padding(.vertical, 15) }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.accentColor : Color.primary.opacity(0.13), lineWidth: active ? 1.8 : 1))
            .overlay(alignment: .leading) {
                if !node.needs.isEmpty { port(stateColor).offset(x: -3) }
            }
            .overlay(alignment: .trailing) {
                if nodes.contains(where: { $0.needs.contains(node.id) }) { port(stateColor).offset(x: 3) }
            }
            .shadow(color: active ? Color.accentColor.opacity(0.1) : .primary.opacity(0.05), radius: active ? 8 : 5, y: 3)
        }
        .buttonStyle(.plain)
        .help(node.id + " · " + node.title + " · " + FlowFormat.stateTitle(node.state))
        .accessibilityLabel(node.id + ", " + node.title + ", " + FlowFormat.stateTitle(node.state))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func port(_ color: Color) -> some View {
        Circle().fill(Color(nsColor: .controlBackgroundColor))
            .overlay(Circle().stroke(color.opacity(0.75), lineWidth: 1.5))
            .frame(width: 6, height: 6).allowsHitTesting(false).accessibilityHidden(true)
    }
}
