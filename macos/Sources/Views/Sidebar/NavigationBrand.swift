import AppKit
import SwiftUI

/// The app mark anchors both the expanded navigation and its compact rail.
struct NavigationBrand: View {
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Gitrochi").font(.system(size: 15, weight: .semibold))
                    Text("Workspace").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Gitrochi")
    }
}
