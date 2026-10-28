import SwiftUI

/// Predecessor and duration edits are atomic and never move task dates.
struct ProjectDependenciesEditor: View {
    let detail: HubDetail
    let row: HubProjectRow
    let locked: Bool
    let save: ([String], Int?) async -> String?
    @ViewState private var selected: Set<String> = []
    @ViewState private var duration = ""
    @ViewState private var query = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var initialized = false
    private var candidates: [HubProjectRow] { detail.rows.filter { $0.id != row.id && (query.trimmed.isEmpty || $0.title.localizedCaseInsensitiveContains(query.trimmed)) } }
    private var validDuration: Bool { duration.isEmpty || (duration.range(of: "^[0-9]+$", options: .regularExpression) != nil && Int(duration).map { (1...3650).contains($0) } == true) }
    private var dirty: Bool { selected != Set(row.predecessorIDs ?? []) || duration != (row.durationDays.map(String.init) ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Task predecessors").font(.system(size: 12, weight: .semibold))
            Text("A task is ready when its predecessors are done. Archived unfinished predecessors keep it blocked.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Find predecessor tasks", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(candidates.prefix(60))) { candidate in
                            Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { enabled in
                                if enabled { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                            })) {
                                Text(candidate.title + (candidate.archived ? " · " + String(localized: "Archived") : "")).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }.toggleStyle(.checkbox)
                        }
                        if candidates.isEmpty { Text("No other matching tasks in this project.").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(220, max(34, CGFloat(min(60, candidates.count)) * 32)))
                if candidates.count > 60 { Text(verbatim: String(localized: "Showing {0} of {1} tasks. Refine the search to find more.").replacingOccurrences(of: "{0}", with: "60").replacingOccurrences(of: "{1}", with: candidates.count.formatted())).font(.caption).foregroundStyle(.secondary) }
                Text(verbatim: String(localized: "{0} predecessors selected").replacingOccurrences(of: "{0}", with: selected.count.formatted())).font(.caption).foregroundStyle(.secondary)
                if selected.count > 100 { Text("Choose up to 100 different predecessor tasks from this project, excluding this task.").font(.caption).foregroundStyle(.red) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Duration (days)").font(.caption)
                    TextField("Duration (days)", text: $duration).textFieldStyle(.roundedBorder).accessibilityLabel("Duration (days)")
                }
                if !validDuration { Text("Enter a duration from 1 to 3650 whole days, or leave it empty.").font(.caption).foregroundStyle(.red) }
                Text("Durations are explicit estimates. Saving predecessors never reschedules tasks.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Button("Save task dependencies") { Task { await submit() } }.buttonStyle(.borderedProminent).disabled(!dirty || !validDuration || selected.count > 100)
                }
            }.disabled(locked || busy || row.archived)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Clear predecessor links from dependent tasks before deleting their predecessor.").font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain).accessibilityLabel("Task predecessors")
            .onAppear { if !initialized { reset(); initialized = true } }
            .onChange(of: row.predecessorIDs) { _, _ in reset() }
            .onChange(of: row.durationDays) { _, _ in reset() }
    }
    private func reset() { selected = Set(row.predecessorIDs ?? []); duration = row.durationDays.map(String.init) ?? "" }
    private func submit() async {
        guard !locked, !busy, !row.archived, dirty, validDuration, selected.count <= 100 else { return }
        busy = true; error = nil
        error = await save(selected.sorted(), duration.isEmpty ? nil : Int(duration))
        busy = false
    }
}
