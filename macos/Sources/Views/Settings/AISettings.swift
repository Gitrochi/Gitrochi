import SwiftUI
import AppKit

struct AISettings: View {
    private let ai = AIStore.shared
    private let tools = ToolStore.shared
    @ViewState private var selected: AIProvider = AIStore.shared.provider
    @ViewState private var key = ""
    @ViewState private var models: [String] = []
    @ViewState private var listing = false
    @ViewState private var testing = false
    @ViewState private var result: String?
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section("AI for commit messages, commit explanations and PR descriptions") {
                Picker("", selection: $selected) {
                    ForEach(AIProvider.allCases) { p in
                        HStack {
                            Text(p.title)
                            if ai.provider == p {
                                Text("In use").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            } else if ai.problem(p) == nil {
                                Text("Ready").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag(p)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section {
                if let tool = selected.tool {
                    LabeledContent("Executable") {
                        if let p = tools.path(tool) {
                            Text(p).lineLimit(1).truncationMode(.head)
                        } else {
                            Text("Not found — locate it in the Tools tab").foregroundStyle(.red)
                        }
                    }
                }
                if selected == .compatible {
                    TextField("Server address", text: Binding(get: { ai.baseURL }, set: { ai.setBaseURL($0) }),
                              prompt: Text("http://localhost:11434/v1"))
                }
                if !selected.isCLI {
                    if ai.hasKey[selected.rawValue] == true {
                        HStack {
                            Label("API key saved", symbol: "key.fill")
                            Spacer()
                            Button("Delete") { ai.setKey(selected, "") }
                        }
                    } else {
                        HStack {
                            SecureField("API key", text: $key, prompt: Text(selected.keyHint))
                            Button("Save") { ai.setKey(selected, key); key = "" }
                                .disabled(key.trimmed.isEmpty)
                        }
                    }
                }
                HStack {
                    TextField("Model", text: Binding(get: { ai.model(selected) }, set: { ai.setModel(selected, $0) }),
                              prompt: Text(selected.modelHint))
                    if !models.isEmpty {
                        Menu("List") {
                            ForEach(models, id: \.self) { m in Button(m) { ai.setModel(selected, m) } }
                        }
                        .fixedSize()
                    }
                    if !selected.isCLI {
                        Button { fetchModels() } label: {
                            if listing { ProgressView().controlSize(.small) } else { Text("Load list") }
                        }
                        .disabled(listing)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text(selected.note).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let u = selected.keyURL.flatMap(URL.init(string:)) { Link("Create key", destination: u) }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Test connection") { test() }.disabled(testing)
                    if ai.provider != selected {
                        Button("Use this AI") { ai.provider = selected }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let result { Text(result).font(.caption).lineLimit(3) }
            } header: {
                Text(selected.title)
            } footer: {
                Text("Your changes (diff) are sent to the chosen AI. Keys are stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: selected) { _, _ in
            models = []; result = nil; error = nil; key = ""
        }
    }

    private func fetchModels() {
        listing = true
        error = nil
        let p = selected
        Task {
            do {
                models = try await ai.listModels(p)
                if models.isEmpty { error = String(localized: "No models were returned.") }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            listing = false
        }
    }

    private func test() {
        testing = true
        result = nil
        let p = selected
        Task {
            do {
                let r = try await ai.complete(system: "Reply with exactly: OK", prompt: "ping", effort: "low", using: p)
                result = String(localized: "✅ Response: \(r.prefix(40))")
            } catch {
                result = "❌ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            testing = false
        }
    }
}
