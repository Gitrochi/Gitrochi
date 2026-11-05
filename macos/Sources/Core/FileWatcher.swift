import Foundation
import CoreServices

/// 저장소 폴더(작업 트리 + .git)의 변경을 FSEvents 로 받아 콜백한다.
/// 파일 단위로 받아서(.git/index 와 .git/HEAD 를 구별해야 해서) 어떤 새로 고침이 필요한지 고를 수 있게 한다.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]) -> Void

    /// paths: 작업 트리와, 그 밖에 있는 git 폴더들(연결된 워크트리의 .git/worktrees/<이름>, 공용 .git)
    init(paths: [String], callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let handler: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.callback(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(nil, handler, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// 최근 연 저장소 목록(UserDefaults)
enum Recents {
    private static let key = "recentRepositories"
    /// When each repository was last opened, by path; Home shows it beside the repository
    private static let openedKey = "recentRepositoryOpened"

    static func load() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @discardableResult
    static func add(_ url: URL) -> [URL] {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        let kept = Array(list.prefix(12))
        UserDefaults.standard.set(kept, forKey: key)
        var opened = (UserDefaults.standard.dictionary(forKey: openedKey) as? [String: Double]) ?? [:]
        opened[url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(opened.filter { kept.contains($0.key) }, forKey: openedKey)
        return load()
    }

    /// When the repository was last opened; nil for one opened before this was recorded
    static func opened(_ url: URL) -> Date? {
        ((UserDefaults.standard.dictionary(forKey: openedKey) as? [String: Double]) ?? [:])[url.path].map(Date.init(timeIntervalSince1970:))
    }

    @discardableResult
    static func remove(_ url: URL) -> [URL] {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        UserDefaults.standard.set(list, forKey: key)
        return load()
    }
}
