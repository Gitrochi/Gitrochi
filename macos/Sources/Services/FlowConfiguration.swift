import Foundation

/// Editing flow sources never approves or executes their scripts.
extension FlowEngine {
    static let scriptExample = """
    version: 1
    flows:
      ci:
        description: Build, check and finish
        trigger: [manual]
        nodes:
          prepare:
            run: |
              echo "Preparing the workspace"
          check:
            needs: [prepare]
            run: |
              echo "Replace this command with your test script"
          finish:
            needs: [check]
            run: echo "Flow complete"
    """ + "\n"

    static func configurationFiles(in repo: URL) -> [String] {
        let fm = FileManager.default
        // The engine ignores flow.yaml when flow.yml is present.
        var paths = [fm.fileExists(atPath: repo.appendingPathComponent(".gitch/flow.yml").path) ? ".gitch/flow.yml" : ".gitch/flow.yaml"]
        let directory = repo.appendingPathComponent(".gitch/flows")
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            paths += names.filter { !$0.hasPrefix(".") && ["yml", "yaml"].contains(($0 as NSString).pathExtension) }.sorted().map { ".gitch/flows/" + $0 }
        }
        paths += [".gitch/flow.local.yml", ".gitch/flow.local.yaml"]
        return paths.filter {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: repo.appendingPathComponent($0).path, isDirectory: &directory) && !directory.boolValue
        }
    }

    /// Restores the original source after failed validation, unless another editor changed it.
    static func saveConfiguration(_ content: String, original: String?, file: String, in repo: URL) async throws {
        let allowed = configurationFiles(in: repo)
        guard allowed.contains(file) || (file == ".gitch/flow.yml" && original == nil) else {
            throw Failure(message: String(localized: "Choose an existing flow file to edit."))
        }
        let target = repo.appendingPathComponent(file)
        let fm = FileManager.default
        let current = fm.fileExists(atPath: target.path) ? try String(contentsOf: target, encoding: .utf8) : nil
        guard current == original else {
            throw Failure(message: String(localized: "This flow file changed outside Gitrochi. Reopen the editor before saving."))
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: target, atomically: true, encoding: .utf8)
        do {
            let result = try await run(["validate", "--json"], in: repo)
            guard result.status == 0 else { throw failure(result) }
        } catch {
            let currentDraft = try? String(contentsOf: target, encoding: .utf8)
            guard currentDraft == content else {
                throw Failure(message: String(localized: "The flow file changed during validation. Your other editor's changes were kept."))
            }
            if let original { try original.write(to: target, atomically: true, encoding: .utf8) }
            else { try fm.removeItem(at: target) }
            throw error
        }
    }
}
