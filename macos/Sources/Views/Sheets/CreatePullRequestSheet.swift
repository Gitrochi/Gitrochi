import SwiftUI
import AppKit

struct CreatePullRequestSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var bodyText = ""
    @ViewState private var base = ""
    @ViewState private var bases: [String] = []
    @ViewState private var draft = false
    @ViewState private var generating = false
    @ViewState private var previewing = false

    var body: some View {
        let provider = store.target?.provider ?? .github
        VStack(alignment: .leading, spacing: 12) {
            Text("New \(provider.requestName)").font(.title3.weight(.semibold))
            HStack {
                Text(store.headBranch ?? "").font(.system(.body, design: .monospaced))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("", selection: $base) {
                    ForEach(bases, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Picker("", selection: $previewing) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                if previewing {
                    ScrollView {
                        if bodyText.trimmed.isEmpty {
                            Text("Nothing to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownView(bodyText, target: store.target)
                        }
                    }
                    .padding(8)
                } else {
                    TextEditor(text: $bodyText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Toggle("Draft", isOn: $draft)
                Spacer()
                if generating { ProgressView().controlSize(.small) }
                Button { generate() } label: { Label("Write with \(AIStore.shared.short(for: .pullRequest))", systemImage: "sparkles") }
                    .disabled(generating || base.isEmpty)
            }
            if store.status.upstream == nil || store.status.ahead > 0 {
                Text("Pushes the current branch to \(store.target?.remote ?? String(localized: "Remotes")) before creating.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let t = title.trimmed, b = bodyText, target = base, d = draft
                    dismiss()
                    Task { await store.createPullRequest(title: t, body: b, base: target, draft: d) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty || base.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            bases = store.pullRequestBaseCandidates()
            if let b = await store.defaultBaseBranch() { base = b }
            if let saved = store.newPullRequestDraft, saved.branch == store.headBranch {
                title = saved.title; bodyText = saved.body; base = saved.base; draft = saved.draft
            }
            if title.isEmpty, let branch = store.headBranch {
                title = branch.split(separator: "/").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? branch
            }
        }
    }

    private func generate() {
        generating = true
        Task {
            if let d = await store.draftPullRequest(base: base) {
                title = d.title
                bodyText = d.body
            }
            generating = false
        }
    }
}
