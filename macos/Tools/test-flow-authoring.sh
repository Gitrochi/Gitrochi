#!/usr/bin/env bash
# Exercises the actual authoring store without credentials, app launch or script execution.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
cat > "$FIXTURE/Fixture.swift" <<'SWIFT'
import Foundation

struct FlowGraphView {
    struct Node {
        let id: String
        let title: String
        let block: String
        let needs: [String]
        let state: String?
        let subtitle: String
    }
}
@MainActor final class FlowStore {
    let repo = FileManager.default.temporaryDirectory
    func refresh() async {}
}
@MainActor enum FlowEngine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static var renderDelay = false
    static var inspectDelay = false
    static var scriptExample = "version: 1\nflows: {}\n"
    static func configurationFiles(in repo: URL) -> [String] { [] }
    static func blockCatalog(in repo: URL) async throws -> FlowBlockCatalog { try JSONDecoder().decode(FlowBlockCatalog.self, from: Data("{\"blocks\":[]}".utf8)) }
    static func proposeInit(in repo: URL) async throws -> FlowInitProposal { fatalError("not used") }
    static func inspectDesign(_ yaml: String, file: String, in repo: URL) async throws -> FlowDesignInspection {
        if inspectDelay { try await Task.sleep(for: .milliseconds(60)) }
        return try JSONDecoder().decode(FlowDesignInspection.self, from: Data("{\"document\":{\"flows\":{}},\"yaml\":\"original\",\"format\":\"flow\",\"diagnostics\":[],\"editable\":true,\"proposal\":null}".utf8))
    }
    static func renderDesign(_ document: FlowJSON, original: String?, in repo: URL) async throws -> FlowDesignRendered {
        if renderDelay { try await Task.sleep(for: .milliseconds(60)) }
        return try JSONDecoder().decode(FlowDesignRendered.self, from: Data("{\"yaml\":\"rendered old source\",\"diagnostics\":[],\"formattingChanged\":true}".utf8))
    }
    static func saveConfiguration(_ content: String, original: String?, file: String, in repo: URL) async throws { fatalError("not used") }
}
@main struct AuthoringTests {
    @MainActor static func main() async throws {
        let warnings = (0..<6).map { FlowDesignDiagnostic(severity: "warning", code: "CI_PROVIDER_SEMANTICS", message: "Preserved provider field", path: "jobs.checks.step\($0)", line: nil) }
        let grouped = FlowDesignDiagnostic.grouped(warnings)
        precondition(warnings.count == 6 && grouped.count == 1)
        precondition(grouped[0].diagnostics.count == 6 && grouped[0].paths.count == 6)
        let different = FlowDesignDiagnostic(severity: "info", code: "FORMAT_NORMALIZED", message: "Review formatting", path: nil, line: nil)
        precondition(FlowDesignDiagnostic.grouped(warnings + [different]).count == 2)
        let wide = FlowGraphLayout.make((0..<6).map { .init(id: "stage-\($0)", needs: $0 == 0 ? [] : ["stage-\($0 - 1)"]) })
        let fit = FlowGraphLayout.fit(wide, viewport: CGSize(width: 500, height: 300))
        precondition(fit < 0.35 && wide.width * fit <= 488.001)
        let tall = FlowGraphLayout.make((0..<6).map { .init(id: "parallel-\($0)", needs: []) })
        let verticalFit = FlowGraphLayout.fit(tall, viewport: CGSize(width: 500, height: 220))
        precondition(tall.height * verticalFit <= 172.001)
        let store = FlowAuthoringStore(flows: FlowStore())
        store.document = try JSONDecoder().decode(FlowJSON.self, from: Data("""
        {"version":1,"custom":{"keep":true},"suites":{"unit":{"use":"test.junit","with":{"report":"results.xml","run":"test-command"}}},"flows":{"verify":{"nodes":{
        "explicit":{"use":"cmd","with":{"run":"echo explicit","customInput":"keep"},"futureOption":{"keep":true}},
        "short":"echo shorthand",
        "a":{"run":"echo a"},
        "b":{"needs":["a"],"run":"echo b"},
        "c":{"needs":["b"],"run":"echo c"},
        "suite":{"suite":"unit"},
        "nested":{"flow":"another"}
        }}}}
        """.utf8))
        store.selectedFlow = "verify"
        store.selectedNode = "explicit"
        precondition(store.nodeValue("run", inputs: true).string == "echo explicit")
        store.setNodeValue("run", .string("echo changed"), inputs: true)
        precondition(store.selected["with"]["run"].string == "echo changed")
        precondition(store.selected["run"] == .null)
        precondition(store.selected["with"]["customInput"].string == "keep")
        precondition(store.selected["futureOption"]["keep"].bool == true)
        precondition(store.document["custom"]["keep"].bool == true)
        store.selectedNode = "short"
        store.setNodeValue("run", .string("echo changed shorthand"), inputs: true)
        precondition(store.selected["run"].string == "echo changed shorthand")
        precondition(store.selected["with"] == .null)
        precondition(store.blockID(store.nodes["nested"]!) == "flow")
        store.selectedNode = "suite"
        precondition(store.suiteDefinition["use"].string == "test.junit")
        let suiteBefore = store.document["suites"]
        store.setNodeValue("timeout", .string("5m"))
        precondition(store.document["suites"] == suiteBefore)
        store.selectedNode = "a"
        precondition(!store.canDepend(on: "c"))
        precondition(!store.canDepend(on: "a"))
        store.toggleDependency("c", enabled: true)
        precondition(store.selected["needs"] == .null)
        store.selectedNode = "b"
        store.removeNode()
        precondition(store.nodes["b"] == nil)
        precondition(store.nodes["c"]?["needs"].dependencyIDs == [])
        store.saving = true
        let frozen = store.document
        store.selectedNode = "a"
        store.setNodeValue("run", .string("must not change"), inputs: true)
        store.removeNode()
        precondition(store.document == frozen)
        store.saving = false
        store.editable = true
        store.source = "source"
        store.yaml = "source"
        FlowEngine.renderDelay = true
        let render = Task { await store.updatePreview() }
        try await Task.sleep(for: .milliseconds(10))
        store.yaml = "newly typed YAML"
        await render.value
        precondition(store.yaml == "newly typed YAML")
        FlowEngine.inspectDelay = true
        let inspection = Task { try await store.inspect() }
        try await Task.sleep(for: .milliseconds(10))
        store.yaml = "even newer YAML"
        do { try await inspection.value; preconditionFailure("stale inspection accepted") } catch {}
        precondition(store.yaml == "even newer YAML")
        precondition(store.document == frozen)
        print("PASS: authoring preserves unknown inputs, explicit cmd, shorthand, suites, subflows, dependencies, save lock and newer YAML")
    }
}
SWIFT
swiftc -parse-as-library -module-cache-path "$FIXTURE/modules" \
    "$REPO_ROOT/macos/Sources/Core/FlowModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowDesignModels.swift" \
    "$REPO_ROOT/macos/Sources/Core/FlowGraphLayout.swift" \
    "$REPO_ROOT/macos/Sources/Store/FlowAuthoringStore.swift" "$FIXTURE/Fixture.swift" -o "$FIXTURE/test-authoring"
"$FIXTURE/test-authoring"
