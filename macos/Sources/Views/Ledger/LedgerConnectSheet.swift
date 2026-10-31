import SwiftUI
import AppKit

/// Connect Claude Code: the `claude mcp add` command for the bundled ledger binary, to copy and run in a terminal, and a
/// connection test (the bundled binary's MCP handshake, and `info`). It never edits a client's settings; agents Gitrochi
/// starts need none of this. (Windows: features/connect-ledger-mcp/ui/LedgerConnectSheet.tsx)
struct LedgerConnectSheet: View {
    let ledger: LedgerStore
    /// Where the app bundles the ledger's command-line tool
    var binaryPath = LedgerCommandLine.bundled.path
    @Environment(\.dismiss) private var dismiss
    @ViewState private var notice = ""
    @ViewState private var error: String?
    @ViewState private var testing = false

    private var command: String { "claude mcp add --scope user gitrochi-ledger -- \"\(binaryPath)\" mcp" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Claude Code").font(.title3.bold())
            Text("Run this once in a terminal. Claude Code then reports its sessions to the ledger: what they started from, questions, results.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .accessibilityLabel("Command")
            Text("Agents you start from Gitrochi are tracked without this. Nothing is written to Claude Code's settings by Gitrochi.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !notice.isEmpty { Text(notice).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed)).textSelection(.enabled) }
            HStack {
                Button("Test connection") { test() }.disabled(testing)
                    .help("Ask the ledger for its version and database")
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    notice = String(localized: "Copied")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func test() {
        testing = true
        error = nil
        Task {
            do {
                let tools = try await LedgerCommandLine.tools(binary: URL(fileURLWithPath: binaryPath))
                let info = try await ledger.info()
                notice = String(localized: "The ledger command answers with its tools: \(tools.joined(separator: ", ")).") + "\n"
                    + String(localized: "The ledger answers: schema \(info.schemaVersion), change \(info.rev), database \(info.dbPath).")
                    + (info.enabled ? "" : "\n" + String(localized: "The ledger is turned off (GITROCHI_LEDGER=0)."))
            } catch {
                self.error = error.localizedDescription
            }
            testing = false
        }
    }
}
