import SwiftUI

/// The default authoring surface: modules, dependencies and typed block inputs.
struct FlowVisualEditor: View {
    @Bindable var design: FlowAuthoringStore
    @ViewState private var addModule = false
    @ViewState private var addFlow = false
    @ViewState private var flowName = ""
    @ViewState private var removeModule = false
    @ViewState private var connections: [FlowConnection] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Flow", selection: $design.selectedFlow) {
                    ForEach(design.flowNames, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 260)
                Button { addFlow = true } label: { Label("Add flow", systemImage: "plus") }
                Spacer()
                Button { addModule = true } label: { Label("Add module", systemImage: "square.stack.3d.up.badge.plus") }
                    .disabled(design.selectedFlow.isEmpty)
            }.controlSize(.small).padding(12)
            Divider()
            if design.flowNames.isEmpty {
                ContentUnavailableView("Add a flow", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create a flow, then add modules and connect their dependencies."))
            } else {
                HSplitView {
                    FlowGraphView(nodes: design.graphNodes, selected: $design.selectedNode, initialFit: true).id(design.selectedFlow)
                        .frame(minWidth: 380)
                    inspector.id(design.selectedNode).frame(minWidth: 300, idealWidth: 340, maxWidth: 430)
                }
            }
        }
        .sheet(isPresented: $addModule) { FlowModuleCatalog(design: design) }
        .alert("Add flow", isPresented: $addFlow) {
            TextField("Flow name", text: $flowName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { design.addFlow(flowName); flowName = "" }
        }
        .confirmationDialog("Remove this module and its dependency links?", isPresented: $removeModule) {
            Button("Remove module", role: .destructive) { design.removeNode() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: design.selectedFlow) { _, _ in design.selectedNode = design.nodeIDs.first; design.fieldErrors = [:] }
        .onChange(of: design.selectedNode) { _, _ in design.fieldErrors = [:] }
        .task { connections = (try? await FlowEngine.connections(in: design.flows.repo)) ?? [] }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let id = design.selectedNode {
                    let block = design.selectedBlock
                    HStack(spacing: 10) {
                        let style = FlowBlockStyle.look(block?.id ?? design.blockID(design.selected))
                        Image(systemName: style.icon).foregroundStyle(style.color).frame(width: 34, height: 34)
                            .background(style.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(id).font(.headline).textSelection(.enabled)
                            Text(block?.title ?? design.blockID(design.selected)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { removeModule = true } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove module")
                    }
                    if let block { FlowModuleEffects(block: block) }
                    Divider()
                    if design.selected["suite"] != .null {
                        FlowSchemaField(name: "suite", schema: .object(["type": .string("string")]), value: Binding(get: { design.nodeValue("suite") }, set: { design.setNodeValue("suite", $0) }), onError: { design.fieldErrors["suite"] = $0 })
                        Text("These inputs belong to the shared suite. The suite definition is preserved; node settings and dependencies can be edited here.").font(.caption).foregroundStyle(.secondary)
                        ForEach(design.suiteDefinition["with"].object.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key).font(.caption.weight(.medium))
                                Text(design.suiteDefinition["with"][key].fieldText).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    } else if let block {
                        Text("Inputs").font(.subheadline.weight(.semibold))
                        ForEach(block.inputs["properties"].object.keys.sorted(), id: \.self) { key in
                            let schema = inputSchema(key, block: block)
                            FlowSchemaField(name: key, schema: schema, value: Binding(get: { design.nodeValue(key, inputs: true) }, set: {
                                design.setNodeValue(key, $0 == .null ? nil : $0, inputs: true)
                            }), required: block.inputs["required"].array.compactMap(\.string).contains(key), onError: { design.fieldErrors[key] = $0 })
                            if let error = design.fieldErrors[key] { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    } else {
                        Text("This module's advanced settings are preserved. Use YAML to edit fields outside the catalogue.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    dependencies
                    DisclosureGroup("Execution settings") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(["description", "cwd", "timeout", "if"], id: \.self) { key in
                                FlowSchemaField(name: key, schema: .object(["type": .string("string")]), value: Binding(get: { design.nodeValue(key) }, set: {
                                    design.setNodeValue(key, $0 == .null ? nil : $0)
                                }), onError: { design.fieldErrors[key] = $0 })
                            }
                        }.padding(.top, 10)
                    }
                    DisclosureGroup("Advanced fields") {
                        FlowSchemaField(name: "Module JSON", schema: .object(["oneOf": .array([])]), value: Binding(get: { design.canonical(design.selected) }, set: {
                            design.change(["flows", design.selectedFlow, "nodes", id], $0)
                        }), onError: { design.fieldErrors["advanced"] = $0 }).padding(.top, 10)
                    }
                } else {
                    Text("Choose a module or add one to configure its inputs.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var dependencies: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Dependencies", systemImage: "arrow.triangle.branch").font(.subheadline.weight(.semibold))
            ForEach(design.nodeIDs.filter { $0 != design.selectedNode }, id: \.self) { id in
                let enabled = design.canonical(design.selected)["needs"].dependencyIDs.contains(id)
                Toggle(id, isOn: Binding(get: { enabled }, set: { design.toggleDependency(id, enabled: $0) }))
                    .toggleStyle(.checkbox).disabled(!enabled && !design.canDepend(on: id))
            }
            Text("Circular dependencies are disabled.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func inputSchema(_ key: String, block: FlowBlockCatalog.Block) -> FlowJSON {
        var schema = FlowInputSchema.field(key, block: block.id, schema: block.inputs["properties"][key])
        if key == "connection", !connections.isEmpty {
            var names = connections.map(\.name)
            if let current = design.nodeValue(key, inputs: true).string, !names.contains(current) { names.append(current) }
            schema = schema.setting(["enum"], to: .array(names.sorted().map(FlowJSON.string)))
        }
        return schema
    }
}

struct FlowModuleEffects: View {
    let block: FlowBlockCatalog.Block
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Effects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if block.outward { Label("Acts outside this computer", systemImage: "arrow.up.forward.app").foregroundStyle(.orange) }
            if block.destructive { Label("Review before running; changes may be hard to undo.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            ForEach(block.capabilities, id: \.self) { capability in Label(capabilityTitle(capability), systemImage: "circle.dotted").foregroundStyle(.secondary) }
            if let outputs = block.outputs, outputs != .null { Text(outputs.jsonText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
            Text("Results, outputs and errors appear in the run details.").foregroundStyle(.secondary)
        }
        .font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func capabilityTitle(_ value: String) -> String {
        switch value {
        case "process": return String(localized: "Runs a process")
        case "docker": return String(localized: "Uses Docker")
        case "network": return String(localized: "Uses network")
        case "secret", "secrets": return String(localized: "Reads saved credentials")
        case "ssh": return String(localized: "Uses SSH")
        case "ci", "ci-api", "remote-ci": return String(localized: "Uses remote CI")
        case "outward": return String(localized: "Acts outside this computer")
        default: return value
        }
    }
}

private struct FlowModuleCatalog: View {
    let design: FlowAuthoringStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var search = ""
    @ViewState private var selected = "cmd"
    @ViewState private var name = "step"
    private var block: FlowBlockCatalog.Block? { design.catalog.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add module").font(.title3.weight(.semibold))
            TextField("Search modules", text: $search).textFieldStyle(.roundedBorder)
            HSplitView {
                List(selection: $selected) {
                    ForEach(design.catalog.filter { search.isEmpty || ($0.id + $0.title + $0.category).localizedCaseInsensitiveContains(search) }) { block in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.title).font(.callout.weight(.medium))
                            Text(block.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }.tag(block.id).padding(.vertical, 3)
                    }
                }.frame(minWidth: 240)
                ScrollView {
                    if let block {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(block.title).font(.headline)
                            FlowModuleEffects(block: block)
                            Text("Inputs").font(.subheadline.weight(.semibold))
                            ForEach(block.inputs["properties"].object.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key).font(.caption.monospaced().weight(.medium))
                                    if let description = block.inputs["properties"][key]["description"].string { Text(description).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.padding(14)
                    }
                }.frame(minWidth: 300)
            }
            TextField("Module identifier", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                if let error = design.error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { if let block { design.addNode(id: name, block: block); if design.selectedNode == name { dismiss() } } }
                    .buttonStyle(.borderedProminent).disabled(block == nil || name.isEmpty)
            }
        }.padding(20).frame(width: 740, height: 600)
        .onChange(of: selected) { _, value in
            let base = value.replacingOccurrences(of: ".", with: "-")
            var proposal = base; var number = 2
            while design.nodes[proposal] != nil { proposal = "\(base)-\(number)"; number += 1 }
            name = proposal
        }
    }
}
