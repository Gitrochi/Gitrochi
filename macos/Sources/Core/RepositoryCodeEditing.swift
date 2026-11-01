import Foundation

/// UTF-16 editing operations shared by the editable source view and its regression tests.
enum RepositoryCodeEditing {
    struct Edit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    static func indent(_ text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let source = text as NSString
        guard selection.location <= source.length, NSMaxRange(selection) <= source.length else { return nil }
        if selection.length == 0, !outdent {
            return Edit(range: selection, replacement: "  ", selection: NSRange(location: selection.location + 2, length: 0))
        }
        let selected = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let range = source.lineRange(for: selected)
        let original = source.substring(with: range)
        var lines = original.components(separatedBy: "\n")
        var removedFirst = 0
        for index in lines.indices {
            if index == lines.count - 1, lines[index].isEmpty, original.hasSuffix("\n") { continue }
            if outdent {
                let count = lines[index].hasPrefix("\t") ? 1 : min(2, lines[index].prefix { $0 == " " }.count)
                if index == 0 { removedFirst = count }
                lines[index] = String(lines[index].dropFirst(count))
            } else { lines[index] = "  " + lines[index] }
        }
        let replacement = lines.joined(separator: "\n")
        let nextSelection = selection.length == 0
            ? NSRange(location: max(range.location, selection.location - removedFirst), length: 0)
            : NSRange(location: range.location, length: (replacement as NSString).length)
        return Edit(range: range, replacement: replacement, selection: nextSelection)
    }

    static func newline(_ text: String, selection: NSRange) -> Edit? {
        let source = text as NSString
        guard selection.location <= source.length, NSMaxRange(selection) <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indentation = String(before.prefix { $0 == " " || $0 == "\t" })
        let replacement = (text.contains("\r\n") ? "\r\n" : "\n") + indentation
        return Edit(range: selection, replacement: replacement,
                    selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
    }
}
