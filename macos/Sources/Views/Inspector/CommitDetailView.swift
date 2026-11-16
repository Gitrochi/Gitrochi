import AppKit
import SwiftUI

/// The selected commit, as the redesign board's flat panel: a 44 pt header (what it is, the short SHA, copy, ⋯), then
/// the message, its author, parents and actions, and the changed files. (Windows: widgets/inspector/ui/CommitDetailView.tsx)
struct CommitDetailView: View {
    @Environment(RepoStore.self) private var store
    let sha: String
    @ViewState private var bodyExpanded = false

    var body: some View {
        // a late answer for another commit is never shown under this one
        if let d = store.detail, d.sha == sha {
            VStack(spacing: 0) {
                header(d)
                Divider()
                InspectorScrollView(inset: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        message(d)
                            .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
                        files(d)
                            .padding(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    }
                }
                .id(sha)   // another commit starts at the top
            }
            .background(StudioStyle.surface)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioStyle.surface)
        }
    }

    private func header(_ d: CommitDetail) -> some View {
        HStack(spacing: 8) {
            Text(d.parents.count > 1 ? "Merge commit" : "Commit")
                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                // in a narrow panel the SHA gives way first: what this is stays whole
                .fixedSize().layoutPriority(1)
            Text(verbatim: String(d.sha.prefix(7)))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(HostedList.caption)
                .lineLimit(1).textSelection(.enabled)
            Button { store.copy(d.sha) } label: { SymbolIcon("doc.on.doc").font(.system(size: 13)) }
                .buttonStyle(PullRequestIconButtonStyle())
                .help("Copy commit SHA").accessibilityLabel("Copy commit SHA")
            Spacer(minLength: 0)
            // the graph's own menu for this commit, so the two never drift apart
            Menu {
                CommitMenu(commit: Commit(id: d.sha, parents: d.parents, author: d.author,
                                          email: d.email, date: d.date, subject: d.summary, body: d.body))
            } label: { SymbolIcon("ellipsis").font(.system(size: 14)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 24, height: 24)
                .help("More commit actions").accessibilityLabel("More commit actions")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func message(_ d: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let refs = store.refsByCommit[sha] ?? []
            if !refs.isEmpty {
                WorkbenchFlow(spacing: 4) {
                    ForEach(refs.prefix(4)) { CommitRefChip(label: $0) }
                    if refs.count > 4 {
                        Text(verbatim: "+\(refs.count - 4)").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                            .frame(height: 18).help(refs.dropFirst(4).map(\.name).joined(separator: "\n"))
                    }
                }
                .padding(.bottom, 8)
            }
            Text(d.summary)
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("commit-detail-summary")
            author(d).padding(.top, 8)
            if !d.body.isEmpty { description(d).padding(.top, 10) }
            if !d.parents.isEmpty { parents(d).padding(.top, 6) }
            WorkbenchFlow(spacing: 6) {
                Button("New branch…") { store.requestNewBranch(from: d.sha, label: String(d.sha.prefix(7))) }
                Button("Tag…") { store.sheet = .tag(sha: d.sha) }
            }
            .buttonStyle(HostedListButtonStyle())
            // a running git command blocks both; the tip names it
            .disabled(store.busy != nil).help(store.busy ?? "")
            .padding(.top, 10)
            explanation
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line: the photo (or the initial), the name and when. The email and the exact date are on hover; who
    /// committed it appears only when that differs from the author.
    private func author(_ d: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AuthorAvatar(name: d.author, email: d.email, size: 20)
                Text(verbatim: d.author).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .help("\(d.author) <\(d.email)>")
                    .accessibilityIdentifier("commit-detail-author")
                Text(verbatim: ListDate.when(d.date, locale: AppLanguage.locale)).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize().layoutPriority(1)
                    .help(Fmt.long(d.date))
            }
            if d.committer != d.author || abs(d.commitDate.timeIntervalSince(d.date)) > 60 {
                Text(d.committer == d.author ? "Commit: \(Fmt.long(d.commitDate))" : "Commit: \(d.committer) · \(Fmt.long(d.commitDate))")
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .help(d.committer == d.author ? "" : "\(d.committer) <\(d.committerEmail)>")
            }
        }
    }

    @ViewBuilder private func description(_ d: CommitDetail) -> some View {
        let long = d.body.count > 400 || d.body.filter { $0 == "\n" }.count > 8
        let collapsed = long && !bodyExpanded
        MarkdownView(d.body, target: store.target)
            .font(.system(size: 13)).lineSpacing(4)
            .foregroundStyle(StudioStyle.Tone.neutral.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: collapsed ? 160 : nil, alignment: .top)
            .clipped()
            .mask { LinearGradient(stops: [.init(color: .black, location: collapsed ? 0.7 : 1), .init(color: collapsed ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom) }
        if long {
            Button(bodyExpanded ? "Collapse" : "Show all") { bodyExpanded.toggle() }
                .buttonStyle(HostedListTextButtonStyle())
        }
    }

    private func parents(_ d: CommitDetail) -> some View {
        WorkbenchFlow(spacing: 4) {
            Text(d.parents.count > 1 ? "Parents" : "Parent").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                .frame(height: 24)
            ForEach(d.parents, id: \.self) { p in
                Button { store.reveal(p) } label: {
                    Text(verbatim: String(p.prefix(7))).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioStyle.link)
                        .padding(.horizontal, 4).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to parent commit")
                .accessibilityLabel("Go to parent commit").accessibilityValue(Text(verbatim: String(p.prefix(7))))
            }
        }
    }

    /// The AI's explanation: a grey text button until there is one, then the text under the provider's name.
    @ViewBuilder private var explanation: some View {
        let provider = AIStore.shared.short(for: .explain)
        let text = store.explanations[sha]
        if let text {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SymbolIcon("sparkles").font(.system(size: 13)).accessibilityHidden(true)
                    Text("\(provider) explanation").font(.system(size: 12))
                }
                .foregroundStyle(HostedList.caption)
                Text(verbatim: text)
                    .font(.system(size: 13)).lineSpacing(4)
                    .foregroundStyle(StudioStyle.Tone.neutral.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        }
        Group {
            if store.explaining.contains(sha) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                }
                .frame(minHeight: 24)
            } else if let failure = store.explainFailures[sha] {
                FailureBlock(title: String(localized: "Couldn't explain this commit"), caption: failure) {
                    Task { await store.explainCommit(sha) }
                }
            } else {
                Button { Task { await store.explainCommit(sha) } } label: {
                    HStack(spacing: 6) {
                        if text == nil { SymbolIcon("sparkles").font(.system(size: 13)).accessibilityHidden(true) }
                        Text(text == nil ? "Explain with AI…" : "Explain again")
                    }
                }
                .buttonStyle(HostedListTextButtonStyle())
                .help(provider)
            }
        }
        .padding(.top, 8)
    }

    private func files(_ d: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let stats = store.detailStats.values
            let added = stats.compactMap(\.added).reduce(0, +)
            let deleted = stats.compactMap(\.deleted).reduce(0, +)
            HStack(spacing: 6) {
                Text("Changed files").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(verbatim: "\(store.detailFiles.count)")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(StudioStyle.Tone.neutral.text)
                    .padding(.horizontal, 8).frame(height: 18)
                    .background(Capsule().fill(StudioStyle.Tone.neutral.fill))
                Spacer(minLength: 0)
                FileViewToggle()
            }
            .frame(minHeight: 28)
            if added + deleted > 0 {
                HStack(spacing: 8) {
                    LineStatText(added: added, deleted: deleted)
                    ChangeBar(added: added, deleted: deleted)
                    Spacer(minLength: 0)
                }
            }
            ChangeList(changes: store.detailFiles,
                       isSelected: { store.diffSource == .commit(sha: sha, change: $0, parent: d.parents.first) },
                       stats: store.detailStats,
                       onOpen: { store.openDiff(.commit(sha: sha, change: $0, parent: d.parents.first)) }) { f in
                Button("File history") { store.openFileHistory(f.path) }
                Button("Show blame at this commit") { store.openBlame(f.path, rev: sha) }.disabled(f.kind == .deleted)
                Divider()
                Button("Show in Finder") { store.revealInFinder(f) }
                Button("Copy path") { store.copy(f.path) }
            }
            // the row's fill reaches past the column so its text lines up with the title above
            .padding(.horizontal, -8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }
}

/// A branch or tag on this commit, in the board's neutral chip: the graph owns the lane colours.
/// (Windows: CommitRefChip)
private struct CommitRefChip: View {
    let label: RefLabel

    var body: some View {
        HStack(spacing: 4) {
            if label.isCurrent && label.kind == .local {
                SymbolIcon("checkmark").font(.system(size: 10, weight: .semibold)).accessibilityLabel("Current branch")
            }
            if label.kind == .tag { SymbolIcon("tag").font(.system(size: 11)) }
            if label.kind == .head { SymbolIcon("scope").font(.system(size: 11)) }
            Text(verbatim: label.name).lineLimit(1).truncationMode(.middle)
            if label.kind == .local { SymbolIcon("arrow.triangle.branch").font(.system(size: 11)) }
            if label.kind == .remote { SymbolIcon("cloud").font(.system(size: 11)) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(HostedList.caption)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 6).fill(Self.fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Self.edge))
        .help(label.name)
    }

    private static let fill = tone(light: 0xf6f6f7, dark: 0x2b2b2f)
    private static let edge = tone(light: 0xc9c9ce, dark: 0x4a4a50)

    private static func tone(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        })
    }
}
