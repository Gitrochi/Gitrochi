import SwiftUI

/// 좁은 창에서만 자동으로 접고, 사용자가 고른 펼침·접힘 상태는 유지한다.
struct SidebarPresentationState {
    private(set) var visibility: NavigationSplitViewVisibility = .automatic
    private(set) var isNarrow = false
    private var visibilityBeforeAutomaticCollapse: NavigationSplitViewVisibility?

    mutating func setNarrow(_ narrow: Bool) {
        guard narrow != isNarrow else { return }
        isNarrow = narrow
        if narrow {
            guard visibility != .detailOnly else { return }
            visibilityBeforeAutomaticCollapse = visibility
            visibility = .detailOnly
        } else {
            if let previous = visibilityBeforeAutomaticCollapse, visibility == .detailOnly {
                visibility = previous
            }
            visibilityBeforeAutomaticCollapse = nil
        }
    }

    mutating func setVisibility(_ value: NavigationSplitViewVisibility) {
        guard value != visibility else { return }
        visibilityBeforeAutomaticCollapse = nil
        visibility = value
    }

    mutating func expand() { setVisibility(.all) }
}
