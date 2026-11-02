import Foundation
import CoreFoundation

/// Parses explicitly pasted question text without reading a client, choosing a session or saving anything.
enum LedgerChatGPTDraft {
    struct Question: Codable, Hashable {
        var text: String
        var options: [LedgerQuestion.Option]
        var multiSelect: Bool?
        var suggestedAnswer: String?

        var value: LedgerJSON {
            var result: [String: LedgerJSON] = ["text": .string(text), "options": .array(options.map { option in
                var value: [String: LedgerJSON] = ["label": .string(option.label)]
                if let description = option.description { value["description"] = .string(description) }
                if let recommended = option.recommended { value["recommended"] = .bool(recommended) }
                return .object(value)
            })]
            if let multiSelect { result["multiSelect"] = .bool(multiSelect) }
            if let suggestedAnswer { result["suggestedAnswer"] = .string(suggestedAnswer) }
            return .object(result)
        }
    }

    private enum Failure: String, LocalizedError {
        case empty = "Paste a question first."
        case tooLarge = "Pasted text is limited to 64 KiB."
        case json = "Could not read the pasted JSON."
        case multiple = "Use Paste reports for multiple questions."
        case text = "Question text must be nonempty text."
        case options = "Question options must be an array."
        case labels = "Question option labels must be nonempty and distinct."
        case strings = "Question descriptions and suggestions must be text."
        case flags = "Question flags must be true or false."
        var errorDescription: String? { String(localized: String.LocalizationValue(rawValue)) }
    }

    static func parseQuestion(_ raw: String) throws -> Question {
        guard raw.utf8.count <= 64 * 1024 else { throw Failure.tooLarge }
        var text = trim(raw)
        guard !text.isEmpty else { throw Failure.empty }
        var json = text.hasPrefix("{") || text.hasPrefix("[")
        if match(#"^```(?:ledger|json)?[ \t]*\r?\n"#, in: text, insensitive: true) != nil {
            let fences = try NSRegularExpression(pattern: #"^```(?:ledger|json)?[ \t]*$"#, options: [.anchorsMatchLines, .caseInsensitive])
            if fences.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) > 2 { throw Failure.multiple }
            guard let inner = match(#"^```(?:ledger|json)?[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*$"#, in: text, group: 1, insensitive: true),
                  !inner.contains("```") else { throw Failure.json }
            text = trim(inner)
            json = true
        }
        if json {
            let value: Any
            do { value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }
            catch { throw Failure.json }
            return try single(value)
        }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var blocks: [(start: Int, end: Int, labels: [String])] = []
        var index = 0
        while index < lines.count {
            guard let first = bullet(lines[index]) else { index += 1; continue }
            let start = index
            var labels = [first]
            while index + 1 < lines.count, let next = bullet(lines[index + 1]) { labels.append(next); index += 1 }
            blocks.append((start, index + 1, labels))
            index += 1
        }
        guard blocks.count <= 1 else { throw Failure.multiple }
        guard let block = blocks.first, block.start > 0 else { return Question(text: text, options: []) }
        let body = trim((Array(lines[..<block.start]) + Array(lines[block.end...])).joined(separator: "\n"))
        return try question(["text": body, "options": block.labels])
    }

    private static func single(_ value: Any) throws -> Question {
        if let entries = value as? [Any] {
            guard entries.count <= 1 else { throw Failure.multiple }
            return try question(entries.first)
        }
        if let object = value as? [String: Any], object["text"] == nil,
           object.keys.contains("question") || object.keys.contains("questions") {
            var entries: [Any] = []
            if let entry = object["question"], !(entry is NSNull) { entries.append(entry) }
            if let supplied = object["questions"] { entries += (supplied as? [Any]) ?? [supplied] }
            guard entries.count <= 1 else { throw Failure.multiple }
            if let text = object["question"] as? String,
               object.keys.contains("options") || object.keys.contains("multiSelect") || object.keys.contains("suggestedAnswer") {
                var form = object
                form["text"] = text
                form["question"] = nil
                form["questions"] = nil
                return try question(form)
            }
            return try question(entries.first)
        }
        return try question(value)
    }

    private static func question(_ value: Any?) throws -> Question {
        if let text = value as? String { return Question(text: try requiredText(text), options: []) }
        guard let object = value as? [String: Any] else { throw Failure.text }
        if let question = object["question"], !(question is NSNull) { throw Failure.multiple }
        if let questions = object["questions"], (questions as? [Any])?.isEmpty != true { throw Failure.multiple }
        let text = try requiredText(object["text"])
        var options: [LedgerQuestion.Option] = []
        if let supplied = object["options"] {
            guard let choices = supplied as? [Any] else { throw Failure.options }
            for choice in choices {
                let fields: [String: Any]
                if let label = choice as? String { fields = ["label": label] }
                else if let object = choice as? [String: Any] { fields = object }
                else { throw Failure.labels }
                guard let rawLabel = fields["label"] as? String, !trim(rawLabel).isEmpty else { throw Failure.labels }
                let label = trim(rawLabel)
                guard !options.contains(where: { $0.label == label }) else { throw Failure.labels }
                let description = try optionalText(fields, "description")
                let explicit = try flag(fields, "recommended")
                let recommended = explicit ?? (marked(label) || marked(description ?? "") ? true : nil)
                options.append(.init(label: label, description: description, recommended: recommended))
            }
        }
        return Question(text: text, options: options, multiSelect: try flag(object, "multiSelect"),
                        suggestedAnswer: try optionalText(object, "suggestedAnswer"))
    }

    private static func requiredText(_ value: Any?) throws -> String {
        guard let text = value as? String, !trim(text).isEmpty else { throw Failure.text }
        return trim(text)
    }

    private static func optionalText(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value as? String else { throw Failure.strings }
        return trim(text)
    }

    private static func flag(_ object: [String: Any], _ key: String) throws -> Bool? {
        guard let value = object[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.flags }
        return number.boolValue
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func marked(_ text: String) -> Bool {
        match(#"[(\[（【]\s*(?:recommended|recommend|suggested|추천|권장|추천안)\s*[)\]）】]\s*$"#, in: text, insensitive: true) != nil
    }
    private static func bullet(_ text: String) -> String? {
        match(#"^[ \t]*(?:[-*+•]|\d+[.)])(?:[ \t]+|$)(.*?)[ \t]*$"#, in: text, group: 1)
    }
    private static func match(_ pattern: String, in text: String, group: Int = 0, insensitive: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: insensitive ? .caseInsensitive : []),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}
