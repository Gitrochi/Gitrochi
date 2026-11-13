import SwiftUI
import AppKit

// One form for a failed check, its log and the heads of the groups checks are listed in (docs/design.md, Shared
// components): pull request checks, Actions and Flows draw these. (Windows: shared/ui/FailedCheckBlock.tsx)

/// The setting "Wrap long lines" turns on; without it only the lines that report a failure wrap
private let checkLogWrapKey = "ciLogWrap"

/// One more entry of a failed check's ⋯ menu, after Wrap long lines and Copy log
struct CheckMenuItem {
    let title: String
    var disabled = false
    /// A divider comes before it
    var separated = false
    let run: () -> Void
}

/// What a failed check offers; whatever is left nil is not drawn
struct FailedCheckActions {
    var jump: (() -> Void)? = nil
    /// A button only one page needs (Load log), placed before Re-run
    var extra: (title: String, disabled: Bool, run: () -> Void)? = nil
    var rerun: (title: String, disabled: Bool, run: () -> Void)? = nil
    var open: (() -> Void)? = nil
    /// ⋯ is drawn with Wrap long lines and Copy log; `copy` is nil while there is no log to copy
    var menu = false
    var copy: (() -> Void)? = nil
    var more: [CheckMenuItem] = []
    var moreLabel = String(localized: "More job actions")

    var isEmpty: Bool { jump == nil && extra == nil && rerun == nil && open == nil && !menu }
}

/// A bordered card, a pane that fills its column under a ruled header, or the bare parts
enum FailedCheckForm { case card, pane, plain }

/// What failed and what to do about it: the status icon, the job's name, "Failed after 3m 12s" in the failed tone and
/// a 12 pt caption naming the failed tests; then Jump to first error, Re-run job, open in browser and ⋯. The actions
/// drop below the words in a narrow column. The log goes in as its content.
struct FailedCheckBlock<Icon: View, Content: View>: View {
    var form = FailedCheckForm.plain
    /// Left out where the column's own header names the job or step
    var name: String? = nil
    let outcome: String
    /// The outcome takes the failed tone; a job that did not fail keeps the header in neutral words
    var failed = true
    /// The failed tests by name: "1 test failed: SearchTests.testQuery"
    var tests: [String] = []
    /// What the caption says when no test is named: the server's own summary
    var caption: String? = nil
    var busy = false
    var actions = FailedCheckActions()
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch form {
        case .card:
            VStack(alignment: .leading, spacing: 0) {
                head.padding(.horizontal, 12).padding(.vertical, 10)
                content()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        case .pane:
            VStack(alignment: .leading, spacing: 0) {
                head.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .plain:
            VStack(alignment: .leading, spacing: 8) {
                head
                content()
            }
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 4) {
            if actions.isEmpty {
                words
            } else {
                // the words keep their width: in a narrow column the actions drop below them and wrap
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { title; Spacer(minLength: 8); HStack(spacing: 6) { buttons }.fixedSize() }
                    VStack(alignment: .leading, spacing: 6) {
                        words
                        WorkbenchFlow(spacing: 6) { buttons }
                    }
                }
            }
            if !tests.isEmpty {
                (Text(verbatim: (tests.count == 1 ? String(localized: "1 test failed:") : String(localized: "\(tests.count) tests failed:")) + " ")
                    + Text(verbatim: JobLog.testNames(tests)).font(.system(size: 11, design: .monospaced)))
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.leading, 22)
            } else if let caption, !caption.isEmpty {
                Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Icon, name and outcome on one line
    private var title: some View {
        HStack(spacing: 8) {
            icon()
            if let name { nameText(name).lineLimit(1) }
            outcomeText
            if busy { ProgressView().controlSize(.mini) }
        }
    }

    /// The same words where the line is short: a long name wraps, and the outcome goes below it
    private var words: some View {
        WorkbenchFlow(spacing: 8) {
            if let name {
                HStack(alignment: .firstTextBaseline, spacing: 8) { icon(); nameText(name).fixedSize(horizontal: false, vertical: true) }
            } else {
                icon()
            }
            outcomeText
            if busy { ProgressView().controlSize(.mini) }
        }
    }

    private func nameText(_ name: String) -> some View {
        Text(verbatim: name).font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
    }

    /// The failed tone on words that say it failed; the icon says it too
    private var outcomeText: some View {
        Text(verbatim: outcome).font(.system(size: 12)).foregroundStyle(failed ? StudioStyle.Tone.failed.text : HostedList.caption)
            .lineLimit(1).fixedSize()
    }

    @ViewBuilder private var buttons: some View {
        if let jump = actions.jump {
            Button("Jump to first error", action: jump).buttonStyle(HostedListButtonStyle())
        }
        if let extra = actions.extra {
            Button(extra.title, action: extra.run).buttonStyle(HostedListButtonStyle()).disabled(extra.disabled)
        }
        if let rerun = actions.rerun {
            Button(action: rerun.run) { Label(rerun.title, symbol: "arrow.clockwise") }
                .buttonStyle(HostedListButtonStyle()).disabled(rerun.disabled)
        }
        if let open = actions.open {
            Button(action: open) { Label("Open in browser", symbol: "arrow.up.right.square") }
                .buttonStyle(HostedListButtonStyle(iconOnly: true))
                .help("Open in browser").accessibilityLabel("Open in browser")
        }
        if actions.menu {
            CheckLogMenu(label: actions.moreLabel, copy: actions.copy, more: actions.more)
        }
    }
}

/// ⋯ on a log: Wrap long lines and Copy log first, then what the page adds (Windows: checkLogMenu)
struct CheckLogMenu: View {
    var label = String(localized: "More job actions")
    /// Nil while there is no log to copy
    var copy: (() -> Void)? = nil
    var more: [CheckMenuItem] = []
    @AppStorage(checkLogWrapKey) private var wrap = false

    var body: some View {
        Menu {
            Toggle("Wrap long lines", isOn: $wrap)
            Button("Copy log") { copy?() }.disabled(copy == nil)
            ForEach(more.indices, id: \.self) { index in
                let item = more[index]
                if item.separated { Divider() }
                Button(item.title, action: item.run).disabled(item.disabled)
            }
        } label: {
            DesignIconImage(icon: .more, size: 12).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(label).accessibilityLabel(label)
    }
}

extension FailedCheckBlock where Content == EmptyView {
    /// The header alone, where the log sits elsewhere on the page
    init(form: FailedCheckForm = .plain, name: String? = nil, outcome: String, failed: Bool = true, tests: [String] = [], caption: String? = nil,
         busy: Bool = false, actions: FailedCheckActions = FailedCheckActions(), @ViewBuilder icon: @escaping () -> Icon) {
        self.init(form: form, name: name, outcome: outcome, failed: failed, tests: tests, caption: caption, busy: busy, actions: actions, icon: icon) { EmptyView() }
    }
}

/// The head of a group of checks: "Failed", "Passed 5". The count is left out where a tab already shows it. With
/// `open` the head folds its group, and what it is given (the passed jobs' names) follows the title.
struct CheckGroupHead<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var open: Binding<Bool>? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if let open {
            Button { open.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    SymbolIcon(open.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                    words
                    trailing()
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) { words; trailing() }
        }
    }

    private var words: some View {
        Text(verbatim: count.map { "\(title) \($0)" } ?? title)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption).fixedSize()
    }
}

extension CheckGroupHead where Trailing == EmptyView {
    init(title: String, count: Int? = nil, open: Binding<Bool>? = nil) {
        self.init(title: title, count: count, open: open) { EmptyView() }
    }
}

/// Numbered log lines. The lines that report a failure wrap and stand out in the failed tone; the others keep their
/// length and scroll sideways, under a fade on the right edge while there is more that way. A log opens a few lines
/// before its first error; one without an error opens on its end and follows it.
struct CheckLog: View {
    /// What VoiceOver calls the region
    let label: String
    let lines: [JobLog.Line]
    /// Counts presses of Jump to first error
    var jump = 0
    /// The log is still being written: it follows its end whatever it holds
    var follow = false
    var truncated = false
    /// Takes the height it is given; otherwise it fits its lines up to 320 pt and scrolls beyond
    var fill = false
    /// Its own hairline and corners, where no card around it gives them
    var framed = false
    @AppStorage(checkLogWrapKey) private var wrap = false
    /// The lines before the part the log opens on are shown on request
    @ViewState private var all = false
    @ViewState private var measured: CGFloat?
    @ViewState private var more = false

    var body: some View {
        let first = all ? 0 : JobLog.firstShown(lines)
        let shown = Array(lines[first...])
        VStack(alignment: .leading, spacing: 0) {
            if truncated {
                Text("Log preview is limited to 2 MB. Open the browser for the complete log.")
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.top, 6)
            }
            if first > 0 {
                Button("Show \(first) earlier lines") { all = true }
                    .buttonStyle(HostedListTextButtonStyle()).padding(.leading, 56).padding(.top, 4)
            }
            if lines.isEmpty {
                Text("No log output yet.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            } else {
                CheckLogText(lines: shown, wrap: wrap, jump: jump, follow: follow, measures: !fill) { height, more in
                    if !fill, measured != height { measured = height }
                    if self.more != more { self.more = more }
                }
                .frame(height: fill ? nil : min(320, measured ?? CGFloat(shown.count) * CheckLogText.lineHeight + 12))
                .frame(maxHeight: fill ? .infinity : nil)
                .overlay(alignment: .trailing) {
                    if more {
                        LinearGradient(colors: [StudioStyle.canvas.opacity(0), StudioStyle.canvas], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 12).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.canvas)
        .clipShape(RoundedRectangle(cornerRadius: framed ? 6 : 0))
        .overlay { if framed { RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Read-only monospaced text with line numbers; a SwiftUI Text is slow with a log of thousands of lines.
private struct CheckLogText: NSViewRepresentable {
    static let lineHeight: CGFloat = 20

    let lines: [JobLog.Line]
    let wrap: Bool
    let jump: Int
    let follow: Bool
    /// Whether the height of the text is worth working out (a log that fills its pane has no use for it)
    let measures: Bool
    /// The height of the text, and whether there is more of it to the right of what shows
    let report: (CGFloat, Bool) -> Void

    final class Coordinator: NSObject {
        var signature = ""
        var jump = 0
        var wrap: Bool?
        var measures = false
        var report: (CGFloat, Bool) -> Void = { _, _ in }
        /// Where the lines that report a failure are, so they can be fitted to the width that shows
        var errors: [NSRange] = []
        var limit: CGFloat = 0
        var last: (CGFloat, Bool)?
        weak var scroll: NSScrollView?

        @objc func changed(_ note: Notification) {
            guard let scroll else { return }
            fit(scroll)
            measure(scroll)
        }

        /// A line that reports a failure wraps at the width that shows, so it is never cut; the rest keep their length
        func fit(_ scroll: NSScrollView) {
            guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
            let padding = view.textContainer?.lineFragmentPadding ?? 5
            let width = wrap == true ? 0 : max(160, scroll.contentSize.width - view.textContainerInset.width * 2 - padding * 2)
            guard abs(width - limit) > 0.5 else { return }
            limit = width
            guard !errors.isEmpty else { return }
            storage.beginEditing()
            for range in errors where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.paragraphStyle, value: CheckLogText.style(gutter: gutter, wrapAt: width), range: range)
            }
            storage.endEditing()
        }

        var gutter: CGFloat = 0

        func measure(_ scroll: NSScrollView) {
            guard let view = scroll.documentView as? NSTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
            var height: CGFloat = 0
            if measures {
                manager.ensureLayout(for: container)
                height = ceil(manager.usedRect(for: container).height + view.textContainerInset.height * 2)
            }
            let visible = scroll.contentView.bounds
            let more = wrap == false && view.frame.width > visible.maxX + 1
            if let last, last.0 == height, last.1 == more { return }
            last = (height, more)
            let report = report
            // SwiftUI state must not change while the view is being updated
            DispatchQueue.main.async { report(height, more) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.textContainer?.replaceLayoutManager(CheckLogLayoutManager())
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 11, height: 6)
        }
        let state = context.coordinator
        state.jump = jump
        state.scroll = scroll
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(state, selector: #selector(Coordinator.changed(_:)), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(state, selector: #selector(Coordinator.changed(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let state = context.coordinator
        state.report = report
        state.measures = measures
        if state.wrap != wrap {
            // a new text view wraps already; only a change, or no wrapping, needs setting up
            let changed = state.wrap != nil
            state.wrap = wrap
            if !wrap {
                // unwrapped lines scroll sideways
                scroll.hasHorizontalScroller = true
                view.isHorizontallyResizable = true
                view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                view.textContainer?.widthTracksTextView = false
                view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            } else if changed {
                scroll.hasHorizontalScroller = false
                view.isHorizontallyResizable = false
                view.frame.size.width = scroll.contentSize.width
                view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                view.textContainer?.widthTracksTextView = true
            }
            state.limit = -1
        }
        let signature = "\(lines.first?.number ?? 0)|\(lines.count)|\(lines.last?.text.hashValue ?? 0)|\(lines.first?.text.hashValue ?? 0)"
        if state.signature != signature {
            let hasError = lines.contains(where: \.isError)
            let following = (follow || !hasError) && (view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.height - 8)
            // an append keeps the reader's sideways position; a log's first fill opens at its line numbers
            let column = view.string.isEmpty ? 0 : scroll.contentView.bounds.origin.x
            let text = Self.attributed(lines)
            state.signature = signature
            state.errors = text.errors
            state.gutter = text.gutter
            state.limit = -1
            view.textStorage?.setAttributedString(text.string)
            state.fit(scroll)
            if following { view.scrollToEndOfDocument(nil); Self.showColumn(column, in: scroll) }
        } else {
            state.fit(scroll)
        }
        if state.jump != jump {
            state.jump = jump
            if let error = state.errors.first { view.scrollRangeToVisible(error); Self.showColumn(0, in: scroll) }
        }
        state.measure(scroll)
    }

    /// Scrolling to a line also moves sideways to where that line ends; a log is read from its line numbers
    private static func showColumn(_ x: CGFloat, in scroll: NSScrollView) {
        var origin = scroll.contentView.bounds.origin
        guard origin.x != x else { return }
        origin.x = x
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Lines are 20 pt tall; a wrapped line continues under its text, not under its number
    static func style(gutter: CGFloat, wrapAt width: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.headIndent = gutter
        // a positive tail indent is measured from the leading edge: the line wraps there whatever the container's width
        style.tailIndent = width
        return style
    }

    /// The numbered lines, with the ranges of the ones that report a failure and the width of the number column
    private static func attributed(_ lines: [JobLog.Line]) -> (string: NSAttributedString, errors: [NSRange], gutter: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let digits = max(3, String(lines.last?.number ?? 0).count)
        let gutter = ceil(("0" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits + 2))
        let paragraph = style(gutter: gutter)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        var marked = plain
        marked[.foregroundColor] = NSColor(StudioStyle.Tone.failed.text)
        marked[.checkLogErrorLine] = true
        var markedNumber = marked
        markedNumber[.foregroundColor] = NSColor.secondaryLabelColor
        let out = NSMutableAttributedString()
        var errors: [NSRange] = []
        for (index, line) in lines.enumerated() {
            let label = String(line.number)
            let start = out.length
            out.append(NSAttributedString(string: String(repeating: " ", count: max(0, digits - label.count)) + label + "  ", attributes: line.isError ? markedNumber : number))
            out.append(NSAttributedString(string: line.text + (index == lines.count - 1 ? "" : "\n"), attributes: line.isError ? marked : plain))
            if line.isError { errors.append(NSRange(location: start, length: out.length - start)) }
        }
        return (out, errors, gutter)
    }
}

private extension NSAttributedString.Key {
    static let checkLogErrorLine = NSAttributedString.Key("checkLogErrorLine")
}

/// Draws the failed tone across a whole line, not only behind its text
private final class CheckLogLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange range: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: range, at: origin)
        guard let storage = textStorage else { return }
        NSColor(StudioStyle.Tone.failed.fill).setFill()
        enumerateLineFragments(forGlyphRange: range) { rect, _, _, glyphs, _ in
            let location = self.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
            guard location < storage.length, storage.attribute(.checkLogErrorLine, at: location, effectiveRange: nil) != nil else { return }
            NSRect(x: 0, y: rect.minY + origin.y, width: 100_000, height: rect.height).fill()
        }
    }
}
