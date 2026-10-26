import SwiftUI

/// 창과 사이드바가 좁아져도 작업 버튼을 숨기지 않고 다음 줄에 배치한다.
struct WorkbenchFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        let available = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = ideal.width > available
                ? view.sizeThatFits(ProposedViewSize(width: available, height: nil)) : ideal
            if x > 0 && x + size.width > available {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y)); sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins, sizes)
    }
}

/// 목록과 상세가 각각 읽을 수 있는 폭을 확보하지 못하면 위아래로 전환한다.
struct AdaptiveWorkbenchSplit<Leading: View, Detail: View>: View {
    var threshold: CGFloat = 640
    var listWidth: CGFloat = 260
    @ViewBuilder var leading: Leading
    @ViewBuilder var detail: Detail
    @ViewState private var resizedWidth: CGFloat?
    @ViewState private var dragOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let stacked = geometry.size.width < threshold
            let width = max(180, min(resizedWidth ?? listWidth, min(360, geometry.size.width - 270)))
            // 배치만 바꾸고 자식의 identity는 유지해야 작성 중인 댓글·편집 내용이 보존된다.
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                leading
                    .frame(width: stacked ? nil : width, height: stacked ? max(120, min(220, geometry.size.height * 0.32)) : nil)
                    .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
                Color.clear
                    .frame(width: stacked ? nil : 5, height: stacked ? 1 : nil)
                    .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        guard !stacked else { return }
                        if dragOrigin == nil { dragOrigin = width }
                        resizedWidth = max(180, min((dragOrigin ?? width) + value.translation.width, min(360, geometry.size.width - 270)))
                    }.onEnded { _ in dragOrigin = nil })
                detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
