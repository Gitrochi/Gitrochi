#!/usr/bin/env bash
# Exercise calendar scheduling without real accounts, preferences or network access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tools/project-backend-test-sources.sh"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum Hosting {
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { fatalError("Unexpected credential or network request") }
    static func data(_ request: URLRequest) async throws -> Data { fatalError("Unexpected network request") }
}

@main struct ProjectScheduleTests {
    @MainActor static func main() throws {
        let fields = [
            HubProjectField(id: "start", name: "Start date", options: [], kind: .date),
            HubProjectField(id: "due", name: "Due date", options: [], kind: .date),
            HubProjectField(id: "status", name: "Status", options: [HubProjectOption(id: "done", name: "Shipped"), HubProjectOption(id: "todo", name: "Todo")]),
            HubProjectField(id: "priority", name: "Priority", options: [HubProjectOption(id: "high", name: "High")])
        ]
        let settings = ProjectScheduleSettings(completedOptionIDs: ["done"])
        func row(_ id: String, _ values: [String: String] = [:], state: String = "", assignees: [String] = [], archived: Bool = false, kind: HubProjectRowKind = .issue, statuses: [String: String] = [:]) -> HubProjectRow {
            HubProjectRow(id: id, title: id, body: "", url: "", contentID: id, statuses: statuses, kind: kind, state: state, assignees: assignees, archived: archived, values: values)
        }
        for value in ["2024-02-29", "2000-02-29", "1582-10-10", "0001-01-01", "0099-12-31", "9999-12-31"] {
            precondition(ProjectSchedule.parseDay(value) != nil, "Real Gregorian dates must be accepted: \(value)")
        }
        for value in [nil, "", "2026-02-29", "1900-02-29", "2026-04-31", "2026-00-10", "2026-13-01", "2026-01-00", "0000-01-01", "2026-1-01", "2026-01-1", "2026-10-26T00:00:00Z", " 2026-10-26", "2026-10-26 ", "２０２６-１０-２６"] as [String?] {
            precondition(ProjectSchedule.parseDay(value) == nil, "Malformed dates must never normalize into a real task date")
        }
        let instant = ISO8601DateFormatter().date(from: "2026-10-26T23:30:00Z")!
        precondition(ProjectSchedule.today(instant, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "2026-10-27")
        precondition(ProjectSchedule.today(instant, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!) == "2026-10-26")
        precondition(ProjectSchedule.addDays("2026-03-07", 2) == "2026-03-09")
        precondition(ProjectSchedule.addDays("2026-11-01", 1) == "2026-11-02")
        precondition(ProjectSchedule.addDays("2024-02-28", 1) == "2024-02-29")
        precondition(ProjectSchedule.addDays("2026-12-31", 1) == "2027-01-01")
        precondition(ProjectSchedule.addDays("1582-10-04", 1) == "1582-10-05")
        precondition(ProjectSchedule.addDays("0001-01-01", -1) == nil)
        precondition(ProjectSchedule.addDays("9999-12-31", 1) == nil)
        precondition(ProjectSchedule.addDays("2026-10-27", Int.min) == nil)
        let month = ProjectSchedule.monthDays("2026-10-27")
        precondition(month.count == 42 && month.first == "2026-09-28" && month.last == "2026-11-08" && Set(month).count == 42)
        precondition(ProjectSchedule.weekDays("2027-01-01") == ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"])
        precondition(ProjectSchedule.monthDays("2026-03-09", weekStartsOn: 0).first == "2026-03-01")
        precondition(ProjectSchedule.weekDays("invalid").isEmpty && ProjectSchedule.weekDays("2026-10-27", weekStartsOn: 9).isEmpty)

        let selected = ProjectSchedule.fields(fields, settings: settings)
        precondition(selected.start?.id == "start" && selected.due?.id == "due" && selected.status?.id == "status")
        let explicit = ProjectSchedule.fields(fields, settings: ProjectScheduleSettings(startFieldID: "", dueFieldID: "missing", statusFieldID: "priority"))
        precondition(explicit.start == nil && explicit.due == nil && explicit.status?.id == "priority", "An explicit selection must never silently fall back")
        precondition(ProjectSchedule.fields([HubProjectField(id: "release", name: "Release", options: [], kind: .date)]).due?.id == "release")
        precondition(ProjectSchedule.fields([HubProjectField(id: "a", name: "Alpha", options: [], kind: .date), HubProjectField(id: "b", name: "Beta", options: [], kind: .date)]).due == nil)
        precondition(ProjectSchedule.fields([fields[3]]).status == nil, "Priority must never become a completion field by position")

        let entries = ProjectSchedule.entries([
            row("late", ["due": "2026-10-26"], assignees: ["alex", "sam", "ALEX"]),
            row("today", ["due": "2026-10-27"], assignees: ["alex"]),
            row("week", ["due": "2026-11-03"]), row("later", ["due": "2026-11-04"]),
            row("unscheduled"), row("bad", ["due": "2026-02-30"]),
            row("reversed", ["start": "2026-10-29", "due": "2026-10-26"]),
            row("configured", ["due": "2026-10-26"], statuses: ["status": "done"]),
            row("closed", state: "CLOSED"), row("merged", state: "MERGED", kind: .pullRequest),
            row("start-only", ["start": "2026-10-26"]),
            row("archived", ["due": "2026-10-26"], archived: true), row("private", kind: .redacted)
        ], fields: fields, settings: settings)
        precondition(entries.count == 11)
        let reversed = entries.first { $0.id == "reversed" }!
        precondition(reversed.invalidRange && reversed.start == "2026-10-29" && reversed.due == "2026-10-26", "Reversed ranges must remain visible as invalid, never silently swapped")
        precondition(ProjectSchedule.summary(entries, today: "2026-10-27") == ProjectScheduleSummary(active: 8, overdue: 1, today: 1, upcoming: 1, unscheduled: 2, completed: 3, invalid: 2))
        precondition(ProjectSchedule.summary(entries, today: "invalid").overdue == 0)
        precondition(!ProjectSchedule.entries([row("last-option", statuses: ["status": "todo"])], fields: fields).first!.completed)
        precondition(!ProjectSchedule.entries([row("removed-option", statuses: ["status": "removed"])], fields: fields, settings: ProjectScheduleSettings(completedOptionIDs: ["removed"])).first!.completed)
        let workload = ProjectSchedule.workload(entries, today: "2026-10-27")
        precondition(workload.first { $0.assignee == "alex" }!.summary.active == 2)
        precondition(workload.first { $0.assignee == "sam" }!.summary.overdue == 1)
        precondition(workload.last!.assignee.isEmpty && workload.reduce(0) { $0 + $1.summary.active } == 9, "Shared tasks count once per person while empty assignees remain explicit")

        let shiftedRange = try ProjectSchedule.reschedule(row("range", ["start": "2026-03-07", "due": "2026-03-09"]), fields: fields, settings: settings, targetDay: "2026-11-02")
        precondition(shiftedRange == [ProjectScheduleChange(fieldID: "start", value: "2026-10-31"), ProjectScheduleChange(fieldID: "due", value: "2026-11-02")])
        let shiftedSingle = try ProjectSchedule.reschedule(row("single", ["due": "2026-10-27"]), fields: fields, targetDay: "2026-10-30")
        precondition(shiftedSingle == [ProjectScheduleChange(fieldID: "due", value: "2026-10-30")])
        let newlyScheduled = try ProjectSchedule.reschedule(row("new"), fields: fields, targetDay: "2026-10-30")
        precondition(newlyScheduled == [ProjectScheduleChange(fieldID: "due", value: "2026-10-30")])
        let shiftedStart = try ProjectSchedule.reschedule(row("start", ["start": "2026-10-27"]), fields: [fields[0]], targetDay: "2026-10-30")
        precondition(shiftedStart == [ProjectScheduleChange(fieldID: "start", value: "2026-10-30")])
        for item in [row("bad", ["due": "2026-02-30"]), row("reversed", ["start": "2026-10-30", "due": "2026-10-27"]), row("early-due", ["start": "2026-10-31"]), row("archived", archived: true), row("private", kind: .redacted)] {
            do { _ = try ProjectSchedule.reschedule(item, fields: fields, targetDay: "2026-10-30"); preconditionFailure("Invalid edits must fail") } catch {}
        }
        do { _ = try ProjectSchedule.reschedule(row("invalid"), fields: fields, targetDay: "2026-02-30"); preconditionFailure() } catch {}
        do { _ = try ProjectSchedule.reschedule(row("missing"), fields: [], targetDay: "2026-10-30"); preconditionFailure() } catch {}
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProjectScheduleSettings.self, from: encoded)
        precondition(decoded == settings)
        print("Project schedule: strict calendar dates, local today, DST-safe ranges, field selections, explicit completion, loaded-item metrics, shared workload and validated rescheduling passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-schedule"
"$TASK_TMP/test-project-schedule"
