import SwiftUI
import AppKit

/// 실행 파일 위치: 자동으로 못 찾으면 직접 불러온다.
struct ToolsSettings: View {
    private let tools = ToolStore.shared
    @ViewState private var error: String?
    @ViewState private var busy: ToolID?
    @AppStorage(AgentCenter.Place.key) private var agentPlace = AgentCenter.Place.app

    var body: some View {
        Form {
            Section {
                Text("Install locations differ from person to person. If a tool isn't found automatically, use **Locate** to choose the executable yourself. The chosen path is saved and used next time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Run coding agents in", selection: $agentPlace) {
                    Text("Gitrochi terminal").tag(AgentCenter.Place.app)
                    Text("Terminal app").tag(AgentCenter.Place.terminal)
                }
            } footer: {
                Text("In Gitrochi, a session runs in a new tab of the terminal below the graph and ends when you quit the app. Choose Terminal app to keep sessions running without Gitrochi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ToolID.allCases) { id in
                let st = tools.state(id)
                Section {
                    HStack {
                        Text(st.path ?? "—")
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.head)
                            .textSelection(.enabled)
                        Spacer()
                        if busy == id { ProgressView().controlSize(.small) }
                        Button("Locate…") { choose(id) }
                        if st.source == .custom {
                            Button("Auto") { tools.resetToAuto(id) }
                                .help("Clears the path you chose and finds it automatically again")
                        }
                        if st.source == .none, let u = id.install.flatMap(URL.init(string:)) {
                            Link("Install", destination: u)
                        }
                    }
                    if let v = st.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(id.title)
                        if id == .git { Text("Required").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        switch st.source {
                        case .custom: Text("Set manually").font(.caption).foregroundStyle(Color.accentColor)
                        case .auto: Text("Found automatically").font(.caption).foregroundStyle(.secondary)
                        case .none: Text("None").font(.caption).foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text(id.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private func choose(_ id: ToolID) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.treatsFilePackagesAsDirectories = true
        p.showsHiddenFiles = true
        p.prompt = String(localized: "Locate")
        p.message = String(localized: "Choose the \(id.title) executable")
        if let cur = tools.path(id) { p.directoryURL = URL(fileURLWithPath: (cur as NSString).deletingLastPathComponent) }
        guard p.runModal() == .OK, let u = p.url else { return }
        error = nil
        busy = id
        Task {
            do { try await tools.setCustom(id, path: u.path) } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = nil
        }
    }
}
