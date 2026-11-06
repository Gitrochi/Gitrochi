import SwiftUI
import AppKit

/// Claude Code, Codex and the ChatGPT browser extension as equals: whether each one's data reaches this Ledger, and the
/// action that fixes it. Set up and Repair install hooks that run the stable ledger command and have the client register
/// its MCP server, and the command stays there to copy when it cannot. Shown in the Connect agents sheet and Settings › Ledger.
/// (Windows: features/connect-ledger-mcp/ui/LedgerConnections.tsx)
struct LedgerConnectionsSection: View {
    let ledger: LedgerStore
    /// Opens the browser extension's setup, which asks before it allows a connection
    let openBrowser: () -> Void
    @ViewState private var statuses: [LedgerSetupClient: LedgerIntegrationStatus] = [:]
    @ViewState private var browser: LedgerBrowserStatus?
    @ViewState private var stable: LedgerStableCommand?
    @ViewState private var errors: [String: String] = [:]
    @ViewState private var working: String?
    @ViewState private var notice: String?
    @ViewState private var loaded = false

    private static let browserKey = "browser"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LedgerSetupClient.allCases) { client in
                agentRow(client)
                Divider()
            }
            browserRow
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    // MARK: - Rows

    private func agentRow(_ client: LedgerSetupClient) -> some View {
        let status = statuses[client]
        let look = status.map { LedgerConnectionLook.agent($0, stableExists: stable?.exists == true) }
        let details = [status?.hookCommand?.path, status?.mcp.command?.path].compactMap { $0 }
        return row(key: client.rawValue, title: client.title, symbol: client == .claude ? "terminal" : "chevron.left.forwardslash.chevron.right",
                   look: look, help: Array(Set(details)).sorted().joined(separator: "\n")) { action in
            perform(action, client: client, status: status, look: look)
        }
    }

    private var browserRow: some View {
        let look = browser.map { LedgerConnectionLook.browser(installed: $0.installed, hostExists: $0.hostExists, lastDataAt: $0.lastDataAt) }
        return row(key: Self.browserKey, title: String(localized: "ChatGPT browser extension"), symbol: "globe", look: look,
                   help: browser?.hostPath ?? "", dialogs: true) { action in
            switch action {
            case .setUp, .repair: openBrowser()
            case .remove: run(Self.browserKey) { browser = try await ledger.client.removeBrowser() }
            case .copy: break
            }
        }
    }

    private func row(key: String, title: String, symbol: String, look: LedgerConnectionLook?, help: String, dialogs: Bool = false,
                     perform: @escaping (LedgerConnectionLook.Action) -> Void) -> some View {
        let summary = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let look { pill(look) } else if !loaded { ProgressView().controlSize(.mini) }
            }
            if let error = errors[key] {
                Text(error).font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.failed.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let look {
                Text(explanation(look, title: title)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let buttons = HStack(spacing: 6) {
            ForEach(look?.actions ?? [], id: \.self) { action in
                Button(actionTitle(action, dialogs: dialogs)) { perform(action) }
                    .disabled(working != nil)
            }
            if working == key { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                icon(symbol)
                summary
                Spacer(minLength: 12)
                buttons.fixedSize()
            }
            HStack(alignment: .top, spacing: 10) {
                icon(symbol)
                VStack(alignment: .leading, spacing: 6) { summary; buttons }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 9)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
            .accessibilityHidden(true)
    }

    @ViewBuilder private func pill(_ look: LedgerConnectionLook) -> some View {
        switch look.state {
        case .notSetUp: StatusPill(title: String(localized: "Not set up"), symbol: "circle.dashed", tone: .neutral)
        case .connected:
            StatusPill(title: look.lastDataAt.map { String(localized: "Connected · last data \(LedgerTime.short($0))") } ?? String(localized: "Connected"),
                       symbol: "checkmark.circle", tone: .passed)
        case .noData: StatusPill(title: String(localized: "Connected · no data yet"), symbol: "clock", tone: .info)
        case .repair: StatusPill(title: String(localized: "Needs repair"), symbol: "wrench.and.screwdriver", tone: .waiting)
        case .missing: StatusPill(title: String(localized: "Command missing"), symbol: "xmark.octagon", tone: .failed)
        }
    }

    private func explanation(_ look: LedgerConnectionLook, title: String) -> String {
        let text = String(localized: String.LocalizationValue(look.explanation))
        return text.replacingOccurrences(of: "%@", with: title)
    }

    private func actionTitle(_ action: LedgerConnectionLook.Action, dialogs: Bool) -> LocalizedStringKey {
        switch action {
        case .setUp: dialogs ? "Set up…" : "Set up"
        case .repair: dialogs ? "Repair…" : "Repair"
        case .remove: "Remove"
        case .copy: "Copy MCP command"
        }
    }

    // MARK: - Actions

    private func perform(_ action: LedgerConnectionLook.Action, client: LedgerSetupClient, status: LedgerIntegrationStatus?,
                         look: LedgerConnectionLook?) {
        let bundled = LedgerCommandLine.bundled.path
        let hooks = (status?.ownedHookCount ?? 0) > 0
        let program = ToolStore.shared.path(client == .claude ? .claude : .codex)
        switch action {
        case .setUp, .repair:
            run(client.rawValue) {
                // Repairing only the MCP entry adds no hooks a person did not choose
                if action == .setUp || hooks || look?.repairsMcp != true {
                    statuses[client] = try await ledger.client.installIntegration(client, bundled: bundled)
                }
                do {
                    statuses[client] = try await ledger.client.registerMcp(client, bundled: bundled, program: program)
                } catch {
                    throw LedgerFailure(code: "MCP", message: String(localized: "The Ledger tools were not registered: \(error.localizedDescription) Copy the MCP command and run it."))
                }
            }
        case .remove:
            run(client.rawValue) {
                if hooks { statuses[client] = try await ledger.client.removeIntegration(client) }
                if status?.mcp.registered == true { statuses[client] = try await ledger.client.removeMcp(client, program: program) }
            }
        case .copy:
            copyMcp(client, registered: status?.mcp.registered ?? false)
        }
    }

    private func copyMcp(_ client: LedgerSetupClient, registered: Bool) {
        guard let path = stable?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(client.mcpCommand(stable: path, registered: registered), forType: .string)
        notice = String(localized: "Copied. Run it in a terminal to register the Ledger tools.")
    }

    /// One action at a time; afterwards everything is read again, since a repair can change more than its own row
    private func run(_ key: String, _ action: @escaping () async throws -> Void) {
        guard working == nil else { return }
        working = key
        errors[key] = nil
        notice = nil
        Task {
            do { try await action() } catch { errors[key] = error.localizedDescription }
            working = nil
            await load(keepErrors: true)
        }
    }

    private func load(keepErrors: Bool = false) async {
        let client = ledger.client
        if !keepErrors { errors = [:] }
        stable = try? await client.stableCommand(bundled: LedgerCommandLine.bundled.path)
        for setup in LedgerSetupClient.allCases {
            do { statuses[setup] = try await client.integrationStatus(setup) } catch {
                if errors[setup.rawValue] == nil { errors[setup.rawValue] = error.localizedDescription }
            }
        }
        do { browser = try await client.browserStatus() } catch {
            if errors[Self.browserKey] == nil { errors[Self.browserKey] = error.localizedDescription }
        }
        loaded = true
    }
}
