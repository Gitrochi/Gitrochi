import SwiftUI

/// 중첩 NSSplitView 의 최소 크기가 창 밖으로 번지는 것을 막고 실제 가용 공간 안에서 두 열을 나눈다.
struct WorkspaceColumns<Leading: View, Trailing: View>: View {
    @Binding var width: Double
    let fixedTrailing: Bool
    let minimumFlexible: CGFloat
    var trailingCollapsed = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewState private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let upper = max(250, min(380, geometry.size.width - minimumFlexible - 1))
            let fixed = min(max(width, 250), upper)
            let left = trailingCollapsed ? geometry.size.width : (fixedTrailing ? max(0, geometry.size.width - fixed - 1) : fixed)
            HStack(spacing: 0) {
                leading
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .frame(width: left, height: geometry.size.height, alignment: .topLeading).clipped()
                if !trailingCollapsed { divider(upper: upper) }
                trailing
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .frame(width: max(0, geometry.size.width - left - 1), height: geometry.size.height, alignment: .topLeading).clipped()
                    .disabled(trailingCollapsed)
                    .accessibilityHidden(trailingCollapsed)
            }
        }
    }

    private func divider(upper: CGFloat) -> some View {
        Rectangle().fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? width
                            if dragStart == nil { dragStart = start }
                            let delta = value.translation.width * (fixedTrailing ? -1 : 1)
                            width = min(max(start + delta, 250), upper)
                        }
                        .onEnded { _ in dragStart = nil })
            }
            .accessibilityLabel("Resize file and detail columns")
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { direction in
                width = min(max(width + (direction == .increment ? 20 : -20), 250), upper)
            }
    }
}
