import SwiftUI

struct LocalWorkflowsSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var tab = "Recovery"
    @ViewState private var branch = "recovered-work"
    @ViewState private var pattern = ""
    @ViewState private var lockPath = ""
    @ViewState private var good = ""
    @ViewState private var bad = "HEAD"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repository tools").font(.title3.bold())
            Picker("Tools", selection: $tab) {
                Text("Recovery").tag("Recovery"); Text("LFS").tag("LFS"); Text("Submodules").tag("Submodules"); Text("Bisect").tag("Bisect")
            }.pickerStyle(.segmented)
            if let error = store.localWorkflows.error ?? store.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = store.localWorkflows.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab { case "Recovery": recovery; case "LFS": lfs; case "Submodules": submodules; default: bisect }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            HStack {
                if store.localWorkflows.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await store.loadLocalWorkflows() } }.disabled(disabled)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 960, height: 680).task { await store.loadLocalWorkflows() }
    }
    private var disabled: Bool { store.busy != nil || store.localWorkflows.loading }
    private var recovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discarded changes are saved locally before removal. Copies keep binary files, new files, symlinks, and the index. Restore at the original commit with a clean working tree.").font(.caption).foregroundStyle(.secondary)
            Text("Saved working trees").font(.headline)
            if store.localWorkflows.recovery.isEmpty { Text("No safety copies yet.").foregroundStyle(.secondary) }
            ForEach(store.localWorkflows.recovery) { entry in
                HStack {
                    Text(entry.created, style: .date); Text(entry.created, style: .time); Text(String(entry.head.prefix(8))).font(.system(.caption, design: .monospaced)); Spacer()
                    Button("Preview changes") { Task { await store.previewRecovery(entry) } }
                    Button("Restore safety copy") { store.restoreSafetyCopy(entry) }.disabled(disabled)
                }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            if !store.localWorkflows.preview.isEmpty { code(store.localWorkflows.preview) }
            Text("Reflog recovery").font(.headline)
            Text("Recover a commit into a new branch. Your current branch and working files stay in place. Git controls reflog retention.").font(.caption).foregroundStyle(.secondary)
            TextField("Recovery branch name", text: $branch)
            ForEach(store.localWorkflows.reflog) { entry in
                HStack {
                    Text(String(entry.sha.prefix(8))).font(.system(.caption, design: .monospaced))
                    VStack(alignment: .leading) { Text(entry.message).lineLimit(2); Text(entry.selector + " · " + entry.date).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Create recovery branch") { Task { await store.recoverCommit(entry.sha, branch: branch) } }.disabled(disabled || branch.trimmed.isEmpty)
                }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
    private var lfs: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.localWorkflows.lfsAvailable { Text("Git LFS is not installed. Install Git LFS for your platform, then refresh.") }
            else {
                Text("Tracking changes .gitattributes for future additions. Existing history is not migrated. Review and commit the attribute change yourself.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("LFS pattern", text: $pattern, prompt: Text("*.psd"))
                    Button("Track pattern") { Task { await store.lfsTrack(pattern) } }.disabled(disabled || pattern.trimmed.isEmpty)
                    Button("Untrack pattern") { Task { await store.lfsTrack(pattern, remove: true) } }.disabled(disabled || pattern.trimmed.isEmpty)
                    Button("Check local objects") { Task { await store.checkLFS() } }.disabled(disabled)
                }
                code(store.localWorkflows.lfsPatterns + "\n" + store.localWorkflows.lfsFiles)
                Text("Server locks").font(.headline)
                HStack {
                    TextField("File to lock", text: $lockPath, prompt: Text("assets/design.psd"))
                    Button("Lock file") { Task { await store.lockLFS(lockPath) } }.disabled(disabled || lockPath.isEmpty)
                    Button("Load server locks") { Task { await store.loadLFSLocks() } }.disabled(disabled)
                }
                ForEach(store.localWorkflows.lfsLocks) { lock in HStack { Text(lock.path + " · " + lock.owner); Spacer(); Button("Unlock") { store.unlockLFS(lock.id) }.disabled(disabled) } }
            }
        }
    }
    private var submodules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates use the exact commit recorded in this repository. Nested submodules and remote branch tips are not updated automatically. Review the server URL before connecting.").font(.caption).foregroundStyle(.secondary)
            if store.localWorkflows.submodules.isEmpty { Text("No submodules.").foregroundStyle(.secondary) }
            ForEach(store.localWorkflows.submodules) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.path).bold(); Text(moduleStatus(entry.status)).font(.caption); Spacer()
                        Button("Initialize / update") { store.updateSubmodule(entry) }.disabled(disabled)
                        Button("Open") { if let url = store.url, LocalWorkflowState.safePath(entry.path) { store.openRepo?(url.appendingPathComponent(entry.path)) } }.disabled(entry.status == "-")
                    }
                    Text((LocalWorkflowState.safeURL(entry.url) ? entry.url : String(localized: "Unvalidated URL hidden")) + " · " + entry.sha.prefix(12)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
    private var bisect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find the first commit that introduced a problem. Test the checked-out commit, then mark the result. Git performs the binary search; no test command runs automatically.").font(.caption).foregroundStyle(.secondary)
            if !store.localWorkflows.bisectActive {
                HStack {
                    TextField("Known good commit", text: $good); TextField("Known bad commit", text: $bad)
                    Button("Start bisect") { Task { await store.startBisect(good: good, bad: bad) } }.disabled(disabled || good.trimmed.isEmpty || bad.trimmed.isEmpty)
                }
            } else {
                Text(store.localWorkflows.bisectResult.isEmpty ? String(localized: "Test this commit") : String(localized: "First bad commit found")).font(.headline)
                Text(store.localWorkflows.bisectResult.isEmpty ? store.localWorkflows.bisectCurrent : store.localWorkflows.bisectResult).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Group { Button("Good") { Task { await store.markBisect("good") } }; Button("Bad") { Task { await store.markBisect("bad") } }; Button("Skip") { Task { await store.markBisect("skip") } } }.disabled(!store.localWorkflows.bisectResult.isEmpty)
                    Spacer(); Button("Reset bisect") { Task { await store.resetBisect() } }
                }.disabled(disabled)
                code(store.localWorkflows.bisectLog)
            }
        }
    }
    private func code(_ text: String) -> some View { ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(minHeight: 80, maxHeight: 240).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)) }
    private func moduleStatus(_ value: String) -> String { switch value { case "-": return String(localized: "Not initialized"); case "+": return String(localized: "Different commit"); case "U": return String(localized: "Conflicted"); default: return String(localized: "At recorded commit") } }
}
