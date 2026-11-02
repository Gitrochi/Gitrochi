import AppKit
import Foundation

@main
struct TerminalVoiceTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }
        let decomposed = "\u{1100}\u{1175}\u{11BA}\u{1105}\u{1169}\u{110E}\u{1175}"
        let vocabulary = TerminalSpeechVocabulary.make(repositoryName: decomposed,
            branches: ["main", "feature/voice-input", String(repeating: "x", count: 81)],
            paths: ["Sources/App.swift", "tests/voice.test.ts", "/Users/me/private/File.swift", "../.env", "config/credentials.json", "C:\\Users\\me\\private.key"],
            custom: "깃로치, Codex, CODEX, API client\nhttps://example.com, www.example.com, secret@example.com, ghp_privatevalue, token=privatevalue, /Users/me/private, ~/, bad\u{1B}term")
        check(vocabulary.contains("깃로치"), "Korean hints are normalized to NFC")
        check(vocabulary.filter { $0 == "깃로치" }.count == 1, "Composed and decomposed Korean hints deduplicate")
        check(vocabulary.filter { $0.lowercased() == "codex" }.count == 1, "Hints deduplicate without changing display spelling")
        check(vocabulary.contains("Gitrochi") && vocabulary.contains("gitch") && vocabulary.contains("Swift"), "Common development words remain available")
        check(vocabulary.contains("API client"), "User phrases remain literal recognition hints")
        check(vocabulary.contains("feature/voice-input"), "Repository branch vocabulary remains available")
        check(vocabulary.contains("App.swift") && vocabulary.contains("App"), "File names and stems aid recognition")
        check(!vocabulary.contains("Sources/App.swift") && !vocabulary.contains("File.swift"), "Neither relative directories nor absolute home paths become hints")
        check(!vocabulary.contains(".env") && !vocabulary.contains("credentials.json") && !vocabulary.contains("private.key"), "Sensitive file names stay out of vocabulary")
        check(!vocabulary.contains { $0.contains("://") || $0.contains("@") || $0.hasPrefix("www.") }, "URLs and email addresses stay out of vocabulary")
        check(!vocabulary.contains { $0.hasPrefix("ghp_") || $0.contains("token=") }, "Credential-shaped values stay out of vocabulary")
        check(!vocabulary.contains { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }, "Control characters are rejected")
        let tokenShapes = ["sk-secretvalue", "github_pat_secretvalue", "glpat-secretvalue", "AKIAEXAMPLEVALUE", String(repeating: "a", count: 40), "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"]
        check(TerminalSpeechVocabulary.bounded(tokenShapes).isEmpty, "Token and high-entropy shapes are excluded")
        check(TerminalSpeechVocabulary.bounded(["Asia", "Asian languages"]) == ["Asia", "Asian languages"], "Ordinary terms do not look like access keys")
        let many = TerminalSpeechVocabulary.bounded((0..<200).map { "term \($0)" })
        check(many.count == 100 && many.first == "term 0" && many.last == "term 99", "Vocabulary is stable and bounded to 100 entries")
        check(TerminalSpeechVocabulary.bounded([String(repeating: "가", count: 80)]).count == 1, "80-character hints are supported")
        check(TerminalSpeechVocabulary.bounded([String(repeating: "가", count: 81)]).isEmpty, "Longer hints are rejected")
        check(vocabulary == TerminalSpeechVocabulary.make(repositoryName: decomposed,
            branches: ["main", "feature/voice-input", String(repeating: "x", count: 81)],
            paths: ["Sources/App.swift", "tests/voice.test.ts", "/Users/me/private/File.swift", "../.env", "config/credentials.json", "C:\\Users\\me\\private.key"],
            custom: "깃로치, Codex, CODEX, API client\nhttps://example.com, www.example.com, secret@example.com, ghp_privatevalue, token=privatevalue, /Users/me/private, ~/, bad\u{1B}term"), "Vocabulary generation is deterministic")

        func locale(_ saved: String = "", _ app: String = "system", _ system: String = "ko_KR") -> String {
            TerminalSpeechVocabulary.localeIdentifier(saved: saved, appLanguage: app, systemLanguage: system)
        }
        check(locale() == "ko-KR", "First use follows a Korean system language")
        check(locale("", "en", "ko_KR") == "en-US", "Explicit app English overrides automatic system Korean")
        check(locale("", "ko", "en_US") == "ko-KR", "Explicit app Korean overrides system English")
        check(locale("en-US", "ko", "ko_KR") == "en-US", "Saved speech language overrides app language")
        check(locale("en_KR") == "en-US", "Invalid English region combinations resolve to the supported English locale")
        check(locale("ko-US") == "ko-KR", "Korean uses its supported locale")
        check(locale("", "system", "ja_JP") == "ja-JP", "Other current languages are preserved")
        check(locale("", "fr", "fr_CA") == "fr-CA", "Automatic preserves a matching system region for other languages")
        check(locale("de-DE", "ko") == "de-DE", "Explicit other languages are not silently changed to English")

        var hold = TerminalHoldToTalk.Gesture()
        check(!hold.isHolding, "The hold begins unlatched")
        check(hold.handle(.press(isRepeat: true)) == nil && !hold.isHolding, "An orphan keyboard repeat cannot start recording")
        check(hold.handle(.press(isRepeat: false)) == .begin && hold.isHolding, "A fresh chord begins exactly once")
        check(hold.handle(.press(isRepeat: true)) == nil && hold.isHolding, "Repeated keydown cannot restart recognition")
        check(hold.handle(.press(isRepeat: false)) == nil, "Duplicate keydown cannot restart recognition")
        check(hold.handle(.release) == .finish && !hold.isHolding, "Space release finalizes independently of modifier state")
        check(hold.handle(.release) == nil, "Duplicate release cannot finalize twice")
        check(hold.handle(.press(isRepeat: false)) == .begin, "A second hold can start")
        check(hold.handle(.escape) == .cancel && !hold.isHolding, "Escape cancels the active hold")
        check(hold.handle(.release) == nil, "Releasing after cancellation cannot submit a finalization")
        check(hold.handle(.press(isRepeat: false)) == .begin, "A new hold can follow cancellation")
        check(hold.handle(.lostContext) == .cancel && !hold.isHolding, "Window or application changes cancel the hold")
        check(hold.handle(.lostContext) == nil, "Repeated deactivation does not cancel unrelated review")
        check(TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .shift]), "Only the intended Space chord starts a hold")
        check(TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .shift, .capsLock]), "Caps Lock does not interfere with the chord")
        check(!TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .shift, .command]), "Command-modified shortcuts are left alone")
        check(!TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .shift, .option]), "Option-modified shortcuts are left alone")
        check(!TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .option]), "Input-source and VoiceOver shortcuts are left alone")
        check(!TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.option]), "Option-Space is left alone")
        check(!TerminalHoldToTalk.matchesChord(keyCode: 0, modifiers: [.control, .shift]), "Other keys are left alone")
        var run = TerminalDictationRun()
        let pending = run.begin()
        run.cancel()
        check(!run.listen(pending), "A released short hold cannot start audio after a late authorization result")

        for state in [TerminalDictation.State.idle, .review, .failure] {
            check(!TerminalDictation.cancelsOnDeactivation(state: state, requestingPermissions: false), "Deactivation preserves review and recovery state")
        }
        for state in [TerminalDictation.State.requesting, .listening, .finishing] {
            check(TerminalDictation.cancelsOnDeactivation(state: state, requestingPermissions: false), "Deactivation always stops active audio and pending capture")
        }
        check(!TerminalDictation.cancelsOnDeactivation(state: .requesting, requestingPermissions: true), "A permissions-only setup can finish without recording")
        print("Terminal voice hints and local hold state: \(checks) checks passed")
    }
}
