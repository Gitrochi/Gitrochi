import SwiftUI
import AppKit

/// Reading controls are independent of Git requests and never modify the file.
struct RepositoryCodeReader: View {
    let text: String
    let path: String
    let syntax: Bool
    @Binding var fontSize: CGFloat
    @Binding var wraps: Bool
    @Binding var findText: String
    @Binding var matchIndex: Int
    @ViewState private var tokens: [RepositoryCodeReading.Token] = []
    @ViewState private var starts: [Int] = []
    @ViewState private var matches: [NSRange] = []
    @ViewState private var truncatedMatches = false
    @ViewState private var copied = false
    @FocusState private var findFocused: Bool

    private struct Document: Equatable { let text: String; let path: String; let syntax: Bool }
    private struct Search: Equatable { let text: String; let query: String }
    private var activeMatch: NSRange? { matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }
    private var counter: String {
        guard !findText.isEmpty else { return "" }
        if matches.isEmpty { return String(localized: "No matches") }
        return String(localized: "{0} of {1}").replacingOccurrences(of: "{0}", with: (matchIndex + 1).formatted()).replacingOccurrences(of: "{1}", with: matches.count.formatted() + (truncatedMatches ? "+" : ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { findFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command).help("Find in file").accessibilityLabel("Find in file")
                TextField("Find in file", text: $findText).textFieldStyle(.plain).focused($findFocused)
                    .onSubmit { advance(1) }.accessibilityLabel("Find in file")
                if !findText.isEmpty {
                    Text(counter).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    Button { advance(-1) } label: { Image(systemName: "chevron.up") }.disabled(matches.isEmpty).help("Previous match").accessibilityLabel("Previous match")
                    Button { advance(1) } label: { Image(systemName: "chevron.down") }.disabled(matches.isEmpty).help("Next match").accessibilityLabel("Next match")
                    Button { findText = "" } label: { Image(systemName: "xmark") }.help("Clear search").accessibilityLabel("Clear search")
                }
            }.buttonStyle(.borderless).font(.callout).padding(.horizontal, 14).padding(.vertical, 11)
            Divider()
            if truncatedMatches {
                Text("More than 10,000 matches. Refine your search.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            RepositorySourceView(text: text, tokens: tokens, lineStarts: starts, fontSize: fontSize, wraps: wraps, activeMatch: activeMatch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            WorkbenchFlow(spacing: 12) {
                Label(LocalizedStringKey(syntax ? RepositoryCodeReading.language(for: path) : "Plain text"), systemImage: "chevron.left.forwardslash.chevron.right")
                Text(verbatim: String(localized: "{0} lines").replacingOccurrences(of: "{0}", with: starts.count.formatted()))
                Label("Read only", systemImage: "lock")
                Button { wraps.toggle() } label: {
                    Image(systemName: "text.word.spacing").foregroundStyle(wraps ? Color.accentColor : .secondary)
                }.help("Wrap lines").accessibilityLabel("Wrap lines").accessibilityValue(wraps ? String(localized: "On") : String(localized: "Off"))
                HStack(spacing: 6) {
                    Button { fontSize = max(11, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }.disabled(fontSize <= 11).help("Decrease font size").accessibilityLabel("Decrease font size")
                    Text("\(Int(fontSize))").monospacedDigit().frame(minWidth: 15)
                    Button { fontSize = min(20, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }.disabled(fontSize >= 20).help("Increase font size").accessibilityLabel("Increase font size")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .help(copied ? String(localized: "Copied") : String(localized: "Copy source"))
                    .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy source"))
            }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .task(id: Document(text: text, path: path, syntax: syntax)) {
            tokens = []; starts = []; copied = false
            let input = text, inputPath = path, shouldStyle = syntax
            let result = await Task.detached(priority: .userInitiated) {
                (RepositoryCodeReading.lineStarts(in: input), shouldStyle ? RepositoryCodeReading.tokens(in: input, path: inputPath) : [])
            }.value
            guard !Task.isCancelled else { return }
            starts = result.0; tokens = result.1
        }
        .task(id: Search(text: text, query: findText)) {
            matches = []; matchIndex = 0; truncatedMatches = false
            guard !findText.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let input = text, query = findText
            let result = await Task.detached(priority: .userInitiated) { RepositoryCodeReading.matches(in: input, query: query) }.value
            guard !Task.isCancelled else { return }
            truncatedMatches = result.count > 10_000
            matches = Array(result.prefix(10_000))
        }
        .onChange(of: copied) { _, value in
            guard value else { return }
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        }
        .onExitCommand { if findFocused { findText = "" } }
    }

    private func advance(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
    }
}
