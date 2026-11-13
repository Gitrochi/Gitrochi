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

    /// One line of a log as the failed-check block draws it (Windows: LogLine)
    struct Line: Identifiable, Equatable {
        let number: Int
        let text: String
        let isError: Bool
        var id: Int { number }
    }

    private static let exitCode = try! NSRegularExpression(pattern: #"exit code [1-9]"#)

    /// Lines numbered from 1; the ones that report a failure are marked (Windows: numberedLog)
    static func numbered(_ lines: [String]) -> [Line] {
        lines.enumerated().map { index, text in
            Line(number: index + 1, text: text, isError: isError(text) || first(exitCode, in: text) != nil)
        }
    }

    /// A job's log as numbered lines, without the empty line a final newline leaves (Windows: checkLogLines)
    static func numbered(log: String) -> [Line] {
        var all = lines(log)
        if all.last?.isEmpty == true { all.removeLast() }
        return numbered(all)
    }

    static func firstError(_ lines: [Line]) -> Line? { lines.first(where: \.isError) }

    /// How many lines a log folds away at first: it opens a few lines before its first error, or on its last two
    /// hundred (Windows: firstLogLine)
    static func firstShown(_ lines: [Line]) -> Int {
        if let error = lines.firstIndex(where: \.isError) { return max(0, error - 3) }
        return max(0, lines.count - 200)
    }

    // How test runners name a failed test, one family per runner; a log is read with the first family that finds any.
    private static let testFailures: [NSRegularExpression] = [
        // XCTest: Test Case '-[AppTests.SearchTests testQuery]' failed, or 'SearchTests.testQuery'
        #"Test Case '(?:-\[)?([^']+?)\]?' failed"#,
        // Go: --- FAIL: TestQuery (0.00s)
        #"^\s*--- FAIL: (\S+)"#,
        // cargo: test search::tests::query ... FAILED
        #"^test (\S+) \.\.\. FAILED\s*$"#,
        // pytest: FAILED tests/test_search.py::test_query - AssertionError
        #"^FAILED (\S+::\S+)"#,
        // Vitest: FAIL tests/search.test.ts > search > keeps the query
        #"^\s*FAIL\s+(\S+ > .+?)\s*$"#,
        // Jest, Mocha and Vitest: ✕ keeps the query (12 ms), × keeps the query 12ms
        #"^\s*[✕×✗]\s+(.+?)(?:\s+\(?\d+(?:\.\d+)?\s*m?s\)?)?\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    /// Linters and compilers mark their diagnostics with × too, so the last rule needs a test runner's summary in the log
    private static let runnerSummary = try! NSRegularExpression(pattern: #"^\s*(?:Tests?:|Test Files|Test Suites:|\d+ failing\b)"#)

    /// The tests a log says failed, by name, in order and once each (Windows: failedTests)
    static func failedTests(_ lines: [String]) -> [String] {
        for (family, pattern) in testFailures.enumerated() {
            if family == testFailures.count - 1,
               !lines.contains(where: { runnerSummary.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) { continue }
            var names: [String] = []
            for line in lines {
                guard var name = first(pattern, in: line) else { continue }
                // XCTest writes "Module.Type method"; a person reads "Type.method"
                if family == 0, let space = name.firstIndex(of: " ") {
                    let type = name[..<space].split(separator: ".").last.map(String.init) ?? String(name[..<space])
                    name = type + "." + name[name.index(after: space)...]
                }
                if !names.contains(name) { names.append(name) }
            }
            if !names.isEmpty { return names }
        }
        return []
    }

    /// The names a "1 test failed:" caption lists: the first three, and a sign that there are more (Windows: testNames)
    static func testNames(_ tests: [String]) -> String {
        tests.prefix(3).joined(separator: ", ") + (tests.count > 3 ? ", …" : "")
    }

    /// A log read once, so a view that redraws does not read it again: its numbered lines and the tests it names
    struct Reading: Equatable {
        var lines: [Line] = []
        var tests: [String] = []

        init() {}
        init(log: String) { self.init(lines: JobLog.numbered(log: log)) }
        /// Output that is already split into lines (a flow step's)
        init(output: [String]) { self.init(lines: JobLog.numbered(output)) }
        private init(lines: [Line]) {
            self.lines = lines
            tests = JobLog.failedTests(lines.map(\.text))
        }
    }

    /// The first capture group of the first match
    private static func first(_ pattern: NSRegularExpression, in line: String) -> String? {
        guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[range])
    }
}
