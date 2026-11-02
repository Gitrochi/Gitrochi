import SwiftUI

/// Agents waiting on a person right now, with the time left before auto-continue answers: in full at the top of the
/// Inbox, one line each above the other views. Answer…, Allow, Deny, Answer in terminal and Not this time go out through
/// `prompt_answer` (DESIGN.md §9.1). A wait held for the person (no countdown) only says why and offers Answer in
/// terminal: no hook waits on it, so an answer sent from here would not reach the agent. Its buttons are reached with
/// Tab; no single key answers an agent. (Windows: widgets/ledger-workspace/ui/LedgerPromptStrip.tsx)
struct LedgerPromptStrip: View {
    let prompts: [LedgerPendingPrompt]
    let ledger: LedgerStore
    var compact = false
    /// Shows the Inbox, where a question is answered in full
    var openInbox: () -> Void = {}
    var retainedChanged: (Bool) -> Void = { _ in }
    @ViewState private var retained: [Int: LedgerPendingPrompt] = [:]

    private var shown: [LedgerPendingPrompt] {
        prompts + retained.values.filter { saved in !prompts.contains { $0.id == saved.id } }.sorted { $0.id < $1.id }
    }

    var body: some View {
        Group {
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    LedgerSectionHeader(title: String(localized: "Waiting now"), count: prompts.count)
                    ForEach(shown) { prompt in
                        if compact {
                            LedgerPromptLine(prompt: prompt, ledger: ledger, openInbox: openInbox)
                        } else {
                            LedgerPromptCard(prompt: prompt, ledger: ledger, primary: prompt.id == prompts.first?.id,
                                             waiting: prompts.contains { $0.id == prompt.id },
                                             draftChanged: { drafted in
                                                 if drafted { retained[prompt.id] = prompt } else { retained[prompt.id] = nil }
                                             }, closeDraft: { retained[prompt.id] = nil })
                        }
                    }
                }
            }
        }
        .onChange(of: retained) { _, drafts in retainedChanged(!drafts.isEmpty) }
    }
}

/// The buttons every waiting prompt has besides its answer: leave it to the terminal, or let this one pass without an
/// automatic answer. Both end the hook without a decision, so the agent's own question or dialog shows in its terminal.
/// A held wait's terminal already asks, so its Answer in terminal sends nothing; the person's answer there settles it.
private struct LedgerPromptExits: View {
    let prompt: LedgerPendingPrompt
    let ledger: LedgerStore
    let busy: Bool

    var body: some View {
        if LedgerCountdown.isCounting(prompt) {
            Button("Answer in terminal") {
                LedgerAgentTerminal.focus(prompt, ledger: ledger)
                Task { await ledger.reply(prompt, .answerInTerminal) }
            }
            .disabled(busy)
            .help("Stop waiting here and answer in the agent's own terminal")
            if LedgerCountdown.isAutomatic(prompt) {
                Button("Not this time") { Task { await ledger.reply(prompt, .holdAuto) } }
                    .disabled(busy)
                    .help("No automatic answer for this prompt: it waits for you in the agent's terminal")
            }
        } else {
            Button("Answer in terminal") {
                if !LedgerAgentTerminal.focus(prompt, ledger: ledger) {
                    ledger.showNotice(String(localized: "The agent's terminal is not open in Gitrochi. Answer it where the agent runs."))
                }
            }
            .help("Go to terminal")
        }
    }
}

/// The terminal of the agent that asks, when Gitrochi started it: AgentCenter knows it by GITROCHI_AGENT_ID, which the
/// hook stores with the prompt and `track` with the session (Windows: LedgerWorkspace's openTerminal)
private enum LedgerAgentTerminal {
    /// Brings it forward; false when it is not an agent Gitrochi runs
    @MainActor @discardableResult
    static func focus(_ prompt: LedgerPendingPrompt, ledger: LedgerStore) -> Bool {
        let center = AgentCenter.shared
        guard let id = prompt.agentId ?? ledger.session(prompt.sessionId)?.links.agentId,
              let agent = center.sessions.first(where: { $0.id == id }),
              center.runsInApp(agent) || (agent.pid != nil && agent.status != .ended) else { return false }
        center.focus(agent)
        return true
    }
}

/// One waiting prompt in a line: what it is, the time left, and the answers that need no typing
private struct LedgerPromptLine: View {
    let prompt: LedgerPendingPrompt
    let ledger: LedgerStore
    let openInbox: () -> Void

    private var busy: Bool { ledger.working.contains("p\(prompt.id)") }

    var body: some View {
        let session = ledger.session(prompt.sessionId)
        let summary = LedgerPromptText.summary(prompt)
        HStack(spacing: 8) {
            Image(systemName: prompt.kind.symbol).font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.waiting.text)
                .accessibilityHidden(true)
            if let session { LedgerSessionLabel(id: session.id, color: session.color) }
            Text(summary).font(.callout).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: 6)
            LedgerCountdownView(prompt: prompt, skew: ledger.clockSkew, inline: true)
            Group {
                if LedgerCountdown.isCounting(prompt) {
                    switch prompt.kind {
                    case .permission, .exitPlanMode:
                        Button("Allow") { Task { await ledger.reply(prompt, .allow) } }
                        Button("Deny") { Task { await ledger.reply(prompt, .deny(message: nil)) } }
                    case .stopQuestion, .askUserQuestion:
                        Button("Answer…", action: openInbox).help("Answer in the Inbox")
                    }
                }
                LedgerPromptExits(prompt: prompt, ledger: ledger, busy: busy)
            }
            .disabled(busy)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.kind.title + ": " + summary)
    }
}

private struct LedgerPromptCard: View {
    let prompt: LedgerPendingPrompt
    let ledger: LedgerStore
    /// Fills its main button
    var primary = true
    var waiting = true
    var draftChanged: (Bool) -> Void = { _ in }
    var closeDraft: () -> Void = {}
    @ViewState private var drafts: [String: String] = [:]
    @ViewState private var showWholePlan = false

    private var busy: Bool { ledger.working.contains("p\(prompt.id)") }
    private var session: LedgerSession? { ledger.session(prompt.sessionId) }
    private var questions: [LedgerAnswerQuestion] { LedgerPromptAnswers.questions(prompt) }
    /// Held for the person: what it asks is shown, and only the terminal answers it
    private var held: Bool { !LedgerCountdown.isCounting(prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if waiting {
                actions
            } else {
                Text("Your draft was not sent.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Close") { drafts = [:]; closeDraft() }.controlSize(.small)
            }
            if waiting, !held, prompt.kind == .stopQuestion || prompt.kind == .askUserQuestion, submittedAnswers == nil {
                Text("Answer every question before sending.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if waiting, !held, prompt.kind == .stopQuestion || prompt.kind == .askUserQuestion {
                Text("Return adds a line · ⌘Return saves").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if waiting, let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.kind.title + (session.map { ", " + $0.id + " " + $0.title } ?? ""))
        .onChange(of: drafts) { _, answers in draftChanged(answers.values.contains { !$0.isEmpty }) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: prompt.kind.symbol).font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.waiting.text)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.kind.title).font(.callout.weight(.semibold))
                if let session {
                    HStack(spacing: 6) {
                        LedgerSessionLabel(id: session.id, color: session.color)
                        Text(session.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                } else if let agent = prompt.agentId {
                    Text(agent).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if waiting {
                LedgerCountdownView(prompt: prompt, skew: ledger.clockSkew)
            } else {
                Text("The prompt was already answered.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch prompt.kind {
        case .stopQuestion:
            let question = LedgerPromptText.summary(prompt)
            if let body = LedgerPromptText.body(prompt), body != question {
                Text(body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(questions) { answerQuestion($0) }
        case .askUserQuestion:
            ForEach(questions) { answerQuestion($0) }
        case .exitPlanMode:
            let plan = LedgerPromptText.body(prompt) ?? ""
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(plan)
                    .frame(maxHeight: showWholePlan ? nil : 110, alignment: .top)
                    .clipped()
                if plan.split(separator: "\n").count > 6 {
                    Button(showWholePlan ? String(localized: "Show less") : String(localized: "Show the whole plan")) { showWholePlan.toggle() }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        case .permission:
            let tool = LedgerPromptText.tool(prompt)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let name = tool?.name {
                    Text(name).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                }
                Text(tool?.summary ?? LedgerPromptText.summary(prompt))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(4).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func answerQuestion(_ question: LedgerAnswerQuestion) -> some View {
        if held {
            VStack(alignment: .leading, spacing: 5) {
                if let header = question.header {
                    Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(question.question).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(question.options, id: \.self) { option in
                    optionText(option, picked: false, multiple: question.multiple)
                }
            }
        } else {
            LedgerQuestionAnswerEditor(question: question,
                                       text: Binding(get: { drafts[question.id] ?? "" }, set: { drafts[question.id] = $0 }),
                                       busy: busy || !waiting, submit: sendAnswers)
        }
    }

    private func optionText(_ option: LedgerPromptText.Option, picked: Bool, multiple: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: picked ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (multiple ? "square" : "circle"))
                .foregroundStyle(picked ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(option.label).font(.callout)
                    if option.recommended, !option.label.localizedCaseInsensitiveContains("recommended") {
                        // a marker: neutral, with the accent only in its dot (docs/design.md, Badges)
                        HStack(spacing: 4) {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text("Recommended")
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.Tone.neutral.text)
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(Capsule().fill(StudioStyle.Tone.neutral.fill))
                    }
                }
                if let detail = option.description, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }

    private var submittedAnswers: [String: String]? { LedgerPromptAnswers.answers(questions, drafts: drafts) }

    private func sendAnswers() {
        guard waiting, !held, !busy, let answers = submittedAnswers else { return }
        Task {
            if prompt.kind == .stopQuestion, let question = questions.first, let text = answers[question.question] {
                if await ledger.reply(prompt, .text(text)) { drafts = [:]; closeDraft() }
            } else {
                if await ledger.reply(prompt, .choices(answers)) { drafts = [:]; closeDraft() }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if held {
            // filled only on the most urgent card: one filled button per region (docs/design.md, Controls)
            HStack(spacing: 8) { LedgerPromptExits(prompt: prompt, ledger: ledger, busy: busy) }
                .prominentButton(primary).controlSize(.small)
        } else {
            answers
        }
    }

    private var answers: some View {
        WorkbenchFlow(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            switch prompt.kind {
            case .stopQuestion, .askUserQuestion:
                Button("Send answer", action: sendAnswers)
                .prominentButton(primary).disabled(busy || submittedAnswers == nil)
            case .permission, .exitPlanMode:
                Button("Allow") { Task { await ledger.reply(prompt, .allow) } }.prominentButton(primary).disabled(busy)
                Button("Deny") { Task { await ledger.reply(prompt, .deny(message: nil)) } }.disabled(busy)
            }
            LedgerPromptExits(prompt: prompt, ledger: ledger, busy: busy)
            if LedgerCountdown.isAutomatic(prompt), let auto = LedgerPromptText.proposed(prompt) {
                Text("If nobody answers: “\(auto)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .controlSize(.small)
    }

    /// Where else the person can answer while Gitrochi waits (#171); for a held wait, why it waits and where to answer
    private var note: String? {
        if held { return LedgerPromptText.heldText(prompt) }
        switch prompt.kind {
        case .permission: return String(localized: "The terminal shows this request too; an answer there counts as well.")
        case .askUserQuestion, .exitPlanMode: return String(localized: "The terminal shows this question only after the wait.")
        case .stopQuestion: return nil
        }
    }
}

/// The time left until auto-continue answers, ticking every second; a held prompt says it waits for a person, and why
struct LedgerCountdownView: View {
    let prompt: LedgerPendingPrompt
    let skew: LedgerMs
    /// Without the bar, for one-line prompts
    var inline = false

    var body: some View {
        if LedgerCountdown.isCounting(prompt) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = LedgerMs((context.date.timeIntervalSince1970 * 1000).rounded()) + skew
                VStack(alignment: .trailing, spacing: 4) {
                    Label(LedgerCountdown.isAutomatic(prompt)
                          ? String(localized: "Auto in \(LedgerCountdown.text(deadline: prompt.deadline, now: now))")
                          : String(localized: "Time left \(LedgerCountdown.text(deadline: prompt.deadline, now: now))"), systemImage: "timer")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StudioStyle.Tone.waiting.text)
                        .fixedSize()
                    if !inline {
                        ProgressView(value: LedgerCountdown.fraction(created: prompt.createdAt, deadline: prompt.deadline, now: now))
                            .progressViewStyle(.linear).tint(StudioStyle.Tone.waiting.text).frame(width: 96)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LedgerCountdown.isAutomatic(prompt)
                                     ? String(localized: "Auto-continues in \(LedgerCountdown.spoken(deadline: prompt.deadline, now: now))")
                                     : String(localized: "Answer within \(LedgerCountdown.spoken(deadline: prompt.deadline, now: now))"))
            }
        } else {
            Label("Waiting for you", systemImage: "hand.raised").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioStyle.Tone.waiting.text)
                .help(LedgerPromptText.heldText(prompt))
        }
    }
}
