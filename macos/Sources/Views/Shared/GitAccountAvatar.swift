import SwiftUI

/// Reuse connected profiles, then public hosting profiles; private servers retain initials until connected.
struct GitAccountAvatar: View {
    let account: Gitch.Account
    @ViewState private var remoteURL: URL?
    private var connected: HostAccount? {
        AccountStore.shared.accounts.first {
            GitAccountPresentation.key(host: $0.host, username: $0.username) == GitAccountPresentation.key(host: account.hosts, username: account.id)
        }
    }
    private var knownURL: URL? {
        connected?.avatarURL.flatMap(URL.init(string:)) ?? GitAccountPresentation.avatarURL(host: account.hosts, username: account.id)
    }
    var body: some View {
        HostingAvatar(name: connected?.name ?? account.id, username: account.id, avatarURL: knownURL ?? remoteURL, size: 28)
            .task(id: account.id + account.hosts + String(AvatarStore.shared.enabled)) {
                guard AvatarStore.shared.enabled, knownURL == nil,
                      let server = URL(string: "https://" + GitAccountPresentation.host(account.hosts)), server.host != nil else { return }
                var parts = URLComponents(url: server.appendingPathComponent("api/v4/users"), resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "username", value: account.id)]
                guard let url = parts.url else { return }
                let request = URLRequest(url: url, timeoutInterval: 8)
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let profiles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let profile = profiles.first(where: { ($0["username"] as? String)?.lowercased() == account.id.lowercased() }),
                      let raw = profile["avatar_url"] as? String, let image = URL(string: raw, relativeTo: server),
                      ["http", "https"].contains(image.scheme?.lowercased() ?? "") else { return }
                remoteURL = image.absoluteURL
            }
    }
}
