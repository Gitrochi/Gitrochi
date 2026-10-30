import SwiftUI

/// Local connection references and read-only Jenkins discovery share the flow workspace.
struct FlowConnectionsView: View {
    let repo: URL
    @ViewState private var showing = false
    @ViewState private var connections: [FlowConnection] = []

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connected services").font(.callout.weight(.semibold))
                Text("Docker, Compose, Jenkins and HTTP CI modules · GitHub Actions and GitLab runs")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Manage connections") { showing = true }.controlSize(.small)
        }
        .padding(12).background(Color(nsColor: .controlBackgroundColor))
        .task(id: repo) { connections = (try? await FlowEngine.connections(in: repo)) ?? [] }
        .sheet(isPresented: $showing) { FlowConnectionsSheet(repo: repo, initial: connections) }
    }
}

private struct FlowConnectionsSheet: View {
    let repo: URL
    let initial: [FlowConnection]
    @Environment(\.dismiss) private var dismiss
    @ViewState private var connections: [FlowConnection] = []
    @ViewState private var draft = FlowConnection.empty
    @ViewState private var selected: String?
    @ViewState private var busy = false
    @ViewState private var message: String?
    @ViewState private var error: String?
    @ViewState private var browse: FlowRemoteBrowse?
    @ViewState private var job = ""
    @ViewState private var run: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connected services", systemImage: "network").font(.title3.weight(.semibold))
            HSplitView {
                sidebar.frame(minWidth: 160, idealWidth: 180, maxWidth: 210)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        fields
                        actions
                        if let message { Text(message).font(.caption).foregroundStyle(.green).accessibilityAddTraits(.updatesFrequently) }
                        if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        if let browse { remoteBrowser(browse) }
                        Text("GitHub Actions and GitLab history, jobs and controls appear in the repository CI panel. Jenkins and other providers run through reviewed CI modules; HTTP CI endpoints are configured per module.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14)
                }.frame(minWidth: 430)
            }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Done") { dismiss() }.disabled(busy) }
        }
        .padding(20).frame(width: 900, height: 680)
        .interactiveDismissDisabled(busy)
        .task { connections = initial; await perform { connections = try await FlowEngine.connections(in: repo) } }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button("Add connection") { selected = nil; draft = .empty; browse = nil; error = nil; message = nil }.disabled(busy)
                ForEach(connections) { connection in
                    Button {
                        selected = connection.name; draft = connection; browse = nil; job = ""; run = nil; error = nil; message = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.name).font(.callout.weight(.semibold))
                            Text(connection.provider).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(selected == connection.name ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(busy)
                }
                Text("Docker and Compose use your local Docker context. Add their modules in the visual editor.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(.trailing, 12)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Connection name") { TextField("build-server", text: $draft.name).disabled(selected != nil) }
            Picker("Provider", selection: $draft.kind) {
                Text("GitHub Actions").tag("github"); Text("GitLab CI/CD").tag("gitlab"); Text("Jenkins").tag("jenkins")
                Text("HTTP CI").tag("http"); Text("Webhook").tag("webhook")
            }
            LabeledContent("Server address") { TextField("https://ci.example.com", text: $draft.url) }
            LabeledContent("User (optional)") { TextField("", text: Binding(get: { draft.user ?? "" }, set: { draft.user = $0.isEmpty ? nil : $0 })) }
            LabeledContent("Project (optional)") { TextField("owner/repository", text: Binding(get: { draft.project ?? "" }, set: { draft.project = $0.isEmpty ? nil : $0 })) }
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Credential reference") { TextField("env:CI_TOKEN", text: $draft.secret).autocorrectionDisabled() }
                Text("Use env:CI_TOKEN, app:account-id or gh:login. Existing saved tokens can use keystore.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Allowed jobs (comma separated)") {
                TextField("team/*", text: Binding(get: { draft.allow.joined(separator: ", ") }, set: {
                    draft.allow = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }))
            }
        }.textFieldStyle(.roundedBorder).disabled(busy)
    }

    private var actions: some View {
        HStack {
            Button("Save connection") { Task { await perform {
                try await FlowEngine.saveConnection(draft, in: repo)
                connections = try await FlowEngine.connections(in: repo); selected = draft.name
                message = String(localized: "Connection saved.")
            } } }.buttonStyle(.borderedProminent)
            Button("Test connection") { Task { await perform {
                guard let selected else { return }
                let result = try await FlowEngine.testConnection(selected, in: repo)
                guard result.ok else { throw FlowEngine.Failure(message: [result.message, result.action].compactMap { $0 }.joined(separator: "\n")) }
                message = String(localized: "Connection is available.")
            } } }.disabled(selected == nil)
            if selected != nil && draft.kind == "jenkins" {
                Button("Browse Jenkins builds") { loadBuilds("") }
            }
        }.controlSize(.small).disabled(busy)
    }

    private func remoteBrowser(_ result: FlowRemoteBrowse) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(job.isEmpty ? String(localized: "Jenkins jobs") : job).font(.callout.weight(.semibold))
                if let run { Text("#\(run)").font(.caption.monospaced()) }
                Spacer()
                if !job.isEmpty { Button("Back") { loadBuilds(run != nil ? job : job.split(separator: "/").dropLast().joined(separator: "/")) } }
            }
            ForEach(result.jobs) { item in
                Button { loadBuilds(item.path) } label: {
                    HStack { Image(systemName: item.folder ? "folder" : "shippingbox"); Text(item.name); Spacer(); Image(systemName: "chevron.right") }
                        .padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            ForEach(result.runs) { item in
                Button { loadBuilds(job, number: item.id) } label: {
                    HStack {
                        Text(item.title).fontWeight(.medium)
                        FlowStatusBadge(state: item.status == "success" ? "SUCCEEDED" : item.status == "canceled" ? "CANCELLED" : item.status.uppercased())
                        Spacer()
                        if item.startedAt > 0 { Text(Date(timeIntervalSince1970: item.startedAt / 1000), style: .relative).foregroundStyle(.secondary) }
                        Text("View logs").foregroundStyle(Color.accentColor)
                    }.font(.caption).padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let log = result.log {
                ScrollView([.horizontal, .vertical]) { Text(log.isEmpty ? String(localized: "No log output yet.") : log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                    .defaultScrollAnchor(.topLeading)
                    .frame(height: 190).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
            if result.truncated { Text("The log preview is truncated.").font(.caption).foregroundStyle(.secondary) }
            if result.jobs.isEmpty && result.runs.isEmpty && result.log == nil { Text("No builds or jobs found.").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10)).disabled(busy)
    }

    private func loadBuilds(_ path: String, number: String? = nil) {
        Task { await perform {
            guard let selected else { return }
            let result = try await FlowEngine.browseConnection(selected, job: path, run: number, in: repo)
            browse = result; job = path; run = number
        } }
    }

    @MainActor private func perform(_ work: () async throws -> Void) async {
        busy = true; error = nil; message = nil
        defer { busy = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }
}
