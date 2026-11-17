import SwiftUI

/// The current marker of docs/design.md: a 12 pt accent dot in an 18 pt halo, standing in a row's 13 pt icon column
/// (Windows: `.side-current` in widgets/sidebar/ui/sidebar.css)
struct CurrentMarker: View {
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 12, height: 12)
            .background(Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 18, height: 18))
            .frame(width: 13, height: 18)
            .accessibilityLabel("Current")
    }
}
