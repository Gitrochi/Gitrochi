import SwiftUI

/// 중첩 NSSplitView 의 최소 크기가 창 밖으로 번지는 것을 막고 실제 가용 공간 안에서 두 열을 나눈다.
struct WorkspaceColumns<Leading: View, Trailing: View>: View {
    @Binding var width: Double
    let fixedTrailing: Bool
    let minimumFlexible: CGFloat
    var trailingCollapsed = false
    /// How much wider the columns will be once the sliding page list has folded (pageListOverhang). The fixed column
    /// keeps the width it will have then, and the flexible one is laid out that much wider and cut off, so neither
    /// is laid out again on every frame of the slide.
    var overhang: CGFloat = 0
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewState private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width + overhang
            let upper = max(250, min(380, total - minimumFlexible - 1))
            let fixed = min(max(width, 250), upper)
            let left = trailingCollapsed ? total : (fixedTrailing ? max(0, total - fixed - 1) : fixed)
            // a flexible leading column shows less than it is laid out at; a flexible trailing one passes the overhang on
            let shown = fixedTrailing ? max(0, left - overhang) : left
            HStack(spacing: 0) {
                leading
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .frame(width: left, height: geometry.size.height, alignment: .topLeading)
                    .frame(width: shown, alignment: .topLeading).clipped()
                    // each column moves as one piece; without the group every view in it would be moved on its own
                    .geometryGroup()
                if !trailingCollapsed { divider(upper: upper) }
                trailing
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .frame(width: max(0, geometry.size.width - shown - 1), height: geometry.size.height, alignment: .topLeading).clipped()
                    .geometryGroup()
                    .disabled(trailingCollapsed)
                    .accessibilityHidden(trailingCollapsed)
            }
            // the overhang follows the page list's slide; animated as well, the columns would be laid out on every frame after all
            .animation(nil, value: overhang)
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
