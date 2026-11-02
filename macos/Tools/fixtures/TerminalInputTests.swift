import Foundation

@main
struct TerminalInputTests {
    static func main() {
        check(TerminalInput.singleLine("  Explain this diff  ") == "Explain this diff", "Trim reviewed input")
        check(TerminalInput.singleLine("first\r\nsecond\tthird") == "first second third", "Newlines and tabs cannot submit commands")
        check(TerminalInput.singleLine("echo ready\u{1B}[200~\rwhoami\u{1B}[201~") == "echo ready [200~ whoami [201~", "Remove terminal escape controls")
        check(TerminalInput.singleLine("a\u{00}\u{7F}\u{85}\u{9B}b") == "a b", "Remove C0, C1 and DEL controls")
        check(TerminalInput.singleLine("a\u{2028}b\u{2029}c\u{00A0}d") == "a b c d", "Flatten Unicode line and space separators")
        check(TerminalInput.singleLine("현재 변경 사항을 설명해 줘") == "현재 변경 사항을 설명해 줘", "Preserve Korean dictation")
        check(TerminalInput.singleLine("fix \"quoted names\" / café 🛠") == "fix \"quoted names\" / café 🛠", "Preserve ordinary Unicode and punctuation")
        check(TerminalInput.singleLine("\r\n\u{1B}\t").isEmpty, "Control-only input is not inserted")
        let allControls = String(String.UnicodeScalarView((0...0x9F).compactMap(UnicodeScalar.init)))
        check(!TerminalInput.singleLine(allControls).unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }, "No terminal controls survive review")

        var run = TerminalDictationRun()
        check(run.state == .idle, "New dictation is idle")
        let first = run.begin()
        check(run.state == .requesting && run.accepts(first), "Authorization belongs to a recording")
        run.cancel()
        check(run.state == .idle && !run.accepts(first), "Cancel invalidates pending authorization")
        check(!run.listen(first), "Late authorization cannot start the microphone")
        check(!run.complete(first, hasText: true), "Late transcript cannot reopen cancelled review")

        let second = run.begin()
        check(run.listen(second) && run.state == .listening, "Authorized recording starts")
        check(!run.finish(first) && run.state == .listening, "Old stop cannot stop a new recording")
        check(run.finish(second) && run.state == .finishing, "Stop waits for a final result")
        check(run.complete(second, hasText: true) && run.state == .review, "Final text is ready for review")
        check(!run.fail(second) && run.state == .review, "Late cancellation error cannot overwrite review")

        let empty = run.begin()
        check(run.listen(empty), "Another recording can start")
        check(run.complete(empty, hasText: false) && run.state == .failure, "Empty speech cannot be inserted")
        let replaced = run.begin()
        let current = run.begin()
        check(!run.listen(replaced) && run.accepts(current), "Replacement invalidates earlier permission requests")
        check(run.fail(current) && run.state == .failure && !run.accepts(current), "Failures stop accepting callbacks")
        run.cancel()
        check(run.state == .idle, "Cancel resets errors and review state")
        print("Terminal input and dictation lifecycle: 24 checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
