import SwiftUI

/// Run diagrams and step lists keep a subtle separator and independent resizing.
struct FlowVerticalSplitView<Leading: View, Trailing: View>: View {
    var initialFraction: CGFloat = 0.66
    var minimumLeading: CGFloat = 220
    var minimumTrailing: CGFloat = 130
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewState private var fraction: CGFloat?
    @ViewState private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.height - 1)
            let lower = min(minimumLeading, available * 0.6)
            let upper = max(lower, available - min(minimumTrailing, available * 0.4))
            let height = min(max(available * (fraction ?? initialFraction), lower), upper)
            VStack(spacing: 0) {
                leading.frame(maxWidth: .infinity).frame(height: height).clipped()
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45)).frame(height: 1)
                    .overlay {
                        Color.clear.frame(height: 9).contentShape(Rectangle()).pointerStyle(.rowResize)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = height }
                                    fraction = min(max((dragStart ?? height) + value.translation.height, lower), upper) / max(1, available)
                                }.onEnded { _ in dragStart = nil })
                    }
                    .accessibilityLabel("Resize run panes")
                    .accessibilityAdjustableAction { direction in
                        fraction = min(max(height + (direction == .increment ? 20 : -20), lower), upper) / max(1, available)
                    }
                trailing.frame(maxWidth: .infinity).frame(height: max(0, available - height)).clipped()
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
