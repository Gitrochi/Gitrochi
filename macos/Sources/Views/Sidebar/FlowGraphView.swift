import SwiftUI

/// A scrollable dependency canvas shared by plans, live runs and saved runs. Each card reads top to bottom: how the
/// step did, its name, what it is for, and the command it runs. A connector means "needs": the step on the right
/// starts only after the step on the left has passed. (Windows: FlowGraph.tsx)
struct FlowGraphView: View {
    struct Node: Identifiable {
        let id: String
        /// The step's own words, when the flow file gives any
        let title: String?
        let block: String
        let needs: [String]
        /// nil before any run: the card shows a hollow circle
        let state: String?
        /// The step's script; the card shows its first real line
        let command: String?
        var durationMs: Int? = nil

        init(id: String, title: String?, block: String, needs: [String], state: String?, command: String?, durationMs: Int? = nil) {
            self.id = id; self.title = title; self.block = block; self.needs = needs
            self.state = state; self.command = command; self.durationMs = durationMs
        }

        /// A planned step with the latest run laid over it
        init(_ step: FlowWorkspaceSummary.Step) {
            self.init(id: step.id, title: step.node.title, block: step.node.block, needs: step.node.needs,
                      state: step.state, command: step.node.run, durationMs: step.durationMs)
        }

        /// A step of a run; the run's events carry no script
        init(_ node: FlowRunView.Node) {
            self.init(id: node.id, title: node.title, block: node.block, needs: node.needs,
                      state: node.state.rawValue, command: nil, durationMs: node.durationMs)
        }
    }

    /// The zoom control and the gap under it, which the canvas does not get
    private static let controlsHeight: CGFloat = 36
    private static let warningHeight: CGFloat = 24

    let nodes: [Node]
    @Binding var selected: String?
    /// nil follows the size of the canvas ("Fit") until the person zooms
    @ViewState private var zoom: CGFloat? = 1
    /// Where the person dragged each card, from its laid-out place
    @ViewState private var offsets: [String: CGSize] = [:]
    @ViewState private var dragStarts: [String: CGSize] = [:]
    @FocusState private var graphFocused: Bool

    init(nodes: [Node], selected: Binding<String?>, initialFit: Bool = false) {
        self.nodes = nodes
        _selected = selected
        _zoom = ViewState(initialValue: initialFit ? nil : 1)
    }

    var body: some View {
        let layout = positionedLayout()
        let unarranged = layout.missingDependencies + layout.unresolved
        GeometryReader { geometry in
            let viewport = CGSize(width: geometry.size.width,
                                  height: max(0, geometry.size.height - Self.controlsHeight - (unarranged.isEmpty ? 0 : Self.warningHeight)))
            let scale = zoom ?? FlowGraphLayout.fit(layout, viewport: viewport)
            VStack(alignment: .trailing, spacing: 0) {
                controls(scale: scale).padding(.bottom, Self.controlsHeight - 28)
                canvas(layout, scale: scale, viewport: viewport)
                if !unarranged.isEmpty { warning(unarranged) }
            }
        }
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

    // MARK: Canvas

    private func canvas(_ layout: FlowGraphLayout.Layout, scale: CGFloat, viewport: CGSize) -> some View {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                FlowCanvasInteraction(onZoom: { factor in
                    if factor < 1, scale <= 0.1 { return }
                    zoom = min(2.5, max(0.1, scale * factor))
                })
                connections(layout)
                ForEach(layout.items, id: \.id) { item in
                    if let node = byID[item.id] {
                        FlowStepCard(node: node, selected: selected == node.id) { pick(node.id) }
                            .frame(width: FlowGraphLayout.cardWidth, height: FlowGraphLayout.cardHeight)
                            .offset(x: item.x, y: item.y)
                            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                                pick(item.id)
                                if dragStarts[item.id] == nil { dragStarts[item.id] = offsets[item.id] ?? .zero }
                                let start = dragStarts[item.id] ?? .zero
                                offsets[item.id] = boundedOffset(id: item.id, x: start.width + value.translation.width / scale, y: start.height + value.translation.height / scale)
                            }.onEnded { _ in dragStarts[item.id] = nil })
                    }
                }
                if nodes.isEmpty {
                    Text("This flow has no steps.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .padding(FlowGraphLayout.margin)
                }
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
            // the background stays draggable where the graph is smaller than the canvas
            .frame(minWidth: max(0, viewport.width - 2), minHeight: max(0, viewport.height - 2), alignment: .topLeading)
        }
    }

    /// Connectors under the cards: neutral, red only on the failed path, dashed into a skipped step, with a dot
    /// where each one arrives
    private func connections(_ layout: FlowGraphLayout.Layout) -> some View {
        Canvas { context, _ in
            let positions = Dictionary(layout.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let states = Dictionary(nodes.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
            var edges: [(path: Path, end: CGPoint, look: FlowWorkspaceSummary.EdgeLook)] = []
            for node in nodes {
                guard let target = positions[node.id] else { continue }
                for dependency in Set(node.needs) {
                    guard let source = positions[dependency] else { continue }
                    let start = CGPoint(x: source.x + FlowGraphLayout.cardWidth, y: source.y + FlowGraphLayout.cardHeight / 2)
                    let end = CGPoint(x: target.x, y: target.y + FlowGraphLayout.cardHeight / 2)
                    let middle = (start.x + end.x) / 2
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                    edges.append((path, end, FlowWorkspaceSummary.edgeLook(from: states[dependency] ?? nil, to: node.state)))
                }
            }
            // the failed path is drawn last, so a neutral connector never crosses over it
            for edge in edges.filter({ !$0.look.failed }) + edges.filter({ $0.look.failed }) {
                let color = edge.look.failed ? Color.red : HostedList.edge
                context.stroke(edge.path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: edge.look.dashed ? [4, 4] : []))
                context.fill(Path(ellipseIn: CGRect(x: edge.end.x - 3, y: edge.end.y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func warning(_ details: [String]) -> some View {
        Text("Some dependencies could not be arranged. Check the flow configuration.")
            .font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.waiting.text).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Self.warningHeight, alignment: .leading)
            .help(details.joined(separator: "\n"))
    }

    // MARK: Zoom control

    private func controls(scale: CGFloat) -> some View {
        HStack(spacing: 2) {
            Button { zoom = max(0.1, scale / 1.2) } label: { DesignIconImage(icon: .minus, size: 13) }
                .help("Zoom out").accessibilityLabel("Zoom out").disabled(scale <= 0.1)
            Text(scale, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 11, design: .monospaced)).frame(minWidth: 40)
            Button { zoom = min(2.5, scale * 1.2) } label: { DesignIconImage(icon: .plus, size: 13) }
                .help("Zoom in").accessibilityLabel("Zoom in").disabled(scale >= 2.5)
            Rectangle().fill(StudioStyle.border).frame(width: 1, height: 16)
            Button { zoom = nil } label: {
                Text("Fit").font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Fit graph to view")
            // only once a card was moved: there is nothing to reset before that
            if !offsets.isEmpty {
                Button { offsets = [:]; zoom = 1 } label: { SymbolIcon("arrow.counterclockwise") }
                    .help("Reset layout").accessibilityLabel("Reset layout")
            }
        }
        .buttonStyle(PullRequestIconButtonStyle())
        .padding(.horizontal, 2).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel("Dependency graph")
    }

    // MARK: Moving cards

    private func pick(_ id: String) {
        if selected != id { selected = id }
        graphFocused = true
    }

    private var inputs: [FlowGraphLayout.Input] { nodes.map { .init(id: $0.id, needs: $0.needs) } }

    /// The layout with each dragged card at its own place, and the canvas grown to hold it
    private func positionedLayout() -> FlowGraphLayout.Layout {
        let original = FlowGraphLayout.make(inputs)
        let margin = FlowGraphLayout.margin
        let items = original.items.map { item in
            let offset = offsets[item.id] ?? .zero
            return FlowGraphLayout.Item(id: item.id, x: max(margin, item.x + offset.width), y: max(margin, item.y + offset.height))
        }
        return .init(items: items,
                     width: max(original.width, (items.map(\.x).max() ?? 0) + FlowGraphLayout.cardWidth + margin),
                     height: max(original.height, (items.map(\.y).max() ?? 0) + FlowGraphLayout.cardHeight + margin),
                     missingDependencies: original.missingDependencies, unresolved: original.unresolved)
    }

    private func moveSelected(x: CGFloat, y: CGFloat) {
        guard let selected else { return }
        let current = offsets[selected] ?? .zero
        offsets[selected] = boundedOffset(id: selected, x: current.width + x, y: current.height + y)
    }

    /// A card never leaves the canvas at the top or the left
    private func boundedOffset(id: String, x: CGFloat, y: CGFloat) -> CGSize {
        let margin = FlowGraphLayout.margin
        let base = FlowGraphLayout.make(inputs).items.first { $0.id == id }
        return CGSize(width: max(margin - (base?.x ?? margin), x), height: max(margin - (base?.y ?? margin), y))
    }
}

/// One step: its state (a hollow circle before any run), its id and how long it took; then what it is for, in its own
/// words or as its kind; then the first line it runs. Selection is the tint alone; a skipped step has a dashed edge.
private struct FlowStepCard: View {
    let node: FlowGraphView.Node
    let selected: Bool
    let pick: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        let skipped = node.state == "SKIPPED"
        let failed = FlowWorkspaceSummary.tone(node.state) == .failed
        let duration = node.durationMs.map(FlowFormat.duration)
        let shape = RoundedRectangle(cornerRadius: 10)
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    FlowStateIcon(state: node.state, size: 14, spins: true)
                    Text(verbatim: node.id).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(skipped ? HostedList.caption : Color.primary)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if let duration {
                        Text(verbatim: duration).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(failed ? StudioStyle.Tone.failed.text : HostedList.caption).fixedSize()
                    }
                }
                Text(verbatim: FlowWorkspaceSummary.stepSummary(id: node.id, title: node.title) ?? FlowBlockStyle.look(node.block).title)
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption).lineLimit(1)
                if let command = FlowWorkspaceSummary.stepCommand(node.command) {
                    Text(verbatim: command).font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.caption).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Color.accentColor.opacity(0.16) : hovered ? StudioStyle.hover : Color.clear))
            .background(shape.fill(StudioStyle.surface))
            .overlay(shape.strokeBorder(skipped ? HostedList.edge : StudioStyle.border, style: StrokeStyle(lineWidth: 1, dash: skipped ? [4, 3] : [])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help([node.id, FlowFormat.stateTitle(node.state), duration].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel([node.id, FlowFormat.stateTitle(node.state), duration].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
