import Foundation

/// 확인한 원본 SHA 와 목적지에만 push 하도록 검토 정보를 보존한다.
struct PushReviewPlan {
    struct Commit: Identifiable {
        let sha: String
        let subject: String
        let author: String
        let email: String
        var id: String { sha }
    }
    let repo: URL
    let branch: String
    let sourceOID: String
    let remote: String
    let destination: String
    let pushURL: String
    let destinationOID: String?
    let force: Bool
    let setUpstream: Bool
    let stamp: String
    let author: String
    let account: String
    let credentialAccount: String
    let preflight: Gitch.Preflight
    let commits: [Commit]
    let commitCount: Int
    let files: [String]
    let fileCount: Int
    let fileScope: String
    let comparisonBase: String?

    var displayURL: String { PushReview.displayURL(pushURL) }
    var arguments: [String] {
        ["push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no"]
            + (force ? ["--force-with-lease=\(destination):\(destinationOID ?? "")"] : [])
            + [remote, "\(sourceOID):\(destination)"]
    }
}

/// Git 의 기본 push 설정 중 단일 브랜치 목적지만 정확하게 풀어낸다.
enum PushReview {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { String(localized: String.LocalizationValue(message)) }
    }
    typealias Config = [String: [String]]

    static func config(_ output: String) -> Config {
        var result: Config = [:]
        for entry in output.split(separator: "\0") {
            guard let at = entry.firstIndex(of: "\n") else { continue }
            result[String(entry[..<at]), default: []].append(String(entry[entry.index(after: at)...]))
        }
        return result
    }

    static func displayURL(_ value: String) -> String {
        value.replacingOccurrences(of: "(?i)((?:https?|ssh|git|ftp)://)[^/@]+@", with: "$1[redacted]@", options: .regularExpression)
            .replacingOccurrences(of: "(?i)([?&](?:token|access_token|private_token|oauth_token|api_key|password)=)[^&\\s]*", with: "$1[redacted]", options: .regularExpression)
    }

    static func configStamp(_ config: Config) -> String {
        let relevant = config.filter { key, _ in
            ["branch.", "remote.", "push.", "url.", "user.", "gitsw.", "core.sshcommand", "credential."].contains { key.hasPrefix($0) }
        }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: relevant, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func destination(config: Config, remotes: [String], branch: String, currentBranch: String?, remoteOverride: String?) throws -> (remote: String, destination: String, setUpstream: Bool) {
        func value(_ key: String) -> String { config[key]?.last ?? "" }
        let choices = [remoteOverride ?? "", value("branch.\(branch).pushremote"), value("remote.pushdefault"), value("branch.\(branch).remote"), remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes[0] : ""]
        guard let remote = choices.first(where: { !$0.isEmpty }), remotes.contains(remote) else {
            throw Failure(message: "The push remote is missing or ambiguous. Configure a named remote first.")
        }
        guard !["true", "yes", "on", "1"].contains(value("remote.\(remote).mirror").lowercased()) else {
            throw Failure(message: "Mirror pushes cannot be reviewed as a single branch. Disable remote mirror mode first.")
        }
        let upstreamRemote = value("branch.\(branch).remote"), upstream = value("branch.\(branch).merge")
        var destination = "refs/heads/" + branch
        if remoteOverride == nil {
            let specs = config["remote.\(remote).push"] ?? []
            if !specs.isEmpty {
                guard specs.count == 1, !specs[0].contains(where: { "*+^".contains($0) }) else {
                    throw Failure(message: "Multiple, wildcard or forced push refspecs cannot be reviewed as a single branch. Configure one explicit branch refspec.")
                }
                let parts = specs[0].components(separatedBy: ":")
                let sources = [branch, "refs/heads/" + branch] + (currentBranch == branch ? ["HEAD"] : [])
                guard sources.contains(parts[0]), parts.count <= 2 else {
                    throw Failure(message: "The configured push refspec does not select this branch. Configure one explicit branch refspec.")
                }
                destination = parts.count == 2 ? parts[1] : "refs/heads/" + branch
                if !destination.hasPrefix("refs/") { destination = "refs/heads/" + destination }
            } else {
                let mode = value("push.default").isEmpty ? "simple" : value("push.default")
                switch mode {
                case "nothing", "matching":
                    throw Failure(message: "This push.default mode does not select a single branch. Use current, simple or upstream.")
                case "upstream", "tracking":
                    guard upstreamRemote == remote, !upstream.isEmpty else {
                        throw Failure(message: "The upstream push destination is missing or belongs to a different remote.")
                    }
                    destination = upstream
                case "simple":
                    if upstreamRemote == remote, !upstream.isEmpty, upstream != destination {
                        throw Failure(message: "The upstream branch has a different name. Select an explicit push refspec or use push.default=upstream.")
                    }
                case "current": break
                default: throw Failure(message: "The push.default mode is unsupported. Select an explicit branch refspec.")
                }
            }
        }
        let invalid = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "~^:?*[\\"))
        guard destination.hasPrefix("refs/heads/"), destination != "refs/heads/", destination.rangeOfCharacter(from: invalid) == nil,
              !destination.contains("//"), !destination.contains(".."), !destination.contains("@{"), !destination.hasSuffix("/"), !destination.hasSuffix("."),
              !destination.components(separatedBy: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) else {
            throw Failure(message: "The push destination is not a valid branch ref.")
        }
        return (remote, destination, upstreamRemote.isEmpty || upstream.isEmpty)
    }
}
