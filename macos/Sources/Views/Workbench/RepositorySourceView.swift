import SwiftUI
import AppKit

/// A selectable native reader keeps large blobs out of the SwiftUI view tree.
struct RepositorySourceView: NSViewRepresentable {
    let text: String
    let tokens: [RepositoryCodeReading.Token]
    let lineStarts: [Int]
    let fontSize: CGFloat
    let wraps: Bool
    let activeMatch: NSRange?
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = RepositoryCodeClipView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.usesFindBar = false
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel(String(localized: "Source"))
        view.minSize = .zero
        view.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        view.isVerticallyResizable = true
        scroll.documentView = view
        let ruler = RepositoryLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        ruler.wantsLayer = true
        ruler.layer?.masksToBounds = true
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = view
        context.coordinator.ruler = ruler
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak ruler] _ in ruler?.needsDisplay = true }
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        let changed = coordinator.text != text
        let styleChanged = changed || coordinator.fontSize != fontSize || coordinator.tokens != tokens || coordinator.lineStarts != lineStarts || coordinator.dark != (colorScheme == .dark)
        if styleChanged {
            let selection = view.selectedRanges
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.defaultTabInterval = fontSize * 2.4
            paragraph.tabStops = []
            // AppKit can overlay vertical rulers, so reserve the gutter in every paragraph.
            let gutterWidth = max(46, CGFloat(String(max(1, lineStarts.count)).count) * fontSize * 0.65 + 22)
            paragraph.firstLineHeadIndent = gutterWidth
            paragraph.headIndent = gutterWidth
            let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph])
            for token in tokens {
                let color: NSColor
                switch token.kind {
                case .comment: color = .secondaryLabelColor
                case .string: color = .systemGreen
                case .keyword: color = .systemPurple
                case .number: color = .systemOrange
                }
                let readable = token.kind == .comment ? color : color.blended(withFraction: colorScheme == .dark ? 0.15 : 0.35, of: colorScheme == .dark ? .white : .black) ?? color
                if NSMaxRange(token.range) <= value.length { value.addAttribute(.foregroundColor, value: readable, range: token.range) }
            }
            view.textStorage?.setAttributedString(value)
            if !changed { view.selectedRanges = selection }
            coordinator.text = text
            coordinator.fontSize = fontSize
            coordinator.tokens = tokens
            coordinator.lineStarts = lineStarts
            coordinator.dark = colorScheme == .dark
            coordinator.ruler?.lineStarts = lineStarts
            coordinator.ruler?.fontSize = fontSize
            coordinator.ruler?.ruleThickness = gutterWidth
            scroll.tile()
        }
        if coordinator.wraps != wraps || changed || styleChanged {
            scroll.hasHorizontalScroller = !wraps
            view.isHorizontallyResizable = !wraps
            view.autoresizingMask = wraps ? [.width] : []
            view.textContainer?.widthTracksTextView = wraps
            let width = max(1, scroll.contentSize.width)
            view.textContainer?.containerSize = NSSize(width: wraps ? max(1, width - 28) : 10_000_000, height: 10_000_000)
            view.setFrameSize(NSSize(width: width, height: max(1, scroll.contentSize.height)))
            view.sizeToFit()
            coordinator.wraps = wraps
        }
        if changed || styleChanged || coordinator.activeMatch != activeMatch {
            if let layout = view.layoutManager {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
                if let range = activeMatch, NSMaxRange(range) <= (text as NSString).length {
                    layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), forCharacterRange: range)
                    view.scrollRangeToVisible(range)
                }
            }
            coordinator.activeMatch = activeMatch
        }
        coordinator.ruler?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: NSTextView?
        fileprivate weak var ruler: RepositoryLineRuler?
        var scrollObserver: NSObjectProtocol?
        var text = ""
        var fontSize: CGFloat = 0
        var tokens: [RepositoryCodeReading.Token] = []
        var lineStarts: [Int] = []
        var dark = false
        var wraps: Bool?
        var activeMatch: NSRange?
        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    }
}

private final class RepositoryCodeClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        // The paragraph already reserves the overlay ruler's space.
        result.origin.x = max(0, result.origin.x)
        return result
    }
}

private final class RepositoryLineRuler: NSRulerView {
    var lineStarts: [Int] = []
    var fontSize: CGFloat = 13
    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let view = clientView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer, !lineStarts.isEmpty else { return }
        let visible = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let chars = layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] < chars.location { low = middle + 1 } else { high = middle }
        }
        let first = max(0, low - 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        for index in first..<lineStarts.count {
            guard lineStarts[index] <= NSMaxRange(chars), lineStarts[index] < (view.string as NSString).length else { break }
            let glyph = layout.glyphIndexForCharacter(at: lineStarts[index])
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view)
            let label = String(index + 1) as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 12, y: point.y + 1), withAttributes: attributes)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}
