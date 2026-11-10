import SwiftUI

/// An explicit paste becomes a local draft or a reviewed question, never a client-side send.
struct LedgerChatGPTDraftSheet: View {
    let ledger: LedgerStore
    let onOpenQuestion: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var mode = Mode.answer
    @ViewState private var raw = ""
    @ViewState private var selectedQuestion: Int?
    @ViewState private var project = ""
    @ViewState private var sessionID = ""
    @ViewState private var preview: LedgerChatGPTDraft.Question?
    @ViewState private var working = false
    @ViewState private var error: String?

    private enum Mode: String, CaseIterable { case answer, question }
    private var questions: [LedgerQuestion] { (ledger.state?.questions ?? []).filter { question in question.state == .open && (ledger.project == nil || ledger.session(question.sessionId)?.project == ledger.project) } }
    private var sessions: [LedgerSession] { (ledger.state?.sessions ?? []).filter { $0.archivedAt == nil && $0.status == .active } }
    private var question: LedgerQuestion? {
        guard let selectedQuestion else { return nil }
        return questions.first { $0.id == selectedQuestion }
    }
    private var target: LedgerSession? { sessions.first { $0.id == sessionID && $0.project == project } }
    private var tooLarge: Bool { raw.utf8.count > 65_536 }
    private var usable: Bool { !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tooLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring a ChatGPT draft…").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pasted by you", symbol: "doc.on.clipboard").font(.callout).foregroundStyle(.secondary)
                    Text("Accept the suggestion with Tab in its original app without sending it. Copy the draft or question and paste it here. Review the destination before using it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("This is a manual transfer. The Ledger does not read ChatGPT or Codex input boxes automatically.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Use pasted text", selection: $mode) {
                        Text("Answer a question").tag(Mode.answer)
                        Text("Add a question").tag(Mode.question)
                    }
                    .pickerStyle(.segmented).disabled(working)
                    if mode == .answer { answerTarget } else { questionTarget }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copied text").font(.callout.weight(.medium))
                        TextEditor(text: $raw)
                            .font(.callout).scrollContentBackground(.hidden).padding(4).frame(height: 150)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                            .accessibilityLabel("Copied text").disabled(working)
                    }
                    if mode == .question {
                        Text("A question can include bullet choices or a structured Ledger question. Use Paste reports for several questions.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if tooLarge { Text("Pasted text is limited to 64 KiB.").foregroundStyle(StudioStyle.Tone.failed.text).font(.callout) }
                    else if !usable { Text("Paste text before continuing.").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if mode == .answer, selectedQuestion != nil, question == nil {
                        Text("The selected question is no longer open. Choose another question; your copied text is still here.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if mode == .question, !sessionID.isEmpty, target == nil {
                        Text("The selected session is no longer active. Choose a destination again.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if mode == .question, project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Choose a project name before saving.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let preview, mode == .question { previewView(preview) }
                    if let error { Text(error).font(.callout).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(20).frame(minWidth: 500, idealWidth: 660, maxWidth: 800, minHeight: 560, idealHeight: 700, maxHeight: 850)
        .onAppear {
            project = ledger.project ?? ledger.state?.projects.first?.key ?? ""
            selectedQuestion = (questions.first { $0.sessionId == ledger.selection } ?? questions.first)?.id
            sessionID = sessions.first { $0.id == ledger.selection && $0.project == project }?.id ?? ""
        }
        .onChange(of: raw) { _, _ in preview = nil; error = nil }
        .onChange(of: mode) { _, _ in error = nil }
        .interactiveDismissDisabled(working)
    }

    @ViewBuilder private var answerTarget: some View {
        if questions.isEmpty {
            VStack(spacing: 6) {
                DesignIconImage(icon: .comment, size: 24).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("No open questions").font(.callout.weight(.semibold))
                Text("Add a question from the pasted text, or choose another project in the Ledger.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Add a question") { mode = .question }
            }
            .frame(maxWidth: .infinity).padding(12)
        } else {
            Picker("Question in your Ledger", selection: Binding(get: { question?.id ?? -1 }, set: { selectedQuestion = $0 })) {
                if question == nil { Text("Select a question").tag(-1) }
                ForEach(questions) { question in Text((ledger.session(question.sessionId)?.title ?? question.sessionId) + " · " + question.text).tag(question.id) }
            }
            .disabled(working)
        }
    }

    private var questionTarget: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Project", text: $project).textFieldStyle(.roundedBorder).disabled(working)
                .onChange(of: project) { _, _ in if target == nil { sessionID = "" } }
            Picker("Session", selection: $sessionID) {
                Text("New session").tag("")
                if !sessionID.isEmpty && target == nil { Text("Select a session").tag(sessionID) }
                ForEach(sessions.filter { $0.project == project }) { session in Text(session.title).tag(session.id) }
            }
            .disabled(working)
        }
    }

    private func previewView(_ question: LedgerChatGPTDraft.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.callout.weight(.semibold))
            Text(question.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                        if option.recommended == true { Text("Recommended").foregroundStyle(.secondary) }
                    }
                    if let detail = option.description { Text(detail).foregroundStyle(.secondary).font(.system(size: 11)) }
                }
            }
            if let suggestion = question.suggestedAnswer {
                Text("Suggested answer").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(suggestion).font(.callout).textSelection(.enabled)
            }
            Button("Update preview", action: makePreview).controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .answer ? String(localized: "Only fills a draft. Send it from the question form.")
                                : String(localized: "Preview the question and choices before saving."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                if mode == .answer {
                    Button("Use draft", action: useDraft).buttonStyle(.borderedProminent).disabled(working || !usable || question == nil)
                } else if preview != nil {
                    Button("Save question", action: save).buttonStyle(.borderedProminent)
                        .disabled(working || project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!sessionID.isEmpty && target == nil))
                } else {
                    Button("Preview", action: makePreview).buttonStyle(.borderedProminent).disabled(working || !usable)
                }
            }
        }
    }

    private func makePreview() {
        do { preview = try LedgerChatGPTDraft.parseQuestion(raw); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func useDraft() {
        guard usable, let question else { return }
        ledger.drafts[question.id] = raw
        ledger.page = .inbox
        onOpenQuestion(question.sessionId)
        dismiss()
    }

    private func save() {
        guard let preview, !working, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sessionID.isEmpty || target != nil else { return }
        working = true
        error = nil
        var report: [String: LedgerJSON] = ["event": .string("question"), "project": .string(project.trimmingCharacters(in: .whitespacesAndNewlines)),
            "summary": .string(preview.text), "question": preview.value,
            "body": .string("Source: text pasted by the user. The source app was not verified.")]
        if let target { report["session"] = .string(target.id) }
        else { report["title"] = .string(String(preview.text.prefix(120))) }
        Task {
            do {
                let data = try JSONEncoder().encode(LedgerJSON.object(report))
                let blocks = try await ledger.importReports(String(decoding: data, as: UTF8.self))
                if let failed = blocks.first(where: { !$0.ok && !$0.duplicate }) { error = failed.error ?? String(localized: "Could not read this block") }
                else if let id = blocks.compactMap(\.sessionId).first {
                    await ledger.choose(project: project.trimmingCharacters(in: .whitespacesAndNewlines))
                    ledger.page = .inbox
                    onOpenQuestion(id)
                    dismiss()
                } else { error = String(localized: "No report blocks found.") }
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
