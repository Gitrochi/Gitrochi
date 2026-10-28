import SwiftUI

struct TeamHubPanel: View {
    let store: RepoStore
    @ViewState private var endpoint = UserDefaults.standard.string(forKey: "teamHubEndpoint") ?? ""
    @ViewState private var repo = ""
    @ViewState private var token = ""
    @ViewState private var snapshot: TeamHub.Snapshot?
    @ViewState private var error = ""
    @ViewState private var busy = false
    @ViewState private var connected = false
    @ViewState private var generation = 0
    @ViewState private var connection: (endpoint: String, repo: String, token: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Team overlap evidence").font(.headline)
            Grid(alignment: .leading) {
                GridRow { Text("Hub URL"); TextField("https://hub.example.com", text: $endpoint).accessibilityLabel("Hub URL") }
                GridRow { Text("Repository key"); TextField("example.com/team/app", text: $repo).accessibilityLabel("Repository key") }
                GridRow { Text("Hub token"); SecureField("Hub token", text: $token) }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Connect and read") { Task { await connect() } }.disabled(endpoint.isEmpty || repo.isEmpty || busy)
                Button("Refresh") { Task { await refresh() } }.disabled(connection == nil || busy)
                if busy { ProgressView().controlSize(.small) }
                Text(connected ? String(localized: "Connected · refreshes every 30 seconds") : String(localized: "Disconnected")).font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot {
                Text("Observed at \(snapshot.observedAt)").font(.caption).foregroundStyle(.secondary)
                Text("\(snapshot.presence.count) active participants").font(.caption)
                ForEach(snapshot.overlaps) { overlap in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(overlap.a.member + " · " + overlap.b.member).fontWeight(.medium)
                        Text(overlap.kind == "same-file" ? String(localized: "Same-file observation") : String(localized: "Related-file inference")).font(.caption)
                        Text(overlap.a.branch + " ↔ " + overlap.b.branch).font(.caption).foregroundStyle(.secondary)
                        ForEach(overlap.paths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        Button("View overlap in graph") { Task { await store.openWorkGraphForPaths(overlap.paths) } }.disabled(!connected || store.graphJob != nil)
                    }.accessibilityElement(children: .combine)
                }
                if snapshot.overlaps.isEmpty { Text("No overlaps were reported in this snapshot.").foregroundStyle(.secondary) }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("This view reads configured hub snapshots. It does not publish your files or start a monitor.").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: endpoint) { _, _ in invalidate() }
        .onChange(of: repo) { _, _ in invalidate() }
        .onChange(of: token) { _, _ in invalidate() }
        .onDisappear { generation += 1; connection = nil }
        .task {
            if repo.isEmpty, let remote = store.remoteURLs["origin"] ?? store.remoteURLs.values.first { repo = (try? TeamHub.repoKey(remote)) ?? "" }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled, connection != nil { await refresh() }
            }
        }
    }

    private func invalidate() { generation += 1; connection = nil; snapshot = nil; connected = false; busy = false; error = "" }

    private func connect() async {
        let request = generation
        do {
            let url = try TeamHub.endpoint(endpoint).absoluteString
            let key = try TeamHub.repoKey(repo)
            let secretKey = "teamHub:" + url
            let credential: String
            if token.isEmpty { credential = await Keychain.get(secretKey) ?? "" }
            else {
                guard await Keychain.set(token, for: secretKey) else { throw TeamHub.Failure(message: String(localized: "Could not save the team hub credential.")) }
                credential = token
            }
            guard !credential.isEmpty else { throw TeamHub.Failure(message: String(localized: "Enter a team hub token. It is stored only in the system credential store.")) }
            guard request == generation else { return }
            UserDefaults.standard.set(url, forKey: "teamHubEndpoint")
            connection = (url, key, credential)
            await refresh()
        } catch { self.error = store.describe(error) }
    }

    private func refresh() async {
        guard let connection else { return }
        generation += 1
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
        do {
            let result = try await TeamHub.read(endpoint: connection.endpoint, repo: connection.repo, token: connection.token)
            guard request == generation, !Task.isCancelled else { return }
            snapshot = result; connected = true; error = ""
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            connected = false; self.error = String(localized: "The team hub is disconnected. Previously observed data may be stale.")
        }
    }
}
