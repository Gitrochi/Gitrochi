import AppKit
import Observation
import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>
@MainActor var terminalLayoutIcon: NSImage?
@MainActor func terminalLayoutOpenSettings(_ url: URL) { fatalError("Rendering must never open Settings") }

/// Simulated recognition never records, requests permission, stores text, or starts a process.
@MainActor @Observable final class TerminalDictation {
    typealias State = TerminalDictationRun.State
    /* TERMINAL_DICTATION_RECOVERY */
    var recovery: Recovery?
    var transcript = ""
    var level: Float = 0
    var error: String?
    var notice: String?
    var state: State = .idle
    var needsPermissionSetup = false
    var isBusy: Bool { [.requesting, .listening, .finishing].contains(state) }
    func start(localeIdentifier: String, contextualStrings: [String] = []) { fatalError("A layout fixture must never start recording") }
    func stop() { state = .review }
    func cancel() { state = .idle }
}

struct TerminalLayoutProbe: NSViewRepresentable {
    let identifier: String
    final class Probe: NSView {
        var fixtureIdentifier = ""
    }
    func makeNSView(context: Context) -> NSView {
        let view = Probe(); view.fixtureIdentifier = identifier; return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.fixtureIdentifier = identifier }
}

@MainActor private final class PreviewActions {
    var commands: [String] = []
    var copies = 0
    var nextTabs = 0
    func select(_ command: TerminalQuickCommand) { commands.append(command.command) }
}

/// Production chrome surrounds inert output; this fixture does not exercise a PTY.
private struct TerminalPreviewPane: View {
    let id: String
    let focused: Bool
    let short: Bool
    let eyes: String
    let actions: PreviewActions
    private let tabs = [UUID(), UUID(), UUID()]

    @ViewState private var paneSize = CGSize(width: 800, height: 260)

    var body: some View {
        VStack(spacing: 0) {
            // the production tab bar, folded by the pane's measured width as TerminalPaneView does
            TerminalTabBar(tabs: [
                TerminalTabItem(id: tabs[0], title: focused ? "desktop-client" : "Release checks", directory: "/Workspace/desktop-client", number: 1,
                                mark: focused ? .none : .ring, state: focused ? "Idle" : "Running"),
                TerminalTabItem(id: tabs[1], title: "Claude Code", directory: "/Workspace/desktop-client", number: 2, mark: .dot, state: "New output"),
                TerminalTabItem(id: tabs[2], title: "A long session title to check horizontal overflow", directory: "/Workspace/desktop-client", number: 3,
                                mark: .hollow, state: "Exited"),
            ], selected: tabs[0], focused: focused, width: paneSize.width, corner: focused,
                           select: { _ in }, close: { _ in }, newTerminal: {}, voice: {}, hide: {}) { EmptyView() }
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            output
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            if TerminalPanelLayout.railShown(height: paneSize.height) {
                TerminalQuickActions(enabled: true, width: paneSize.width, select: actions.select)
                    .background(TerminalLayoutProbe(identifier: "quick-rail"))
            }
            TerminalStatusBar(directory: "/Workspace/a-long-project-folder/desktop-client", activity: focused ? .idle : .running,
                              program: focused ? "zsh" : "npm", branch: focused ? "feature/terminal" : nil,
                              unseenCount: focused ? 1 : 0, width: paneSize.width,
                              copyDirectory: { actions.copies += 1 }, nextUnseen: { actions.nextTabs += 1 })
                .background(TerminalLayoutProbe(identifier: "status"))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { paneSize = $0 }
        .background(TerminalLayoutProbe(identifier: "pane"))
    }

    private var output: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                if !short {
                    HStack(spacing: 8) {
                        Text("❯").foregroundStyle(Color.accentColor)
                        Text(focused ? "gitch ck" : "gitch preflight")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            eyeLogo
                            cliTitle
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            eyeLogo
                            cliTitle
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        result("Branch", focused ? "feature/terminal" : "main")
                        result("Account", "Ready")
                        result("Working tree", "Clean")
                    }
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("❯").foregroundStyle(Color.accentColor)
                    Rectangle().fill(Color.primary).frame(width: 7, height: 15)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var eyeLogo: some View {
        Text(verbatim: eyes)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .fixedSize()
            .accessibilityLabel("Gitrochi eye logo")
    }

    private var cliTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GITROCHI / STATUS").font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text("desktop-client").foregroundStyle(.secondary)
            Text("Everything is up to date.").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func result(_ key: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: key).frame(width: 96, alignment: .leading)
            Text(verbatim: value).lineLimit(1).truncationMode(.middle)
        }
    }
}


@MainActor var terminalLayoutInitialDestination = TerminalVoiceDestination.terminal
@MainActor var terminalLayoutShowVocabulary = false

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, gemini
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : self == .codex ? "Codex" : "Gemini CLI" }
}
enum AppLanguage { static let key = "appLanguage" }
enum AIProvider: String { case compatible, fixture; var title: String { "Preview AI" } }

/// The production cleanup client calls only this in-process fixture; there is no network implementation.
@MainActor @Observable final class AIStore {
    static let shared = AIStore()
    var provider = AIProvider.fixture
    var baseURL = ""
    var hasKey: [String: Bool] = ["fixture": true]
    var unavailable = false
    var unconfigured = false
    var holdCleanup = false
    var pendingCleanup: CheckedContinuation<Void, Never>?
    var requests: [(system: String, prompt: String)] = []
    func model(_ provider: AIProvider) -> String { "local fixture" }
    func problem(_ provider: AIProvider) -> String? { unconfigured ? "Choose an AI provider in Settings before cleaning up." : nil }
    func complete(system: String, prompt: String, effort: String, using provider: AIProvider?) async throws -> String {
        precondition(provider == .fixture && effort == "low", "Cleanup must use the displayed default provider")
        precondition(system.contains("untrusted data") && system.contains("never answer"), "Cleanup retains its transcription-only contract")
        guard let payload = try JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any],
              let source = payload["transcript"] as? String else { fatalError("Cleanup must send a JSON transcript payload") }
        requests.append((system, prompt))
        await Task.yield()
        if holdCleanup { await withCheckedContinuation { pendingCleanup = $0 } }
        if unavailable { throw FixtureFailure.unavailable }
        var cleaned = source.hasPrefix("음 ") ? String(source.dropFirst(2)) : source
        if !cleaned.hasSuffix(".") { cleaned += "." }
        return String(data: try JSONSerialization.data(withJSONObject: ["text": cleaned]), encoding: .utf8)!
    }
}
private enum FixtureFailure: LocalizedError {
    case unavailable
    var errorDescription: String? { "The preview provider is unavailable. Try again." }
}
@MainActor private final class VoicePreviewActions {
    var sent: [(destination: TerminalVoiceDestination, text: String, kind: AgentKind)] = []
    var failSend = false
    var holdSend = false
    var attempts = 0
    var pendingSend: CheckedContinuation<Void, Never>?
    func send(_ destination: TerminalVoiceDestination, _ text: String, _ kind: AgentKind) async throws {
        attempts += 1
        if holdSend { await withCheckedContinuation { pendingSend = $0 } }
        if failSend { throw FixtureFailure.unavailable }
        sent.append((destination, destination == .terminal ? TerminalInput.singleLine(text) : text, kind))
    }
}

@main private struct TerminalLayoutFixture {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count >= 5, "Pass output folder, canonical icon, CLI artwork and preview language")
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard let icon = NSImage(contentsOfFile: arguments[2]) else { fatalError("Load the genuine Gitrochi app icon") }
        let eyes = try String(contentsOfFile: arguments[3], encoding: .utf8)
        let language = arguments[4]
        terminalLayoutIcon = icon
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        let suite = "dev.gitrochi.terminal-layout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(language, forKey: AppLanguage.key)
        defaults.set("ko-KR", forKey: "terminalDictationLocale")
        defaults.set("재현 테스트, 음성 입력", forKey: "terminalDictationWords")
        defaults.set(true, forKey: "terminalDictationUseRepositoryWords")
        UserDefaults.standard.register(defaults: [AppLanguage.key: language])
        if language == "ko" { precondition(String(localized: "Cancel") != "Cancel", "The fixture bundle must load Korean localization") }
        let commands = TerminalQuickCommand.allCases.map(\.command)
        precondition(commands == ["gitch ck", "gitch preflight", "gitch pr status", "gitch ci"], "Quick actions preserve reviewable commands")
        let legacy = ["normal", "narrow", "split", "split-450", "short", "copied", "voice-idle", "voice-review", "voice-listening", "voice-unavailable", "voice-microphone-denied", "voice-speech-denied", "voice-language-unavailable", "voice-input-device", "voice-multiline"]
        let workflows = ["voice-korean-hints", "voice-cleanup-comparison", "voice-cleanup-applied", "voice-cleanup-restored", "voice-cleanup-source-edit", "voice-cleanup-working", "voice-ai-unavailable", "voice-ai-unconfigured", "voice-destination-terminal", "voice-destination-explain", "voice-destination-commit", "voice-destination-agent", "voice-confirmed-explain", "voice-confirmed-commit", "voice-confirmed-agent", "voice-commit-no-staged", "voice-send-failure", "voice-send-working"]
        let selectedScenario = ProcessInfo.processInfo.environment["GITROCHI_TERMINAL_LAYOUT_SCENARIO"]
        let scenarios = (language == "en" ? legacy + workflows : workflows).filter { selectedScenario == nil || $0 == selectedScenario }
        for appearance in ["light", "dark"] {
            for scenario in scenarios {
                let voice = scenario.hasPrefix("voice-")
                let narrow = scenario == "narrow", split = scenario == "split" || scenario == "split-450", short = scenario == "short"
                let actions = PreviewActions(), voiceActions = VoicePreviewActions(), dictation = TerminalDictation()
                let ai = AIStore.shared
                ai.requests = []; ai.unavailable = scenario == "voice-ai-unavailable"; ai.unconfigured = scenario == "voice-ai-unconfigured"
                terminalLayoutShowVocabulary = scenario == "voice-korean-hints"
                ai.holdCleanup = scenario == "voice-cleanup-working"
                voiceActions.failSend = scenario == "voice-send-failure"
                voiceActions.holdSend = scenario == "voice-send-working"
                terminalLayoutInitialDestination = scenario.contains("explain") || scenario == "voice-send-failure" || scenario == "voice-send-working" ? .explainChanges
                    : scenario.contains("commit") ? .commitDraft : scenario.contains("agent") ? .agent : .terminal
                if scenario == "voice-listening" {
                    dictation.state = .listening; dictation.level = 0.65; dictation.transcript = "Review the changes in this repository"
                } else if scenario == "voice-unavailable" {
                    dictation.state = .failure; dictation.error = "Speech recognition is unavailable right now. Try again in a moment."
                } else if scenario == "voice-microphone-denied" {
                    dictation.state = .failure; dictation.recovery = .microphone
                    dictation.error = "Allow Microphone access for Gitrochi in System Settings to use voice input."
                } else if scenario == "voice-speech-denied" {
                    dictation.state = .failure; dictation.recovery = .speech
                    dictation.error = "Allow Speech Recognition for Gitrochi in System Settings to use voice input."
                } else if scenario == "voice-language-unavailable" {
                    dictation.state = .failure; dictation.recovery = .language
                    dictation.error = "On-device speech is unavailable for this language. Choose another language or install its dictation support in System Settings."
                } else if scenario == "voice-input-device" {
                    dictation.state = .failure; dictation.recovery = .inputDevice
                    dictation.error = "No microphone is available. Connect a microphone and try again."
                } else if scenario == "voice-multiline" {
                    dictation.state = .review; dictation.transcript = "Review this diff.\n\tExplain the next steps.\u{1B}"
                } else if voice && scenario != "voice-idle" {
                    dictation.state = .review
                    dictation.transcript = workflows.contains(scenario) ? "음 RepoStore.swift 변경을 설명해줘" : "Review the changes in this repository and explain the next steps."
                }
                let source = dictation.transcript
                let content: AnyView, size: CGSize
                if voice {
                    content = AnyView(TerminalDictationComposer(dictation: dictation, target: "desktop-client",
                        repositoryName: "desktop-client", directory: "/Workspace/desktop-client",
                        repositoryWords: ["RepoStore.swift", "feature/voice", "Gitrochi"],
                        commitAvailable: scenario != "voice-commit-no-staged",
                        providerTitle: { $0 == .agent ? "Claude Code" : "Preview AI · local fixture" },
                        send: voiceActions.send,
                        insert: { _ in fatalError("The fixture never sends PTY input") }, dismiss: {})
                        .frame(width: 500, height: 660)
                        .background(TerminalLayoutProbe(identifier: "composer")))
                    size = CGSize(width: 544, height: 704)
                } else {
                    // docked: flat panes with a 1pt line between them, as under the centre column
                    content = AnyView(HStack(spacing: 0) {
                        TerminalPreviewPane(id: "primary", focused: true, short: short, eyes: eyes, actions: actions)
                        if split {
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                            TerminalPreviewPane(id: "secondary", focused: false, short: false, eyes: eyes, actions: actions)
                        }
                    })
                    size = CGSize(width: narrow ? 360 : scenario == "split-450" ? 450 : split ? 900 : 1000,
                                  height: short ? 120 : narrow ? 300 : split ? 340 : 450)
                    precondition(TerminalPanelLayout.railShown(height: size.height) == !short, "Only the short scenario is below the rail's height")
                }
                let host = NSHostingController(rootView: content.defaultAppStorage(defaults)
                    .environment(\.locale, Locale(identifier: language))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                    .tint(Color(nsColor: .systemBlue)).accentColor(Color(nsColor: .systemBlue))
                    .preferredColorScheme(appearance == "dark" ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                func probes() -> [TerminalLayoutProbe.Probe] { descendants(host.view).compactMap { $0 as? TerminalLayoutProbe.Probe } }
                func settle(_ duration: TimeInterval = 0.12) {
                    let deadline = Date().addingTimeInterval(duration)
                    repeat {
                        host.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
                        app.updateWindows(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                    } while Date() < deadline
                }
                func click(_ identifier: String, xFraction: CGFloat = 0.5) {
                    guard let probe = probes().first(where: { $0.fixtureIdentifier == identifier }) else { fatalError("Missing actual production control: " + identifier) }
                    scrollTo(identifier)
                    settle(0.05)
                    let point = probe.convert(NSPoint(x: probe.bounds.width * xFraction, y: probe.bounds.midY), to: nil)
                    let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    }
                    // Native borderless buttons track until mouse-up; queue it before delivering mouse-down.
                    app.postEvent(events[1], atStart: true)
                    window.sendEvent(events[0])
                    settle()
                }
                func scrollTo(_ identifier: String) {
                    guard let probe = probes().first(where: { $0.fixtureIdentifier == identifier }) else { fatalError("Missing production content: " + identifier) }
                    _ = probe.scrollToVisible(probe.bounds)
                    if let scroll = descendants(host.view).compactMap({ $0 as? NSScrollView }).filter({ $0.bounds.height > 200 }).max(by: { $0.bounds.height < $1.bounds.height }),
                       let document = scroll.documentView {
                        let frame = probe.convert(probe.bounds, to: document)
                        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                        let y = min(maximum, max(0, frame.midY - scroll.contentView.bounds.height * 0.5))
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    settle()
                }
                settle(0.2)
                precondition(ai.requests.isEmpty && voiceActions.sent.isEmpty, "Opening any destination cannot send text or run AI")
                if scenario == "copied" { click("folder-copy"); precondition(actions.copies == 1) }
                if scenario.contains("cleanup") || scenario == "voice-ai-unavailable" {
                    click("composer-cleanup")
                    precondition(ai.requests.count == 1, "Cleanup starts only after its actual button is clicked")
                    let payload = try JSONSerialization.jsonObject(with: Data(ai.requests[0].prompt.utf8)) as! [String: Any]
                    precondition(payload["transcript"] as? String == source && (payload["vocabulary"] as? [String])?.contains("RepoStore.swift") == true, "Cleanup receives the exact reviewed text and enabled hints")
                    precondition(dictation.transcript == source && voiceActions.sent.isEmpty, "A suggestion cannot replace or send the draft automatically")
                    if scenario == "voice-cleanup-working" {
                        click("composer-insert")
                        precondition(voiceActions.sent.isEmpty && ai.requests.count == 1, "Cleanup in flight cannot submit or duplicate requests")
                    } else if scenario != "voice-ai-unavailable" {
                        precondition(probes().contains { $0.fixtureIdentifier == "composer-comparison" }, "Successful cleanup shows the real comparison view")
                        if scenario == "voice-cleanup-applied" || scenario == "voice-cleanup-restored" {
                            click("composer-use-cleaned")
                            precondition(dictation.transcript == "RepoStore.swift 변경을 설명해줘.", "Only Use cleaned text applies the suggestion")
                            if scenario == "voice-cleanup-restored" {
                                click("composer-restore"); precondition(dictation.transcript == source, "Restore original recovers the complete original")
                            }
                        } else if scenario == "voice-cleanup-source-edit" {
                            dictation.transcript = "수정된 원문을 그대로 유지해줘"; settle()
                            precondition(!probes().contains { $0.fixtureIdentifier == "composer-comparison" }, "Editing the draft invalidates the old suggestion")
                        } else { scrollTo("composer-comparison") }
                    }
                }
                if scenario == "voice-ai-unconfigured" {
                    click("composer-cleanup")
                    precondition(ai.requests.isEmpty, "An unconfigured provider cannot receive cleanup text")
                }
                if scenario == "voice-korean-hints" {
                    precondition(probes().contains { $0.fixtureIdentifier == "composer-custom-words" }, "Expanded hints must show the actual custom-word editor")
                    scrollTo("composer-vocabulary")
                }
                if scenario.contains("destination-") || scenario.contains("confirmed-") || scenario == "voice-commit-no-staged" || scenario == "voice-send-failure" || scenario == "voice-send-working" {
                    click("composer-insert")
                    if terminalLayoutInitialDestination == .terminal {
                        precondition(voiceActions.sent.count == 1 && voiceActions.sent[0].destination == .terminal, "Terminal insertion uses only the explicit submit action")
                    } else if scenario == "voice-commit-no-staged" {
                        precondition(voiceActions.sent.isEmpty && !probes().contains { $0.fixtureIdentifier == "composer-confirmation" }, "Commit review stays disabled when nothing is staged")
                        scrollTo("composer-destination")
                    } else {
                        precondition(voiceActions.sent.isEmpty && probes().contains { $0.fixtureIdentifier == "composer-confirmation" }, "Review shows the real confirmation without dispatching")
                        scrollTo("composer-confirmation")
                        if scenario.contains("confirmed-") || scenario == "voice-send-failure" || scenario == "voice-send-working" {
                            click("composer-confirm-send")
                            precondition(voiceActions.sent.count == (scenario == "voice-send-failure" || scenario == "voice-send-working" ? 0 : 1), "Dispatch occurs only after the actual confirmation button")
                            if scenario == "voice-send-working" {
                                click("composer-confirm-send"); click("composer-cleanup")
                                precondition(voiceActions.attempts == 1 && ai.requests.isEmpty, "In-flight sends cannot duplicate dispatch or start cleanup")
                                scrollTo("composer-confirmation")
                            }
                        }
                    }
                }
                let measured = probes(), bounds = host.view.bounds
                var measurements: [String: [Double]] = [:]
                // a split draws every control once per pane: the second pane's are "<name>#2"
                func key(_ identifier: String) -> String { measurements[identifier] == nil ? identifier : identifier + "#2" }
                func count(_ identifier: String) -> Int { measured.filter { $0.fixtureIdentifier == identifier }.count }
                for probe in measured {
                    let frame = probe.convert(probe.bounds, to: host.view)
                    precondition(frame.width > 0 && frame.height > 0, "A measured production control must retain its hit area: " + probe.fixtureIdentifier)
                    precondition(frame.minX >= -1 && frame.maxX <= bounds.maxX + 1, "Production content cannot overflow horizontally: " + probe.fixtureIdentifier)
                    if !voice || ["composer", "composer-cancel", "composer-insert"].contains(probe.fixtureIdentifier) {
                        precondition(bounds.insetBy(dx: -1, dy: -1).contains(frame), "Persistent controls must fit in the viewport: " + probe.fixtureIdentifier)
                    }
                    if ["new", "voice", "actions", "hide"].contains(probe.fixtureIdentifier) {
                        precondition(frame.width >= 26 && frame.height >= 26, "Toolbar hit areas remain intact")
                    }
                    measurements[key(probe.fixtureIdentifier)] = [frame.origin.x, frame.origin.y, frame.width, frame.height].map(Double.init)
                }
                if voice {
                    precondition(measurements["composer-editor"] != nil && measurements["composer-cancel"] != nil && measurements["composer-insert"] != nil)
                    precondition(measurements["composer-editor"]![3] >= 80)
                    precondition((measurements["composer-stop"] != nil) == (scenario == "voice-listening"))
                    precondition((measurements["composer-recovery"] != nil) == (dictation.recovery != nil))
                    precondition((measurements["composer-insertion-preview"] != nil) == (scenario == "voice-multiline"))
                } else {
                    let panes = split ? 2 : 1, compact = scenario == "split-450"
                    let paneWidth = Double(bounds.width - (split ? 1 : 0)) / Double(panes)
                    precondition(count("tabs") == panes && count("actions") == panes, "Every pane has its tabs and its actions menu")
                    precondition(measurements["tabs"]![2] >= 40, "At least one tab stays readable")
                    // no logo: the tabs start the bar
                    precondition(measurements["tabs"]![0] <= measurements["pane"]![0] + 12, "The tab bar starts with the tabs")
                    precondition(TerminalPanelLayout.compactBar(width: paneWidth) == compact, "The fixture's narrowest split is the compact one")
                    precondition(count("new") == (compact ? 0 : panes) && count("voice") == (compact ? 0 : panes), "A compact bar folds New terminal and Voice input into the actions menu")
                    precondition(count("hide") == (compact ? 0 : 1), "Hide appears once, in the corner pane")
                    precondition(count("quick-rail") == (short ? 0 : panes), "A short pane hides the command rail")
                    precondition(count("commands") == (short || !TerminalPanelLayout.commandsFolded(width: paneWidth) ? 0 : panes), "A narrow pane folds the commands into one menu")
                    let hidden = TerminalPanelLayout.tabOverflow(count: 3, selected: 0, width: TerminalPanelLayout.tabStripWidth(bar: paneWidth, controls: compact ? 1 : 4)).hidden.count
                    precondition((count("overflow") > 0) == (hidden > 0), "Tabs that do not fit go into the » menu")
                    precondition(count("status") == panes, "The status line always stays")
                }
                precondition(actions.commands.isEmpty && actions.copies == (scenario == "copied" ? 1 : 0) && actions.nextTabs == 0, "Rendering cannot execute commands or touch the clipboard")
                guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("Could not allocate terminal preview") }
                host.view.cacheDisplay(in: bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode terminal preview") }
                let name = scenario + "-" + appearance + (language == "ko" ? "-ko" : "")
                try png.write(to: output.appendingPathComponent(name + ".png"))
                let result: [String: Any] = ["ok": true, "scenario": scenario, "appearance": appearance, "language": language, "bundleLanguage": Bundle.main.preferredLocalizations.first ?? "",
                    "width": bounds.width, "height": bounds.height, "controls": measurements, "quickCommands": commands,
                    "cleanupRequests": ai.requests.count, "explicitSends": voiceActions.sent.count, "syntheticOutput": true, "genuineAppIcon": true, "screenshot": name + ".png"]
                let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                try json.write(to: output.appendingPathComponent(name + ".json"))
                print("PASS " + name + " (" + String(measurements.count) + " measured controls)")
                fflush(stdout)
                ai.pendingCleanup?.resume(); ai.pendingCleanup = nil
                voiceActions.pendingSend?.resume(); voiceActions.pendingSend = nil
                settle(0.04)
                window.orderOut(nil); window.contentViewController = nil
            }
        }
        print("Terminal voice layout previews: " + output.path)
    }
}
