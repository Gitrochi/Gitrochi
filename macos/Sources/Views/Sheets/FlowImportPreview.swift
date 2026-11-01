import SwiftUI

struct FlowImportDraft: Identifiable {
    let id = UUID()
    let name: String
    let inspection: FlowDesignInspection
}

enum FlowImportChoice { case flow, proposal, compose }

struct FlowImportReplacement: Identifiable {
    let id = UUID()
    let draft: FlowImportDraft
    let choice: FlowImportChoice
}

/// Foreign CI sources are previewed intact; only an explicitly chosen proposal becomes a local flow.
struct FlowImportPreview: View {
    let draft: FlowImportDraft
    let onUse: (FlowImportChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected: String?
    @ViewState private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import preview").font(.title3.weight(.semibold))
                    Text(draft.name + " · " + draft.inspection.format).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Source", isOn: $showSource).toggleStyle(.button).controlSize(.small)
            }
            Text("Import creates a separate flow file. Nothing runs, and the original source is kept unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            if showSource {
                ScrollView([.horizontal, .vertical]) {
                    Text(draft.inspection.yaml).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            } else {
                HSplitView {
                    FlowGraphView(nodes: previewNodes, selected: $selected, initialFit: true).frame(minWidth: 420, minHeight: 280)
                    importedDetails.frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                }
            }
            if !draft.inspection.diagnostics.isEmpty {
                ScrollView {
                    FlowDesignDiagnosticsView(diagnostics: draft.inspection.diagnostics)
                }.frame(maxHeight: 110)
            }
            if draft.inspection.proposal != nil {
                Label("The proposal triggers the original CI remotely. Configure its saved connection and review it before running.", systemImage: "arrow.up.forward.app")
                    .font(.caption).foregroundStyle(.orange)
            }
            if draft.inspection.format == "compose" {
                Text("Compose services remain in their original source. A deployment flow requires a project, service and image; its source is copied only when you save.")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Copying a Compose source changes its base directory. Review relative build, volume and environment-file paths before saving.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if draft.inspection.editable, draft.inspection.format == "flow" {
                    Button("Import as a new flow") { onUse(.flow); dismiss() }.buttonStyle(.borderedProminent)
                } else if draft.inspection.proposal != nil {
                    Button("Review proposed remote flow") { onUse(.proposal); dismiss() }.buttonStyle(.borderedProminent)
                } else if draft.inspection.format == "compose", draft.inspection.document != nil,
                          !draft.inspection.diagnostics.contains(where: { $0.severity == "error" }) {
                    Button("Configure Compose deployment") { onUse(.compose); dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(20).frame(width: 980, height: 720)
        .onAppear { selected = previewValues.keys.sorted().first }
    }

    private var previewValues: [String: FlowJSON] {
        let document = draft.inspection.document ?? .null
        switch draft.inspection.format {
        case "compose": return document["services"].object
        case "github": return document["jobs"].object
        case "gitlab": return document.object.filter { $0.value["script"] != .null || $0.value["trigger"] != .null }
        case "flow": return document["flows"].object.values.first?["nodes"].object ?? [:]
        default: return [:]
        }
    }

    private var previewNodes: [FlowGraphView.Node] {
        let values = previewValues
        return values.keys.sorted().map { id in
            let value = values[id] ?? .null
            let needs: [String]
            if draft.inspection.format == "compose" { needs = value["depends_on"].object.isEmpty ? value["depends_on"].dependencyIDs : value["depends_on"].object.keys.sorted() }
            else { needs = value["needs"].array.compactMap { $0.string ?? $0["job"].string } + (value["needs"].string.map { [$0] } ?? []) }
            return .init(id: id, title: value["description"].string ?? value["name"].string ?? id,
                         block: previewBlock(value), needs: needs, state: nil,
                         subtitle: value["image"].string ?? value["run"].string ?? value.string ?? value["script"].fieldText)
        }
    }

    private func previewBlock(_ value: FlowJSON) -> String {
        switch draft.inspection.format {
        case "github": return "ci.github.workflow"
        case "gitlab": return "ci.gitlab.pipeline"
        case "compose": return "docker.run"
        default:
            if let use = value["use"].string { return use }
            if let suite = value["suite"].string, let use = draft.inspection.document?["suites"][suite]["use"].string { return use }
            return value["flow"] != .null ? "flow" : "cmd"
        }
    }

    private var importedDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selected, let value = previewValues[selected] {
                    Text(selected).font(.headline).textSelection(.enabled)
                    importedField("Runner", value["runs-on"])
                    importedField("Condition", value["if"])
                    importedField("Image", value["image"])
                    importedField("Ports", value["ports"])
                    importedField("Volumes", value["volumes"])
                    let environmentKeys = Array(Set(Array(value["env"].object.keys) + Array(value["variables"].object.keys) + Array(value["environment"].object.keys))).sorted()
                    if !environmentKeys.isEmpty { importedField("Environment keys", .array(environmentKeys.map(FlowJSON.string))) }
                    importedField("Commands", value.string.map(FlowJSON.string) ?? value["script"])
                    importedField("Command", value["run"])
                    ForEach(Array(value["steps"].array.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(step["name"].string ?? "\(index + 1)").font(.caption.weight(.semibold))
                            importedField("Uses", step["uses"])
                            importedField("Command", step["run"])
                            importedField("Condition", step["if"])
                        }.padding(10).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else if draft.inspection.format == "jenkins" {
                    Label("Jenkins runs remotely", systemImage: "server.rack").font(.headline)
                    Text("Jenkins Groovy is preserved as source. Configure the saved Jenkins connection and job in the proposed remote flow.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Choose a module to inspect its source settings.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private func importedField(_ title: LocalizedStringKey, _ value: FlowJSON) -> some View {
        if value != .null {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(value.array.isEmpty ? value.fieldText : value.array.map(\.fieldText).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
