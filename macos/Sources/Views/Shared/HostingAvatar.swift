import SwiftUI

/// Hosting profiles use the same remote-image pattern as connected accounts, with the existing initials fallback.
struct HostingAvatar: View {
    let name: String
    var username = ""
    var avatarURL: URL?
    var size: CGFloat = 32

    var body: some View {
        AsyncImage(url: AvatarStore.shared.enabled ? avatarURL : nil) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Avatar(name: name.isEmpty ? username : name, email: username.isEmpty ? name : username, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
