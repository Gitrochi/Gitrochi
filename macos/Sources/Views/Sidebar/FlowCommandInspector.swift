import SwiftUI

/// The selected step's metadata and exact script, using the same block language as the canvas.
struct FlowCommandInspector: View {
    let node: FlowPlan.Node?
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let node {
                    let category = FlowBlockStyle.look(node.block)
                    HStack(spacing: 10) {
                        Image(systemName: category.icon).font(.system(size: 16, weight: .medium)).foregroundStyle(category.color)
                            .frame(width: 36, height: 36).background(category.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Step details").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Text(node.id).font(.headline).textSelection(.enabled).lineLimit(2)
                        }
                    }
                    if let title = node.title, title != node.id, title != "Command" {
                        Text(title).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(node.block).font(.system(size: 10, design: .monospaced)).foregroundStyle(category.color)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(category.color.opacity(0.08), in: Capsule())
                        Spacer()
                        FlowStatusBadge(state: node.decision == "skip" ? "SKIPPED" : node.decision == "rejected" ? "REJECTED" : nil, compact: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        if !node.needs.isEmpty { field("Dependencies", node.needs.joined(separator: ", "), icon: "arrow.triangle.branch") }
                        field("Executor", node.executor ?? "local", icon: "desktopcomputer")
                        if let source = node.src { field("Source", source, icon: "doc.text") }
                    }
                    if let command = node.run { script("Script", command, icon: "terminal", color: category.color) }
                    if let undo = node.undo { script("Undo", undo, icon: "arrow.uturn.backward", color: .orange) }
                    if let reason = node.reason?.message {
                        Text(reason).font(.caption).foregroundStyle(.secondary).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if node.outward == true { Label("outward", systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.orange) }
                    if node.destructive == true { Label("hard to undo", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Button(action: onEdit) { Label("Edit scripts…", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Image(systemName: "cursorarrow.click").font(.title2).foregroundStyle(.tertiary)
                    Text("Choose a step to inspect its script.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func field(_ title: LocalizedStringKey, _ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func script(_ title: LocalizedStringKey, _ text: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.05))
            Divider().opacity(0.6)
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
    }
}
