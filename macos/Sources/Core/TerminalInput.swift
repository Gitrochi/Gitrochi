import Foundation

/// Text reviewed outside the terminal must never carry an Enter key or terminal control sequence.
enum TerminalInput {
    static func singleLine(_ text: String) -> String {
        let separated = text.unicodeScalars.map { scalar -> String in
            let control = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            return control || CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : String(scalar)
        }.joined()
        return separated.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A finished or cancelled recording cannot accept late permission, meter or transcription callbacks.
struct TerminalDictationRun {
    enum State: Equatable {
        case idle, requesting, listening, finishing, review, failure
    }

    private(set) var state: State = .idle
    private(set) var id: UUID?

    mutating func begin() -> UUID {
        let next = UUID()
        id = next
        state = .requesting
        return next
    }

    func accepts(_ token: UUID) -> Bool { id == token }

    @discardableResult
    mutating func listen(_ token: UUID) -> Bool {
        guard accepts(token), state == .requesting else { return false }
        state = .listening
        return true
    }

    @discardableResult
    mutating func finish(_ token: UUID) -> Bool {
        guard accepts(token), state == .listening else { return false }
        state = .finishing
        return true
    }

    @discardableResult
    mutating func complete(_ token: UUID, hasText: Bool) -> Bool {
        guard accepts(token) else { return false }
        id = nil
        state = hasText ? .review : .failure
        return true
    }

    @discardableResult
    mutating func fail(_ token: UUID) -> Bool {
        guard accepts(token) else { return false }
        id = nil
        state = .failure
        return true
    }

    mutating func cancel() {
        id = nil
        state = .idle
    }
}
