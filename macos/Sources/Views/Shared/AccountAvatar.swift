import AppKit
import Observation
import SwiftUI

/// Profile photos by address, fetched once off the main thread and kept for the session, so the toolbar button, its
/// popover and Settings show the same picture without loading it again. A failed address is tried again after a while.
@MainActor @Observable
final class AccountPhotoStore {
    static let shared = AccountPhotoStore()

    /// Bumped when a photo arrives, so the views that asked for it redraw
    private(set) var version = 0
    @ObservationIgnored private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var loading = Set<URL>()
    @ObservationIgnored private var failed: [URL: Date] = [:]

    func image(for url: URL) -> NSImage? {
        _ = version
        if let image = images[url] { return image }
        load(url)
        return nil
    }

    private func load(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !loading.contains(url) else { return }
        if let last = failed[url], Date().timeIntervalSince(last) < 300 { return }
        loading.insert(url)
        Task {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
            let data = try? await URLSession.shared.data(for: request).0
            loading.remove(url)
            if let data, let image = NSImage(data: data), image.isValid {
                images[url] = image; failed[url] = nil; version += 1
            } else {
                failed[url] = Date()
            }
        }
    }
}

/// One account, one picture: its profile photo, and the initial only for an account without one or while photos are
/// turned off. (Windows: AccountAvatar)
struct AccountAvatar: View {
    let name: String?
    let username: String
    let avatarURL: URL?
    var size: CGFloat = 24

    init(account: HostAccount, size: CGFloat = 24) {
        name = account.name; username = account.username; avatarURL = account.avatarURL.flatMap(URL.init(string:)); self.size = size
    }

    /// A Git identity that reuses a hosting profile
    init(name: String?, username: String, avatarURL: URL?, size: CGFloat = 24) {
        self.name = name; self.username = username; self.avatarURL = avatarURL; self.size = size
    }

    var body: some View {
        Group {
            if AvatarStore.shared.enabled, let avatarURL, let image = AccountPhotoStore.shared.image(for: avatarURL) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Palette.lane(Palette.stableHash(username.lowercased())))
                    .overlay(Text(verbatim: AccountPresentation.initial(name: name, username: username))
                        .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
