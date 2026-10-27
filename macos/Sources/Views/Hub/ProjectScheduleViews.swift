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
        formatter.locale = .current
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

/// Agenda rows expose the actual date field and leave every shared mutation to the parent.
struct ProjectScheduleTaskRow: View {
    let entry: ProjectScheduleEntry
    let today: String
    let dateField: HubProjectField?
    let canComplete: Bool
    let locked: Bool
    let select: (HubProjectRow) -> Void
    let editDate: (HubProjectRow, HubProjectField) -> Void
    let complete: (HubProjectRow) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button { complete(entry.row) } label: {
                Image(systemName: entry.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(entry.completed ? .green : Color.secondary.opacity(0.55))
            }.buttonStyle(.plain).disabled(locked || entry.completed || !canComplete)
                .help("Move to completed status").accessibilityLabel("Move to completed status")
            Button { select(entry.row) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.row.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 7) {
                        if !entry.row.repository.isEmpty { Text(entry.row.repository).lineLimit(1).truncationMode(.middle) }
                        if let number = entry.row.number { Text("#\(number)").monospacedDigit() }
                        if let name = entry.row.assignees.first { Text("@" + name).lineLimit(1) }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let dateField {
                Button { editDate(entry.row, dateField) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: entry.invalidDate || entry.invalidRange ? "exclamationmark.triangle" : "calendar")
                        Text(entry.date.map { ProjectSchedulePresentation.date($0) } ?? String(localized: "Schedule"))
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(ProjectSchedulePresentation.color(entry, today: today))
                        .padding(.horizontal, 7).padding(.vertical, 5).background(ProjectSchedulePresentation.color(entry, today: today).opacity(0.07), in: Capsule())
                }.buttonStyle(.plain).disabled(locked || entry.row.archived || entry.row.kind == .redacted).help("Edit task date")
            }
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
