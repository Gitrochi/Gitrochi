import SwiftUI
import AppKit

/// Work spans conversations and keeps its own dated records and correction history.
/// Windows: widgets/ledger-workspace/ui/LedgerWorkLog.tsx.
struct LedgerWorkLogSheet: View {
    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var project = ""
    @ViewState private var items: [LedgerJSON] = []
    @ViewState private var events: [LedgerJSON] = []
    @ViewState private var history: [LedgerJSON] = []
    @ViewState private var warnings: [LedgerJSON] = []
    @ViewState private var selected = ""
    @ViewState private var creating = false
    @ViewState private var itemID = ""
    @ViewState private var title = ""
    @ViewState private var bundle = ""
    @ViewState private var output = ""
    @ViewState private var scope = ""
    @ViewState private var stem = ""
    @ViewState private var splitFrom = ""
    @ViewState private var date = Self.today()
    @ViewState private var event = "progress"
    @ViewState private var text = ""
    @ViewState private var refs = ""
    @ViewState private var destination = ""
    @ViewState private var record = ""
    @ViewState private var originalDate = ""
    @ViewState private var conservative = ""
    @ViewState private var slack = ""
    @ViewState private var fromDate = ""
    @ViewState private var toDate = ""
    @ViewState private var bundleFilter = ""
    @ViewState private var summaryReport = false
    @ViewState private var includeRefs = false
    @ViewState private var report: String?
    @ViewState private var paste = ""
    @ViewState private var showPaste = false
    @ViewState private var error: String?
    @ViewState private var notice: String?
    @ViewState private var working = false
    @ViewState private var loadingDetail = false

    private static let kinds = ["progress", "started", "completed", "issue", "held", "resumed", "frozen", "cancelled", "plan", "transfer", "stem", "item_fix", "text_fix", "date_fix", "move", "carry", "bundle_completed", "bundle_reopened", "skipped", "note"]
    private static let labels = ["Progress", "Started", "Completed", "Issue", "Held", "Resumed", "Frozen", "Cancelled", "Plan", "Transfer", "Set group", "Edit work item", "Correct text", "Correct date", "Move record", "Carry issue", "Complete bundle", "Reopen bundle", "Leave unassigned", "Message to work agents"]
    private static let corrections = ["text_fix", "date_fix", "move", "carry"]
    private var selectedItem: LedgerJSON? { items.first { $0["id"].string == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Work log").font(.title3.weight(.semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Project", text: $project).frame(maxWidth: 220).disabled(working)
                Button("Load") { Task { await refresh() } }.disabled(project.isEmpty || working)
                Button("New work item") { resetForm(); creating = true; report = nil }.disabled(project.isEmpty || working)
                Button("Build report") { Task { await buildReport() } }.disabled(project.isEmpty || working)
                Button("Unassigned reports") { Task { await unassigned() } }.disabled(project.isEmpty || working)
                Button("Paste work records") { showPaste.toggle() }
            }.controlSize(.small)
            HStack {
                TextField("Bundle", text: $bundleFilter)
                TextField("From date", text: $fromDate)
                TextField("To date", text: $toDate)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Summary report", isOn: $summaryReport)
                Toggle("Include evidence references", isOn: $includeRefs)
            }.toggleStyle(.checkbox).font(.caption)
            if !warnings.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                Text([warning["item"].string, warning["message"].string.map { String(localized: String.LocalizationValue($0)) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                } label: { Text("Work warnings") + Text(" (\(warnings.count))") }
            }
            if let error { Text(error).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
            if showPaste {
                TextEditor(text: $paste).font(.system(.callout, design: .monospaced)).frame(height: 100)
                    .accessibilityLabel("Work records")
                Button("Import work records") { Task { await importRecords() } }.disabled(working || paste.isEmpty || project.isEmpty)
            }
            if let report {
                HStack {
                    Button("Back") { self.report = nil }
                    Button("Copy report") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string) }
                }
                ScrollView { MarkdownView(report).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                if bundleFilter.isEmpty || item["bundle"].string == bundleFilter {
                                    Button {
                                        selected = item["id"].string ?? ""; resetForm(); creating = false
                                        Task { await loadDetail() }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item["title"].string ?? "").fontWeight(selected == item["id"].string && !creating ? .semibold : .regular)
                                            Text([item["id"].string, item["bundle"].string, item["status"].string].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                            .background(selected == item["id"].string && !creating ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain).disabled(working)
                                }
                            }
                            if items.isEmpty { Text("No work items yet").foregroundStyle(.secondary).padding(16) }
                        }
                    }.frame(width: 260)
                    Divider()
                    ScrollView { editor.padding(16) }.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20).frame(width: 980, height: 680)
        .onChange(of: project) { _, _ in selected = ""; items = []; events = []; history = []; warnings = []; report = nil; creating = false; resetForm() }
        .task {
            project = ledger.project ?? ledger.state?.projects.first?.key ?? ""
            if !project.isEmpty { await refresh() }
        }
    }

    @ViewBuilder private var editor: some View {
        if creating || !selected.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(creating ? String(localized: "New work item") : selectedItem?["title"].string ?? selected).font(.headline)
                if creating {
                    TextField("Work ID", text: $itemID).help("W-app-01")
                    TextField("Bundle", text: $bundle)
                    TextField("Split from item (optional)", text: $splitFrom)
                } else {
                    Picker("Record type", selection: Binding(get: { event }, set: { chooseType($0) })) {
                        ForEach(Array(Self.kinds.enumerated()), id: \.element) { index, kind in
                            Text(LocalizedStringKey(Self.labels[index])).tag(kind)
                        }
                    }
                }
                if creating || event == "item_fix" {
                    TextField("Title", text: $title)
                    TextField("Expected output", text: $output)
                    TextField("Work scope", text: $scope)
                }
                TextField("Work date", text: $date)
                if creating || event == "stem" { TextField("Work group", text: $stem) }
                if !creating, event == "plan" {
                    TextField("Conservative date", text: $conservative)
                    TextField("Slack date", text: $slack)
                }
                if !creating, ["transfer", "move", "carry"].contains(event) { TextField("Destination", text: $destination) }
                if !creating, Self.corrections.contains(event) {
                    TextField("Record number", text: $record).onChange(of: record) { _, value in
                        if let id = Int(value), let entry = events.first(where: { $0["id"].int == id }) { chooseRecord(entry) }
                    }
                }
                if !creating, event == "date_fix" { TextField("Original date", text: $originalDate) }
                Text("Work description").font(.callout)
                TextEditor(text: $text).frame(minHeight: 70).accessibilityLabel("Work description")
                TextField("Evidence references", text: $refs)
                Text("Prefix an uncertain work date with ~. Corrections keep the original record in history.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save work record") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(working || project.isEmpty || (!creating && loadingDetail) || (creating && (itemID.isEmpty || title.isEmpty || bundle.isEmpty)) || (!creating && event == "item_fix" && title.isEmpty))
                if !creating {
                    Divider()
                    Text("Work history").font(.headline)
                    ForEach(Array(events.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Button { chooseRecord(entry) } label: {
                                Text("#\(entry["id"].int ?? 0) · \(entry["estimated"].bool == true ? "~" : "")\(entry["date"].string ?? "") · \(eventLabel(entry["event"].string ?? ""))")
                            }.buttonStyle(.link).font(.caption).help("Use this record").disabled(working)
                            Text(entry["text"].string ?? "").textSelection(.enabled)
                            if !entry["refs"].array.isEmpty { Text(entry["refs"].array.compactMap(\.string).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                        Divider()
                    }
                    if !history.isEmpty {
                        DisclosureGroup {
                            ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text([entry["date"].string, entry["action"].string.map(eventLabel)].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                                    Text("Before") + Text(": " + changeText(entry["before"]))
                                    Text("After") + Text(": " + changeText(entry["after"]))
                                }.font(.caption).textSelection(.enabled).padding(.vertical, 6)
                            }
                        } label: { Text(String(localized: "{0} corrections retained").replacingOccurrences(of: "{0}", with: String(history.count))) }
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(working)
        } else {
            Text("Group work across conversations and turn dated records into reports.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func call(_ args: [String: LedgerJSON]) async throws -> LedgerJSON {
        try await ledger.client.work(args.merging(["project": .string(project)]) { $1 })
    }
    private func refresh(manageWorking: Bool = true) async {
        if manageWorking { working = true }; error = nil
        do { let value = try await call(["action": .string("list")]); items = value["items"].array; warnings = value["warnings"].array }
        catch { self.error = error.localizedDescription }
        if manageWorking { working = false }
    }
    private func loadDetail() async {
        events = []; history = []
        let item = selected
        loadingDetail = true
        defer { if selected == item { loadingDetail = false } }
        do { let value = try await call(["action": .string("detail"), "item": .string(item)]); if selected == item { events = value["events"].array; history = value["history"].array } }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        working = true; error = nil; notice = nil
        var args: [String: LedgerJSON] = ["action": .string(creating ? "add_item" : event == "note" ? "note" : "event"), "item": .string(creating ? itemID : selected), "date": .string(date), "event": .string(creating ? "registered" : event), "text": .string(text), "refs": .array(refs.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }), "bundle": .string(creating ? bundle : selectedItem?["bundle"].string ?? "")]
        if creating || event == "item_fix" {
            args["title"] = .string(title); args["output"] = .string(output)
            args["scope"] = .array(scope.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        }
        if creating {
            args["stem"] = .string(stem)
            if !splitFrom.isEmpty { args["from"] = .string(splitFrom) }
        } else {
            if event == "note" { args["target"] = .string(selected) }
            if event == "plan" { args["plan"] = .object(["conservative": .string(conservative), "slack": .string(slack)]) }
            if ["transfer", "move", "carry"].contains(event) { args["to"] = .string(destination) }
            if event == "stem" { args["stem"] = .string(stem) }
            if Self.corrections.contains(event), let record = Int(record) { args["eventId"] = .number(Double(record)) }
            if event == "date_fix" { args["was"] = .string(originalDate) }
        }
        do {
            _ = try await call(args)
            if creating { selected = itemID }
            creating = false; resetForm(); notice = String(localized: "Work record saved")
            await refresh(manageWorking: false); await loadDetail()
        } catch { self.error = error.localizedDescription }
        working = false
    }
    private func buildReport() async {
        working = true; error = nil
        var args: [String: LedgerJSON] = ["action": .string("report"), "summary": .bool(summaryReport), "refs": .bool(includeRefs)]
        if !bundleFilter.isEmpty { args["bundle"] = .string(bundleFilter) }
        if !fromDate.isEmpty { args["from"] = .string(fromDate) }
        if !toDate.isEmpty { args["to"] = .string(toDate) }
        do { report = try await call(args)["markdown"].string }
        catch { self.error = error.localizedDescription }
        working = false
    }
    private func unassigned() async {
        working = true; error = nil
        do {
            var args: [String: LedgerJSON] = ["action": .string("unassigned")]
            if !fromDate.isEmpty { args["from"] = .string(fromDate) }; if !toDate.isEmpty { args["to"] = .string(toDate) }
            let value = try await call(args)
            let entries = value["events"].array.isEmpty ? value["unassigned"].array : value["events"].array
            report = "# " + String(localized: "Unassigned reports") + "\n\n" + entries.map { "- E\($0["id"].int ?? 0): \($0["summary"].string ?? $0["text"].string ?? "")" }.joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
        working = false
    }
    private func importRecords() async {
        working = true; error = nil
        do {
            let value = try await call(["action": .string("import"), "text": .string(paste)])
            notice = value["results"].array.map { "\($0["line"].int ?? 0): " + ($0["error"]["message"].string ?? $0["error"].string ?? $0["status"].string ?? "") }.joined(separator: " · ")
            await refresh(manageWorking: false)
        } catch { self.error = error.localizedDescription }
        working = false
    }
    private static func today() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
    private func resetForm() {
        itemID = ""; title = ""; bundle = ""; output = ""; scope = ""; stem = ""; splitFrom = ""; date = Self.today()
        event = "progress"; text = ""; refs = ""; destination = ""; record = ""; originalDate = ""; conservative = ""; slack = ""
    }
    private func chooseType(_ value: String) {
        let entry = events.first { $0["id"].int == Int(record) }
        event = value; date = Self.today(); text = ""; refs = ""; record = ""; originalDate = ""
        title = selectedItem?["title"].string ?? ""; output = selectedItem?["output"].string ?? ""
        scope = selectedItem?["scope"].array.compactMap(\.string).joined(separator: ", ") ?? ""; stem = selectedItem?["stem"].string ?? ""
        if Self.corrections.contains(value), let entry { chooseRecord(entry) }
    }
    private func chooseRecord(_ entry: LedgerJSON) {
        if !Self.corrections.contains(event) { event = "text_fix" }
        record = String(entry["id"].int ?? 0); originalDate = entry["date"].string ?? ""
        date = ["date_fix", "carry"].contains(event) ? Self.today() : originalDate
        text = event == "text_fix" ? entry["text"].string ?? "" : ""
        refs = entry["refs"].array.compactMap(\.string).joined(separator: ", ")
    }
    private func changeText(_ value: LedgerJSON) -> String {
        let fields = [("text", "Work description"), ("date", "Work date"), ("title", "Title"), ("output", "Expected output"), ("scope", "Work scope"), ("stem", "Work group"), ("item", "Work ID"), ("bundle", "Bundle"), ("from_item", "From item"), ("to_item", "To item"), ("field", "Field"), ("value", "Value")]
        return fields.compactMap { key, label in
            let text = value[key].string ?? (value[key].array.isEmpty ? "" : value[key].array.compactMap(\.string).joined(separator: ", "))
            return text.isEmpty ? nil : String(localized: String.LocalizationValue(label)) + ": " + text
        }.joined(separator: " · ")
    }
    private func eventLabel(_ value: String) -> String {
        let aliases = ["work_text_fixes": "text_fix", "work_date_fixes": "date_fix", "work_item_fixes": "item_fix", "work_stems": "stem", "work_moves": "move", "work_carries": "carry", "work_splits": "split"]
        let kind = aliases[value] ?? value
        let label = Self.kinds.firstIndex(of: kind).map { Self.labels[$0] } ?? (kind == "registered" ? "Registered" : kind == "split" ? "Split work item" : value)
        return String(localized: String.LocalizationValue(label))
    }
}
