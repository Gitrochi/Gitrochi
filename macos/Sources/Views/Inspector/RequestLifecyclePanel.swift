import SwiftUI

/// The side cards of a request's conversation: Merge, Reviewers and, while editing, the request's own fields.
/// Windows: RequestLifecyclePanel.tsx.
struct RequestLifecyclePanel: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    /// Who approved or asked for changes, once the review is loaded
    var review: ReviewState?
    var headSHA: String?
    /// What the Checks tab counted; nil when nothing needs attention or it has not read them yet
    var badge: PullRequestPage.ChecksBadge?
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
                row(checksSymbol, checksTone) { Text(verbatim: checksText) }
                row(request.conflicts ? "xmark.circle.fill" : "checkmark.circle.fill", request.conflicts ? .failed : .passed) {
                    Text(verbatim: request.conflicts ? String(localized: "Conflicts with \(request.base)") : String(localized: "No conflicts with \(request.base)"))
                }
                if let review {
                    let met = !review.approvedBy.isEmpty && review.changesRequestedBy.isEmpty && (review.approvalsLeft ?? 0) == 0
                    row(met ? "checkmark.circle.fill" : "exclamationmark.circle.fill", met ? .passed : .waiting) {
                        if let left = review.approvalsLeft, left > 0 { Text("\(left) more approvals needed.") } else { Text("Approvals") }
                    }
                }
                if request.state == "open" {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(request.methods, id: \.self) { value in Button(Self.methodTitle(value)) { method = value } }
                        } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: Self.methodTitle(method)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                SymbolIcon("chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(StudioStyle.Rail.icon)
                            }
                            .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .accessibilityLabel("Merge method")
                        // the card's one filled button; neutral when blocked, with the reason directly below
                        Button("Merge…") { store.confirmMergeRequest(method: method) }
                            .buttonStyle(PullRequestButtonStyle(filled: true))
                            .disabled(disabled || !request.blockers.isEmpty)
                            .help(([request.policy] + request.blockers).joined(separator: "\n"))
                    }
                    .padding(.top, 4)
                    if let reason = PullRequestPage.mergeReason(conflicts: request.conflicts, base: request.base, badge: badge, approvalsLeft: review?.approvalsLeft, blockers: request.blockers) {
                        PullRequestCaption(reason)
                    }
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

    private static func methodTitle(_ value: String) -> String {
        value == "merge" ? String(localized: "Create a merge commit") : value == "squash" ? String(localized: "Squash and merge") : String(localized: "Rebase and merge")
    }

    private var checksText: String {
        switch badge {
        case .failed(let count)?: return count == 1 ? String(localized: "1 check failed") : String(localized: "\(count) checks failed")
        case .running(let count)?: return count == 1 ? String(localized: "1 check running") : String(localized: "\(count) checks running")
        case nil: return headSHA.flatMap({ store.ciBySha[$0]?.status }) == .success ? String(localized: "All checks passed") : String(localized: "Checks pending")
        }
    }

    private var checksSymbol: String {
        if case .failed? = badge { return "xmark.circle.fill" }
        if case .running? = badge { return "clock.fill" }
        return storedChecksSymbol
    }

    private var storedChecksSymbol: String {
        switch headSHA.flatMap({ store.ciBySha[$0]?.status }) {
        case .success?: return "checkmark.circle.fill"
        case .failed?: return "xmark.circle.fill"
        case nil: return "circle.dotted"
        default: return "clock.fill"
        }
    }

    private var checksTone: StudioStyle.Tone {
        if case .failed? = badge { return .failed }
        if case .running? = badge { return .waiting }
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
            SymbolIcon(symbol).font(.system(size: 13)).foregroundStyle(tone.text).frame(width: 14)
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
                    RequestAuthorAvatar(author: name, size: 20)
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
            SymbolIcon(symbol).font(.system(size: 11))
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
