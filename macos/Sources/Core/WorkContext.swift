import Foundation

/// A bounded selection snapshot. The repository path is hashed locally, never serialized.
struct WorkContext: Codable, Equatable {
    let schemaVersion: Int
    let repositoryID: String
    let head: String?
    let revision: String?
    let scope: String
    let selectedPaths: [String]
    let selectedNodeIDs: [String]
    let screenID: String
    let observedAt: String
    let fingerprint: String

    init(repositoryPath: String, head: String?, scope: String, selectedPaths: [String] = [], selectedNodeIDs: [String] = [], screenID: String, observedAt: String? = nil, revision: String? = nil) {
        schemaVersion = 1
        let normalized = repositoryPath.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        repositoryID = "repo-" + Self.hash(normalized)
        self.head = head
        self.revision = revision
        self.scope = ["staged", "worktree", "commits"].contains(scope) ? scope : "worktree"
        self.selectedPaths = Array(Set(selectedPaths.filter(Self.safePath)).sorted().prefix(100))
        self.selectedNodeIDs = Array(Set(selectedNodeIDs.filter { !$0.isEmpty && $0.count <= 500 && $0.rangeOfCharacter(from: .controlCharacters) == nil }).sorted().prefix(100))
        self.screenID = String(screenID.prefix(100))
        self.observedAt = observedAt ?? ISO8601DateFormatter().string(from: Date())
        fingerprint = Self.hash(["1", repositoryID, head ?? "", revision ?? "", self.scope, self.screenID, self.selectedPaths.joined(separator: "\0"), self.selectedNodeIDs.joined(separator: "\0")].joined(separator: "\u{1f}"))
    }

    /// FNV-1a over UTF-8, mirrored by shared/lib/work-context.ts.
    static func hash(_ value: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return String(format: "%08x", hash)
    }

    static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 500, !path.hasPrefix("/"), path.rangeOfCharacter(from: CharacterSet(charactersIn: "\\:\0\r\n")) == nil,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return path.range(of: "(^|/)(?:\\.git|\\.env(?:\\..*)?|\\.ssh|\\.aws|\\.npmrc|\\.netrc|credentials?|secrets?)(?:/|$)|\\.(?:pem|key|p12|pfx|keystore)$|(^|/)id_(?:rsa|ed25519|ecdsa)(?:\\.|$)", options: [.regularExpression, .caseInsensitive]) == nil
    }

    var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }

    enum CodingKeys: String, CodingKey { case schemaVersion, repositoryID, head, revision, scope, selectedPaths, selectedNodeIDs, screenID, observedAt, fingerprint }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(repositoryID, forKey: .repositoryID)
        try values.encode(head, forKey: .head); try values.encode(revision, forKey: .revision); try values.encode(scope, forKey: .scope)
        try values.encode(selectedPaths, forKey: .selectedPaths); try values.encode(selectedNodeIDs, forKey: .selectedNodeIDs)
        try values.encode(screenID, forKey: .screenID); try values.encode(observedAt, forKey: .observedAt); try values.encode(fingerprint, forKey: .fingerprint)
    }
}

struct WorkGraphEdge: Codable, Equatable { let source: String; let target: String }
struct WorkGraphSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let nodeIDs: [String]
    let edges: [WorkGraphEdge]

    static func parse(_ text: String) -> WorkGraphSnapshot? {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), value.schemaVersion == 1, !value.id.isEmpty,
              value.nodeIDs.count <= 1000, Set(value.nodeIDs).count == value.nodeIDs.count,
              value.nodeIDs.allSatisfy({ !$0.isEmpty && $0.count <= 500 }), value.edges.count <= 4000 else { return nil }
        let known = Set(value.nodeIDs)
        return value.edges.allSatisfy { known.contains($0.source) && known.contains($0.target) } ? value : nil
    }
}

struct WorkGraphAction: Codable, Equatable { let kind: String; let nodeIDs: [String]? }
struct WorkGraphActions: Codable, Equatable {
    let schemaVersion: Int
    let snapshotID: String
    let actions: [WorkGraphAction]

    /// Validate the full envelope before changing any graph selection.
    static func validate(_ raw: Any, snapshot: WorkGraphSnapshot) -> WorkGraphActions? {
        guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: ["schemaVersion", "snapshotID", "actions"]),
              let data = try? JSONSerialization.data(withJSONObject: object), let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schemaVersion == 1, decoded.snapshotID == snapshot.id,
              let values = object["actions"] as? [[String: Any]], values.count <= 12 else { return nil }
        let known = Set(snapshot.nodeIDs)
        var actions: [WorkGraphAction] = []
        for value in values {
            if value["kind"] as? String == "clear", value.count == 1 { actions.append(WorkGraphAction(kind: "clear", nodeIDs: nil)); continue }
            guard let kind = value["kind"] as? String, ["nodes", "path"].contains(kind), Set(value.keys).isSubset(of: ["kind", "nodeIDs"]),
                  let ids = value["nodeIDs"] as? [String], !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count, ids.allSatisfy(known.contains) else { return nil }
            if kind == "path" {
                guard ids.count >= 2 else { return nil }
                for index in 1..<ids.count where !snapshot.edges.contains(WorkGraphEdge(source: ids[index - 1], target: ids[index])) { return nil }
            }
            actions.append(WorkGraphAction(kind: kind, nodeIDs: ids))
        }
        return WorkGraphActions(schemaVersion: 1, snapshotID: snapshot.id, actions: actions)
    }

    var encodedFragment: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
