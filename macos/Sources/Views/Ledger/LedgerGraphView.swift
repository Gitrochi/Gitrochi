import SwiftUI

/// Baselines as the trunk and sessions as lanes that fork from their base and join the version they went into,
/// drawn with the commit graph's lane width, row height, line width and colours. Newest on top; open sessions continue
/// upward as a dashed line. (Windows: widgets/ledger-workspace/ui/LedgerGraphView.tsx)
struct LedgerGraphView: View {
    let ledger: LedgerStore
    let open: (String) -> Void
    @ViewState private var laneOffset: CGFloat = 0
    @ViewState private var hovered: String?
    @ViewState private var cursor: String?
    @ViewState private var showLegend = false
    @FocusState private var focused: Bool

    private var plot: LedgerGraphPlot { ledger.plot }

    var body: some View {
        let visible = GraphMetrics.width(lanes: plot.lanes)
        let content = GraphMetrics.contentWidth(lanes: plot.lanes)
        let offset = GraphMetrics.clampOffset(laneOffset, content: content, visible: visible)
        VStack(spacing: 0) {
            header(visible: visible, content: content, offset: offset)
            Divider()
            if ledger.graph == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plot.rows.isEmpty {
                WorkspaceEmptyState(title: "Nothing in this period", systemImage: "point.3.connected.trianglepath.dotted",
                                    description: "No baseline or report falls in the period. Show a longer one.",
                                    actionTitle: ledger.range.wider == nil ? nil : "Show more",
                                    action: ledger.range.wider == nil ? nil : { Task { await ledger.showMoreGraph() } })
            } else {
                rows(visible: visible, offset: offset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hovered, let row = plot.rows.first(where: { $0.id == hovered }) {
                LedgerGraphCard(node: row.node, session: ledger.session(row.node.sessionId), baselines: ledger.state?.baselines ?? [])
                    .padding(.top, 52).padding(.trailing, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private func header(visible: CGFloat, content: CGFloat, offset: CGFloat) -> some View {
        WorkbenchFlow(spacing: 10) {
            Picker("Period", selection: Binding(get: { ledger.range }, set: { range in Task { await ledger.setRange(range) } })) {
                ForEach(LedgerRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("The period the graph covers; remembered")
            if ledger.project == nil, let projects = ledger.state?.projects, projects.count > 1 {
                Picker("Project", selection: Binding(get: { ledger.graphProject ?? "" }, set: { key in Task { await ledger.chooseGraphProject(key) } })) {
                    ForEach(projects) { Text($0.name).tag($0.key) }
                }
                .fixedSize()
                .help("Each project has its own trunk of baselines")
            }
            if content > visible {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: Binding(get: { Double(offset) }, set: { laneOffset = CGFloat($0) }), in: 0...Double(content - visible))
                        .controlSize(.mini).frame(width: 110)
                        .accessibilityLabel("Scroll the lanes")
                }
                .help("More lanes than fit: scroll them sideways")
            }
            Button { showLegend.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("What the shapes mean")
                .accessibilityLabel("Legend")
                .popover(isPresented: $showLegend, arrowEdge: .bottom) { LedgerGraphLegend() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(visible: CGFloat, offset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plot.rows) { row in
                        let session = row.node.sessionId
                        HStack(spacing: 0) {
                            LedgerGraphCell(row: row, offset: offset, selected: session != nil && session == ledger.selection && row.node.lane > 0)
                                .frame(width: visible, height: GraphMetrics.rowHeight)
                                .clipped()
                            LedgerGraphLabel(node: row.node, session: ledger.session(session))
                                .padding(.trailing, 14)
                        }
                        .background(rowBackground(row))
                        .contentShape(Rectangle())
                        .onHover { inside in hovered = inside ? row.id : (hovered == row.id ? nil : hovered) }
                        .onTapGesture {
                            focused = true
                            cursor = row.id
                            if let session { open(session) }
                        }
                        .id(row.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(session == nil ? [] : .isButton)
                        .accessibilityAction(named: "Open") { if let session { open(session) } }
                    }
                    footer
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.return) {
                guard let id = plot.rows.first(where: { $0.id == cursor })?.node.sessionId else { return .ignored }
                open(id)
                return .handled
            }
            .onChange(of: ledger.selection) { _, id in
                // a session picked elsewhere comes into view, lane included
                guard let id, let row = plot.rows.first(where: { $0.node.sessionId == id && $0.node.lane > 0 }) else { return }
                laneOffset = GraphMetrics.offset(revealing: row.node.lane, current: laneOffset,
                                                 content: GraphMetrics.contentWidth(lanes: plot.lanes), visible: GraphMetrics.width(lanes: plot.lanes))
                if cursor == nil || plot.rows.first(where: { $0.id == cursor })?.node.sessionId != id {
                    cursor = row.id
                    proxy.scrollTo(row.id, anchor: .center)
                }
            }
        }
    }

    private func rowBackground(_ row: LedgerGraphPlot.Row) -> Color {
        if row.id == cursor, focused { return StudioStyle.selection }
        if let id = row.node.sessionId, id == ledger.selection, row.node.lane > 0 { return StudioStyle.selection.opacity(0.6) }
        return hovered == row.id ? StudioStyle.hover : .clear
    }

    @ViewBuilder private var footer: some View {
        let hiddenSessions = ledger.state?.hiddenBefore ?? 0
        if plot.hiddenRows > 0 || (hiddenSessions > 0 && ledger.range.wider != nil) {
            HStack(spacing: 8) {
                Text(plot.hiddenRows > 0 ? String(localized: "Older rows not drawn yet: \(plot.hiddenRows)")
                                         : String(localized: "Older sessions outside this period: \(hiddenSessions)"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show more") { Task { await ledger.showMoreGraph() } }.controlSize(.small)
            }
            .padding(14)
        }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !plot.rows.isEmpty else { return }
        let index = plot.rows.firstIndex { $0.id == cursor }.map { $0 + delta } ?? 0
        let row = plot.rows[min(max(index, 0), plot.rows.count - 1)]
        cursor = row.id
        proxy.scrollTo(row.id)
        laneOffset = GraphMetrics.offset(revealing: row.node.lane, current: laneOffset,
                                         content: GraphMetrics.contentWidth(lanes: plot.lanes), visible: GraphMetrics.width(lanes: plot.lanes))
    }
}

/// One row of lanes, drawn the way GraphCell draws the commit graph: 2-point round lines, the same curves where a line
/// changes lanes, dashes for hand-offs and open sessions
private struct LedgerGraphCell: View {
    let row: LedgerGraphPlot.Row
    let offset: CGFloat
    let selected: Bool

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            func x(_ lane: Double) -> CGFloat {
                LedgerGraphPlot.point(lane: lane, row: 0, laneWidth: GraphMetrics.laneWidth, rowHeight: GraphMetrics.rowHeight,
                                      leftPad: GraphMetrics.leftPad).x - offset
            }
            for s in row.segments {
                let a = CGPoint(x: x(s.x1), y: h * s.y1), b = CGPoint(x: x(s.x2), y: h * s.y2)
                var p = Path()
                p.move(to: a)
                if s.x1 == s.x2 {
                    p.addLine(to: b)
                } else {
                    let mid = (a.y + b.y) / 2
                    p.addCurve(to: b, control1: CGPoint(x: a.x, y: mid), control2: CGPoint(x: b.x, y: mid))
                }
                ctx.stroke(p, with: .color(Palette.lane(s.color)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: s.dashed ? [3, 3] : []))
            }
            let node = row.node
            let color = Palette.lane(node.color)
            let center = CGPoint(x: x(Double(node.lane)), y: h / 2)
            let background = Color(nsColor: .textBackgroundColor)
            func circle(_ r: CGFloat) -> Path { Circle().path(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)) }
            switch node.kind {
            case .baseline:
                ctx.fill(circle(7), with: .color(background))
                ctx.fill(circle(6), with: .color(color))
                ctx.fill(circle(2.2), with: .color(background))
            case .release:
                ctx.fill(circle(7), with: .color(background))
                ctx.fill(circle(6), with: .color(color))
                ctx.stroke(circle(9), with: .color(color), lineWidth: 1.5)
            case .start:
                ctx.fill(circle(5.5), with: .color(background))
                ctx.stroke(circle(4.5), with: .color(color), lineWidth: 2)
            case .event:
                ctx.fill(circle(5.5), with: .color(background))
                ctx.fill(circle(4), with: .color(color))
            case .merge:
                ctx.fill(circle(5.5), with: .color(background))
                ctx.fill(circle(4), with: .color(color))
                ctx.stroke(circle(7.5), with: .color(color), lineWidth: 1.5)
            case .end:
                let square = Path(roundedRect: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9), cornerRadius: 1.5)
                ctx.fill(square, with: .color(color))
            }
            if selected { ctx.stroke(circle(10.5), with: .color(.accentColor), lineWidth: 1.5) }
        }
        .accessibilityHidden(true)
    }
}

/// What a row is: a baseline with its version, or a session's report
private struct LedgerGraphLabel: View {
    let node: LedgerGraphNode
    let session: LedgerSession?

    var body: some View {
        HStack(spacing: 8) {
            if node.lane == 0 {
                Label(node.version ?? node.label ?? "", systemImage: "tag")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if node.kind == .release, let by = node.sessionId {
                    Text("released by \(by)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                if let session { LedgerSessionLabel(id: session.id, color: session.color) }
                else if let id = node.sessionId { LedgerSessionLabel(id: id, color: node.color) }
                Text(node.label ?? "").font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                if node.kind == .start, let title = session?.title {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Text(LedgerTime.short(node.ts)).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(height: GraphMetrics.rowHeight)
    }
}

/// The card beside the graph for the row under the pointer
private struct LedgerGraphCard: View {
    let node: LedgerGraphNode
    let session: LedgerSession?
    let baselines: [LedgerBaseline]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if node.lane == 0 {
                let baseline = baselines.first { $0.version == node.version }
                Label(node.version ?? "", systemImage: "tag").font(.callout.weight(.semibold))
                if let baseline { Text(baseline.source.title + (baseline.note.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary) }
            } else if let session {
                HStack(spacing: 6) {
                    LedgerSessionLabel(id: session.id, color: session.color)
                    LedgerVerdictBadge(verdict: session.verdict)
                }
                Text(session.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(node.label ?? "").font(.caption).fixedSize(horizontal: false, vertical: true)
                if let base = session.baseVersion {
                    Text(base + " → " + (session.baseCurrent ?? base)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(LedgerTime.long(node.ts)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// What the graph's shapes mean
private struct LedgerGraphLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend").font(.headline)
            entry(.baseline, "Baseline")
            entry(.release, "Baseline a session released")
            entry(.start, "Session started")
            entry(.event, "Report")
            entry(.merge, "Merged into a baseline")
            entry(.end, "Closed or dropped")
            HStack(spacing: 8) {
                dashes.frame(width: 26, height: 14)
                Text("Hand-off, or a session still open")
            }
        }
        .font(.callout)
        .padding(14)
    }

    private var dashes: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            ctx.stroke(p, with: .color(Palette.lane(1)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 3]))
        }
    }

    private func entry(_ kind: LedgerGraphNode.Kind, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            LedgerGraphCell(row: .init(node: LedgerGraphNode(id: "legend", lane: 0, ts: 0, color: kind == .baseline || kind == .release ? 0 : 1, kind: kind),
                                       segments: []), offset: 4, selected: false)
                .frame(width: 26, height: 22)
            Text(title)
        }
    }
}
