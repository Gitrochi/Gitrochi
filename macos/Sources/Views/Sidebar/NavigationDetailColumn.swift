import SwiftUI

private struct PageListOverhangKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How much wider the page will be once the sliding page list has folded (PageListFold); otherwise 0. A page lays
    /// its flexible column out this much wider and cuts it off, so the column is laid out once for the whole slide.
    var pageListOverhang: CGFloat {
        get { self[PageListOverhangKey.self] }
        set { self[PageListOverhangKey.self] = newValue }
    }
}

/// The window's detail column: the icon rail, then the page (docs/design.md › App shell, Sidebar). Their places come
/// from how much of the page list is in the window on each frame of the list's own slide (PageListFold), not from an
/// animation of their own.
struct NavigationDetailColumn<Page: View>: View {
    /// The page list is sliding in or out
    let sliding: Bool
    @ViewBuilder let page: Page

    var body: some View {
        GeometryReader { geometry in
            // the column starts where the page list ends
            let fold = PageListFold(showing: geometry.frame(in: .global).minX, sliding: sliding)
            HStack(spacing: 0) {
                if fold.rail > 0 {
                    HStack(spacing: 0) {
                        NavigationSidebarRail()
                        Divider()
                    }
                    // the list uncovers the rail from the rail's right edge
                    .frame(width: fold.rail, alignment: .trailing)
                    .clipped()
                }
                page
                    .environment(\.pageListOverhang, fold.overhang)
                    .frame(width: max(0, geometry.size.width - fold.rail), height: geometry.size.height, alignment: .topLeading)
                    // the page moves as one piece; without the group every view in it would be moved on its own
                    .geometryGroup()
            }
            // these frames follow the list's slide; animated as well, the page would be laid out between its frames
            .animation(nil, value: [geometry.size.width, geometry.size.height, fold.rail, fold.overhang])
        }
    }
}
