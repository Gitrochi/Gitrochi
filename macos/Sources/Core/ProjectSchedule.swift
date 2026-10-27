import Foundation

/// Windows: entities/hosting/model/project-schedule.ts. Dates are calendar days, never instants.
struct ProjectScheduleSettings: Codable, Equatable {
    var startFieldID: String? = nil
    var dueFieldID: String? = nil
    var statusFieldID: String? = nil
    var completedOptionIDs: [String] = []
}

struct ProjectScheduleFields {
    var start: HubProjectField?
    var due: HubProjectField?
    var status: HubProjectField?
}

struct ProjectScheduleEntry: Identifiable {
    var row: HubProjectRow
    var start: String?
    var due: String?
    var completed: Bool
    var invalidDate: Bool
    var invalidRange: Bool
    var id: String { row.id }
    var date: String? { due ?? start }
}

struct ProjectScheduleSummary: Equatable {
    var active = 0
    var overdue = 0
    var today = 0
    var upcoming = 0
    var unscheduled = 0
    var completed = 0
    var invalid = 0
}

struct ProjectScheduleWorkload: Identifiable {
    var assignee: String
    var summary: ProjectScheduleSummary
    var id: String { assignee.lowercased() }
}

struct ProjectScheduleChange: Equatable {
    var fieldID: String
    var value: String
}

enum ProjectScheduleError: Error {
    case invalidDate, invalidRange, missingDateField, unavailableItem
}

enum ProjectSchedule {
    private static let monthStarts = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    private static func leap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }
    private static func daysBeforeYear(_ year: Int) -> Int { let previous = year - 1; return previous * 365 + previous / 4 - previous / 100 + previous / 400 }

    static func parseDay(_ value: String?) -> Date? {
        guard let value, value.utf8.count == 10 else { return nil }
        let bytes = Array(value.utf8)
        guard bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }),
              let year = Int(value.prefix(4)), (1...9999).contains(year),
              let month = Int(value.dropFirst(5).prefix(2)), (1...12).contains(month), let day = Int(value.suffix(2)) else { return nil }
        let monthDays = [31, leap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { return nil }
        // Calendar's historical reform skips dates in 1582; project dates use proleptic Gregorian days.
        let ordinal = daysBeforeYear(year) + monthStarts[month - 1] + (month > 2 && leap(year) ? 1 : 0) + day - 1
        return Date(timeIntervalSince1970: Double(ordinal - 719_162) * 86_400)
    }

    static func dayString(_ date: Date) -> String {
        let ordinal = Int(floor(date.timeIntervalSince1970 / 86_400)) + 719_162
        guard ordinal >= 0, ordinal < daysBeforeYear(10_000) else { return "" }
        var low = 1, high = 10_000
        while low + 1 < high { let middle = (low + high) / 2; if daysBeforeYear(middle) <= ordinal { low = middle } else { high = middle } }
        let year = low, yearDay = ordinal - daysBeforeYear(year)
        let starts = monthStarts.enumerated().map { $0.element + ($0.offset > 1 && leap(year) ? 1 : 0) }
        let monthIndex = starts.lastIndex { $0 <= yearDay }!
        return String(format: "%04d-%02d-%02d", year, monthIndex + 1, yearDay - starts[monthIndex] + 1)
    }

    static func today(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func addDays(_ day: String, _ count: Int) -> String? {
        guard let date = parseDay(day), count >= -3_652_058, count <= 3_652_058 else { return nil }
        let result = date.addingTimeInterval(Double(count) * 86_400)
        let text = dayString(result)
        return parseDay(text) == nil ? nil : text
    }

    static func weekDays(_ day: String, weekStartsOn: Int = 1) -> [String] {
        guard let date = parseDay(day), (0...6).contains(weekStartsOn) else { return [] }
        let weekday = ((Int(floor(date.timeIntervalSince1970 / 86_400)) + 4) % 7 + 7) % 7
        guard let first = addDays(day, -((weekday - weekStartsOn + 7) % 7)) else { return [] }
        return (0..<7).compactMap { addDays(first, $0) }
    }

    static func monthDays(_ day: String, weekStartsOn: Int = 1) -> [String] {
        guard parseDay(day) != nil,
              let first = weekDays(String(day.prefix(7)) + "-01", weekStartsOn: weekStartsOn).first else { return [] }
        return (0..<42).compactMap { addDays(first, $0) }
    }

    static func fields(_ fields: [HubProjectField], settings: ProjectScheduleSettings = .init()) -> ProjectScheduleFields {
        let dates = fields.filter { $0.kind == .date }
        func explicit(_ id: String?, candidates: [HubProjectField]) -> HubProjectField? {
            guard let id else { return nil }
            return candidates.first { $0.id == id }
        }
        func named(_ candidates: [HubProjectField], names: [String]) -> HubProjectField? {
            candidates.first { names.contains($0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")) }
        }
        let start = settings.startFieldID == nil ? dates.first { $0.id == "local-start" } ?? named(dates, names: ["start", "start date", "begin", "begin date", "planned start"]) : explicit(settings.startFieldID, candidates: dates)
        let remaining = dates.filter { $0.id != start?.id }
        let due = settings.dueFieldID == nil ? remaining.first { $0.id == "local-due" } ?? named(remaining, names: ["due", "due date", "deadline", "end", "end date", "target", "target date"]) ?? (remaining.count == 1 ? remaining.first : nil) : explicit(settings.dueFieldID, candidates: dates)
        let selects = fields.filter { $0.kind == .singleSelect }
        let status = settings.statusFieldID == nil ? selects.first { $0.id == "local-status" } ?? named(selects, names: ["status", "state"]) : explicit(settings.statusFieldID, candidates: selects)
        return ProjectScheduleFields(start: start, due: due, status: status)
    }

    static func entries(_ rows: [HubProjectRow], fields: [HubProjectField], settings: ProjectScheduleSettings = .init()) -> [ProjectScheduleEntry] {
        let selected = self.fields(fields, settings: settings)
        return rows.filter { !$0.archived && $0.kind != .redacted }.map { row in
            let rawStart = selected.start.map { value(row, field: $0) } ?? ""
            let rawDue = selected.due.map { value(row, field: $0) } ?? ""
            let start = parseDay(rawStart) == nil ? nil : rawStart
            let due = parseDay(rawDue) == nil ? nil : rawDue
            let nativeClosed = ["closed", "merged"].contains(row.state.lowercased())
            let status = selected.status.map { value(row, field: $0) }
            let configuredComplete = selected.status?.options.contains { $0.id == status && settings.completedOptionIDs.contains($0.id) } == true
            return ProjectScheduleEntry(row: row, start: start, due: due, completed: nativeClosed || configuredComplete,
                invalidDate: !rawStart.isEmpty && start == nil || !rawDue.isEmpty && due == nil,
                invalidRange: start != nil && due != nil && start! > due!)
        }
    }

    static func summary(_ entries: [ProjectScheduleEntry], today: String) -> ProjectScheduleSummary {
        var result = ProjectScheduleSummary()
        let horizon = addDays(today, 7)
        for entry in entries {
            if entry.invalidDate || entry.invalidRange { result.invalid += 1 }
            if entry.completed { result.completed += 1; continue }
            result.active += 1
            if entry.date == nil { result.unscheduled += 1 }
            guard parseDay(today) != nil, !entry.invalidRange else { continue }
            if let due = entry.due, due < today { result.overdue += 1 }
            if entry.date == today { result.today += 1 }
            if let day = entry.date, let horizon, day > today && day <= horizon { result.upcoming += 1 }
        }
        return result
    }

    /// Shared tasks count once per assignee, so workload totals may exceed the project total.
    static func workload(_ entries: [ProjectScheduleEntry], today: String) -> [ProjectScheduleWorkload] {
        var grouped: [String: [ProjectScheduleEntry]] = [:], names: [String: String] = [:]
        for entry in entries {
            var seen = Set<String>()
            let assignees = entry.row.assignees.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for assignee in assignees.isEmpty ? [""] : assignees {
                let key = assignee.lowercased()
                guard seen.insert(key).inserted else { continue }
                names[key] = names[key] ?? assignee
                grouped[key, default: []].append(entry)
            }
        }
        return grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return false }; if rhs.isEmpty { return true }; return lhs < rhs
        }.map { ProjectScheduleWorkload(assignee: names[$0]!, summary: summary(grouped[$0]!, today: today)) }
    }

    static func reschedule(_ row: HubProjectRow, fields: [HubProjectField], settings: ProjectScheduleSettings = .init(), targetDay: String) throws -> [ProjectScheduleChange] {
        guard !row.archived, row.kind != .redacted else { throw ProjectScheduleError.unavailableItem }
        guard let target = parseDay(targetDay) else { throw ProjectScheduleError.invalidDate }
        let selected = self.fields(fields, settings: settings)
        guard let anchor = selected.due ?? selected.start else { throw ProjectScheduleError.missingDateField }
        guard let entry = entries([row], fields: fields, settings: settings).first, !entry.invalidDate else { throw ProjectScheduleError.invalidDate }
        guard !entry.invalidRange else { throw ProjectScheduleError.invalidRange }
        if let startField = selected.start, let dueField = selected.due, startField.id != dueField.id,
           let start = entry.start.flatMap(parseDay), let due = entry.due.flatMap(parseDay) {
            let duration = Int(due.timeIntervalSince(start) / 86_400)
            guard let shifted = addDays(dayString(target), -duration) else { throw ProjectScheduleError.invalidDate }
            return [ProjectScheduleChange(fieldID: startField.id, value: shifted), ProjectScheduleChange(fieldID: dueField.id, value: targetDay)]
        }
        if anchor.id == selected.due?.id, let start = entry.start, start > targetDay { throw ProjectScheduleError.invalidRange }
        return [ProjectScheduleChange(fieldID: anchor.id, value: targetDay)]
    }

    private static func value(_ row: HubProjectRow, field: HubProjectField) -> String { row.values[field.id] ?? row.statuses[field.id] ?? "" }
}
