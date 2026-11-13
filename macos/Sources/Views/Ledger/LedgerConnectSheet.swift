import SwiftUI
import AppKit

/// Local agents can send MCP reports and install passive activity hooks independently. The probe checks Gitrochi's
/// Ledger and its bundled MCP command, never client configuration or hook trust. (Windows: features/connect-ledger-mcp)
struct LedgerConnectSheet: View {
    let ledger: LedgerStore
    /// Where the app bundles the ledger's command-line tool
    var binaryPath = LedgerCommandLine.bundled.path
    /// Opens the browser extension's setup from its Connections row
    var openBrowser: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @ViewState private var notice = ""
    @ViewState private var error: String?
    @ViewState private var testing = false
    @ViewState private var client: LedgerSetupClient = .claude
    // Windows: LedgerConnectSheet.tsx. This is an instruction to copy, kept in English like a project's CLAUDE.md.
    private let reportingInstruction = "Use ledger_report to send a start report for this conversation and its current work. Include the project and a short title. Send progress, question and done reports as the work changes."

    var body: some View {
        SharedSheet(title: String(localized: "Connect agents"),
                    context: String(localized: "Local agents report their work to this app's Ledger."), width: 680,
                    cancelTitle: String(localized: "Close"), cancel: { dismiss() }) {
            Button("Test Ledger") { test() }.disabled(testing)
            if testing { ProgressView().controlSize(.small) }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connections").font(.system(size: 13, weight: .semibold))
                    LedgerConnectionsSection(ledger: ledger, openBrowser: openBrowser)
                    Divider()
                    Picker("Agent", selection: $client) {
                        ForEach(LedgerSetupClient.allCases) { client in Text(verbatim: client.title).tag(client) }
                    }
                    .pickerStyle(.menu).frame(maxWidth: 260)
                    if client == .codex {
                        Text("Codex CLI and local Desktop tasks share this setup. Cloud-orchestrated tasks do not run these hooks; they appear only when the agent sends Ledger reports.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Ledger reports").font(.system(size: 13, weight: .semibold))
                    Text("Register the Ledger tools by running this command in a terminal.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    copyBlock(client.registration(binary: binaryPath), label: "MCP registration command", copyLabel: "Copy command")
                    Text("Registration makes the tools available. It does not import existing conversations or make agents report automatically.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Start a new conversation, then ask the agent to send a start report with ledger_report.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    copyBlock(reportingInstruction, label: "Reporting instruction", copyLabel: "Copy reporting instruction")
                    DisclosureGroup("MCP settings entry") {
                        copyBlock(client.configuration(binary: binaryPath), label: "MCP settings entry", copyLabel: "Copy MCP settings").padding(.top, 6)
                    }
                    .font(.system(size: 11))
                    Text("Automatic activity").font(.system(size: 13, weight: .semibold))
                    Text("Install activity hooks for this agent. Existing hooks are kept. MCP registration is separate.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    copyBlock(client.install(binary: binaryPath), label: "Activity setup command", copyLabel: "Copy command")
                    Text("Activity records do not mark work complete. Task details still come from the agent's reports.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if client == .codex {
                        Text("After installing, open /hooks in Codex and review and trust the Ledger hooks. Installation does not trust them.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Check or remove automatic activity") {
                        VStack(alignment: .leading, spacing: 6) {
                            copyBlock(client.status(binary: binaryPath), label: "Status", copyLabel: "Copy command")
                            Text("Setup status checks configuration only, not whether hooks are trusted or running.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            copyBlock(client.remove(binary: binaryPath), label: "Remove", copyLabel: "Copy command")
                        }.padding(.top, 6)
                    }.font(.system(size: 11))
                    Text("To track new Claude Code agents launched from Gitrochi automatically, turn on Settings > Ledger > Track agents I start. It is off by default.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Set up, Repair and Remove change only Gitrochi's own entries in that client's hook settings, after a backup, and ask the client itself to add or remove the gitrochi-ledger MCP server.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Checks this app's Ledger, not agent configuration or hook trust.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !notice.isEmpty {
                        Text(notice).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
        .frame(height: 650)
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
