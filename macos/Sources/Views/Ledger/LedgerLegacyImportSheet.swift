import SwiftUI
import AppKit

/// Import from claude-ledger: copies the standalone tool's database into the ledger without writing to that file. It
/// first counts what is new (a dry run), then imports on request; sessions the ledger already has stay as they are.
/// (Windows: features/import-ledger-reports/ui/LedgerLegacyImport.tsx)
struct LedgerLegacyImportSheet: View {
    let ledger: LedgerStore
    let path: String
    /// Back to pasting reports, when this replaced the Import sheet's content
    var back: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var preview: LedgerLegacyImportResult?
    @ViewState private var result: LedgerLegacyImportResult?
    @ViewState private var working = false
    @ViewState private var error: String?

    /// Asks for the claude-ledger database; nil when the person cancels
    @MainActor static func chooseDatabase() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the claude-ledger database to import. Gitrochi only reads it.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from claude-ledger").font(.title3.bold())
            Text("Gitrochi only reads this file and never changes it. Sessions the ledger already has are left as they are.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: path)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .help(path)
            if let summary = result ?? preview { counts(summary) }
            if let error { Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed)).textSelection(.enabled) }
            HStack {
                if let back, result == nil { Button("Back") { back() } }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(result == nil ? String(localized: "Cancel") : String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Import") { Task { await run(dryRun: false) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || preview.map(Self.isEmpty) ?? true)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { await run(dryRun: true) }
    }

    /// Nothing the ledger does not have already
    static func isEmpty(_ summary: LedgerLegacyImportResult) -> Bool {
        let c = summary.counts
        return c.projects + c.baselines + c.baselinesUpdated + c.sessions + c.events + c.questions + c.imports == 0
    }

    private func counts(_ summary: LedgerLegacyImportResult) -> some View {
        let c = summary.counts
        return VStack(alignment: .leading, spacing: 6) {
            Text(summary.dryRun ? (Self.isEmpty(summary) ? String(localized: "Nothing new to import.") : String(localized: "Ready to import:"))
                                : String(localized: "Imported:"))
                .font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                row("Sessions", c.sessions)
                row("Events", c.events)
                row("Questions", c.questions)
                row("Baselines", c.baselines)
                if c.baselinesUpdated > 0 { row("Baselines completed", c.baselinesUpdated) }
                row("Projects", c.projects)
                row("Pasted blocks", c.imports)
            }
            .font(.callout)
            if !summary.skipped.isEmpty {
                Text("Already in the ledger, left as they are: \(Self.list(summary.skipped))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !summary.errors.isEmpty {
                Text("Could not be read: \(Self.list(summary.errors))")
                    .font(.caption).foregroundStyle(Color(nsColor: .systemOrange)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ count: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(count, format: .number).monospacedDigit()
        }
    }

    /// The first few, then how many more
    static func list(_ items: [String], limit: Int = 8) -> String {
        items.count <= limit ? items.joined(separator: ", ")
                             : items.prefix(limit).joined(separator: ", ") + " " + String(localized: "and \(items.count - limit) more")
    }

    private func run(dryRun: Bool) async {
        working = true
        error = nil
        do {
            let answer = try await ledger.importLegacy(path: path, dryRun: dryRun)
            if dryRun { preview = answer } else { result = answer }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}
