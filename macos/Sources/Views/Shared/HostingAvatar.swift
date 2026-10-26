import SwiftUI

/// Hosting profiles use the same remote-image pattern as connected accounts, with the existing initials fallback.
struct HostingAvatar: View {
    enum Style { case person, organization }

    let name: String
    var username = ""
    var avatarURL: URL?
    var size: CGFloat = 32
    var style: Style = .person

    private var shape: AnyShape {
        style == .organization
            ? AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            : AnyShape(Circle())
    }

    var body: some View {
        AsyncImage(url: AvatarStore.shared.enabled ? avatarURL : nil) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                if style == .organization {
                    shape.fill(Palette.lane(Palette.stableHash((username.isEmpty ? name : username).lowercased())))
                        .overlay(Text((name.isEmpty ? username : name).first.map { String($0).uppercased() } ?? "?")
                            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
                } else {
                    Avatar(name: name.isEmpty ? username : name, email: username.isEmpty ? name : username, size: size)
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
