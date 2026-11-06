import SwiftUI

/// The project overview, as the redesign's Projects board draws it: chips that count the open tasks, the Schedule list
/// they add up to, and progress and later deadlines beside it. Everything is derived from the loaded tasks, the
/// project's own fields and real dates. (Windows: widgets/hosting-hub/ui/ProjectOverview.tsx)
struct ProjectDashboard: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    @Binding var settings: ProjectScheduleSettings
    let locked: Bool
    let select: (HubProjectRow) -> Void
    let editDate: (HubProjectRow, HubProjectField) -> Void
    let complete: (HubProjectRow) -> Void
    let manageFields: () -> Void
    var selectedID: String? = nil
    /// A pressed chip's group, "invalid" for the tasks whose dates need fixing, or empty for the whole list
    @ViewState private var focus = ""
    @ViewState private var showingDone = false
    @ViewState private var width: CGFloat = 1000
    @ViewState private var today = ProjectSchedule.today()
    private var scheduleFields: ProjectScheduleFields { ProjectSchedule.fields(fields, settings: settings) }
    private var entries: [ProjectScheduleEntry] { ProjectSchedule.entries(rows, fields: fields, settings: settings) }
    private var canComplete: Bool { scheduleFields.status?.options.contains { settings.completedOptionIDs.contains($0.id) } == true }
    private var caption: Color { StudioStyle.Rail.icon }

    var body: some View {
        let entries = self.entries, overview = ProjectSchedule.overview(entries, today: today)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                chips(overview)
                if scheduleFields.due == nil && scheduleFields.start == nil {
                    strip(symbol: "calendar.badge.plus", color: caption, lead: "Turn tasks into a plan",
                          caption: "Add a date field, then choose it in Schedule settings. Every task can have a real place on your calendar.") {
                        Button("Set up schedule fields…", action: manageFields)
                    }
                }
                if entries.contains(where: { $0.invalidDate || $0.invalidRange }) {
                    strip(symbol: "exclamationmark.triangle.fill", color: StudioStyle.Tone.waiting.text, lead: "Some loaded tasks have invalid dates or a due date before their start. Open a task to correct its dates.", caption: nil) {
                        Button(focus == "invalid" ? LocalizedStringKey("View all tasks") : LocalizedStringKey("Date issues")) { focus = focus == "invalid" ? "" : "invalid" }
                    }
                }
                if width >= 856 {
                    HStack(alignment: .top, spacing: 16) { schedule(entries, overview).frame(maxWidth: .infinity); side(entries, overview).frame(width: 280) }
                } else { schedule(entries, overview); side(entries, overview) }
            }
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
            // as wide as the window: the board's width is the size it was drawn at, not a limit
            .frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel("Project scheduling overview")
            .task { await refreshCalendarDay() }
    }

    // MARK: Chips

    private func chips(_ overview: ProjectScheduleOverview) -> some View {
        WorkbenchFlow(spacing: 8) {
            chip(.overdue, "Overdue", overview)
            chip(.today, "Today", overview)
            chip(.upcoming, "Next 7 days", overview)
            // An empty Unscheduled chip would only be noise.
            if overview.counts[.unscheduled, default: 0] > 0 || focus == ProjectScheduleGroup.unscheduled.rawValue { chip(.unscheduled, "Unscheduled", overview) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Task counts")
    }

    private func chip(_ group: ProjectScheduleGroup, _ title: LocalizedStringKey, _ overview: ProjectScheduleOverview) -> some View {
        let count = overview.counts[group, default: 0], on = focus == group.rawValue, alert = group == .overdue && count > 0
        return Button { focus = on ? "" : group.rawValue } label: {
            HStack(spacing: 6) {
                if alert { DesignIconImage(icon: .alert, size: 12).foregroundStyle(StudioStyle.Tone.failed.text).accessibilityHidden(true) }
                Text(count.formatted()).font(.system(size: 15, weight: .semibold)).foregroundStyle(alert ? StudioStyle.Tone.failed.text : count == 0 ? caption : Color.primary)
                Text(title).font(.system(size: 12)).foregroundStyle(alert ? StudioStyle.Tone.failed.text : caption)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.16) : StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.clear : StudioStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Schedule

    private func listed(_ entries: [ProjectScheduleEntry], _ overview: ProjectScheduleOverview) -> [ProjectScheduleEntry] {
        if focus == "invalid" { return entries.filter { $0.invalidDate || $0.invalidRange } }
        if let group = ProjectScheduleGroup(rawValue: focus) { return overview.rows.filter { ProjectSchedule.group($0, today: today) == group } }
        return overview.rows + (showingDone ? overview.done : [])
    }

    private func schedule(_ entries: [ProjectScheduleEntry], _ overview: ProjectScheduleOverview) -> some View {
        let tasks = listed(entries, overview)
        return VStack(alignment: .leading, spacing: 0) {
            cardTitle("Schedule").padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
            LazyVStack(spacing: 0) {
                ForEach(tasks) { entry in
                    Divider()
                    ProjectScheduleTaskRow(entry: entry, today: today, dateField: scheduleFields.due ?? scheduleFields.start, status: scheduleFields.status, settings: settings,
                                           selected: entry.id == selectedID, canComplete: canComplete, locked: locked, select: select, editDate: editDate, complete: complete)
                }
            }
            if tasks.isEmpty {
                Divider()
                Text(entries.isEmpty ? LocalizedStringKey("No tasks yet") : LocalizedStringKey("No open tasks in this view")).font(.system(size: 12)).foregroundStyle(caption)
                    .padding(.horizontal, 12).frame(height: 36)
            }
            if focus.isEmpty, !overview.done.isEmpty {
                Divider()
                Button { showingDone.toggle() } label: {
                    Text(showingDone ? LocalizedStringKey("Hide done tasks") : LocalizedStringKey("Show \(overview.done.count) more done tasks")).font(.system(size: 12, weight: .medium)).foregroundStyle(caption)
                        .frame(minHeight: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).frame(height: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
    }

    // MARK: Side cards

    private func side(_ entries: [ProjectScheduleEntry], _ overview: ProjectScheduleOverview) -> some View {
        VStack(spacing: 12) { progressCard(entries); deadlinesCard(overview); workloadCard(entries) }
    }

    private func progressCard(_ entries: [ProjectScheduleEntry]) -> some View {
        let progress = ProjectSchedule.progress(entries, status: scheduleFields.status, settings: settings)
        let parts: [(String, Int, Color)] = [
            (String(localized: "Done"), progress.done, StudioStyle.Tone.passed.text),
            (String(localized: "In progress"), progress.inProgress, StudioStyle.Tone.info.text),
            (String(localized: "To do"), progress.todo, StudioStyle.Tone.neutral.fill)
        ]
        return card {
            cardTitle("Progress")
            Text("\(progress.percent)% done").font(.system(size: 15, weight: .semibold))
            GeometryReader { geometry in
                let shown = parts.filter { $0.1 > 0 }, room = max(0, geometry.size.width - CGFloat(max(0, shown.count - 1)) * 4)
                HStack(spacing: 4) {
                    ForEach(shown, id: \.0) { part in part.2.frame(width: room * CGFloat(part.1) / CGFloat(max(1, progress.total))) }
                }
            }
            .frame(height: 8).background(StudioStyle.Tone.neutral.fill).clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement(children: .ignore).accessibilityLabel(parts.map { $0.0 + " " + $0.1.formatted() }.joined(separator: ", "))
            WorkbenchFlow(spacing: 16) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 8, height: 8)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.16)))
                        Text(verbatim: part.0 + " " + part.1.formatted()).font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.neutral.text)
                    }
                }
            }
            .accessibilityHidden(true)
            if scheduleFields.status != nil, settings.completedOptionIDs.isEmpty {
                Text("Choose completed statuses in Schedule settings to include finished drafts and tasks.").font(.system(size: 12)).foregroundStyle(caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deadlinesCard(_ overview: ProjectScheduleOverview) -> some View {
        card {
            cardTitle("Upcoming deadlines")
            ForEach(overview.later.prefix(5)) { entry in
                Button { select(entry.row) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "flag").font(.system(size: 12)).foregroundStyle(caption).accessibilityHidden(true)
                        Text(entry.row.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: entry.due.map { ProjectSchedulePresentation.date($0) } ?? "").font(.system(size: 12)).foregroundStyle(caption).fixedSize()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if overview.later.isEmpty { Text("Nothing is due after the next 7 days.").font(.system(size: 12)).foregroundStyle(caption) }
        }
    }

    /// The board draws no workload; it stays as a third card because nothing there replaces it.
    @ViewBuilder private func workloadCard(_ entries: [ProjectScheduleEntry]) -> some View {
        let workload = ProjectSchedule.workload(entries, today: today).filter { $0.summary.active > 0 }
            .sorted { $0.summary.active == $1.summary.active ? $0.assignee < $1.assignee : $0.summary.active > $1.summary.active }
        if !workload.isEmpty {
            card {
                cardTitle("Team workload")
                ForEach(Array(workload.prefix(6)), id: \.assignee) { member in
                    HStack(spacing: 8) {
                        if member.assignee.isEmpty { Image(systemName: "person.crop.circle.dashed").font(.system(size: 16)).foregroundStyle(caption).frame(width: 20, height: 20).accessibilityHidden(true) }
                        else { Avatar(name: member.assignee, email: member.assignee, size: 20).accessibilityHidden(true) }
                        Text(member.assignee.isEmpty ? String(localized: "Unassigned") : "@" + member.assignee).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        if member.summary.overdue > 0 { StatusPill(title: String(localized: "Overdue") + " " + member.summary.overdue.formatted(), symbol: "exclamationmark.circle", tone: .failed) }
                        Text(member.summary.active.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(caption)
                    }
                }
            }
        }
    }

    // MARK: Parts

    private func cardTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(caption).accessibilityAddTraits(.isHeader)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
    }

    /// A notice as docs/design.md draws one: a white strip with a hairline, a 14 pt icon, dark lead text and one plain action
    private func strip<Action: View>(symbol: String, color: Color, lead: LocalizedStringKey, caption text: LocalizedStringKey?, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(lead).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let text { Text(text).font(.system(size: 12)).foregroundStyle(caption).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.border))
    }

    private func refreshCalendarDay() async {
        while !Task.isCancelled {
            today = ProjectSchedule.today()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
