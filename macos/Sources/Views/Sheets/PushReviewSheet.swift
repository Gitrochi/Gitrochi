import SwiftUI

/// 검토 중 원본이나 목적지가 바뀌면 갱신한 내용을 한 번 더 확인한다.
struct PushReviewSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let branch: String
    let force: Bool
    let remoteOverride: String?

    /// The review could not be read, so there is nothing to confirm until it is retried
    private var reviewFailed: Bool { store.pushReview == nil && store.pushReviewError != nil && !store.pushReviewLoading }

    private func refresh() { Task { await store.loadPushReview(branch: branch, force: force, remoteOverride: remoteOverride) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review push").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.pushReviewLoading {
                        HStack { ProgressView().controlSize(.small); Text("Checking push destination…") }
                    }
                    if let error = store.pushReviewError {
                        // a review that could not be read blocks the push; a later failure leaves the review in place
                        if reviewFailed {
                            FailureBlock(title: String(localized: "Couldn't check the push destination"), caption: error) { refresh() }
                        } else {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    if force {
                        Label("Force push can replace remote history. The reviewed remote revision is protected by an explicit lease.", symbol: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    if let plan = store.pushReview {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            row("Push account", plan.account)
                            row("Credential account", plan.credentialAccount)
                            row("Commit identity", plan.author)
                            row("Push URL", plan.displayURL)
                            row("Destination branch", plan.remote + " / " + String(plan.destination.dropFirst("refs/heads/".count)))
                            row("Source revision", plan.branch + " · " + String(plan.sourceOID.prefix(12)))
                            row("Remote revision", plan.destinationOID.map { String($0.prefix(12)) } ?? String(localized: "New branch"))
                        }
                        Text("The account follows gitch policy. SSH and credential helpers choose the network login.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Outgoing commits (\(plan.commitCount))").font(.headline)
                        if plan.commitCount == 0 { Text("No outgoing commits").foregroundStyle(.secondary) }
                        ForEach(plan.commits) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(String(commit.sha.prefix(8))).monospaced().foregroundStyle(.secondary)
                                    Text(commit.subject)
                                }
                                Text(commit.author + " <" + commit.email + ">").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if plan.commitCount > plan.commits.count {
                            Text("Showing the first \(plan.commits.count) items").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        if let base = plan.comparisonBase, plan.destinationOID == nil { LabeledContent("File comparison base", value: String(base.prefix(12))) }
                        if plan.fileScope == "snapshot" { Text("Files in new branch snapshot (\(plan.fileCount))").font(.headline) }
                        else { Text("Changed files (\(plan.fileCount))").font(.headline) }
                        ForEach(plan.files, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                        if plan.fileCount > plan.files.count {
                            Text("Showing the first \(plan.files.count) items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 560)
            HStack {
                Button("Refresh review") { refresh() }
                    .disabled(store.pushReviewLoading)
                Spacer()
                Button("Cancel", role: .cancel) { store.cancelPushReview(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(store.busy != nil)
                Button(force ? String(localized: "Confirm force push") : String(localized: "Confirm push")) {
                    Task { await store.confirmPushReview() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.pushReview == nil || store.pushReviewLoading)
                .disabledReason(reviewFailed ? DisabledReason.retryAbove : nil)
            }
        }
        .padding(20).frame(width: 700)
        .interactiveDismissDisabled(store.busy != nil)
        .task { await store.loadPushReview(branch: branch, force: force, remoteOverride: remoteOverride) }
        .onDisappear { store.cancelPushReview() }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }
}
