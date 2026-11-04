#!/usr/bin/env bash
# Renders the Ledger page off screen on demo data, in light and dark: Inbox, Board, Graph, Streams, a wait held for the
# person, the inspector, the empty state, a narrow window and wrapped compact controls, the two sheets, and the large demo (1,000
# sessions, 50,000 events). Then
# the page, Settings › Ledger and Import from claude-ledger on the core itself, through its C ABI, with the core's demo
# in a temporary database.
# Text recognition checks that each part is drawn (on its larger text: small labels are read unreliably), and the
# large demo reports frame and filter timings.
#   macos/Tools/test-ledger-layout.sh [--connect-only | --connections-only] [output folder for the screenshots]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_CONNECT_ONLY=0
TASK_CAPTURE_MODE=--all
if [[ "${1:-}" == "--connect-only" ]]; then TASK_CONNECT_ONLY=1; TASK_CAPTURE_MODE=--connect-only; shift; fi
if [[ "${1:-}" == "--questions-only" ]]; then TASK_CAPTURE_MODE=--questions-only; shift; fi
if [[ "${1:-}" == "--tutorial-only" ]]; then TASK_CAPTURE_MODE=--tutorial-only; shift; fi
if [[ "${1:-}" == "--chatgpt-only" ]]; then TASK_CAPTURE_MODE=--chatgpt-only; shift; fi
if [[ "${1:-}" == "--browser-only" ]]; then TASK_CAPTURE_MODE=--browser-only; shift; fi
if [[ "${1:-}" == "--extras-only" ]]; then TASK_CONNECT_ONLY=1; TASK_CAPTURE_MODE=--extras-only; shift; fi
if [[ "${1:-}" == "--connections-only" ]]; then TASK_CONNECT_ONLY=1; TASK_CAPTURE_MODE=--connections-only; shift; fi
TASK_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-ledger-layout.XXXXXX")}"
mkdir -p "$TASK_OUTPUT"
ARCH="$(uname -m)"
ST="${GITROCHI_SWIFTTERM_DIR:-$ROOT/.build/swiftterm/$ARCH}"
[[ -f "$ST/libSwiftTerm.a" ]] || { echo 'Run macos/build.sh once to build SwiftTerm.' >&2; exit 1; }
python3 - "$ROOT" "$TASK_TMP" "$TASK_CONNECT_ONLY" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:3])
connect_only = sys.argv[3] == '1'
for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text()
    if relative == 'App/App.swift':
        # the fixture brings its own entry point
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    if relative == 'Views/Ledger/LedgerConnectSheet.swift':
        # The fixture selects both agents without changing production access control.
        text = text.replace('@ViewState private var client:', '@ViewState var client:')
        if connect_only:
            text = text.replace('DisclosureGroup("Check or remove automatic activity") {',
                                'DisclosureGroup("Check or remove automatic activity", isExpanded: .constant(true)) {')
    if relative == 'Views/Ledger/LedgerChatGPTDraftSheet.swift':
        # The fixture supplies local pasted text and reviewed modes without changing production visibility.
        for field in ('mode', 'raw', 'preview'):
            text = text.replace('@ViewState private var ' + field, '@ViewState var ' + field)
        text = text.replace('private enum Mode:', 'enum Mode:')
    if relative == 'Views/Ledger/LedgerBrowserSheet.swift':
        text = text.replace('@ViewState private var extensionId', '@ViewState var extensionId')
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
cat > "$TASK_TMP/LedgerLayout.swift" <<'SWIFT'
import SwiftUI
import AppKit
import Vision
import ImageIO

@MainActor func settle(_ seconds: Double = 0.35) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

@MainActor func wait(_ work: @escaping @MainActor () async -> Void) {
    var done = false
    Task { @MainActor in await work(); done = true }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}

@MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
}

@MainActor func answerEditors(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(answerEditors(in:))
}

/// Rendering and editing the paste sheet may not send a report or answer by themselves.
final class LedgerLayoutWriteProbe: LedgerBackend, @unchecked Sendable {
    private let inner = DemoLedgerBackend(mode: .standard)
    private let lock = NSLock()
    private var writes = 0
    func call(method: String, args: Data) -> Data {
        lock.lock()
        if ["human", "import", "prompt_answer"].contains(method) { writes += 1 }
        lock.unlock()
        return inner.call(method: method, args: args)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return writes }
}

/// Browser captures use a fake registration response and never touch Chrome's configuration.
final class BrowserLayoutBackend: LedgerBackend, @unchecked Sendable {
    let installed: Bool
    private let inner = DemoLedgerBackend(mode: .standard)
    private let lock = NSLock()
    private var writes = 0
    init(installed: Bool) { self.installed = installed }
    func call(method: String, args: Data) -> Data {
        if method == "browser_status" {
            return Data("{\"installed\":\(installed),\"hostName\":\"com.gitrochi.ledger\",\"manifestPath\":\"/tmp/demo-host.json\",\"extensionId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"hostPath\":\"/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger-browser\"}".utf8)
        }
        if ["browser_install", "browser_remove"].contains(method) {
            lock.lock(); writes += 1; lock.unlock()
            return Data(#"{"error":{"code":"TEST","message":"Registration is disabled in this fixture"}}"#.utf8)
        }
        return inner.call(method: method, args: args)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return writes }
}

@MainActor @Observable final class BrowserQuestionProbe {
    var draft = ""
    var sent = 0
    var question = LedgerQuestion(id: 99004, sessionId: "demo", text: "Which release channel should I use?", state: .open,
                                 createdAt: 0, options: [.init(label: "Stable", description: "Use the verified release", recommended: true),
                                                         .init(label: "Nightly", description: "Try the newest changes", recommended: false)],
                                 suggestedAnswer: "Stable", browserSourceUrl: "https://chatgpt.com/c/00000000-0000-4000-8000-000000000042", browserDraft: "Stable after checks")
}

struct BrowserQuestionFixture: View {
    let probe: BrowserQuestionProbe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(probe.question.text).font(.title3.weight(.semibold))
            LedgerReportedAnswerField(question: probe.question, text: Binding(get: { probe.draft }, set: { probe.draft = $0 }), save: { probe.sent += 1 })
        }.padding(20)
    }
}

@MainActor final class Shot {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    init<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, dark: Bool) {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        // an opaque window background, as in the app: text on a transparent one reads as text on black
        host = NSHostingView(rootView: AnyView(content.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light)))
        window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.contentView = host
        host.frame = bounds
        window.orderBack(nil)
        settle()
    }

    /// Lays out and draws one frame; seconds it took
    @discardableResult func frame() -> Double {
        let start = Date()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        return Date().timeIntervalSince(start)
    }

    func png() -> Data {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        return data
    }

    func close() { window.orderOut(nil) }
}

/// Text recognition misreads a letter now and then ("flaky" as "tlaky" or "flakv"): a word of four letters or more
/// counts as seen when the text has it with one letter wrong, and a label of three words or more when all but one of its
/// words are seen
func seen(_ label: String, in text: String) -> Bool {
    let text = text.lowercased(), words = label.lowercased().split(separator: " ").map(String.init)
    if text.contains(label.lowercased()) { return true }
    let read = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    func found(_ word: String) -> Bool {
        text.contains(word) || (word.count >= 4 && read.contains { $0.count == word.count && zip($0, word).filter { $0 != $1 }.count == 1 })
    }
    return words.count > 2 && words.filter(found).count >= words.count - 1
}

@MainActor func text(in png: Data) throws -> String {
    func read(_ handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    var recognized = try read(VNImageRequestHandler(data: png))
    // Vision reduces a tall page to fit: recognize its small navigation labels at their native size too.
    if let source = CGImageSourceCreateWithData(png as CFData, nil), let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil),
       bitmap.height > bitmap.width,
       let header = bitmap.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: 500)) {
        recognized += "\n" + (try read(VNImageRequestHandler(cgImage: header)))
    }
    return recognized
}

/// A reported question uses the same editable choices as live hooks, including an alternative draft.
struct ReportedQuestionFixture: View {
    @ViewState private var answer = "Nightly"
    private var question: LedgerQuestion {
        LedgerQuestion(id: 99003, sessionId: "demo", text: "Which release channel should I use?", state: .open,
                       answer: nil, answeredBy: nil, createdAt: 0, answeredAt: nil, deliveredAt: nil,
                       options: [.init(label: "Stable", description: "Use the latest verified release", recommended: true),
                                 .init(label: "Nightly", description: "Try the newest changes", recommended: false)],
                       suggestedAnswer: "Stable")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.text).font(.title3.weight(.semibold))
            LedgerReportedAnswerField(question: question, text: $answer, save: {})
            Text("The session reads your answer with its next report.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor final class AnswerKeyboardProbe {
    var submitted: [String] = []
}

/// Two editors prove that only the focused form handles the explicit save shortcut.
struct AnswerKeyboardFixture: View {
    let probe: AnswerKeyboardProbe
    @ViewState private var first = ""
    @ViewState private var second = ""
    private var question: LedgerAnswerQuestion {
        .init(id: "keyboard", question: "Which channel?", options: [], multiple: false, suggestion: "Stable")
    }
    var body: some View {
        VStack(spacing: 12) {
            LedgerQuestionAnswerEditor(question: question, text: $first, submit: {
                if !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { probe.submitted.append("first:" + first) }
            })
            LedgerQuestionAnswerEditor(question: question, text: $second, submit: {
                if !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { probe.submitted.append("second:" + second) }
            })
        }
        .padding(16)
    }
}

@main struct LedgerLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "dev.gitrochi.ledger-layout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var shots = 0

        func store(_ mode: DemoLedgerBackend.Mode) -> LedgerStore {
            let ledger = LedgerStore(client: LedgerClient(backend: DemoLedgerBackend(mode: mode)), defaults: defaults, interval: .seconds(600))
            wait { await ledger.reload() }
            return ledger
        }

        func shoot<Content: View>(_ name: String, _ content: Content, width: CGFloat, height: CGFloat, expect: [String], absent: [String] = [], scrollToEnd: Bool = false) throws {
            for dark in [false, true] {
                let shot = Shot(content, width: width, height: height, dark: dark)
                settle(0.4)
                if scrollToEnd || CommandLine.arguments.contains("--connect-only"),
                   let list = scrollViews(in: shot.host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                    let contentHeight = list.documentView?.frame.height ?? 0
                    list.contentView.scroll(to: NSPoint(x: 0, y: max(0, contentHeight - list.contentView.bounds.height)))
                    list.reflectScrolledClipView(list.contentView)
                    settle(0.2)
                }
                let png = shot.png()
                let file = "ledger-\(name)-\(dark ? "dark" : "light").png"
                try png.write(to: output.appendingPathComponent(file))
                let recognized = try text(in: png)
                for label in expect where !seen(label, in: recognized) {
                    fatalError("\(file): “\(label)” is not on screen\n\(recognized)")
                }
                for label in absent where recognized.localizedCaseInsensitiveContains(label) {
                    fatalError("\(file): “\(label)” should not be on screen")
                }
                shot.close()
                shots += 1
            }
        }

        func browserShots() throws {
            for installed in [false, true] {
                let backend = BrowserLayoutBackend(installed: installed)
                let browser = LedgerStore(client: LedgerClient(backend: backend), defaults: defaults, interval: .seconds(600))
                try shoot(installed ? "browser-installed" : "browser-setup", LedgerBrowserSheet(ledger: browser), width: 540, height: 760,
                          expect: ["ChatGPT browser extension", "Open extension folder", "Extension ID", "Allow browser connection",
                                   installed ? "Browser host installed" : "Browser host not installed"])
                guard backend.count == 0 else { fatalError("Opening browser setup must not install or remove registration") }
            }
            let probe = BrowserQuestionProbe()
            let typed = Shot(BrowserQuestionFixture(probe: probe), width: 540, height: 520, dark: false)
            guard let editor = answerEditors(in: typed.host).first else { fatalError("Browser answer must use the production editor") }
            typed.window.makeFirstResponder(editor)
            func tab() {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: typed.window.windowNumber, context: nil, characters: "\t",
                                            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
                editor.keyDown(with: event); settle(0.1)
            }
            tab()
            guard probe.draft == "Stable after checks", probe.sent == 0 else { fatalError("Browser Tab must fill the accepted draft without sending") }
            editor.insertText(" and review", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            settle(0.1)
            probe.question.browserDraft = "Nightly instead"
            settle(0.1)
            typed.window.makeFirstResponder(editor)
            tab()
            guard probe.draft == "Stable after checks and review", probe.sent == 0 else { fatalError("A newer browser draft must preserve unsent editing") }
            typed.close()
            try shoot("browser-question", BrowserQuestionFixture(probe: probe), width: 540, height: 520,
                      expect: ["Which release channel", "Source conversation", "Browser draft accepted with Tab", "Use suggestion", "Send answer"])
        }
        if CommandLine.arguments.contains("--browser-only") {
            try browserShots()
            print("PASS: \(shots) browser setup and answer screenshots in light and dark; no registration, native Tab fill and unsent edit preservation. \(output.path)")
            return
        }

        func chatGPTShots() throws {
            let probe = LedgerLayoutWriteProbe()
            let local = LedgerStore(client: LedgerClient(backend: probe), defaults: defaults, interval: .seconds(600))
            wait { await local.reload() }
            var opened = 0
            let typing = Shot(LedgerChatGPTDraftSheet(ledger: local, onOpenQuestion: { _ in opened += 1 }), width: 540, height: 760, dark: false)
            guard let editor = answerEditors(in: typing.host).first else { fatalError("The paste editor is missing") }
            editor.insertText("Use the verified release after all checks pass.", replacementRange: NSRange(location: 0, length: 0))
            settle(0.2)
            guard local.drafts.isEmpty, probe.count == 0, opened == 0 else { fatalError("Pasting must not save a draft, send an answer or open a destination") }
            typing.close()
            let demo = store(.standard)
            let copied = "Use the verified release after all checks pass."
            try shoot("chatgpt-answer", LedgerChatGPTDraftSheet(ledger: demo, onOpenQuestion: { _ in }, raw: copied), width: 660, height: 700,
                      expect: ["Bring a ChatGPT draft", "Pasted by you", "Copied text", "Use draft", "Only fills a draft"])
            let raw = #"{"text":"Which release channel should we use?","options":[{"label":"Stable","description":"Use a verified release","recommended":true},{"label":"Nightly","description":"Try the newest changes"}],"suggestedAnswer":"Stable"}"#
            let preview = try LedgerChatGPTDraft.parseQuestion(raw)
            try shoot("chatgpt-question-preview", LedgerChatGPTDraftSheet(ledger: demo, onOpenQuestion: { _ in }, mode: .question, raw: raw, preview: preview), width: 540, height: 820,
                      expect: ["Preview", "Which release channel", "Stable", "Nightly", "Suggested answer", "Save question"], scrollToEnd: true)
            let empty = store(.empty)
            try shoot("chatgpt-empty", LedgerChatGPTDraftSheet(ledger: empty, onOpenQuestion: { _ in }), width: 540, height: 760,
                      expect: ["No open questions", "Add a question", "Paste text before continuing", "Use draft"])
            try shoot("chatgpt-oversize", LedgerChatGPTDraftSheet(ledger: demo, onOpenQuestion: { _ in }, raw: String(repeating: "A", count: 65_537)), width: 540, height: 760,
                      expect: ["Pasted text is limited to 64 KiB", "Use draft"], scrollToEnd: true)
        }
        if CommandLine.arguments.contains("--chatgpt-only") {
            try chatGPTShots()
            print("PASS: \(shots) explicit ChatGPT paste screenshots in light and dark; answer, reviewed question, empty and narrow size warning. \(output.path)")
            return
        }
        if !CommandLine.arguments.contains("--connect-only") && !CommandLine.arguments.contains("--questions-only") && !CommandLine.arguments.contains("--tutorial-only") && !CommandLine.arguments.contains("--extras-only") && !CommandLine.arguments.contains("--connections-only") {
            try chatGPTShots()
        }

        func tutorialShots() throws {
            let tutorial = LedgerLearning(defaults: defaults)
            tutorial.restart()
            try shoot("tutorial-concepts", LedgerLearningSheet(learning: tutorial), width: 720, height: 640,
                      expect: ["Learn Ledger", "Sessions and baselines", "Baseline", "Session"])
            tutorial.next()
            tutorial.chosenView = 2
            try shoot("tutorial-views", LedgerLearningSheet(learning: tutorial), width: 720, height: 640,
                      expect: ["Choose a view", "Inbox", "Board", "Graph", "Streams"])
            tutorial.next()
            try shoot("tutorial-answer", LedgerLearningSheet(learning: tutorial), width: 540, height: 760,
                      expect: ["Try answering a question", "Which channel", "Stable", "Use suggestion", "Send answer"])
            let practice = Shot(LedgerLearningSheet(learning: tutorial), width: 540, height: 760, dark: false)
            guard let editor = answerEditors(in: practice.host).first else { fatalError("Tutorial must use the production answer editor") }
            func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
                practice.window.makeFirstResponder(editor)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                            windowNumber: practice.window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                editor.keyDown(with: event)
                settle(0.1)
            }
            tutorial.next()
            guard tutorial.step == .answer, !tutorial.canAdvance else { fatalError("Tutorial skipped answer practice") }
            press(48, "\t")
            guard tutorial.answerDraft == "Stable", !tutorial.canAdvance else { fatalError("Tutorial Tab must fill without sending") }
            editor.insertText(" after the checks", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            settle(0.1)
            guard tutorial.answerDraft == "Stable after the checks" else { fatalError("Tutorial answer must remain editable") }
            press(36, "\r", .command)
            guard tutorial.progress.answerSent, tutorial.canAdvance else { fatalError("Tutorial send did not finish the local exercise") }
            practice.close()
            let restored = LedgerLearning(defaults: defaults)
            guard restored.step == .answer, restored.progress.answerSent, restored.answerDraft.isEmpty else { fatalError("Tutorial did not restore progress without storing draft text") }
            restored.next()
            try shoot("tutorial-delivery", LedgerLearningSheet(learning: restored), width: 720, height: 640,
                      expect: ["Follow an answer to completion", "Mark delivered", "saved"])
            restored.next()
            guard restored.step == .delivery else { fatalError("Tutorial skipped delivery practice") }
            restored.deliver(); restored.confirm(); restored.archive(); restored.next()
            guard restored.step == .connect else { fatalError("Delivery practice did not unlock setup") }
            try shoot("tutorial-connect", LedgerLearningSheet(learning: restored, openConnect: {}, bringChatGPTDraft: {}), width: 720, height: 640,
                      expect: ["Connect your agent", "Connect agents", "Bring a ChatGPT draft"])
            restored.next()
            guard LedgerLearning(defaults: defaults).progress.completed else { fatalError("Tutorial completion did not persist") }
            try shoot("tutorial-guide", LedgerLearningSheet(learning: restored, initialTab: .guide, openConnect: {}, bringChatGPTDraft: {}), width: 540, height: 760,
                      expect: ["Search the guide", "Setup", "Claude Code", "Answer delivery", "Privacy"])
            restored.restart()
            guard restored.step == .concepts, !restored.progress.completed else { fatalError("Tutorial Restart did not reset practice") }
        }
        if CommandLine.arguments.contains("--tutorial-only") {
            try tutorialShots()
            print("PASS: \(shots) tutorial and guide screenshots in light and dark; native Tab/edit/send, practice gates, restore and restart. \(output.path)")
            return
        }
        if !CommandLine.arguments.contains("--connect-only") && !CommandLine.arguments.contains("--questions-only") && !CommandLine.arguments.contains("--extras-only") && !CommandLine.arguments.contains("--connections-only") {
            try tutorialShots()
        }

        let ledger = store(.standard)
        if CommandLine.arguments.contains("--extras-only") {
            wait {
                _ = try? await ledger.client.notebook(["action": "save", "title": "Release checklist", "body": "## Review\n\nInspect the cache policy and confirm the release notes.", "pinned": true])
                _ = try? await ledger.client.work(["action": "add_item", "project": "harbor", "item": "W-demo-01", "title": "Review cache policy", "bundle": "Release", "date": "2026-11-02", "text": "Compared cache eviction choices"])
                _ = try? await ledger.client.documents(["action": "set_roots", "project": "harbor", "roots": ["Demo documents"]])
            }
            wait { await ledger.choose(project: "harbor") }
            try shoot("notebook", LedgerNotebookSheet(ledger: ledger), width: 980, height: 650, expect: ["Notebook", "Release checklist", "Pin note"])
            try shoot("work-log", LedgerWorkLogSheet(ledger: ledger), width: 980, height: 680, expect: ["Work log", "Review cache policy", "Build report"])
            try shoot("documents", LedgerDocumentsSheet(ledger: ledger), width: 1040, height: 720, expect: ["Document tracker", "Save folders and scan", "DOC-12"])
            try shoot("records", LedgerManageSheet(ledger: ledger), width: 840, height: 720, expect: ["Manage records", "Session details", "Save session details"])
            print("PASS: \(shots) added-feature screenshots in light and dark. \(output.path)")
            return
        }
        if CommandLine.arguments.contains("--connections-only") {
            // The demo's connections: Claude Code delivering, Codex on an outdated command, the browser extension not set up
            let sheet = LedgerConnectSheet(ledger: ledger, binaryPath: "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger")
            try shoot("connections-sheet", sheet, width: 680, height: 700,
                      expect: ["Connect agents", "Connections", "Claude Code", "Needs repair", "ChatGPT browser extension", "Copy MCP command"])
            try shoot("connections-settings", LedgerSettings(ledger: ledger), width: 640, height: 900,
                      expect: ["Connections", "Claude Code", "Needs repair", "Not set up", "Connect and import"], scrollToEnd: true)
            let empty = store(.empty)
            try shoot("connections-entry", LedgerWorkspaceView(repositoryPath: nil, ledger: empty), width: 1200, height: 760,
                      expect: ["No reports yet", "ChatGPT browser extension", "Connect Claude Code"])
            print("PASS: \(shots) connection screenshots in light and dark. \(output.path)")
            return
        }
        func connectShots() throws {
            let focused = CommandLine.arguments.contains("--connect-only")
            try shoot("connect", LedgerConnectSheet(ledger: ledger, binaryPath: "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger"), width: 680, height: 700,
                      expect: focused ? ["Connect agents", "Status", "Remove", "integrate claude --status", "integrate claude --remove", "Test Ledger"] : ["Connect agents", "claude mcp add", "Copy reporting instruction", "Test Ledger"])
            try shoot("connect-codex", LedgerConnectSheet(ledger: ledger, binaryPath: "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger", client: .codex), width: 680, height: 700,
                      expect: focused ? ["Connect agents", "Status", "Remove", "integrate codex --status", "integrate codex --remove", "Test Ledger"] : ["Connect agents", "codex mcp add", "Copy reporting instruction", "Test Ledger"])
        }
        if CommandLine.arguments.contains("--connect-only") {
            try connectShots()
            print("PASS: \(shots) agent connection screenshots in light and dark. \(output.path)")
            return
        }
        func questionShots() throws {
            let now = LedgerStore.localNow()
            let ask = LedgerPendingPrompt(id: 99001, sessionId: nil, agentId: nil, kind: .askUserQuestion,
                payload: ["autoAnswer": false, "questions": [
                    ["header": "Release channel", "question": "Which release channel should I use?", "options": [
                        ["label": "Stable", "description": "Use the latest verified release", "recommended": true],
                        ["label": "Nightly", "description": "Try the newest changes"]]],
                    ["header": "Validation", "question": "Which checks should run?", "multiSelect": true, "options": [
                        ["label": "Build", "description": "Compile both apps", "recommended": true],
                        ["label": "Tests", "description": "Check the changed behavior", "recommended": true],
                        ["label": "Documentation", "description": "Review the user guide"]]],
                    ["header": "Release notes", "question": "What should the release notes mention?", "options": [],
                     "suggestedAnswer": "Summarize user-visible changes."]]],
                createdAt: now, deadline: now + 300_000, state: .waiting, answer: nil, answeredBy: nil)
            let stop = LedgerPendingPrompt(id: 99002, sessionId: nil, agentId: nil, kind: .stopQuestion,
                payload: ["question": "Should I continue with the proposed scope?", "options": [
                    ["label": "Continue", "description": "Keep the agreed changes", "recommended": true],
                    ["label": "Adjust the scope", "description": "Describe what should change"]],
                    "suggestedAnswer": "Continue after the checks pass."],
                createdAt: now, deadline: now + 300_000, state: .waiting, answer: nil, answeredBy: nil)
            let probe = AnswerKeyboardProbe()
            let keyboard = Shot(AnswerKeyboardFixture(probe: probe), width: 800, height: 700, dark: false)
            let editors = answerEditors(in: keyboard.host)
            guard editors.count == 2, let editor = editors.first else { fatalError("The answer editors are missing") }
            func press(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
                keyboard.window.makeFirstResponder(editor)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                            timestamp: 0, windowNumber: keyboard.window.windowNumber, context: nil,
                                            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                editor.keyDown(with: event)
                settle(0.1)
            }
            press(36, "\r", .command)
            guard probe.submitted.isEmpty else { fatalError("An empty form was sent") }
            press(48, "\t", .shift)
            guard editor.string.isEmpty else { fatalError("Shift-Tab filled an answer") }
            press(48, "\t")
            guard editor.string == "Stable", probe.submitted.isEmpty else { fatalError("Tab must fill a draft without sending it") }
            press(48, "\t")
            guard editor.string == "Stable" else { fatalError("Tab replaced a nonempty answer") }
            press(36, "\r", .command)
            guard probe.submitted == ["first:Stable"], editors[1].string.isEmpty else { fatalError("The save shortcut must send only the focused form") }
            press(36, "\r")
            guard probe.submitted.count == 1 else { fatalError("Plain Return sent an answer") }
            editor.setMarkedText("編", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            guard editor.hasMarkedText() else { fatalError("The composition fixture did not begin") }
            press(36, "\r", .command)
            guard probe.submitted.count == 1 else { fatalError("An input-method composition submitted an answer") }
            keyboard.close()
            try shoot("question-choices", LedgerPromptStrip(prompts: [ask, stop], ledger: ledger).padding(16), width: 800, height: 1560,
                      expect: ["Which release channel", "Which checks", "release notes mention", "Use suggestion", "Send answer", "Your answer", "Time left"],
                      absent: ["Answer sent to the agent"])
            try shoot("reported-question", ReportedQuestionFixture(), width: 720, height: 460,
                      expect: ["Which release channel", "Stable", "Nightly", "Use suggestion", "Send answer"])
        }
        if CommandLine.arguments.contains("--questions-only") {
            try questionShots()
            print("PASS: \(shots) question-choice screenshots in light and dark. \(output.path)")
            return
        }
        try questionShots()
        let sessions = ledger.state!.sessions
        let retry = sessions.first { $0.verdict == .needsHuman && $0.project == "harbor" }!
        let decision = sessions.first { $0.role == .decision }!

        ledger.selection = retry.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("inbox", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 2100,
                  expect: ["Inbox", "How many times should sign-in retry", "Retry sign-in after a timeout", "Outline the onboarding chapter",
                           "offline drafts be kept", "Choose the cache eviction policy", "Write the export guide", "Investigate the flaky upload test"])
        // a wait held for the person: why and where to answer it, and no answer that would not reach the agent
        let held = ledger.inbox.prompts.filter { !LedgerCountdown.isCounting($0) }
        try shoot("prompt-held", LedgerPromptStrip(prompts: held, ledger: ledger), width: 720, height: 460,
                  expect: ["Plan to approve", "Finish the glossary review", "Answer in terminal"], absent: ["Allow", "Deny", "Not this time", "Auto in"])

        ledger.page = .board
        ledger.selection = decision.id
        ledger.boardSelection = Set(sessions.filter { $0.verdict == .pendingMerge }.map(\.id))
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("board", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 940,
                  expect: ["Board", "selected", "Choose the cache eviction policy", "Add CSV export"])
        ledger.boardSelection = []

        wait { await ledger.setRange(.month) }
        ledger.page = .graph
        ledger.selection = retry.id
        wait { await ledger.loadGraph(); try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("graph", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 940,
                  expect: ["Graph", "v1.4.2", "v1.4.1"])

        ledger.page = .streams
        wait { try? await Task.sleep(for: .milliseconds(300)) }
        try shoot("streams", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 1440, height: 940,
                  expect: ["Streams", "Core implementation channel", "v1.4.2", "v1.4.0"])

        ledger.page = .inbox
        try shoot("narrow", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 980, height: 760,
                  expect: ["Inbox", "Board", "Graph", "All verdicts", "Retry sign-in after a timeout"], absent: ["Answer or dismiss the open questions"])
        try shoot("stacked", LedgerWorkspaceView(repositoryPath: nil, ledger: ledger), width: 620, height: 820,
                  expect: ["Inbox", "Board", "Graph", "All verdicts"])

        ledger.selection = decision.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("inspector", LedgerInspector(ledger: ledger, open: { _ in }, close: {}), width: 480, height: 900,
                  expect: ["Choose the cache eviction policy", "Decision", "200 MB"])
        // a session that may auto-continue: its own switch and wait
        ledger.selection = retry.id
        wait { await ledger.loadAutoContinueDefault(); try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("inspector-auto-continue", LedgerInspector(ledger: ledger, open: { _ in }, close: {}), width: 480, height: 1100,
                  expect: ["Retry sign-in after a timeout", "Continue automatically when nobody answers"])

        try connectShots()
        try shoot("import", LedgerImportSheet(ledger: ledger), width: 620, height: 380, expect: ["Paste reports", "Import"])

        let empty = store(.empty)
        try shoot("empty", LedgerWorkspaceView(repositoryPath: nil, ledger: empty), width: 1200, height: 760,
                  expect: ["No reports yet", "Connect agents", "Paste reports"])

        // the core itself, through its C ABI, as the app reads it
        let core = LedgerStore(client: LedgerClient(backend: NativeLedgerBackend(database: CommandLine.arguments[2])), defaults: defaults, interval: .seconds(600))
        wait { await core.setRange(.all); await core.reload() }
        let asking = core.state!.sessions.first { $0.verdict == .needsHuman }!
        core.selection = asking.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("core-inbox", LedgerWorkspaceView(repositoryPath: nil, ledger: core), width: 1440, height: 940, expect: ["Inbox", asking.title])
        let confirm = core.state!.sessions.first { $0.verdict == .confirm }!
        core.page = .board
        core.selection = confirm.id
        wait { try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("core-board", LedgerWorkspaceView(repositoryPath: nil, ledger: core), width: 1440, height: 940, expect: ["Board", confirm.title])
        core.page = .graph
        wait { await core.loadGraph(); try? await Task.sleep(for: .milliseconds(200)) }
        try shoot("core-graph", LedgerWorkspaceView(repositoryPath: nil, ledger: core), width: 1440, height: 940, expect: ["Graph", "1.4.2"])
        // a repository with its own auto-continue policy, so Settings shows the switch and the wait
        wait {
            if let stored = try? await core.settings() {
                _ = try? await core.saveSettings(["autoContinue": stored.autoContinueArgument(repository: "/Volumes/Work/harbor-app", .init(enabled: true, delaySec: 45))])
            }
        }
        try shoot("settings", LedgerSettings(ledger: core), width: 600, height: 2300,
                  expect: ["Track agents I start", "Agents Gitrochi starts", "Continue automatically when nobody answers", "harbor-app",
                           "Show notifications", "Show the Inbox count on the Dock icon",
                           "Stale after", "Roles and stream lines", "implementation", "Version pattern", "Back up now", "Connect agents"])
        try shoot("import-legacy", LedgerLegacyImportSheet(ledger: core, path: CommandLine.arguments[3]), width: 620, height: 380,
                  expect: ["Import from claude-ledger", "Ready to import", "Sessions"])

        // the large demo: one frame at the top, then frames while scrolling, and the filter while typing
        let big = store(.large)
        wait { await big.setRange(.all) }
        big.page = .board
        let shot = Shot(LedgerWorkspaceView(repositoryPath: nil, ledger: big), width: 1440, height: 940, dark: false)
        settle(0.5)
        let first = shot.frame()
        let list = scrollViews(in: shot.host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }!
        var frames: [Double] = []
        let content = list.documentView?.frame.height ?? 0
        for step in 1...40 {
            let y = content * Double(step) / 40 - list.contentView.bounds.height
            list.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            list.reflectScrolledClipView(list.contentView)
            frames.append(shot.frame())
        }
        let png = shot.png()
        try png.write(to: output.appendingPathComponent("ledger-large-board-light.png"))
        var filter = big.filter
        filter.text = "cache"
        let typed = Date()
        big.filter = filter
        let before = big.boardRows.count
        while big.boardRows.count == before { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        let filterTime = Date().timeIntervalSince(typed) + shot.frame()
        filter.text = ""
        big.filter = filter
        settle(0.2)
        shot.close()
        big.page = .graph
        let graphShot = Shot(LedgerWorkspaceView(repositoryPath: nil, ledger: big), width: 1440, height: 940, dark: true)
        wait { await big.loadGraph() }
        settle(0.5)
        let graphFirst = graphShot.frame()
        let graphList = scrollViews(in: graphShot.host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }!
        var graphFrames: [Double] = []
        for step in 1...40 {
            graphList.contentView.scroll(to: NSPoint(x: 0, y: (graphList.documentView?.frame.height ?? 0) * Double(step) / 41))
            graphList.reflectScrolledClipView(graphList.contentView)
            graphFrames.append(graphShot.frame())
        }
        try graphShot.png().write(to: output.appendingPathComponent("ledger-large-graph-dark.png"))
        graphShot.close()
        func report(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.1f ms, slowest %.1f ms", sorted[sorted.count / 2] * 1000, (sorted.last ?? 0) * 1000)
        }
        print(String(format: "Large demo: Board first frame %.0f ms; scrolling %@ over %d frames; filter to a drawn frame %.0f ms; Graph (%d rows drawn of %d) first frame %.0f ms; scrolling %@",
                     first * 1000, report(frames), frames.count, filterTime * 1000, big.plot.rows.count, big.graph?.nodes.count ?? 0, graphFirst * 1000, report(graphFrames)))
        precondition(report(frames).isEmpty == false && (frames.sorted()[frames.count / 2]) < 0.25, "Board scrolling is too slow")
        print("PASS: \(shots) screenshots in light and dark with the labels on screen. \(output.path)")
    }
}
SWIFT
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
TASK_OPTIMIZATION=(-O)
if [[ "$TASK_CONNECT_ONLY" == 1 ]]; then TASK_OPTIMIZATION=(-Onone); fi
xcrun swiftc -parse-as-library -swift-version 5 "${TASK_OPTIMIZATION[@]}" -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/LedgerLayout.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/ledger-layout"
# The core's own demo in a temporary database, and a claude-ledger file to import; a call that names no database
# would use another temporary one, never the person's ledger
"$(dirname "$TASK_CORE")/gitrochi-ledger" demo "$TASK_TMP/ledger.sqlite3" > /dev/null
sqlite3 "$TASK_TMP/claude-ledger.db" < "$ROOT/Tools/fixtures/claude-ledger.sql"
export GITROCHI_LEDGER_DB="$TASK_TMP/default.sqlite3"
"$TASK_TMP/ledger-layout" "$TASK_OUTPUT" "$TASK_TMP/ledger.sqlite3" "$TASK_TMP/claude-ledger.db" "$TASK_CAPTURE_MODE"
