import SwiftUI
import AppKit

/// Registration makes the tools available; agents still need to report. The probe checks Gitrochi's Ledger and its
/// bundled MCP command, never Claude Code's configuration. (Windows: features/connect-ledger-mcp/LedgerConnectSheet)
struct LedgerConnectSheet: View {
    let ledger: LedgerStore
    /// Where the app bundles the ledger's command-line tool
    var binaryPath = LedgerCommandLine.bundled.path
    @Environment(\.dismiss) private var dismiss
    @ViewState private var notice = ""
    @ViewState private var error: String?
    @ViewState private var testing = false

    private var command: String { "claude mcp add --scope user gitrochi-ledger -- \"\(binaryPath)\" mcp" }
    private var config: String {
        let entry: [String: Any] = ["command": binaryPath, "args": ["mcp"]]
        let values: [String: Any] = ["mcpServers": ["gitrochi-ledger": entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    // Windows: LedgerConnectSheet.tsx. This is an instruction to copy, kept in English like a project's CLAUDE.md.
    private let reportingInstruction = "Use ledger_report to send a start report for this conversation and its current work. Include the project and a short title. Send progress, question and done reports as the work changes."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Claude Code").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Register the Ledger tools with Claude Code by running this command in a terminal.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    copyBlock(command, label: "Command for Claude Code", copyLabel: "Copy command")
                    Text("Registration makes the tools available. It does not import existing conversations or make agents report automatically.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Start or restart a Claude Code conversation, then ask it to call ledger_report with a start report for its current work.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    copyBlock(reportingInstruction, label: "Reporting instruction", copyLabel: "Copy reporting instruction")
                    DisclosureGroup("Other MCP clients: add this entry to their MCP settings.") {
                        copyBlock(config, label: "MCP settings entry", copyLabel: "Copy MCP settings").padding(.top, 6)
                    }
                    .font(.system(size: 11))
                    Text("To track new Claude Code agents launched from Gitrochi automatically, turn on Settings > Ledger > Track agents I start. It is off by default.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Nothing is written to Claude Code's settings by Gitrochi.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !notice.isEmpty {
                        Text(notice).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Checks this app's Ledger, not Claude Code's MCP configuration.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Test Ledger") { test() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 650)
    }

    private func copyBlock(_ text: String, label: String, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(label)).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(LocalizedStringKey(copyLabel)) { copy(text) }.font(.system(size: 11))
            }
            Text(verbatim: text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
                .accessibilityLabel(LocalizedStringKey(label))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = String(localized: "Copied")
    }

    private func test() {
        testing = true
        error = nil
        notice = ""
        Task {
            do {
                let tools = try await LedgerCommandLine.tools(binary: URL(fileURLWithPath: binaryPath))
                let info = try await ledger.info()
                notice = String(localized: "The Ledger responds.") + "\n"
                    + String(localized: "Connecting tools alone creates no session. Send a first report to see this conversation here.") + "\n"
                    + String(localized: "Find progress in Board and Streams. Inbox only shows questions, reviews and decisions that need you.") + "\n"
                    + String(localized: "The ledger command answers with its tools: \(tools.joined(separator: ", ")).") + "\n"
                    + String(localized: "The ledger answers: schema \(info.schemaVersion), change \(info.rev), database \(info.dbPath).")
                    + (info.enabled ? "" : "\n" + String(localized: "The ledger is turned off (GITROCHI_LEDGER=0)."))
            } catch {
                self.error = error.localizedDescription
            }
            testing = false
        }
    }
}
