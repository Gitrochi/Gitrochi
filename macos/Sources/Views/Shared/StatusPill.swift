import SwiftUI

/// A status badge as docs/design.md draws it: an 11 pt icon first, then the label, in a tone's text on its fill; 18 pt
/// tall, 8 pt at each side, fully rounded, 11 pt semibold. Colour is never the only sign: the icon and the label say it.
struct StatusPill: View {
    let title: String
    let symbol: String
    let tone: StudioStyle.Tone

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone.text)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Capsule().fill(tone.fill))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
