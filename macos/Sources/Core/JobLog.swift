import Foundation

/// Reading a CI job's log, shared by the Actions page and a request's Checks. (Windows: shared/lib/job-log.ts)
enum JobLog {
    private static let errorWord = try! NSRegularExpression(pattern: #"(^|[^A-Za-z_-])(error|fatal)([^A-Za-z_-]|$)"#, options: .caseInsensitive)
    private static let failWord = try! NSRegularExpression(pattern: #"(^|[^A-Za-z_-])FAIL(ED|URE)?([^A-Za-z_-]|$)"#)

    private static let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z "#)
    private static let colour = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    /// A log as a person reads it: without the runner's time stamps, colour codes and bookkeeping lines. A flag, a
    /// file name or a word like `--show-error` is not an error. (Windows: logLines)
    static func lines(_ log: String) -> [String] {
        log.components(separatedBy: "\n").compactMap { raw in
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            for pattern in [stamp, colour] {
                line = pattern.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            }
            guard line.hasPrefix("##["), let end = line.firstIndex(of: "]") else { return line }
            let rest = String(line[line.index(after: end)...])
            switch line[line.index(line.startIndex, offsetBy: 3)..<end] {
            case "group": return rest
            case "error": return "Error: " + rest
            case "warning": return "Warning: " + rest
            case "notice": return "Notice: " + rest
            default: return nil
            }
        }
    }

    /// A line the log marks: it names an error, or FAIL in capitals as test runners print it
    static func isError(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return errorWord.firstMatch(in: line, range: range) != nil || failWord.firstMatch(in: line, range: range) != nil
    }
}
