import SwiftUI

/// 커밋 칸 위: gitch 가 보는 이 저장소의 계정과 커밋·push 전 점검(gitch 계정을 만들어 두었을 때만).
/// 계정 이름을 눌러 이 저장소에 쓸 계정을 바꾸고(gitch use · unlock), ⋯ 메뉴로 저장소 단위 gitch 명령을 쓴다.
struct GitchBar: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var showChecks = false
    /// 바꾸기 전에 확인받을 계정
    @ViewState private var switching: Gitch.Account?
    @ViewState private var confirmUnlock = false
    @ViewState private var confirmIgnore = false
    /// gitch fix 가 고칠 커밋 목록(확인받기 전)
    @ViewState private var fixPreview: String?
    /// 고칠 것이 없을 때 gitch 가 낸 안내
    @ViewState private var fixNothing: String?
    @ViewState private var showBackups = false

    var body: some View {
        if let s = store.gitchStatus {
            HStack(spacing: 5) {
                Text(verbatim: "gitch").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Image(systemName: s.account == nil ? "exclamationmark.triangle.fill" : s.lockedAccount != nil ? "lock.fill" : "person.fill")
                    .font(.caption2)
                    .foregroundStyle(s.account == nil ? Color.orange : Color.secondary)
                Menu {
                    ForEach(store.gitchAccounts) { a in
                        Button { switching = a } label: {
                            if a.id == s.lockedAccount {
                                Label { Text(verbatim: "\(a.id) · \(a.email)") } icon: { DesignIconImage(icon: .check) }
                            } else {
                                Text(verbatim: "\(a.id) · \(a.email)")
                            }
                        }
                        .disabled(a.id == s.lockedAccount)
                    }
                    if s.lockedAccount != nil {
                        Divider()
                        Button("Unlock this repository…") { confirmUnlock = true }
                    }
                } label: {
                    Text(s.account ?? String(localized: "No account"))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.gitchAccounts.isEmpty)
                .help(summary(s) + "\n" + String(localized: "Click to use another gitch account for this repository."))
                if s.ignored == true {
                    Text("Not managed by gitch").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if store.gitchChecking { ProgressView().controlSize(.mini) }
                if let p = store.gitchPreflight {
                    Button { showChecks.toggle() } label: { GitchResultPill(result: p.result) }
                        .buttonStyle(.plain)
                        .help("gitch checks before commit and push")
                        .popover(isPresented: $showChecks, arrowEdge: .bottom) { GitchChecks() }
                }
                actions(s)
            }
            .alert(Text("Use \(switching?.id ?? "") for this repository?"),
                   isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
                   presenting: switching) { a in
                Button("Cancel", role: .cancel) {}
                Button("Use this account") { Task { await store.useGitchAccount(a.id) } }
            } message: { a in
                Text("gitch sets the commit author to \(a.email) and points origin (and upstream) at \(a.id)'s SSH alias, then locks the repository to it.")
            }
            .alert("Unlock this repository?", isPresented: $confirmUnlock) {
                Button("Cancel", role: .cancel) {}
                Button("Unlock") { Task { await store.unlockGitch() } }
            } message: {
                Text("gitch stops requiring \(s.lockedAccount ?? "") for commits and pushes here. The commit author stays as it is.")
            }
            .alert("Exclude this repository from gitch checks?", isPresented: $confirmIgnore) {
                Button("Cancel", role: .cancel) {}
                Button("Exclude", role: .destructive) { Task { await store.setGitchIgnored(true) } }
            } message: {
                Text("gitch won't check authors, secrets or pushes in this repository until you turn it back on.")
            }
            .alert("Fix commit authors?", isPresented: Binding(get: { fixPreview != nil }, set: { if !$0 { fixPreview = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button("Fix") { Task { await store.gitchFix() } }
            } message: {
                Text(fixPreview ?? "")
            }
            .alert("Commit authors are fine", isPresented: Binding(get: { fixNothing != nil }, set: { if !$0 { fixNothing = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(fixNothing ?? "")
            }
            .sheet(isPresented: $showBackups) { GitchBackupsSheet() }
        }
    }

    /// ⋯ 메뉴: 저장소 단위 gitch 명령(터미널의 gitch up · sync · fix · rescue · ignore · doctor 와 같다)
    private func actions(_ s: Gitch.Status) -> some View {
        Menu {
            Button("Follow the default branch") { Task { await store.gitchUp() } }
                .help("gitch up: moves this branch onto the latest default branch, or merges it if the branch is already pushed. A backup is saved first.")
            if store.remotes.contains("upstream") {
                Button("Update the fork from upstream") { Task { await store.gitchSync() } }
                    .help("gitch sync: brings this branch up to date with the original repository (upstream).")
            }
            Divider()
            Button("Fix authors of unpushed commits…") {
                Task {
                    guard let r = await store.gitchFixPreview() else { return }
                    if r.needsFix { fixPreview = r.text } else { fixNothing = r.text }
                }
            }
            Button("Backups…") { showBackups = true }
            Divider()
            if s.ignored == true {
                Button("Check this repository with gitch again") { Task { await store.setGitchIgnored(false) } }
            } else {
                Button("Exclude this repository from gitch checks…") { confirmIgnore = true }
            }
            Button("Run doctor in Terminal") { try? Gitch.openInTerminal(["doctor"], in: store.url?.path) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.busy != nil)
        .help("gitch commands for this repository")
    }

    private func summary(_ s: Gitch.Status) -> String {
        guard let a = s.account else {
            return String(localized: "gitch doesn't know which account this repository uses. Lock it with gitch use <account>.")
        }
        var text = s.accountSource == "lock" ? String(localized: "Locked to \(a)") : String(localized: "\(a) (chosen by a gitch rule)")
        if let push = s.pushAccount, push != a { text += " · " + String(localized: "Pushes as \(push)") }
        return text
    }
}

/// 점검 결과(OK · WARN · STOP)
private enum GitchLevel {
    static func icon(_ level: String) -> String {
        switch level {
        case "OK": return "checkmark.circle.fill"
        case "WARN": return "exclamationmark.triangle.fill"
        default: return "xmark.octagon.fill"
        }
    }

    static func color(_ level: String) -> Color {
        switch level {
        case "OK": return .green
        case "WARN": return .orange
        default: return .red
        }
    }

    static func title(_ level: String) -> String {
        switch level {
        case "OK": return String(localized: "Ready")
        case "WARN": return String(localized: "Warning")
        default: return String(localized: "Blocked")
        }
    }
}

private struct GitchResultPill: View {
    let result: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: GitchLevel.icon(result))
            Text(GitchLevel.title(result))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(GitchLevel.color(result))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(GitchLevel.color(result).opacity(0.15)))
    }
}

/// 점검 항목(문구는 gitch 가 낸 그대로)과 다시 점검하기
private struct GitchChecks: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("gitch checks before commit and push").font(.headline)
            if let p = store.gitchPreflight {
                ForEach(p.checks, id: \.self) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: GitchLevel.icon(c.level)).foregroundStyle(GitchLevel.color(c.level))
                        Text(c.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Check again with fetch") { Task { await store.refreshGitch(fetch: true) } }
                    .disabled(store.gitchChecking)
                if store.gitchChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Run doctor in Terminal") {
                    do { try Gitch.openInTerminal(["doctor"], in: store.url?.path) } catch {
                        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// gitch 자동 백업(gitch rescue): 되돌리기 · 새 브랜치로 꺼내기
private struct GitchBackupsSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var backups: [Gitch.Backup] = []
    @ViewState private var loaded = false
    @ViewState private var restoring: Gitch.Backup?
    @ViewState private var branchFor: Gitch.Backup?
    @ViewState private var branchName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("gitch backups").font(.title3.weight(.semibold))
            Text("gitch saves a backup before pull, up, sync, fix, undo and amend, and keeps the 30 most recent.")
                .font(.callout).foregroundStyle(.secondary)
            if loaded && backups.isEmpty {
                ContentUnavailableView("No backups yet", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                List(backups) { b in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: b.date).font(.callout.monospacedDigit())
                                Text(verbatim: b.reason).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                if b.hasChanges { Text("+ uncommitted changes").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(verbatim: "\(b.sha)  \(b.subject)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Restore to a new branch…") { branchName = ""; branchFor = b }.controlSize(.small)
                        Button("Restore here…") { restoring = b }.controlSize(.small)
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 420)
        .task {
            backups = await store.gitchBackups()
            loaded = true
        }
        .alert("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { b in
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                Task {
                    if await store.gitchRestore(b, toBranch: nil) { dismiss() }
                }
            }
        } message: { b in
            Text("The current branch moves back to \(b.date) (\(b.reason)). gitch backs up the current state first.")
        }
        .alert("Restore to a new branch", isPresented: Binding(get: { branchFor != nil }, set: { if !$0 { branchFor = nil } }), presenting: branchFor) { b in
            TextField("New branch name", text: $branchName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = branchName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    if await store.gitchRestore(b, toBranch: name) { dismiss() }
                }
            }
        } message: { b in
            Text("Creates a branch at \(b.sha) without changing the current branch.")
        }
    }
}
