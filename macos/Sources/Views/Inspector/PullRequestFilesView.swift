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
    @AppStorage(requestFileViewModeKey) private var mode = "tree"
    @ViewState private var collapsed = Set<String>()
    @ViewState private var viewed = Set<String>()
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
                FileViewToggle(key: requestFileViewModeKey, fallback: "tree")
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
                                if let file = review.files.first(where: { $0.path == change.path }) { fileRow(file, review, indent: FileTree.fileIndent(depth: row.depth), folder: false) }
                            }
                        }
                    } else {
                        ForEach(review.files) { fileRow($0, review, indent: 8, folder: true) }
                    }
                    // the line comments waiting to be sent stay with the files
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
        return FileFolderRow(name: name, count: count, depth: depth, expanded: open) {
            if open { collapsed.insert(path) } else { collapsed.remove(path) }
        }
    }

    /// The shared file row with the review's marks: threads, the counts where there is room for them, and Viewed
    private func fileRow(_ file: ReviewFile, _ review: PullRequestReview, indent: CGFloat, folder: Bool) -> some View {
        let isViewed = viewed.contains(file.path)
        return FileRow(change: file.change, selected: openPath == file.path, showDirectory: folder,
                       // a compact row has no room for the counts: they are in the tip
                       stat: compact || file.patch == nil ? nil : LineStat(added: file.additions, deleted: file.deletions),
                       note: compact || file.patch != nil ? nil : file.additions + file.deletions > 0 ? String(localized: "Too large") : String(localized: "Binary"),
                       dimmed: isViewed,
                       threads: PullRequestPage.threadCount(review.comments, path: file.path),
                       indent: indent,
                       viewed: isViewed, setViewed: { setViewed(file.path, $0) },
                       open: { store.openReviewFile(number, file) },
                       space: { setViewed(file.path, !isViewed) },
                       tip: file.patch == nil ? String(localized: "Binary or too large — view it in the browser") : "\(file.path)  +\(file.additions) −\(file.deletions)")
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

    /// The shared diff header of docs/design.md; the request's files carry their own position
    private func diffHeader(_ file: ReviewFile, index: Int, count: Int, splitAllowed: Bool) -> some View {
        DiffHeader(kind: file.kind, path: file.path, position: CodeFilePosition(index: index, count: count, step: step),
                   splitDisabledReason: splitAllowed ? nil : String(localized: "Split needs a diff at least 1000 px wide"),
                   ask: .init(disabled: store.diffLoading || store.diff?.isBinary == true) { Task { await store.openChangeQuestion() } }) {
            Button("Show in Finder") { store.revealInFinder(file.change) }
            Button("Copy path") { store.copy(file.path) }
        }
    }
}

/// J and K step through the files unless something is being typed (Pull requests' Changed files and Compare)
@MainActor final class FileKeys {
    private var monitor: Any?

    func start(_ step: @escaping (Bool) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased(), key == "j" || key == "k",
                  // a field editor and the terminal both take text: the letters are theirs
                  let window = event.window, window.attachedSheet == nil, !(window.firstResponder is NSTextInputClient) else { return event }
            step(key == "j")
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
