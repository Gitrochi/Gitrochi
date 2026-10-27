import SwiftUI

/// A planning overview based only on loaded tasks, explicit project fields and real dates.
struct ProjectDashboard: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    @Binding var settings: ProjectScheduleSettings
    let locked: Bool
    let select: (HubProjectRow) -> Void
    let editDate: (HubProjectRow, HubProjectField) -> Void
    let complete: (HubProjectRow) -> Void
    let manageFields: () -> Void
    var addTask: (() -> Void)? = nil
    var openCalendar: (() -> Void)? = nil
    @ViewState private var focus = "focus"
    @ViewState private var width: CGFloat = 1000
    @ViewState private var today = ProjectSchedule.today()
    private var scheduleFields: ProjectScheduleFields { ProjectSchedule.fields(fields, settings: settings) }
    private var entries: [ProjectScheduleEntry] { ProjectSchedule.entries(rows, fields: fields, settings: settings) }
    private var summary: ProjectScheduleSummary { ProjectSchedule.summary(entries, today: today) }
    private var canComplete: Bool { scheduleFields.status?.options.contains { settings.completedOptionIDs.contains($0.id) } == true }
    private var endOfWeek: String { ProjectSchedule.addDays(today, 7) ?? today }
    private var agenda: [ProjectScheduleEntry] {
        entries.filter { entry in
            if focus == "invalid" { return entry.invalidDate || entry.invalidRange }
            if focus == "completed" { return entry.completed }
            guard !entry.completed else { return false }
            if focus == "unscheduled" { return entry.date == nil }
            guard !entry.invalidRange else { return false }
            guard let date = entry.date else { return false }
            if focus == "overdue" { return entry.due.map { $0 < today } ?? false }
            if focus == "today" { return date == today }
            if focus == "upcoming" { return date > today && date <= endOfWeek }
            return date <= endOfWeek
        }.sorted { lhs, rhs in
            if lhs.date != rhs.date { return (lhs.date ?? "9999") < (rhs.date ?? "9999") }
            return lhs.row.title.localizedStandardCompare(rhs.row.title) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                metricCards
                if summary.invalid > 0 {
                    Button { focus = "invalid" } label: { Label("Some loaded tasks have invalid dates or a due date before their start. Open a task to correct its dates.", systemImage: "exclamationmark.triangle") }
                        .buttonStyle(.plain)
                        .font(.caption).foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if width >= 900 {
                    HStack(alignment: .top, spacing: 20) { agendaPanel.frame(maxWidth: .infinity); sidePanels.frame(width: 310) }
                } else { agendaPanel; sidePanels }
                Text("Based on loaded project items. Archived and private items are excluded.").font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel("Project scheduling overview")
            .task { await refreshCalendarDay() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ProjectSchedulePresentation.date(today, template: "EEEE MMMM d")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text("Make room for your best work.").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(-0.4)
                    Text(heroMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "calendar.badge.clock").font(.system(size: 36, weight: .light)).foregroundStyle(Color.accentColor.opacity(0.8)).padding(18).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
            }
            WorkbenchFlow(spacing: 12) {
                if let addTask { Button(action: addTask) { Label("New task", systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(locked) }
                if let openCalendar { Button(action: openCalendar) { Label("Open calendar", systemImage: "calendar") }.buttonStyle(.bordered) }
                Label("Planning overview", systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                if let due = scheduleFields.due { Label(due.name, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
                ProjectScheduleConfiguration(fields: fields, settings: $settings, manageFields: manageFields).controlSize(.small)
            }
            if scheduleFields.due == nil && scheduleFields.start == nil {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "calendar.badge.plus").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turn tasks into a plan").font(.callout.weight(.semibold))
                        Text("Add a date field, then choose it in Schedule settings. Every task can have a real place on your calendar.").font(.caption).foregroundStyle(.secondary)
                        Button("Set up schedule fields…", action: manageFields).buttonStyle(.borderless)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            }
        }.padding(22).background {
            RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Color.accentColor.opacity(0.075), Color.accentColor.opacity(0.015)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.accentColor.opacity(0.1)))
    }

    private var heroMessage: String {
        if summary.overdue > 0 { return String(localized: "A few deadlines need attention. Clear the overdue work and protect what comes next.") }
        if summary.today > 0 { return String(localized: "Your priorities are ready. Keep today's commitments in view while you build.") }
        if summary.active > 0 { return String(localized: "See what is coming, give undated work a deadline, and move your project forward.") }
        return String(localized: "A clear plan starts with a task. Add work to your project to build your schedule.")
    }

    private var metricCards: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 100), spacing: 11), count: width >= 900 ? 5 : width >= 640 ? 3 : 2), spacing: 11) {
            metric("Overdue", count: summary.overdue, symbol: "exclamationmark.circle", color: .red, key: "overdue")
            metric("Today", count: summary.today, symbol: "sun.max", color: .orange, key: "today")
            metric("Next 7 days", count: summary.upcoming, symbol: "calendar", color: .accentColor, key: "upcoming")
            metric("Unscheduled", count: summary.unscheduled, symbol: "tray", color: .secondary, key: "unscheduled")
            metric("Completed", count: summary.completed, symbol: "checkmark.circle", color: .green, key: "completed")
        }
    }

    private func metric(_ title: LocalizedStringKey, count: Int, symbol: String, color: Color, key: String) -> some View {
        Button { focus = focus == key ? "focus" : key } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(color); Spacer(); if focus == key { Image(systemName: "checkmark").font(.caption2).foregroundStyle(color) } }
                Text(count.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == key ? color.opacity(0.5) : Color.secondary.opacity(0.1)))
        }.buttonStyle(.plain).accessibilityAddTraits(focus == key ? .isSelected : [])
    }

    private var agendaPanel: some View {
        let tasks = agenda
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Your agenda").font(.system(size: 16, weight: .semibold)); Text("The work that deserves your attention.").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Menu {
                    Button("Focus: overdue and next 7 days") { focus = "focus" }
                    Button("Overdue") { focus = "overdue" }; Button("Today") { focus = "today" }
                    Button("Next 7 days") { focus = "upcoming" }; Button("Unscheduled") { focus = "unscheduled" }; Button("Completed") { focus = "completed" }
                    if summary.invalid > 0 { Button("Date issues") { focus = "invalid" } }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.help("Choose agenda focus")
            }.padding(.bottom, 18)
            HStack(spacing: 6) { Circle().fill(focusColor).frame(width: 6, height: 6); Text(focusTitle).font(.caption.weight(.semibold)); Text(tasks.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }.padding(.bottom, 4)
            if tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("A little breathing room").font(.callout.weight(.semibold))
                    Text("No loaded tasks match this focus. Choose another focus or schedule your undated work.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Show unscheduled tasks") { focus = "unscheduled" }.buttonStyle(.borderless)
                }.frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { entry in
                        ProjectScheduleTaskRow(entry: entry, today: today, dateField: scheduleFields.due ?? scheduleFields.start, canComplete: canComplete, locked: locked, select: select, editDate: editDate, complete: complete)
                        if entry.row.id != tasks.last?.row.id { Divider().opacity(0.6) }
                    }
                }
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.secondary.opacity(0.1)))
    }

    private var focusTitle: String {
        switch focus { case "overdue": return String(localized: "Overdue"); case "today": return String(localized: "Today"); case "upcoming": return String(localized: "Next 7 days"); case "unscheduled": return String(localized: "Unscheduled"); case "completed": return String(localized: "Completed"); case "invalid": return String(localized: "Date issues"); default: return String(localized: "Focus: overdue and next 7 days") }
    }
    private var focusColor: Color { focus == "overdue" ? .red : focus == "today" ? .orange : focus == "completed" ? .green : .accentColor }

    private var sidePanels: some View { VStack(spacing: 20) { progressPanel; deadlinePanel; workloadPanel } }

    private var progressPanel: some View {
        let total = summary.active + summary.completed
        return panel("Project progress", symbol: "chart.pie") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(total == 0 ? "0%" : (Double(summary.completed) / Double(total)).formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("complete").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(summary.completed)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(summary.completed), total: Double(max(1, total))).tint(.green)
            if let status = scheduleFields.status {
                ForEach(status.options.filter { option in entries.contains { ($0.row.values[status.id] ?? $0.row.statuses[status.id]) == option.id } }.prefix(5)) { option in
                    HStack { Text(option.name).lineLimit(1); Spacer(); Text(entries.filter { ($0.row.values[status.id] ?? $0.row.statuses[status.id]) == option.id }.count.formatted()).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.completedOptionIDs.isEmpty { Text("Choose completed statuses in Schedule settings to include finished drafts and tasks.").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private var deadlinePanel: some View {
        let dated = entries.filter { !$0.completed && $0.due != nil }
        let days = Array(Set(dated.compactMap(\.due).filter { $0 >= today && $0 <= endOfWeek })).sorted()
        return panel("Deadline pressure", symbol: "calendar.badge.exclamationmark") {
            if summary.overdue > 0 {
                HStack { Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(.red); Spacer(); Text(summary.overdue.formatted()).fontWeight(.semibold).foregroundStyle(.red) }.font(.caption)
            }
            if days.isEmpty { Text("No upcoming due dates in the next 7 days.").font(.caption).foregroundStyle(.secondary) }
            ForEach(days.prefix(5), id: \.self) { day in
                let count = dated.filter { $0.due == day }.count
                HStack { Text(day == today ? String(localized: "Today") : ProjectSchedulePresentation.date(day, template: "EEE MMMd")); Spacer(); Text(count.formatted()).monospacedDigit().padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.08), in: Capsule()) }.font(.caption)
            }
            Text("Task counts by due date, based on loaded items.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var workloadPanel: some View {
        let workload = ProjectSchedule.workload(entries, today: today).sorted { $0.summary.active == $1.summary.active ? $0.assignee < $1.assignee : $0.summary.active > $1.summary.active }
        let maximum = max(1, workload.map { $0.summary.active }.max() ?? 1)
        return panel("Team workload", symbol: "person.2") {
            if workload.isEmpty { Text("No loaded tasks to assign yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(workload.prefix(6)), id: \.assignee) { member in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(member.assignee.isEmpty ? String(localized: "Unassigned") : "@" + member.assignee).lineLimit(1); Spacer(); if member.summary.overdue > 0 { Label(member.summary.overdue.formatted(), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).labelStyle(.titleAndIcon) }; Text(member.summary.active.formatted()).monospacedDigit() }.font(.caption)
                    GeometryReader { geometry in Capsule().fill(Color.accentColor.opacity(0.08)).overlay(alignment: .leading) { Capsule().fill(Color.accentColor.opacity(member.assignee.isEmpty ? 0.3 : 0.65)).frame(width: geometry.size.width * Double(member.summary.active) / Double(maximum)) } }.frame(height: 5)
                }.padding(.vertical, 3)
            }
            Text("Active tasks per assignee. A task may have several assignees.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func panel<Content: View>(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) { Label(title, systemImage: symbol).font(.callout.weight(.semibold)); content() }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.secondary.opacity(0.1)))
    }

    private func refreshCalendarDay() async {
        while !Task.isCancelled {
            today = ProjectSchedule.today()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
