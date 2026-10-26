import Foundation

/// Local view preferences never change the shared GitHub project or invent unloaded data.
struct ProjectWorkbenchFilter: Codable, Equatable {
    var query = ""
    var kind = "all"
    var onlyCurrentRepository = false
    var onlyMine = false
    var includeArchived = false
    var sort = "updated"

    func apply(_ rows: [HubProjectRow], repository: String, username: String) -> [HubProjectRow] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let result = rows.filter { row in
            guard includeArchived || !row.archived else { return false }
            guard kind == "all" || row.kind.rawValue == kind else { return false }
            guard !onlyCurrentRepository || !repository.isEmpty && row.repository.caseInsensitiveCompare(repository) == .orderedSame else { return false }
            guard !onlyMine || row.assignees.contains(where: { $0.caseInsensitiveCompare(username) == .orderedSame }) else { return false }
            let searchable = ([row.title, row.body, row.repository, row.number.map { "#\($0)" } ?? ""] + row.labels + row.assignees).joined(separator: " ").lowercased()
            return terms.allSatisfy { searchable.contains($0) }
        }
        if sort == "manual" { return result }
        return result.sorted { lhs, rhs in
            if sort == "title" { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
            if sort == "number", lhs.number != rhs.number { return (lhs.number ?? Int.max) < (rhs.number ?? Int.max) }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }
}

enum ProjectWorkbench {
    static func suggestedBranch(number: Int?, title: String) -> String {
        let words = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let slug = String(words.joined(separator: "-").prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = [number.map(String.init), slug.isEmpty ? "task" : slug].compactMap { $0 }.joined(separator: "-")
        return "feature/" + suffix
    }

    static func date(_ value: String?) -> Date? {
        guard let value, value.count == 10 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
}
