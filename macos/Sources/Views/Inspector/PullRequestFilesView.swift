import SwiftUI
import AppKit

/// A request's Changed files, as the redesign's board draws it: the file tree (340pt, 280pt when compact) beside the
/// open file's diff under a 44pt header. The diff itself is the shared DiffView without its own header.
/// Windows: PullRequestFilesView.tsx.
struct PullRequestFilesView: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    /// The list column is showing or the page is narrow: a narrower tree, no +/- counts in its rows
    let compact: Bool
    /// Changed files is the visible tab: J and K step through the files and the first file opens
    let active: Bool
    /// The repository's inspector has no room for a diff: the tree alone, and a file opens on the Pull requests page
    var treeOnly = false
    @AppStorage(fileViewModeKey) private var mode = "list"
    @ViewState private var collapsed = Set<String>()
    @ViewState private var viewed = Set<String>()
    @ViewState private var hovered: String?
    @ViewState private var keys = FileKeys()
    /// The file that was open when the tab was left, to come back to
    @ViewState private var lastPath: String?

    private var review: PullRequestReview? { store.review?.number == number ? store.review : nil }
    private var openPath: String? {
        if case .review(let n, let change, _)? = store.diffSource, n == number { return change.path }
        return nil
    }
    private var viewedKey: String? { review.map { PullRequestPage.viewedKey(repositoryKey: $0.repositoryKey, number: number, headSHA: $0.headSHA) } }

    var body: some View {
        Group {
            if let review {
                if review.files.isEmpty {
                    PullRequestCaption(String(localized: "No changed files")).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    if treeOnly {
                        tree(review).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                    GeometryReader { geometry in
                        // too narrow for the tree beside a readable diff: the tree goes on top
                        let width = PullRequestPage.treeWidth(compact: compact), stacked = geometry.size.width < width + 480
                        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                        layout {
                            tree(review)
                                .frame(width: stacked ? nil : width, height: stacked ? max(150, min(260, geometry.size.height * 0.4)) : nil)
                                .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity, alignment: .top)
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
                            diff(review).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    }
                }
            } else if store.reviewLoading {
                ProgressView().controlSize(.small).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
            }
        }
        .onChange(of: active, initial: true) { _, _ in sync() }
        .onChange(of: review?.headSHA, initial: true) { _, _ in
            viewed = viewedKey.map(PullRequestViewedStorage.load) ?? []
            sync()
        }
        .onChange(of: openPath) { _, path in if let path { lastPath = path } }
        .onDisappear { keys.stop() }
    }

    /// While the tab shows, a file of this request is open (the first one to begin with) and J / K step through them
    private func sync() {
        guard active, !treeOnly, let review else { keys.stop(); return }
        let files = ordered(review)
        if openPath == nil || !files.contains(where: { $0.path == openPath }), let first = files.first(where: { $0.path == lastPath }) ?? files.first {
            store.openReviewFile(number, first)
        }
        keys.start { forward in step(forward ? 1 : -1) }
    }

    /// The files in the order the tree draws them, so "2 / 6", J and K follow what is on screen
    private func ordered(_ review: PullRequestReview) -> [ReviewFile] {
        guard mode == "tree" else { return review.files }
        return FileTree.rows(review.files.map(\.change), collapsed: []).compactMap { row in
            if case .file(let change) = row.kind { return review.files.first { $0.path == change.path } }
            return nil
        }
    }

    private func step(_ offset: Int) {
        guard let files = review.map(ordered), let index = files.firstIndex(where: { $0.path == openPath }), files.indices.contains(index + offset) else { return }
        store.openReviewFile(number, files[index + offset])
    }

    private func setViewed(_ path: String, _ on: Bool) {
        if on { viewed.insert(path) } else { viewed.remove(path) }
        if let viewedKey { PullRequestViewedStorage.save(viewedKey, viewed) }
    }

    // MARK: Tree

    private func tree(_ review: PullRequestReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PullRequestCaption(String(localized: "\(viewed.intersection(review.files.map(\.path)).count) viewed"))
                Spacer(minLength: 8)
                FileViewToggle()
            }
            .padding(.leading, 6)
            .frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if mode == "tree" {
                        ForEach(FileTree.rows(review.files.map(\.change), collapsed: collapsed)) { row in
                            switch row.kind {
                            case .folder(let path, let name, let files): folderRow(path: path, name: name, count: files.count, depth: row.depth)
                            case .file(let change):
                                if let file = review.files.first(where: { $0.path == change.path }) { fileRow(file, review, indent: 6 + CGFloat(row.depth) * 14 + 18, folder: false) }
                            }
                        }
                    } else {
                        ForEach(review.files) { fileRow($0, review, indent: 6, folder: true) }
                    }
                    // how to comment on a line, and the line comments waiting to be sent, stay with the files
                    ReviewDraftPanel(number: number).padding(.top, 12).padding(.horizontal, 6)
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }

    private func folderRow(path: String, name: String, count: Int, depth: Int) -> some View {
        let open = !collapsed.contains(path)
        return Button { if open { collapsed.insert(path) } else { collapsed.remove(path) } } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 12)
                DesignIconImage(icon: .repository, size: 11).foregroundStyle(StudioStyle.Rail.icon)
                Text(verbatim: name).fontWeight(.medium).lineLimit(1).truncationMode(.head)
                // a folder holding a single file needs no count
                if count > 1 { StatusPill(title: String(count), symbol: nil, tone: .neutral) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.leading, 6 + CGFloat(depth) * 14).padding(.trailing, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered == "d:" + path ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? "d:" + path : (hovered == "d:" + path ? nil : hovered) }
    }

    private func fileRow(_ file: ReviewFile, _ review: PullRequestReview, indent: CGFloat, folder: Bool) -> some View {
        let selected = openPath == file.path, isViewed = viewed.contains(file.path)
        let name = (file.path as NSString).lastPathComponent
        let threads = PullRequestPage.threadCount(review.comments, path: file.path)
        let secondary = selected ? Color.primary.opacity(0.72) : StudioStyle.Rail.icon
        return HStack(spacing: 6) {
            Button { store.openReviewFile(number, file) } label: {
                HStack(spacing: 6) {
                    StatusBadge(kind: file.kind)
                    // a rename's old name gives way first; the file name is never cut
                    if let old = file.oldPath, old != file.path {
                        Text(verbatim: (old as NSString).lastPathComponent + " →").font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).layoutPriority(-1)
                    }
                    Text(verbatim: name).fontWeight(selected ? .semibold : .regular).lineLimit(1).fixedSize()
                    if folder {
                        PullRequestFolderLabel(path: file.path, color: secondary).layoutPriority(-2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.path)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if threads > 0 {
                HStack(spacing: 4) {
                    DesignIconImage(icon: .comment, size: 10)
                    Text(verbatim: String(threads)).font(.system(size: 11))
                }
                .foregroundStyle(secondary).fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(threads == 1 ? String(localized: "1 thread") : String(localized: "\(threads) threads"))
            }
            if !compact { LineStatText(added: file.additions, deleted: file.deletions).fixedSize() }
            Button { setViewed(file.path, !isViewed) } label: {
                Image(systemName: isViewed ? "checkmark.square.fill" : "square").font(.system(size: 14))
                    .foregroundStyle(isViewed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Viewed \(name)")
            .accessibilityLabel("Viewed \(name)")
            .accessibilityValue(isViewed ? "On" : "Off")
        }
        .font(.system(size: 13))
        .padding(.leading, indent).padding(.trailing, 2)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hovered == file.path ? StudioStyle.hover : Color.clear))
        .onHover { hovered = $0 ? file.path : (hovered == file.path ? nil : hovered) }
        // the counts a compact row has no room for
        .help(Text(verbatim: file.patch == nil ? String(localized: "Binary or too large — view it in the browser") : "\(file.path)  +\(file.additions) −\(file.deletions)"))
    }

    // MARK: Diff

    @ViewBuilder private func diff(_ review: PullRequestReview) -> some View {
        let files = ordered(review)
        if let source = store.diffSource, case .review(let n, let change, _) = source, n == number,
           let index = files.firstIndex(where: { $0.path == change.path }) {
            GeometryReader { geometry in
                let allowed = PullRequestPage.splitAllowed(diffWidth: geometry.size.width)
                VStack(spacing: 0) {
                    diffHeader(files[index], index: index, count: files.count, splitAllowed: allowed)
                    Divider()
                    DiffView(source: source, chrome: false, splitAllowed: allowed)
                }
            }
        } else {
            Color.clear
        }
    }

    /// The shared diff header of docs/design.md: badge, file name and folder; position and stepping; layout, whitespace, Ask AI, more
    private func diffHeader(_ file: ReviewFile, index: Int, count: Int, splitAllowed: Bool) -> some View {
        let _ = store.diffSettingsVersion
        let whitespace = store.diffIgnoreWhitespace
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                StatusBadge(kind: file.kind)
                Text(verbatim: (file.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                PullRequestFolderLabel(path: file.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text(verbatim: "\(index + 1) / \(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).padding(.trailing, 4).fixedSize()
                Button { step(-1) } label: { DesignIconImage(icon: .chevronUp) }
                    .buttonStyle(PullRequestIconButtonStyle()).disabled(index == 0)
                    .help("Previous file (K)").accessibilityLabel("Previous file (K)")
                Button { step(1) } label: { DesignIconImage(icon: .chevronDown) }
                    .buttonStyle(PullRequestIconButtonStyle()).disabled(index + 1 >= count)
                    .help("Next file (J)").accessibilityLabel("Next file (J)")
            }
            PullRequestSegmented(label: "Diff layout", items: [
                .init(value: false, title: String(localized: "Unified")),
                .init(value: true, title: String(localized: "Split"), disabledReason: splitAllowed ? nil : String(localized: "Split needs a diff at least 1000 px wide")),
            ], selection: store.diffSplit && splitAllowed) { store.diffSplit = $0 }
            Button { store.diffIgnoreWhitespace.toggle() } label: { Image(systemName: "text.word.spacing") }
                .buttonStyle(PullRequestIconButtonStyle(on: whitespace))
                .help("Hide whitespace")
                .accessibilityLabel("Hide whitespace")
                .accessibilityValue(whitespace ? "On" : "Off")
                .accessibilityAddTraits(whitespace ? .isSelected : [])
            Button("Ask AI…") { Task { await store.openChangeQuestion() } }
                .buttonStyle(PullRequestTextButtonStyle())
                .disabled(store.diffLoading || store.diff?.isBinary == true)
                .help("Ask questions about the selected changes")
            Menu {
                Button("Show in Finder") { store.revealInFinder(file.change) }
                Button("Copy path") { store.copy(file.path) }
            } label: {
                DesignIconImage(icon: .more, size: 12).foregroundStyle(StudioStyle.Tone.neutral.text)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More file actions").accessibilityLabel("More file actions")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

/// J and K step through the files unless something is being typed
@MainActor private final class FileKeys {
    private var monitor: Any?

    func start(_ step: @escaping (Bool) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased(), key == "j" || key == "k",
                  let window = event.window, window.attachedSheet == nil, !(window.firstResponder is NSText) else { return event }
            step(key == "j")
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
