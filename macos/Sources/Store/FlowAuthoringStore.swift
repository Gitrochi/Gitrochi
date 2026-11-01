import Foundation
import Observation

/// Keeps a complete document; visual controls change only the fields a person edits.
@MainActor @Observable
final class FlowAuthoringStore {
    let flows: FlowStore
    var files: [String] = []
    var file = ".gitch/flow.yml"
    var original: String?
    var source = ""
    var yaml = ""
    var document: FlowJSON = .object([:])
    var baseline: FlowJSON = .object([:])
    var diagnostics: [FlowDesignDiagnostic] = []
    var catalog: [FlowBlockCatalog.Block] = []
    var selectedFlow = ""
    var selectedNode: String?
    var loading = false
    var saving = false
    var error: String?
    var editable = false
    var revision = 0
    var fieldErrors: [String: String] = [:]
    var attachments: [String: String] = [:]

    init(flows: FlowStore, initialFlow: String? = nil, initialNode: String? = nil) {
        self.flows = flows
        selectedFlow = initialFlow ?? ""
        selectedNode = initialNode
    }
    var dirty: Bool { yaml != (original ?? "") || document != baseline }
    var flowNames: [String] { document["flows"].object.keys.sorted() }
    var nodes: [String: FlowJSON] { document["flows"][selectedFlow]["nodes"].object }
    var nodeIDs: [String] { nodes.keys.sorted() }
    var selected: FlowJSON { selectedNode.flatMap { nodes[$0] } ?? .null }
    var suiteDefinition: FlowJSON { selected["suite"].string.map { document["suites"][$0] } ?? .null }
    var selectedBlock: FlowBlockCatalog.Block? {
        let id = selected["suite"] != .null ? suiteDefinition["use"].string ?? "" : blockID(selected)
        return catalog.first { $0.id == id }
    }
    var graphNodes: [FlowGraphView.Node] {
        nodeIDs.map { id in
            let node = canonical(nodes[id] ?? .null)
            return .init(id: id, title: node["description"].string ?? id, block: blockID(node), needs: node["needs"].dependencyIDs,
                         state: nil, subtitle: node["run"].string?.split(separator: "\n").first.map(String.init) ?? node["use"].string ?? "")
        }
    }

    func initialize() async {
        loading = true
        defer { loading = false }
        files = FlowEngine.configurationFiles(in: flows.repo)
        if files.isEmpty { files = [".gitch/flow.yml"] }
        do { catalog = try await FlowEngine.blockCatalog(in: flows.repo).blocks }
        catch { self.error = error.localizedDescription }
        await load(files[0])
    }

    func load(_ file: String) async {
        guard !saving else { return }
        loading = true
        defer { loading = false }
        self.file = file
        attachments = [:]
        fieldErrors = [:]
        error = nil
        do {
            let url = flows.repo.appendingPathComponent(file)
            original = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
            if let original { yaml = original }
            else { yaml = (try? await FlowEngine.proposeInit(in: flows.repo).yaml) ?? FlowEngine.scriptExample }
            try await inspect()
        } catch { self.error = error.localizedDescription; editable = false }
    }

    func inspect() async throws {
        let requestedYaml = yaml
        let requestedFile = file
        let result = try await FlowEngine.inspectDesign(requestedYaml, file: requestedFile, in: flows.repo)
        guard yaml == requestedYaml, file == requestedFile else { throw FlowEngine.Failure(message: String(localized: "The source changed while it was being inspected. Try again.")) }
        diagnostics = result.diagnostics
        editable = result.editable
        guard result.editable, let document = result.document else { return }
        self.document = document
        baseline = document
        source = yaml
        ensureSelection()
    }

    func updatePreview() async {
        guard editable, !saving else { return }
        let expected = revision
        let expectedYaml = yaml
        let expectedSource = source
        do {
            let value = try await FlowEngine.renderDesign(document, original: source, in: flows.repo)
            guard !Task.isCancelled, revision == expected, yaml == expectedYaml, source == expectedSource, !saving else { return }
            diagnostics = value.diagnostics
            guard !value.diagnostics.contains(where: { $0.severity == "error" }) else { return }
            yaml = value.yaml
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    /// A source-mode transition waits for the current visual document, so Save cannot use an older preview.
    func prepareSource() async throws {
        let expected = document
        let expectedSource = source
        let rendered = try await FlowEngine.renderDesign(expected, original: expectedSource, in: flows.repo)
        guard document == expected, source == expectedSource else { throw FlowEngine.Failure(message: String(localized: "The source changed while it was being inspected. Try again.")) }
        diagnostics = rendered.diagnostics
        if let problem = diagnostics.first(where: { $0.severity == "error" }) { throw FlowEngine.Failure(message: problem.message) }
        yaml = rendered.yaml
    }

    func change(_ path: [String], _ value: FlowJSON?) {
        guard !saving else { return }
        document = document.setting(path, to: value)
        revision += 1
        error = nil
    }

    func nodeValue(_ key: String, inputs: Bool = false) -> FlowJSON {
        let node = canonical(selected)
        return inputs && node["use"].string != nil ? node["with"][key] : node[key]
    }

    func setNodeValue(_ key: String, _ value: FlowJSON?, inputs: Bool = false) {
        guard let id = selectedNode, !saving else { return }
        if case .string = selected {
            document = document.setting(["flows", selectedFlow, "nodes", id], to: canonical(selected))
        }
        let inputPath = inputs && selected["use"].string != nil ? ["with", key] : [key]
        change(["flows", selectedFlow, "nodes", id] + inputPath, value)
    }

    func addFlow(_ name: String) {
        guard !saving else { return }
        guard validID(name), document["flows"][name] == .null else { error = String(localized: "Choose a unique name using letters, numbers, hyphens or underscores."); return }
        change(["flows", name], .object(["nodes": .object([:])]))
        selectedFlow = name
        selectedNode = nil
    }

    func addNode(id: String, block: FlowBlockCatalog.Block) {
        guard !saving else { return }
        guard validID(id), nodes[id] == nil else { error = String(localized: "Choose a unique name using letters, numbers, hyphens or underscores."); return }
        var input: [String: FlowJSON] = [:]
        let required = block.inputs["required"].array.compactMap(\.string)
        for key in required {
            let schema = block.inputs["properties"][key]
            input[key] = schema["default"] != .null ? schema["default"] : schema["type"].string == "object" ? .object([:]) : .string("")
        }
        let node: FlowJSON = block.id == "cmd" ? .object(input) : .object(["use": .string(block.id), "with": .object(input)])
        change(["flows", selectedFlow, "nodes", id], node)
        selectedNode = id
    }

    func removeNode() {
        guard let id = selectedNode, !saving else { return }
        for (other, value) in nodes where other != id {
            let dependencies = canonical(value)["needs"].dependencyIDs
            if dependencies.contains(id) {
                let remaining = dependencies.filter { $0 != id }
                change(["flows", selectedFlow, "nodes", other, "needs"], .array(remaining.map(FlowJSON.string)))
            }
        }
        change(["flows", selectedFlow, "nodes", id], nil)
        fieldErrors = [:]
        selectedNode = nodeIDs.first
    }

    func canDepend(on candidate: String) -> Bool {
        guard let selectedNode, selectedNode != candidate else { return false }
        var pending = [candidate]
        var seen = Set<String>()
        while let id = pending.popLast() {
            if id == selectedNode { return false }
            guard seen.insert(id).inserted else { continue }
            pending += canonical(nodes[id] ?? .null)["needs"].dependencyIDs
        }
        return true
    }

    func toggleDependency(_ id: String, enabled: Bool) {
        guard !enabled || canDepend(on: id) else { return }
        var dependencies = canonical(selected)["needs"].dependencyIDs.filter { $0 != id }
        if enabled { dependencies.append(id) }
        setNodeValue("needs", .array(dependencies.map(FlowJSON.string)))
    }

    func importDraft(yaml: String, name: String) async throws {
        guard !saving else { return }
        let safe = name.lowercased().replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let base = safe.isEmpty ? "imported-flow" : safe
        var target = ".gitch/flows/\(base).yml"
        var number = 2
        while FileManager.default.fileExists(atPath: flows.repo.appendingPathComponent(target).path) {
            target = ".gitch/flows/\(base)-\(number).yml"; number += 1
        }
        file = target
        original = nil
        self.yaml = yaml
        attachments = [:]
        fieldErrors = [:]
        try await inspect()
        if !files.contains(target) { files.append(target) }
    }

    func importCompose(_ inspection: FlowDesignInspection, name: String) async throws {
        let safe = name.lowercased().replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        var sourceFile = ".gitch/imports/\(safe.isEmpty ? "compose" : safe).yml"
        var number = 2
        while FileManager.default.fileExists(atPath: flows.repo.appendingPathComponent(sourceFile).path) {
            sourceFile = ".gitch/imports/\(safe)-\(number).yml"; number += 1
        }
        let services = inspection.document?["services"].object ?? [:]
        let deployment: FlowJSON = .object(["version": .number(1), "flows": .object(["compose-deploy": .object(["nodes": .object([
            "deploy": .object(["use": .string("deploy.compose"), "with": .object(["file": .string(sourceFile), "project": .string(""),
                "service": .string(services.keys.sorted().first ?? ""), "image": .string("")])])
        ])])])])
        let rendered = try await FlowEngine.renderDesign(deployment, original: nil, in: flows.repo)
        try await importDraft(yaml: rendered.yaml, name: name + "-flow")
        attachments[sourceFile] = inspection.yaml
    }

    func save(visual: Bool) async throws {
        guard !saving else { throw FlowEngine.Failure(message: String(localized: "Wait for the current save to finish.")) }
        guard fieldErrors.isEmpty else { throw FlowEngine.Failure(message: String(localized: "Correct the highlighted inputs before saving.")) }
        saving = true
        defer { saving = false }
        if visual { try await prepareSource() }
        var written: [String] = []
        do {
            for (path, content) in attachments {
                let target = flows.repo.appendingPathComponent(path)
                guard !FileManager.default.fileExists(atPath: target.path) else { throw FlowEngine.Failure(message: String(localized: "An imported source file already exists. Import again to choose a new destination.")) }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: target, options: .withoutOverwriting)
                written.append(path)
            }
            try await FlowEngine.saveConfiguration(yaml, original: original, file: file, in: flows.repo)
        } catch {
            for path in written {
                let target = flows.repo.appendingPathComponent(path)
                if (try? String(contentsOf: target, encoding: .utf8)) == attachments[path] { try? FileManager.default.removeItem(at: target) }
            }
            throw error
        }
        attachments = [:]
        original = yaml
        baseline = document
        await flows.refresh()
    }

    func blockID(_ node: FlowJSON) -> String {
        if let use = node["use"].string { return use }
        if node.string != nil || node["run"] != .null { return "cmd" }
        if node["flow"] != .null { return "flow" }
        return node["suite"] != .null ? "suite" : "unknown"
    }
    func canonical(_ node: FlowJSON) -> FlowJSON { node.string.map { .object(["run": .string($0)]) } ?? node }
    private func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil }
    private func ensureSelection() {
        if !flowNames.contains(selectedFlow) { selectedFlow = flowNames.first ?? "" }
        if !nodeIDs.contains(selectedNode ?? "") { selectedNode = nodeIDs.first }
    }
}
