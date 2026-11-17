import AppKit
import SwiftUI

/// The selected commit, as the redesign board's flat panel: a header as tall as the graph's (what it is, the short SHA, copy, ⋯), then
/// the message, its author, trailers, parents and actions, and the changed files. Nothing else: a commit's refs are on its graph row.
/// (Windows: widgets/inspector/ui/CommitDetailView.tsx)
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
                            .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
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
        // as tall as the graph's column header beside it, so the two dividers meet in one line
        .frame(height: GraphMetrics.headerHeight)
    }

    private func message(_ d: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(d.summary)
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("commit-detail-summary")
            // a looser rhythm than the board's 8 / 10 / 6: read in the app, its blocks ran together
            author(d).padding(.top, 10)
            if !d.prose.isEmpty { description(d).padding(.top, 14) }
            if !d.trailers.isEmpty { trailers(d).padding(.top, 12) }
            if !d.parents.isEmpty { parents(d).padding(.top, 12) }
            WorkbenchFlow(spacing: 6) {
                Button("New branch…") { store.requestNewBranch(from: d.sha, label: String(d.sha.prefix(7))) }
                Button("Tag…") { store.sheet = .tag(sha: d.sha) }
            }
            .buttonStyle(HostedListButtonStyle())
            // a running git command blocks both; the tip names it
            .disabled(store.busy != nil).help(store.busy ?? "")
            .padding(.top, 12)
            explanation
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line: the photo (or the initial), the name and when. The email is on the name's hover and the exact date on the
    /// time's, which also says who committed it and when, if that differs from the author.
    private func author(_ d: CommitDetail) -> some View {
        HStack(spacing: 6) {
            AuthorAvatar(name: d.author, email: d.email, size: 20)
            Text(verbatim: d.author).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .help("\(d.author) <\(d.email)>")
                .accessibilityIdentifier("commit-detail-author")
            Text(verbatim: ListDate.when(d.date, locale: AppLanguage.locale)).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                .fixedSize().layoutPriority(1)
                .help(Self.dates(d))
        }
    }

    /// The author date, and under it the committer and commit date when they are not the author's (a rebase, a cherry-pick)
    static func dates(_ d: CommitDetail) -> String {
        let authored = Fmt.long(d.date), committed = Fmt.long(d.commitDate)
        if d.committer != d.author {
            let who = "\(d.committer) <\(d.committerEmail)>"
            return authored + "\n" + String(localized: "Commit: \(who) · \(committed)")
        }
        return abs(d.commitDate.timeIntervalSince(d.date)) > 60 ? authored + "\n" + String(localized: "Commit: \(committed)") : authored
    }

    @ViewBuilder private func description(_ d: CommitDetail) -> some View {
        let long = d.prose.count > 400 || d.prose.filter { $0 == "\n" }.count > 8
        let collapsed = long && !bodyExpanded
        MarkdownView(d.prose, target: store.target)
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

    /// The board's Trailers group: the issues this commit closes, as links, then its co-authors
    private func trailers(_ d: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(d.trailers.issues, id: \.number) { issueRow($0) }
            ForEach(d.trailers.coAuthors, id: \.email) { coAuthorRow($0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trailers")
    }

    /// "Closes #42 <title>": the title only once it was read (a connected account); the state colours the icon
    @ViewBuilder private func issueRow(_ trailer: CommitTrailers.Issue) -> some View {
        let item = store.trailerIssue(trailer.number)
        let title = item?.title ?? ""
        let open = item.map { ["open", "opened"].contains($0.state) }
        let row = HStack(spacing: 6) {
            SymbolIcon(open == false ? "checkmark.circle" : "smallcircle.filled.circle").font(.system(size: 14))
                .foregroundStyle(open == true ? StudioStyle.Tone.passed.text : HostedList.caption)
                .accessibilityHidden(true)
            Group {
                switch trailer.keyword {
                case "fixes": Text("Fixes")
                case "resolves": Text("Resolves")
                default: Text("Closes")
                }
            }
            .foregroundStyle(HostedList.caption).fixedSize()
            Text(verbatim: "#\(trailer.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.link).fixedSize()
            if !title.isEmpty {
                Text(verbatim: title).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 12))
        .frame(height: 24).contentShape(Rectangle())
        .help(title)
        // without a hosting server there is no page to open, so the row is plain text rather than a dimmed button
        if store.target == nil {
            row.accessibilityElement(children: .combine)
        } else {
            Button { store.openTrailerIssue(trailer.number) } label: { row }.buttonStyle(.plain)
        }
    }

    private func coAuthorRow(_ author: CommitTrailers.CoAuthor) -> some View {
        HStack(spacing: 6) {
            AuthorAvatar(name: author.name, email: author.email, size: 16)
            Text(verbatim: author.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            StatusPill(title: String(localized: "Co-author"), tone: .neutral)
                .fixedSize().layoutPriority(1)
        }
        .frame(height: 24)
        // the trailer as it was written
        .help(author.line)
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

    /// The AI's explanation: the board's grey text button, and under it the text once there is one, in the body's type. The
    /// provider is on the button's hover; the board draws no caption.
    @ViewBuilder private var explanation: some View {
        let text = store.explanations[sha]
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
                        SymbolIcon("sparkles").font(.system(size: 13)).accessibilityHidden(true)
                        Text(text == nil ? "Explain with AI…" : "Explain again")
                    }
                }
                .buttonStyle(HostedListTextButtonStyle())
                .help(AIStore.shared.short(for: .explain))
            }
        }
        .padding(.top, 12)
        if let text {
            Text(verbatim: text)
                .font(.system(size: 13)).lineSpacing(4)
                .foregroundStyle(StudioStyle.Tone.neutral.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityIdentifier("commit-detail-explanation")
        }
    }

    private func files(_ d: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
