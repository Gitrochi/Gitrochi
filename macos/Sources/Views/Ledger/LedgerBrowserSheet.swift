import SwiftUI
import AppKit

/// Registration is explicit; reading status and preparing this sheet never grants browser access.
struct LedgerBrowserSheet: View {
    let ledger: LedgerStore
    var hostURL = LedgerBrowserSetup.host
    var extensionURL = LedgerBrowserSetup.extensionFolder
    @Environment(\.dismiss) private var dismiss
    @ViewState private var extensionId = ""
    @ViewState private var status: LedgerBrowserStatus?
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var confirmInstall = false

    private var cleanId: String { extensionId.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ChatGPT browser extension").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only the conversation you select in the extension is synced. Other tabs and conversations are not read.")
                        .font(.callout)
                    Text("Completed ChatGPT questions and choices appear in Ledger. A draft accepted with Tab can be offered as an editable answer.")
                        .font(.callout)
                    Text("Answers are saved in Ledger. They are not sent back to ChatGPT.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("The native ChatGPT app and unaccepted predictions are not read.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Button("Open extension folder") { openExtension() }.disabled(busy)
                    Text("In Chrome at chrome://extensions, enable Developer mode and choose Load unpacked. Select this folder, then enter the extension ID here.")
                        .font(.callout)
                    TextField("Extension ID", text: $extensionId)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .disabled(busy).accessibilityLabel("Extension ID")
                    if !LedgerBrowserSetup.validExtensionId(cleanId) {
                        Text("Enter the 32-letter extension ID shown by Chrome.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Installation allows this extension to connect locally. Pair a conversation from its popup to start syncing.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Allow browser connection") { confirmInstall = true }
                        .prominentButton(true).disabled(busy || !LedgerBrowserSetup.validExtensionId(cleanId))
                    Divider()
                    if let status {
                        Label(status.installed ? String(localized: "Browser host installed") : String(localized: "Browser host not installed"),
                              symbol: status.installed ? "checkmark.circle" : "circle")
                            .font(.callout.weight(.medium))
                        DisclosureGroup("Connection details") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: status.hostName)
                                if let id = status.extensionId { Text(verbatim: id) }
                                if let path = status.hostPath { Text(verbatim: path) }
                                Text(verbatim: status.manifestPath)
                            }
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }.font(.system(size: 11))
                        if status.installed {
                            Button("Remove browser connection") { remove() }.disabled(busy)
                        }
                    }
                    if let error {
                        Text(error).font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Refresh") { refresh() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(minWidth: 420, idealWidth: 620, maxWidth: 680, minHeight: 500, idealHeight: 680, maxHeight: 760)
        .task { refresh() }
        .alert("Allow browser connection?", isPresented: $confirmInstall) {
            Button("Cancel", role: .cancel) {}
            Button("Allow") { install() }
        } message: {
            Text("This grants the selected extension access to Ledger project and session names and allows it to add questions and accepted Tab drafts.")
            Text(verbatim: cleanId)
        }
    }

    private func openExtension() {
        guard FileManager.default.fileExists(atPath: extensionURL.appendingPathComponent("manifest.json").path) else {
            error = String(localized: "The bundled browser extension is missing.")
            return
        }
        NSWorkspace.shared.open(extensionURL)
    }

    private func refresh() {
        perform { try await ledger.client.browserStatus() }
    }

    private func install() {
        guard LedgerBrowserSetup.validExtensionId(cleanId) else { return }
        guard FileManager.default.isExecutableFile(atPath: hostURL.path) else {
            error = String(localized: "The bundled browser host is missing. Rebuild or reinstall Gitrochi.")
            return
        }
        let id = cleanId
        perform { try await ledger.client.installBrowser(extensionId: id, hostPath: hostURL.path) }
    }

    private func remove() {
        perform { try await ledger.client.removeBrowser() }
    }

    private func perform(_ action: @escaping () async throws -> LedgerBrowserStatus) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                let result = try await action()
                status = result
                if extensionId.isEmpty, let id = result.extensionId { extensionId = id }
            } catch { self.error = String(localized: String.LocalizationValue(error.localizedDescription)) }
            busy = false
        }
    }
}
