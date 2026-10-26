import SwiftUI

struct CompareRevisionsSheet: View {
    let store: RepoStore
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var state = store.historyTools
        VStack(alignment: .leading, spacing: 12) {
            if !embedded { Text("Compare revisions").font(.title3.weight(.semibold)) }
            VStack(spacing: 8) {
                HStack {
                    RevisionPicker(title: String(localized: "From revision"), revision: $state.left, store: store)
                    Button { let old = state.left; state.left = state.right; state.right = old } label: { Image(systemName: "arrow.left.arrow.right") }.help("Swap revisions")
                }
                HStack {
                    RevisionPicker(title: String(localized: "To revision"), revision: $state.right, store: store)
                    Button("Compare") { Task { await store.loadRevisionComparison() } }.disabled(state.comparisonLoading || state.left.isEmpty || state.right.isEmpty)
                }
            }
            Toggle("Compare from the common ancestor (changes introduced by the right side)", isOn: $state.useMergeBase)
            Text("Uncommitted changes are excluded. Compare fixes both revisions to immutable commits.").font(.caption).foregroundStyle(.secondary)
            if state.comparisonLoading { ProgressView().controlSize(.small) }
            if let error = state.comparisonError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let result = state.comparison {
                Text(comparisonLabel(result))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                AdaptiveWorkbenchSplit(listWidth: 250) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(result.files) { file in
                                Button { Task { await store.selectComparisonFile(file) } } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.path).font(.callout).lineLimit(2)
                                        if let old = file.oldPath { Text(old + " → " + file.path).font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                        .background(state.comparisonPath == file.path ? Color.accentColor.opacity(0.15) : Color.clear)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } detail: {
                    HistoryPatchView(text: result.files.isEmpty ? String(localized: "No differences between these revisions.") : state.comparisonPatch)
                }.frame(minHeight: 250, maxHeight: embedded ? .infinity : 440)
            } else if !state.comparisonLoading {
                ContentUnavailableView("Choose two revisions to compare", systemImage: "arrow.left.arrow.right", description: Text("Use branches, tags or commit IDs.")).frame(height: 250)
            }
            if !embedded { HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }.padding(embedded ? 0 : 20).frame(width: embedded ? nil : 1020)
            .onDisappear { store.cancelHistoryTools() }
    }
    private func comparisonLabel(_ result: RevisionComparison) -> String {
        var text = String(result.left.prefix(12)) + " → " + String(result.right.prefix(12))
        if result.mergeBase { text += " · " + String(localized: "Common ancestor") + ": " + String(result.base.prefix(12)) }
        return text
    }
}

/// A revision field: type a branch, tag or commit, or pick one from the list next to it
struct RevisionPicker: View {
    let title: String
    @Binding var revision: String
    let store: RepoStore

    var body: some View {
        HStack(spacing: 0) {
            TextField(title, text: $revision)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
            Menu {
                if let head = store.headBranch { Button(head + " " + String(localized: "(current)")) { revision = head } }
                Button("HEAD") { revision = "HEAD" }
                if !store.localBranches.isEmpty {
                    Section("Local branches") { ForEach(store.localBranches) { branch in Button(branch.name) { revision = branch.name } } }
                }
                if !store.remoteBranches.isEmpty {
                    Section("Remote branches") { ForEach(store.remoteBranches) { branch in Button(branch.name) { revision = branch.name } } }
                }
                if !store.tags.isEmpty {
                    Section("Tags") { ForEach(store.tags) { tag in Button(tag.name) { revision = tag.name } } }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 24)
            .help("Choose a branch or tag")
            .accessibilityLabel(String(localized: "Choose a branch or tag") + ": " + title)
        }
    }
}

struct BatchCommitsSheet: View {
    let store: RepoStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var state = store.historyTools
        VStack(alignment: .leading, spacing: 12) {
            Text("Review selected commits").font(.title3.weight(.semibold))
            Picker("Action", selection: $state.batchAction) {
                ForEach(BatchCommitAction.allCases) { action in Text(action.title).tag(action) }
            }.disabled(state.batchLoading)
            Text("Commits run from top to bottom. Cherry-pick normally uses oldest first; revert uses newest first.").font(.caption).foregroundStyle(.secondary)
            Text(state.batchBranch.replacingOccurrences(of: "refs/heads/", with: "") + " · HEAD " + String(state.batchHead.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
            if state.batchLoading { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(state.batch.enumerated()), id: \.element.sha) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1).").foregroundStyle(.secondary)
                            Text(String(item.sha.prefix(8))).font(.caption.monospaced())
                            Text(item.subject).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(item.message)
                            Text(item.author).font(.caption).foregroundStyle(.secondary)
                            Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0 || state.batchLoading).help("Run earlier")
                            Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == state.batch.count - 1 || state.batchLoading).help("Run later")
                        }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }.frame(minHeight: 100, maxHeight: 350)
            Text("A clean working tree is required. A conflict stops the sequence; use Continue or Abort in the operation banner. Completed operations can be undone.").font(.caption).foregroundStyle(.secondary)
            if state.batchAction == .squash || state.batchAction == .drop {
                Text("Cleanup rewrites history on the current branch. Squash requires adjacent commits; a second plan shows every affected commit before starting.").font(.caption).foregroundStyle(.orange)
            }
            if let error = state.batchError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(state.batchLoading)
                Button(state.batchAction == .squash || state.batchAction == .drop ? "Review cleanup plan" : "Apply selected commits") {
                    Task { await store.executeBatchCommits() }
                }.disabled(state.batchLoading || state.batchError != nil || state.batch.isEmpty || store.busy != nil)
            }
        }.padding(20).frame(width: 850)
            .interactiveDismissDisabled(state.batchLoading)
            .onDisappear { store.cancelHistoryTools() }
    }
    private func move(_ index: Int, _ delta: Int) {
        let destination = index + delta
        guard historyRangeContains(destination) else { return }
        store.historyTools.batch.swapAt(index, destination)
    }
    private func historyRangeContains(_ index: Int) -> Bool { store.historyTools.batch.indices.contains(index) }
}

struct LineHistorySheet: View {
    let store: RepoStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var state = store.historyTools
        VStack(alignment: .leading, spacing: 12) {
            Text("Line and function history").font(.title3.weight(.semibold))
            HStack { Text("File").frame(width: 65, alignment: .leading); TextField("File", text: $state.linePath).textFieldStyle(.roundedBorder) }
            HStack {
                Text("Revision").frame(width: 65, alignment: .leading)
                TextField("Revision", text: $state.lineRevision).textFieldStyle(.roundedBorder)
                Text("Lines")
                TextField("First line", value: $state.lineStart, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                Text("–")
                TextField("Last line", value: $state.lineEnd, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            HStack {
                TextField("Function name (optional)", text: $state.functionName).textFieldStyle(.roundedBorder)
                Button("Trace history") { Task { await store.loadLineHistory() } }.disabled(state.lineLoading)
            }
            Text("A function name replaces the line range. Git detects function boundaries using its language rules. Only committed content is traced, up to 200 commits.").font(.caption).foregroundStyle(.secondary)
            if state.lineLoading { ProgressView().controlSize(.small) }
            if let error = state.lineError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if state.lineTruncated { Text("Output truncated. Narrow the selection.").font(.caption).foregroundStyle(.orange) }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.lineEntries) { item in
                            Button { state.lineSelected = item.sha } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.subject).font(.callout).lineLimit(2)
                                    Text(item.author + " · " + item.date + " · " + String(item.sha.prefix(8))).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(state.lineSelected == item.sha ? Color.accentColor.opacity(0.15) : Color.clear)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(minWidth: 200, idealWidth: 280, maxWidth: 350)
                HistoryPatchView(text: state.lineEntries.first(where: { $0.sha == state.lineSelected })?.patch ?? "")
            }.frame(height: 400)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 1020)
            .onDisappear { store.cancelHistoryTools() }
    }
}

private struct HistoryPatchView: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? " " : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.25))
    }
}
