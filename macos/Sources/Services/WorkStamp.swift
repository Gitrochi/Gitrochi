import Foundation
import CryptoKit

enum WorkStamp {
    /// Hash tracked contents locally. Untracked data cannot be certified by this stamp.
    static func read(in repo: URL) async throws -> (head: String?, stamp: String) {
        let headResult = try await Git.run(["rev-parse", "--verify", "HEAD"], in: repo, ok: [0, 128])
        let head = headResult.status == 0 ? headResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let args = ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--binary"]
        let diff = try await Git.run(args + (head.map { [$0] } ?? ["--cached"]) + ["--"], in: repo)
        let unstaged = head == nil ? try await Git.run(args + ["--"], in: repo).output : ""
        let status = try await Git.run(["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignore-submodules=none"], in: repo)
        let flags = try await Git.run(["ls-files", "-v", "-z"], in: repo)
        let content = (head ?? "") + "\0" + diff.output + unstaged + "\0" + status.output
        let stamp = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        let untracked = status.output.split(separator: "\0").contains { $0.hasPrefix("? ") }
        let hidden = flags.output.split(separator: "\0").contains { row in row.hasPrefix("S ") || (row.first?.isLowercase == true) }
        let submodule = status.output.split(separator: "\0").contains { row in
            let fields = row.split(separator: " ")
            return fields.count > 2 && ["1", "2"].contains(fields[0]) && fields[2].hasPrefix("S") && (fields[2].contains("M") || fields[2].contains("U"))
        }
        return (head, (hidden || submodule ? "uncertified:" : untracked ? "untracked:" : "") + stamp)
    }
}
