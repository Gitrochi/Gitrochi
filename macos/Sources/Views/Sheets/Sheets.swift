import SwiftUI
import AppKit

private struct SheetFrame<Content: View>: View {
    let title: String
    let confirmTitle: String
    let canConfirm: Bool
    let onConfirm: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.title3.weight(.semibold)).padding([.top, .horizontal], 20)
            Form { content }
                .formStyle(.grouped)
                .frame(maxHeight: 560)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
    }
}

struct NewBranchSheet: View {
    @Environment(RepoStore.self) private var store
    let start: String
    let label: String
    @ViewState private var name = ""
    @ViewState private var checkout = true

    var body: some View {
        SheetFrame(title: String(localized: "New branch"), confirmTitle: String(localized: "Create"), canConfirm: valid,
                   onConfirm: { Task { await store.createBranch(name.trimmed, at: start, checkout: checkout) } }) {
            TextField("Name", text: $name, prompt: Text("feature/new-feature"))
            LabeledContent("Start point", value: label)
            Toggle("Check out after creating", isOn: $checkout)
        }
    }

    private var valid: Bool {
        let n = name.trimmed
        return !n.isEmpty && !n.contains(" ") && !n.hasPrefix("-") && !n.contains("..")
    }
}

struct TagSheet: View {
    @Environment(RepoStore.self) private var store
    let sha: String
    @ViewState private var name = ""
    @ViewState private var message = ""

    var body: some View {
        SheetFrame(title: String(localized: "Create tag"), confirmTitle: String(localized: "Create"), canConfirm: !name.trimmed.isEmpty && !name.contains(" "),
                   onConfirm: { Task { await store.createTag(name.trimmed, message: message, at: sha) } }) {
            TextField("Name", text: $name, prompt: Text("v1.0.0"))
            TextField("Message", text: $message, prompt: Text("Leave empty for a lightweight tag"))
            LabeledContent("Commit", value: String(sha.prefix(10)))
        }
    }
}

struct StashSheet: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var message = ""
    @ViewState private var includeUntracked = true

    var body: some View {
        SheetFrame(title: String(localized: "Stash changes"), confirmTitle: "Stash", canConfirm: true,
                   onConfirm: { Task { await store.stash(message: message, includeUntracked: includeUntracked) } }) {
            TextField("Message", text: $message, prompt: Text("Optional"))
            Toggle("Include untracked new files", isOn: $includeUntracked)
        }
    }
}

struct CloneSheet: View {
    var initialURL = ""
    @Environment(RepoStore.self) private var store
    private let accounts = AccountStore.shared
    @ViewState private var accountID: String?
    @ViewState private var repos: [RemoteRepo] = []
    @ViewState private var reposError: String?
    @ViewState private var loadingRepos = false
    @ViewState private var query = ""
    @ViewState private var remote = ""
    @ViewState private var parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    @ViewState private var folder = ""
    @ViewState private var folderEdited = false

    var body: some View {
        SheetFrame(title: String(localized: "Clone repository"), confirmTitle: String(localized: "Clone"),
                   canConfirm: !remote.trimmed.isEmpty && !folder.trimmed.isEmpty,
                   onConfirm: { Task { await store.clone(remote: remote.trimmed, parent: parent, folder: folder.trimmed) } }) {
            if !accounts.accounts.isEmpty {
                Section("My repositories") {
                    Picker("Accounts", selection: $accountID) {
                        ForEach(accounts.accounts) { a in
                            Text("\(a.provider == .github ? "GitHub" : a.host) · @\(a.username)").tag(Optional(a.id))
                        }
                    }
                    TextField("Search", text: $query)
                    List(filteredRepos, selection: Binding(get: { repos.first { $0.cloneURL == remote }?.id },
                                                           set: { id in if let r = repos.first(where: { $0.id == id }) { remote = r.cloneURL } })) { r in
                        HStack(spacing: 6) {
                            Image(systemName: r.isPrivate ? "lock" : "globe").foregroundStyle(.secondary).frame(width: 14)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(r.fullName).lineLimit(1)
                                if let d = r.summary, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .tag(r.id)
                    }
                    .frame(height: 170)
                    .overlay {
                        if loadingRepos { ProgressView() }
                        else if let reposError { Text(reposError).font(.caption).foregroundStyle(.red).padding() }
                    }
                }
                .task(id: accountID) { await loadRepos() }
                .onAppear { if accountID == nil { accountID = accounts.accounts.first?.id } }
            }
            TextField("URL", text: $remote, prompt: Text("https://github.com/user/repo.git"))
                .onAppear { if remote.isEmpty { remote = initialURL; folder = Self.guessName(initialURL) } }
                .onChange(of: remote) { _, v in
                    if !folderEdited { folder = Self.guessName(v) }
                }
            LabeledContent("Location") {
                HStack {
                    Text(parent.path).lineLimit(1).truncationMode(.head)
                    Button("Change…") { choose() }
                }
            }
            TextField("Folder name", text: Binding(get: { folder }, set: { folder = $0; folderEdited = true }))
        }
    }

    private var filteredRepos: [RemoteRepo] {
        let q = query.trimmed.lowercased()
        return q.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(q) }
    }

    private func loadRepos() async {
        guard let a = accounts.accounts.first(where: { $0.id == accountID }), let token = accounts.token(for: a) else { return }
        loadingRepos = true
        reposError = nil
        do {
            repos = try await Hosting.repositories(a.provider, token: token, apiBase: a.apiBase)
        } catch {
            repos = []
            reposError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loadingRepos = false
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = parent
        if p.runModal() == .OK, let u = p.url { parent = u }
    }

    /// https://host/a/b.git, git@host:a/b.git → "b"
    static func guessName(_ url: String) -> String {
        let last = url.trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }
}

/// 「이 브랜치에서 바뀐 의존」의 기준 고르기(gitch graph diff). 고른 브랜치 · 태그와 이 브랜치가 갈라진 곳과 비교한다.
struct GraphDiffSheet: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var relation = Gitch.GraphRelation.files
    /// 빈 글자면 gitch 가 고른다(기본 브랜치와 갈라진 곳)
    @ViewState private var base = ""

    var body: some View {
        // 다른 gitch graph 페이지를 만드는 중이면 openGraphDiff 가 아무것도 하지 않으므로 끈다
        SheetFrame(title: String(localized: "Compare dependencies"), confirmTitle: String(localized: "Compare"), canConfirm: store.graphJob == nil,
                   onConfirm: {
                       let r = relation, b = base
                       Task { await store.openGraphDiff(r, base: b.isEmpty ? nil : b) }
                   }) {
            Section {
                Picker("Structure graph", selection: $relation) {
                    ForEach(Gitch.GraphRelation.compared) { Text($0.title).tag($0) }
                }
                // Windows(<optgroup>)와 같게: 로컬 브랜치 · 원격 · 태그 묶음에 제목을 달고, 빈 묶음은 숨긴다
                let local = store.localBranches.filter { !$0.isCurrent }
                // origin/HEAD 는 기본 브랜치를 가리킬 뿐이라 뺀다
                let remote = store.remoteBranches.filter { !$0.shortName.hasSuffix("HEAD") }
                Picker("Compare with", selection: $base) {
                    Text("Default branch (where this branch split off)").tag("")
                    if !local.isEmpty {
                        Section("Local branches") {
                            ForEach(local) { b in Text(b.name).tag(b.name) }
                        }
                    }
                    if !remote.isEmpty {
                        Section("Remotes") {
                            ForEach(remote) { b in Text(b.name).tag(b.name) }
                        }
                    }
                    if !store.tags.isEmpty {
                        Section("Tags") {
                            ForEach(store.tags) { t in Text(t.name).tag(t.name) }
                        }
                    }
                }
            } footer: {
                Text("Gitrochi compares with where this branch split off from the branch or tag you pick, so only this branch's changes show. Uncommitted changes to tracked files are included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
