import SwiftUI
import AppKit

/// The open issue, as the Issues board draws it: number and state, the title with its actions, who opened it and when;
/// then the description and the activity beside the Development and Details cards, and the comment field at the bottom.
/// Drafts stay while the list reloads. (Windows: widgets/inspector/ui/IssueDetail.tsx)
struct IssueDetailView: View {
    @Environment(RepoStore.self) private var store
    let detail: CollaborationInboxDetail
    @ViewState private var draft = ""
    @ViewState private var preview = false
    @ViewState private var editing: String?
    @ViewState private var editText = ""
    @ViewState private var width: CGFloat = 900
    @FocusState private var composerFocused: Bool
    @Environment(\.locale) private var locale
    private var item: CollaborationInboxItem { detail.item }
    private var isOpen: Bool { ["open", "opened"].contains(item.state) }
    private var busy: Bool { store.collaboration.inboxBusy || store.collaboration.inboxLoading }
    private var context: String { [store.url?.path ?? "", store.target?.host ?? "", store.target?.path ?? "", store.hostingAccount?.id ?? "", item.id].joined(separator: "|") }
    /// The comment field is one line until it is used
    private var composing: Bool { composerFocused || preview || !draft.isEmpty }
    /// Too narrow for the cards beside the text: they go under it, as the board's columns wrap
    private var stacked: Bool { width < 760 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 24)
            ScrollView {
                Group {
                    if stacked {
                        VStack(alignment: .leading, spacing: 24) { main; side }
                    } else {
                        HStack(alignment: .top, spacing: 28) {
                            main.frame(maxWidth: .infinity, alignment: .leading)
                            side.frame(width: 280)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(context)
            Divider()
            composer
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: context) { _, _ in draft = ""; preview = false; editing = nil; editText = "" }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: "#\(item.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(HostedList.caption)
                StatusPill(title: WorkState.title(item.state), symbol: isOpen ? "smallcircle.filled.circle" : "checkmark.circle", tone: isOpen ? .passed : .neutral)
                if store.collaboration.inboxLoading { ProgressView().controlSize(.small) }
            }
            if stacked {
                title
                actions
            } else {
                HStack(alignment: .top, spacing: 12) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Avatar(name: item.author, email: item.author, size: 20)
                    Text(verbatim: "@\(item.author)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                // the list row owns the updated date; the detail says when the issue was opened
                if let date = ListDate.parse(item.createdAt) {
                    Text(verbatim: String(localized: "Opened {0}").replacingOccurrences(of: "{0}", with: ListDate.day(date, locale: locale)))
                        .font(.system(size: 12)).foregroundStyle(HostedList.caption).help(date.formatted(date: .long, time: .shortened))
                }
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(verbatim: item.title).font(.system(size: 22, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { store.sheet = .issueEditor(number: item.number, title: item.title, body: item.body) } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(HostedListButtonStyle()).disabled(busy)
            Button { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } } label: { Label("Open in browser", systemImage: "arrow.up.right.square") }
                .buttonStyle(HostedListButtonStyle())
            Menu {
                Button("Refresh conversation") { Task { await store.openInboxItem(item) } }
                Button("Copy link") { store.copy(item.url) }
            } label: { DesignIconImage(icon: .more, size: 12) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                .help("More issue actions").accessibilityLabel("More issue actions")
        }
    }

    // MARK: Description and activity

    private var main: some View {
        VStack(alignment: .leading, spacing: 16) {
            if item.body.trimmed.isEmpty { Text("No description").font(.system(size: 13)).foregroundStyle(HostedList.caption) }
            else { MarkdownView(item.body, target: store.target).font(.system(size: 13)) }
            if let error = store.collaboration.inboxError {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled)
            }
            Divider()
            Text("Activity").font(.system(size: 15, weight: .semibold))
            if detail.comments.isEmpty && !store.collaboration.inboxLoading {
                Text("No comments yet. Start the conversation.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
            }
            VStack(alignment: .leading, spacing: 20) {
                ForEach(detail.comments) { comment($0) }
            }
            if detail.more {
                Button("Load more comments") { Task { await store.openInboxItem(item, append: true) } }
                    .buttonStyle(HostedListTextButtonStyle()).disabled(busy)
            }
        }
    }

    private func comment(_ comment: CollaborationInboxComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: comment.author, email: comment.author, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: "@\(comment.author)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let date = ListDate.parse(comment.createdAt) {
                        Text(verbatim: ListDate.when(date, locale: locale)).font(.system(size: 12)).foregroundStyle(HostedList.caption).help(date.formatted(date: .long, time: .shortened))
                    }
                    if comment.author.caseInsensitiveCompare(item.author) == .orderedSame { StatusPill(title: String(localized: "Author"), tone: .neutral) }
                }
                if editing == comment.id {
                    TextEditor(text: $editText).font(.system(size: 13)).frame(minHeight: 100).accessibilityLabel("Edit comment").disabled(busy)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                    HStack(spacing: 8) {
                        Button("Save comment") { let value = editText; Task { if await store.changeIssueComment(item, comment: comment, body: value) { editing = nil } } }
                            .hostedListFilledButton().disabled(busy || editText.trimmed.isEmpty)
                        Button("Cancel") { editing = nil }.buttonStyle(HostedListButtonStyle()).disabled(busy)
                    }
                } else {
                    MarkdownView(comment.body, target: store.target).font(.system(size: 13))
                }
                HStack(spacing: 16) {
                    Button("Quote reply") {
                        draft += (draft.isEmpty ? "" : "\n\n") + IssueWorkflow.quote(author: comment.author, body: comment.body)
                        preview = false; composerFocused = true
                    }
                    .buttonStyle(HostedListTextButtonStyle()).disabled(busy)
                    if comment.editable {
                        Button("Edit") { editing = comment.id; editText = comment.body }
                            .buttonStyle(HostedListTextButtonStyle()).disabled(busy || editing != nil)
                        Button("Delete") { store.confirmDeleteIssueComment(item, comment: comment) }
                            .buttonStyle(HostedListTextButtonStyle(destructive: true)).disabled(busy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Cards

    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            IssueDevelopmentPanel(item: item)
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow(alignment: .top) {
                        fact("Assignees")
                        if item.assignees.isEmpty { none } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(item.assignees, id: \.self) { name in
                                    HStack(spacing: 6) {
                                        Avatar(name: name, email: name, size: 20)
                                        Text(verbatim: "@\(name)").lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                    GridRow(alignment: .top) {
                        fact("Labels")
                        if item.labels.isEmpty { none } else {
                            WorkbenchFlow(spacing: 4) { ForEach(item.labels, id: \.self) { label($0) } }
                        }
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Details")
        }
    }

    private func fact(_ title: LocalizedStringKey) -> some View {
        Text(title).foregroundStyle(HostedList.caption).frame(width: 84, alignment: .leading)
    }

    private var none: some View { Text("None").foregroundStyle(HostedList.caption) }

    /// A label is neutral; its colour is a dot beside the name, never the only sign
    private func label(_ label: IssueLabel) -> some View {
        HStack(spacing: 5) {
            if let color = label.color.flatMap(Self.color) { Circle().fill(color).frame(width: 8, height: 8) }
            Text(verbatim: label.name).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(StudioStyle.Tone.neutral.text)
        .padding(.horizontal, 8).frame(height: 18)
        .background(Capsule().fill(StudioStyle.Tone.neutral.fill))
    }

    /// GitHub names a label's colour "1f5a9e", GitLab "#1f5a9e"
    private static func color(_ hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    // MARK: Comment field

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if composing {
                Picker("Comment", selection: $preview) { Text("Write").tag(false); Text("Preview").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 210)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft).font(.system(size: 13)).focused($composerFocused).disabled(store.collaboration.inboxBusy)
                        .scrollContentBackground(.hidden).padding(.horizontal, 7).padding(.vertical, 9)
                        .opacity(preview ? 0 : 1).allowsHitTesting(!preview).accessibilityHidden(preview).accessibilityLabel("Comment")
                    if preview {
                        ScrollView {
                            if draft.trimmed.isEmpty { Text("Nothing to preview").foregroundStyle(HostedList.caption).frame(maxWidth: .infinity, alignment: .leading) }
                            else { MarkdownView(draft, target: store.target).font(.system(size: 13)) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    } else if draft.isEmpty {
                        Text("Write a comment…").font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 12).padding(.vertical, 9).allowsHitTesting(false)
                    }
                }
                .frame(height: composing ? 92 : 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(composerFocused ? Color.accentColor.opacity(0.7) : HostedList.edge))
                if store.collaboration.inboxBusy { ProgressView().controlSize(.small).frame(height: 28) }
                Button { store.confirmIssueState(item) } label: {
                    Label(isOpen ? String(localized: "Close issue…") : String(localized: "Reopen…"), systemImage: isOpen ? "checkmark.circle" : "arrow.uturn.backward.circle")
                }
                .buttonStyle(HostedListButtonStyle()).disabled(busy)
                Button("Comment") { send() }
                    .hostedListFilledButton()
                    .disabled(draft.trimmed.isEmpty || busy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(draft.trimmed.isEmpty ? String(localized: "A comment needs text") : "")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(StudioStyle.canvas)
    }

    private func send() {
        let sent = draft, id = item.id
        guard !sent.trimmed.isEmpty, !busy else { return }
        Task { if await store.inboxAction(item, action: "comment", body: sent), store.collaboration.inboxDetail?.item.id == id, draft == sent { draft = ""; preview = false } }
    }
}
