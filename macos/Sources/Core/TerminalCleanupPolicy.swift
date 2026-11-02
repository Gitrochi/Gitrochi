import Foundation

/// A cleanup may change presentation, but names, commands, quantities and negation remain the user's words.
enum TerminalCleanupPolicy {
    static let maximumLength = 8_000
    enum Failure: Error { case invalidInput, invalidResponse, changedMeaning }

    static func suggestion(from response: String, original: String, vocabulary: [String]) throws -> String {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.count <= maximumLength else { throw Failure.invalidInput }
        guard response.utf8.count <= 65_536 else { throw Failure.invalidResponse }
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: .newlines)
            guard lines.count >= 3, ["```", "```json"].contains(lines[0].lowercased()), lines.last == "```" else { throw Failure.invalidResponse }
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["text"], let candidate = object["text"] as? String else { throw Failure.invalidResponse }
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength,
              text.count <= max(32, Int(Double(original.count) * 1.3)),
              !text.unicodeScalars.contains(where: { $0.value < 0x20 && ![9, 10, 13].contains($0.value) }) else { throw Failure.invalidResponse }
        guard protected(original, vocabulary: vocabulary) == protected(text, vocabulary: vocabulary),
              negations(original) == negations(text) else { throw Failure.changedMeaning }
        let sourceWords = words(original).map { $0.lowercased() }.filter { !fillers.contains($0) }
        let cleanedWords = words(text).map { $0.lowercased() }.filter { !fillers.contains($0) }
        let sourceSet = Set(sourceWords), sourceJoined = sourceWords.joined()
        let cleanedLength = cleanedWords.joined().count
        guard cleanedLength >= max(1, Int(Double(sourceJoined.count) * 0.5)) else { throw Failure.changedMeaning }
        for word in cleanedWords where !sourceSet.contains(word) && !sourceJoined.contains(word) {
            // A one-letter correction is allowed; paraphrases and answers are not transcription cleanup.
            guard word.count >= 5, sourceWords.contains(where: { $0.count >= 5 && oneEditApart($0, word) }) else { throw Failure.changedMeaning }
        }
        return text
    }

    private static let fillers: Set<String> = ["음", "어", "어어", "저기", "um", "uh", "umm", "uhh"]
    private static let commandWords: Set<String> = ["git", "gitch", "npm", "pnpm", "yarn", "cargo", "swift", "python", "python3", "node", "claude", "codex", "gemini", "brew", "rm", "mv", "cp", "curl", "ssh", "docker", "preflight", "ck", "ci", "pr", "status", "main", "master"]

    private static func protected(_ text: String, vocabulary: [String]) -> [String: Int] {
        var tokens = matches(#"[A-Za-z0-9_./:@=+-]+"#, in: text).map { raw -> String in
            var token = raw
            while token.hasSuffix(".") { token.removeLast() }
            return token
        }.filter { token in
            guard token.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
            return token.rangeOfCharacter(from: CharacterSet(charactersIn: "/_.:@=+-0123456789")) != nil
                || matches(#"[a-z][A-Z]|[A-Z]{2}"#, in: token).count > 0
                || commandWords.contains(token.lowercased())
        }
        tokens += matches(#"[+-]?\d+(?:[.,]\d+)*%?"#, in: text).map { "number:" + $0 }
        tokens += matches(#"`[^`]+`"#, in: text).map { "code:" + $0 }
        for item in vocabulary.prefix(64) where !item.isEmpty && item.count <= 96 {
            let count = text.components(separatedBy: item).count - 1
            tokens += Array(repeating: "vocabulary:" + item, count: count)
        }
        return counts(tokens)
    }

    private static func negations(_ text: String) -> [String: Int] {
        let joined = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        var markers: [String] = []
        for root in ["하지마", "않", "말고", "말아", "아니", "없이", "금지", "제외"] {
            markers += Array(repeating: root, count: joined.components(separatedBy: root).count - 1)
        }
        markers += matches(#"(?:^|[\s.,!?])(?:안|못)(?=\s|[가-힣])"#, in: text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
        markers += matches(#"(?i)\b(?:no|not|never|without|cannot|can't|don't|won't|mustn't|shouldn't)\b"#, in: text).map { $0.lowercased() }
        return counts(markers)
    }

    private static func words(_ text: String) -> [String] { matches(#"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#, in: text) }
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }
    private static func counts(_ values: [String]) -> [String: Int] { values.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
    private static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let left = Array(a), right = Array(b)
        guard abs(left.count - right.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < left.count && j < right.count {
            if left[i] == right[j] { i += 1; j += 1; continue }
            edits += 1
            guard edits <= 1 else { return false }
            if left.count >= right.count { i += 1 }
            if right.count >= left.count { j += 1 }
        }
        return edits + (left.count - i) + (right.count - j) <= 1
    }
}
