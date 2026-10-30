import SwiftUI

/// Stable engine messages use the app's translations; unknown messages keep their original text.
struct FlowDesignDiagnosticsView: View {
    let diagnostics: [FlowDesignDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(FlowDesignDiagnostic.grouped(diagnostics)) { group in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: group.severity == "error" ? "xmark.circle" : "info.circle")
                        .foregroundStyle(group.severity == "error" ? Color.red : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(group.message))
                            .foregroundStyle(group.severity == "error" ? Color.red : .secondary)
                        if !group.paths.isEmpty {
                            Text(group.paths.joined(separator: ", "))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                .lineLimit(2).help(group.paths.joined(separator: "\n"))
                        }
                    }
                    if group.diagnostics.count > 1 {
                        Text(verbatim: "×\(group.diagnostics.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.07), in: Capsule())
                    }
                }
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
