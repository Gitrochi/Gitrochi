import AppKit
import AVFoundation
import Combine
import Observation
import Speech

/// On-device dictation for Gitrochi's terminal composer; audio and transcripts are never stored.
@MainActor @Observable
final class TerminalDictation {
    typealias State = TerminalDictationRun.State

    /// Recovery only supplies a destination; the composer opens Settings after an explicit click.
    enum Recovery: Equatable {
        case microphone, speech, language, inputDevice

        var settingsURL: URL? {
            let destination: String
            switch self {
            case .microphone:
                destination = "com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
            case .speech:
                destination = "com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition"
            case .language:
                destination = "com.apple.Keyboard-Settings.extension"
            case .inputDevice:
                destination = "com.apple.Sound-Settings.extension"
            }
            return URL(string: "x-apple.systempreferences:" + destination)
        }
    }

    var transcript = ""
    private(set) var level: Float = 0
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var recovery: Recovery?
    private var run = TerminalDictationRun()

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var authorization: Task<Void, Never>?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var inactive: AnyCancellable?
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var requestingPermissions = false

    var state: State { run.state }
    var isCapturing: Bool { state == .listening || state == .finishing }
    var isBusy: Bool { state == .requesting || isCapturing }
    var needsPermissionSetup: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    init() {
        inactive = NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // System permission dialogs can deactivate the app; this run never starts audio.
                    if Self.cancelsOnDeactivation(state: self.state, requestingPermissions: self.requestingPermissions) {
                        self.cancel()
                    }
                }
            }
    }

    deinit {
        authorization?.cancel()
        finishTimeout?.cancel()
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        recognition?.cancel()
    }

    func start(localeIdentifier: String, contextualStrings: [String] = []) {
        cancel()
        let vocabulary = TerminalSpeechVocabulary.bounded(contextualStrings)
        let needsPermissions = needsPermissionSetup
        requestingPermissions = needsPermissions
        let token = run.begin()
        authorization = Task { [weak self] in
            let speech = await Self.speechPermission()
            guard let self, self.run.accepts(token), !Task.isCancelled else { return }
            guard speech == .authorized else {
                self.fail(token, String(localized: "Allow Speech Recognition for Gitrochi in System Settings to use voice input."), recovery: .speech)
                return
            }
            let microphone = await Self.microphonePermission()
            guard self.run.accepts(token), !Task.isCancelled else { return }
            guard microphone else {
                self.fail(token, String(localized: "Allow Microphone access for Gitrochi in System Settings to use voice input."), recovery: .microphone)
                return
            }
            if needsPermissions {
                self.cancel()
                self.notice = String(localized: "Access is ready. Choose Start listening to begin.")
                return
            }
            guard NSApp.isActive else { self.cancel(); return }
            self.beginCapture(localeIdentifier: localeIdentifier, contextualStrings: vocabulary, token: token)
        }
    }

    static func cancelsOnDeactivation(state: State, requestingPermissions: Bool) -> Bool {
        state == .listening || state == .finishing || (state == .requesting && !requestingPermissions)
    }

    func stop() {
        // Releasing a short hold while permission is pending must never start a microphone later.
        if state == .requesting { cancel(); return }
        guard let token = run.id, run.finish(token) else { return }
        stopAudio()
        request?.endAudio()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.complete(token)
        }
    }

    func cancel() {
        // Invalidate before stopping Speech, which can synchronously deliver a completion callback.
        run.cancel()
        teardown()
        transcript = ""
        level = 0
        error = nil
        notice = nil
        recovery = nil
        requestingPermissions = false
    }

    private func beginCapture(localeIdentifier: String, contextualStrings: [String], token: UUID) {
        guard run.accepts(token) else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition else {
            fail(token, String(localized: "On-device speech is unavailable for this language. Choose another language or install its dictation support in System Settings."), recovery: .language)
            return
        }
        guard recognizer.isAvailable else {
            fail(token, String(localized: "Speech recognition is unavailable right now. Try again in a moment."))
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail(token, String(localized: "No microphone is available. Connect a microphone and try again."), recovery: .inputDevice)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = contextualStrings
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.engine = engine
        self.recognizer = recognizer
        self.request = request
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let sampleCount = Int(buffer.frameLength)
            var power: Float = 0
            if sampleCount > 0, let samples = buffer.floatChannelData?[0] {
                for index in 0..<sampleCount { power += samples[index] * samples[index] }
                power = min(1, sqrt(power / Float(sampleCount)) * 5)
            }
            let meter = power
            Task { @MainActor [weak self] in
                guard let self, self.run.accepts(token), self.state == .listening else { return }
                self.level = meter
            }
        }
        hasTap = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.run.accepts(token) else { return }
                if let text { self.transcript = text }
                if final {
                    self.complete(token)
                } else if recognitionError != nil {
                    if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.fail(token, String(localized: "Speech recognition stopped. Check your microphone and try again."))
                    } else {
                        self.complete(token)
                    }
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            run.listen(token)
        } catch {
            fail(token, String(localized: "The microphone could not start. Check your input device in System Settings and try again."), recovery: .inputDevice)
        }
    }

    private func complete(_ token: UUID) {
        let hasText = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard run.complete(token, hasText: hasText) else { return }
        teardown()
        level = 0
        recovery = nil
        error = hasText ? nil : String(localized: "No speech was recognized. Try again.")
    }

    private func fail(_ token: UUID, _ message: String, recovery: Recovery? = nil) {
        guard run.fail(token) else { return }
        teardown()
        level = 0
        error = message
        self.recovery = recovery
    }

    private func stopAudio() {
        engine?.stop()
        if hasTap {
            engine?.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        level = 0
    }

    private func teardown() {
        authorization?.cancel()
        authorization = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        stopAudio()
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        request = nil
        engine = nil
    }

    private static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }
}
