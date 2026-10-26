import SwiftUI

/// 커밋 정리(인터랙티브 리베이스): 커밋마다 그대로·메시지 고치기·아래 커밋에 합치기·빼기를 고르고 순서를 바꾼다
struct InteractiveRebaseSheet: View {
    var embedded = false
    var onClose: (() -> Void)? = nil
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var plan: RebasePlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean up commits").font(.title3.weight(.semibold))
                Text("\(plan?.items.count ?? 0) commits on '\(store.headBranch ?? "")' — newest at the top. Squash combines a commit into the one right below it (older).")
                    .font(.callout).foregroundStyle(.secondary)
                if plan?.pushed == true {
                    Label("Includes commits already pushed to the remote. You'll need to force push after cleaning up.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 10)
            if plan != nil {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array((plan?.items ?? []).enumerated()), id: \.element.id) { i, _ in row(i) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160, maxHeight: 480)
            }
            HStack {
                if let p = plan?.problem {
                    Label(p, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                } else {
                    Text("You can always return to the state before you started (Undo, ⌥⌘Z).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Start cleanup") {
                    guard let p = plan else { return }
                    close()
                    Task { await store.runInteractiveRebase(p) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.problem != nil || plan?.changed != true || store.busy != nil)
            }
            .padding(20)
        }
        .frame(width: embedded ? nil : 720)
        .onAppear { if plan == nil { plan = store.rebasePlan } }
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    private func binding(_ i: Int) -> Binding<RebaseItem> {
        Binding(get: { plan?.items[i] ?? RebaseItem(sha: "", message: "", author: "") },
                set: { plan?.items[i] = $0 })
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let item = binding(i)
        let count = plan?.items.count ?? 0
        let a = item.wrappedValue.action
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: item.action) {
                    ForEach(RebaseAction.allCases) { act in
                        Label(act.title, systemImage: act.symbol).tag(act)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
                .help("What to do with this commit")
                Text(String(item.wrappedValue.sha.prefix(7))).font(.callout.monospaced()).foregroundStyle(.secondary)
                Text(item.wrappedValue.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(a == .drop)
                    .foregroundStyle(a == .drop ? .secondary : .primary)
                    .help(item.wrappedValue.message)
                Spacer(minLength: 4)
                Text(item.wrappedValue.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { move(i, -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(i == 0).help("Up (later)")
                    .accessibilityLabel("Up")
                Button { move(i, 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).disabled(i == count - 1).help("Down (earlier)")
                    .accessibilityLabel("Down")
            }
            if a == .reword {
                TextEditor(text: item.newMessage)
                    .font(.callout)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint(a).opacity(a == .pick ? 0.04 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint(a).opacity(a == .pick ? 0.12 : 0.35)))
    }

    private func tint(_ a: RebaseAction) -> Color {
        switch a {
        case .pick: return .secondary
        case .reword: return .blue
        case .squash, .fixup: return .purple
        case .drop: return .red
        }
    }

    private func move(_ i: Int, _ d: Int) {
        guard var p = plan, p.items.indices.contains(i + d) else { return }
        p.items.swapAt(i, i + d)
        plan = p
    }
}
