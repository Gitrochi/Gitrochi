import SwiftUI

/// Filename-first lookup keeps recent paths one shortcut away.
struct RepositoryQuickOpen: View {
    let paths: [String]
    let recent: [String]
    let width: CGFloat
    let open: (String) -> Void
    let close: () -> Void
    @ViewState private var query = ""
    @ViewState private var results: [String] = []
    @ViewState private var rankedQuery = ""
    @ViewState private var highlighted: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color.accentColor)
                TextField("Search files by name or path", text: $query).textFieldStyle(.plain)
                    .focused($focused).onSubmit(activate)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .accessibilityLabel("Search files by name or path").accessibilityIdentifier("code-quick-open-search")
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    .help("Close quick open").accessibilityLabel("Close quick open").keyboardShortcut(.cancelAction)
            }.padding(17)
            Divider()
            HStack { Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recent files" : "Files").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 17).padding(.vertical, 11)
            if results.isEmpty {
                ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass").frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(results, id: \.self) { path in
                                Button { open(path) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text((path as NSString).lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                        if highlighted == path { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(highlighted == path ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(path).help(path)
                                    .accessibilityIdentifier("code-quick-open-result-" + path)
                                    .accessibilityAddTraits(highlighted == path ? .isSelected : [])
                                    .onHover { if $0 { highlighted = path } }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 8)
                    }.onChange(of: highlighted) { _, value in if let value { proxy.scrollTo(value) } }
                }
            }
        }
        .frame(width: min(580, max(320, width - 40)), height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true; results = RepositoryCodeNavigation.rankedPaths(paths, query: "", recent: recent); highlighted = results.first }
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(80)) }
            guard !Task.isCancelled else { return }
            let all = paths, input = query, previous = recent
            let ranked = await Task.detached(priority: .userInitiated) { RepositoryCodeNavigation.rankedPaths(all, query: input, recent: previous) }.value
            guard !Task.isCancelled else { return }
            results = ranked; rankedQuery = input; highlighted = ranked.first
        }
        .onExitCommand(perform: close)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex(of: highlighted ?? "") ?? 0
        highlighted = results[min(max(index + delta, 0), results.count - 1)]
    }

    private func activate() {
        let path = rankedQuery == query ? highlighted : RepositoryCodeNavigation.rankedPaths(paths, query: query, recent: recent).first
        if let path { open(path) }
    }
}
