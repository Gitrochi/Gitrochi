import SwiftUI

/// The side cards of a request's conversation: Merge, Reviewers and, while editing, the request's own fields.
/// Windows: RequestLifecyclePanel.tsx.
struct RequestLifecyclePanel: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    /// Who approved or asked for changes, once the review is loaded
    var review: ReviewState?
    var headSHA: String?
    /// "Edit request…" in the More menu opens the fields here
    @Binding var editing: Bool
    @ViewState private var title = ""
    @ViewState private var description = ""
    @ViewState private var base = ""
    @ViewState private var reviewers = ""
    @ViewState private var requesting = false
    @ViewState private var method = "merge"
    private var state: CollaborationState { store.collaboration }
    private var disabled: Bool { state.lifecycleBusy || state.lifecycleLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let request = state.lifecycle.flatMap { $0.number == number ? $0 : nil }
            merge(request)
            reviewerCard(request)
            if editing, let request, request.canEdit { editCard }
        }
        .task(id: "\(state.contextID):\(number)") { editing = false; requesting = false; await store.loadRequestLifecycle(number); method = state.lifecycle?.methods.first ?? "merge" }
        .onChange(of: editing) { _, on in
            guard on, let r = state.lifecycle, r.number == number else { return }
            title = r.title; description = r.body; base = r.base
        }
    }

    // MARK: Merge

    private func merge(_ request: RequestLifecycle?) -> some View {
        PullRequestCard(title: "Merge") {
            if let request {
                row(checksSymbol, checksTone) { Text(verbatim: request.checks) }
                if let review {
                    let met = !review.approvedBy.isEmpty && review.changesRequestedBy.isEmpty && (review.approvalsLeft ?? 0) == 0
                    row(met ? "checkmark.circle.fill" : "exclamationmark.circle.fill", met ? .passed : .waiting) {
                        if let left = review.approvalsLeft, left > 0 { Text("\(left) more approvals needed.") } else { Text("Approvals") }
                    }
                }
                if request.state == "open" {
                    HStack(spacing: 6) {
                        Picker("Merge method", selection: $method) {
                            ForEach(request.methods, id: \.self) { value in
                                Text(value == "merge" ? String(localized: "Create a merge commit") : value == "squash" ? String(localized: "Squash and merge") : String(localized: "Rebase and merge")).tag(value)
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        // the card's one filled button; neutral when blocked, with the reason directly below
                        Button("Merge…") { store.confirmMergeRequest(method: method) }
                            .buttonStyle(PullRequestButtonStyle(filled: true))
                            .disabled(disabled || !request.blockers.isEmpty)
                            .help(request.policy)
                    }
                    .padding(.top, 4)
                    ForEach(request.blockers, id: \.self) { PullRequestCaption($0) }
                } else {
                    PullRequestCaption(WorkState.title(request.state))
                }
            } else if state.lifecycleLoading {
                ProgressView().controlSize(.small)
            }
            if let error = state.lifecycleError {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled)
            }
        }
    }

    private var checksSymbol: String {
        switch headSHA.flatMap({ store.ciBySha[$0]?.status }) {
        case .success?: return "checkmark.circle.fill"
        case .failed?: return "xmark.circle.fill"
        case nil: return "circle.dotted"
        default: return "clock.fill"
        }
    }

    private var checksTone: StudioStyle.Tone {
        switch headSHA.flatMap({ store.ciBySha[$0]?.status }) {
        case .success?: return .passed
        case .failed?: return .failed
        case nil: return .neutral
        default: return .waiting
        }
    }

    /// A checklist row: the icon carries the state, the text stays neutral
    private func row<Content: View>(_ symbol: String, _ tone: StudioStyle.Tone, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tone.text).frame(width: 14)
            content().fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Reviewers

    private func reviewerCard(_ request: RequestLifecycle?) -> some View {
        let approved = review?.approvedBy ?? [], changes = review?.changesRequestedBy ?? []
        var names: [String] = []
        for name in (request?.reviewers ?? []) + approved + changes where !names.contains(name) { names.append(name) }
        return PullRequestCard(title: "Reviewers") {
            if names.isEmpty { PullRequestCaption(String(localized: "No one has approved yet.")) }
            ForEach(names, id: \.self) { name in
                HStack(spacing: 8) {
                    Avatar(name: name, email: name, size: 20)
                    Text(verbatim: "@\(name)").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if changes.contains(name) { status("Changes requested", "exclamationmark.bubble.fill", .waiting) }
                    else if approved.contains(name) { status("Approved", "checkmark.circle.fill", .passed) }
                    else { status("Waiting", "clock.fill", .waiting) }
                }
            }
            if let request, request.canEdit {
                Button("Request review…") { reviewers = request.reviewers.joined(separator: ", "); requesting.toggle() }
                    .buttonStyle(PullRequestTextButtonStyle()).disabled(disabled)
                if requesting {
                    TextField("Reviewers (comma-separated usernames)", text: $reviewers).textFieldStyle(.roundedBorder).disabled(disabled)
                    Button("Save reviewers") { Task { if await store.saveRequestReviewers(number, names: reviewers.components(separatedBy: ",")) { requesting = false } } }
                        .buttonStyle(PullRequestButtonStyle()).disabled(disabled)
                }
            }
        }
    }

    private func status(_ title: LocalizedStringKey, _ symbol: String, _ tone: StudioStyle.Tone) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.text).fixedSize()
    }

    // MARK: Edit

    private var editCard: some View {
        PullRequestCard(title: "Edit request…") {
            TextField("Title", text: $title)
            Text("Description").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            TextEditor(text: $description).frame(height: 90).font(.system(size: 13))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
            TextField("Target branch", text: $base)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { editing = false }.buttonStyle(PullRequestButtonStyle())
                Button("Save request") { Task { if await store.saveRequestMetadata(number, title: title, body: description, base: base) { editing = false } } }
                    .buttonStyle(PullRequestButtonStyle(filled: true))
                    .disabled(title.trimmed.isEmpty || base.trimmed.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).disabled(disabled)
    }
}
