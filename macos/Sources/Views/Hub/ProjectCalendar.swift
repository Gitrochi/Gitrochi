import SwiftUI

/// Calendar drops propose real field changes; the workspace confirms and performs the write.
struct ProjectCalendar: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    @Binding var settings: ProjectScheduleSettings
    let locked: Bool
    let select: (HubProjectRow) -> Void
    let editDate: (HubProjectRow, HubProjectField) -> Void
    let complete: (HubProjectRow) -> Void
    let reschedule: (HubProjectRow, String) -> Void
    let manageFields: () -> Void
    @ViewState private var anchor = ProjectSchedule.today()
    @ViewState private var mode = "month"
    @ViewState private var includeCompleted = false
    @ViewState private var showingUndated = true
    @ViewState private var selectedDay: String?
    @ViewState private var pendingDayAction: (() -> Void)?
    @ViewState private var width: CGFloat = 1000
    @ViewState private var today = ProjectSchedule.today()
    private var scheduleFields: ProjectScheduleFields { ProjectSchedule.fields(fields, settings: settings) }
    private var entries: [ProjectScheduleEntry] { ProjectSchedule.entries(rows, fields: fields, settings: settings) }
    private var visible: [ProjectScheduleEntry] { entries.filter { includeCompleted || !$0.completed } }
    private var days: [String] { mode == "month" ? ProjectSchedule.monthDays(anchor) : ProjectSchedule.weekDays(anchor) }
    private var undated: [ProjectScheduleEntry] { visible.filter { $0.date == nil || $0.invalidRange } }
    private var canComplete: Bool { scheduleFields.status?.options.contains { settings.completedOptionIDs.contains($0.id) } == true }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if scheduleFields.start == nil && scheduleFields.due == nil {
                ContentUnavailableView {
                    Label("Give your work a date", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Add a date field to this project, then choose it in Schedule settings. Your task dates will stay in sync with GitHub.")
                } actions: { Button("Set up schedule fields…", action: manageFields).buttonStyle(.borderedProminent) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 20) {
                        calendarGrid
                        if !undated.isEmpty { undatedPanel }
                        Text("Tasks span their start through due date. Drag to propose a new due date; confirmation is required before saving. Tasks with both dates keep their duration.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(20).frame(width: max(740, width), alignment: .topLeading)
                }.defaultScrollAnchor(.topLeading)
            }
        }.background(Color(nsColor: .windowBackgroundColor)).accessibilityElement(children: .contain).accessibilityLabel("Project calendar")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task { await refreshCalendarDay() }
            .sheet(isPresented: Binding(get: { selectedDay != nil }, set: { if !$0 { selectedDay = nil } }), onDismiss: {
                let action = pendingDayAction
                pendingDayAction = nil
                action?()
            }) {
                if let day = selectedDay { dayAgenda(day) }
            }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchFlow(spacing: 12) {
                HStack(spacing: 4) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }.help("Previous calendar period")
                    Button { navigate(1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }.help("Next calendar period")
                }
                Text(periodTitle).font(.system(size: 19, weight: .semibold)).frame(minWidth: 170, alignment: .leading)
                Button("Today") { anchor = today }
                Picker("Calendar period", selection: $mode) { Text("Month").tag("month"); Text("Week").tag("week") }.labelsHidden().pickerStyle(.segmented).frame(width: 155)
                Menu {
                    Toggle("Show completed tasks", isOn: $includeCompleted)
                    Toggle("Show unscheduled tasks", isOn: $showingUndated)
                } label: { Image(systemName: "eye") }.help("Calendar visibility")
                ProjectScheduleConfiguration(fields: fields, settings: $settings, manageFields: manageFields)
            }
            HStack(spacing: 7) {
                Image(systemName: "calendar").foregroundStyle(Color.accentColor)
                Text(scheduleFields.due?.name ?? scheduleFields.start?.name ?? String(localized: "No date field selected")).fontWeight(.medium)
                Text("·")
                Text("Loaded project items")
                if locked { ProgressView().controlSize(.mini) }
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 17)
    }

    private var periodTitle: String {
        if mode == "month" { return ProjectSchedulePresentation.date(anchor, template: "MMMM yyyy") }
        guard let first = days.first, let last = days.last else { return ProjectSchedulePresentation.date(anchor) }
        return ProjectSchedulePresentation.date(first) + " – " + ProjectSchedulePresentation.date(last, template: "MMMd yyyy")
    }

    private var calendarGrid: some View {
        let entries = visible
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(days.prefix(7)), id: \.self) { day in
                    Text(ProjectSchedulePresentation.date(day, template: "EEE")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }.background(Color.secondary.opacity(0.025))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 88), spacing: 0, alignment: .top), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in calendarDay(day, entries: entries) }
            }
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13)).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.secondary.opacity(0.14)))
    }

    private func calendarDay(_ day: String, entries: [ProjectScheduleEntry]) -> some View {
        let items = tasks(day, entries: entries)
        let outside = mode == "month" && day.prefix(7) != anchor.prefix(7)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { selectedDay = day } label: {
                    Text(String(Int(day.suffix(2)) ?? 1)).font(.system(size: 11, weight: day == today ? .bold : .medium))
                        .frame(width: 25, height: 25).foregroundStyle(day == today ? Color.white : outside ? Color.secondary : Color.primary)
                        .background(day == today ? Color.accentColor : Color.clear, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel(ProjectSchedulePresentation.date(day, template: "EEEE MMMM d yyyy"))
                Spacer(minLength: 0)
                if !items.isEmpty { Text(items.count.formatted()).font(.system(size: 9)).foregroundStyle(.tertiary) }
            }.padding(.bottom, 3)
            ForEach(Array(items.prefix(mode == "month" ? 3 : 30))) { entry in calendarTask(entry, day: day) }
            if items.count > (mode == "month" ? 3 : 30) {
                Button { selectedDay = day } label: { HStack(spacing: 4) { Text("Show all"); Text(items.count.formatted()).monospacedDigit() }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(.top, 1)
            }
            Spacer(minLength: 4)
        }.padding(8).frame(maxWidth: .infinity, minHeight: mode == "month" ? 100 : 390, alignment: .topLeading)
            .background(outside ? Color.secondary.opacity(0.03) : day == today ? Color.accentColor.opacity(0.025) : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.09)).frame(height: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.09)).frame(width: 1) }
            .dropDestination(for: String.self) { identifiers, _ in
                guard !locked, identifiers.count == 1, let row = rows.first(where: { $0.id == identifiers.first }), !row.archived, row.kind != .redacted else { return false }
                reschedule(row, day)
                return true
            }
    }

    private func calendarTask(_ entry: ProjectScheduleEntry, day: String? = nil) -> some View {
        let color = entry.completed ? Color.green : ProjectSchedulePresentation.taskColor(entry.row)
        return Button { select(entry.row) } label: {
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.row.title).font(.system(size: 10, weight: .medium)).lineLimit(mode == "month" ? 2 : 3).multilineTextAlignment(.leading).foregroundStyle(.primary)
                    if mode == "week", let person = entry.row.assignees.first { Text("@" + person).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if entry.completed { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.green) }
                else if let day, day == entry.due { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(color).accessibilityLabel("Due date") }
            }.padding(.vertical, 6).padding(.horizontal, 5).fixedSize(horizontal: false, vertical: true)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(entry.row.title)
            .onDrag { NSItemProvider(object: (locked || entry.completed ? "" : entry.row.id) as NSString) }
            .contextMenu {
                if let field = scheduleFields.due ?? scheduleFields.start { Button("Edit task date") { editDate(entry.row, field) }.disabled(locked) }
                Button("Move to completed status") { complete(entry.row) }.disabled(locked || entry.completed || !canComplete)
            }
    }

    private var undatedPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button { showingUndated.toggle() } label: { HStack(spacing: 8) { Image(systemName: showingUndated ? "chevron.down" : "chevron.right").font(.caption2); Label("Unscheduled", systemImage: "tray").font(.callout.weight(.semibold)); Text(undated.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                Spacer()
                Text("Drag onto a day to schedule").font(.caption).foregroundStyle(.secondary)
            }
            if showingUndated {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 350), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(undated) { entry in calendarTask(entry) }
                }
                if undated.contains(where: { $0.invalidRange }) { Text("Tasks with invalid date ranges must be corrected before they can be rescheduled.").font(.caption2).foregroundStyle(.orange) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.1)))
    }

    private func dayAgenda(_ day: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(ProjectSchedulePresentation.date(day, template: "EEEE MMMM d")).font(.title2.weight(.semibold)); Spacer(); Button("Done") { selectedDay = nil } }
            Text("Loaded project items").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if tasks(day).isEmpty { ContentUnavailableView("No tasks on this day", systemImage: "calendar", description: Text("Drag a task here from the calendar to propose a date.")) }
                    ForEach(tasks(day)) { entry in
                        ProjectScheduleTaskRow(entry: entry, today: today, dateField: scheduleFields.due ?? scheduleFields.start, canComplete: canComplete, locked: locked,
                            select: { row in afterDayDismiss { select(row) } }, editDate: { row, field in afterDayDismiss { editDate(row, field) } }, complete: { row in afterDayDismiss { complete(row) } })
                        Divider()
                    }
                }
            }
        }.padding(24).frame(width: 600, height: 510)
    }

    private func tasks(_ day: String, entries: [ProjectScheduleEntry]? = nil) -> [ProjectScheduleEntry] {
        (entries ?? visible).filter { entry in
            guard !entry.invalidRange else { return false }
            if let start = entry.start, let due = entry.due { return start <= day && day <= due }
            return entry.date == day
        }.sorted { lhs, rhs in
            if lhs.completed != rhs.completed { return !lhs.completed }
            return lhs.row.title.localizedStandardCompare(rhs.row.title) == .orderedAscending
        }
    }

    private func navigate(_ offset: Int) {
        if mode == "week" { anchor = ProjectSchedule.addDays(anchor, offset * 7) ?? anchor; return }
        guard let date = ProjectSchedule.parseDay(String(anchor.prefix(7)) + "-01") else { return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if let next = calendar.date(byAdding: .month, value: offset, to: date) { anchor = ProjectSchedule.dayString(next) }
    }

    private func afterDayDismiss(_ action: @escaping () -> Void) {
        pendingDayAction = action
        selectedDay = nil
    }

    private func refreshCalendarDay() async {
        while !Task.isCancelled {
            let previous = today
            today = ProjectSchedule.today()
            if anchor == previous { anchor = today }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
