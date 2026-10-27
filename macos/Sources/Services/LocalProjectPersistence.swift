import Foundation
import Darwin

protocol LocalProjectPersistence {
    func read() async throws -> String?
    func write(expected: String?, content: String) async throws
}

/// The file lock protects other app instances; atomic replacement preserves the last complete document.
actor LocalProjectFileStorage: LocalProjectPersistence {
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gitrochi/local-planner/projects.json")) { self.url = url }

    func read() throws -> String? { try withLock { try readUnlocked() } }
    func write(expected: String?, content: String) throws {
        try withLock {
            guard try readUnlocked() == expected else { throw LocalProjectError.stale }
            guard let data = content.data(using: .utf8), data.count <= LocalProjectLimits.maxBytes else { throw LocalProjectError.invalidData }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    private func readUnlocked() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= LocalProjectLimits.maxBytes else { throw LocalProjectError.invalidData }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw LocalProjectError.invalidData }
        return text
    }
    private func withLock<T>(_ work: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LocalProjectError.storage }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LocalProjectError.storage }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }
}
