import SwiftUI

/// The timeline uses real calendar days. Undated and invalid tasks stay beside the work they describe.
struct ProjectRoadmap: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    var settings = ProjectScheduleSettings()
    let select: (HubProjectRow) -> Void
    var editDate: ((HubProjectRow, HubProjectField) -> Void)? = nil
    var dependencyRows: [HubProjectRow]? = nil
    var selectedID: String? = nil
    @ViewState private var startID: String?
    @ViewState private var dueID: String?
    private var dateFields: [HubProjectField] { fields.filter { $0.kind == .date } }
    private var effectiveSettings: ProjectScheduleSettings {
        var result = settings
        if let startID { result.startFieldID = startID == "__automatic__" ? nil : startID }
        if let dueID { result.dueFieldID = dueID == "__automatic__" ? nil : dueID }
        return result
    }
    private var resolved: ProjectScheduleFields { ProjectSchedule.fields(fields, settings: effectiveSettings) }
    private var entries: [ProjectScheduleEntry] { ProjectSchedule.entries(rows, fields: fields, settings: effectiveSettings) }
    private var scheduled: [ProjectScheduleEntry] {
        entries.filter { $0.date != nil && !$0.invalidDate && !$0.invalidRange }.sorted {
            if ($0.start ?? $0.due) != ($1.start ?? $1.due) { return ($0.start ?? $0.due ?? "") < ($1.start ?? $1.due ?? "") }
            return $0.id < $1.id
        }
    }
    private var undated: [ProjectScheduleEntry] { entries.filter { $0.date == nil || $0.invalidDate || $0.invalidRange } }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let dependencyRows { ProjectDependencyView(rows: dependencyRows, select: select, selectedID: selectedID) }
                    HStack(spacing: 10) {
                        Label("Roadmap", systemImage: "chart.bar.xaxis").font(.system(size: 13, weight: .semibold))
                        Text(scheduled.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        dateConfiguration
                    }
                    if dateFields.isEmpty {
                        Label("Add a date field to this project to see real task dates on the roadmap.", systemImage: "calendar.badge.plus")
                            .font(.callout).foregroundStyle(.secondary).padding(16).frame(maxWidth: 760, alignment: .leading)
                            .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !scheduled.isEmpty {
                        if geometry.size.width >= 1040 && !undated.isEmpty {
                            HStack(alignment: .top, spacing: 16) {
                                timeline(width: max(600, geometry.size.width - 356))
                                undatedList.frame(width: 280)
                            }
                        } else {
                            timeline(width: max(600, geometry.size.width - 40))
                            if !undated.isEmpty { undatedList.frame(maxWidth: 760, alignment: .leading) }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Give your work a timeline", systemImage: "calendar").font(.system(size: 14, weight: .semibold))
                            Text("No loaded tasks have dates yet. Select a task to set its date fields.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: 760, alignment: .leading)
                            .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        if !undated.isEmpty { undatedList.frame(maxWidth: 760, alignment: .leading) }
                    }
                }.padding(20).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }.defaultScrollAnchor(.top)
        }.accessibilityLabel("Project roadmap")
    }

    private var dateConfiguration: some View {
        Menu {
            Picker("Start date field", selection: Binding(get: { startID ?? settings.startFieldID ?? "__automatic__" }, set: { startID = $0 })) {
                Text("Automatic").tag("__automatic__")
                Text("None").tag("")
                ForEach(dateFields) { Text($0.name).tag($0.id) }
            }
            Picker("Due date field", selection: Binding(get: { dueID ?? settings.dueFieldID ?? "__automatic__" }, set: { dueID = $0 })) {
                Text("Automatic").tag("__automatic__")
                Text("None").tag("")
                ForEach(dateFields) { Text($0.name).tag($0.id) }
            }
        } label: { Label("Schedule settings", systemImage: "slider.horizontal.3") }.controlSize(.small)
    }

    private var undatedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Unscheduled", systemImage: "calendar.badge.questionmark").font(.system(size: 12, weight: .semibold))
                Text(undated.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(13)
            Divider()
            ForEach(undated) { entry in
                HStack(alignment: .center, spacing: 12) {
                    Button { select(entry.row) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.invalidDate || entry.invalidRange ? "exclamationmark.triangle" : ProjectTaskStyle.symbol(entry.row))
                                .foregroundStyle(entry.invalidDate || entry.invalidRange ? .orange : ProjectTaskStyle.color(entry.row)).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                                if let assignee = entry.row.assignees.first { Text(assignee).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button {
                        if let field = resolved.due ?? resolved.start, let editDate { editDate(entry.row, field) }
                        else { select(entry.row) }
                    } label: { Label("Schedule", systemImage: "calendar.badge.plus").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(.borderless).fixedSize().disabled(dateFields.isEmpty).help("Edit task date")
                    Spacer(minLength: 0)
                }.padding(13).frame(minHeight: 54, alignment: .leading)
                if entry.id != undated.last?.id { Divider().padding(.horizontal, 13) }
            }
            if undated.contains(where: { $0.invalidDate || $0.invalidRange }) {
                Text("Tasks with invalid date ranges must be corrected before they can be rescheduled.")
                    .font(.caption).foregroundStyle(.orange).padding(13)
            }
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
            .accessibilityLabel("Unscheduled project tasks")
    }

    private func timeline(width: CGFloat) -> some View {
        let first = scheduled.compactMap { $0.start ?? $0.due }.min() ?? ProjectSchedule.today()
        let last = scheduled.compactMap { $0.due ?? $0.start }.max() ?? first
        let start = ProjectSchedule.addDays(first, -1) ?? first
        let end = max(ProjectSchedule.addDays(last, 1) ?? last, ProjectSchedule.addDays(start, 7) ?? last)
        let totalDays = max(1, days(start, end) + 1)
        let titleWidth: CGFloat = 230, chartWidth = max(350, width - titleWidth - 24)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(scheduled) { entry in
                        let rowStart = entry.start ?? entry.due ?? first, rowEnd = entry.due ?? entry.start ?? rowStart
                        HStack(spacing: 0) {
                            Button { select(entry.row) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.completed ? "checkmark.circle.fill" : ProjectTaskStyle.symbol(entry.row)).foregroundStyle(entry.completed ? .green : ProjectTaskStyle.color(entry.row))
                                    Text(entry.row.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                }.padding(.horizontal, 12).frame(width: titleWidth, height: 48, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            ZStack(alignment: .leading) {
                                grid(width: chartWidth)
                                Button { select(entry.row) } label: {
                                    RoundedRectangle(cornerRadius: 5).fill(entry.completed ? Color.green.opacity(0.7) : Color.accentColor.opacity(0.7))
                                        .frame(width: max(8, chartWidth * CGFloat(days(rowStart, rowEnd) + 1) / CGFloat(totalDays)), height: 22)
                                }.buttonStyle(.plain).offset(x: chartWidth * CGFloat(days(start, rowStart)) / CGFloat(totalDays))
                            }.frame(width: chartWidth, height: 48)
                                .help(ProjectSchedulePresentation.date(rowStart) + " – " + ProjectSchedulePresentation.date(rowEnd))
                        }
                        Divider()
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("Task").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(width: titleWidth, alignment: .leading)
                        HStack(spacing: 0) {
                            ForEach(0..<5) { index in
                                let day = ProjectSchedule.addDays(start, (totalDays - 1) * index / 4) ?? start
                                Text(ProjectSchedulePresentation.date(day)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.frame(width: chartWidth)
                    }.frame(height: 36).background(Color(nsColor: .controlBackgroundColor)).overlay(alignment: .bottom) { Divider() }
                }
            }.frame(width: titleWidth + chartWidth, alignment: .topLeading)
        }.frame(height: min(420, CGFloat(scheduled.count) * 49 + 36)).defaultScrollAnchor(.topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }

    private func grid(width: CGFloat) -> some View {
        HStack(spacing: 0) { ForEach(0..<5) { _ in Rectangle().fill(Color.secondary.opacity(0.08)).frame(width: 1); Spacer(minLength: 0) } }.frame(width: width)
    }
    private func days(_ from: String, _ to: String) -> Int {
        guard let first = ProjectSchedule.parseDay(from), let last = ProjectSchedule.parseDay(to) else { return 0 }
        return Int((last.timeIntervalSince1970 - first.timeIntervalSince1970) / 86_400)
    }
}
