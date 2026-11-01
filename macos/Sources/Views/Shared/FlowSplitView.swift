import SwiftUI

/// Flow panes use an explicit theme separator instead of AppKit split-view drawing.
struct FlowSplitView<Leading: View, Trailing: View>: View {
    var initialFraction: CGFloat = 0.58
    var minimumLeading: CGFloat = 360
    var minimumTrailing: CGFloat = 280
    var maximumLeading: CGFloat? = nil
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewState private var fraction: CGFloat?
    @ViewState private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 1)
            let upper = max(minimumLeading, min(maximumLeading ?? available, available - minimumTrailing))
            let width = min(max(available * (fraction ?? initialFraction), minimumLeading), upper)
            if geometry.size.width < minimumLeading + minimumTrailing + 1 {
                VStack(spacing: 0) {
                    pane(leading).frame(height: max(180, geometry.size.height * 0.56))
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45)).frame(height: 1)
                    pane(trailing)
                }
            } else {
                HStack(spacing: 0) {
                    pane(leading).frame(width: width)
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45)).frame(width: 1)
                        .overlay {
                            Color.clear.frame(width: 9).contentShape(Rectangle()).pointerStyle(.columnResize)
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragStart == nil { dragStart = width }
                                        fraction = min(max((dragStart ?? width) + value.translation.width, minimumLeading), upper) / max(1, available)
                                    }.onEnded { _ in dragStart = nil })
                        }
                        .accessibilityLabel("Resize flow panes")
                        .accessibilityAdjustableAction { direction in
                            fraction = min(max(width + (direction == .increment ? 20 : -20), minimumLeading), upper) / max(1, available)
                        }
                    pane(trailing).frame(width: max(0, available - width))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pane<Content: View>(_ content: Content) -> some View {
        content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).clipped()
    }
}
