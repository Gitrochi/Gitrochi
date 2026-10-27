import SwiftUI

/// The roadmap uses actual date values; undated tasks remain explicit instead of receiving invented dates.
struct ProjectRoadmap: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    let select: (HubProjectRow) -> Void
    @ViewState private var startID = ""
    @ViewState private var endID = ""
    private var dateFields: [HubProjectField] { fields.filter { $0.kind == .date } }
    private var startField: HubProjectField? { dateFields.first { $0.id == startID } ?? dateFields.first }
    private var endField: HubProjectField? { dateFields.first { $0.id == endID } ?? dateFields.dropFirst().first ?? startField }
    private var scheduled: [(row: HubProjectRow, start: Date, end: Date)] {
        guard let startField else { return [] }
        return rows.compactMap { row in
            guard let start = ProjectWorkbench.date(row.values[startField.id]) else { return nil }
            let end = ProjectWorkbench.date(row.values[endField?.id ?? ""]) ?? start
            return (row, min(start, end), max(start, end))
        }.sorted { $0.start < $1.start }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if dateFields.isEmpty {
                ContentUnavailableView("Give your work a timeline", systemImage: "calendar", description: Text("Add a date field to this project to see real task dates on the roadmap."))
            } else {
                WorkbenchFlow {
                    Picker("Start date", selection: Binding(get: { startField?.id ?? "" }, set: { startID = $0 })) { ForEach(dateFields) { field in Text(field.name).tag(field.id) } }.frame(width: 220)
                    Picker("End date", selection: Binding(get: { endField?.id ?? "" }, set: { endID = $0 })) { ForEach(dateFields) { field in Text(field.name).tag(field.id) } }.frame(width: 220)
                }
                if let first = scheduled.first?.start, let last = scheduled.map(\.end).max() {
                    timeline(start: first.addingTimeInterval(-86400), end: max(last, first.addingTimeInterval(86400 * 7)).addingTimeInterval(86400))
                } else { Text("No loaded tasks have dates yet. Select a task to set its date fields.").font(.callout).foregroundStyle(.secondary).padding(20) }
                let unscheduled = rows.filter { row in !scheduled.contains { $0.row.id == row.id } }
                if !unscheduled.isEmpty {
                    Text("Unscheduled").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView { LazyVStack(spacing: 1) { ForEach(unscheduled) { row in Button { select(row) } label: { HStack { Image(systemName: ProjectTaskStyle.symbol(row)).foregroundStyle(ProjectTaskStyle.color(row)); Text(row.title); Spacer(); Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary) }.padding(10).contentShape(Rectangle()) }.buttonStyle(.plain) } } }.frame(maxHeight: 180)
                }
                Spacer(minLength: 0)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func timeline(start: Date, end: Date) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("Task").frame(width: 215, alignment: .leading); HStack { ForEach(0..<5) { index in Text(start.addingTimeInterval(end.timeIntervalSince(start) * Double(index) / 4), format: .dateTime.month(.abbreviated).day()).frame(maxWidth: .infinity, alignment: .leading) } }.frame(width: 620) }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.vertical, 12)
                ForEach(scheduled, id: \.row.id) { entry in
                    HStack(spacing: 10) {
                        Button { select(entry.row) } label: { Text(entry.row.title).font(.callout).lineLimit(2).frame(width: 205, alignment: .leading) }.buttonStyle(.plain)
                        GeometryReader { geometry in
                            let span = end.timeIntervalSince(start), offset = entry.start.timeIntervalSince(start) / span, duration = max(86400, entry.end.timeIntervalSince(entry.start)) / span
                            ZStack(alignment: .leading) {
                                HStack(spacing: 0) { ForEach(0..<5) { _ in Rectangle().fill(Color.secondary.opacity(0.07)).frame(width: 1); Spacer(minLength: 0) } }
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8)).frame(width: max(8, geometry.size.width * duration), height: 23).offset(x: geometry.size.width * offset)
                            }
                        }.frame(width: 620, height: 42).help(entry.start.formatted(date: .abbreviated, time: .omitted) + " – " + entry.end.formatted(date: .abbreviated, time: .omitted))
                    }
                    Divider()
                }
            }
        }.frame(maxHeight: 350).accessibilityLabel("Project roadmap")
    }
}
