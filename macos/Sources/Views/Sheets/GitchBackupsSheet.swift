import SwiftUI

/// gitch 자동 백업(gitch rescue): 되돌리기 · 새 브랜치로 꺼내기. Opened from ⋯ › gitch › Backups…
/// (Windows: GitchBackupsSheet in features/gitch-backups)
struct GitchBackupsSheet: View {
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
                ContentUnavailableView("No backups yet", symbol: "clock.arrow.circlepath")
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
