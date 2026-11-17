import SwiftUI
import AppKit
import CryptoKit
import Observation

/// 커밋 작성자 프로필 사진. 이메일로 찾는다:
/// ① GitHub noreply 주소면 GitHub 프로필 ② 연결한 사내 GitLab 의 프로필 ③ Gravatar. 없으면 이니셜.
/// 받은 사진과 '없음'은 디스크에 저장해 두고(없음은 7일 뒤 다시 확인), 한 번에 4개까지만 받는다.
@MainActor @Observable
final class AvatarStore {
    static let shared = AvatarStore()

    var enabled: Bool = UserDefaults.standard.object(forKey: "avatarFetch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "avatarFetch") }
    }

    /// 사진을 새로 받을 때마다 올라간다(화면이 다시 그려지게). 사진 표 자체는 그리는 중에 채워도 되게 관찰하지 않는다.
    private(set) var version = 0
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var missing = Set<String>()
    @ObservationIgnored private var queued = Set<String>()
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running = 0

    private let directory: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitrochi/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func key(_ email: String) -> String {
        SHA256.hash(data: Data(email.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 작성자 이름(이메일로 못 찾을 때 GitLab 사용자 이름으로 찾는 데 씀)
    @ObservationIgnored private var names: [String: String] = [:]
    /// 열린 GitHub 저장소들(커밋 작성자의 GitHub 계정을 찾을 때) — 저장소 경로 owner/repo
    @ObservationIgnored private var githubRepos: [String] = []

    func noteGitHubRepo(_ path: String) {
        if !githubRepos.contains(path) { githubRepos.insert(path, at: 0) }
        if githubRepos.count > 3 { githubRepos.removeLast() }
    }

    /// 있으면 사진, 없으면 nil(필요하면 뒤에서 받기 시작)
    func image(for rawEmail: String, name: String = "") -> NSImage? {
        guard enabled else { return nil }
        _ = version
        let email = rawEmail.trimmed.lowercased()
        guard !email.isEmpty, email.contains("@") else { return nil }
        if let img = images[email] { return img }
        if missing.contains(email) || queued.contains(email) { return nil }
        // 디스크에 있으면 바로
        let file = directory.appendingPathComponent(key(email) + ".png")
        if let img = NSImage(contentsOf: file) {
            images[email] = img
            return img
        }
        let none = directory.appendingPathComponent(key(email) + ".none")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: none.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86_400 {
            missing.insert(email)
            return nil
        }
        if !name.isEmpty { names[email] = name }
        queued.insert(email)
        queue.append(email)
        pump()
        return nil
    }

    private func pump() {
        while running < 4, !queue.isEmpty {
            let email = queue.removeFirst()
            running += 1
            Task {
                let data = await Self.fetch(email, name: names[email] ?? "", gitlab: gitlabAccounts(), github: githubContext())
                running -= 1
                queued.remove(email)
                let base = directory.appendingPathComponent(key(email))
                if let data, let img = NSImage(data: data) {
                    try? data.write(to: base.appendingPathExtension("png"))
                    images[email] = img
                    version += 1
                } else {
                    missing.insert(email)
                    FileManager.default.createFile(atPath: base.appendingPathExtension("none").path, contents: nil)
                }
                pump()
            }
        }
    }

    private func githubContext() -> (token: String, repos: [String])? {
        let store = AccountStore.shared
        guard !githubRepos.isEmpty, let a = store.accounts(for: .github).first, let t = store.token(for: a) else { return nil }
        return (t, githubRepos)
    }

    private func gitlabAccounts() -> [(server: String, token: String)] {
        let store = AccountStore.shared
        return store.accounts(for: .gitlab).compactMap { a in store.token(for: a).map { (a.server, $0) } }
    }

    /// 이미 받은 '없음' 표시를 지우고 다시 받기(설정에서)
    func refresh() {
        missing.removeAll()
        images.removeAll()
        version += 1
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: 받기

    nonisolated private static func get(_ url: String, headers: [String: String] = [:]) async -> (Int, Data)? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.setValue("Gitrochi", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    nonisolated private static func image(_ url: String, headers: [String: String] = [:]) async -> Data? {
        guard let (code, data) = await get(url, headers: headers), code == 200, NSImage(data: data) != nil else { return nil }
        return data
    }

    nonisolated static func gravatarURL(_ email: String) -> String {
        let md5 = Insecure.MD5.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return "https://www.gravatar.com/avatar/\(md5)?s=64&d=404"
    }

    nonisolated private static func json(_ url: String, headers: [String: String]) async -> Any? {
        guard let (code, data) = await get(url, headers: headers), code == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// GitLab 사용자 목록에서 사진 주소(올린 사진만 — Gravatar 로 돌려주면 nil)
    nonisolated private static func gitlabAvatar(_ users: Any?, matchName: String? = nil) -> String? {
        var list = users as? [[String: Any]] ?? []
        if let n = matchName?.trimmed.lowercased(), !n.isEmpty {
            list = list.filter { ($0["name"] as? String)?.trimmed.lowercased() == n }
        }
        // 같은 이름이 여럿이면 누군지 몰라 쓰지 않는다
        guard list.count == 1, let url = list[0]["avatar_url"] as? String, !url.isEmpty, !url.contains("gravatar.com") else { return nil }
        return url
    }

    nonisolated private static func fetch(_ email: String, name: String, gitlab: [(server: String, token: String)],
                                          github: (token: String, repos: [String])?) async -> Data? {
        // ① GitHub noreply: 12345+name@users.noreply.github.com 또는 name@users.noreply.github.com
        if email.hasSuffix("@users.noreply.github.com") {
            let local = String(email.dropLast("@users.noreply.github.com".count))
            if let plus = local.firstIndex(of: "+"), let id = Int(local[..<plus]) {
                if let d = await image("https://avatars.githubusercontent.com/u/\(id)?s=64") { return d }
            } else if let d = await image("https://github.com/\(local).png?size=64") { return d }
        }
        // ② 사내 GitLab: 공개 이메일 → 이메일 검색 → 사용자 이름(이메일 앞부분) → 이름이 정확히 같은 한 사람
        let q = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let local = String(email.split(separator: "@").first ?? "")
        for g in gitlab {
            let h = ["PRIVATE-TOKEN": g.token]
            var url: String?
            if let obj = await json("\(g.server)/api/v4/avatar?email=\(q(email))&size=64", headers: h) as? [String: Any],
               let u = obj["avatar_url"] as? String, !u.isEmpty, !u.contains("gravatar.com") { url = u }
            if url == nil { url = gitlabAvatar(await json("\(g.server)/api/v4/users?search=\(q(email))&per_page=5", headers: h)) }
            if url == nil, !local.isEmpty {
                // 회사 GitLab 은 보통 사용자 이름 = 이메일 앞부분
                url = gitlabAvatar(await json("\(g.server)/api/v4/users?username=\(q(local))", headers: h))
            }
            if url == nil, !name.trimmed.isEmpty {
                url = gitlabAvatar(await json("\(g.server)/api/v4/users?search=\(q(name.trimmed))&per_page=20", headers: h), matchName: name)
            }
            guard let u = url else { continue }
            let full = u.hasPrefix("/") ? g.server + u : u
            if let d = await image(full, headers: full.hasPrefix(g.server) ? h : [:]) { return d }
        }
        // ③ GitHub 저장소: 그 이메일로 한 커밋의 GitHub 계정 사진
        if let github {
            for repo in github.repos {
                let h = ["Authorization": "Bearer \(github.token)", "Accept": "application/vnd.github+json"]
                if let list = await json("https://api.github.com/repos/\(repo)/commits?author=\(q(email))&per_page=1", headers: h) as? [[String: Any]],
                   let author = list.first?["author"] as? [String: Any], let u = author["avatar_url"] as? String,
                   let d = await image(u.contains("?") ? u + "&s=64" : u + "?s=64") { return d }
            }
        }
        // ④ Gravatar(없으면 404)
        return await image(gravatarURL(email))
    }
}

/// 작성자 동그라미: 프로필 사진이 있으면 사진, 없으면 이니셜
struct AuthorAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 20
    /// On a graph node, the lane whose ring it sits in: an initial then takes the person's node colour
    var lane: Int? = nil

    var body: some View {
        if let img = AvatarStore.shared.image(for: email, name: name) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Avatar(name: name, email: email, size: size, lane: lane)
        }
    }
}
