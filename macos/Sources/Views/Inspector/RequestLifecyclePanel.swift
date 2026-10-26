import SwiftUI

struct RequestLifecyclePanel: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    @ViewState private var editing = false
    @ViewState private var title = ""
    @ViewState private var description = ""
    @ViewState private var base = ""
    @ViewState private var reviewers = ""
    @ViewState private var method = "merge"
    private var state: CollaborationState { store.collaboration }
    private var disabled: Bool { state.lifecycleBusy || state.lifecycleLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Request management").font(.subheadline.weight(.semibold))
                Spacer()
                if disabled { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await store.loadRequestLifecycle(number) } }.disabled(disabled)
            }
            if let error = state.lifecycleError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let r = state.lifecycle, r.number == number {
                Text("State: \(r.state) · \(String(r.headSHA.prefix(12)))").font(.caption)
                Text(r.checks).font(.caption).foregroundStyle(.secondary)
                Text(r.policy).font(.caption2).foregroundStyle(.secondary)
                ForEach(r.blockers, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                actionButtons(r)
                if editing { editFields }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.25)))
        .controlSize(.small)
        .task(id: number) { editing = false; await store.loadRequestLifecycle(number); method = state.lifecycle?.methods.first ?? "merge" }
    }
    private func actionButtons(_ r: RequestLifecycle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if r.state == "open" {
                HStack {
                    Picker("Merge method", selection: $method) {
                        ForEach(r.methods, id: \.self) { value in Text(value == "merge" ? String(localized: "Merge") : value == "squash" ? String(localized: "Squash") : String(localized: "Rebase")).tag(value) }
                    }.labelsHidden()
                    Button("Merge…") { store.confirmMergeRequest(method: method) }.buttonStyle(.borderedProminent).disabled(disabled || !r.blockers.isEmpty)
                }
            }
            HStack {
                if r.canRebase { Button("Rebase on server…") { store.confirmRequestRebase() } }
                if r.state != "merged", r.canEdit { Button(r.state == "open" ? String(localized: "Close request…") : String(localized: "Reopen…")) { store.confirmRequestState(open: r.state != "open") } }
                if r.canEdit {
                    Button("Edit request…") {
                        title = r.title; description = r.body; base = r.base; reviewers = r.reviewers.joined(separator: ", "); editing.toggle()
                    }
                }
            }.disabled(disabled)
        }
    }
    private var editFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
            Text("Description").font(.caption)
            TextEditor(text: $description).frame(height: 90).font(.callout)
            TextField("Target branch", text: $base)
            Button("Save request") { Task { if await store.saveRequestMetadata(number, title: title, body: description, base: base) { editing = false } } }.disabled(title.trimmed.isEmpty || base.trimmed.isEmpty)
            TextField("Reviewers (comma-separated usernames)", text: $reviewers)
            Button("Save reviewers") { Task { _ = await store.saveRequestReviewers(number, names: reviewers.components(separatedBy: ",")) } }
        }.textFieldStyle(.roundedBorder).disabled(disabled)
    }
}
