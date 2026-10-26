import SwiftUI

/// 충돌 해결: 충돌 블록마다 내 것 · 상대 것 · 둘 다 · 직접 고치기를 고르고, 다 고르면 저장하고 해결됨으로 표시
struct ConflictView: View {
    @Environment(RepoStore.self) private var store
    let change: FileChange
    @ViewState private var threeWay = true
    @ViewState private var showBase = false
    @ViewState private var manualResult: String?
    @ViewState private var scrollGroup = ConflictScrollGroup()

    var body: some View {
        Group {
            if let doc = store.conflictDoc, store.conflictPath == change.path {
                if doc.isEmpty { noMarkers } else { resolver(doc) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: change.path) { store.loadConflict(change) }
    }

    /// 충돌 표시가 없는 충돌(한쪽이 지웠거나 바이너리)
    private var noMarkers: some View {
        VStack(spacing: 12) {
            ContentUnavailableView("Conflict without conflict markers", systemImage: "exclamationmark.triangle",
                                   description: Text("One side deleted the file, or it's a binary file. Choose whether to keep or delete it."))
            HStack {
                Button("Delete this file") { Task { await store.resolveDeleted(change, keep: false) } }
                Button("Keep this file") { Task { await store.resolveDeleted(change, keep: true) } }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("Use mine (\(store.conflictSides.ours))") { Task { await store.resolveWholeFile(change, ours: true) } }
                Button("Use theirs (\(store.conflictSides.theirs))") { Task { await store.resolveWholeFile(change, ours: false) } }
            }
            .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolver(_ doc: ConflictDocument) -> some View {
        let sides = store.conflictSides
        let done = doc.blocks.filter { store.conflictChoices[$0.id] != nil }.count
        let result = manualResult ?? doc.projection("result", choices: store.conflictChoices)
        let remaining = ConflictDocument.parse(result).blocks.count
        let canSave = manualResult == nil ? done == doc.blocks.count : remaining == 0 && result.range(of: "(?m)^<{7,}([ \\t]|$)", options: .regularExpression) == nil
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(doc.blocks.count) conflicts — \(done) chosen").font(.callout.weight(.semibold))
                Spacer()
                Button(threeWay ? String(localized: "Block view") : String(localized: "Three-way editor")) { threeWay.toggle() }
                Button("Reload") { store.loadConflict(change); manualResult = nil }
                Menu("Whole file") {
                    Button("All mine (\(sides.ours))") { Task { await store.resolveWholeFile(change, ours: true) } }
                    Button("All theirs (\(sides.theirs))") { Task { await store.resolveWholeFile(change, ours: false) } }
                }
                .fixedSize()
                .help("Resolves the whole file to one side at once instead of choosing block by block")
                Button("Save and mark as resolved") { Task { await store.saveConflictResolution(change, editedText: manualResult) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || store.busy != nil)
                    .help(done < doc.blocks.count ? "Choose every conflict block before saving" : "Saves the file as chosen and stages it")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            Divider()
            if threeWay {
                HStack {
                    Text("Non-conflicting lines are included automatically.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(showBase ? String(localized: "Hide common ancestor") : String(localized: "Show common ancestor")) { showBase.toggle() }
                    if manualResult != nil { Button("Use block choices") { manualResult = nil } }
                }.controlSize(.small).padding(8)
                HStack(spacing: 1) {
                    if showBase { pane(String(localized: "Common ancestor"), text: .constant(doc.projection("base")), editable: false) }
                    pane(String(localized: "Mine · \(sides.ours)"), text: .constant(doc.projection("ours")), editable: false)
                    pane(String(localized: "Final result"), text: Binding(get: { result }, set: { manualResult = $0 }), editable: true)
                    pane(String(localized: "Theirs · \(sides.theirs)"), text: .constant(doc.projection("theirs")), editable: false)
                }.frame(minHeight: 240, maxHeight: .infinity).background(Color(nsColor: .separatorColor))
                HStack {
                    Text("\(remaining) unresolved blocks in the result").font(.caption)
                    if manualResult != nil { Text("Manual result editing is active. Use block choices to rebuild from the selections below.").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(doc.segments.enumerated()), id: \.offset) { _, seg in
                        switch seg {
                        case .text(let lines): TextSegment(lines: lines)
                        case .conflict(let i): BlockCard(block: doc.blocks[i], sides: sides)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: threeWay ? 230 : .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onChange(of: doc.sourceText) { _, _ in manualResult = nil }
    }

    private func pane(_ title: String, text: Binding<String>, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(1).padding(7).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.06))
            ConflictTextPane(text: text, editable: editable, group: scrollGroup).accessibilityLabel(title)
        }.frame(maxWidth: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

/// 충돌 없는 부분: 길면 앞뒤 3줄만
private struct TextSegment: View {
    let lines: [String]
    @ViewState private var expanded = false

    var body: some View {
        let short = lines.count > 8 && !expanded
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((short ? Array(lines.prefix(3)) : lines).enumerated()), id: \.offset) { _, l in code(l) }
            if short {
                Button("… show \(lines.count - 6) more lines") { expanded = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.vertical, 2)
                ForEach(Array(lines.suffix(3).enumerated()), id: \.offset) { _, l in code(l) }
            }
        }
        .foregroundStyle(.secondary)
    }

    private func code(_ l: String) -> some View {
        Text(l.isEmpty ? " " : l.replacingOccurrences(of: "\t", with: "    "))
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
    }
}

/// 충돌 블록 하나: 왼쪽 내 것, 오른쪽 상대 것, 아래 고르기
private struct BlockCard: View {
    @Environment(RepoStore.self) private var store
    let block: ConflictDocument.Block
    let sides: (ours: String, theirs: String)
    @ViewState private var editing = false
    @ViewState private var text = ""

    var body: some View {
        let choice = store.conflictChoices[block.id]
        VStack(alignment: .leading, spacing: 8) {
            if let choice, !editing {
                HStack {
                    Label("Chosen: \(title(choice))", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.semibold))
                    Spacer()
                    Button("Choose again") { store.chooseConflict(block.id, nil) }.controlSize(.small)
                }
                lines(ConflictDocument.lines(block, choice), tint: .green)
            } else if editing {
                Text("Edit manually").font(.callout.weight(.semibold))
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Use this") { store.chooseConflict(block.id, .custom(text)); editing = false }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    side(String(localized: "Mine · \(sides.ours)"), block.oursLabel, block.ours, tint: .blue)
                    side(String(localized: "Theirs · \(sides.theirs)"), block.theirsLabel, block.theirs, tint: .purple)
                }
                HStack(spacing: 6) {
                    Button("Mine") { store.chooseConflict(block.id, .ours) }
                    Button("Theirs") { store.chooseConflict(block.id, .theirs) }
                    Menu("Both") {
                        Button("Mine first") { store.chooseConflict(block.id, .oursThenTheirs) }
                        Button("Theirs first") { store.chooseConflict(block.id, .theirsThenOurs) }
                    }
                    .fixedSize()
                    Button("Edit manually…") {
                        text = (block.ours + block.theirs).joined(separator: "\n")
                        editing = true
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(choice == nil ? 0.07 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((choice == nil ? Color.orange : Color.green).opacity(0.4)))
    }

    private func title(_ c: ConflictDocument.Choice) -> String {
        switch c {
        case .ours: return String(localized: "Mine")
        case .theirs: return String(localized: "Theirs")
        case .oursThenTheirs: return String(localized: "Both (mine first)")
        case .theirsThenOurs: return String(localized: "Both (theirs first)")
        case .custom: return String(localized: "Edited manually")
        }
    }

    private func side(_ title: String, _ label: String, _ l: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                .help(label.isEmpty ? title : "\(title)\n\(label)")
            lines(l, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lines(_ l: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if l.isEmpty {
                Text("(empty)").font(.caption).foregroundStyle(.secondary).padding(4)
            }
            ForEach(Array(l.enumerated()), id: \.offset) { _, s in
                Text(s.isEmpty ? " " : s.replacingOccurrences(of: "\t", with: "    "))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
        .textSelection(.enabled)
    }
}
