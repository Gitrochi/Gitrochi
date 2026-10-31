import SwiftUI

/// Paste reports: fenced ```ledger blocks (or JSON lines with an "event") from a conversation that could not report
/// itself; each block gets its own result. (Windows: features/import-ledger-reports/ui/LedgerImportSheet.tsx)
struct LedgerImportSheet: View {
    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    @ViewState private var results: [LedgerImportResult.Block]?
    @ViewState private var importing = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste reports").font(.title3.bold())
            Text("Paste a conversation or the ledger blocks from it. Every block is read on its own: one that fails does not stop the rest, and a block imported before is skipped.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .accessibilityLabel("Reports to import")
            if let results { resultList(results) }
            if let error { Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed)).textSelection(.enabled) }
            HStack {
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button(results == nil ? String(localized: "Cancel") : String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(importing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Import (⌘↩)")
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func resultList(_ results: [LedgerImportResult.Block]) -> some View {
        let imported = results.filter(\.ok).count, duplicates = results.filter(\.duplicate).count
        return VStack(alignment: .leading, spacing: 6) {
            Text(results.isEmpty ? String(localized: "No report blocks found.")
                                 : String(localized: "\(imported) imported · \(duplicates) already imported · \(results.count - imported - duplicates) failed"))
                .font(.callout.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results) { block in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: block.ok ? "checkmark.circle.fill" : block.duplicate ? "equal.circle" : "xmark.octagon.fill")
                                .foregroundStyle(block.ok ? Color(nsColor: .systemGreen) : block.duplicate ? .secondary : Color(nsColor: .systemRed))
                                .accessibilityHidden(true)
                            Text("Block \(block.index + 1)").font(.caption.weight(.semibold)).monospacedDigit()
                            Text(line(block)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private func line(_ block: LedgerImportResult.Block) -> String {
        if block.ok { return String(localized: "Imported into \(block.sessionId ?? "")") }
        if block.duplicate { return String(localized: "Already imported") }
        return block.error ?? String(localized: "Could not read this block")
    }

    private func run() {
        importing = true
        error = nil
        let pasted = text
        Task {
            do { results = try await ledger.importReports(pasted) } catch { self.error = error.localizedDescription }
            importing = false
        }
    }
}
