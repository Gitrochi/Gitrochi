import SwiftUI

/// Shared schedule controls keep Overview and Calendar on the same project fields.
struct ProjectScheduleConfiguration: View {
    let fields: [HubProjectField]
    @Binding var settings: ProjectScheduleSettings
    let manageFields: () -> Void
    private var dateFields: [HubProjectField] { fields.filter { $0.kind == .date } }
    private var status: HubProjectField? { ProjectSchedule.fields(fields, settings: settings).status }

    var body: some View {
        Menu {
            Picker("Start date field", selection: selection(\.startFieldID)) {
                Text("Automatic").tag("__automatic__")
                Text("None").tag("")
                ForEach(dateFields) { Text($0.name).tag($0.id) }
            }
            Picker("Due date field", selection: selection(\.dueFieldID)) {
                Text("Automatic").tag("__automatic__")
                Text("None").tag("")
                ForEach(dateFields) { Text($0.name).tag($0.id) }
            }
            Divider()
            Picker("Completion status field", selection: Binding(get: { settings.statusFieldID ?? "__automatic__" }, set: { value in
                settings.statusFieldID = value == "__automatic__" ? nil : value
                settings.completedOptionIDs = []
            })) {
                Text("Automatic").tag("__automatic__")
                Text("None").tag("")
                ForEach(fields.filter { $0.kind == .singleSelect }) { Text($0.name).tag($0.id) }
            }
            if let status {
                Menu("Completed statuses") {
                    ForEach(status.options) { option in
                        Toggle(option.name, isOn: Binding(get: { settings.completedOptionIDs.contains(option.id) }, set: { selected in
                            if selected { settings.completedOptionIDs.append(option.id) }
                            else { settings.completedOptionIDs.removeAll { $0 == option.id } }
                        }))
                    }
                }
            }
            Divider()
            Button("Manage date and status fields…", action: manageFields)
        } label: { Label("Schedule settings", systemImage: "slider.horizontal.3") }
            .help("Choose the project fields used for scheduling and completion")
    }

    private func selection(_ path: WritableKeyPath<ProjectScheduleSettings, String?>) -> Binding<String> {
        Binding(get: { settings[keyPath: path] ?? "__automatic__" }, set: { settings[keyPath: path] = $0 == "__automatic__" ? nil : $0 })
    }
}

enum ProjectSchedulePresentation {
    static func date(_ day: String, template: String = "MMMd") -> String {
        guard let date = ProjectWorkbench.date(day) else { return day }
        let formatter = DateFormatter()
        // the app's language, which Settings may set apart from the system's
        formatter.locale = AppLanguage.locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func color(_ entry: ProjectScheduleEntry, today: String) -> Color {
        if entry.completed { return .green }
        guard let due = entry.due else { return .secondary }
        if due < today { return .red }
        if due == today { return .orange }
        return .accentColor
    }

    static func taskColor(_ row: HubProjectRow) -> Color {
        let index = row.id.utf8.reduce(0) { ($0 + Int($1)) % 6 }
        return [.accentColor, .teal, .blue, .orange, .purple, .pink][index]
    }
}

/// The todo row of docs/design.md: checkbox, title, one line of meta, status pill, avatar. A done task shows a check
/// and a gray title. Every change is left to the parent. (Windows: widgets/hosting-hub/ui/ProjectAgendaTask.tsx)
struct ProjectScheduleTaskRow: View {
    let entry: ProjectScheduleEntry
    let today: String
    let dateField: HubProjectField?
    var status: HubProjectField? = nil
    var settings = ProjectScheduleSettings()
    var selected = false
    let canComplete: Bool
    let locked: Bool
    let select: (HubProjectRow) -> Void
    let editDate: (HubProjectRow, HubProjectField) -> Void
    let complete: (HubProjectRow) -> Void
    @ViewState private var hovering = false
    private var overdue: Bool { !entry.completed && !entry.invalidRange && entry.due.map { $0 < today } == true }
    private var stage: ProjectScheduleStage { ProjectSchedule.stage(entry, status: status, settings: settings) }
    /// The project's own word for the status; a closed item without one is simply done
    private var statusName: String? {
        let name = status.map { ProjectTaskStyle.value(entry.row, field: $0) } ?? ""
        return name.isEmpty ? (entry.completed ? String(localized: "Done") : nil) : name
    }

    /// A box that cannot be ticked says why
    private var checkHelp: LocalizedStringKey {
        entry.completed ? "Done" : canComplete ? "Mark as done" : "Choose completed statuses in Schedule settings to include finished drafts and tasks."
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { complete(entry.row) } label: {
                Image(systemName: entry.completed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16)).foregroundStyle(entry.completed ? Color.accentColor : StudioStyle.Rail.icon)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(locked || entry.completed || !canComplete)
                .help(checkHelp)
                .accessibilityLabel("Mark as done: \(entry.row.title)").accessibilityAddTraits(entry.completed ? .isSelected : [])
            Button { select(entry.row) } label: {
                HStack(spacing: 8) {
                    Text(entry.row.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(entry.completed ? StudioStyle.Rail.icon : Color.primary).lineLimit(1).truncationMode(.tail)
                    meta.layoutPriority(1)
                    Spacer(minLength: 8)
                    Group { if let statusName { StatusPill(title: statusName, symbol: stage == .done ? "checkmark.circle" : stage == .inProgress ? "circle.lefthalf.filled" : "circle", tone: stage == .done ? .passed : stage == .inProgress ? .info : .neutral) } }
                        .frame(width: 96, alignment: .leading).clipped()
                    Group { if let name = entry.row.assignees.first { Avatar(name: name, email: name, size: 20).help("@" + name).accessibilityLabel("Assigned to @\(name)") } }
                        .frame(width: 20, height: 20)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 12)).frame(minHeight: 36)
        .background(selected ? Color.accentColor.opacity(0.16) : hovering ? StudioStyle.hover : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            if let dateField { Button("Edit task date") { editDate(entry.row, dateField) }.disabled(locked || entry.row.archived || entry.row.kind == .redacted) }
        }
    }

    /// One line: when the task is due, and that it is overdue in words as well as in colour
    private var meta: some View {
        HStack(spacing: 4) {
            if overdue || entry.invalidDate || entry.invalidRange { Image(systemName: overdue ? "exclamationmark.circle" : "exclamationmark.triangle").font(.system(size: 11)).accessibilityHidden(true) }
            Text(verbatim: dueText).lineLimit(1)
        }
        .font(.system(size: 12, weight: overdue ? .semibold : .regular))
        .foregroundStyle(overdue ? StudioStyle.Tone.failed.text : StudioStyle.Rail.icon)
        .fixedSize()
    }
    private var dueText: String {
        guard let day = entry.date else { return String(localized: "No due date") }
        let date = day == today ? String(localized: "Today") : ProjectSchedulePresentation.date(day)
        return overdue ? String(localized: "Overdue") + " · " + date : date
    }
}
